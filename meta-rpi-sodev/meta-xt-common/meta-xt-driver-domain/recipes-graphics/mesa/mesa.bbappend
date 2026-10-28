# wrynose: renamed from mesa_%.bbappend. wrynose mesa is versionless (mesa.bb),
# which a _% (underscore-version) bbappend does NOT match; mesa.bbappend does
# (cf. meta-raspberrypi/meta-selinux both use mesa.bbappend).
#
# Enable glvnd in mesa so the vendor-neutral GL dispatch libraries
# (libOpenGL.so.0 / libEGL.so.1 / libGLESv2.so.2 via libglvnd) are produced.
# The DomD qemu device-model (-display sdl,gl=es + virtio-gpu-gl/virgl) probes
# "libGL.so.1 or libOpenGL.so.0"; without glvnd this wayland-only (x11 removed)
# mesa builds neither, so the GL display init fails. With glvnd, libglvnd provides
# libOpenGL.so.0 (libGL.so.1 needs glx/x11, not built here) which satisfies the probe,
# and libegl-mesa ships the egl_vendor.d JSON so weston's EGL still routes to mesa V3D.
PACKAGECONFIG:append = " glvnd"

# ---------------------------------------------------------------------------
# TEMPORARY VERSION PIN AHEAD OF POKY: mesa 26.0.5 -> 26.2.4
#
# Why: v3dv in 26.0.5 submits a real, fully-serialised V3D control-list job for
# every vkQueueSubmit that signals a semaphore, purely to satisfy Vulkan's
# signal-operation-order rules ("Finish by submitting a no-op job that
# synchronizes across all queues"). Measured on this board, the AGL cluster on
# Venus/Vulkan issues ONE render pass per frame but the host runs 11.1 bin jobs
# per frame; those extra ~10 are those empty jobs. They cost almost no GPU time
# but they cost a submit ioctl, kernel scheduling and a cross-queue barrier each.
# See docs/VULKAN-VENUS.md section 7e.
#
# mesa MR !42407 ("v3dv: Re-implement noop jobs as cpu jobs", Igalia, merged
# 2026-06-29) replaces them with CPU-side syncobj merging
# (drmSyncobjExportSyncFile -> sync_merge -> drmSyncobjImportSyncFile) and
# deletes queue_submit_noop_job/job_emit_noop outright. It first ships in
# 26.2.0; it is NOT backported to 26.0.x or 26.1.x, and the MR's commits do not
# apply to 26.0.5 (they sit on top of that cycle's v3dv queue rework), so a
# version bump is the only way to get it. 26.2.0 also carries the required
# follow-up d4ee4a62885 ("honor wait dependencies for job-less submissions"),
# whose own description is this exact workload -- semaphore chaining with an
# empty command buffer.
#
# Verified on the 26.2.4 tarball (as before on 26.2.2):
#   queue_submit_noop_job / job_emit_noop / noop_job   -> 0 hits
#   drmSyncobjExportSyncFile / ...Import / sync_merge  -> present
#   v3dv_queue.c:1033                                  -> the src_count == 0 fix
#   sha256 matches docs.mesa3d.org/relnotes/26.2.4
#
# Revisit at the next poky upgrade: once poky's mesa is >= 26.2.0 this whole
# block goes away. Nothing else in this block is version-specific. The recipe's
# own source patches (egl/wayland, v3d and v3dv, at the end of this file) are not part
# of the pin, but they were written against 26.2.x, so re-check their do_patch at
# that upgrade.
# The guest-side venus/virgl patches live in meta-agl-venus (DomU's mesa 24.0.7)
# and are untouched by this pin.
# DELIBERATELY NOT gated on the venus DISTRO_FEATURE, unlike everything else
# this series adds. The reason is that both lanes run weston on the same V3DV,
# and the MR this pin is for (!42407) is a v3dv submit-path fix, not a Venus
# one -- so splitting the host GL/Vulkan driver by lane would mean shipping and
# testing two of them for no benefit. Consequence to state plainly: `--gpu=gl`
# is the pre-Venus device model and the pre-Venus memory map, but NOT the
# pre-Venus mesa. The gl lane was build-verified in this configuration.
# 26.2.4 (was 26.2.2); this layer's 3 patches below apply to it with patch -F 0.
PV = "26.2.4"
SRC_URI[sha256sum] = "bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9"

# poky's own patches, checked against 26.2.4 (same result as on 26.2.2):
#   0001-meson-misdetects-64bit-atomics-on-mips-clang.patch  -> still applies, kept
#   0001-gallivm-Fix-armhf-build-against-LLVM-22.patch       -> merged upstream (reverse-applies)
#   0001-freedreno-...-build-path-into-binaries.patch        -> context moved; it is a
#       build-reproducibility patch for freedreno, and this target builds
#       vulkan-drivers=broadcom,gfxstream,virtio with no freedreno/turnip, so nothing
#       of it can end up in our binaries. Rebasing it for a driver we do not build is
#       not worth carrying.
#
# The two names in the :remove below are poky's exact filenames at mesa 26.0.5. If a
# poky upgrade renames or drops either, the :remove stops matching -- and that failure
# is LOUD, not silent: do_patch then tries to apply a patch written for a different
# tree and stops. So a do_patch failure in this recipe after a poky bump means "re-check
# this block", not "the pin is broken".
SRC_URI:remove = "file://0001-gallivm-Fix-armhf-build-against-LLVM-22.patch file://0001-freedreno-don-t-encode-build-path-into-binaries.patch"

# egl/wayland: let a Wayland client allocate its scanout buffers on vc4.
# DomA's picture reaches HDMI through qemu's SDL window (doma.cfg '-display sdl,gl=es',
# both GPU lanes), which kiosk-shell makes fullscreen, and weston tries every repaint
# to put it straight on the vc4 primary plane. It fails: weston-debug drm-backend logs
# "couldn't get FB for view: gbm bo get handle failed" and weston composes the window
# with V3D instead (measured on the RPi4, 2026-09-23). qemu opens
# only v3d's render node, because weston advertises that as the dma-buf main device;
# without kmsro, v3d answers a SCANOUT allocation with non-contiguous memory that vc4
# (no IOMMU on BCM2711) cannot import. The patch checks whether the display-only
# device the scanout tranche names can import the buffer; if not, it allocates the
# buffer there as a dumb buffer and imports that into v3d. A device that can import
# (BCM2712's HVS sits behind an IOMMU) keeps the render GPU's buffer.
FILESEXTRAPATHS:prepend := "${THISDIR}/mesa:"
SRC_URI += "file://0001-egl-wayland-allocate-scanout-buffers-on-a-display-on.patch"

# v3d: fill the tiled blit temporary with the TFU instead of the CPU.
# qemu's SDL display blits DomA's (linear) scanout into its window with a y-flip
# every frame. A flipped blit from a linear source ends in v3d_render_blit, which
# copied the source into a tiled temporary with util_resource_copy_region: a CPU
# map that waits for the guest's rendering, then a software retile, on qemu's main
# thread -- the thread that also answers DomA's ioreqs. Measured on the RPi4
# (2026-09-24, V3D_DEBUG=perf + backtraces): ~20 blocking maps/s, qemu's main
# thread 19-29% in v3d_wait_bo_ioctl; with the patch none, and the guest
# compositor's frame time 14.7 -> 9.9 ms.
SRC_URI += "file://0002-v3d-fill-the-tiled-blit-temporary-with-the-TFU.patch"

# v3dv: build the signal fence once per submit and leave idle kernel queues out of it.
# Each signal of a submit used to repeat four sync_file exports and three merges; the
# AAOS WebView signals ~4 syncs per submit, and the other venus ring of the context spun
# in spin_wait_for_sync_file() meanwhile (RPi4, 2026-10-01: merges 4563 -> 26 per 10 s,
# spin iterations 1883 -> 474). See the patch.
SRC_URI += "file://0003-v3dv-build-the-signal-fence-once-per-submit.patch"
