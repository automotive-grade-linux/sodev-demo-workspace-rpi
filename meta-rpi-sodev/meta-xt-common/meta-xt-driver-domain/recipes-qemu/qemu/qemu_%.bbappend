# meta-xt-driver-domain overlay on the PRISTINE meta-xt-common/meta-xt-qemu qemu recipe.
#
# Stacks on the base qemu_%.bbappend (meta-xt-qemu), carrying four RPi5/Xen qemu
# deltas without editing meta-xt-qemu's qemu.inc / qemu-package-split.inc:
#
#   common-0001  package split: assign qemu-system-aarch64 to the
#                ${PN}-system-aarch64 package (the pristine qemu-package-split.inc
#                assigns it to ${PN}-aarch64, leaving system-aarch64 empty ->
#                "Nothing RPROVIDES qemu-system-aarch64").
#   common-0002  device-model death fix: two qemu source patches
#                (0101 RESUME-QAPI guard, 0103 deferred autostart vm_start).
#   common-0003  virtio-pci ISR IOREQ range fix: one qemu source patch (0110).
#   common-0004  vhost backends for enable_virtio, drop kvm PACKAGECONFIG.
#   rpi5-0111    virtio-tablet BTN_TOUCH: one qemu source patch (0111), so the
#                virtio-tablet-pci device emits BTN_TOUCH (not BTN_MOUSE). Android
#                classifies an ABS_X/ABS_Y device as a touchscreen only when it
#                sends BTN_TOUCH, so this is required for DomA(AAOS) touch on
#                HDMI-A-2. Ported verbatim from V4H meta-xen-domd (EPAM).
#
# Mechanism: a .bbappend in this layer is parsed after the base recipe + base
# .bbappend, so plain '=' re-assignments and :append/:remove here win. Patch
# files live in this layer's files/; meta-xt-qemu stays pristine.
#
# meta-xt-qemu now provides THREE qemu recipes -- 11.1.2 (both boards' Vulkan lane),
# 10.0.2 (selectable instead) and 7.0.0 (the `--gpu=gl` lane) --
# and a qemu_%.bbappend applies to all of them, as
# well as to oe-core's own
# qemu_10.2.0.bb which meta-xt-qemu's 10.0.2 and 11.1.2 recipes `require` (bitbake-layers
# show-appends confirmed it for 10.0.2, 7.0.0 and 10.2.0 before 11.1.2 was added,
# whose name the same qemu_%.bbappend matches; qemu-system-native gets only
# meta-virtualization's bbappend, so nothing here reaches a native build). The
# source patches are 7.0.0-only and gated on PV accordingly, the gtk+/pixman pair
# is Venus-only and gated on DISTRO_FEATURES, and the package split plus the vhost
# and kvm deltas are version- and lane-independent and stay unconditional.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# --- common-0002 + common-0003: qemu device-model / IOREQ source patches ---
# RESUME guard, deferral of the autostart vm_start to the first main-loop
# iteration, and registration of the virtio-pci BAR4 ISR page (BAR+0x1000) in
# the IOREQ rangeset (self-heals -EEXIST partial overlaps), fixing a spurious
# Xen data abort and the resulting guest vp_interrupt panic. class-target only,
# matching how the base qemu.inc appends cross.patch.
#
# ALL SIX patches below are written against 7.0.0 sources, so they are gated on
# PV: meta-xt-qemu also carries the Venus-capable builds the DEFAULT lane
# (--gpu=vulkan) selects -- qemu_11.1.2.bb on both boards, or qemu_10.0.2.bb where a
# board selects it, see docs/VULKAN-VENUS.md -- and this bbappend applies to all
# three recipes. Applying a 7.0.0 patch to qemu 10 or 11 sources would fail do_patch,
# so those lanes deliberately start with none of them and get back only what they
# actually need.
#
# Status of all six against v10.0.2-xt (SRCREV f460a035). None is open any more,
# which is what allowed the default to move to the Vulkan lane:
#   0101 RESUME/QAPI guard              -- FORWARD-PORTED, with 0103, as
#                                          meta-xt-qemu's 0201 (listed with the
#                                          hardware-decode patches in
#                                          qemu_10.0.2.bb). It guards a RESUME emit
#                                          that died before the main loop was up in
#                                          7.0.0. That death was not seen on 10.0.2:
#                                          both guests' device models came up on
#                                          every boot of the RPi4 board
#                                          verification, 2026-09-10..12. The path
#                                          it comes from is still there, though:
#                                          libxl spawns the device model with only
#                                          "-monitor /dev/null" (no QMP monitor, no
#                                          -S), and 10.0.2's qmp_x_exit_preconfig()
#                                          still calls qmp_cont() inside
#                                          qemu_init().
#   0103 deferred autostart vm_start    -- FORWARD-PORTED with 0101, as 0201; see
#                                          0101.
#   0110 virtio-pci ISR IOREQ range     -- REBASED as meta-xt-qemu's 0120, against the
#                                          fork's reworked xen ioreq code.
#   0111 virtio-tablet BTN_TOUCH        -- REBASED as meta-xt-qemu's 0118, which is
#                                          smaller than this one because 10.0.2 already
#                                          has 'touch' in InputButton and BTN_TOUCH in
#                                          keymap_button (so the tablet already
#                                          advertises it) -- only the send-side remap
#                                          was missing. This 7.0.0 copy stays for the
#                                          7.0.0 lane.
#   0112 vTPM GUEST_TPM_BASE guard      -- MOOT. 10.0.2 has no hw/arm/xen_arm.c at all
#                                          (the Arm Xen machine is hw/arm/xen-pvh.c on
#                                          the xen-pvh-common code), and GUEST_TPM_BASE
#                                          appears nowhere in the tree -- checked in the
#                                          fork at that SRCREV.
#   0113 sched_attr redefinition guard  -- FIXED UPSTREAM. 10.0.2's own
#                                          linux-user/syscall.c already wraps the local
#                                          struct in #ifndef SCHED_ATTR_SIZE_VER0.
QEMU_XT_7_0_0_PATCHES = " \
    file://0101-fix-qapi-event-emit-no-qmp-monitor-std.patch \
    file://0103-fix-defer-autostart-vmstart-to-main-loop.patch \
    file://0110-xen-ioreq-isr-range-fix.patch \
    file://0111-virtio-input-hid-send-BTN_TOUCH-event-for-virtio-tab.patch \
    file://0112-xen-arm-guard-vtpm-on-guest-tpm-base.patch \
    file://0113-linux-user-guard-sched-attr-redefinition.patch \
"
# rpi5-0111 is in the list above because Android (DomA/AAOS) treats an ABS_X/ABS_Y
# device as a touchscreen only when it also sends BTN_TOUCH -- required for the
# HDMI-A-2 USB touch panel. Ported verbatim from V4H meta-xen-domd (EPAM).
# rpi5-0112 [Xen 4.21]: Xen 4.21 removed GUEST_TPM_BASE/SIZE (ARM vTPM guest
# layout) from public/arch-arm.h, breaking qemu xen_arm.c xen_enable_tpm()
# (referenced inside #ifdef CONFIG_TPM). vTPM is unused here; the patch guards the
# wiring on the define so qemu builds against both 4.19 and 4.21 headers.
# rpi5-0113 [wrynose / glibc 2.43]: qemu 7.0.0 linux-user/syscall.c defines its
# own `struct sched_attr` ("not defined in glibc") which glibc 2.43 (wrynose)
# now provides via <sched.h> -> "redefinition of struct sched_attr" in
# do_compile. The patch guards the local definition with #ifndef
# SCHED_ATTR_SIZE_VER0 (glibc's own struct guard); the two definitions are
# field-identical.
# startswith('7.'), not contains('PV', '7.0.0'): bb.utils.contains matches the
# whole whitespace-separated token, so the moment PV becomes 7.0.0+git<sha> (a
# SRCREV-following recipe, an AUTOREV experiment) the exact match fails and all six
# patches disappear SILENTLY. Two of them -- 0112 (Xen 4.21 dropped
# GUEST_TPM_BASE) and 0113 (glibc 2.43 defines struct sched_attr) -- are what make
# qemu 7.0.0 compile at all, so the symptom would not look like a missing patch; it
# would look like an unrelated compile error. A prefix test keeps working across
# 7.x, and a hypothetical qemu 8.x would fail loudly at do_patch instead, which is
# the better failure.
SRC_URI:append:class-target = "${@d.getVar('QEMU_XT_7_0_0_PATCHES') if d.getVar('PV').startswith('7.') else ''}"
# NOTE: a virtio-gpu EDID 60Hz patch was investigated for the AGL cluster (DomU)
# free-run (~104fps) but ABANDONED: the EDID refresh_rate is advisory only, and
# the older guest virtio_gpu DRM (DomU kernel) emits an immediate (ASAP)
# synthetic flip-done that defeats weston/Flutter frame pacing -- so the reported
# EDID rate does not cap the frame rate. The real cap lives in the DomU guest
# stack (guest virtio_gpu vblank timer, or agl-compositor/Flutter repaint
# pacing), not in the qemu-side EDID. See fps investigation notes.

# --- common-0001: fix the qemu-system-aarch64 package split ---
# The pristine qemu-package-split.inc (required when vmsep is in DISTRO_FEATURES)
# assigns BOTH qemu-aarch64 and qemu-system-aarch64 binaries to ${PN}-aarch64,
# leaving the ${PN}-system-aarch64 package empty. Re-assign here: keep only
# qemu-aarch64 in ${PN}-aarch64, and put qemu-system-aarch64 in
# ${PN}-system-aarch64 so OE does not drop an empty package.
FILES:${PN}-aarch64:class-target = "${bindir}/qemu-aarch64"
FILES:${PN}-system-aarch64:class-target = "${bindir}/qemu-system-aarch64"
# The same upstream split also leaves an RPROVIDES alias behind: meta-virtualization
# declares RPROVIDES:${PN}-aarch64:append:class-target = " ${PN}-system-aarch64"
# because in ITS layout qemu-aarch64 ships both binaries. Here it does not (see the
# two FILES lines above), and the alias makes the SBOM name the wrong package. poky's
# collect_package_providers() (meta/lib/oe/spdx_common.py) maps every RPROVIDES to a
# provider in one flat dict while walking PACKAGES in order, so the alias carried by
# qemu-aarch64 -- which comes after qemu-system-aarch64 in PACKAGES -- overwrites the
# entry qemu-system-aarch64 registered for itself. The rootfs SPDX document then lists
# qemu-aarch64, which is not installed, and omits qemu-system-aarch64, which is.
# Dropping the alias costs nothing here: each package owns exactly one binary, and the
# image asks for qemu-system-aarch64 by its real name. The :class-target override
# mirrors the one upstream uses, so this line is inert for nativesdk-qemu exactly as
# the alias is. qemu-user-aarch64 is left alone -- that alias names no real package,
# so it clobbers nothing.
RPROVIDES:${PN}-aarch64:remove:class-target = "${PN}-system-aarch64"

# --- common-0004: vhost backends for enable_virtio, drop kvm ---
# With the enable_virtio DISTRO_FEATURE:
#   - vhost PACKAGECONFIG builds the vhost-net/vhost-vsock/vhost-scsi backends
#     into qemu
#   - kvm is removed: Xen does not need KVM
PACKAGECONFIG:append = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' vhost', '', d)}"
# gtk+ PACKAGECONFIG, with the pixman it needs, for the Venus lane only. The
# guests display through SDL (-display sdl,gl=es); what gtk has and SDL lacks
# for the Venus device:
#
#   * upstream qemu sets `qemu_egl_display` only from the egl-headless, dbus,
#     spice and gtk display backends (ui/egl-helpers.c, ui/gtk.c:2137), never
#     from sdl, and without it virtio_gpu_virgl_init() does not install the v4
#     get_egl_display callback, so vrend cannot import a guest dma-buf via EGL.
#     meta-xt-qemu's 0117 is what makes sdl set it, from SDL's own EGLDisplay.
#   * sdl also does not implement the dmabuf display ops (dpy_gl_scanout_dmabuf and
#     friends); console.c, egl-headless, dbus, spice and gtk do.
#   * upstream's documented configuration for venus is `-display gtk,gl=on`
#     (qemu.readthedocs.io virtio-gpu, and Collabora's venus-on-qemu write-up). SDL is not
#     a supported display for this device.
#
# gtk+3 pulls in librsvg-native, which builds on DomD's oe-core: the
# pkg-config-native wrapper bug that breaks it on scarthgap
# (EXTRA_NATIVE_PKGCONFIG_PATH not passed through) is fixed by oe-core
# a59fa4a4bf ("pkg-config-native,librsvg-native: fix
# EXTRA_NATIVE_PKGCONFIG_PATH"), which the oe-core revision DomD builds with
# includes.
#
# GATED ON THE VENUS DISTRO_FEATURE, because every reason above is a Venus one.
# The guests run -display sdl,gl=es in both lanes, so no guest selects the gtk
# backend, and ungated this bbappend would add gtk+3, librsvg and pixman to the
# gl lane's DomD rootfs and to qemu 7.0.0, that lane's device model.
#
# pixman comes with gtk, not on its own: qemu's meson refuses gtk without it --
#   meson.build:1949: ERROR: Feature gtk cannot be enabled: cannot enable GTK if pixman
#   is not available
# The effective set was "epoxy fdt gtk+ pie sdl seccomp slirp vhost virglrenderer
# virtfs xen" with no pixman, so enabling gtk alone fails do_configure.
#
# Kept because this is the configuration that was verified on hardware. Whether
# the pair is still needed now that 0117 gives SDL an EGLDisplay has not been
# measured.
PACKAGECONFIG:append = "${@bb.utils.contains('DISTRO_FEATURES', 'venus', ' gtk+ pixman', '', d)}"
PACKAGECONFIG:remove = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' kvm', '', d)}"
