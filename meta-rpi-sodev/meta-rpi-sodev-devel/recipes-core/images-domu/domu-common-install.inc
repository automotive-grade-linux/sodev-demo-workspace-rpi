# SPDX-License-Identifier: Apache-2.0
# DomU debug-image package set (static-IP + ssh network drop-in).
#
# Gated on the DomU MACHINE (virtio-armv8-xt). This .inc is required from the
# images-domu/ core-image-minimal.bbappend / core-image-weston.bbappend, which
# land on the GENERIC core-image-* recipes. bitbake applies a .bbappend to its
# target recipe regardless of the layer subdir it lives in, so without a gate the
# DomD build (MACHINE=raspberrypi5) would also pull in this DomU-only drop-in
# (cross-contamination). The MACHINE override makes it inert unless the DomU
# machine is active; the DomD-side install (images/, gated on raspberrypi5) is
# inert here, and vice versa.
IMAGE_INSTALL:append:virtio-armv8-xt = " domu-network"
