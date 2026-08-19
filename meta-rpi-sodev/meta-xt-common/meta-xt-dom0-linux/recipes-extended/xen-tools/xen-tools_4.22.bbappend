# ============================================================================
# Xen 4.22 + 28-patch shared series + 5 toolstack-only patches = 33 fetched
# ============================================================================
# Attaches to xen-tools_4.22.bb (PV "4.22+stable", SRCREV d45d5687f1, branch
# stable-4.22) instead of the xen-troops fork _git recipe. Selected by
#   PREFERRED_VERSION_xen-tools = "4.22+stable"
# (set in the DomD build's local.conf / rpi5-sodev.yaml).
#
# [4.22] The recipe it attaches to is NO LONGER the stock meta-virtualization
# one: master at 526c9725 stops at xen-tools_4.21.bb, so this layer carries an
# interim local xen-tools_4.22.bb alongside this file, to be submitted upstream
# and deleted once accepted. See that recipe's header.
#
# xen-tools unpacks its own copy of the same xen.git tree and compiles the
# toolstack (libxc / libxl / xl). The same 28-patch series applied to the
# hypervisor is applied here too, because the series touches both xen/ (arch)
# and tools/ (libxl/libxc/xl) and must stay a contiguous quilt series so the
# tools-side hunks land (0006-0024 = the virtio-pci / vgsx / cacheable-iomem
# libxl+xl work; 0004-0005 = the Flask xsm policy the tools build ships).
#
# NOTE on pre-patches: [4.22] the set changed. The local xen-tools_4.22.bb SRC_URI
# carries
#   0001-python-pygrub-pass-DISTUTILS-xen-4.19.patch   (verbatim, clean on 4.22)
#   0001-libxl_nocpuid-fix-build-error.patch           (verbatim, clean on 4.22)
#   0001-tests-vpci-drop-explicit-g-use.patch          (REFRESHED for 4.22)
# and DROPS two that 4.22 took upstream:
#   0001-tools-libxl-Fix-build-with-NOCPUID-and-json-c.patch -> ca7906501e
#   0001-ARM-Drop-ThumbEE-support.patch                      -> 5bbe1fe413
# The rationale per patch is recorded in the recipe's own header. As in 4.21, the
# 4.19-era fork gcc15 fixes (our own nocpuid variant and
# 0002-libxl-dirname-const-strrchr) are NOT re-added here, and the
# virt-networking files (10-ether.network / 10-xenbr0.*) are NOT re-added either:
# xen-tools_4.22.bb does not `require xen-source.inc`, so the fork's
# "SRC_URI = ${XEN_URL}" reset that used to wipe them never runs; upstream
# xen-tools.inc supplies them from meta-virtualization's files/.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# The 28 shared patches (0002-0024 + 4.22-000{1..5}) are single copies living in
# meta-xt-common/recipes-extended/xen-common/files, which both this bbappend and
# the hypervisor xen_4.22.bbappend point at -- the two SRC_URI lists name the same
# 28 files. Only the toolstack-only project patches (0001-qemu_envs / 0059 / 0061
# / 0062 / 0063), the systemd unit, and the interim recipe's own stock
# pre-patches remain in ./files here.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../recipes-extended/xen-common/files:"

# --- the same patch series as the hypervisor, minus the two hypervisor-only
# --- patches (28 patches; order matters). 0025-dom0less-arm-xenstore-page-from-
# --- domain-static-mem.patch and 4.22-0006-dom0less-seed-next-phandle-below-
# --- reserved-range.patch both touch xen/ (arch) only, with no tools/ hunk, so
# --- both are intentionally excluded from the toolstack series here. The
# --- toolstack-only patches (qemu_envs, 0059, 0061, 0062, 0063) follow below.

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
    file://4.22-0004-vgic-pci-irq-level-race-fix.patch \
    file://4.22-0005-build-honour-external-toolchain-vars.patch \
"

# --- project toolstack feature patches (verified: all 5 apply CLEAN on 4.22) ---
# qemu_envs   : pass WAYLAND_DISPLAY/XDG_RUNTIME_DIR/SDL_VIDEODRIVER/WMCLASS to
#               the guest device-model (doma.cfg display path).
# 0059        : libxl__domain_make pre-creates the qdisk backend xenstore tree
#               {dom0, DomD RW} so a Dom0-created DomU whose device-model runs in
#               the dom0less DomD can connect its qdisk backend (else no display).
# 0061        : xl devd reaps the device-model on domain death (stale-qemu fix).
# 0063        : virtio dm_needed: no LOCAL device model when the devd
#               delegation path (0015) owns the backend (DomD-as-toolstack
#               double-spawn fix; rc=-3 on hardware).
# 0062        : init-dom0less per-vcpu availability fix (multi-vCPU dom0less
#               domains; upstream submission candidate).
# (0053/0055/0052/0050/0058 are NOT added, unchanged from 4.21: 0053/0055/0052/0050
#  REJECTed on 4.21, and 0058 initialized a b_info field 4.21 had removed ->
#  compile error. All were already disabled in the fork _git bbappend for 4.21.
#  [4.22] NOT re-verified against 4.22: these patch files are not carried in this
#  workspace, so there is nothing here to test. They stay excluded. If they are
#  ever wanted back, re-test them against stable-4.22 first -- do not assume the
#  4.21 verdicts still hold.)
SRC_URI:append = " \
    file://0001-Add-qemu_envs-guest-config-for-custom-environment-va.patch \
    file://0059-libxl-qdisk-driverdom-libxl-perm.patch \
    file://0061-libxl-devd-reap-dm-on-domain-death.patch \
    file://0062-init-dom0less-fix-per-vcpu-availability-writes.patch \
    file://0063-libxl-virtio-no-local-dm-when-devd-owns-backend.patch \
"

# --- [4.22] package the two test binaries 4.22 adds --------------------------
# Xen 4.22 adds tools/tests/mem-claim and tools/tests/numa (neither exists in
# 4.21). meta-virtualization's xen-tools.inc lists every test binary explicitly
# in FILES:${PN}-test, so the two new ones land nowhere and do_package fails:
#
#   ERROR: xen-tools-4.22+stable-r0 do_package: QA Issue: xen-tools:
#     Files/directories were installed but not shipped in any package:
#       /usr/lib/xen/tests/test-mem-claim
#       /usr/lib/xen/tests/test-numa
#   ERROR: ... Fatal QA errors were found, failing task.
#
# This is an upstream packaging gap, not something this project introduced: the
# proper home for these two lines is xen-tools.inc (they are harmless for
# 4.19/4.20/4.21, where the paths simply do not exist, and ${PN}-test is
# ALLOW_EMPTY). Carried here so the fix is version-scoped and this bbappend stays
# the only local delta. The same two lines are being submitted upstream together
# with the 4.22 version recipes; remove this block once xen-tools.inc carries them.
FILES:${PN}-test += "\
    ${libdir}/xen/tests/test-mem-claim \
    ${libdir}/xen/tests/test-numa \
    "

# --- patch-fuzz QA: left at ERROR (the OE default) ---------------------------
# [4.22] The 4.21 bbappend demoted patch-fuzz to a warning here:
#   WARN_QA:append = " patch-fuzz"
#   ERROR_QA:remove = "patch-fuzz"
# with its own CAVEAT noting that a permanent demotion lets a silently
# mis-applied patch (fuzz, or a hunk landing at the wrong offset after a context
# shift) pass do_patch with only a warning. Both lines are REMOVED for 4.22:
# every patch in this series applies to stable-4.22 with zero fuzz and zero
# offset warnings (0008/0018 regenerated, 0022/4.22-0001 rebased), so there is
# nothing left to tolerate, and a mis-apply on a future point update should fail
# the build rather than warn. If a stable-4.22.x bump shifts context, refresh the
# affected patch -- do not re-add the demotion. Kept in sync with the hypervisor
# xen_4.22.bbappend.
# Upstream-Status is present on every patch, so the separate patch-status QA is
# satisfied and is not touched here.

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
