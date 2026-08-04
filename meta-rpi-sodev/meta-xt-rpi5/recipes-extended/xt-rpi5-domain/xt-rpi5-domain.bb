SUMMARY = "RPi5 domain helpers for the disaggregated Xen layout"
DESCRIPTION = "\
    Board-specific helpers for the RPi5 domain topology (thin control domain + \
    dom0less driver domain + guests). \
\
    Components: \
      /usr/lib/xen/bin/domain-cpu-pin                 (boot-time vCPU pinning) \
      /usr/lib/systemd/system/domain-cpu-pin.service  (runs it once xencommons is up) \
\
    The control domain and the dom0less driver domain are built without an xl \
    config, so they cannot pin themselves the way the xl-created guests do with \
    'cpus='; this recipe pins them after the toolstack is up. Add further RPi5 \
    domain helpers here rather than forking the upstream meta-xt-common recipes."

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://domain-cpu-pin \
    file://domain-cpu-pin.service \
    "

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "domain-cpu-pin.service"
SYSTEMD_AUTO_ENABLE = "enable"

# domain-cpu-pin drives the domains through xl.
RDEPENDS:${PN} = "xen-tools-xl"

do_install() {
    install -d ${D}/usr/lib/xen/bin
    install -m 0755 ${UNPACKDIR}/domain-cpu-pin ${D}/usr/lib/xen/bin/domain-cpu-pin

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/domain-cpu-pin.service \
        ${D}${systemd_system_unitdir}/domain-cpu-pin.service
}

FILES:${PN} = " \
    /usr/lib/xen/bin/domain-cpu-pin \
    ${systemd_system_unitdir}/domain-cpu-pin.service \
    "
