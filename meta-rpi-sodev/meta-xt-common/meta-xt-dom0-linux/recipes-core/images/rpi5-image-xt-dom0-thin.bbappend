# Dom0 = toolstack: install the DomU xl guest config (+ create/attach services)
# into the Dom0 rootfs (the toolstack that runs `xl create`).
# Additive bbappend — the base rpi5-image-xt-dom0-thin.bb is not modified.
#   xt-xen-cfg-domu : DomU xl guest config + xl-create/attach services (was the
#                     the DomU layer's dom0-thin bbappend, folded in here).
#
# The DomA xl guest config (xt-xen-cfg-doma) and the AAOS kernel/ramdisk staging
# (aaos-guest-binaries:do_deploy) are added by the meta-xt-doma bbappend for this
# image, which is only in bblayers when ENABLE_ANDROID=yes (rpi5-sodev.yaml). This
# keeps a DomA-less build (ENABLE_ANDROID=no) from requiring an unbuildable
# meta-xt-doma provider.
# [ENABLE_DOMU gate] xt-xen-cfg-domu carries the auto-enabled xl-create-domu.service,
# so install it only when a DomU is built. The moulin dom0-linux conf sets
# XT_DOMU_CFG_INSTALL="xt-xen-cfg-domu" for ENABLE_DOMU=yes, else "" (a guest-less
# build must not ship a service that fails every boot). Default "" for standalone parse.
XT_DOMU_CFG_INSTALL ??= ""
IMAGE_INSTALL:append = " ${XT_DOMU_CFG_INSTALL}"
# [ENABLE_DOMZ gate] Same for DomZ (the Zephyr RTOS domain). In THIS flavour Dom0
# owns the xl toolstack, so domz.cfg + xl-create-domz.service belong in the Dom0
# rootfs; the moulin dom0-linux conf sets XT_DOMZ_CFG_INSTALL="xt-xen-cfg-domz"
# when DomZ is built (--domz), else "".
XT_DOMZ_CFG_INSTALL ??= ""
IMAGE_INSTALL:append = " ${XT_DOMZ_CFG_INSTALL}"

# Dedicated USB-C point-to-point management network into Linux Dom0:
#   host side: DHCP from 192.168.77.10-192.168.77.20/24
#   Dom0 side: 192.168.77.2/24 (usb0)
IMAGE_INSTALL:append = " dom0-usb-gadget"

# Advertised name for USB management discovery.
SODEV_MANAGEMENT_HOSTNAME ??= "basecamp"

ROOTFS_POSTPROCESS_COMMAND += "set_usb_gadget_hostname; "
set_usb_gadget_hostname() {
    echo "${SODEV_MANAGEMENT_HOSTNAME}" > ${IMAGE_ROOTFS}${sysconfdir}/hostname
    sed -i 's|@SODEV_MANAGEMENT_HOSTNAME@|${SODEV_MANAGEMENT_HOSTNAME}|g' \
        ${IMAGE_ROOTFS}${bindir}/dom0-usb-gadget-up
}
