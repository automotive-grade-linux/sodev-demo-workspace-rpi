SUMMARY = "U-boot boot script for Xen on Raspberry Pi 5"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "^raspberrypi5$"

DEPENDS = "u-boot-mkimage-native"

INHIBIT_DEFAULT_DEPS = "1"

TEMPLATE_FILE = "boot.cmd.xen.in"

# The former boot.cmd.xen.{1,2,3}.in assembly was always discarded on rpi5 (the
# only COMPATIBLE_MACHINE), where the bbappend's do_compile:raspberrypi5 override
# supplies a static board-tuned boot.cmd. Those fragments were removed; the rpi5
# override adds the static .in files it needs via SRC_URI:append:raspberrypi5.
SRC_URI = ""
# Nothing is unpacked into ${UNPACKDIR}/${BP}, so point S at UNPACKDIR itself;
# otherwise do_unpack warns that the directory named by S does not exist.
S = "${UNPACKDIR}"
MMC_PASSTHROUGH_DTBO = "mmc-passthrough.dtbo"
USB_PASSTHROUGH_DTBO = "usb-passthrough.dtbo"
PCIE1_PASSTHROUGH_DTBO = "pcie1-passthrough.dtbo"
HDMI_PASSTHROUGH_DTBO = "hdmi-passthrough.dtbo"

BOOT_MEDIA ?= "mmc"
DOM0_IMAGE ?= "zephyr.bin"
DOM0_IMG_ADDR ?= "0xe00000"
# DOM0 image max size = 4M
DOMD_IMAGE ?= "Image.gz"
DOMD_IMG_ADDR ?= "0x1200000"
# DOMD image max size = 11M
DOMD_DTB ?= "${RPI_SOC_FAMILY}-${MACHINE}-domd.dtb"
DOMD_DTB_ADDR ?= "0x1d00000"
XEN_IMAGE ?= "xen"
XEN_IMG_ADDR ?= "0x2000000"
# XEN image max size = 2M
XEN_DTBO ?= "${RPI_SOC_FAMILY}-${MACHINE}-xen.dtbo"
UBOOT_BOOT_SCRIPT ?= "boot.scr"
UBOOT_BOOT_SCRIPT_SOURCE ?= "boot.cmd"

# Removed: XEN_DTBO_ADDR, XENPOLICY_IMAGE, XENPOLICY_IMG_ADDR, XEN_BOOTARGS,
# DOM0_BOOTARGS and DOMD_BOOTARGS. They were substitution inputs for the upstream
# .1/.2/.3.in template assembly, which this recipe no longer performs (see the
# SRC_URI comment above): nothing referenced them, and XEN_BOOTARGS in particular had
# drifted to state dom0_mem=128M and xsm=flask, while the static boot scripts really
# pass dom0_mem=512M and xsm=dummy. Keeping a stale, unread copy of the hypervisor
# command line next to the real one is worse than not having it. The live values are
# in meta-xt-rpi5/recipes-bsp/xt-rpi-u-boot-scr/files/boot.cmd.xen.*-dom0.in.
# The DOM0_/DOMD_/XEN_ IMAGE and *_ADDR variables above are kept: they still document
# the upstream load-address budget the static scripts were checked against.

# XEN_OVERLAYS is likewise not consumed by any task here. It is kept because the
# vendored xt-prod-devel-rpi5-domd bbappend appends to it, and that layer is carried
# pristine; removing the base assignment would leave those appends dangling.
XEN_OVERLAYS = "${XEN_DTBO}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_mmc", " ${MMC_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_usb", " ${USB_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_nvme", " ${PCIE1_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_hdmi", " ${HDMI_PASSTHROUGH_DTBO}", "", d)}"

do_compile() {
    # STUB: the real boot script is produced by the rpi5 bbappend override
    # (do_compile:raspberrypi5), which copies a static board-tuned boot.cmd and
    # runs mkimage. COMPATIBLE_MACHINE is ^raspberrypi5$, so this machine-agnostic
    # body is always fully overridden and never runs; it exists only to keep the
    # base recipe self-consistent (empty boot.cmd + mkimage, no removed-file refs).
    : > ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}
    mkimage -A ${UBOOT_ARCH} -T script -C none -n "Boot script" \
        -d "${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}" ${UBOOT_BOOT_SCRIPT}
}

inherit kernel-arch deploy nopackages

do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${UBOOT_BOOT_SCRIPT} ${DEPLOYDIR}
    install -m 0644 ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE} ${DEPLOYDIR}
}

addtask do_deploy after do_compile before do_build

PROVIDES += "u-boot-default-script"
