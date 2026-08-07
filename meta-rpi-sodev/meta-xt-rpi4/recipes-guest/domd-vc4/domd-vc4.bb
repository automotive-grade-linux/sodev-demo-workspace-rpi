SUMMARY = "DomD VC4 graphics driver-domain partial device tree (compiled to dtb)"
DESCRIPTION = "Compiles and deploys the DomD partial device tree \
(/passthrough/{v3d,mailbox,hdmi,hvs,pixelvalve,genet,pcie,emmc2...}) used by the \
dom0less DomD, and stages the shared DomD kernel Image for reference. DomD owns \
vc4-drm (HVS + HDMI x2 + the VideoCore mailbox) and v3d (3D), plus GENET and — in \
the Zephyr flavour — the SD card, and runs weston as the sole compositor for both \
micro-HDMI outputs (HDMI-A-1 = Cluster IC, HDMI-A-2 = the DomU/DomA surface via \
virglrenderer). \
Under the shipping dom0less setup DomD is created by Xen from boot modules, so no \
xl config or systemd service is shipped here; only the DTB (via do_deploy) is \
consumed downstream."

PV = "0.2"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

# Templated from the machine so it cannot drift from the file on disk or from the
# deploy/boot-partition lists in rpi4-sodev.yaml, which use the same expansion.
# MACHINE is raspberrypi4-64, so this is bcm2711-raspberrypi4-64-domd-vc4.
DOMD_VC4_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-domd-vc4"

SRC_URI = " \
    file://${DOMD_VC4_DT_NAME}.dts \
"

S = "${UNPACKDIR}"

# dtc-native for dts -> dtb compilation
DEPENDS = "dtc-native virtual/kernel"

COMPATIBLE_MACHINE = "^raspberrypi4-64$"

# The partial DT carries an explicit /passthrough subtree (xen,path + xen,reg +
# interrupt-parent = <&gic> with phandle 0xfde8 = GUEST_PHANDLE_GIC) and is
# compiled with plain dtc.
#
# An empty /passthrough{} does not work: dom0less-build.c's
# domain_handle_dtb_boot_module() copies only the partial DT's `aliases` and
# `passthrough` nodes, so an empty /passthrough copies nothing — the device nodes
# needed for phandle resolution are absent, vc4-drm never binds, /dev/dri is not
# created and weston crash-loops.
#
# Validate the file before building:
#   The DT cross-check
# which dtc-compiles it and runs the DomD passthrough cross-check against the real
# bcm2711-rpi-4-b.dtb (page-aligned + non-overlapping xen,reg, xen,path targets
# that exist, and GIC SPIs that match the host nodes).
do_compile() {
    dts="${UNPACKDIR}/${DOMD_VC4_DT_NAME}.dts"
    if [ "${DOM0_OS}" = "linux" ]; then
        # The thin Linux Dom0 is the hardware domain and KEEPS the SD card
        # (/emmc2bus/mmc@7e340000, GIC SPI 126). Strip the DomD SD block so the
        # dom0less DomD does not re-request that SPI (route_irq_to_guest -EBUSY).
        # The Zephyr flavour keeps the block — dtc reads the pristine source, so
        # its DTB is byte-identical with these markers present. The filtered copy
        # uses a distinct basename (B == S == UNPACKDIR) so it never clobbers the
        # source.
        strip="${B}/${DOMD_VC4_DT_NAME}-linux.dts"
        sed '/SODEV-LINUX-DOM0-SD-STRIP-BEGIN/,/SODEV-LINUX-DOM0-SD-STRIP-END/d' \
            "$dts" > "$strip"
        # Self-validate the strip: if the BEGIN/END markers are ever renamed or
        # removed by a future .dts edit, sed silently passes the file through
        # unchanged and the Linux-flavour DomD would claim the SD IRQ that
        # Dom0-Linux owns -> route_irq_to_guest -EBUSY at DomD creation, with NO
        # build error. Fail loudly instead.
        if cmp -s "$dts" "$strip"; then
            bbfatal "domd-vc4: SD-STRIP markers not found in ${dts} (DOM0_OS=linux) -> refusing to ship an unstripped DomD DT"
        fi
        dts="$strip"
    fi
    dtc -O dtb -I dts -o ${B}/${DOMD_VC4_DT_NAME}.dtb \
        "$dts" 2>${B}/dtc-compile.log
    bbnote "Compiled partial DT (DOM0_OS=${DOM0_OS}): $(stat -c '%s' ${B}/${DOMD_VC4_DT_NAME}.dtb) bytes"
}
# DOM0_OS gates the filtered-vs-pristine DTB, so it must be in the task hash
# (otherwise building zephyr then linux against one sstate cache reuses the wrong
# DTB).
do_compile[vardeps] += "DOM0_OS"

# Deploy the partial DT into DEPLOY_DIR_IMAGE; rpi4-sodev.yaml copies it from
# there onto the boot partition, and install_guest_payload
# (rpi5-image-xt-dom0-thin) picks it up for the Dom0 initramfs.
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${B}/${DOMD_VC4_DT_NAME}.dtb \
        ${DEPLOYDIR}/${DOMD_VC4_DT_NAME}.dtb
}
addtask deploy after do_compile before do_build

do_install() {
    install -d ${D}/usr/lib/xen/boot
    install -m 0644 ${B}/${DOMD_VC4_DT_NAME}.dtb \
        ${D}/usr/lib/xen/boot/${DOMD_VC4_DT_NAME}.dtb

    # DomD kernel (the same Linux Image as Dom0; renamed for clarity)
    if [ -f ${DEPLOY_DIR_IMAGE}/Image ]; then
        install -m 0644 ${DEPLOY_DIR_IMAGE}/Image \
            ${D}/usr/lib/xen/boot/linux-domd-vc4
    fi

    # Source dts, for reference on the target
    install -d ${D}${datadir}/xen/dts
    install -m 0644 ${UNPACKDIR}/${DOMD_VC4_DT_NAME}.dts \
        ${D}${datadir}/xen/dts/${DOMD_VC4_DT_NAME}.dts
}

# DEPLOY_DIR_IMAGE access (the kernel Image) happens at do_install time.
do_install[depends] += "virtual/kernel:do_deploy"

FILES:${PN} = " \
    /usr/lib/xen/boot/${DOMD_VC4_DT_NAME}.dtb \
    /usr/lib/xen/boot/linux-domd-vc4 \
    ${datadir}/xen/dts/${DOMD_VC4_DT_NAME}.dts \
"
