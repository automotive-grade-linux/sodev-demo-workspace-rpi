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
