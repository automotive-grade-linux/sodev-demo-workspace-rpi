# SPDX-License-Identifier: Apache-2.0
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Opt-in (devel) weston-init overlay. Installs the diagnostic weston.ini
# variants and the weston-simple-egl GPU-validation service that were split
# out of the shipping meta-xt-driver-domain weston-init.bbappend. The shipping
# append still installs the active weston.ini + the 95/97/98 drop-ins; this
# append only adds development-time extras. Both appends apply when this layer
# is opted in.

# Add systemd service for weston-simple-egl
SRC_URI += "file://weston-simple-egl.service"
# Alternate config: pixman software renderer, for bypassing the
# weston gl-renderer / Mesa V3D Gallium path during vertical-stripe noise
# investigation. Switch manually:
#   cp /etc/xdg/weston/weston.ini.pixman /etc/xdg/weston/weston.ini && \
#     systemctl restart weston
# Revert via weston.ini.glrender, an alternate single-HDMI desktop-shell
# gl-renderer config. NOTE: it is NOT a backup/copy of the shipping weston.ini
# (which is a kiosk-shell dual-output app-id-routing config from
# meta-xt-driver-domain); it is a separate diagnostic profile.
SRC_URI += "file://weston.ini.pixman"
SRC_URI += "file://weston.ini.glrender"

inherit systemd

# weston-simple-egl is a debug spinning-triangle app for GPU validation. It is
# not needed by the demo (DomU cluster + AAOS) and constantly consumed ~15% V3D
# plus some CPU, so its auto-start is disabled. The service file is still kept
# by the do_install below, so manual validation is possible via `systemctl start
# weston-simple-egl`.

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/weston-simple-egl.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/xdg/weston
    # Alternate: pixman software renderer.
    install -m 0644 ${UNPACKDIR}/weston.ini.pixman \
        ${D}${sysconfdir}/xdg/weston/weston.ini.pixman
    # Alternate: single-HDMI desktop-shell gl-renderer config (diagnostic;
    # NOT a backup of the shipping kiosk-shell weston.ini).
    install -m 0644 ${UNPACKDIR}/weston.ini.glrender \
        ${D}${sysconfdir}/xdg/weston/weston.ini.glrender
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/weston-simple-egl.service \
    ${sysconfdir}/xdg/weston/weston.ini.pixman \
    ${sysconfdir}/xdg/weston/weston.ini.glrender \
"
