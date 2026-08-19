SUMMARY = "Xen runtime cfg for the DomZ (Zephyr RTOS) guest (xl create)"
DESCRIPTION = "\
    /etc/xen/domz.cfg + xl-create-domz.service. Installed into the rootfs of \
    whichever domain runs the toolstack: DomD in the Zephyr-Dom0 flavour, the \
    thin Dom0 in the linux one (both component confs set XT_DOMZ_CFG_INSTALL). \
    DomZ needs no rootfs, no device model and no disk attach, so unlike \
    xt-xen-cfg-domu/doma this recipe ships nothing but the guest config and the \
    unit that creates it. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://domz.cfg \
    file://xl-create-domz.service \
    "

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "xl-create-domz.service"
SYSTEMD_AUTO_ENABLE = "enable"

# The unit needs `xl`; the mount in ExecStartPre is busybox.
RDEPENDS:${PN} = "xen-tools-xl"

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/domz.cfg ${D}${sysconfdir}/xen/domz.cfg

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-domz.service \
        ${D}${systemd_system_unitdir}/xl-create-domz.service
}

FILES:${PN} = " \
    ${sysconfdir}/xen/domz.cfg \
    ${systemd_system_unitdir}/xl-create-domz.service \
    "
