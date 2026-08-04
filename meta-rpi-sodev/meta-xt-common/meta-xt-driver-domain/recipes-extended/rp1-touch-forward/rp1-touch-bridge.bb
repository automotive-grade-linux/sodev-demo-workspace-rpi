SUMMARY = "RP1 touch output routing udev rule (DomD)"
DESCRIPTION = "Ships 72-rp1-touch-output.rules, which routes the native RP1 USB \
touch panel (passed through to DomD) to the AAOS output (HDMI-A-2) in weston and \
force-enumerates it on a <5A PSU."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PV = "1.0"

SRC_URI = "file://72-rp1-touch-output.rules"
S = "${UNPACKDIR}"

do_install() {
    # udev rule: bind the passed-through RP1 touchscreen to the AAOS output in weston.
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/72-rp1-touch-output.rules ${D}${sysconfdir}/udev/rules.d/72-rp1-touch-output.rules
}

FILES:${PN} += "${sysconfdir}/udev/rules.d/72-rp1-touch-output.rules"
