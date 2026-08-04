SUMMARY = "Xen runtime cfg for the DomU guest (xl create)"
DESCRIPTION = "\
    /etc/xen/domu.cfg + xl-create-domu.service (disaggregated topology: runs inside DomD, the \
    toolstack domain). qemu reads the DomU rootfs directly from /dev/mmcblk0p3 \
    (DomD owns the SD via SDHCI passthrough); the old Dom0-blkback \
    xl-attach-disks chain is gone. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# xl-attach-disks.service is dropped from the package:
# the Dom0-blkback disk chain does not exist under the Zephyr Dom0; DomD
# owns the SD (SDHCI passthrough) and qemu reads /dev/mmcblk0pN directly.
SRC_URI = " \
    file://domu.cfg \
    file://xl-create-domu.service \
    "

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = " \
    xl-create-domu.service \
    "
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/domu.cfg ${D}${sysconfdir}/xen/domu.cfg

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-domu.service ${D}${systemd_system_unitdir}/xl-create-domu.service
}

FILES:${PN} = " \
    ${sysconfdir}/xen/domu.cfg \
    ${systemd_system_unitdir}/xl-create-domu.service \
    "
