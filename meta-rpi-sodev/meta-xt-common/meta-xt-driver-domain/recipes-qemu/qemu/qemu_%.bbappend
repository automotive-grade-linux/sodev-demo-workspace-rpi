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

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# --- common-0002 + common-0003: qemu device-model / IOREQ source patches ---
# RESUME guard, deferral of the autostart vm_start to the first main-loop
# iteration, and registration of the virtio-pci BAR4 ISR page (BAR+0x1000) in
# the IOREQ rangeset (self-heals -EEXIST partial overlaps), fixing a spurious
# Xen data abort and the resulting guest vp_interrupt panic. class-target only,
# matching how the base qemu.inc appends cross.patch.
SRC_URI:append:class-target = " file://0101-fix-qapi-event-emit-no-qmp-monitor-std.patch"
SRC_URI:append:class-target = " file://0103-fix-defer-autostart-vmstart-to-main-loop.patch"
SRC_URI:append:class-target = " file://0110-xen-ioreq-isr-range-fix.patch"
# rpi5-0111: virtio-tablet emits BTN_TOUCH so Android (DomA/AAOS) treats it as a
# touchscreen — required for the HDMI-A-2 USB touch panel to work.
SRC_URI:append:class-target = " file://0111-virtio-input-hid-send-BTN_TOUCH-event-for-virtio-tab.patch"
# rpi5-0112 [Xen 4.21]: Xen 4.21 removed GUEST_TPM_BASE/SIZE (ARM vTPM guest
# layout) from public/arch-arm.h, breaking qemu xen_arm.c xen_enable_tpm()
# (referenced inside #ifdef CONFIG_TPM). vTPM is unused here; guard the wiring
# on the define so qemu builds against both 4.19 and 4.21 headers.
SRC_URI:append:class-target = " file://0112-xen-arm-guard-vtpm-on-guest-tpm-base.patch"
# rpi5-0113 [wrynose / glibc 2.43]: qemu 7.0.0 linux-user/syscall.c defines its
# own `struct sched_attr` ("not defined in glibc") which glibc 2.43 (wrynose)
# now provides via <sched.h> -> "redefinition of struct sched_attr" in
# do_compile. Guard the local definition with #ifndef SCHED_ATTR_SIZE_VER0
# (glibc's own struct guard); the two definitions are field-identical.
SRC_URI:append:class-target = " file://0113-linux-user-guard-sched-attr-redefinition.patch"
# NOTE: a virtio-gpu EDID 60Hz patch was investigated for the AGL cluster (DomU)
# free-run (~104fps) but ABANDONED: the EDID refresh_rate is advisory only, and
# the older guest virtio_gpu DRM (DomU kernel) emits an immediate (ASAP)
# synthetic flip-done that defeats weston/Flutter frame pacing — so the reported
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

# --- common-0004: vhost backends for enable_virtio, drop kvm ---
# With the enable_virtio DISTRO_FEATURE:
#   - vhost PACKAGECONFIG builds the vhost-net/vhost-vsock/vhost-scsi backends
#     into qemu
#   - kvm is removed: Xen does not need KVM
PACKAGECONFIG:append = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' vhost', '', d)}"
# gtk+ PACKAGECONFIG is omitted (librsvg-native build failure); SDL is used
# instead via the -display sdl,gl=on device-model option.
PACKAGECONFIG:remove = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' kvm', '', d)}"
