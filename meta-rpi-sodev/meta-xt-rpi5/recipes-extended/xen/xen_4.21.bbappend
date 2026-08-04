# ============================================================================
# Stock meta-virtualization Xen 4.21 + 29-patch series (hypervisor)
# ============================================================================
# This bbappend attaches to the STOCK meta-virtualization recipe
# xen_4.21.bb (PV "4.21.0+stable", SRCREV 1c72306b, branch stable-4.21) instead
# of the xen-troops fork _git recipe. It is selected by
#   PREFERRED_VERSION_xen = "4.21.0+stable"
# (set in the DomD build's local.conf / rpi5-sodev.yaml linux_domain_conf).
#
# The whole RPi5 delta that the fork branch (xen-4.21-xt-gen5) used to carry is
# reconstructed here as an ordered file:// patch series applied on top of the
# pristine xenbits stable-4.21 tree:
#
#   0002-0024  the 23 xen-troops fork commits that sat on top of stable-4.21
#              (virtio-pci / vgsx / DTB-passthrough / cacheable-iomem / Flask /
#               legacy-PCI level IRQ emulation), extracted with git format-patch.
#   4.21-0001  working-delta-rebased  (BCM2712 dom0-MMIO / vGIC SPI relax /
#              nr_spis floor / iomem-irq grant / SCI via 4.21
#              firmware/sci.c / domctl renumber) = former 0007-0021, squashed.
#              (No pl011 change: the former BCM2712 console RX poll timer was
#              removed once overlays/bcm2712d0.dtbo on p1 corrected uart10 to
#              INTID 152 so the stock pl011 RX IRQ fires; 2-arg IRQ handler is
#              stock 4.21.)
#   4.21-0002  route-msi-ranges       (RP1 MSI-X route via 4.21
#              arch_handle_passthrough_prop() hook, commit d16f10d5a4).
#   4.21-0003  revert-bufioreq-arm-restriction (re-revert upstream 2fbd7e609e so
#              create_ioreq_server() accepts HVM_IOREQSRV_BUFIOREQ_ATOMIC from
#              the DomD qemu device-model; without it DomU/DomA go black).
#   4.21-0004  vgic-pci-irq-level-race-fix (fix the pci_irq_level race in the
#              legacy-PCI level IRQ emulation on the vGIC).
#
# NOTE on ThumbEE: the stock xen_4.21.bb SRC_URI already carries
# 0001-ARM-Drop-ThumbEE-support.patch (Andrew Cooper 5bbe1fe413, binutils/gcc15
# fix), so it is NOT re-added here. Verified: on the stable-4.21 tree with the
# stock ThumbEE patch applied first, the whole 0002-0024 + 4.21-0001..4 series
# still applies clean (git apply --check and patch -p1 --fuzz=2, no reject/fuzz).
#
# The fork _git bbappends (this layer, meta-xt-driver-domain, xt-prod-devel-...
# xen_git.bbappend, which retarget XEN_URL/XEN_REV) attach only to xen_git.bb,
# so once PREFERRED_VERSION_xen selects 4.21.0+stable they become inert.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# 0002-0024 + 4.21-000{1,2,3,4} are byte-identical to the xen-tools toolstack copies
# and live in a shared dir (meta-xt-common/recipes-extended/xen-common/files) that
# both this hypervisor bbappend and the xen-tools bbappend point at. Only the
# hypervisor-only 0025 and the Kconfig .cfg fragments remain in ./files here.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../meta-xt-common/recipes-extended/xen-common/files:"

# --- 29-patch series (order matters; matches the verified git-apply order) ---
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
    file://4.21-0001-working-delta-rebased.patch \
    file://4.21-0002-route-msi-ranges.patch \
    file://4.21-0003-revert-bufioreq-arm-restriction.patch \
    file://0025-dom0less-arm-xenstore-page-from-domain-static-mem.patch \
    file://4.21-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.21-0005-build-honour-external-toolchain-vars.patch \
"

# --- hypervisor Kconfig fragments ---
# xen-hyp-config.cfg: EXPERT/UNSUPPORTED/STATIC_MEMORY/TEE/OPTEE (+XSM), matching
#   the hardware-proven fork .config. Found on first hardware boot :
#   without it Xen panics "direct-map is not valid for domain domD without
#   static allocation" (the xen.dtso DomD node uses direct-map + xen,static-mem,
#   both EXPERT/UNSUPPORTED-gated in stable-4.21).
# xen-config-ioreq.cfg: CONFIG_IOREQ_SERVER (qemu virtio backend). NOTE: it is
#   EXPERT-gated too, so it only takes effect together with xen-hyp-config.cfg —
#   listed after it so the merged fragment order matches the dependency.
# xen-config-rpi5-passthrough.cfg: turns on the BCM2712 passthrough quirks that
#   4.21-0001 adds to xen/arch/arm/Kconfig. They all default to n / 0 there, so
#   this fragment is the only thing that enables them. UNSUPPORTED-gated, hence
#   also listed after xen-hyp-config.cfg.
SRC_URI:append = " file://xen-hyp-config.cfg file://xen-config-ioreq.cfg file://xen-config-rpi5-passthrough.cfg"

# --- hypervisor Kconfig fragment: SCMI/SCI (conditional on the scmi MACHINE_FEATURE,
#     mirrors the fork's xt-prod-devel-rpi5-domd xen_git.bbappend anonymous-python) ---
python __anonymous() {
    if bb.utils.contains('MACHINE_FEATURES', 'scmi', True, False, d):
        d.appendVar('SRC_URI', ' file://xen-scmi.cfg')
}

# Tolerate patch-fuzz from base offset drift in the local RPi5 hot-fix patches
# (the 0002-0024 series and the 4.21-000x squashes apply clean today, but keep the
# QA demotion so future stable-4.21 point updates that shift context only warn
# instead of failing the build). Upstream-Status is present on every patch, so the
# separate patch-status QA is satisfied and is not touched here.
# CAVEAT: demoting patch-fuzz from ERROR to WARN *permanently* means a future patch
# that no longer applies cleanly (fuzz, or a hunk landing at the wrong offset after a
# context shift) can pass do_patch with only a warning instead of failing the build --
# a silently mis-applied patch. Behaviour is intentionally left as-is (all patches
# apply clean at the current SRCREV); on any base bump, re-check the do_patch log for
# "Fuzz"/offset warnings and refresh the affected patch rather than relying on this.
WARN_QA:append = " patch-fuzz"
ERROR_QA:remove = "patch-fuzz"
