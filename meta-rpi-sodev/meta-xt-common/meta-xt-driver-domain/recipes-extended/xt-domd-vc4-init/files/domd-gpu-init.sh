#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# DomD GPU bring-up, run once before the compositor starts.
#
# This used to be a PID-1 script (rdinit=/init-vc4.sh) that also launched weston
# by hand. weston is now started by the stock systemd weston.service, as on V4H,
# so only the parts that systemd cannot express declaratively remain here.
set -u

log() { echo "domd-gpu-init: $*"; }

# 1. Ordered GPU module load.
#
# The order is load-bearing and cannot be expressed with modules-load.d, which
# gives no ordering guarantee: vc4's component_bind_all() needs the DDC i2c
# adapter (i2c-brcmstb) already bound, otherwise the HDMI components fail to
# bind and no connector appears. That is also why CONFIG_I2C_BRCMSTB is pinned
# to =m in xen-config-a4b-frontend.cfg -- a built-in i2c driver would take the
# udev-driven load order away from us.
# Failures are accumulated and reported through the exit status. Reporting success
# unconditionally would make this unit show `active (exited)` with a dead GPU, and
# the first visible error would then be weston timing out 120 s later -- far from
# the real cause. A stale kernel-module package after a kernel bump (vermagic
# mismatch) is the realistic way for all three to fail at once.
failed=0
for m in i2c-brcmstb vc4 v3d; do
    if modprobe "$m"; then
        log "modprobe $m ok"
    else
        log "ERROR: modprobe $m failed"
        failed=$((failed + 1))
    fi
done

# 2. Pin V3D runtime-active (belt-and-suspenders for the 6.18 runtime-PM hang).
#
# 6.18 added V3D autosuspend, which POWER_OFFs the V3D SMS power island and gates
# the core clock through the firmware mailbox / power domain. Under Xen those
# resources do not belong to DomD, so DomD cannot complete the power-off/on
# handshake and the first GPU idle->resume (e.g. a virtio-gpu-gl guest starting to
# render) wedges the whole board. Kernel patch 0012 already pins the device
# active; writing power/control=on (pm_runtime_forbid) is a redundant runtime
# guard for the case where the device binds through a path that patch misses.
pinned=0
for f in /sys/devices/platform/axi/*.v3d/power/control \
         /sys/devices/platform/*.v3d/power/control \
         /sys/bus/platform/devices/*.v3d/power/control; do
    if [ -e "$f" ] && echo on > "$f" 2>/dev/null; then
        log "pinned $f = on"
        pinned=$((pinned + 1))
    fi
done
# Log the miss too: if v3d EPROBE_DEFERs none of the globs match, nothing is
# pinned, and silence would hide that the runtime-PM guard is not in force.
[ "$pinned" -gt 0 ] || log "WARNING: no V3D power/control node found; runtime-PM pin NOT applied"

# 3. Virtual terminals.
#
# weston.service carries ConditionPathExists=/dev/tty0 and TTYPath=/dev/tty7.
# devtmpfs normally provides both, so this is only a fallback for the case where
# it does not; it is deliberately non-fatal.
[ -c /dev/tty0 ] || mknod /dev/tty0 c 4 0 2>/dev/null || log "WARNING: no /dev/tty0"
n=1
while [ $n -le 7 ]; do
    if [ ! -c "/dev/tty$n" ]; then
        mknod "/dev/tty$n" c 4 $n 2>/dev/null && chmod 0600 "/dev/tty$n"
    fi
    n=$((n + 1))
done

# 4. Diagnostics (journal).
log "dri nodes: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
log "modules: $(grep -E '^(vc4|v3d|drm) ' /proc/modules | cut -d' ' -f1 | tr '\n' ' ')"

if [ "$failed" -gt 0 ]; then
    log "FAILED: $failed of 3 GPU modules did not load"
    exit 1
fi
exit 0
