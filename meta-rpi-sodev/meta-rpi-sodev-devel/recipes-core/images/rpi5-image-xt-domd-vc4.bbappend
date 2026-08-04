# SPDX-License-Identifier: Apache-2.0
# Opt-in debug/diagnostic additions for the DomD rootfs.
#
# This appends to rpi5-image-xt-domd-vc4, which is the recipe the shipping DomD
# image (rpi5-image-xt-domd-v4h) `require`s -- so these packages actually reach the
# image that gets built. An earlier version of this file appended to
# rpi5-image-xt-domd instead, which is a separate leaf recipe that the shipping
# chain never goes through, so nothing it added was ever installed.
#
# The layer as a whole is opt-in: it is not in rpi5-sodev.yaml's layer list, so
# adding it to bblayers.conf is what turns these on.
DEBUG_PACKAGES = " \
    openssh \
    openssh-sftp-server \
    iproute2 \
    iputils \
    ethtool \
    tcpdump \
    xt-cluster-shm \
    xt-vram-tools \
"

IMAGE_INSTALL:append = " ${DEBUG_PACKAGES}"
