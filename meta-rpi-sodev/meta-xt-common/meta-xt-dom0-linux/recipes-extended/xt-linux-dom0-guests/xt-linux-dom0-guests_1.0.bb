SUMMARY = "Linux Dom0 (DOM0_OS=linux) guest bring-up glue"
DESCRIPTION = "\
    For the thin-Linux control Dom0 flavour ONLY (ships in rpi5-image-xt-dom0-thin, \
    never in the DomD rootfs image). DomD is dom0less in both flavours; in the linux \
    flavour Dom0 owns the SD, so it must block-attach the guest partitions \
    (p3 -> xvdb, p4 -> xvdc) to the dom0less DomD, whose `xl devd` then spawns the \
    guest device-models against them. Provides: \
      - xl-attach-disks.service : the Dom0 -> DomD block-attach (existence-guarded). \
      - xl-create-{domu,doma,domz}.service.d/10-linux-dom0.conf : drop-ins that replace \
        the DomD-only Requires=domd-toolstack-prep.service (a Zephyr-xenstore seeder \
        absent from a Linux Dom0) with Requires on the real toolstack (xenstored) + \
        xl-attach-disks.service. Shipped as drop-ins so the shared xl-create-* units \
        (also installed into the DomD rootfs image for the zephyr flavour) are untouched. \
    "

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://xl-attach-disks.service \
    file://domd-toolstack-prep.service \
    file://xl-create-domu.service.d/10-linux-dom0.conf \
    file://xl-create-doma.service.d/10-linux-dom0.conf \
    file://xl-create-domz.service.d/10-linux-dom0.conf \
    "

S = "${UNPACKDIR}"

# xl block-attach / xenstore-{read,exists} come from the xen tools; the thin-Linux
# Dom0 image installs them already, but declare the runtime deps explicitly.
RDEPENDS:${PN} = "xen-tools-xl xen-tools-xenstore"

inherit systemd

SYSTEMD_SERVICE:${PN} = "xl-attach-disks.service domd-toolstack-prep.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-attach-disks.service \
        ${D}${systemd_system_unitdir}/xl-attach-disks.service
    install -m 0644 ${UNPACKDIR}/domd-toolstack-prep.service \
        ${D}${systemd_system_unitdir}/domd-toolstack-prep.service

    install -d ${D}${systemd_system_unitdir}/xl-create-domu.service.d
    install -m 0644 ${UNPACKDIR}/xl-create-domu.service.d/10-linux-dom0.conf \
        ${D}${systemd_system_unitdir}/xl-create-domu.service.d/10-linux-dom0.conf

    install -d ${D}${systemd_system_unitdir}/xl-create-doma.service.d
    install -m 0644 ${UNPACKDIR}/xl-create-doma.service.d/10-linux-dom0.conf \
        ${D}${systemd_system_unitdir}/xl-create-doma.service.d/10-linux-dom0.conf

    # DomZ (Zephyr RTOS domain): no xl-attach-disks dependency, DomZ has no disk.
    install -d ${D}${systemd_system_unitdir}/xl-create-domz.service.d
    install -m 0644 ${UNPACKDIR}/xl-create-domz.service.d/10-linux-dom0.conf \
        ${D}${systemd_system_unitdir}/xl-create-domz.service.d/10-linux-dom0.conf
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/xl-attach-disks.service \
    ${systemd_system_unitdir}/domd-toolstack-prep.service \
    ${systemd_system_unitdir}/xl-create-domu.service.d/10-linux-dom0.conf \
    ${systemd_system_unitdir}/xl-create-doma.service.d/10-linux-dom0.conf \
    ${systemd_system_unitdir}/xl-create-domz.service.d/10-linux-dom0.conf \
    "
