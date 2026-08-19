# ============================================================================
# Xen 4.22 + 30-patch series (hypervisor)
# ============================================================================
# This bbappend attaches to xen_4.22.bb (PV "4.22.0+stable", SRCREV d45d5687f1,
# branch stable-4.22). It is selected by
#   PREFERRED_VERSION_xen = "4.22.0+stable"
# (set in the DomD build's local.conf / rpi5-sodev.yaml linux_domain_conf).
#
# [4.22] The recipe it attaches to is NO LONGER the stock meta-virtualization
# one. meta-virtualization master (526c9725) stops at xen_4.21.bb, so this layer
# carries an interim local xen_4.22.bb alongside this file, to be submitted
# upstream and deleted once accepted. See that recipe's header. Everything else
# about the arrangement is unchanged from 4.21: a pristine xenbits stable-4.22
# tree plus an ordered file:// patch series.
#
#   0002-0024  the 23 xen-troops fork commits that sat on top of stable-4.21
#              (virtio-pci / vgsx / DTB-passthrough / cacheable-iomem / Flask /
#               legacy-PCI level IRQ emulation), extracted with git format-patch.
#              25 of the 29 apply clean to stable-4.22 untouched; 0008 and 0018
#              were regenerated against 4.22 (context drift only) and 0022 was
#              rebased -- see the per-patch Local-Modifications: headers.
#   4.22-0001  working-delta-rebased  (BCM2712 dom0-MMIO / vGIC SPI relax /
#              nr_spis floor / iomem-irq grant / SCI via firmware/sci.c /
#              domctl renumber) = former 0007-0021, squashed.
#              Rebased for 4.22: upstream e263eeaf71 / 329edc090d converted
#              arch_do_domctl()'s XEN_DOMCTL_bind_pt_irq from early-returns to
#              an `rc = ...` if/else chain under read_lock(&currd->caps_lock),
#              so our two diagnostic printks moved into that shape. No change
#              in behaviour.
#              (No pl011 change: the former BCM2712 console RX poll timer was
#              removed once overlays/bcm2712d0.dtbo on p1 corrected uart10 to
#              INTID 152 so the stock pl011 RX IRQ fires; 2-arg IRQ handler is
#              stock.)
#   4.22-0002  route-msi-ranges       (RP1 MSI-X route via the
#              arch_handle_passthrough_prop() hook, xen-troops fork commit d16f10d5a4 (not in xenbits)).
#   4.22-0003  revert-bufioreq-arm-restriction (re-revert upstream 2fbd7e609e so
#              create_ioreq_server() accepts HVM_IOREQSRV_BUFIOREQ_ATOMIC from
#              the DomD qemu device-model; without it DomU/DomA go black).
#   4.22-0004  vgic-pci-irq-level-race-fix (fix the pci_irq_level race in the
#              legacy-PCI level IRQ emulation on the vGIC).
#   4.22-0005  build-honour-external-toolchain-vars.
#
#   4.22-0006  dom0less-seed-next-phandle-below-reserved-range. NOT board-specific
#              and an upstream regression fix: 4.22's a010efd323 seeds
#              kinfo->next_phandle with fdt_generate_phandle() and then refuses
#              the domain when that lands in the Xen-reserved phandle range. The
#              dummy /gic placeholder in every partial DT carries
#              GUEST_PHANDLE_GIC (65000) -- libxl gives its generated GIC node
#              that value, and dom0less used the same constant unconditionally
#              up to 4.21 -- so the seed is always 65001 and DomD creation dies
#              with "Device tree generation failed (-75)" followed by
#              "Panic on CPU 0: Could not set up domain domD (rc = -22)".
#              Measured on hardware 2026-08-18: without it NO configuration of
#              this workspace boots on either board.
# NOTE on ThumbEE: [4.22] no longer relevant. In 4.21 the stock xen_4.21.bb
# SRC_URI carried 0001-ARM-Drop-ThumbEE-support.patch (Andrew Cooper 5bbe1fe413,
# binutils/gcc15 fix) and this bbappend documented that it was therefore not
# re-added here. That commit is IN 4.22, so the local xen_4.22.bb drops the
# pre-patch entirely. Nothing to add or exclude here.
#
# The fork _git bbappends (this layer, meta-xt-driver-domain, xt-prod-devel-...
# xen_git.bbappend, which retarget XEN_URL/XEN_REV) attach only to xen_git.bb,
# so once PREFERRED_VERSION_xen selects 4.22.0+stable they become inert.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# The 28 patches shared with the toolstack (0002-0024 + 4.22-000{1..5}) live in a
# shared dir (meta-xt-common/recipes-extended/xen-common/files) that both this
# hypervisor bbappend and the xen-tools bbappend point at, so there is a single
# copy of each -- both SRC_URI lists name those same 28 files. This bbappend adds
# the two hypervisor-only ones from the same shared dir (0025 and 4.22-0006, both
# xen/ only, no tools/ hunk), which is why it fetches 30 where the toolstack
# fetches 28 of the shared set. Only the Kconfig .cfg fragments live in ./files
# here (alongside the interim recipe's own stock pre-patches).
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../meta-xt-common/recipes-extended/xen-common/files:"

# --- 30-patch series (order matters; matches the verified git-apply order) ---
SRC_URI:append = " \
    file://0002-xen-arm-ignore-spurious-interrupts-from-virtual-time.patch \
    file://0003-Adjust-guest-memory-map.patch \
    file://0004-xsm-Configure-Flask-policy-for-DomD.patch \
    file://0005-flask-Use-use_device_iommu_nointremap-primitives-for.patch \
    file://0006-libxl-Add-DTB-passthrough-nodes-list.patch \
    file://0007-libxl-add-vgsx-device.patch \
    file://0008-xl-add-vgsx-config-parser.patch \
    file://0009-docs-add-vgsx-xl.cfg-entry.patch \
    file://0010-libxl-Pass-max_vcpus-to-Qemu-in-case-of-PVH-domain-A.patch \
    file://0011-libxl-arm-Add-basic-virtio-pci-support.patch \
    file://0012-libxl-arm-Reuse-generic-PCI-IOMMU-bindings-for-virti.patch \
    file://0013-xen-arm-Emulate-level-for-legacy-PCI-interrupts-with.patch \
    file://0014-libxl-Add-backend_type-property-for-the-Virtio-devic.patch \
    file://0015-libxl-Update-xl-devd-to-also-spawn-Qemu-for-Virtio-d.patch \
    file://0016-libxl-Wait-for-Qemu-spawned-by-xl-devd-to-be-ready-b.patch \
    file://0017-libxl-arm-adjust-vpci-IRQ-map-according-to-vgic-conf.patch \
    file://0018-libxl-arm-Rework-virtio-pci-support-for-dynamic-PCI-.patch \
    file://0019-xen-arm-Update-emulation-of-level-for-legacy-PCI-int.patch \
    file://0020-libxl-Allow-virtio-pci-backends-from-different-domai.patch \
    file://0021-Revert-xen-arm-don-t-iomem_permit_access-for-reserve.patch \
    file://0022-xen-extend-XEN_DOMCTL_memory_mapping-to-handle-cache.patch \
    file://0023-libxc-introduce-xc_domain_memory_mapping_cache-to-ha.patch \
    file://0024-libxl-xl-add-cacheability-option-to-iomem.patch \
    file://4.22-0001-working-delta-rebased.patch \
    file://4.22-0002-route-msi-ranges.patch \
    file://4.22-0003-revert-bufioreq-arm-restriction.patch \
    file://0025-dom0less-arm-xenstore-page-from-domain-static-mem.patch \
    file://4.22-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.22-0005-build-honour-external-toolchain-vars.patch \
    file://4.22-0006-dom0less-seed-next-phandle-below-reserved-range.patch \
"

# --- hypervisor Kconfig fragments ---
# xen-hyp-config.cfg: EXPERT/UNSUPPORTED/STATIC_MEMORY/TEE/OPTEE (+XSM), matching
#   the hardware-proven fork .config. Found on first hardware boot :
#   without it Xen panics "direct-map is not valid for domain domD without
#   static allocation" (the xen.dtso DomD node uses direct-map + xen,static-mem,
#   both EXPERT/UNSUPPORTED-gated in stable-4.22 as they were in stable-4.21).
# xen-config-ioreq.cfg: CONFIG_IOREQ_SERVER (qemu virtio backend). NOTE: it is
#   EXPERT-gated too, so it only takes effect together with xen-hyp-config.cfg —
#   listed after it so the merged fragment order matches the dependency.
# xen-config-rpi5-passthrough.cfg: turns on the BCM2712 passthrough quirks that
#   4.22-0001 adds to xen/arch/arm/Kconfig. They all default to n / 0 there, so
#   this fragment is the only thing that enables them. UNSUPPORTED-gated, hence
#   also listed after xen-hyp-config.cfg.
SRC_URI:append = " file://xen-hyp-config.cfg file://xen-config-ioreq.cfg file://xen-config-rpi5-passthrough.cfg"

# --- hypervisor Kconfig fragment: SCMI/SCI (conditional on the scmi MACHINE_FEATURE,
#     mirrors the fork's xt-prod-devel-rpi5-domd xen_git.bbappend anonymous-python) ---
python __anonymous() {
    if bb.utils.contains('MACHINE_FEATURES', 'scmi', True, False, d):
        d.appendVar('SRC_URI', ' file://xen-scmi.cfg')
}

# --- patch-fuzz QA: left at ERROR (the OE default) ---------------------------
# [4.22] The 4.21 bbappend demoted patch-fuzz to a warning here:
#   WARN_QA:append = " patch-fuzz"
#   ERROR_QA:remove = "patch-fuzz"
# with its own CAVEAT noting that a permanent demotion lets a silently
# mis-applied patch (fuzz, or a hunk landing at the wrong offset after a context
# shift) pass do_patch with only a warning. Both lines are REMOVED for 4.22:
# every patch in the series applies to stable-4.22 with zero fuzz and zero offset
# warnings (0008/0018 regenerated, 0022/4.22-0001 rebased), so there is nothing
# left to tolerate, and a mis-apply on a future point update should fail the
# build rather than warn. If a stable-4.22.x bump shifts context, refresh the
# affected patch -- do not re-add the demotion.
# Upstream-Status is present on every patch, so the separate patch-status QA is
# satisfied and is not touched here.
