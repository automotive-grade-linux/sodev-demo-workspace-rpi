#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# domd-gpu-firstcheck.sh: orchestrated one-shot check of DomD GPU rendering.
#
# Goal: in the current config (xl-create DomD + GPU passthrough), step through
#   how far GPU rendering works and isolate whether the HDMI noise is
#     (a) Mesa V3D Gallium (D0 stepping), or
#     (b) scanout/DMA/direct-map.
#   Each step stops so HDMI can be photographed with a webcam.
#
# Decision logic:
#   - modetest (kernel DRM, no Mesa) shows clean color bars -> scanout/HVS/DMA healthy
#   - pixman weston (CPU render) also clean                  -> confirms the above
#   - only V3D gl-renderer / kmscube striped                 -> root cause is Mesa V3D (needs mesa >= 26.0, V3D 7.1.10 D0 shader-state support)
#   - modetest itself striped/garbled                        -> scanout/DMA/direct-map
#
# Usage (in the DomD console, as root):
#   domd-gpu-firstcheck.sh            # run all steps in order (Enter to advance)
#   domd-gpu-firstcheck.sh --auto 10  # auto-advance after 10 s per step (unattended/recording)
#   CONN_MODE=<conn>@<crtc>:<WxH> domd-gpu-firstcheck.sh  # override the probed modetest target

AUTO=0
WAIT=10
if [ "$1" = "--auto" ]; then
    AUTO=1
    [ -n "$2" ] && WAIT="$2"
fi

# modetest target. The object ids are runtime enumeration values and the mode
# depends on the attached panel, so probe them rather than hardcoding a value from
# one particular board+cable setup. CONN_MODE overrides the probe.
if [ -z "${CONN_MODE:-}" ]; then
    _c=$(modetest -M vc4 -c 2>/dev/null | awk '$2=="connected"{print $1; exit}')
    _r=$(modetest -M vc4 -p 2>/dev/null | awk '/^[0-9]+/{print $1; exit}')
    _m=$(modetest -M vc4 -c 2>/dev/null | awk '/#0/{print $2; exit}')
    [ -n "$_c" ] && [ -n "$_r" ] && [ -n "$_m" ] && CONN_MODE="${_c}@${_r}:${_m}"
fi
CONN_MODE="${CONN_MODE:-}"

# Back up the ORIGINAL weston.ini before Steps 4/5 overwrite it with the
# pixman/glrender diagnostic variants. The shipping weston.ini (kiosk-shell,
# dual-output app-id routing) is neither of those, so we save it here and restore
# it in cleanup. The [ ! -f ] guard preserves a good backup across a re-run after
# a mid-way abort (i.e. we never back up an already-swapped variant over it).
WESTON_INI=/etc/xdg/weston/weston.ini
WESTON_INI_ORIG=/etc/xdg/weston/weston.ini.firstcheck-orig
if [ -f "$WESTON_INI" ] && [ ! -f "$WESTON_INI_ORIG" ]; then
    cp "$WESTON_INI" "$WESTON_INI_ORIG"
    echo "  (saved original weston.ini -> $WESTON_INI_ORIG)"
fi

# Restore the original weston.ini and restart weston on ANY exit -- including an
# operator Ctrl-C at a "Press Enter" pause, which would otherwise leave DomD stuck
# on the pixman/glrender diagnostic profile. Mirrors verify-stripe-bug.sh's trap.
restore_weston_ini() {
    if [ -f "$WESTON_INI_ORIG" ]; then
        cp "$WESTON_INI_ORIG" "$WESTON_INI"
        echo "  restored $WESTON_INI from $WESTON_INI_ORIG"
    elif [ -f /etc/xdg/weston/weston.ini.pixman ]; then
        # Fallback only (no original backup captured, e.g. weston.ini absent at start).
        cp /etc/xdg/weston/weston.ini.pixman "$WESTON_INI"
        echo "  no original backup found; fell back to the pixman variant"
    fi
    systemctl restart weston 2>/dev/null || true
}
trap restore_weston_ini EXIT

pause() {
    echo ""
    if [ "$AUTO" = "1" ]; then
        echo ">>> [$1] Photograph HDMI now. Advancing in ${WAIT}s..."
        sleep "$WAIT"
    else
        echo ">>> [$1] Photograph HDMI now. Press Enter to advance..."
        read -r _
    fi
}

echo "==================================================================="
echo " DomD GPU first-check  ($(date '+%F %T'))  host=$(hostname)"
echo "==================================================================="

# ---- Step 1: device layer (before rendering) ----------------------------
echo ""
echo "===== Step 1: GPU device layer ====="
echo "--- uname ---"; uname -r
echo "--- /dev/dri ---"; ls -l /dev/dri/ 2>/dev/null
echo "--- /sys/module vc4/v3d (built-in check) ---"; ls /sys/module/ 2>/dev/null | grep -iE "vc4|v3d|drm" || echo "(none)"
echo "--- lsmod vc4/v3d ---"; lsmod | grep -iE "vc4|v3d" || echo "(modular driver not loaded or built-in)"
echo "--- dmesg vc4/v3d bind ---"; dmesg | grep -iE "vc4|v3d|bound .* (hvs|hdmi|gpu)" | tail -20
echo "--- connector status ---"; for s in /sys/class/drm/*/status; do echo "  $s = $(cat "$s" 2>/dev/null)"; done
echo "--- modetest connectors/crtcs ---"; modetest -M vc4 -c 2>/dev/null | grep -iE "^id|connected|^[0-9]+\s" | head -20
echo "  (using CONN_MODE=$CONN_MODE. If wrong, pick from above and re-run with CONN_MODE=)"

# ---- Step 2: modetest (no Mesa) = core of the decision -------------------
echo ""
echo "===== Step 2: modetest SMPTE color bars (no Mesa / direct kernel DRM scanout) ====="
echo "  clean color bars -> scanout/HVS/DMA healthy (=> root cause is Mesa)"
echo "  noise/garbled    -> scanout/HVS/DMA problem below Mesa: check the DomD's"
echo "                      xen,static-mem + direct-map ranges and the CMA window"
systemctl stop weston-simple-egl weston weston.socket 2>/dev/null || true
sleep 1
tail -f /dev/null | modetest -M vc4 -s "$CONN_MODE" -v &
MTPID=$!
echo "  modetest PID=$MTPID ($CONN_MODE)"
sleep 3
pause "Step2 modetest"
kill $MTPID 2>/dev/null || true
wait $MTPID 2>/dev/null || true

# ---- Step 3: kmscube (GBM/EGL, V3D 3D without weston) --------------------
echo ""
echo "===== Step 3: kmscube (GBM/EGL = V3D 3D, without weston) ====="
echo "  clean rotating cube -> V3D render path healthy"
echo "  striped/garbled     -> V3D Gallium (Mesa) is the cause (confirmed if Step2 was clean)"
if command -v kmscube >/dev/null 2>&1; then
    kmscube -D /dev/dri/card0 &
    KCPID=$!
    sleep 3
    pause "Step3 kmscube"
    kill $KCPID 2>/dev/null || true
    wait $KCPID 2>/dev/null || true
else
    echo "  kmscube not present (skip)"
fi

# ---- Step 4: weston pixman (CPU render = current default) ----------------
echo ""
echo "===== Step 4: weston pixman renderer (CPU render = clean fallback) ====="
if [ -f /etc/xdg/weston/weston.ini.pixman ]; then
    cp /etc/xdg/weston/weston.ini.pixman /etc/xdg/weston/weston.ini
fi
systemctl restart weston 2>/dev/null || systemctl start weston 2>/dev/null || true
sleep 5
systemctl is-active weston 2>/dev/null || echo "  weston failed to start (check journalctl -u weston)"
echo "  starting weston-simple-egl (kms_swrast=CPU)"
( weston-simple-egl >/tmp/segl-pixman.log 2>&1 & ) || true
sleep 3
echo "  fps: $(grep -oE '[0-9.]+ fps' /tmp/segl-pixman.log | tail -1)"
echo "  expected: honeycomb background + RGB triangle rendered cleanly (CPU render, no noise)"
pause "Step4 weston-pixman"

# ---- Step 5: weston gl-renderer (V3D GPU hardware) ----------------------
echo ""
echo "===== Step 5: weston gl-renderer (V3D GPU hardware) ====="
echo "  Mesa unpatched -> vertical stripe noise (D0 stepping)"
echo "  mesa >= 26.0 -> clean (GPU acceleration works)"
if [ -f /etc/xdg/weston/weston.ini.glrender ]; then
    cp /etc/xdg/weston/weston.ini.glrender /etc/xdg/weston/weston.ini
    systemctl restart weston 2>/dev/null || true
    sleep 5
    ( weston-simple-egl >/tmp/segl-gl.log 2>&1 & ) || true
    sleep 3
    echo "  fps: $(grep -oE '[0-9.]+ fps' /tmp/segl-gl.log | tail -1)"
    pause "Step5 weston-glrender"
else
    echo "  weston.ini.glrender not present (skip)"
fi

# ---- restore the original weston.ini -------------------------------------
# Handled by the restore_weston_ini EXIT trap armed after the backup above, so it
# also fires on an operator Ctrl-C at a "Press Enter" pause. Nothing to restore
# here in the normal-completion path.
echo ""
echo "===== cleanup: restore original weston.ini (via EXIT trap) ====="

echo ""
echo "==================================================================="
echo " Decision guide:"
echo "   Step2 modetest clean + Step4 pixman clean + Step5 gl striped"
echo "     => root cause Mesa V3D => needs mesa >= 26.0 (V3D 7.1.10 D0 support)"
echo "   Step2 modetest itself striped/garbled"
echo "     => scanout/HVS/DMA problem below Mesa: re-check DomD's xen,static-mem"
echo "        + direct-map ranges in bcm2712-raspberrypi5-xen.dtso and the CMA size"
echo "==================================================================="
