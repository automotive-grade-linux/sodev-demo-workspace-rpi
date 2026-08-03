
# This bbappend is load-bearing: it decides which trusted-firmware-a source the
# DomD build actually uses. It replaces the upstream tree with the xen-troops
# fork, whose plat/rpi/rpi5 already carries the RPi5 platform and SCMI support
# this board needs, and pins it by SRCREV. TFA is built only in the DomD build
# (this layer is in that build's layers and not the Dom0 one), and the armstub
# that lands on SD p1 comes from there, so this override is not optional.
#
# Current master branch
SRC_URI_TRUSTED_FIRMWARE_A = "git://github.com/xen-troops/arm-trusted-firmware.git;protocol=https"

SRCREV_tfa = "9446cc4ea01d22155959b1df7f98f0ef3627e505"
SRCBRANCH = "rpi5_dev"

EXTRA_OEMAKE += "${@bb.utils.contains('MACHINE_FEATURES', 'scmi', 'SCMI_SERVER_SUPPORT=1', 'SCMI_SERVER_SUPPORT=0', d)}"


