require recipes-bsp/trusted-firmware-a/trusted-firmware-a.inc

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Current master branch
SRCREV_tfa = "09a1cc2a0bd066702daa269bf35de9c5743ccc93"
SRCBRANCH = "master"

LIC_FILES_CHKSUM += "file://docs/license.rst;md5=b5fbfdeb6855162dded31fadcd5d4dc5"

COMPATIBLE_MACHINE:raspberrypi5 = "raspberrypi5"

TFA_PLATFORM:raspberrypi5 = "rpi5"

TFA_SPD:raspberrypi5 = "opteed"
TFA_BUILD_TARGET:raspberrypi5 = "bl31"
TFA_INSTALL_TARGET:raspberrypi5 = "armstub8-2712"

DEPENDS:append:raspberrypi5 = " optee-os"

do_compile:append:raspberrypi5() {
    # Create a secure flash image for booting via Video Core. See:
    # https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git/tree/docs/plat/rpi5.rst
    cp ${BUILD_DIR}/bl31.bin ${BUILD_DIR}/armstub8-2712.bin
    dd if=${STAGING_DIR_TARGET}${nonarch_base_libdir}/firmware/tee-raw.bin \
       		of=${BUILD_DIR}/armstub8-2712.bin bs=1024 seek=512 conv=notrunc
}

# ---------------------------------------------------------------------------
# BCM2712 stepping for the SCMI pinctrl server
# ---------------------------------------------------------------------------
# This layer supports BCM2712 D0 boards only. The pin controller is NOT
# register-compatible with C0: on D0 the VideoCore firmware rewrites the node to
#   compatible = "brcm,bcm2712d0-pinctrl"; reg = <0x7d504100 0x20>;   (C0: 0x30)
# via overlays/bcm2712d0.dtbo, which it applies on D0 boards only and ignores on
# C0.
#
# The TF-A this build fetches -- the xen-troops fork, selected by the
# xt-prod-devel-rpi5-domd bbappend; upstream TF-A has no Pi 5 pin controller
# code at all -- carries only the C0 register map, so the pad accesses for
# gpio24..35 land at offset 0x24, past the end of the D0 block. Measured: an
# SCMI bias-pull-up on gpio30..35 wedges the requesting CPU in EL3 with no
# output whatsoever, and the mux requests quietly configure the wrong pins. The
# patch adds the D0 tables (transcribed from the Linux driver) and this flag
# selects them; it defaults to 0 in platform.mk, the C0 tables.
#
# On a C0 board the D0 tables aim the SCMI pin requests at other pins'
# registers, so do not carry this flag over to another board without checking
# its stepping.
SRC_URI:append:raspberrypi5 = " file://0001-plat-rpi5-pinctrl-add-BCM2712-D0-stepping-tables.patch"
EXTRA_OEMAKE:append:raspberrypi5 = " RPI5_PINCTRL_D0=1"
