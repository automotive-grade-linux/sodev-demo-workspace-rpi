# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
SUMMARY = "A small image just capable of allowing a device to boot."

# NAME: the "rpi5-" prefix is retained deliberately even though this is the RPi4
# layer. It is a RECIPE name, and what depends on it is board-independent:
# meta-xt-driver-domain/recipes-core/images/rpi5-image-xt-domd-vc4.bb `require`s it by
# path, rpi5-image-xt-domd.bb in this directory does too, rpi4-sodev.yaml names
# rpi5-image-xt-domd-v4h as the domd build_target, and several meta-xt-common bbappends
# (rpi5-image-xt-domd-v4h.bbappend, rpi5-image-xt-dom0-thin.bbappend, ...) attach to
# those names. Renaming would touch a dozen unrelated files for no functional gain.
#
# The body below is entirely machine-neutral: trusted-firmware-a builds PLAT=rpi4 and
# rpi-bootfiles produces the RPi4 config.txt, both selected by MACHINE rather than by
# anything here.
require recipes-core/images/core-image-minimal.bb

# Enable package manager
EXTRA_IMAGE_FEATURES += "package-management"

RDEPENDS += "rpi-bootfiles trusted-firmware-a"

do_image[depends] += " \
    rpi-bootfiles:do_deploy \
    trusted-firmware-a:do_deploy \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot-tools-native:do_populate_sysroot', '',d)} \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot:do_deploy', '',d)} \
    ${@bb.utils.contains('RPI_USE_U_BOOT', '1', 'u-boot-default-script:do_deploy', '',d)} \
"

# Basic packages
PACKAGE_INSTALL:append = " \
    coreutils \
    u-boot \
    xen \
    xen-tools-scripts-network \
    xen-tools-scripts-block \
    xen-tools-xenstore \
    xen-tools-devd \
    virtual-xenstored \
    xen-network \
"

IMAGE_FSTYPES:remove = "wic.bz2 wic.bmap ext3"
IMAGE_FSTYPES:append = " ext4"
