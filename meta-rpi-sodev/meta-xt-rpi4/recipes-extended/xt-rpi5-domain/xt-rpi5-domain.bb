SUMMARY = "RPi4 domain helpers for the disaggregated Xen layout"
DESCRIPTION = "\
    Board-specific helpers for the RPi4 domain topology (thin control domain + \
    dom0less driver domain + guests). \
\
    Components: \
      /usr/lib/xen/bin/domain-cpu-pin                 (boot-time vCPU pinning) \
      /usr/lib/systemd/system/domain-cpu-pin.service  (runs it once xencommons is up) \
\
    The control domain and the dom0less driver domain are built without an xl \
    config, so they cannot pin themselves the way the xl-created guests do with \
    'cpus='; this recipe pins them after the toolstack is up. Add further RPi4 \
    domain helpers here rather than forking the upstream meta-xt-common recipes."

# THE NAME IS `xt-rpi5-domain` DELIBERATELY, in the Raspberry Pi 4 layer.
#
# Boot-time vCPU pinning lives in the BOARD layer, and the shared DomD/Dom0 images
# install it by name:
#     meta-xt-driver-domain/recipes-core/images/rpi5-image-xt-domd-vc4.bb
#         IMAGE_INSTALL:append = " ... xt-rpi5-domain ..."
#     meta-xt-dom0-linux/recipes-core/images/rpi5-image-xt-dom0-thin.bb
#         IMAGE_INSTALL = " ... xt-rpi5-domain ..."
# Naming this recipe xt-rpi4-domain instead makes those images unbuildable on this
# board -- verified, not assumed:
#     ERROR: Nothing RPROVIDES 'xt-rpi5-domain' (but rpi5-image-xt-domd-v4h.bb
#            RDEPENDS on or otherwise requires it)
#     ERROR: Required build target 'rpi5-image-xt-domd-v4h' has no buildable providers.
# Keeping the name is the same decision as keeping the rpi5-image-* recipe names (see
# README.md): these are RECIPE names shared with meta-xt-common, not board names, and
# the alternative is a rename touching a dozen unrelated files.
#
# domain-cpu-pin and its unit are byte-identical to the meta-xt-rpi5 ones on purpose:
# the script is board-agnostic (it only issues `xl vcpu-pin`) and the CPU map it encodes
# -- Dom0 -> pcpu 0, dom0less DomD -> pcpu 0-1, DomU -> 1, DomA -> 2-3 -- applies
# unchanged to BCM2711, which is also a 4-core part (Cortex-A72 x4 instead of A76 x4).
# If the Raspberry Pi 4 map ever diverges, change files/domain-cpu-pin HERE; the
# meta-xt-rpi5 copy is a different file in a layer that is never loaded with this one.

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
