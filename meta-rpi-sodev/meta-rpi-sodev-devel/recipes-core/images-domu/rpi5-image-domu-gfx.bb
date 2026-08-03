# SPDX-License-Identifier: Apache-2.0
DESCRIPTION = "DomU graphics image with Wayland + Mesa (virgl) + SDL2 OpenGL ES \
for VirtIO-GPU based rendering. Bundled as initramfs to keep dom0less boot flow."

LICENSE = "Apache-2.0"

IMAGE_FEATURES = "empty-root-password allow-empty-password allow-root-login post-install-logging"
IMAGE_LINGUAS = ""
IMAGE_FSTYPES = "${INITRAMFS_FSTYPES}"

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    base-files \
    busybox \
    udev \
    kmod \
    weston \
    weston-init \
    weston-examples \
    wayland \
    wayland-protocols \
    mesa \
    mesa-megadriver \
    libgles2-mesa \
    libegl-mesa \
    libsdl2 \
    sdl2-demo \
    evtest \
    libinput \
    openssh \
    openssh-sshd \
    openssh-sftp-server \
    domu-network \
    ${CORE_IMAGE_EXTRA_INSTALL} \
"

inherit core-image

BAD_RECOMMENDATIONS += "busybox-syslog"

IMAGE_ROOTFS_SIZE ?= "524288"
IMAGE_ROOTFS_EXTRA_SPACE = "262144"

# Wayland + Mesa + SDL2 stack pushes initramfs above the 128 MiB default.
# Cap at 1 GiB to fit the Wayland graphics stack.
INITRAMFS_MAXSIZE = "1048576"
