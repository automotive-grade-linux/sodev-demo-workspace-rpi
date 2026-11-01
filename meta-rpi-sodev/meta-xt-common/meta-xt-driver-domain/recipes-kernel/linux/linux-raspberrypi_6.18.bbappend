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

# 0013 is NOT board-specific, which is why it has its own block: brcmstb-l2 backs
# BCM2711's aon_intr (the HDMI/display L2 controller, GIC SPI 96) and BCM2712's
# disp_intr (SPI 97) and aon_intr (SPI 239) alike, so both boards' DomD needs it.
#
# It fixes an UPSTREAM race: brcmstb_l2_intc_probe() calls
# irq_set_chained_handler_and_data() -- which unmasks the parent line and re-sends
# anything pending on it -- before assigning data->gc, and the handler dereferences
# data->gc in its first statement. A parent that is already pending therefore takes
# the machine down during an initcall. Measured on a Raspberry Pi 4, 2026-09-02,
# after an HDMI display swap: DomD panicked 0.53 s into boot with
#   "Unable to handle kernel NULL pointer dereference at virtual address 8"
#   "pc : brcmstb_l2_intc_irq_handle+0x40" / "Fatal exception in interrupt"
# BCM2711's aon_intr is the sole edge-triggered GIC line on that SoC, so its parent
# latches pending state from the firmware's pre-Linux HDMI activity. See
# docs/TROUBLESHOOTING.md, "DomD panics in brcmstb_l2_intc during boot".
#
# 🚨 DELETE THIS WHEN UPSTREAM CARRIES THE FIX. It is a local carry of a fix to
# upstream code, so once the pinned raspberrypi/linux gains an equivalent change
# this patch either stops applying or applies twice. Check on every SRCREV bump:
#
#     grep -n -B6 'Set the IRQ chaining logic' drivers/irqchip/irq-brcmstb-l2.c
#
# If irq_set_chained_handler_and_data() still comes BEFORE the
# "data->gc = irq_get_domain_generic_chip(...)" assignment, upstream is still broken
# and the patch is still needed. If it comes after it, remove the patch file and the
# SRC_URI line below. The patch is a pure move, so dropping it restores the pinned
# upstream file byte-for-byte.
SRC_URI:append = " \
    file://0013-irqchip-brcmstb-l2-set-up-the-generic-chip-before-ch.patch \
"

# [Venus] 0014 + venus-gntdev-dmabuf.cfg give the device model a way to learn the
# frame numbers of a dma-buf, which is the only thing standing between a guest and
# Vulkan through virtio-gpu/Venus: Mesa's venus backs its large mappable
# allocations with dma-bufs, a dma-buf mapping is VM_PFNMAP so /proc/self/pagemap
# reports nothing for it, and a window the device model cannot share into the
# guest's physmap is withdrawn by qemu's 0116 (left emulated, the guest's client
# would die at its first SIMD store to it on arm64), so the guest's vkMapMemory on
# it fails. gntdev-dmabuf already builds exactly that frame-number
# array on its import path; 0014 adds the ioctl that returns it.
#
# Numbered 0014, not 0013: 0013 is this bbappend's own brcmstb-l2 patch above.
#
# Gated on the venus DISTRO_FEATURE, so the --gpu=gl lane's kernel is untouched
# (same idiom as the rest of the Venus lane, see docs/VULKAN-VENUS.md).
SRC_URI:append = " ${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0014-xen-gntdev-return-a-dma-buf-s-frame-numbers-to-users.patch \
     file://venus-gntdev-dmabuf.cfg', '', d)}"

# 0015 is the DomD kernel half of DomA's hardware decode, and it pairs with qemu
# patch 0227-v10 (the device model asking for non-coherent host buffers). vb2
# dma-contig MMAP buffers are coherent (Normal-NC on arm64) by default, and a CPU
# reading a decoded frame out of one runs at bus speed: measured 678 MB/s against
# 3469 MB/s for cached memory on a Raspberry Pi 4, i.e. 1.4 ms instead of 0.3 ms
# for a 942 KB frame. The device model copies every frame, so it pays that per
# frame. Setting allow_cache_hints lets REQBUFS accept
# V4L2_MEMORY_FLAG_NON_COHERENT; nothing changes for callers that do not pass it.
#
# Not board-specific in this bbappend's sense even though only BCM2711 has the
# driver: bcm2835-codec is built for both boards' DomD and simply never binds on
# BCM2712, which has no vchiq node.
#
# Numbered 0015 because 0013 and 0014 are taken by this bbappend's own
# brcmstb-l2 and gntdev patches.
SRC_URI:append = " \
    file://0015-bcm2835-codec-allow-cache-hints-on-both-queues.patch \
"

# 0016 makes a DT dma-ranges peripheral alias effective for MMIO targets inside a
# direct-mapped Xen domain. Every device in such a domain gets
# xen_swiotlb_dma_ops, so dma_map_resource() lands in
# xen_swiotlb_direct_map_resource(), which without 0016 returns the CPU
# physical address untranslated, while raspberrypi/linux's
# dma_direct_map_phys() puts MMIO addresses through phys_to_dma()
# (372f4e66dad6; mainline does not).
#
# Measured on a Raspberry Pi 4 DomD: vc4-hdmi audio programmed DMA40 with
# DEST=0x00_fef2001c, the CPU address of the MAI FIFO, instead of the 0x4_7exx_xxxx
# alias scb's dma-ranges describes. The transfer then completed at memory speed
# (2 periods in ~1 ms), the FIFO stayed EMPTY, ALSA reported an XRUN every ~100 ms
# and nothing was audible -- all with error code 0. The same DTB on bare metal,
# with the direct ops, translates correctly.
SRC_URI:append = " \
    file://0016-xen-swiotlb-translate-MMIO-resource-through-dma-ranges.patch \
"

# 0017: a zero-timeout DRM_IOCTL_V3D_WAIT_BO (Mesa's BO cache asking whether a BO
# is idle) slept up to one jiffy, 4 ms at HZ=250, on a busy BO. QEMU draws DomA's
# decoded frames with Mesa v3d on its main loop, so those sleeps were BQL holds:
# up to 123 ms per iteration in a 1080p60 playback, 33 ms with 0017. Mainline
# made the same change in 2266665 on top of a helper 6.18 does not have; drop
# 0017 when the kernel moves past it.
SRC_URI:append = " \
    file://0017-drm-v3d-do-not-sleep-on-a-zero-timeout-wait-bo.patch \
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

# SCOPED TO raspberrypi5, and it has to be. All five names below are templated from
# ${RPI_SOC_FAMILY}-${MACHINE} (or, for SCMI_XEN_DT_NAME, from the yaml's
# XEN_DT_SCMI which is built the same way), and the files that satisfy them exist
# only as bcm2712-raspberrypi5-* in this layer's files/. Left unscoped, another
# board asks do_fetch for e.g. bcm2711-raspberrypi4-64-domd-scmi.dtso and the parse
# dies with "Unable to get checksum ... file could not be found".
#
# Neither list is order-sensitive — they are device trees copied into the kernel
# source tree and names added to the deploy list, not patches — so scoping them
# leaves the expanded values for raspberrypi5 unchanged.
#
# What a board without these needs to be true instead: no SCMI (BCM2711 has no
# SCMI firmware interface at all; clocks and power come from the VideoCore
# mailbox) and no Wi-Fi overlay (on Raspberry Pi 4 the SDIO Wi-Fi shares GIC SPI
# 126 with the SD controller, so it can only go to the domain that owns the SD
# card).
RPI_KERNEL_DEVICETREE:append:raspberrypi5 = " \
    broadcom/${SCMI_XEN_DT_NAME}.dtbo \
    broadcom/${SCMI_DOMD_DT_NAME}.dtbo \
    broadcom/${SCMI_DOMD_PCIE1_DT_NAME}.dtbo \
    broadcom/${DOMD_WIFI_DT_NAME}.dtbo \
    broadcom/${XEN_WIFI_PASSTHROUGH_DT_NAME}.dtbo \
"

SRC_URI:append:raspberrypi5 = " \
    file://${SCMI_XEN_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${SCMI_DOMD_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${SCMI_DOMD_PCIE1_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${DOMD_WIFI_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${XEN_WIFI_PASSTHROUGH_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
"
