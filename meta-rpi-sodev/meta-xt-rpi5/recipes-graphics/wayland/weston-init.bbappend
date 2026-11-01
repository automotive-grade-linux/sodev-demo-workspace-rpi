# SPDX-License-Identifier: MIT
#
# DomA's display on the Raspberry Pi 5 is a 1920x1080 HDMI monitor on HDMI-A-2.
# DomU (the AGL cluster) stays on HDMI-A-1 at 1920x720.
#
# The shared weston.ini (meta-xt-driver-domain) gives HDMI-A-2 the 1920x720 panel's
# own DTD. It is left alone because the RPi4 layer depends on that exact line: its
# rpi4_hdmi1_modeline requires it to stay once, in HDMI-A-2's section, and fails the
# build otherwise. So the Pi 5 rewrites its copy here, after install, and the RPi4's
# generated file does not change.
#
# CEA-861 VIC 16 (1920x1080@60, 148.5 MHz, h 88/44/148, v 4/5/36), NOT `cvt 1920 1080
# 60`: CVT's wider blanking (173 MHz, htotal 2576) is a computed timing for sinks
# without an EDID, and many HDMI monitors refuse it. A refused modeline does not fail
# loudly -- the atomic commit returns EINVAL for the rest of the session, weston never
# presents a frame and the CRTC keeps scanning out DomD's fbcon.
#
# The guest side of the same resolution is doma.cfg's virtio-gpu xres/yres, rewritten
# by this layer's xt-xen-cfg-doma bbappend. The two must agree: a mismatch does not
# fail, kiosk-shell just scales the guest surface.

# postfuncs, not do_install:append, for the reason given in meta-xt-rpi4's
# weston-init.bbappend: the shared layer re-installs weston.ini from its own
# do_install:append, and the order of :append fragments across layers is parse order.
do_install[postfuncs] += "rpi5_doma_output_fhd"

RPI5_DOMA_PANEL_MODE ?= "mode=93.24 1920 1968 2010 2100 720 723 733 740 +hsync +vsync"
RPI5_DOMA_FHD_MODE ?= "mode=148.5 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync"

rpi5_doma_output_fhd:raspberrypi5() {
    ini="${D}${sysconfdir}/xdg/weston/weston.ini"
    [ -f "$ini" ] || bbfatal "weston-init.bbappend (rpi5): $ini not installed"

    # Refuse to guess: the panel line must be there exactly once (HDMI-A-2's), and
    # HDMI-A-1 must not carry it.
    n=$(grep -cxF '${RPI5_DOMA_PANEL_MODE}' "$ini")
    if [ "$n" != "1" ]; then
        bbfatal "weston-init.bbappend (rpi5): expected HDMI-A-2's panel modeline exactly \
once in $ini, found $n. Looked for:\n  ${RPI5_DOMA_PANEL_MODE}"
    fi
    sed -i "s|^${RPI5_DOMA_PANEL_MODE}\$|${RPI5_DOMA_FHD_MODE}|" "$ini"

    n=$(grep -cxF '${RPI5_DOMA_FHD_MODE}' "$ini")
    if [ "$n" != "1" ] || grep -qxF '${RPI5_DOMA_PANEL_MODE}' "$ini"; then
        bbfatal "weston-init.bbappend (rpi5): the HDMI-A-2 rewrite did not apply cleanly to $ini"
    fi
    # The rewritten line has to be the one in the HDMI-A-2 section.
    if [ "$(awk '/^name=/{o=$0} $0=="${RPI5_DOMA_FHD_MODE}"{print o}' "$ini")" != "name=HDMI-A-2" ]; then
        bbfatal "weston-init.bbappend (rpi5): the 1920x1080 modeline is not in the HDMI-A-2 section of $ini"
    fi
    # The two comment lines above that modeline transcribe the 1920x720
    # panel's DTD. Say what the line is on this board instead, with the same
    # exactly-once checks.
    note_old="# The panel's own preferred DTD, transcribed from its EDID:"
    dtd_old="#   1920x720@60, 93.24 MHz, h 1920 1968 2010 2100, v 720 723 733 740, +hsync +vsync"
    note_new="# CEA-861 VIC 16, the Raspberry Pi 5's 1920x1080 DomA monitor:"
    dtd_new="#   1920x1080@60, 148.5 MHz, h 1920 2008 2052 2200, v 1080 1084 1089 1125, +hsync +vsync"
    if [ "$(grep -cxF "$note_old" "$ini")" != "1" ] || [ "$(grep -cxF "$dtd_old" "$ini")" != "1" ]; then
        bbfatal "weston-init.bbappend (rpi5): expected the panel DTD note above HDMI-A-2's modeline exactly once in $ini"
    fi
    sed -i -e "s|^$note_old\$|$note_new|" -e "s|^$dtd_old\$|$dtd_new|" "$ini"
    if [ "$(grep -cxF "$note_new" "$ini")" != "1" ] || [ "$(grep -cxF "$dtd_new" "$ini")" != "1" ] \
       || grep -qxF "$dtd_old" "$ini"; then
        bbfatal "weston-init.bbappend (rpi5): the HDMI-A-2 note rewrite did not apply cleanly to $ini"
    fi
    bbnote "weston-init.bbappend (rpi5): HDMI-A-2 modeline -> ${RPI5_DOMA_FHD_MODE}"
}

# Default is a no-op, as for meta-xt-rpi4's postfuncs: bitbake gives a postfunc its
# flags from the unsuffixed definition, so without this one exec_func fails on
# every machine with "'NoneType' object has no attribute 'get'".
rpi5_doma_output_fhd() {
    :
}

do_install[vardeps] += "RPI5_DOMA_PANEL_MODE RPI5_DOMA_FHD_MODE"

# weston's priority and CPU on the Raspberry Pi 5 (decided 2026-10-27): nice -19 like
# the device models, on DomD's CPU 0 beside DomA's device model (the DomD qemu wrapper's
# taskset -c 0), off CPU 1, where DomU's device model and its Venus ring threads run.
# A systemd drop-in rather than a renice of the running process, so that only the
# threads weston starts itself get -19 and Mesa's shader disk-cache thread
# (weston:disk$0) keeps the nice 19 / SCHED_BATCH that Mesa gives it.
FILESEXTRAPATHS:prepend:raspberrypi5 := "${THISDIR}/files:"
SRC_URI:append:raspberrypi5 = " file://99-rpi5-priority.conf"
do_install:append:raspberrypi5() {
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/99-rpi5-priority.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/99-rpi5-priority.conf
}
FILES:${PN}:append:raspberrypi5 = " ${systemd_system_unitdir}/weston.service.d/99-rpi5-priority.conf"
