# SPDX-License-Identifier: Apache-2.0
SUMMARY = "AGL Cluster IC stand-in (shm + cairo)"
DESCRIPTION = "Speedometer + tripmeter rendered into wl_shm. A cluster stand-in \
that needs no GPU: useful for bringing a display path up before the V3D stack is \
known good, and for isolating compositor problems from GPU problems. \
Auto-starts via systemd after weston comes up."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://xt-cluster-shm.c \
    file://Makefile \
    file://xt-cluster-shm.service \
    file://README \
"

S = "${UNPACKDIR}"

DEPENDS = "wayland wayland-native wayland-protocols cairo"

inherit pkgconfig systemd

EXTRA_OEMAKE = "WAYLAND_SCANNER=${STAGING_BINDIR_NATIVE}/wayland-scanner WPROTODIR=${STAGING_DATADIR}/wayland-protocols"

do_compile() {
    oe_runmake -f ${S}/Makefile WAYLAND_SCANNER=${STAGING_BINDIR_NATIVE}/wayland-scanner \
        WPROTODIR=${STAGING_DATADIR}/wayland-protocols
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/xt-cluster-shm ${D}${bindir}/xt-cluster-shm

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xt-cluster-shm.service ${D}${systemd_system_unitdir}/xt-cluster-shm.service

    install -d ${D}${docdir}/${PN}
    install -m 0644 ${UNPACKDIR}/README ${D}${docdir}/${PN}/README
}

SYSTEMD_SERVICE:${PN} = "xt-cluster-shm.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

FILES:${PN} = " \
    ${bindir}/xt-cluster-shm \
    ${systemd_system_unitdir}/xt-cluster-shm.service \
    ${docdir}/${PN}/README \
"

RDEPENDS:${PN} = "cairo"
