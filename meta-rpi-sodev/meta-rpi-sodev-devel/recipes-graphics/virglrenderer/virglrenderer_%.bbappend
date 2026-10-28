# DIAGNOSTIC virglrenderer patches, kept out of the product layer.
#
# Both are instruments for Venus command-stream failures whose causes are known
# and fixed: an unexportable gralloc buffer (0017/0018) and DomD page migration
# of shmem-backed blobs (qemu 0121), with the guest's allocation sizes bounded
# by 0021 (VKR_DEVICE_HEAP_MIB). They are kept here rather than dropped: no
# default build references meta-rpi-sodev-devel (see this layer's README and
# build.sh --devel), and the next person to debug this stack should not have to
# rewrite them.
#
# 0015: name the failing command when the command stream goes fatal. Changes
# nothing on a healthy stream. It exists because the stock logs cannot be trusted
# past a context's first fault -- cs_fatal_error is one sticky bool shared by every
# decoder and encoder (struct vkr_context in vkr_context.h) -- and because the
# build is -DNDEBUG, so
# vkr_cs_decoder_sanity_check()'s assert(dec->cur <= dec->end) is inert at all four
# call sites. 0015 dumps the offending command's ring coordinates and leading bytes
# and makes that one assert live. NOTE that a live assert means the render server
# aborts on a desync instead of limping on, which is what you want while measuring
# and not what you want in a product.
#
# 0019: log guest vkAllocateMemory requests of 64 MiB or more (context, size,
# memory type). This is the instrument that closed the DomD reclaim livelock: with
# VKR_DEVICE_HEAP_MIB=1088 in doma.cfg the expected reading is ZERO such lines, and
# a non-zero count means the guest allocator went back to heap/8 blocks. Harmless,
# but it is a debug log line per large allocation, so it does not belong in a
# shipping device model either.
#
# APPLY ORDER. This layer and meta-xt-driver-domain have the same BBFILE_PRIORITY
# (20), so which bbappend's SRC_URI lands first is decided by the bblayers order;
# with the devel layer added last (how build.sh --devel adds it) these two are
# applied AFTER the product series (0002/0009/0016/0017/0018/0021/0022/0023/0025 on
# 1.2.0). Verified in that order with `patch -p1 --fuzz=0` against a pristine 1.2.0
# tree, and on 1.3.0 after its series. The three files they share with the product
# series are touched in different places: 0015's vkr_ring.c hunk is inside
# vkr_ring_submit_cmd(), which 0022/0023/0025 leave alone; 0015 adds a
# function to vkr_cs.h near vkr_cs_decoder_set_buffer_stream() while 0016 edits
# vkr_cs_decoder_lookup_object() further down, and 0019's hunk is in
# vkr_dispatch_vkAllocateMemory() while 0017's is in
# vkr_dispatch_vkGetMemoryResourcePropertiesMESA(), further down the same file.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Gated on the venus DISTRO_FEATURE for the same reason the product bbappend gates its
# own series: both patches are Venus diagnostics, and a --gpu=gl build (even with
# --devel) is meant to be the pre-Venus stack.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'venus', \
    'file://0015-vkr-name-the-failing-command-when-the-command-stream-.patch \
     file://0019-vkr-log-guest-device-memory-allocations-of-64-MiB-an.patch', '', d)}"
