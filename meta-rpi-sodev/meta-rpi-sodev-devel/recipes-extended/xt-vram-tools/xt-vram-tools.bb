# SPDX-License-Identifier: Apache-2.0
SUMMARY = "VRAM dump + analysis tools for stripe noise root cause investigation"
DESCRIPTION = "CMA / VRAM reproducer: dump-cma.sh + analyze-vram.py + \
verify-stripe-bug.sh for diagnosing weston gl-renderer / Mesa V3D Gallium \
stripe noise on RPi5 + Xen Dom0 setup."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://dump-cma.sh \
    file://analyze-vram.py \
    file://verify-stripe-bug.sh \
    file://measure-weston-load.sh \
    file://domd-gpu-firstcheck.sh \
"

S = "${UNPACKDIR}"

# analyze-vram.py needs python3 + PIL (python3-pillow)
# measure-weston-load.sh needs weston-examples (weston-simple-egl/weston-terminal) + procps (top)
# domd-gpu-firstcheck.sh needs modetest (libdrm-tests) + kmscube + weston-simple-egl (weston-examples)
RDEPENDS:${PN} = " \
    python3 \
    python3-pillow \
    libdrm-tests \
    kmscube \
    weston-examples \
    bash \
    coreutils \
    procps \
"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/dump-cma.sh ${D}${bindir}/dump-cma.sh
    install -m 0755 ${UNPACKDIR}/analyze-vram.py ${D}${bindir}/analyze-vram.py
    install -m 0755 ${UNPACKDIR}/verify-stripe-bug.sh ${D}${bindir}/verify-stripe-bug.sh
    install -m 0755 ${UNPACKDIR}/measure-weston-load.sh ${D}${bindir}/measure-weston-load.sh
    install -m 0755 ${UNPACKDIR}/domd-gpu-firstcheck.sh ${D}${bindir}/domd-gpu-firstcheck.sh
}

FILES:${PN} = " \
    ${bindir}/dump-cma.sh \
    ${bindir}/analyze-vram.py \
    ${bindir}/verify-stripe-bug.sh \
    ${bindir}/measure-weston-load.sh \
    ${bindir}/domd-gpu-firstcheck.sh \
"
