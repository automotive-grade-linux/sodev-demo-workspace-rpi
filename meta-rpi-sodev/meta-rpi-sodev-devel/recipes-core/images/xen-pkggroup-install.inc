# SPDX-License-Identifier: Apache-2.0
# DomD debug-image package set: the Xen toolstack + flat-bridge network helpers.
#
# Gated on the DomD MACHINE (raspberrypi5). This .inc is required from
# core-image-minimal.bbappend / core-image-weston.bbappend, which land on the
# GENERIC core-image-* recipes. bitbake applies a .bbappend to its target recipe
# regardless of the layer subdir it lives in, so without a gate the DomU build
# (MACHINE=virtio-armv8-xt, images-domu/) would also pull in this Xen/dnsmasq
# stack (cross-contamination). The MACHINE override makes it inert unless the DomD
# machine is active; the DomU-side install (images-domu/, gated on
# virtio-armv8-xt) is inert here, and vice versa.
#
# NOTE: the Xen block-device scripts are provided by xen-tools-scripts-block
# (present below). A bare "block" PN does not exist anywhere in the tree, so it
# was removed to avoid a do_rootfs failure on opt-in builds.
IMAGE_INSTALL:append:raspberrypi5 = " \
    xen \
    xen-tools-devd \
    xen-tools-scripts-network \
    xen-tools-scripts-block \
    xen-tools-xenstore \
    xen-network \
    xen-network-flatbridge \
    dnsmasq \
    socat \
"
