SUMMARY = "The cluster service for AGL Instrument Cluster."
DESCRIPTION = "\
    The cluster-service is a common implementation for functional service \
    of cluster.  It aim to use reusable implementation for inter process \
    communication and process design. "
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://LICENSE;md5=ae6497158920d9524cf208c09cc4c984"

DEPENDS = "systemd"

PV = "1.0.0+rev${SRCPV}"

SRCREV = "6a583971dd1a98f45e7acf8e12733710bb1bc32e"
SRC_URI = " \
    git://github.com/agl-ic-eg/cluster-service.git;branch=main;protocol=https \
    file://cluster-service.service \
    "
# carla CAN-forwarding patch/sources dropped: not required on the RPi5 architecture.
# wrynose: S now defaults to ${UNPACKDIR}/${BP} (git unpacks there); explicit S removed

inherit autotools pkgconfig systemd

SYSTEMD_SERVICE:${PN} = "cluster-service.service"

do_install:append() {
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/cluster-service.service ${D}${systemd_unitdir}/system/
}
