# A Venus-compositing guest needs virglrenderer to be able to export a guest resource as
# a dma-buf, and that turns out to conflict with keeping GL fast on V3D. Both halves are
# below.
#
# virgl_egl_init_external() -- the path qemu takes once 0117 hands virglrenderer an
# EGLDisplay so Venus dma-bufs can be imported -- also initialises the global gbm, which
# switches every VIRGL_BIND_SHARED guest resource from a plain GL texture onto a GBM
# buffer object. That is what makes the resource exportable, and it is what an Android
# guest compositing with Vulkan requires: without it vrend_pipe_resource_export_fd() can
# only answer VIRGL_RESOURCE_FD_INVALID, every vkGetMemoryResourcePropertiesMESA fails
# with a CS error, and the guest's Venus aborts in vn_relax.
#
# The cost is that GBM allocation on V3D is forced linear and loses UIF tiling. Measured
# on this board with the AGL instrument cluster on GL: 60.0 fps / 0.32 host cores /
# 81.2 % GPU with gbm NULL, against 29.0 / 0.52 / 42.9 % with gbm initialised. A GL guest
# would pay half its frame rate for a feature it never uses, which is why the switch
# below is per device model and only DomA sets it.
#
# Four other ways to give venus an importable dma-buf were considered before qemu 0117
# (a guest-side linear fallback, a host blit, re-exporting through qemu, and a second
# EGLDisplay) and each was eliminated by source reading or by a built-and-measured
# probe; the one below is the only one that needs no guest change.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# PATCH NUMBERING. The numbers follow the upstream MR series this work grew out of, so
# the gaps are deliberate: those numbers belong to patches this layer does not carry --
# the diagnostics live in meta-rpi-sodev-devel and the tiled-GBM backport is not carried
# at all (see the last section of this file).
#
# EVERY patch below is gated on the venus DISTRO_FEATURE, with the same
# bb.utils.contains idiom the xen and kernel bbappends use.
#
# Not because any of them misbehaves without it -- 0002 is inert when no device model
# hands virglrenderer an EGLDisplay, and the vkr ones are not even compiled when
# -Dvenus=false -- but because `--gpu=gl` is meant to rebuild the stack this tree
# shipped before Venus. With the gate, that lane gets oe-core's virglrenderer with no
# additions from us, which is what makes it a fallback worth having. (bitbake records a
# contains() test in the task signature by its ANSWER, so this costs one extra
# signature, not a rehash on every distro-feature change.)

# Which of the two GBM behaviours a guest needs is decided per device model at run time,
# not at build time -- see the long comment in the patch itself. In short: an Android guest
# compositing with Vulkan needs the global gbm (it is what makes guest resources
# exportable as dma-bufs, without which venus aborts), while a GL guest loses half its
# frame rate to it (60.0 -> 29.0 fps measured on the AGL cluster). The device models are
# separate processes, so DomA sets VIRGL_EXTERNAL_GBM=1 in its qemu_envs and DomU does not.
#
# Removing the gbm assignment outright would spare a GL guest that cost, but it
# breaks the other direction: venus-blob-to-host-compositor (import) needs no gbm,
# while gralloc-resource-to-venus-context (export) does, and fails silently without
# one. That is why the switch below keeps the gbm init and makes it per device
# model instead.
#
# Permanent fix, for when both halves land in a release: virglrenderer MR 1654 (merged
# 2026-08-05) picks a tiled DRM format modifier through Vulkan and allocates with
# gbm_bo_create_with_modifiers, which would remove the linear penalty and this switch with
# it -- but only together with its paired mesa MR 43000 (first ships in mesa 26.3), which
# is what lets the GUEST report the same modifier. Without that pairing the host and the
# guest disagree and a Venus-composited screen is garbage; see the tiled-GBM section
# below, which is why that backport is not carried here.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0002-vrend-initialise-GBM-for-an-external-EGLDisplay-only-.patch', '', d)}"

# --- 0009: upstream 1fbd03b2 (MR 1561) ---------------------------------------------------
#
# 1.2.0's compatibility macros for the non-MINIGBM build give the minigbm-only
# flags **bit values that collide with the real libgbm**:
#
#     virglrenderer 1.2.0            mesa 26.2.2 src/gbm/main/gbm.h
#     GBM_BO_USE_TEXTURING (1<<5)    GBM_BO_USE_PROTECTED       = (1<<5)
#     GBM_BO_USE_CAMERA_WRITE (1<<6) GBM_BO_USE_FRONT_RENDERING = (1<<6)
#
# gbm.h is included first and these are enums, so the macros overwrite them
# afterwards. The result is that GBM_BO_USE_TEXTURING, which
# virgl_gbm_convert_flags() sets on every VIRGL_BIND_SAMPLER_VIEW resource, is
# read on the mesa side as **a request for a PROTECTED buffer** (by way of
# vrend_resource_gbm_init / vrend_format_can_sample in vrend_renderer.c).
# Upstream turned this into a `#ifndef X / #define X 0` no-op.
#
# This path is live in the shipping configuration: the PACKAGECONFIG
# `minigbm_allocation` (which the Vulkan lane adds) sets
# ENABLE_MINIGBM_ALLOCATION, and the same #if in 1.2.0 is taken. What it
# actually hits is the device model that initialises gbm through 0002 above
# (= DomA, VIRGL_EXTERNAL_GBM=1), and that is the default configuration itself.
# 0018 below assumes this macro is 0 (it deals with buffers that have only
# TEXTURING getting no gbm bo), so the order matters too.
#
# 0009 matches upstream commit 1fbd03b2 as code, subject and author included: no
# changed lines, no missing hunks, no additions. Its context lines differ only
# by the rebase onto 1.2.0, and `patch -p1 --fuzz=0` applies it to a pristine
# 1.2.0 in recipe order (0009 is in the upstream tag virglrenderer-1.3.0).

SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0009-vrend-Correct-minigbm-definitions.patch', '', d)}"

# --- upstream's tiled GBM allocation: tried, measured, NOT carried -----------
#
# The GBM allocation 0002 switches on is linear on V3D, and linear costs a
# GL-compositing guest half its frame rate (60.0 -> 29.0 fps, measured on the AGL
# cluster). Upstream's answer is to pick a tiled DRM format modifier through Vulkan
# and allocate with gbm_bo_create_with_modifiers -- virglrenderer MRs 1561 (commits
# 1fbd03b2, 025c3e9b, fcfb9f23, all three in virglrenderer-1.3.0), 1644 (4030daff)
# and 1654 (652e8d8b), those last two in no release tag -- and all five backport
# cleanly onto 1.2.0. On V3D they also need a local fix
# (gbm_bo_create_with_modifiers2 + GBM_BO_USE_RENDERING, because the v1 API implies
# GBM_BO_USE_SCANOUT and v3d then rejects every UIF modifier it is offered).
#
# They are not carried, for three reasons:
#
#  1. It corrupts a Venus-compositing guest's display. The guest imports its
#     gralloc buffers into Venus with the modifier its minigbm reports -- LINEAR,
#     because the stock virtio_gpu resource-info path carries no modifier -- while
#     the backport allocates every VIRGL_BIND_SHARED resource UIF on the host.
#     Vulkan renders linear pixels into a tiled buffer and the scanout shows tile
#     garbage (RPi4 DomA, 2026-09-12, host-side DRM framebuffer dump). The fix has
#     to come from the guest learning the real modifier (the mesa MR 43000 pairing,
#     first shipping in mesa 26.3), not from this side.
#  2. There is no configuration left that wants it. The global gbm is switched on
#     per device model by VIRGL_EXTERNAL_GBM, and only DomA's qemu_envs sets it
#     (doma.cfg) -- DomU never initialises gbm, so DomU's GL compositor never pays
#     the linear penalty. Both boards' AAOS products composite with GL in the default
#     configuration, so 1. would apply only to a DomA set back to Vulkan
#     compositing; and in the --gpu=gl configuration DomA's device model does not
#     set VIRGL_EXTERNAL_GBM either.
#  3. It does not apply alongside 0017. 0017's vrend_renderer.c hunk sits in the
#     resource path MR 1561/1654 rewrote, so with the backport applied first 0017
#     fails do_patch at fuzz=0 -- i.e. the knob could not be turned on without
#     rebasing a patch the default configuration depends on.
#
# Revive them together with a guest that reports its real modifier, and measure the
# scanout (a DRM framebuffer dump), not just the frame rate: the first reading of
# this feature was "60 fps, tiled allocations succeed" on a screen that was in fact
# wrong.

# --- Venus: a locking fix, and the three defects full-Vulkan DomA hit ---------
#
# 0016 fixes a genuine race: vkr_cs_decoder_lookup_object() reads obj->type AFTER
# object_mutex is released, while vkr_context_free_object() runs under that same
# mutex from another ring thread -- and the type is what decides whether the
# command is rejected as a fatal stream error. Found while investigating DomA's
# SurfaceFlinger context dying with "object 122 has type 19, not 9" (RPi4,
# 2026-09-08). Applied because the code is wrong on its own terms: it is NOT what
# that failure turned out to be (see 0017/0018 here and qemu 0121), and the
# failure reproduced with a single dispatch thread.
#
# The two instruments that failure was measured with -- the command-stream dump
# with a live sanity assert, and a log line per guest allocation >= 64 MiB -- are
# deliberately NOT here. They live in
# meta-rpi-sodev-devel/recipes-graphics/virglrenderer, which no default build
# parses; see that bbappend for what they print and why a shipping device model
# should not carry them.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0016-vkr-read-the-object-type-under-the-mutex-that-guards-.patch', '', d)}"

# 0017: with HWUI on Venus, a gralloc buffer that vrend backed with a plain GL
# texture cannot be exported as a dma-buf, the proxy never attaches it to the
# render-server context, and the guest's vkGetMemoryFdPropertiesKHR on it was a
# FATAL stream error -- system_server died in vn_relax uploading TaskSnapshot
# bitmaps (RPi4, 2026-09-12). Answer VK_ERROR_INVALID_EXTERNAL_HANDLE instead,
# and log why vrend_resource_gbm_init() skipped the resource.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0017-vkr-vrend-make-an-unexportable-guest-resource-survivab.patch', '', d)}"
# 0018: the cause behind 0017's symptom. Against Mesa's gbm.h GBM_BO_USE_TEXTURING
# is 0, so a SAMPLER_VIEW-only SHARED buffer (HWUI hardware bitmap / TaskSnapshot,
# bind 0x100008) converted to gbm usage 0 and never got a gbm bo -> not exportable
# -> Venus import impossible. Give such a buffer a linear bo.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0018-vrend-give-a-SAMPLER_VIEW-only-shared-buffer-a-gbm-bo-.patch', '', d)}"
# 0021: v3dv sizes its device-local heap from DomD's system RAM (645 MiB on a
# 1408 MiB DomD) and vkr forwards that number to the guest. The guest's Skia/VMA
# then takes heapSize/8 as its block size, because any heap of 1 GiB or less is
# a "small heap" to it (VMA_SMALL_HEAP_MAX_SIZE) -- and every block is a fully
# populated v3d BO in DomD. HWUI RenderThreads allocated such blocks by the
# handful (96 MiB each on a 1664 MiB DomD), DomD fell into a memory-reclaim
# livelock, the device model stopped servicing ioreqs and the guest soft-locked
# (eight stalls on RPi4, 2026-09-12).
# Above 1 GiB VMA switches to the 4 MiB preferredLargeHeapBlockSize Skia asks for
# and large images become dedicated allocations of their real size.
# VKR_DEVICE_HEAP_MIB forces the advertised device-local heap to exactly its value;
# doma.cfg qemu_envs sets 1088, the smallest round value above the threshold. Inert
# when the env is unset.
#
# Clamping the advertised heap to 512 MiB instead was measured and is not enough,
# because 512 MiB is still a small heap to VMA: the blocks became 64 MiB instead of
# 96 and DomD livelocked again on the screen-transition benchmark. Forcing the heap
# ABOVE the threshold is what actually bounds the guest, which is why there is one
# knob here and not two.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0021-vkr-force-the-advertised-device-local-heap-size.patch', '', d)}"

# 0022: the idle venus ring thread used to sleep in cnd_wait() with no bound, so one
# lost guest wake-up left guest and renderer waiting on each other until the guest
# aborted in vn_relax ~895 s later (RPi4 DomA WebView, four times on 2026-10-01).
# Bounded at 10 ms on a CLOCK_MONOTONIC cond; a rescued wake-up is logged as
# "no wake-up from the guest" so the loss rate stays measurable. See the patch.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0022-vkr-bound-the-idle-ring-wait-so-a-lost-guest-wake-up.patch', '', d)}"

# 0023: the guest rate-limits its notify to one per idle_timeout from when it sent it,
# while the ring thread could go idle sooner than that after a notify arrived and
# wiped it -- a submission in the gap sent nothing (a lost wake-up). Stay awake an
# idle_timeout after each notify. Also VKR_RING_IDLE_WAIT_MS for the 0022 bound and
# a late/never-sent count per rescue. See the patch.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0023-vkr-keep-the-ring-awake-an-idle-timeout-after-each-notify.patch', '', d)}"

# 0025: the ring thread's busy-wait between commands (15 yields, then sleeps from
# 10 us) from VKR_RING_RELAX ("<order>,<first sleep us>"), unset = upstream's. The
# guest configs set 0,100: on the Pi 5 the cluster's ring thread made ~24,000 yields a
# second. The cost: a command in the ~1.3 ms before the ring goes idle waits up to
# 0.4 ms instead of 40 us. See the patch.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0025-vkr-make-the-ring-thread-s-busy-wait-tunable.patch', '', d)}"

# virglrenderer 1.3.0 (the recipe from openembedded-core in this layer): 0009 is upstream there, and
# 0017's diagnostic hunk is ported to 1.3.0's vrend_resource_gbm_init (which also gained a gbm_layout_feat
# early-out: without VIRGL_GBM_LAYOUT_ENABLE / _FORCE_ENABLE a non-MINIGBM build gives no resource GBM backing).
SRC_URI:remove = "${@'file://0009-vrend-Correct-minigbm-definitions.patch file://0017-vkr-vrend-make-an-unexportable-guest-resource-survivab.patch' if d.getVar('PV').startswith('1.3') else ''}"
SRC_URI += "${@(bb.utils.contains('DISTRO_FEATURES', 'venus', 'file://0017-vkr-vrend-make-an-unexportable-guest-resource-survivab-v130.patch', '', d) if d.getVar('PV').startswith('1.3') else '')}"
