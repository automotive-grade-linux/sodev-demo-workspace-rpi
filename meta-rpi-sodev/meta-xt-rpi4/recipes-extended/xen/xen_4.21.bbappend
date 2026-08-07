# ============================================================================
# The rpi4 hypervisor series is the 29 patches listed in SRC_URI below.
# It does NOT include 4.21-0002-route-msi-ranges (see the REMOVED note further
# down); the 29 are the ones actually fetched.
# ============================================================================
# This bbappend attaches to the STOCK meta-virtualization recipe
# xen_4.21.bb (PV "4.21.0+stable", SRCREV 1c72306b, branch stable-4.21) instead
# of the xen-troops fork _git recipe. It is selected by
#   PREFERRED_VERSION_xen = "4.21.0+stable"
# (set in the DomD build's local.conf / rpi4-sodev.yaml linux_domain_conf).
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
#   4.21-0005  build-honour-external-toolchain-vars. NOT board-specific: it makes
#              config/StdGNU.mk use `?=` for CC/CXX/CPP/LD so an OE-supplied
#              compiler command line survives, and quotes the multi-word CC that
#              tools/firmware/Makefile passes to the seabios/ovmf sub-makes.
#              Without it a cross build fails with
#                No rule to make target '-mcpu=cortex-a76'
#              — and the equivalent on this board would name -mcpu=cortex-a72.
#
# NOTE on ThumbEE: the stock xen_4.21.bb SRC_URI already carries
# 0001-ARM-Drop-ThumbEE-support.patch (Andrew Cooper 5bbe1fe413, binutils/gcc15
# fix), so it is NOT re-added here. Verified: on the stable-4.21 tree with the
# stock ThumbEE patch applied first, the whole 0002-0024 + 4.21-0001..5 series
# still applies clean (git apply --check and patch -p1 --fuzz=2, no reject/fuzz).
#
# The fork _git bbappends (meta-rpi5-xen / meta-rpi5-domd / xt-prod-devel-...
# xen_git.bbappend, which retarget XEN_URL/XEN_REV) attach only to xen_git.bb,
# so once PREFERRED_VERSION_xen selects 4.21.0+stable they become inert.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# 0002-0024 + 4.21-000{1,2,3,4,5} are byte-identical to the xen-tools toolstack copies
# and live in a shared dir (meta-xt-common/recipes-extended/xen-common/files) that
# both this hypervisor bbappend and the xen-tools bbappend point at. Only the
# hypervisor-only 0025 and the Kconfig .cfg fragments remain in ./files here.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../meta-xt-common/recipes-extended/xen-common/files:"

# --- Xen patch series ---
# REMOVED(rpi4): file://4.21-0002-route-msi-ranges.patch — it routed the BCM2712 MIP MSI
#   (GIC SPI 128-191) so RP1-over-PCIe MSI-X works. RPi4 has NO RP1/MIP; the only PCIe MSI
#   consumer is the VL805 USB3 controller behind the BCM2711 PCIe RC. If VL805 passthrough
#   needs guest MSI, re-derive an equivalent for brcm,bcm2711-pcie (NOT the MIP).
#   The remaining series (0002-0025, 4.21-0001/0003/0004/0005) is SoC-agnostic and carries over.
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
    file://4.21-0003-revert-bufioreq-arm-restriction.patch \
    file://0025-dom0less-arm-xenstore-page-from-domain-static-mem.patch \
    file://4.21-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.21-0005-build-honour-external-toolchain-vars.patch \
"

# --- hypervisor Kconfig fragments ---
# xen-hyp-config.cfg: EXPERT/UNSUPPORTED/STATIC_MEMORY (+XSM). CONFIG_TEE and
#   CONFIG_OPTEE are dropped for rpi4 — OP-TEE is disabled on this board and the
#   DomD node carries no xen,tee (see recipes-bsp/trusted-firmware-a/trusted-firmware-a_git.bb).
#   Without the rest Xen panics on the first hardware boot with "direct-map is
#   not valid for domain domD without static allocation", because the DomD node
#   in bcm2711-raspberrypi4-64-xen.dtso uses direct-map + xen,static-mem and both
#   are EXPERT/UNSUPPORTED-gated in stable-4.21.
# xen-config-ioreq.cfg: CONFIG_IOREQ_SERVER (qemu virtio backend). NOTE: it is
#   EXPERT-gated too, so it only takes effect together with xen-hyp-config.cfg —
#   listed after it so the merged fragment order matches the dependency.
# xen-config-rpi4-passthrough.cfg: the BCM2711 passthrough quirks (hwdom passthrough
#   caps + guest passthrough IRQ type default + guest nr_spis floor). Like
#   xen-config-ioreq.cfg these are UNSUPPORTED-gated, so the file MUST come after
#   xen-hyp-config.cfg in SRC_URI or olddefconfig drops the lines. Added on the v93
#   rebase: v93 split these out of 4.21-0001-working-delta into a board fragment,
#   and the RPi4 port had no counterpart -- see the header of that file for why the
#   gap was invisible until G4 (dom0less DomD is wired up by Xen itself; these
#   symbols govern the `xl create` path that DomA uses).
SRC_URI:append = " file://xen-hyp-config.cfg file://xen-config-ioreq.cfg file://xen-config-rpi4-passthrough.cfg"

# --- hypervisor Kconfig fragment: SCMI/SCI (conditional on the scmi MACHINE_FEATURE,
#     mirrors the fork's xt-prod-devel-rpi5-domd xen_git.bbappend anonymous-python) ---
# REMOVED(rpi4): the scmi MACHINE_FEATURE hook that appended xen-scmi.cfg.
# BCM2711 has no SCMI at all — clocks and power come from the VideoCore firmware
# mailbox (raspberrypi,firmware) — so CONFIG_SCMI_SMC has nothing to talk to and
# xen-scmi.cfg was deleted along with the rest of the SCMI plumbing (TF-A's
# SCMI_SERVER_SUPPORT, the *-scmi.dtso overlays and the SCMI dtbo deploy list).

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

# =============================================================================
# BCM2711 notes on the carried-over 4.21-0001-working-delta-rebased.patch
# =============================================================================
# That patch is shared with the RPi5 layer (meta-xt-common/recipes-extended/
# xen-common/files) and is kept byte-identical. Three of its hunks were written
# against BCM2712; this is how each behaves on BCM2711:
#
#  1. iomem capability grant end constant (0x1_00000000-ish -> 40-bit range):
#     a superset here. BCM2711 peripherals are all below 4 GiB, so nothing is
#     missed and nothing extra is reachable that xen,reg does not already gate.
#
#  2. p2m_mmio_direct_c -> p2m_mmio_direct_dev for hardware-domain device MMIO:
#     motivated by IMP-DEF Async SErrors on BCM2712 register-style peripherals.
#     Device-nGnRE is the correct attribute for BCM2711 MMIO regardless, so the
#     change is right here too — it just is not fixing a bug on this SoC.
#
#  3. route_irq_to_guest() forcing IRQ_TYPE_LEVEL_HIGH when desc->arch.type is
#     IRQ_TYPE_INVALID: *** the one to watch on RPi4. *** BCM2711's display/HDMI
#     L2 interrupt controller (/soc/interrupt-controller@7ef00100, GIC SPI 96) is
#     EDGE_RISING, not LEVEL_HIGH — the only edge-triggered line in this design.
#     It is safe as shipped, because the dom0less path reaches that IRQ through
#     handle_passthrough_prop -> map_interrupts_to_domain -> platform_get_irq,
#     which calls irq_set_type() with the type read from the HOST device tree, so
#     desc->arch.type is already EDGE_RISING and the override never fires. The
#     override only triggers on the libxl path (domd.cfg `irqs=[...]`), which
#     carries no type information. So: if DomD is ever switched from dom0less to
#     `xl create`, do NOT put SPI 96 (Xen irq 128) in irqs=[] without first
#     making that fallback read the type from the DT — a level-configured GIC line
#     on an edge source either misses interrupts or storms.
#     (GIC SPI n maps to Xen/libxl irq n+32: msi SPI 148 -> 180, pcie SPI 147 ->
#     179, INTA-D SPI 143..146 -> 175..178, HDMI L2 SPI 96 -> 128.)
#
#  4. domain_vgic_init() flooring a guest's nr_spis to 288: harmless. The highest
#     SPI this design routes is 158 (GENET irq1), or 176 if the VL805 xHCI
#     platform node is ever used, both well inside 288, and Xen's own ceiling is
#     988 rather than the host GIC's line count.
