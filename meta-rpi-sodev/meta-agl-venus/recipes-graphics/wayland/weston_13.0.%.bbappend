# libweston, which agl-compositor is built on: offer LINEAR in the scanout tranche of a
# KMS device without modifiers (DomU's virtio-gpu), so the cluster's window can go on the
# primary plane instead of being composed by the GPU every frame. See the patch.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-backend-drm-offer-LINEAR-on-a-KMS-device-without-modifiers.patch"
