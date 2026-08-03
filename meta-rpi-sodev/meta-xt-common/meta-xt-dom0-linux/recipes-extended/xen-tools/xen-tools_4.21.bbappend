# ============================================================================
# Stock meta-virtualization Xen 4.21 + 28-patch series (toolstack)
# ============================================================================
# Attaches to the STOCK meta-virtualization xen-tools_4.21.bb
# (PV "4.21+stable", SRCREV 1c72306b, branch stable-4.21) instead of the
# xen-troops fork _git recipe. Selected by
#   PREFERRED_VERSION_xen-tools = "4.21+stable"
# (set in the DomD build's local.conf / rpi5-sodev.yaml).
#
# xen-tools unpacks its own copy of the same xen.git tree and compiles the
# toolstack (libxc / libxl / xl). The same 28-patch series applied to the
# hypervisor is applied here too, because the series touches both xen/ (arch)
# and tools/ (libxl/libxc/xl) and must stay a contiguous quilt series so the
# tools-side hunks land (0006-0024 = the virtio-pci / vgsx / cacheable-iomem
# libxl+xl work; 0004-0005 = the Flask xsm policy the tools build ships).
#
# NOTE on stock pre-patches: stock xen-tools_4.21.bb SRC_URI already carries
#   0001-python-pygrub-pass-DISTUTILS-xen-4.19.patch
#   0001-libxl_nocpuid-fix-build-error.patch          (stock's own variant)
#   0001-tools-libxl-Fix-build-with-NOCPUID-and-json-c.patch
#   0001-tests-vpci-drop-explicit-g-use.patch
#   0001-ARM-Drop-ThumbEE-support.patch
# so the 4.19-era fork gcc15 fixes we used to add here (our own nocpuid variant
# and 0002-libxl-dirname-const-strrchr) are NOT re-added: verified they REJECT
# on stock+27 (stock already fixes those build errors). ThumbEE is likewise
# left to the stock SRC_URI (not re-added). The virt-networking files
# (10-ether.network / 10-xenbr0.*) are also NOT re-added: stock
# xen-tools_4.21.bb does not `require xen-source.inc`, so the fork's
# "SRC_URI = ${XEN_URL}" reset that used to wipe them never runs; stock
# xen-tools.inc supplies them from meta-virtualization's files/.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# 0002-0024 + 4.21-000{1,2,3,4,5} are byte-identical to the hypervisor xen bbappend
# copies and are shared from meta-xt-common/recipes-extended/xen-common/files
# (both bbappends point at it). Only the toolstack-only project patches
# (0001-qemu_envs / 0059 / 0061 / 0062 / 0063) + the systemd unit remain in ./files here.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../recipes-extended/xen-common/files:"

# --- the same patch series as the hypervisor, minus the hypervisor-only
# --- 0025 (28 patches; order matters). The hypervisor xen_4.21.bbappend
# --- adds file://0025-dom0less-arm-xenstore-page-from-domain-static-mem.patch
# --- as the 27th patch, but 0025 only touches xen/ (arch) with no tools/ hunk,
# --- so it is intentionally excluded from the toolstack series here.

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
    file://4.21-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.21-0005-build-honour-external-toolchain-vars.patch \
"

# --- project toolstack feature patches (verified APPLIES on stock+27) ---
# qemu_envs   : pass WAYLAND_DISPLAY/XDG_RUNTIME_DIR/SDL_VIDEODRIVER/WMCLASS to
#               the guest device-model (doma.cfg display path). 4.21-rebased.
# 0059        : libxl__domain_make pre-creates the qdisk backend xenstore tree
#               {dom0, DomD RW} so a Dom0-created DomU whose device-model runs in
#               the dom0less DomD can connect its qdisk backend (else no display).
# 0061        : xl devd reaps the device-model on domain death (stale-qemu fix).
# 0063        : virtio dm_needed: no LOCAL device model when the devd
#               delegation path (0015) owns the backend (DomD-as-toolstack
#               double-spawn fix; rc=-3 on hardware).
# 0062        : init-dom0less per-vcpu availability fix (multi-vCPU dom0less
#               domains; upstream submission candidate).
# (0053/0055/0052/0050/0058 are NOT added: 0053/0055/0052/0050 REJECT on 4.21;
#  0058 initializes b_info.tpm which 4.21 removed -> compile error. All were
#  already disabled in the fork _git bbappend for 4.21.)
SRC_URI:append = " \
    file://0001-Add-qemu_envs-guest-config-for-custom-environment-va.patch \
    file://0059-libxl-qdisk-driverdom-libxl-perm.patch \
    file://0061-libxl-devd-reap-dm-on-domain-death.patch \
    file://0062-init-dom0less-fix-per-vcpu-availability-writes.patch \
    file://0063-libxl-virtio-no-local-dm-when-devd-owns-backend.patch \
"

# Tolerate patch-fuzz from base offset drift (context shifts on stable-4.21 point
# updates). Upstream-Status is present on every patch, so the separate patch-status
# QA is satisfied and is not touched here.
# CAVEAT: demoting patch-fuzz from ERROR to WARN *permanently* means a future patch
# that no longer applies cleanly (fuzz, or a hunk landing at the wrong offset after a
# context shift) can pass do_patch with only a warning instead of failing the build --
# a silently mis-applied patch. Behaviour is intentionally left as-is (all patches
# apply clean at the current SRCREV); on any base bump, re-check the do_patch log for
# "Fuzz"/offset warnings and refresh the affected patch rather than relying on this.
WARN_QA:append = " patch-fuzz"
ERROR_QA:remove = "patch-fuzz"

# Install the systemd unit that auto-invokes init-dom0less on boot (dom0less
# DomD xenstore seeding), same as the fork _git bbappend did.
SRC_URI += " file://xen-init-dom0less.service"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xen-init-dom0less.service \
        ${D}${systemd_system_unitdir}/xen-init-dom0less.service
}

SYSTEMD_SERVICE:${PN}-xencommons:append = " xen-init-dom0less.service"
FILES:${PN}-xencommons += "${systemd_system_unitdir}/xen-init-dom0less.service"
