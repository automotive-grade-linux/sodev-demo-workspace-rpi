SUMMARY = "DomD VC4 graphics driver-domain partial device tree (compiled to dtb)"
DESCRIPTION = "Compiles and deploys the DomD partial device tree (host DTB + \
/passthrough/{v3d,mailbox,hdmi,hvs,pixelvalve...}) used by the dom0less DomD, and \
stages the shared DomD kernel Image for reference. DomD owns vc4-drm (V3D + HVS + \
HDMI + mailbox via Option II passthrough) and runs weston as the sole graphics \
compositor for both HDMI outputs (HDMI-A-1 = Cluster IC, HDMI-A-2 = DomU surface \
via virglrenderer). \
Note: under the shipping dom0less setup DomD is created by Xen from boot modules, \
so no xl config / systemd service is shipped here; only the DTB \
(via do_deploy) is consumed downstream."

PV = "0.2"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit deploy

SRC_URI = " \
    file://bcm2712-raspberrypi5-domd-vc4.dts \
"

S = "${UNPACKDIR}"

# dtc-native for dts -> dtb compilation
DEPENDS = "dtc-native virtual/kernel"

# Use the full partial DT with an explicit /passthrough/{v3d,mailbox,hdmi,
# hvs,pixelvalve...} (xen,path + interrupt-parent = <&gic>, phandle = <0xfde8>
# matching the libxl auto-gen GIC) and compile it with dtc.
#
# An empty /passthrough{} does not work: libxl_arm.c copy_partial_fdt() copies
# the /passthrough subtree, so an empty /passthrough copies nothing (the &gic +
# GPU device nodes needed for phandle resolution are absent), vc4-drm fails to
# bind, /dev/dri is not created, and weston crash-loops.
do_compile() {
    dts="${UNPACKDIR}/bcm2712-raspberrypi5-domd-vc4.dts"
    if [ "${DOM0_OS}" = "linux" ]; then
        # Linux Dom0 is the hardware domain and OWNS the SoC SDHCI (mmc@fff000 +
        # AON GPIO stay in Dom0). Strip the DomD SD/GPIO passthrough block so the
        # dom0less DomD does NOT claim mmc IRQ SPI273 (route_irq_to_guest -EBUSY)
        # nor the AON GPIO. Zephyr keeps the block (dtc reads the pristine source,
        # so the zephyr DTB is byte-identical). Filtered copy uses a distinct
        # basename (B == S == UNPACKDIR) so it never clobbers the source.
        strip="${B}/bcm2712-raspberrypi5-domd-vc4-linux.dts"
        sed '/SODEV-LINUX-DOM0-SD-STRIP-BEGIN/,/SODEV-LINUX-DOM0-SD-STRIP-END/d' \
            "$dts" > "$strip"
        # Self-validate the strip: if the BEGIN/END markers are ever renamed or removed
        # by a future .dts edit, sed silently passes the file through unchanged and the
        # Linux DomD would claim the SoC mmc IRQ (SPI273) + AON GPIO that Dom0-Linux owns
        # -> route_irq_to_guest -EBUSY at DomD creation, with NO build error. Fail loudly.
        if cmp -s "$dts" "$strip"; then
            bbfatal "domd-vc4: SD-STRIP markers not found in ${dts} (DOM0_OS=linux) -> refusing to ship an unstripped DomD DT"
        fi
        dts="$strip"
    fi
    dtc -O dtb -I dts -o ${B}/bcm2712-raspberrypi5-domd-vc4.dtb \
        "$dts" 2>${B}/dtc-compile.log
    bbnote "Compiled partial DT (DOM0_OS=${DOM0_OS}): $(stat -c '%s' ${B}/bcm2712-raspberrypi5-domd-vc4.dtb) bytes"
}
# DOM0_OS gates the filtered-vs-pristine DTB, so it must be in the task hash
# (otherwise building zephyr then linux in one sstate cache reuses the wrong DTB).
do_compile[vardeps] += "DOM0_OS"

# Deploy the partial DT (V4H pattern) into DEPLOY_DIR_IMAGE.
# install_guest_payload (rpi5-image-xt-dom0-thin) copies from DEPLOY_DIR_IMAGE.
do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${B}/bcm2712-raspberrypi5-domd-vc4.dtb \
        ${DEPLOYDIR}/bcm2712-raspberrypi5-domd-vc4.dtb
}
addtask deploy after do_compile before do_build

do_install() {
    # DTB (compiled from dts)
    install -d ${D}/usr/lib/xen/boot
    install -m 0644 ${B}/bcm2712-raspberrypi5-domd-vc4.dtb \
        ${D}/usr/lib/xen/boot/bcm2712-raspberrypi5-domd-vc4.dtb

    # DomD kernel (reuses the same Linux Image as Dom0; renamed for clarity)
    if [ -f ${DEPLOY_DIR_IMAGE}/Image ]; then
        install -m 0644 ${DEPLOY_DIR_IMAGE}/Image \
            ${D}/usr/lib/xen/boot/linux-domd-vc4
    fi

    # Generated dts (host DTB + /passthrough, for reference)
    install -d ${D}${datadir}/xen/dts
    install -m 0644 ${B}/bcm2712-raspberrypi5-domd-vc4.dts \
        ${D}${datadir}/xen/dts/bcm2712-raspberrypi5-domd-vc4.dts
}

# DEPLOY_DIR_IMAGE access (kernel Image) happens at do_install time. Ensure ordering.
do_install[depends] += "virtual/kernel:do_deploy"

FILES:${PN} = " \
    /usr/lib/xen/boot/bcm2712-raspberrypi5-domd-vc4.dtb \
    /usr/lib/xen/boot/linux-domd-vc4 \
    ${datadir}/xen/dts/bcm2712-raspberrypi5-domd-vc4.dts \
"
