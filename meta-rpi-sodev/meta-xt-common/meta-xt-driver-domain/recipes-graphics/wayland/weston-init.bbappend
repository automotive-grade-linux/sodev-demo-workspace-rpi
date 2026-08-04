FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# DomD runs the stock poky weston.service + weston.socket, as the V4H reference
# implementation does. weston therefore keeps poky's defaults: WESTON_USER
# "weston", Type=notify with --modules=systemd-notify.so, PAMName=weston-autologin
# (logind provides the per-user runtime dir) and WantedBy=graphical.target. The
# clients connect to poky's GLOBAL socket, ${runtimedir}/wayland-0 = /run/wayland-0,
# published by weston.socket -- see the XDG_RUNTIME_DIR drop-in installed with the
# DomD image. That avoids the uid assumption V4H's own drop-in carries (it hard
# codes /run/user/1000 and is labelled a temporary hack upstream).

# Dual-HDMI kiosk-shell config: kiosk-shell routes each guest's surface to an
# output by app-id (SDL_VIDEO_WAYLAND_WMCLASS) -- DomU cluster -> HDMI-A-1,
# DomA/AAOS -> HDMI-A-2, replacing poky's desktop-shell default.
#
# poky's weston-init already has `file://weston.ini` in SRC_URI, so the
# FILESEXTRAPATHS:prepend above is what makes that entry resolve to OUR file --
# no second SRC_URI entry is needed. poky then runs its own seds on it
# (backend=, xwayland=, idle-time=, use-pixman=) which would append duplicate
# keys to a file that already sets them explicitly. The re-install in
# do_install:append below therefore matters: it puts our unmodified file back
# after those seds have run.
#
# NOTE: the renderer-diagnostic weston.ini variants (pixman / glrender) and the
# weston-simple-egl GPU-validation service live in the opt-in
# meta-rpi-sodev-devel weston-init.bbappend.
# Weston startup SEGV workaround: a race between the kernel fbcon and weston
# acquiring DRM master. Restart=on-failure retries 2 seconds later; the second
# attempt succeeds once fbcon has settled. A proper fix belongs upstream
# (weston / systemd sequencing).
SRC_URI += "file://97-restart-on-failure.conf"
# Watchdog off + finite start timeout.
SRC_URI += "file://98-no-watchdog.conf"
# V3D_DEBUG for the compositor (was exported by the old PID-1 launcher).
SRC_URI += "file://95-v3d-env.conf"
# Late-EDID race: hold weston until the DRM mode lists stop changing. HDMI-A-2's
# panel answers the EDID read 3.7 s after weston would otherwise have enabled the
# output, the kernel rebuilds the connector's mode list, and weston keeps using a
# mode that no longer exists -- every atomic commit then fails with EINVAL and the
# panel is dark for the rest of the session. Measured on hardware 2026-08-03; see
# the header of weston-wait-drm-modes.sh.
SRC_URI += "file://96-wait-drm-modes.conf"
SRC_URI += "file://weston-wait-drm-modes.sh"


do_install:append() {
    install -d ${D}${sysconfdir}/xdg/weston
    install -m 0644 ${UNPACKDIR}/weston.ini \
        ${D}${sysconfdir}/xdg/weston/weston.ini

    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${UNPACKDIR}/97-restart-on-failure.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/97-restart-on-failure.conf
    install -m 0644 ${UNPACKDIR}/98-no-watchdog.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/98-no-watchdog.conf
    install -m 0644 ${UNPACKDIR}/95-v3d-env.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/95-v3d-env.conf
    install -m 0644 ${UNPACKDIR}/96-wait-drm-modes.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/96-wait-drm-modes.conf

    # ExecStartPre of the drop-in above. A script rather than an inline Exec line
    # because the poll loop needs a shell.
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/weston-wait-drm-modes.sh \
        ${D}${libexecdir}/weston-wait-drm-modes
}

# weston.ini itself is already in poky's FILES:${PN}; only the drop-ins are new.
FILES:${PN} += " \
    ${systemd_system_unitdir}/weston.service.d/97-restart-on-failure.conf \
    ${systemd_system_unitdir}/weston.service.d/98-no-watchdog.conf \
    ${systemd_system_unitdir}/weston.service.d/95-v3d-env.conf \
    ${systemd_system_unitdir}/weston.service.d/96-wait-drm-modes.conf \
    ${libexecdir}/weston-wait-drm-modes \
"
