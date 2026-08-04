FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

require optee-machine.inc

OPTEE_VIRT_GUEST_COUNT ?= "2"

EXTRA_OEMAKE:append = " \
	CFG_NS_VIRTUALIZATION=y \
        CFG_VIRT_GUEST_COUNT=${OPTEE_VIRT_GUEST_COUNT} \
	"
SRC_URI += "\
    file://0001-plat-rpi5-add-basic-Raspberry-Pi-5-support.patch \
"
