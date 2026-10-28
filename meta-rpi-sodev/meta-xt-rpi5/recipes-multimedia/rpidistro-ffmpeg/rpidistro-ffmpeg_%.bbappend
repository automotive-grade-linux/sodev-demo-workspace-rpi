# SPDX-License-Identifier: MIT
# Turn the SAND/COL128 support back on for DomA's HEVC hardware-decode path.
#
# THE GATE. rpidistro-ffmpeg's default PACKAGECONFIG adds `mmal sand vout-drm`
# only when vc4graphics is ABSENT from MACHINE_FEATURES. On this board it is
# always present -- meta-raspberrypi's rpi-base.inc appends it unless
# DISABLE_VC4GRAPHICS is 1, and nothing in this workspace sets that (measured:
# zero hits in yocto/build-dom*/conf and in meta-rpi-sodev). So `sand` is off,
# silently.
#
# WHY THAT BREAKS HEVC DECODE. rpi-hevc-dec's CAPTURE queue offers only the
# COL128 formats -- NV12_COL128, NV12_10_COL128, NV12MT_COL128, NV12MT_10_COL128
# -- and no linear NV12. Without CONFIG_SAND:
#
#   1. the fork's V4L2-to-DRM descriptor conversion falls into `default: return
#      -1` for V4L2_PIX_FMT_NV12_COL128, so the hwaccel cannot even describe the
#      frame;
#   2. libavutil/rpi_sand_fns.o is not built (OBJS-$(CONFIG_SAND)), which is
#      where av_rpi_sand_to_planar_frame() and the AArch64 NEON detiling live;
#   3. libavfilter/vf_unsand.o is not built either -- configure derives
#      unsand_filter_select from "sand".
#
# And the host needs it, not the guest: qemu's decoder mode gets each frame as a
# DRM frame (1.), and a frame it brings back to the CPU with
# av_hwframe_transfer_data() lands in YUV420P, detiled by
# av_rpi_sand_to_planar_frame() (the code in 2); libswscale then converts that to
# RGBA. The guest never sees a COL128 format; it gets the formats decoder mode
# offers.
#
# `mmal` and `vout-drm` are deliberately NOT restored with it. mmal is the
# VideoCore MMAL/OMX path, which needs the closed userland blobs and is
# BCM2711-era; this SoC has no vchiq node at all. vout-drm is an ffmpeg output
# device for local display, irrelevant to decode-only use. Restoring the whole
# conditional would drag both in.
#
# --enable-v4l2-request needs no help: the recipe hardcodes it in EXTRA_OECONF,
# and the v4l-request/drm/udev PACKAGECONFIGs are in the default set, which is
# where configure's libdrm and libudev dependencies come from.
PACKAGECONFIG:append:raspberrypi5 = " sand"

# The one-buffer SAND (NV12_COL128) for 8-bit HEVC, not the two-buffer NV12MT_COL128
# that rpi-hevc-dec lists first: qemu's GL import of a SAND frame (the Raspberry Pi 4
# proxy's, q11-059) takes one dmabuf with the chroma at an offset, the layout
# bcm2835-codec gives. See the patch.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:raspberrypi5 = " file://0001-v4l2request-hevc-take-the-one-buffer-SAND-for-8-bit-output.patch"

# A bounded wait for a free destination buffer: qemu's decoder mode decodes on its
# decode thread (q11-083), and a frame the display holds is let go only on qemu's
# main loop, which may itself be waiting for that thread (a stop, a codec switch), so
# an unbounded wait there could not end. See the patch, whose description is of the
# decode on the main loop it was written for.
SRC_URI:append:raspberrypi5 = " file://0002-v4l2request-bound-the-wait-for-a-free-destination-buffer.patch"
