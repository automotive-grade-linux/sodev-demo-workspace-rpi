SUMMARY = "A small image just capable of allowing a device to boot."

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
