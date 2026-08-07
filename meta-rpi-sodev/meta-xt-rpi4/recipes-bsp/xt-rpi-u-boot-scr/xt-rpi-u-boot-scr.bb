# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
SUMMARY = "U-boot boot script for Xen on Raspberry Pi 4"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
COMPATIBLE_MACHINE = "^raspberrypi4-64$"

DEPENDS = "u-boot-mkimage-native"

INHIBIT_DEFAULT_DEPS = "1"

TEMPLATE_FILE = "boot.cmd.xen.in"

# Upstream xen-troops/meta-xt-rpi5 assembles boot.cmd from boot.cmd.xen.{1,2,3}.in
# templates. This board does not: the bbappend's do_compile:raspberrypi4-64 override
# supplies a static board-tuned boot.cmd, so no fragments are fetched here.
SRC_URI = ""
# Nothing is unpacked into ${UNPACKDIR}/${BP}, so point S at UNPACKDIR itself;
# otherwise do_unpack warns that the directory named by S does not exist.
S = "${UNPACKDIR}"
MMC_PASSTHROUGH_DTBO = "mmc-passthrough.dtbo"
USB_PASSTHROUGH_DTBO = "usb-passthrough.dtbo"
PCIE1_PASSTHROUGH_DTBO = "pcie1-passthrough.dtbo"
HDMI_PASSTHROUGH_DTBO = "hdmi-passthrough.dtbo"
# RPi4-only: releases the on-SoC gpio/spi0/i2c1 the CAN overlays claim. On BCM2712
# those controllers sat inside RP1 and the single RP1 passthrough covered them.
CAN_PASSTHROUGH_DTBO = "can-passthrough.dtbo"

BOOT_MEDIA ?= "mmc"
DOM0_IMAGE ?= "zephyr.bin"
DOM0_IMG_ADDR ?= "0x2400000"
DOMD_IMAGE ?= "Image"
DOMD_IMG_ADDR ?= "0xa4000000"
DOMD_DTB ?= "${RPI_SOC_FAMILY}-${MACHINE}-domd.dtb"
DOMD_DTB_ADDR ?= "0xa0000000"
XEN_IMAGE ?= "xen"
XEN_IMG_ADDR ?= "0x2000000"
XEN_DTBO ?= "${RPI_SOC_FAMILY}-${MACHINE}-xen.dtbo"
UBOOT_BOOT_SCRIPT ?= "boot.scr"
UBOOT_BOOT_SCRIPT_SOURCE ?= "boot.cmd"

# Not declared here, following meta-xt-rpi5: XEN_DTBO_ADDR, XENPOLICY_IMAGE,
# XENPOLICY_IMG_ADDR, XEN_BOOTARGS, DOM0_BOOTARGS and DOMD_BOOTARGS. They are
# substitution inputs for upstream's .1/.2/.3.in template assembly, which this recipe
# does not perform, so nothing would read them — and a second, unread copy of the
# hypervisor command line next to the real one is how the RPi5 recipe ended up
# advertising dom0_mem/xsm values its boot scripts never used. The live values are in
# files/raspberrypi4-64/boot.cmd.xen.{linux,zephyr}-dom0.in.
#
# The DOM0_/DOMD_/XEN_ IMAGE and *_ADDR variables above ARE kept, and their values are
# this board's, not upstream's: they document the BCM2711 load-address budget the static
# scripts were checked against. Note DOMD_IMAGE = "Image" (uncompressed) where RPi5 uses
# Image.gz, and that the DomD kernel/DTB load high (0xa4000000 / 0xa0000000) because
# BCM2711's low memory is carved up between Xen, Dom0 and DomD's static-mem banks.
# The memory-map cross-check validates the boot scripts, not these variables.

# XEN_OVERLAYS is likewise not consumed by any task here; it is kept because it is the
# shape upstream's templated path expects, and because it documents which overlays the
# static boot script applies. Note that rpi4-sodev.yaml does NOT include
# xt-prod-devel-rpi5-domd — the layer whose bbappend appends to XEN_OVERLAYS on RPi5 —
# because that layer also retargets trusted-firmware-a at the xen-troops rpi5_dev fork,
# which is not what this board builds.
XEN_OVERLAYS = "${XEN_DTBO}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_mmc", " ${MMC_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_usb", " ${USB_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_nvme", " ${PCIE1_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_hdmi", " ${HDMI_PASSTHROUGH_DTBO}", "", d)}"
XEN_OVERLAYS:append = "${@bb.utils.contains("MACHINE_FEATURES", "domd_can", " ${CAN_PASSTHROUGH_DTBO}", "", d)}"

do_compile() {
    # STUB: the real boot script is produced by the bbappend override
    # (do_compile:raspberrypi4-64), which copies a static board-tuned boot.cmd and
    # runs mkimage. COMPATIBLE_MACHINE is ^raspberrypi4-64$, so this machine-agnostic
    # body is always fully overridden and never runs; it exists only to keep the
    # base recipe self-consistent (empty boot.cmd + mkimage, no references to files
    # this layer does not carry).
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
