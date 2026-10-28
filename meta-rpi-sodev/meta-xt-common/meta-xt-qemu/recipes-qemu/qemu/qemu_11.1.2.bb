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
# what it does and, for a port, what changed. Two 10.0.2 patches are not carried: 0117
# (qemu 11.1.2 already takes SDL's EGLDisplay), whose place would have been q11-016 --
# the number is left free so references to the others stay valid -- and 0249 (qemu 11
# has its own ring_idx context fences), which came after 0248 = q11-050 and so leaves
# no gap. q11-055 and q11-056 are unused in the same way.
#
# Comments in the q11 patches mark the code of one feature with a tag of the form
# q11-<feature> (often the name of its switch), so that its parts can be found across
# files.

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

# libavcodec for the decoder mode q11-041 adds and q11-042 drives, and ONLY for the
# Raspberry Pi 5.
#
# The two boards reach hardware decode through different host devices, and only one
# of them needs a codec library in the device model. On a Pi 4 the host device is
# bcm2835-codec, which is a STATEFUL V4L2 decoder, so q11-023's plain one-node proxy is
# the whole path: the guest's stateful decoder maps onto a stateful host decoder and
# nothing parses the bitstream in qemu. BCM2712's only decode block is codec@800000
# driven by rpi-hevc-dec, and that is STATELESS -- a media device plus a request fd
# per frame, with the caller expected to parse the bitstream and build the DPB.
# virtio-media cannot carry either: its protocol has five commands and no file
# descriptors, and Android's external/v4l2_codec2 has no stateless support at all.
# So q11-041 converts on the host, offering the guest an ordinary stateful HEVC decoder
# and letting libavcodec do the stateless driving.
#
# rpidistro-ffmpeg rather than poky's ffmpeg: only the Raspberry Pi fork carries the
# v4l2request hwaccel that q11-042 uses. Named as the RECIPE, so PREFERRED_PROVIDER is
# not involved -- that only decides who provides the virtual `ffmpeg`, and this
# DEPENDS is unambiguous on its own.
#
# The dependency is what turns decoder mode on, not a configure switch: meson finds
# the three libraries with pkg-config, and the file q11-041 adds stubs itself out when
# they are absent. That is why the Pi 4 binary is unaffected even though the patches
# are applied for both boards -- it gets the stub, and its device argument
# (XT_DOMA_HWDEC_DEVARG, v4l2-device=/dev/video10) never selects decoder mode.
DEPENDS:append:raspberrypi5 = " rpidistro-ffmpeg"

# qemu 11 removed the GlusterFS block driver and its configure option; the
# 10.2.0 recipe body still maps the PACKAGECONFIG to --disable-glusterfs.
PACKAGECONFIG:remove = "glusterfs"
PACKAGECONFIG[glusterfs] = ""

# The q11 patches apply in the order listed here, which is not their numbers' order: they
# are grouped by the series that brings them (qemu 11.1.2 itself, the display path), and
# the numbers follow the order they were written in.
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
# q11-013..050: ports of this layer's qemu 10.0.2 patches, in the 10.0.2 recipe's order;
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
SRC_URI:append:class-target = " file://q11-023-hw-virtio-add-a-native-virtio-media-device.patch"
SRC_URI:append:class-target = " file://q11-024-audio-alsa-report-the-generic-buffer-as-free-as-7.0-did.patch"
SRC_URI:append:class-target = " file://q11-025-virtio-media-process-the-command-queue-from-a-bottom-half.patch"
SRC_URI:append:class-target = " file://q11-026-virtio-media-drain-only-what-poll-actually-reports.patch"
SRC_URI:append:class-target = " file://q11-027-xen-mapcache-keep-foreign-bucket-heads-mapped-when-unlocked.patch"
SRC_URI:append:class-target = " file://q11-028-virtio-media-merge-adjacent-SG-entries.patch"
SRC_URI:append:class-target = " file://q11-029-xen-mapcache-find-reverse-entries-by-hash-not-by-list-walk.patch"
SRC_URI:append:class-target = " file://q11-030-virtio-media-request-non-coherent-cacheable-host-MMAP-buffer.patch"
SRC_URI:append:class-target = " file://q11-031-virtio-media-write-decoded-frames-straight-into-the-guest-s.patch"
SRC_URI:append:class-target = " file://q11-032-virtio-media-copy-decoded-frames-into-the-virgl-resource-on.patch"
SRC_URI:append:class-target = " file://q11-033-virtio-media-keep-CAPTURE-buffers-coherent-when-the-GPU-copi.patch"
SRC_URI:append:class-target = " file://q11-034-virtio-media-run-the-CAPTURE-queue-as-NV12-on-the-host-conve.patch"
SRC_URI:append:class-target = " file://q11-035-xen-never-unregister-IOREQ-MMIO-ranges.patch"
SRC_URI:append:class-target = " file://q11-036-virtio-gpu-gl-suppress-guest-notifications-while-draining-th.patch"
SRC_URI:append:class-target = " file://q11-037-virtio-media-park-the-host-fd-handler-while-poll-reports-onl.patch"
SRC_URI:append:class-target = " file://q11-038-virtio-gpu-virgl-poll-for-retired-fences-every-1-ms-instead.patch"
SRC_URI:append:class-target = " file://q11-039-virtio-gpu-add-a-refresh_rate-property-for-the-generated-EDI.patch"
SRC_URI:append:class-target = " file://q11-040-virtio-media-add-output-coherent-and-gpu-fence-fd.patch"
SRC_URI:append:class-target = " file://q11-041-hw-virtio-media-add-a-stateful-decoder-mode-backed-by-libavc.patch"
SRC_URI:append:class-target = " file://q11-042-hw-virtio-media-drive-decoder-mode-with-the-v4l2request-hwac.patch"
SRC_URI:append:class-target = " file://q11-043-hw-virtio-media-do-not-fail-an-OUTPUT-QBUF-when-the-decoder.patch"
SRC_URI:append:class-target = " file://q11-044-hw-virtio-media-return-the-OUTPUT-buffer-timestamp-on-comple.patch"
SRC_URI:append:class-target = " file://q11-045-hw-virtio-media-give-decoder-mode-an-RGBA-output-and-the-dir.patch"
SRC_URI:append:class-target = " file://q11-046-virtio-snd-drain-the-TX-queue-from-a-dedicated-thread-tx-pol.patch"
SRC_URI:append:class-target = " file://q11-047-hw-arm-pass-the-virtio-pci-INTX-line-count-to-the-GPEX.patch"
SRC_URI:append:class-target = " file://q11-048-hw-virtio-media-let-host-nv12-scale-the-frame-down-to-the-di.patch"
SRC_URI:append:class-target = " file://q11-049-hw-virtio-media-invalidate-the-RGBA-target-before-the-NV12-d.patch"
SRC_URI:append:class-target = " file://q11-050-virtio-gpu-raise-the-control-queue-interrupt-once-per-batch.patch"
# q11-052..058: an ioreq thread and ISR reads on it (opt-in, QEMU_XEN_IOREQ_THREAD=1), a
#   cap on the foreign mapcache (QEMU_XEN_MAPCACHE_MAX_MB) and QEMU_LAT_DIAG=1 latency
#   counters (x2).
SRC_URI:append:class-target = " file://q11-052-xen-acknowledge-virtio-pci-notify-writes-on-an-ioreq-thread.patch"
SRC_URI:append:class-target = " file://q11-053-xen-mapcache-let-QEMU_XEN_MAPCACHE_MAX_MB-cap-the-foreign-ma.patch"
SRC_URI:append:class-target = " file://q11-054-xen-complete-virtio-pci-ISR-reads-on-the-ioreq-thread-under.patch"
SRC_URI:append:class-target = " file://q11-057-virtio-gpu-virtio-media-log-command-latency-when-QEMU_LAT_DI.patch"
SRC_URI:append:class-target = " file://q11-058-virtio-gpu-split-QEMU_LAT_DIAG-display-latency-into-queue-an.patch"
# q11-065: under Xen, map blobs through the subregion path, not map_fixed (built against
#   virglrenderer >= 1.3.0, map_fixed skips the guest p2m and Venus fails).
# q11-068: retire a destroyed context's ring fences (an upstream 11.1.2 leak).
SRC_URI:append:class-target = " file://q11-065-virtio-gpu-virgl-under-Xen-map-blobs-via-subregion-not-map_f.patch"
SRC_URI:append:class-target = " file://q11-068-virtio-gpu-virgl-retire-a-destroyed-context-s-ring-fences.patch"
#
# The display path: the guests' overlay planes.
# q11-051: overlay planes (overlay-planes=N on virtio-gpu-gl).
SRC_URI:append:class-target = " file://q11-051-virtio-gpu-gl-sdl2-gl-overlay-planes-overlay-planes-N.patch"
