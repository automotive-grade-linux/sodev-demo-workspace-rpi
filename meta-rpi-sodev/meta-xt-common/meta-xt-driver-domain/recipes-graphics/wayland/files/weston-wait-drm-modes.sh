#!/bin/sh
# Hold weston's start until the DRM connector mode lists have stopped changing.
#
# MEASURED ON HARDWARE (2026-08-03, RPi5 + the 12.3FHD panel on HDMI-A-2). weston
# enumerated HDMI-A-2 with "EDID make 'unknown'" and enabled the output from the
# pre-EDID mode list. The panel's EDID landed 3.7 s later, the kernel rebuilt that
# connector's mode list (5 modes -> 17), and weston logged
#
#     DRM: head 'HDMI-A-2' updated, ... EDID make 'PNP(RTD)', model '12.3FHD'
#     Detected a monitor change on head 'HDMI-A-2', not bothering to do anything
#     about it.
#
# and then failed EVERY subsequent atomic commit:
#
#     atomic: couldn't commit new state: Invalid argument
#     repaint-flush failed: No such file or directory
#
# The output stays dark permanently -- still failing 14 minutes later. Worse, the
# guest never notices: its virtio-gpu display has no present fences (AAOS reports
# PresentFences=false / RUNNING_WITHOUT_SYNC_FRAMEWORK=1), so SurfaceFlinger keeps
# composing into a framebuffer nobody scans out. Every guest-side check passes -
# sys.boot_completed=1, the launcher resumed, screencap returns the real UI - while
# the panel shows nothing. Restarting weston once the EDID is already cached clears
# it completely (verified: zero commit failures on the second start), so the fix is
# simply not to start weston before the mode lists have settled.
#
# Pinning the modeline in weston.ini does NOT prevent this, contrary to what the
# comment there used to imply. Pinning fixes a different symptom -- selecting the
# wrong mode while the EDID is missing -- and it works: the output did come up at
# 1920x720@93.240. What breaks is the mode list changing UNDER an output that is
# already enabled.
#
# Why wait for quiescence rather than for a non-empty EDID: HDMI-A-1 on this board
# has no EDID at all (measured: /sys/class/drm/card0-HDMI-A-1/edid is 0 bytes and
# weston reports "EDID make 'unknown'" for the whole session). Waiting for an EDID
# there would burn the full timeout on every boot. A mode list that will not move is
# what weston actually needs, and it is the correct test for both connectors.
# Reading the sysfs `modes` file also triggers a connector detect, so this polls the
# EDID into place instead of merely watching for it.
#
# This never blocks the boot. If the lists are still moving at the deadline it says
# so and lets weston start anyway: a late EDID is a degraded display, whereas a
# weston that never starts is no display at all. weston.service allows this --
# 98-no-watchdog.conf sets TimeoutStartSec=120 and ExecStartPre counts against it,
# so the 25 s ceiling here leaves ample room for the compositor's own start-up.
set -u

TIMEOUT=${WESTON_WAIT_DRM_TIMEOUT:-25}   # seconds before giving up and starting anyway
SETTLE=${WESTON_WAIT_DRM_SETTLE:-3}      # consecutive identical samples that count as settled

# One line per connected connector: "<name>:<comma-separated mode list>". Writeback
# and disconnected connectors are skipped -- they have no modes to stabilise.
snapshot() {
    for s in /sys/class/drm/card*-*/status; do
        [ -r "$s" ] || continue
        [ "$(cat "$s" 2>/dev/null)" = "connected" ] || continue
        d=${s%/status}
        printf '%s:%s\n' "${d##*/}" "$(tr '\n' ',' < "$d/modes" 2>/dev/null)"
    done
}

prev=""
stable=0
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
    cur=$(snapshot)
    # An empty snapshot means no connector has been probed yet, which is not the
    # same thing as a settled one -- do not let it satisfy the settle count.
    if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
        stable=$((stable + 1))
        if [ "$stable" -ge "$SETTLE" ]; then
            echo "weston-wait-drm-modes: mode lists settled after ${i}s"
            exit 0
        fi
    else
        stable=0
    fi
    prev=$cur
    sleep 1
    i=$((i + 1))
done

echo "weston-wait-drm-modes: still changing after ${TIMEOUT}s, starting weston anyway" >&2
echo "weston-wait-drm-modes: last snapshot: $(snapshot | tr '\n' ' ')" >&2
exit 0
