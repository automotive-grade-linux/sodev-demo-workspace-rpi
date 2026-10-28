# Six patches for scarthgap's mesa 24.0.7 -- two to make Venus work at all, one
# performance proof of concept, 0004 for the receiver window's plane, and 0005 and
# 0006 for GL on zink. Each is measured, not assumed. 0001 and 0002 say below why
# wrynose's in-tree 26.x does not need them; 0003's and 0004's defects are still
# in 26.x, and 0005's and 0006's in DomD's 26.2.4 (0006 would have to be rewritten
# there: 26.x rebuilt the usage checks it edits).
#
# The filename is mesa_%.bbappend, so it also attaches to any FUTURE mesa in
# this AGL build. That is deliberate and is the same reasoning as the
# flutter-engine bbappend's: an AGL mesa uprev must fail do_patch loudly rather
# than silently drop the patches or, worse, apply a fix the new mesa already
# has. 0001 and 0002 are 24.0.7-only; 0003 has to be rebased rather than
# dropped, because virgl implements no query_dmabuf_modifiers in 26.x either,
# and without it the per-frame re-tile below comes back.
#
# 0001 is the enablement one. With the ICD built and installed, vkCreateInstance fails
#
#   MESA-VIRTIO: debug: required kernel param 5 is missing
#   MESA-VIRTIO: debug: vn_CreateInstance: VK_ERROR_INITIALIZATION_FAILED
#
# param 5 is VIRTGPU_PARAM_CROSS_DEVICE, which the kernel reports only when the device
# model advertises VIRTIO_GPU_F_RESOURCE_UUID -- and QEMU's virtio-gpu does not.
# Upstream mesa later made the feature optional and says so in the code it added:
# "Qemu doesn't support cross-device sharing." wrynose's 26.0.5 already has it, which
# is why the in-tree DomU works without this.
FILESEXTRAPATHS:prepend := "${THISDIR}/mesa:"
SRC_URI += "file://0001-venus-make-cross-device-optional.patch"

# The second backport is a correctness fix, not an enablement one. 24.0.7's venus
# suballocates small host-visible allocations out of a shared 16 MiB pool, and on the
# Pi 5 (whose renderer does not report has_guest_vram, so the pool is live) every
# buffer bound to a sub-range lands at the POOL BASE on the host -- two suballocated
# buffers alias. Measured in DomU: a fill aimed at one buffer landed entirely in
# another, venus' fence feedback went to the same place, and vkWaitForFences never
# returned. Upstream deletes the pool rather than fixing it -- 26.0.5 has no "pool"
# in vn_device_memory.c at all -- so wrynose's in-tree DomU is unaffected, same as
# with 0001.
SRC_URI += "file://0002-venus-do-not-suballocate-device-memory.patch"

# 0003: virgl never implemented pipe_screen::query_dmabuf_modifiers, so
# dri2_query_dma_buf_modifiers() returned zero modifiers for every format and a compositor on
# virgl could only advertise the implicit modifier -- confirmed on the board with
# weston-simple-dmabuf-feedback, which listed all 34 formats as "modifier NONE_INVALID".
#
# That is what makes guest Vulkan slow here. Venus' WSI, seeing no modifiers, takes the legacy
# path in vn_wsi.c and forces DRM_FORMAT_MOD_LINEAR on scanout images (it logs "forcing
# scanout image linear (no explicit modifier support)" under VN_DEBUG=wsi), and the tiled host
# GPU then re-tiles that image once per frame to sample it -- 2122 "Updating 1920x1080@0
# shadow for linear texture" in 40 s under V3D_DEBUG=perf, and the only reason the TFU engine
# appears in the Vulkan lane at all.
#
# The patch is a proof of concept: the modifier list should come from the host renderer, and
# virgl has no way to ask (union virgl_caps has no modifier table). See the patch header.
SRC_URI += "file://0003-virgl-enumerate-dma-buf-format-modifiers.patch"

# 0004: a gbm SCANOUT | LINEAR buffer (xdg-cluster-receiver's window) reaches the host as
# VIRGL_BIND_LINEAR, so virglrenderer's 0024 can give it a linear layout a display plane
# takes. See the patch.
SRC_URI += "file://0004-virgl-pass-PIPE_BIND_LINEAR-to-the-host.patch"

# 0005 and 0006: GL on zink (MESA_LOADER_DRIVER_OVERRIDE=zink, i.e. on Venus) --
# agl-compositor or a GL client run that way -- could not import the clients'
# buffers. 0005: a host V3DV from mesa 26.x pads a TRANSFER_SRC image by the TFU's
# 64-byte readahead, so zink asked more than a tightly sized dma-buf held and the
# import was refused. 0006: V3DV takes no input attachment on a linear image, so
# zink fell back to a tiled image for a linear dma-buf, which the clients' buffers
# have been since they go to the display planes. Neither changes anything for a
# process that does not load zink. See the patches.
SRC_URI += "file://0005-zink-import-a-dma-buf-short-of-the-TFU-readahead.patch"
SRC_URI += "file://0006-zink-keep-a-linear-image-linear-minus-input-usage.patch"
