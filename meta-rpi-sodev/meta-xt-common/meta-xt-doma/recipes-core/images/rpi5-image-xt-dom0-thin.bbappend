# [DomA] Added to the Linux thin-Dom0 image only when meta-xt-doma is in bblayers
# (ENABLE_ANDROID=yes; see rpi5-sodev.yaml). Moved here from the meta-xt-dom0-linux
# base bbappend so a DomA-less build (ENABLE_ANDROID=no) does not require these
# meta-xt-doma providers (fixes "Nothing PROVIDES 'aaos-guest-binaries'").
#   xt-xen-cfg-doma : DomA xl guest config (+ DomD p4-augmented cfg).
# The AAOS guest kernel/ramdisk are deployed by the DomD build for both Dom0
# flavours (see rpi5-image-xt-domd-v4h.bbappend in this layer); the dom0 build no
# longer stages them.
IMAGE_INSTALL:append = " xt-xen-cfg-doma"
