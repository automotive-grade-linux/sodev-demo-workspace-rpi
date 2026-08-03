SUMMARY = "DomD GPU bring-up unit (ordered vc4/v3d module load)"
DESCRIPTION = "Installs domd-gpu-init.service, a oneshot unit ordered before \
weston.service. It modprobes i2c-brcmstb, then vc4, then v3d in that order -- \
vc4 master's component_bind_all needs the DDC i2c adapter (brcmstb-i2c) bound \
first or HDMI bind fails, and modules-load.d gives no ordering guarantee -- and \
pins V3D runtime-active as a guard for the 6.18 runtime-PM hang under Xen. The \
compositor itself is started by the stock systemd weston.service, as on the V4H \
reference implementation; this recipe no longer supplies a PID 1."

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://domd-gpu-init.sh \
    file://domd-gpu-init.service \
    "

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "domd-gpu-init.service"
SYSTEMD_AUTO_ENABLE = "enable"

# modprobe comes from kmod; the modules themselves are separate image packages
# (kernel-module-i2c-brcmstb / kernel-module-vc4 / kernel-module-v3d).
RDEPENDS:${PN} = "kmod"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/domd-gpu-init.sh ${D}${libexecdir}/domd-gpu-init

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/domd-gpu-init.service \
        ${D}${systemd_system_unitdir}/domd-gpu-init.service
}

FILES:${PN} = " \
    ${libexecdir}/domd-gpu-init \
    ${systemd_system_unitdir}/domd-gpu-init.service \
    "
