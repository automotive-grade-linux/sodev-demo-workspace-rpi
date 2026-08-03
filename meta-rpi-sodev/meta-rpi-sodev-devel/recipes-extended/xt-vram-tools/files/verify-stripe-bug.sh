#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# verify-stripe-bug.sh: one-shot two-step reproducer.
#
# Step 1: stop weston, scan out SMPTE color bars directly to HVS via modetest
#         for 15 s, and confirm by eye that no vertical stripes are mixed in.
# Step 2: restart weston, dd-dump the CMA region via /dev/mem, render the
#         framebuffer to PNG with analyze-vram.py, and re-check for stripes.
#
# Usage:
#   verify-stripe-bug.sh             # normal mode
#   verify-stripe-bug.sh --pixman    # switch to weston.ini.pixman first, then test

set -e

PIXMAN=0
if [ "$1" = "--pixman" ]; then
    PIXMAN=1
    shift
fi

WORKDIR="${1:-/tmp/stripe-verify-$(date +%s)}"
mkdir -p "$WORKDIR"
echo "[stripe-verify] Workdir: $WORKDIR"

# --pixman mode overwrites the active weston.ini. Save the ORIGINAL first and
# restore it on exit (including an early abort under set -e), so the diagnostic
# does not leave DomD stuck on the single-HDMI pixman profile. Normal mode does
# not touch weston.ini, so no backup/restore is armed there.
WESTON_INI=/etc/xdg/weston/weston.ini
WESTON_INI_ORIG=/etc/xdg/weston/weston.ini.stripe-orig
restore_weston_ini() {
    if [ -f "$WESTON_INI_ORIG" ]; then
        echo "[stripe-verify] restoring original weston.ini"
        cp "$WESTON_INI_ORIG" "$WESTON_INI"
        systemctl restart weston 2>/dev/null || true
    fi
}

if [ "$PIXMAN" = "1" ]; then
    echo "[stripe-verify] Switching to pixman renderer..."
    # Back up the original once (guard keeps a good backup across re-runs).
    if [ -f "$WESTON_INI" ] && [ ! -f "$WESTON_INI_ORIG" ]; then
        cp "$WESTON_INI" "$WESTON_INI_ORIG"
    fi
    trap restore_weston_ini EXIT
    cp /etc/xdg/weston/weston.ini.pixman /etc/xdg/weston/weston.ini
    systemctl restart weston || true
    sleep 5
fi

echo ""
echo "===== Pre-modetest state ====="
# CONN_MODE is "<connector>@<crtc>:<WxH>". The object ids are runtime enumeration
# values and the mode depends on the attached panel, so both are probed here
# unless CONN_MODE is set in the environment.
if [ -z "${CONN_MODE:-}" ]; then
    conn=$(modetest -M vc4 -c 2>/dev/null | awk '$2=="connected"{print $1; exit}')
    crtc=$(modetest -M vc4 -p 2>/dev/null | awk '/^[0-9]+/{print $1; exit}')
    mode=$(modetest -M vc4 -c 2>/dev/null | awk '/#0/{print $2; exit}')
    if [ -n "$conn" ] && [ -n "$crtc" ] && [ -n "$mode" ]; then
        CONN_MODE="${conn}@${crtc}:${mode}"
    else
        echo "could not probe connector/crtc/mode; set CONN_MODE=<conn>@<crtc>:<WxH>" >&2
        exit 1
    fi
fi
echo "  using CONN_MODE=${CONN_MODE}"

modetest -M vc4 -p 2>&1 | grep -E "plane|crtc" | head -20

echo ""
echo "===== Step 1: modetest 15-sec SMPTE color bars ====="
echo "  command: modetest -M vc4 -s ${CONN_MODE} -v"
echo "  Look at HDMI: SMPTE color bars should appear"
echo "  If stripes overlay the bars -> HVS/IOMMU bug"
echo "  If bars are clean -> weston/V3D bug (Mesa V3D Gallium real culprit)"

systemctl stop weston-simple-egl weston weston.socket 2>&1 || true
sleep 1

tail -f /dev/null | modetest -M vc4 -s "${CONN_MODE}" -v &
MTPID=$!
echo "  modetest PID=$MTPID started at $(date +%H:%M:%S)"
sleep 15
echo "  killing modetest at $(date +%H:%M:%S)"
kill $MTPID 2>&1 || true
wait $MTPID 2>&1 || true

echo ""
echo "===== Restoring weston ====="
systemctl start weston 2>&1
sleep 5
# weston-simple-egl is NOT auto-started (SYSTEMD_SERVICE is disabled), so it is
# always inactive; querying it here would return non-zero and, under `set -e`,
# abort the script before Step 2. Only check weston, and tolerate a transient
# non-active state so the reproducer always reaches the CMA-dump step.
systemctl is-active weston || true

echo ""
echo "===== Step 2: CMA VRAM dump + framebuffer PNG ====="
DUMP="$WORKDIR/cma-dump.bin"
dump-cma.sh "$DUMP"

echo ""
echo "===== Analyzing CMA dump ====="
analyze-vram.py "$DUMP" "$WORKDIR/vram-png"

echo ""
echo "===== DONE ====="
echo "Results:"
echo "  Workdir:    $WORKDIR"
echo "  CMA dump:   $DUMP"
echo "  PNG output: $WORKDIR/vram-png/"
echo ""
echo "Next: visually inspect $WORKDIR/vram-png/region_*_thumb.png"
echo "  - stripe pattern present -> Mesa V3D Gallium or weston gl-renderer bug"
echo "  - no stripes (gray solid) -> a different cause (investigate if behavior changed)"
