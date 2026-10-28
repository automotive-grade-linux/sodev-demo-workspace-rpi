SUMMARY = "DomD boot-time switches for the DomA device model's display path (RPi4)"
DESCRIPTION = "A tmpfiles.d entry that creates the /run/qemu-* files the q11 qemu series reads \
(ISP / SAND direct scanout, plane handoff), so the display configuration measured on the RPi4 \
is active from boot with the qemu 11 device model. See qemu-domd-display.conf."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://qemu-domd-display.conf"
S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${S}/qemu-domd-display.conf ${D}${nonarch_libdir}/tmpfiles.d/
}

FILES:${PN} = "${nonarch_libdir}/tmpfiles.d/qemu-domd-display.conf"
