# The xen-troops fork's Venus-capable qemu, selectable for either board: GPU=vulkan
# is the default lane and appends PREFERRED_VERSION_qemu = "11.1.2" to the domd conf
# on both boards; setting it to "10.0.2" there selects this one.
# The yaml's base value for that variable is still 7.0.0, which is
# what `--gpu=gl` leaves standing. virtio-gpu-gl grew the `venus=` property in
# QEMU 9.2.0, so the vendored 7.0.0 fork cannot carry Venus at all -- see
# docs/VULKAN-VENUS.md.
#
# Source: the SAME xen-troops fork as qemu_7.0.0.bb, on its v10.0.2-xt branch.
# The fork maintains post-9.2 branches (v10.0.2-xt and v11.0.2-xt), so the Xen ARM
# device-model work does not have to be given up to get Venus.
#
# Venus support confirmed present at this SRCREV, in the fork's own sources:
#   hw/display/virtio-gpu-gl.c   DEFINE_PROP_BIT("venus", ... VIRTIO_GPU_FLAG_VENUS_ENABLED)
#   hw/display/virtio-gpu.c      rejects venus unless BOTH blob and hostmem are set,
#                                and unless VIRGL_VERSION_MAJOR >= 1 (oe-core ships
#                                virglrenderer 1.2.0, so that holds)
# -- which is why the device-model option string is hostmem= + blob=true + venus=true
# and not venus=true alone.
#
# Recipe body: oe-core's qemu 10.2.0 recipe, reached through BBPATH, rather than a
# second ~250-line vendored copy of qemu.inc. What it changes is the fetch, the
# license checksums (the two tags' license files differ) and a handful of
# packaging options -- do_configure:prepend, --disable-guest-agent,
# SYSTEMD_SERVICE and pulseaudio -- all of them below.
# This is the same cross-layer `require` used elsewhere in this
# tree (rpi5-image-xt-domd-vc4.bb requires recipes-core/images/rpi5-image-minimal-domd.bb).
#
# Three things to know before debugging a failure here:
#
#   1. RECIPE/SOURCE SKEW. The recipe body is 10.2.0's, the sources are 10.0.2's.
#      Two consequences, both checked against the real qemu trees rather than
#      assumed:
#        - configure options: the ONLY options that differ between the two tags are
#          igvm/mshv/passt/valgrind/gdb (added in 10.2.0) and avx2/avx512bw (removed
#          in 10.2.0), and the recipe body passes none of them. Every flag it does
#          pass -- the ten directory options, --with-suffix, --disable-strip,
#          --disable-werror, --disable-download, --disable-docs, --disable-af-xdp,
#          --host-cc, --extra-c/ldflags, --target-list, and the PACKAGECONFIG
#          --enable/--disable set -- is accepted by v10.0.2's configure +
#          scripts/meson-buildoptions.sh. So the skew does NOT break configure.
#          (If a future SRCREV moves further, v11.0.2-xt is the other fork branch:
#          11.0.2 > 10.2.0 makes the body older than the sources, which qemu's
#          configure tolerates.)
#        - the license files DO differ, which is why LIC_FILES_CHKSUM is overridden
#          below rather than inherited.
#
#   2. qemu.inc NAME COLLISION. oe-core's qemu_10.2.0.bb does `require qemu.inc`,
#      and this layer ships a qemu.inc of its own (the 7.0.0 one) with that exact
#      name. bitbake resolves a relative require against the requiring file's own
#      directory first, so oe-core's copy is the one that must win. If a failure
#      shows 7.0.0-era configure flags (--with-git=/bin/false, --with-suffix,
#      --disable-strip) being handed to qemu 10's meson, this is why.
#
#   3. THE SIX 7.0.0-ONLY PATCHES. The device-model patches in
#      meta-xt-driver-domain's qemu_%.bbappend are all written against 7.0.0
#      sources and are version-gated off for this recipe. What this recipe carries
#      instead: 0118 is 0111 rebased (virtio-tablet BTN_TOUCH, DomA touch) and 0120
#      is 0110 rebased (virtio-pci ISR IOREQ range). Of the rest, 0112 is moot (no
#      hw/arm/xen_arm.c and no GUEST_TPM_BASE anywhere in 10.0.2), 0113 is fixed in
#      10.0.2 itself, and 0101/0103 come back squashed and forward-ported as
#      0201, with the hardware-decode patches below: the pre-main-loop death
#      they guard was not seen on 10.0.2, but the synchronous autostart path it
#      comes from is still there. That bbappend states the evidence per patch.
require recipes-devtools/qemu/qemu_10.2.0.bb

# '=' not ':append': oe-core's SRC_URI is the release tarball, the patches written
# against that tarball, and three data files that live in oe-core's own qemu/
# directory (powerpc_rom.bin, qemu-guest-agent.init, qemu-guest-agent.udev) which
# FILESPATH -- rooted at THIS recipe's directory -- cannot see. None of it applies
# to a git fetch of the fork. run-ptest is kept because `inherit ptest` expects it
# and this layer's own qemu/ directory provides it (the same copy qemu_7.0.0.bb
# fetches). cross.patch is NOT carried over: it is a 5.2-era configure patch that
# oe-core itself dropped, and it does not apply to qemu 10.
# gitsm, not git: qemu carries submodules, as in qemu_7.0.0.bb's fetch.
SRC_URI = "gitsm://github.com/xen-troops/qemu.git;branch=v10.0.2-xt;protocol=https;name=qemu \
           file://run-ptest \
           ${QEMU_MESON_SUBPROJECTS} \
           "

# MESON SUBPROJECTS -- the one thing a git fetch of qemu >= 9 needs that a release
# tarball does not. Measured, not guessed: with only the gitsm fetch, do_configure
# stops at qemu's own gate
#
#     ERROR: missing subprojects
#     --disable-download specified but subprojects were not checked out.
#
# because oe-core's recipe body passes --disable-download (correctly -- Yocto does
# not fetch during do_configure) and qemu's release tarballs ship
# subprojects/<name>/ already downloaded and patched, while the git tree carries
# only subprojects/<name>.wrap. The gitsm fetch is not the answer: qemu's
# .gitmodules covers roms/* and tests/lcitool only (all of which DID come down
# correctly), never the wrap subprojects.
#
# Three are needed for this configuration, all of them `required: true`:
#   keycodemapdb          ui/meson.build:171 -- generates the keymaps
#   berkeley-softfloat-3  tests/fp/meson.build:38
#   berkeley-testfloat-3  tests/fp/meson.build:42
# The berkeley pair cannot be skipped by disabling tests: tests/meson.build enters
# subdir('fp') whenever CONFIG_TCG is in config_all_accel, and 10.0.2 has no
# meson option to turn tests off.
#
# Revisions are the ones the wrap files pin at this SRCREV, so the result is
# byte-identical to what `meson subprojects download` would produce -- with the
# fetch staying in do_fetch where it belongs.
QEMU_MESON_SUBPROJECTS = " \
    git://gitlab.com/qemu-project/keycodemapdb.git;protocol=https;nobranch=1;name=keycodemapdb;destsuffix=${BP}/subprojects/keycodemapdb \
    git://gitlab.com/qemu-project/berkeley-softfloat-3.git;protocol=https;nobranch=1;name=softfloat;destsuffix=${BP}/subprojects/berkeley-softfloat-3 \
    git://gitlab.com/qemu-project/berkeley-testfloat-3.git;protocol=https;nobranch=1;name=testfloat;destsuffix=${BP}/subprojects/berkeley-testfloat-3 \
"

SRCREV_qemu = "f460a03528d82c819ac449b56783c086d619d604"
# = subprojects/keycodemapdb.wrap @ SRCREV_qemu
SRCREV_keycodemapdb = "f5772a62ec52591ff6870b7e8ef32482371f22c6"
# = subprojects/berkeley-softfloat-3.wrap @ SRCREV_qemu
SRCREV_softfloat = "b64af41c3276f97f0e181920400ee056b9c88037"
# = subprojects/berkeley-testfloat-3.wrap @ SRCREV_qemu
SRCREV_testfloat = "e7af9751d9f9fd3b47911f51a5cfd08af256a9ab"
SRCREV_FORMAT = "qemu_keycodemapdb_softfloat_testfloat"

# The one oe-core patch this recipe DOES need, rebased onto 10.0.2. qemu >= 9's
# configure builds a Python venv with mkvenv.py and then uses the meson inside it,
# ignoring PATH; in a Yocto build the venv creation dies ("found no usable distlib,
# please install it") and the meson that must be used is meson-native from the
# recipe sysroot. oe-core carries this as two patches for its own recipe (0010 +
# 0011); 0011 applies to 10.0.2 unchanged but 0010 does not (10.2.0 factored the
# pwd call into a get_pwd() helper), so the two are folded and rebased here.
#
# This is the only one of oe-core's thirteen patches that is needed: the rest are
# musl fixes, x86/PPC target fixes, reproducibility tweaks or CVE backports for
# code this build does not produce -- and they are written against the 10.2.0
# tarball, so most do not apply to these sources anyway.
SRC_URI:append:class-target = " file://0114-configure-use-the-host-python-and-meson-not-a-venv.patch"

# The ARM Xen machine was renamed between 7.0.0 and this version -- "xenpv" in
# hw/arm/xen_arm.c became "xenpvh" in hw/arm/xen-pvh.c -- while libxl still spawns
# the qemu backend with `-machine xenpv`. Without this the DomU/DomA device model
# never starts: `xl create` fails with "Qdisk backend didn't respond in time" and
# /var/log/xen/qdisk-N.log holds `unsupported machine type: "xenpv"`. Only a
# libxl-created domain shows it: qemu run directly with -M virt never goes
# through libxl.
SRC_URI:append:class-target = " file://0115-hw-arm-accept-xenpv-as-an-alias-for-the-xenpvh-machi.patch"

# On Arm, arch_xen_set_memory() is an empty stub, so a RAM-backed region this
# device model places in the guest's address space is only registered with the
# IOREQ server -- every guest access to it traps here for emulation. For a
# virtio-gpu host-visible blob (Venus) that is fatal, not just slow: a SIMD/FP
# data abort carries no syndrome, Xen has to decode the instruction itself, and
# its decoder handles only general-purpose load/store forms -- so Mesa's first
# memcpy() to the venus ring kills the guest's Vulkan client. 0116 implements the
# hook, putting those pages into the guest's p2m instead (no trap at all).
#
# It needs the matching hypervisor patch (4.22-0007 in xen-common/files) to be
# permitted. Without it the batch fails -- -ESRCH on 4.22, whose
# rcu_lock_remote_domain_by_id() cannot resolve the DOMID_SELF the device model
# passes, and -EPERM on 4.21, whose xsm_map_gmfn_foreign() refuses the direction
# -- and 0116 then WITHDRAWS the window instead of leaving it trapping, so the
# guest's client gets VK_ERROR_MEMORY_MAP_FAILED rather than being killed by an
# undecodable abort. Both halves and the measurements are in
# docs/VULKAN-VENUS.md section 7a.
SRC_URI:append:class-target = " file://0116-hw-arm-share-device-model-RAM-into-the-guest-s-physma.patch"

# 0117: with -display sdl, qemu_egl_display is never set -- only egl-headless, dbus,
# spice and gtk set it. virtio_gpu_virgl_init() installs the v4 get_egl_display callback
# only when qemu_egl_display is non-NULL, so with SDL virglrenderer never reaches
# vrend_winsys_init_external() and vrend's `egl` stays NULL. vrend then imports dma-bufs
# through GL_EXT_memory_object[_fd], which V3D's GL driver does not implement, so the host
# compositor cannot import a guest Vulkan (venus) buffer: PIPE_RESOURCE_SET_TYPE returns
# EINVAL, the compositor's virgl context dies, and every Vulkan client in the guest needs
# MESA_VK_WSI_DEBUG=sw -- a CPU copy per frame, measured at 33 -> 24 fps on the AGL
# instrument cluster plus 0.18 -> 0.57 cores in DomD.
#
# The patch adopts the display SDL already created, the way ui/gtk.c does for GtkGLArea.
# Creating a second EGLDisplay instead does NOT work and was tried: vrend also makes EGL
# fences on it, and eglCreateSyncKHR against a display that does not own the current
# context fails with "Failed to create fence sync object".
SRC_URI:append:class-target = " file://0117-ui-sdl2-adopt-SDL-s-EGLDisplay-so-virglrenderer-can-.patch"

# 0118: DomA touch. Android classifies an ABS_X/ABS_Y device as a touchscreen
# only when it also reports BTN_TOUCH, and virtio-tablet-pci sends BTN_LEFT --
# so the guest gets nothing from a mouse click or a real touch panel. The
# 7.0.0-xt device model gets the fix from meta-xt-driver-domain's 0111, which
# this lane version-gates OFF, and that made guest Vulkan and DomA touch
# mutually exclusive. This is the same fix for 10.0.2, and it is much smaller
# here: upstream already has 'touch' in the InputButton enum and
# [INPUT_BUTTON_TOUCH] = BTN_TOUCH in keymap_button, and because the tablet
# synthesises its EV_KEY bitmap from that whole array
# (virtio_input_extend_config in virtio_tablet_init --
# virtio_tablet_config_v1/v2 declare no EV_KEY at all), the device ALREADY
# advertises BTN_TOUCH. Only the send side was missing.
#
# Applies to both guests, because both use virtio-tablet-pci. That is the same
# situation the 7.0.0 lane ships 0111 in, DomU's AGL compositor included: libinput
# then reads the device as a touchscreen rather than an absolute pointer.
SRC_URI:append:class-target = " file://0118-virtio-input-hid-send-BTN_TOUCH-for-the-tablet-so-An.patch"

# 0119: guest Vulkan vs vhost. Adding the virtio-gpu host-visible blob (0116's
# window) to the guest's address space drives qemu's vhost MemoryListener, and
# vhost_commit() then re-verifies every vring against the rebuilt memory table.
# That check cannot pass under Xen: qemu never maps the whole guest, so the
# RAMBlock behind "xen.ram" has host == NULL and the userspace_addr recorded for
# it is a pseudo-hva equal to the gpa, while vq->desc is a locked map-cache
# pointer -- every ring reads as "relocated" and vhost_commit() abort()s the
# device model. Measured on RPi4 2026-09-07: `adb shell cmd gpu vkjson` in DomA
# killed the dm 3/3 times with "descriptor table relocated for ring 0" /
# "Verify ring failure on region 0", core dump backtrace confirming
# virgl_cmd_resource_map_blob -> memory_region_transaction_commit -> vhost_commit.
#
# Safe because the backend never translates with those addresses: CONFIG_VHOST_XEN=y
# here and the GUEST kernel's vhost-Xen work -- 0004 of the xen_patchset series in
# meta-xt-doma/recipes-kernel/linux/files, not a qemu patch; the fork's qemu tree
# has no vhost-Xen code at all -- redirects core vhost's translate_desc() to
# vhost_xen_map_desc(), which maps by domid. The same module already logs
# "Skip pseudo memory region for Xen grant mappings" for these table entries.
#
# Not Venus-specific -- any post-start memory topology change does it, and it is
# only unreached otherwise because vhost_dev_start() commits before setting
# ->started. Nor is it avoidable from the config side: DomA has three vhost users
# (two vhost-net plus the VHAL's vhost-vsock), and vhost=off on the netdevs just
# moves the abort to the vsock device (region 0 -> region 2, measured).
SRC_URI:append:class-target = " file://0119-vhost-do-not-verify-vring-host-mappings-under-Xen.patch"

# 0120: the RPi4 DomA kernel panics in virtio_pci (vp_interrupt readb of the ISR
# page, vp_notify writew of the notify page) with ESR 0x96000000 -- ISS=0, which
# is Xen's synthesised data abort for an MMIO access no ioreq server covers,
# not a real translation fault (the guest's PTE is valid). Twelve panics across
# three PCI functions, vhost on or off, on GL after hours and on Venus after
# minutes: Venus multiplies the memory-topology commits, and with them the
# per-FlatRange map/unmap churn that leaves a 4 KiB hole in Xen's merged ioreq
# rangeset (map rejects a partial overlap with -EEXIST; qemu discards the rc).
#
# This is the same defect meta-xt-driver-domain's 0110 fixes for the 7.0.0
# device model on RPi5, and that patch is (correctly) PV-gated to 7.x, so it
# never reaches the 10.0.2 device model. 0120 is 0110 re-based onto
# include/hw/xen/xen_native.h (xen_common.h was renamed in qemu 8.2); the code
# is otherwise identical: check the DMOP rc, log it, and on -EEXIST unmap the
# exact span and map it again as one clean range.
SRC_URI:append:class-target = " file://0120-xen-do-not-silently-drop-IOREQ-MMIO-range-registrati.patch"

# 0121: Venus rings/reply shmem are memfd-backed blobs that 0116 shared into the
# guest by frame number with only mlock() holding the pages, and DomD's kernel
# migrates pages freely (compaction, khugepaged). A migrated shared frame leaves
# the guest writing the old page while the render server reads the new one: the
# host decodes an all-zero command chunk, declares the context fatal, and the
# guest ICD aborts in vn_relax -- SurfaceFlinger dies, zygote restarts, the boot
# animation replays. Measured on RPi4 2026-09-12; vm.compact_unevictable_allowed=0
# on DomD stopped it, which is what named the mechanism. 0121 wraps the memfd in a
# udmabuf (a real pin) and hands the dma-buf to the gntdev route 0116 already has.
# If the pin cannot be had (no /dev/udmabuf, an unsealable memfd) it vetoes the
# share rather than falling back to the unpinned route, so the guest gets
# VK_ERROR_MEMORY_MAP_FAILED instead of a ring that corrupts minutes later.
SRC_URI:append:class-target = " file://0121-virtio-gpu-xen-pin-shmem-blobs-through-udmabuf-before-.patch"

# The berkeley wraps carry `patch_directory = <name>`, which is meson's way of
# saying "the build files live in subprojects/packagefiles/<name>, not upstream".
# Nothing in those directories is a patch -- they are a meson.build plus a
# meson_options.txt -- so replicating what meson does on download is a copy.
# keycodemapdb has no patch_directory and needs nothing.
#
# Without this the two subprojects are present but have no meson.build, and
# do_configure fails inside meson instead of inside configure.
do_configure:prepend() {
    for sp in berkeley-softfloat-3 berkeley-testfloat-3; do
        cp -a ${S}/subprojects/packagefiles/$sp/. ${S}/subprojects/$sp/
    done
}

# qemu changed both license files between 10.0.2 and 10.2.0, so the inherited
# LIC_FILES_CHKSUM does not match these sources and do_configure would fail on it.
# Measured at this SRCREV (and identical to upstream's v10.0.2 tag, i.e. the fork
# did not touch them) -- and they happen to be the same values qemu_7.0.0.bb uses,
# because the change landed after 10.0.2:
#     COPYING                 441c28d2cf86e15a37fa47e15a72fbac  (10.2.0: a3b50d8b...)
#     COPYING.LIB endline=24  8c5efda6cf1e1b03dcfd0e6c0d271c7f  (10.2.0: 8a8178c0...)
LIC_FILES_CHKSUM = "file://COPYING;md5=441c28d2cf86e15a37fa47e15a72fbac \
                    file://COPYING.LIB;endline=24;md5=8c5efda6cf1e1b03dcfd0e6c0d271c7f \
                    "

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

# ---------------------------------------------------------------------------
# virtio-media and the Xen/virgl work the hardware decoder needs.
#
# Listed here one per line like the patches above, because this recipe is the
# one place that knows which qemu this product builds. The decode bring-up's
# 0210 (IOREQ MMIO self-heal) and 0211 (virtio-input BTN_TOUCH) are not
# carried: 0120 and 0118 above are the same two fixes, written against this
# recipe.
# ---------------------------------------------------------------------------
SRC_URI:append:class-target = " file://0201-v10-xen-keep-the-autostart-device-model-alive.patch"

SRC_URI:append:class-target = " file://0215-v10-xen-pvh-common-one-INTX-line-per-virtio-pci-slot.patch"

SRC_URI:append:class-target = " file://0216-v10-hw-virtio-add-a-native-virtio-media-device.patch"

# 0220-v10: DomA -> HDMI audio. The alsa backend in 10.0.2 switched
# .buffer_get_free from audio_generic_buffer_get_free to alsa_buffer_get_free,
# so when the host has no free space audio_run_out() stops calling virtio-snd's
# callback. virtio-snd's policy is "do not return TX until it is fully
# consumed", so the guest's ring fills up and it reopens at 23 Hz (measured
# 2026-09-04). It restores the 7.0 op-table entry and deletes
# alsa_buffer_get_free(), which is then left without a user.
# That measurement predates DomD kernel patch 0016, when the HDMI audio DMA
# did not reach the MAI FIFO, so it does not show 10.0.2's report failing on
# its own. The patch is kept because doma.cfg's audiodev values were chosen
# with it (see the patch's description).
SRC_URI:append:class-target = " file://0220-v10-audio-alsa-report-the-generic-buffer-as-free.patch"

# 0222: move the commandq processing into a BH. On Xen/Arm even an MMIO write
#   leaves the guest vCPU descheduled until the ioreq completes
#   (ioreq_needs_completion() excludes only PIO writes), and qemu can complete
#   an ioreq only from the main loop (xen_io_listener has no .eventfd_add, i.e.
#   no ioeventfd). So doing a host V4L2 ioctl and a 942 KB copy inside the vq
#   handler stops the MMIO of every other DomA device for that whole time.
#   virtio-gpu already moves this into a BH for the same reason.
# 0223: narrow the host-side drain with poll's revents. Measured 77 wasted
#   ioctls per frame (DQEVENT fails 100 % of the time, 96 % of DQBUF is EAGAIN).
#   A standalone m2m poll test confirmed a 66.7 % reduction for both vicodec
#   and bcm2835-codec.
SRC_URI:append:class-target = " file://0222-v10-virtio-media-defer-commands-to-a-bottom-half.patch"

SRC_URI:append:class-target = " file://0223-v10-virtio-media-drain-only-what-poll-reports.patch"

# 0224-v10: restore the 7.0 behaviour of the Xen mapcache. Since 9.1 the bucket
#   head entry is munmap'd as well once its lock drops to 0, so every 4 KiB
#   entry costs a privcmd foreign map plus a munmap (a hypercall pair). For
#   virtio-media's 942 KB/frame that measured about 6 ms/frame (the memcpy
#   itself is 0.6 ms). Grants are still unmapped the way upstream does it. The
#   DMA of virtio-blk/net/gpu takes the same path, so this helps beyond HW
#   decode. The fork reverted its own copy of this workaround in the commit
#   SRCREV_qemu pins; the patch says why it is back for foreign mappings.
# 0225-v10: coalesce physically contiguous SG entries in QBUF, so a contiguous
#   run of pages is mapped once.
SRC_URI:append:class-target = " file://0224-v10-xen-mapcache-keep-foreign-bucket-heads-mapped.patch"

SRC_URI:append:class-target = " file://0225-v10-virtio-media-coalesce-sg-runs.patch"

# 0226-v10 / 0227-v10: two patches attributed with perf (cpu-clock, on qemu
#   during HW playback), measured on the board, 2026-09-04.
# 0226: hash the mapcache reverse lookup (vaddr -> MapCacheRev). virtio-gpu
#   keeps every page of a live resource locked, so locked_entries runs into the
#   thousands, and the two linear scans per unmap are 7.5 % of qemu's CPU.
# 0227: V4L2_MEMORY_FLAG_NON_COHERENT on the host-side REQBUFS. A coherent vb2
#   MMAP is Normal-NC and reads at 678 MB/s (3469 MB/s when cached). The
#   942 KB/frame memcpy is 10.7 % of qemu's CPU. Pairs with 0015 on the DomD
#   kernel side (bcm2835-codec allow_cache_hints). If the driver does not
#   support it, vb2 just drops the flag and no harm is done (the log's
#   non_coherent=0/1 says which).
SRC_URI:append:class-target = " file://0226-v10-xen-mapcache-hash-the-reverse-entries.patch"

SRC_URI:append:class-target = " file://0227-v10-virtio-media-request-non-coherent-host-buffers.patch"

# 0228-v10: virtio-media transfers the decode result straight into the guest's
#   virgl resource. When the guest puts a virgl resource id in QBUF's
#   reserved2, as v4l2_codec2 does, DQBUF writes from the host buffer into the
#   GL texture with virgl_renderer_transfer_write_iov, which skips the 942 KB
#   copy into guest pages and the guest's TRANSFER_TO_HOST + WAIT (3 to
#   4.7 ms/frame). -device ...,host-xfer=off disables it.
SRC_URI:append:class-target = " file://0228-v10-virtio-media-direct-virgl-transfer.patch"

# 0229-v10: replace 0228's CPU tiling (glTexSubImage2D -> v3d_move_pixels) with
#   the GPU. The host capture buffer is exported as a dmabuf -> EGLImage
#   (LINEAR) -> glBlitFramebuffer into the virgl resource's texture, which v3d
#   turns into a TFU job (glCopyImageSubData would be a CPU copy on v3d). A
#   dedicated EGL context, and a fence guards QBUF.
#   -device ...,gpu-xfer=off disables it (falling back to 0228's path).
SRC_URI:append:class-target = " file://0229-v10-virtio-media-gpu-copy-into-virgl-resource.patch"

# 0230-v10: with gpu-xfer, CAPTURE stays coherent (the CPU never reads it, so
#   0227's cache maintenance is wasted).
SRC_URI:append:class-target = " file://0230-v10-virtio-media-coherent-capture-buffers-with-gpu-xfer.patch"

# 0231-v10: make CAPTURE NV12 on the host and convert it to RGBA in a GPU shader
#   (this avoids the order-10 allocation failure; the guest still sees RGBA).
#   host-nv12=off goes back.
SRC_URI:append:class-target = " file://0231-v10-virtio-media-host-nv12-capture-with-gpu-conversion.patch"

# 0232-v10: never unmap an IOREQ MMIO range. In the gap between region_del and
#   region_add a virtio-pci ISR read becomes a data abort and the guest panics
#   in vp_interrupt. Reproduced within seconds with an asynchronous/polling
#   driver. On -EEXIST it re-adds the span page by page, in place of 0120's
#   self-heal, whose unmap reopened that gap.
SRC_URI:append:class-target = " file://0232-v10-xen-never-unregister-ioreq-mmio-ranges.patch"

# 0233-v10: suppress the guest's notifications (kicks) while virtio-gpu-gl's
#   ctrl queue is being processed (the same idiom as virtio-blk). At 720p60 that
#   was 360 kicks/s, which this cuts down.
SRC_URI:append:class-target = " file://0233-v10-virtio-gpu-gl-suppress-notifications-while-draining.patch"

# 0234-v10: when virtio-media's host fd wakes on POLLERR alone (vb2: a queue
#   with no buffers), park the handler and restore it on QBUF/STREAMON. At
#   720p60 this was 2402 of the main loop's 3112 wakeups in 4 s.
SRC_URI:append:class-target = " file://0234-v10-virtio-media-park-fd-handler-on-pollerr.patch"

# 0235-v10: poll for retired fences every 1 ms instead of 10 ms. A guest
#   blocked on a fence waits for the next tick, and the 10 ms tick capped
#   1080p60 at 14.7 fps and 720p60 at 22 fps.
SRC_URI:append:class-target = " file://0235-v10-virtio-gpu-virgl-poll-retired-fences-every-1-ms.patch"

# 0236-v10: pin virtio-gpu's EDID refresh with the refresh_rate property (mHz).
#   The 75 Hz default made the guest SurfaceFlinger's vsync 75 Hz, which dropped
#   60 fps video to 37.5 Hz.
SRC_URI:append:class-target = " file://0236-v10-virtio-gpu-edid-refresh-rate-property.patch"

# 0242-v10: two levers for the host-side QBUF cost (gpu_wait 449 us / host
# ioctl 593 us, the latter over both queues, against 84 us native), both off by
# default and both turned on by the RPi4's DomA cfg: (a) output-coherent:
# rb.flags=0 for the host OUTPUT as well (vb2 syncs the whole sizeimage of
# 524288 while the copy is only 8 KB); (b) gpu-fence-fd: take the
# EGL_ANDROID_native_fence_sync fd at blit time, so QBUF only does poll(fd,0)
# (removing two eglMakeCurrent calls).
SRC_URI:append:class-target = " file://0242-v10-virtio-media-output-coherent-and-gpu-fence-fd.patch"

# Pairs with XT_DOMA_HWDEC_DEVARG = "decoder=hevc" (the shared xt-xen-cfg-doma
# default for raspberrypi5) and with XT_DOMA_HWDEC=true on the AOSP side, which
# installs android.hardware.media.c2@1.2-service-v4l2. All three are required:
# the guest-facing decoder, the device argument that selects it, and the Android
# component that drives it. 0217 comes after 0242, not next to 0216, because its
# hunks are anchored on code 0222..0242 add.
SRC_URI:append:class-target = " file://0217-v10-hw-virtio-media-add-a-stateful-decoder-mode.patch"

SRC_URI:append:class-target = " file://0218-v10-hw-virtio-media-drive-decoder-mode-with-the-v4l2request-hwaccel.patch"

# libavcodec for the decoder mode 0217 adds and 0218 drives, and ONLY for the
# Raspberry Pi 5.
#
# The two boards reach hardware decode through different host devices, and only one
# of them needs a codec library in the device model. On a Pi 4 the host device is
# bcm2835-codec, which is a STATEFUL V4L2 decoder, so 0216's plain one-node proxy is
# the whole path: the guest's stateful decoder maps onto a stateful host decoder and
# nothing parses the bitstream in qemu. BCM2712's only decode block is codec@800000
# driven by rpi-hevc-dec, and that is STATELESS -- a media device plus a request fd
# per frame, with the caller expected to parse the bitstream and build the DPB.
# virtio-media cannot carry either: its protocol has five commands and no file
# descriptors, and Android's external/v4l2_codec2 has no stateless support at all.
# So 0217 converts on the host, offering the guest an ordinary stateful HEVC decoder
# and letting libavcodec do the stateless driving.
#
# rpidistro-ffmpeg rather than poky's ffmpeg: only the Raspberry Pi fork carries the
# v4l2request hwaccel that 0218 uses. Named as the RECIPE, so PREFERRED_PROVIDER is
# not involved -- that only decides who provides the virtual `ffmpeg`, and this
# DEPENDS is unambiguous on its own.
#
# The dependency is what turns decoder mode on, not a configure switch: meson finds
# the three libraries with pkg-config, and the file 0217 adds stubs itself out when
# they are absent. That is why the Pi 4 binary is unaffected even though the patches
# are applied for both boards -- it gets the stub, and its device argument
# (XT_DOMA_HWDEC_DEVARG, v4l2-device=/dev/video10) never selects decoder mode.
DEPENDS:append:raspberrypi5 = " rpidistro-ffmpeg"

# 0219-v10: the board run that produced the 0218 measurements then died on the
# fourth input buffer. Decoder mode failed VIDIOC_QBUF while libavcodec was full
# -- an OUTPUT queue is a queue, and v4l2_codec2 treats a QBUF failure as fatal
# (pumpDecodeRequest -> state Error). Input is backlogged instead now. Must stay
# after 0218: it patches the dec_qbuf/dec_pump that 0217 adds.
SRC_URI:append:class-target = " file://0219-v10-hw-virtio-media-do-not-fail-an-OUTPUT-QBUF-when-the-decoder-is-full.patch"

# 0244-v10: the OUTPUT buffer timestamp was never returned to the guest, so
# v4l2_codec2 lost every decode callback after the first (its bitstreamId rides
# in that field) and stopped recycling output buffers -- instrumented guest side
# showed the surface pool saturated at max=23 cur=23. Must stay after 0219.
SRC_URI:append:class-target = " file://0244-v10-hw-virtio-media-return-the-OUTPUT-buffer-timestamp-on-completion.patch"

# 0245-v10: the decode was already right (0219/0244) and the picture was still
# black. This is the display half: RGBA out, because DomA's virgl GL has no
# GL_EXT_YUV_target and cannot sample NV12 at all, plus 0228's direct
# virgl transfer from decoder mode, because virtio-media writes the guest pages
# while the compositor samples the host resource. Must stay after 0244.
SRC_URI:append:class-target = " file://0245-v10-hw-virtio-media-give-decoder-mode-an-RGBA-output-and-the-direct-virgl-transfer.patch"

# 0243-v10: HDMI audio goes completely silent during 1080p30 HW decode. Draining
# TX depends on the audio backend's main-loop callback, and the same main loop
# is turning virtio-media's QBUF, so it is delayed: the guest's PCM write blocks
# for up to 89 ms, the HAL's ring overflows, and AudioFlinger's data is thrown
# away (measured with strace and a recording tap, 2026-09-16). ioeventfd gives
# no fast path under Xen (xen_io_listener has no .eventfd_add), so this cannot
# be handed to an iothread. Instead a dedicated thread runs the
# same drain function. Off by default. On the board it is enabled by adding
# tx-poll-us=10000 to virtio-snd in doma.cfg.
SRC_URI:append:class-target = " file://0243-v10-virtio-snd-drain-tx-from-a-dedicated-thread.patch"
# 0122: 0115 reads the virtio-pci layout from xenstore and 0215 can hand out one
# INTX line per slot, but nothing passed the count between them -- the GPEX stayed
# at four lines however many the guest DT declared, which pairs slots onto shared
# level-triggered SPIs and stalls virtio-snd and the decoder. libxl already
# publishes num_irqs; this reads it.
SRC_URI:append:class-target = " file://0122-hw-arm-pass-the-virtio-pci-INTX-line-count-to-the-GPEX.patch"

# 0246-v10: host-max-width=N lets 0231's NV12 -> RGBA shader scale a frame wider
# than N down to N (both axes by the width ratio, the compose rectangle with
# it), so a 1080p stream reaches a 1280x720 DomA already at display size instead
# of as 8.4 MB of RGBA that SurfaceFlinger then scales. It applies to every
# decode wider than N, displayed or not. Off (0) by default, and meant to be
# set per board from DomA's display width, in the board layer's
# xt-xen-cfg-doma_%.bbappend. Measured on the RPi4 at 1080p30 with the
# guest's frame rate override off: SF 27.1-28.8 -> 29.2-29.7 fps, missed
# 5.3-7.8 -> 0.9-1.3/s. Its context is 0231, 0242 and 0217, so it stays after
# them.
SRC_URI:append:class-target = " file://0246-v10-hw-virtio-media-let-host-nv12-scale-the-frame-down-to-the-display.patch"

# 0247-v10: gpu_draw_nv12() redraws the whole RGBA target with one triangle but
# never invalidated it, so V3D loaded the old target into its tile buffer before
# every draw (3.7 MB at the RPi4's 1280x720, 8.4 MB at 1920x1088).
# glInvalidateFramebuffer after the completeness check lets Mesa's v3d skip that
# load. Measured on the RPi4 (host-max-width=1280), decode only: qemu's V3D
# render per frame 3.21 -> 2.77 ms at 1080p60, 1.25 -> 0.99 ms at 720p60. Its
# context is 0231's; the line numbers assume 0246, so it stays after it.
SRC_URI:append:class-target = " file://0247-v10-hw-virtio-media-invalidate-the-RGBA-target-before-the-NV12-draw.patch"

# 0248-v10: raise virtio-gpu's control-queue interrupt once per batch instead of per
#   response. Under Xen the guest's ISR read is a synchronous ioreq to this main loop;
#   raised mid-batch it waited for the rest of the batch (RPi4 DomA: 430 us per
#   virtio-gpu interrupt vs a 45-60 us round trip, 16% of a guest CPU).
SRC_URI:append:class-target = " file://0248-v10-virtio-gpu-coalesce-control-queue-notifications.patch"

# 0249-v10: fenced SUBMIT_3D from a Venus guest carries INFO_RING_IDX (a fence on a
#   context ring); create a virgl context fence for it instead of a ctx0 EGL fence
#   (RPi4 DomA: ~150/s, each an EGL sync on the main thread).
SRC_URI:append:class-target = " file://0249-v10-virtio-gpu-virgl-honour-ring-idx-with-context-fences.patch"
