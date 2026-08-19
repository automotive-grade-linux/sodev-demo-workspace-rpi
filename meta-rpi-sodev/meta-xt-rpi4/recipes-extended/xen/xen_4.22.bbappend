# ============================================================================
# The rpi4 hypervisor series is the 29 patches listed in SRC_URI below.
# It does NOT include 4.22-0002-route-msi-ranges (see the REMOVED note further
# down); the 29 are the ones actually fetched. The rpi5 bbappend fetches 30 --
# the same set plus that one.
# ============================================================================
# This bbappend attaches to the STOCK meta-virtualization recipe
# xen_4.22.bb (PV "4.22.0+stable", SRCREV d45d5687f1, branch stable-4.22) instead
# of the xen-troops fork _git recipe. It is selected by
#   PREFERRED_VERSION_xen = "4.22.0+stable"
# (set in the DomD build's local.conf / rpi4-sodev.yaml linux_domain_conf).
#
# The whole RPi5 delta that the fork branch (xen-4.21-xt-gen5) used to carry is
# reconstructed here as an ordered file:// patch series applied on top of the
# pristine xenbits stable-4.22 tree:
#
#   0002-0024  the 23 xen-troops fork commits that sat on top of stable-4.21
#              (virtio-pci / vgsx / DTB-passthrough / cacheable-iomem / Flask /
#               legacy-PCI level IRQ emulation), extracted with git format-patch.
#   4.22-0001  working-delta-rebased  (BCM2712 dom0-MMIO / vGIC SPI relax /
#              nr_spis floor / iomem-irq grant / SCI via
#              firmware/sci.c / domctl renumber) = former 0007-0021, squashed.
#              (No pl011 change: the former BCM2712 console RX poll timer was
#              removed once overlays/bcm2712d0.dtbo on p1 corrected uart10 to
#              INTID 152 so the stock pl011 RX IRQ fires; 2-arg IRQ handler is
#              stock upstream.)
#   4.22-0002  route-msi-ranges       (RP1 MSI-X route via the
#              arch_handle_passthrough_prop() hook, xen-troops fork commit d16f10d5a4 (not in xenbits)).
#   4.22-0003  revert-bufioreq-arm-restriction (re-revert upstream 2fbd7e609e so
#              create_ioreq_server() accepts HVM_IOREQSRV_BUFIOREQ_ATOMIC from
#              the DomD qemu device-model; without it DomU/DomA go black).
#   4.22-0004  vgic-pci-irq-level-race-fix (fix the pci_irq_level race in the
#              legacy-PCI level IRQ emulation on the vGIC).
#   4.22-0005  build-honour-external-toolchain-vars. NOT board-specific: it makes
#              config/StdGNU.mk use `?=` for CC/CXX/CPP/LD so an OE-supplied
#              compiler command line survives, and quotes the multi-word CC that
#              tools/firmware/Makefile passes to the seabios/ovmf sub-makes.
#              Without it a cross build fails with
#                No rule to make target '-mcpu=cortex-a76'
#              — and the equivalent on this board would name -mcpu=cortex-a72.
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
# NOTE on ThumbEE: [4.22] no longer relevant. In 4.21 the stock xen_4.21.bb SRC_URI carried
# 0001-ARM-Drop-ThumbEE-support.patch (Andrew Cooper 5bbe1fe413, binutils/gcc15
# fix), so it was NOT re-added here. That commit is IN 4.22, so the interim
# xen_4.22.bb drops the pre-patch entirely. Nothing to add or exclude here.
# still applies clean (git apply --check and patch -p1 --fuzz=2, no reject/fuzz).
#
# The fork _git bbappends (meta-rpi5-xen / meta-rpi5-domd / xt-prod-devel-...
# xen_git.bbappend, which retarget XEN_URL/XEN_REV) attach only to xen_git.bb,
# so once PREFERRED_VERSION_xen selects 4.22.0+stable they become inert.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# 0002-0024 + 4.22-000{1,3,4,5} are the same files the xen-tools toolstack bbappend
# and live in a shared dir (meta-xt-common/recipes-extended/xen-common/files) that
# both this hypervisor bbappend and the xen-tools bbappend point at. Only the
# hypervisor-only 0025 and the Kconfig .cfg fragments remain in ./files here.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../meta-xt-common/recipes-extended/xen-common/files:"

# --- Xen patch series ---
# REMOVED(rpi4): file://4.22-0002-route-msi-ranges.patch — it routed the BCM2712 MIP MSI
#   (GIC SPI 128-191) so RP1-over-PCIe MSI-X works. RPi4 has NO RP1/MIP; the only PCIe MSI
#   consumer is the VL805 USB3 controller behind the BCM2711 PCIe RC. If VL805 passthrough
#   needs guest MSI, re-derive an equivalent for brcm,bcm2711-pcie (NOT the MIP).
#   The remaining series (0002-0025, 4.22-0001/0003/0004/0005) is SoC-agnostic and carries over.
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
    file://4.22-0003-revert-bufioreq-arm-restriction.patch \
    file://0025-dom0less-arm-xenstore-page-from-domain-static-mem.patch \
    file://4.22-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.22-0005-build-honour-external-toolchain-vars.patch \
    file://4.22-0006-dom0less-seed-next-phandle-below-reserved-range.patch \
"

# --- hypervisor Kconfig fragments ---
# xen-hyp-config.cfg: EXPERT/UNSUPPORTED/STATIC_MEMORY (+XSM). CONFIG_TEE and
#   CONFIG_OPTEE are dropped for rpi4 — OP-TEE is disabled on this board and the
#   DomD node carries no xen,tee (see recipes-bsp/trusted-firmware-a/trusted-firmware-a_git.bb).
#   Without the rest Xen panics on the first hardware boot with "direct-map is
#   not valid for domain domD without static allocation", because the DomD node
#   in bcm2711-raspberrypi4-64-xen.dtso uses direct-map + xen,static-mem and both
#   are EXPERT/UNSUPPORTED-gated in stable-4.22.
# xen-config-ioreq.cfg: CONFIG_IOREQ_SERVER (qemu virtio backend). NOTE: it is
#   EXPERT-gated too, so it only takes effect together with xen-hyp-config.cfg —
#   listed after it so the merged fragment order matches the dependency.
# xen-config-rpi4-passthrough.cfg: the BCM2711 passthrough quirks (hwdom passthrough
#   caps + guest passthrough IRQ type default + guest nr_spis floor). Like
#   xen-config-ioreq.cfg these are UNSUPPORTED-gated, so the file MUST come after
#   xen-hyp-config.cfg in SRC_URI or olddefconfig drops the lines. Added on the v93
#   rebase: v93 split these out of 4.22-0001-working-delta into a board fragment,
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

# --- patch-fuzz QA: left at ERROR (the OE default) ---------------------------
# [4.22] The 4.21 revision of this bbappend demoted patch-fuzz to a warning here
# (WARN_QA:append / ERROR_QA:remove) with its own CAVEAT noting that a permanent
# demotion lets a silently mis-applied patch pass do_patch with only a warning.
# Both lines are REMOVED for 4.22: the series applies to stable-4.22 with zero
# fuzz and zero offset warnings (0008/0018 regenerated, 0022/4.22-0001 rebased),
# so there is nothing left to tolerate and a mis-apply should fail the build. If a
# stable-4.22.x bump shifts context, refresh the affected patch -- do not re-add
# the demotion. Kept in sync with the rpi5 bbappend.
# Upstream-Status is present on every patch, so the separate patch-status QA is
# satisfied and is not touched here.

# =============================================================================
# BCM2711 notes on the carried-over 4.22-0001-working-delta-rebased.patch
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
#     IRQ_TYPE_INVALID: harmless here, and the fallback value is the correct one.
#     Every BCM2711 peripheral SPI is active-high level, the display/HDMI L2
#     controller (/soc/interrupt-controller@7ef00100, GIC SPI 96) included.
#     [CORRECTED 2026-09-02] This comment used to claim SPI 96 was EDGE_RISING and
#     "the only edge-triggered line in this design". That came from the
#     bcm2711-rpi-4-b.dtb that raspberrypi/firmware distributes, which still
#     carries the pre-rpi-6.1.y value and is stale; mainline and the pinned
#     rpi-6.18.y both say IRQ_TYPE_LEVEL_HIGH. Following the stale value in the
#     DomD partial DT panicked DomD on hardware -- see docs/TROUBLESHOOTING.md,
#     "DomD panics in brcmstb_l2_intc during boot", and section 4 of
#     meta-xt-rpi4/BCM2711-DT-TRUTH.md.
#     Note the two device trees are separate inputs: Xen programs the PHYSICAL
#     GIC from the host DT (handle_passthrough_prop -> map_device_irqs_to_domain
#     on the node resolved through xen,path), while DomD's own kernel programs its
#     view from the guest partial DT. The p1 dtb shipped here is still the stale
#     firmware prebuilt, so those two currently disagree for SPI 96 -- tracked as
#     an open item; the partial DT is the one that governs what DomD's probe sees,
#     which is why fixing it was what stopped the panic.
#     The override still only triggers on the libxl path (domd.cfg `irqs=[...]`),
#     which carries no type information at all.
#     (GIC SPI n maps to Xen/libxl irq n+32: msi SPI 148 -> 180, pcie SPI 147 ->
#     179, INTA-D SPI 143..146 -> 175..178, HDMI L2 SPI 96 -> 128.)
#
#  4. domain_vgic_init() flooring a guest's nr_spis to 288: harmless. The highest
#     SPI this design routes is 158 (GENET irq1), or 176 if the VL805 xHCI
#     platform node is ever used, both well inside 288, and Xen's own ceiling is
#     988 rather than the host GIC's line count.
