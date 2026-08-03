# [DomA] Applies to the DomD v4h image only when ENABLE_ANDROID=yes: under =no
# every meta-xt-doma recipe (this bbappend included) is BBMASK'd (V4H-style gate,
# see rpi5-sodev.yaml XT_DOMA_BBMASK).
#   xt-aaos-host-services : DomA host backend daemons (VHAL/dumpstate/GNSS over
#                           vsock) that let the AAOS UI scan out to HDMI-A-2.
#   xt-xen-cfg-doma       : doma.cfg/domd.cfg + xl-create-doma.service. This image
#                           is now the DomD rootfs (the initramfs is out of the boot
#                           path), so the unit that creates DomA has to live here.
#   aaos-guest-binaries   : stages the AAOS guest kernel/ramdisk into this (DomD)
#                           build's DEPLOY_DIR_IMAGE for BOTH Dom0 flavours — the
#                           single, flavour-independent producer that the p1 aaos
#                           boot items consume (rpi5-sodev.yaml ENABLE_ANDROID=yes
#                           declares them as domd target_images).
IMAGE_INSTALL:append = " xt-aaos-host-services xt-xen-cfg-doma"
do_image[depends] += " aaos-guest-binaries:do_deploy"
