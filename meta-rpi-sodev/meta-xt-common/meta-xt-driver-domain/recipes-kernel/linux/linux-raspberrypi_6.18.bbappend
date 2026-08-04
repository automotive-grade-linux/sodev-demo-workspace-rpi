# Overlay delta on the PRISTINE xen-troops xt-prod-devel-rpi5-domd
# recipes-kernel/linux/linux-raspberrypi_6.12.bbappend. Second .bbappend (stacks
# on the base, which already appends optee.cfg), adding the Dom0 pinctrl/vc4
# workaround patches. Files live in this layer's files/; the xen-troops submodule
# stays pristine.
#
# 0009 (pinctrl writel skip) avoids a BCM2712 pinctrl Async SError under Xen
# Dom0; 0010 allocates dev->dma_mask before vc4_drm_bind calls dma_set_mask
# (otherwise the axi:gpu container node's dma_mask is NULL and bind fails -EIO).
# NOTE: xen-config-a4b-frontend.cfg (CONFIG_DRM_VC4=m, CONFIG_XEN_BLKDEV_FRONTEND=y,
# CONFIG_XEN_NETDEV_FRONTEND=y) was a byte-identical duplicate of the meta-xt-rpi5
# copy; both layers are always co-present in the dom0/domd kernel builds, so it is
# now supplied solely by meta-xt-rpi5's linux-raspberrypi_6.18.bbappend.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# RPi5-specific kernel fixes for this Xen topology. 0011 (DT-based vc4 component
# match list) is authored here, not derived from the V4H patchset: V4H has no
# drm/vc4 at all, so it lives beside the other RPi5 vc4/v3d fixes.
SRC_URI:append = " \
    file://0009-pinctrl-bcm2712-skip-mmio-writes-under-xen-dom0-xen-troops.patch \
    file://0010-drm-vc4-allocate-dma-mask-before-set-mask-xen-troops.patch \
    file://0011-drm-vc4-DT-based-component-match-list.patch \
    file://0012-drm-v3d-pin-runtime-active-under-xen-domd-xen-troops.patch \
"

# rpi5-0004: V4H Xen patchset for the Dom0/DomD kernel. The base meta-xt-rpi5
# linux-raspberrypi_6.12.bbappend (pristine) does NOT carry these; they were
# being applied by editing the base bbappend directly. Moved here so meta-xt-rpi5
# stays pristine. 0001-0003 + 0009 are the unpopulated-alloc / grant-table /
# balloon contiguous-page helpers (Xen frontend DMA). Patch files live in this layer's
# files/v4h-xen-patches/ (FILESEXTRAPATHS:prepend above already covers them).
SRC_URI:append = " \
    file://v4h-xen-patches/0001-xen-unpopulated-alloc-Introduce-helpers-for-contiguo.patch \
    file://v4h-xen-patches/0002-xen-grant-table-Use-unpopulated-contiguous-pages-ins.patch \
"
# Upstream's 0003 (relaxing the unpopulated-alloc DMA_BIT_MASK restriction) is
# intentionally not applied: the RPi5 V3D is 64-bit-capable and there is no
# out-of-tree PVRKM driver here that would need the relaxation.
SRC_URI:append = " \
    file://v4h-xen-patches/0009-Use-mhp_get_pluggable_range-in-balloon-as-well.patch \
"

# =============================================================================
# re-host: meta-xt-prod-devel-rpi5 (pristine) linux-raspberrypi_6.12.bbappend body.
# Bring optee.cfg + dt_config.inc (resolved via BBPATH) + the
# SCMI/WiFi DT overlays forward to 6.18. dt_config.inc defines the SCMI/WiFi DT
# names this bbappend's SRC_URI expands; it is provided here in
# meta-xt-driver-domain/include/ (this layer is in BOTH the DomD and the thin
# Linux Dom0 bblayers) so the require resolves in both — the thin Dom0 build
# intentionally omits xt-prod-devel-rpi5-domd, which used to be the sole provider.
require include/dt_config.inc
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://optee.cfg \
"

RPI_KERNEL_DEVICETREE:append = " \
    broadcom/${SCMI_XEN_DT_NAME}.dtbo \
    broadcom/${SCMI_DOMD_DT_NAME}.dtbo \
    broadcom/${SCMI_DOMD_PCIE1_DT_NAME}.dtbo \
    broadcom/${DOMD_WIFI_DT_NAME}.dtbo \
    broadcom/${XEN_WIFI_PASSTHROUGH_DT_NAME}.dtbo \
"

SRC_URI:append = " \
    file://${SCMI_XEN_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${SCMI_DOMD_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${SCMI_DOMD_PCIE1_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${DOMD_WIFI_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${XEN_WIFI_PASSTHROUGH_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
"
