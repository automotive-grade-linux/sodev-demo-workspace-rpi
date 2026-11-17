require recipes-bsp/trusted-firmware-a/trusted-firmware-a.inc

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
