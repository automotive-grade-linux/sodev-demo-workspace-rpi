SUMMARY = "DomD toolstack preparation for the Zephyr-Dom0 topology"
DESCRIPTION = "\
    Seeds the Zephyr Dom0 xenstore (cpupool name, xenconsoled backend domid), \
    creates the volatile libxl directories (/var/lib/xen, /var/log/xen/console) \
    and runs the console seeder that satisfies libxl's console waits, so that \
    DomD - a dom0less control domain - can run `xl create` for DomU/DomA. \
    All steps were verified on real HW . \
    "

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://domd-console-seeder.sh \
    file://domd-toolstack-prep.service \
    "

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "domd-toolstack-prep.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "xen-tools-xenstore"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/domd-console-seeder.sh ${D}${libexecdir}/domd-console-seeder.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/domd-toolstack-prep.service ${D}${systemd_system_unitdir}/domd-toolstack-prep.service
}

FILES:${PN} = " \
    ${libexecdir}/domd-console-seeder.sh \
    ${systemd_system_unitdir}/domd-toolstack-prep.service \
    "
