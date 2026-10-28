# qemu 11.1.2 (upstream release tarball) as a second device model for DomD.
# Used where a build sets PREFERRED_VERSION_qemu = "11.1.2" (and, for the linux
# Dom0 flavour, XT_DOM0_QEMU_VERSION to match): both boards' vulkan lanes do. See
# qemu_10.0.2.bb for the device-model design these patches carry.
#
# Recipe body: oe-core's qemu 10.2.0 recipe, reached through BBPATH, as for
# qemu_10.0.2.bb. Its configure options are all accepted by 11.1.2's configure (the
# only one 11.1.2 no longer has is glusterfs, removed below), and its LIC_FILES_CHKSUM
# values match 11.1.2's license files, so neither is overridden.
#
# The patches are q11-NNN-*.patch in qemu-11.1.2/ (generated with git format-patch; do
# not edit the hunks by hand -- bitbake treats fuzz as fatal). Each patch's header says
# what it does and, for a port, what changed. One 10.0.2 patch is not carried here:
# 0117 (qemu 11.1.2 already takes SDL's EGLDisplay), whose place would have been
# q11-016 -- the number is left free so references to the others stay valid.

require recipes-devtools/qemu/qemu_10.2.0.bb

# Not chosen by a conf that leaves PREFERRED_VERSION_qemu unset: qemu_7.0.0.bb,
# qemu_10.0.2.bb and this recipe are in the same layer, where the newest version would
# otherwise win.
DEFAULT_PREFERENCE = "-1"

# A target device model only: no nativesdk variant (the 10.2.0 body declares one, and
# PREFERRED_VERSION_qemu does not reach nativesdk-qemu, which would then pick this
# version without the class-target patches).
BBCLASSEXTEND = ""

# '=' not ':append': oe-core's SRC_URI is its own tarball, its patches against it and
# three data files in oe-core's qemu/ directory that FILESPATH -- rooted at THIS
# recipe's directory -- cannot see. The tarball already contains the meson subprojects
# (keycodemapdb, berkeley-softfloat-3/testfloat-3, ...). run-ptest is kept because
# `inherit ptest` expects it; this layer's qemu/ directory provides it.
SRC_URI = "https://download.qemu.org/qemu-${PV}.tar.xz \
           file://run-ptest \
           "
SRC_URI[sha256sum] = "731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016"

# oe-core's do_install installs the guest-agent init/udev files when qemu-ga was
# built, from ${UNPACKDIR} -- i.e. from the two SRC_URI entries dropped above. The
# guest agent has no role in a device-model-only qemu (the 7.0.0 recipe does not
# build it either), so turn it off rather than vendor the two files.
EXTRA_OECONF:append = " --disable-guest-agent"
# ...and with qemu-ga not built, its systemd unit is not installed either, while
# oe-core's recipe declares it unconditionally. systemd.bbclass turns that into a
# hard do_package error:
#     Didn't find service unit 'qemu-guest-agent.service', specified in
#     SYSTEMD_SERVICE:qemu-guest-agent
# so withdraw the declaration along with the feature. The ${PN}-guest-agent
# package then has no files and OE drops it. (update-rc.d needs no equivalent: it
# has no build-time existence check, and the init script it would register lives
# in the same dropped package.)
SYSTEMD_SERVICE:${PN}-guest-agent = ""

# Same reasoning as the pulsedio drop in this layer's qemu.inc: nothing in these
# images runs pulseaudio (no guest config uses a pulseaudio -audiodev), and
# 'pulseaudio' is in wrynose's DISTRO_FEATURES_DEFAULTS, so the 10.2.0 recipe's
# `bb.utils.filter('DISTRO_FEATURES', 'alsa pulseaudio xen', d)` would otherwise
# add a pulseaudio DEPENDS to the DomD build.
PACKAGECONFIG:remove = "pulseaudio"

# qemu 11 removed the GlusterFS block driver and its configure option; the
# 10.2.0 recipe body still maps the PACKAGECONFIG to --disable-glusterfs.
PACKAGECONFIG:remove = "glusterfs"
PACKAGECONFIG[glusterfs] = ""

# The q11 patches apply in the order listed here; the numbers follow the order they were
# written in.
#
# qemu 11.1.2 itself.
# q11-001..012: the twelve xen-troops v10.0.2-xt commits (Origin: lines name each one).
SRC_URI:append:class-target = " file://q11-001-xen-block-Do-not-write-frontend-nodes.patch"
SRC_URI:append:class-target = " file://q11-002-xen-bus-Do-not-destroy-frontend-backend-directories.patch"
SRC_URI:append:class-target = " file://q11-003-xen-bus-Set-offline-if-backend-s-state-is-XenbusStateClosed.patch"
SRC_URI:append:class-target = " file://q11-004-xen_arm-Mandate-xen_enabled-to-be-true-and-drop-extra-interf.patch"
SRC_URI:append:class-target = " file://q11-005-xen-when-unplugging-emulated-devices-skip-virtio-devices.patch"
SRC_URI:append:class-target = " file://q11-006-xen_pvdev-Do-not-assume-Dom0-when-changing-directory-permiss.patch"
SRC_URI:append:class-target = " file://q11-007-HACK-do-not-enforce-full-ecam-size.patch"
SRC_URI:append:class-target = " file://q11-008-xen-pvh-common-initialize-ram_block--host.patch"
SRC_URI:append:class-target = " file://q11-009-xen-mapcache-leave-first-in-buckets-unmapped.patch"
SRC_URI:append:class-target = " file://q11-010-pci-host-gpex-shrink-memory-region-from-256MB-to-128MB.patch"
SRC_URI:append:class-target = " file://q11-011-xen-mapcache-adjust-bucket-size.patch"
SRC_URI:append:class-target = " file://q11-012-Revert-xen-mapcache-leave-first-in-buckets-unmapped.patch"
# q11-013..022: ports of this layer's qemu 10.0.2 patches, in the 10.0.2 recipe's order;
#   they were ported in one batch, so their Date: lines are seconds apart.
SRC_URI:append:class-target = " file://q11-013-configure-use-the-host-python-and-meson-instead-of-a-venv.patch"
SRC_URI:append:class-target = " file://q11-014-hw-arm-accept-xenpv-and-its-libxl-published-PCI-layout.patch"
SRC_URI:append:class-target = " file://q11-015-hw-arm-share-device-model-RAM-into-the-guest-s-physmap.patch"
SRC_URI:append:class-target = " file://q11-017-virtio-input-hid-send-BTN_TOUCH-for-the-tablet-so-Android-se.patch"
SRC_URI:append:class-target = " file://q11-018-vhost-do-not-verify-vring-host-mappings-under-Xen-it-abort-s.patch"
SRC_URI:append:class-target = " file://q11-019-xen-do-not-silently-drop-IOREQ-MMIO-range-un-registration-fa.patch"
SRC_URI:append:class-target = " file://q11-020-virtio-gpu-xen-pin-shmem-backed-blobs-through-udmabuf-before.patch"
SRC_URI:append:class-target = " file://q11-021-xen-keep-the-autostart-device-model-alive-without-a-QMP-moni.patch"
SRC_URI:append:class-target = " file://q11-022-hw-xen-xen-pvh-common-allow-one-INTX-line-per-virtio-pci-slo.patch"
