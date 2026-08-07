# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# --------------------------------------------------------------------------------
# 1. weston's seat must be bound to the VT its own unit declares (tty7).
#    Full rationale in files/96-vt-bind.conf. Without it the compositor is one
#    `chvt` away from a permanently black panel, which takes DomU's video with it.
#    chvt comes from kbd (busybox also ships one; /usr/bin/chvt is the
#    update-alternatives link, so either provider satisfies the path). kbd is
#    already in the DomD image; the RDEPENDS makes that a requirement instead of a
#    coincidence, because the drop-in silently degrades to "unit fails to start" if
#    the binary disappears.
SRC_URI += "file://96-vt-bind.conf"
RDEPENDS:${PN} += "kbd"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/96-vt-bind.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/96-vt-bind.conf
}

FILES:${PN} += "${systemd_system_unitdir}/weston.service.d/96-vt-bind.conf"

# --------------------------------------------------------------------------------
# 2. RPi4 board wiring fix: the 1920x720 panel is on micro-HDMI 1, not micro-HDMI 2.
#
# WHY THIS EXISTS
# meta-xt-driver-domain's weston.ini pins an explicit modeline per output and says so
# for good reason -- `mode=<WxH>` fails silently to a fallback when the mode is not yet
# in the connector list. Its two modelines encode the V4H/RPi5 bench wiring:
#
#   [output] HDMI-A-1   mode=111.75 1920 2016 2208 2496 720 723 733 748 -hsync +vsync
#            "HDMI-A-1 has no EDID at all", so this is `cvt 1920 720 60` output.
#   [output] HDMI-A-2   mode=93.24  1920 1968 2010 2100 720 723 733 740 +hsync +vsync
#            the panel's own preferred DTD, transcribed from its EDID (PNP RTD,
#            model "12.3FHD").
#
# On this RPi4 bench the SAME "12.3FHD" panel is plugged into micro-HDMI 1. Measured
# on hardware with modetest (2026-08-04):
#
#   35 34 connected HDMI-A-1
#     #0 1920x720 60.00 1920 1968 2010 2100 720 723 733 740 93240 phsync pvsync
#        type: preferred, driver
#   EDID: ... 00 fc 00 31 32 2e 33 46 48 44   ("12.3FHD")
#
# i.e. HDMI-A-1 DOES have an EDID here, and its preferred timing is the 93.24 MHz one
# the upstream file assigns to HDMI-A-2. Forcing the 111.75 MHz CVT timing onto a
# fixed-timing panel makes every atomic commit fail:
#
#   weston[555]: atomic: couldn't commit new state: Invalid argument
#   weston[555]: repaint-flush failed: No such file or directory
#
# repeated forever, so weston never presents a frame and the CRTC keeps scanning out
# fbcon's framebuffer -- the panel shows the DomD text console. Confirmed by
# /sys/kernel/debug/dri/1/state reporting `allocated by = [fbcon]` while weston was
# active, and fixed by this sed: after it, the same file reports `allocated by =
# weston` (XR24, 1920x720), the EINVAL storm stops, and weston-flower was VISIBLE on
# the panel (verified with a webcam, 2026-08-04).
#
# Only HDMI-A-1's modeline changes. The app-ids routing is untouched, so DomU still
# lands on HDMI-A-1 (`app-ids=qemu-system-aarch64-domu,DomU`) and DomA on HDMI-A-2 --
# which is what we want, since HDMI-A-1 is the connector with the panel on it.
#
# If the bench is ever rewired to the upstream arrangement, drop this bbappend rather
# than editing it: the point is that the DEFAULT file describes upstream's wiring.

# postfuncs, not do_install:append: the shared bbappend in meta-xt-driver-domain also
# uses do_install:append to put its own unmodified weston.ini back after poky's seds,
# and the relative order of two :append fragments across layers depends on parse
# order. A postfunc is guaranteed to run after do_install and every append to it.
do_install[postfuncs] += "rpi4_hdmi1_modeline"

RPI4_HDMI1_CVT_MODE ?= "mode=111.75 1920 2016 2208 2496 720 723 733 748 -hsync +vsync"
RPI4_HDMI1_PANEL_MODE ?= "mode=93.24 1920 1968 2010 2100 720 723 733 740 +hsync +vsync"

rpi4_hdmi1_modeline:raspberrypi4-64() {
    ini="${D}${sysconfdir}/xdg/weston/weston.ini"
    if [ ! -f "$ini" ]; then
        bbfatal "weston-init.bbappend (rpi4): $ini not installed -- the shared \
bbappend's do_install:append must have run before this postfunc"
    fi

    # Refuse to guess. If the CVT line is not there, either upstream changed the file
    # or someone already fixed it; both need a human, and silently doing nothing here
    # is exactly how the board would come back with a black panel again.
    if ! grep -qxF '${RPI4_HDMI1_CVT_MODE}' "$ini"; then
        if grep -qxF '${RPI4_HDMI1_PANEL_MODE}' "$ini"; then
            bbnote "weston-init.bbappend (rpi4): HDMI-A-1 already on the panel \
modeline; nothing to do"
            return
        fi
        bbfatal "weston-init.bbappend (rpi4): expected HDMI-A-1 modeline not found in \
$ini. Looked for:\n  ${RPI4_HDMI1_CVT_MODE}\nRe-derive it from \
modetest on the board before touching this."
    fi

    # Only the FIRST occurrence, which is HDMI-A-1's -- HDMI-A-2 keeps its own line.
    sed -i "0,\|^${RPI4_HDMI1_CVT_MODE}\$|s||${RPI4_HDMI1_PANEL_MODE}|" "$ini"

    if ! grep -qxF '${RPI4_HDMI1_PANEL_MODE}' "$ini"; then
        bbfatal "weston-init.bbappend (rpi4): sed did not apply to $ini"
    fi
    n=$(grep -cxF '${RPI4_HDMI1_PANEL_MODE}' "$ini")
    if [ "$n" != "2" ]; then
        bbfatal "weston-init.bbappend (rpi4): expected the panel modeline on BOTH \
outputs after the sed (HDMI-A-1 rewritten + HDMI-A-2 original), found $n in $ini"
    fi
    bbnote "weston-init.bbappend (rpi4): HDMI-A-1 modeline -> ${RPI4_HDMI1_PANEL_MODE}"
}

# The sed above edits a file the shared layer ships, so this bbappend's task hash must
# change when either modeline string does.
do_install[vardeps] += "RPI4_HDMI1_CVT_MODE RPI4_HDMI1_PANEL_MODE"

# 3. Same board wiring, second consequence: WHICH GUEST gets the attached panel.
#
# meta-xt-driver-domain's weston.ini routes DomU to HDMI-A-1 and DomA to HDMI-A-2, because
# on the reference bench both micro-HDMI ports have a panel. Here only micro-HDMI 1 is
# wired (measured: card0-HDMI-A-1 connected 1920x720, card0-HDMI-A-2 disconnected), so
# DomA was rendering to an output weston never creates -- nothing on screen at all.
#
# Swapping the two app-ids lists (rather than adding DomA to HDMI-A-1) keeps every app-id
# on exactly ONE output; listing DomA on both would leave kiosk-shell's choice ambiguous.
# DomU ends up on the dead output, which is acceptable on this board: a 4 GiB SKU cannot
# host DomA and DomU at the same time anyway (see xt-xen-cfg-doma_%.bbappend for the
# memory budget).
#
# THIS MUST STAY IN STEP WITH the touch routing in
# meta-xt-rpi4/recipes-extended/rp1-touch-forward/rp1-touch-bridge.bbappend, which points
# WL_OUTPUT at the same output. weston drops every touch event whose device has no output
# (libweston/libinput-device.c:460), and it does NOT fall back to the primary output when
# WL_OUTPUT names a disconnected one (libinput-seat.c:128-138), so a mismatch between the
# two files is silent: the picture appears and touch does nothing.
RPI4_DOMU_APPIDS ?= "app-ids=qemu-system-aarch64-domu,DomU"
RPI4_DOMA_APPIDS ?= "app-ids=qemu-system-aarch64-doma,DomA"

do_install[postfuncs] += "rpi4_doma_output_swap"
do_install[vardeps] += "RPI4_DOMU_APPIDS RPI4_DOMA_APPIDS"

rpi4_doma_output_swap:raspberrypi4-64() {
    ini="${D}${sysconfdir}/xdg/weston/weston.ini"
    if [ ! -f "$ini" ]; then
        bbfatal "weston-init.bbappend (rpi4): $ini not installed"
    fi

    # Which output currently carries DomA? Read it rather than assume, so an upstream
    # change of the reference layout is caught instead of silently swapped back.
    cur=$(awk -F= '/^name=/{o=$2} /^app-ids=.*DomA/{print o; exit}' "$ini")
    if [ "$cur" = "HDMI-A-1" ]; then
        bbnote "weston-init.bbappend (rpi4): DomA already on HDMI-A-1; nothing to do"
        return
    fi
    if [ "$cur" != "HDMI-A-2" ]; then
        bbfatal "weston-init.bbappend (rpi4): DomA is on output '$cur' in $ini, expected HDMI-A-2 (reference layout) or HDMI-A-1 (already swapped). Upstream changed the output map -- re-derive it from /sys/class/drm on the board before touching this."
    fi

    for l in '${RPI4_DOMU_APPIDS}' '${RPI4_DOMA_APPIDS}'; do
        n=$(grep -cxF "$l" "$ini")
        if [ "$n" != "1" ]; then
            bbfatal "weston-init.bbappend (rpi4): expected exactly one '$l' in $ini, found $n"
        fi
    done

    sed -i -e "s|^${RPI4_DOMU_APPIDS}\$|__RPI4_APPIDS_TMP__|" \
           -e "s|^${RPI4_DOMA_APPIDS}\$|${RPI4_DOMU_APPIDS}|" \
           -e "s|^__RPI4_APPIDS_TMP__\$|${RPI4_DOMA_APPIDS}|" "$ini"

    if grep -qF '__RPI4_APPIDS_TMP__' "$ini"; then
        bbfatal "rpi4_doma_output_swap: temporary token left behind in $ini"
    fi
    doma_out=$(awk -F= '/^name=/{o=$2} /^app-ids=.*DomA/{print o; exit}' "$ini")
    domu_out=$(awk -F= '/^name=/{o=$2} /^app-ids=.*DomU/{print o; exit}' "$ini")
    if [ "$doma_out" != "HDMI-A-1" ] || [ "$domu_out" != "HDMI-A-2" ]; then
        bbfatal "rpi4_doma_output_swap: after the swap DomA is on '$doma_out' and DomU on '$domu_out' in $ini, expected HDMI-A-1 / HDMI-A-2"
    fi
    bbnote "weston-init.bbappend (rpi4): DomA -> HDMI-A-1 (attached panel), DomU -> HDMI-A-2"
}

# Default is a no-op: this board-specific step only runs on raspberrypi4-64.
rpi4_hdmi1_modeline() {
    :
}

# Default is a no-op: this board-specific step only runs on raspberrypi4-64.
rpi4_doma_output_swap() {
    :
}

# Machine gating (required now that both boards live in one layer)
#
# The two postfuncs above encode a fact about THIS RPi4 bench -- only micro-HDMI 1 has a
# panel attached -- so they must not run on any other machine. RPi5 has a panel on both
# ports, where upstream weston.ini's assignment (DomU=HDMI-A-1 / DomA=HDMI-A-2) and its
# modeline are already correct.
#
# do_install[postfuncs] is a varflag and awkward to add or remove per machine, so the
# functions themselves are defined as `name:raspberrypi4-64()` with a same-named no-op as
# the default; bitbake resolves the override and runs the board-specific body on RPi4 and
# the no-op elsewhere.
