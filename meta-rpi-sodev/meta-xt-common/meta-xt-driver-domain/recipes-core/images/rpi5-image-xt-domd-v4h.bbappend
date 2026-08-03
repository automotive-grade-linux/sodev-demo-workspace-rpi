# [DomD deploy completeness] full.img (rouge) needs the full DomD boot-artifact
# set on p1, but the moulin domd component build_target is only this v4h image.
# The DomD partial device tree is produced by a separate recipe and was otherwise
# not built by `ninja domd`, so full.img failed with "no known rule to make it":
#   - bcm2712-raspberrypi5-domd-vc4.dtb  <- domd-vc4
# Pull it into this image's deploy so `ninja domd` produces the complete set.
# Applies to both DOM0_OS=linux and =zephyr (both full.img variants stage it on p1).
# Additive bbappend — the base rpi5-image-xt-domd-v4h.bb is not modified.
#
# No initramfs dependency any more: this ext4 image IS the DomD rootfs, mounted
# from p2 (directly in the zephyr flavour, over PV-block as xvda in the linux one).
# The RAM-initramfs image recipe is still in the tree but is no longer part of
# the shipping boot path -- see the README note on recovering an initramfs boot.
#
# The DomA host backend daemons (xt-aaos-host-services) and the AAOS guest
# kernel/ramdisk staging (aaos-guest-binaries:do_deploy, DOM0_OS=zephyr only) are
# added by the meta-xt-doma bbappend for this image, present only when
# ENABLE_ANDROID=yes — so a DomA-less build does not pull an unbuildable provider.
do_image[depends] += " domd-vc4:do_deploy"
