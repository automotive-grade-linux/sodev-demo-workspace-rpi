# SPDX-License-Identifier: MIT
#
# DomA's display on the Raspberry Pi 5 is a 1920x1080 HDMI monitor (HDMI-A-2).
# The resolution the guest gets is what the device model reports as ui_info, i.e.
# virtio-gpu-gl-pci's xres/yres here; AAOS has no resolution setting of its own and
# follows it. The weston side of the same change (HDMI-A-2's modeline) is in this
# layer's weston-init.bbappend, and the two must agree -- see there.
#
# The shared doma.cfg keeps the upstream 1920x720 and each board layer rewrites its
# own installed copy after do_install (the RPi4 to 1280x720, the Pi 5 here to
# 1920x1080). A postfunc, so it runs after the common recipe's own substitutions.
do_install[postfuncs] += "rpi5_doma_gpu_fhd"

RPI5_DOMA_GPU_RES_FROM ?= "xres=1920,yres=720"
RPI5_DOMA_GPU_RES ?= "xres=1920,yres=1080"

rpi5_doma_gpu_fhd:raspberrypi5() {
    cfg="${D}${sysconfdir}/xen/doma.cfg"
    [ -f "$cfg" ] || bbfatal "xt-xen-cfg-doma.bbappend (rpi5): $cfg not installed"
    n=$(grep -c "virtio-gpu-gl-pci,.*,${RPI5_DOMA_GPU_RES_FROM}" "$cfg")
    if [ "$n" != "1" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi5): expected one virtio-gpu line with \
'${RPI5_DOMA_GPU_RES_FROM}' in $cfg, found $n"
    fi
    sed -i "/virtio-gpu-gl-pci,/s|,${RPI5_DOMA_GPU_RES_FROM}|,${RPI5_DOMA_GPU_RES}|" "$cfg"
    n=$(grep -c "virtio-gpu-gl-pci,.*,${RPI5_DOMA_GPU_RES}" "$cfg")
    if [ "$n" != "1" ] || grep -q "${RPI5_DOMA_GPU_RES_FROM}" "$cfg"; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi5): the virtio-gpu resolution rewrite did not apply cleanly to $cfg"
    fi
    bbnote "xt-xen-cfg-doma.bbappend (rpi5): DomA virtio-gpu -> ${RPI5_DOMA_GPU_RES}"
}

# Default is a no-op, as for meta-xt-rpi4's postfuncs: bitbake gives a postfunc its
# flags from the unsuffixed definition, so without this one exec_func fails on
# every machine with "'NoneType' object has no attribute 'get'".
rpi5_doma_gpu_fhd() {
    :
}

do_install[vardeps] += "RPI5_DOMA_GPU_RES_FROM RPI5_DOMA_GPU_RES"

# DomA's overlay planes and primary-plane scaling, as on the Raspberry Pi 4 board the
# display path was measured on (2026-10-02 .. 10-13): three overlay planes let
# drm_hwcomposer scan the app and the system bars out as DEVICE layers instead of
# SurfaceFlinger compositing them on the GPU (with two planes on qemu 10.0.2, before the
# kernel refused a plane not shown whole, a 640x360 video in a WebView dropped 25% of
# its frames instead of 35%), and plane scaling lets it put a scaled video on the
# primary plane (local 720p60 in the HMI 40 -> 52-55 fps there). Both halves come from
# the common recipe. Plane scaling needs the qemu 11.1.2 device model, which this
# board's vulkan lane selects (rpi5-sodev.yaml); the common recipe stops the build with
# any other, so the gl lane (qemu 7.0.0, which also gets no overlays) keeps it at 0. On
# this board on their own (2026-10-15, no linear scanout buffers) SurfaceFlinger still
# composed one CLIENT layer and a SW-decoded H.264 1080p60 shown by the codec test did
# not get faster (-R 42.1-42.6 -> 38.2, -T 37.3-37.7 -> 38.1 fps).
# Defaults (?=), so a local.conf can override them. For an A/B without the overlays,
# set both to 0: plane scaling 1 with no overlay planes stops the build.
XT_DOMA_OVERLAY_PLANES ?= "3"
XT_DOMA_PLANE_SCALING ?= "${@'1' if d.getVar('XT_DM_QEMU_VERSION').startswith('11.') else '0'}"

# DomA's hardware-decoded HEVC reaches its RGBA buffer on the GPU, not the CPU: qemu's
# decoder mode imports each SAND frame into GL (q11-069; ffmpeg's 0001 makes the frame one
# dmabuf) and waits for the GPU through a fence fd. 1 imports it through EGL with the SAND
# modifier, 2 detiles it in a shader (texture height limits it to frames below 4K), 0 keeps
# the CPU conversion. qemu 10.0.2 has neither the path nor the host-sand property (it
# would refuse the device), so the default is 0 there, and rpi5_doma_hwdec_check
# stops the build for any other combination.
#
# 1 is the default because it measured fastest (RPi5, 2026-10-15, codec CLI, HEVC 1080p60,
# GL SurfaceFlinger, the AGL cluster running in DomU): decode only / decode and display
# 60.5-61.3 / 54.2-54.7 fps with 0, 74.2-75.4 / 53.1-55.0 with 2 and 133.8-136.9 /
# 66.3-66.5 with 1, the device model's main thread at about 17% of a core. (2 was
# measured before q11-069 deferred its GPU wait; 1 gave 91.9-95.3 / 58.3-59.1 then.)
RPI5_DOMA_HOST_SAND ?= "${@'1' if d.getVar('XT_DM_QEMU_VERSION').startswith('11.') else '0'}"

# DomA's H.264 is decoded in DomD too: 1 makes the device decoder=hevc+h264, and qemu
# 11.1.2's decoder mode decodes H.264 with libavcodec in software on a thread of its own,
# the frames reaching the guest on the GPU (q11-072..074). The Pi 5 has no H.264 block,
# so without it DomA's own software decoder, c2.android.avc, does the work on DomA's two
# vCPUs. Measured on the board (codec CLI, -T): H.264 1080p60 35.4 fps with c2.android.avc
# (2026-10-15), 60.6-60.8 with this (2026-10-16); HEVC unchanged. 0 leaves the device HEVC only.
# qemu 10.0.2's decoder mode takes "hevc" alone (it would refuse the device), so the
# default is 0 there and rpi5_doma_hwdec_check stops the build for 1.
# This append comes before the host-sand one: "+h264" belongs right after "decoder=hevc".
RPI5_DOMA_H264 ?= "${@'1' if d.getVar('XT_DM_QEMU_VERSION').startswith('11.') else '0'}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi5 = "${@'+h264' if d.getVar('RPI5_DOMA_H264') == '1' else ''}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi5 = "${@'' if d.getVar('RPI5_DOMA_HOST_SAND') == '0' else ',gpu-fence-fd=on,host-sand=' + d.getVar('RPI5_DOMA_HOST_SAND')}"

# A stream wider than DomA's display reaches DomA at the display's width: q11-076 lets
# qemu 11.1.2's decoder mode take host-max-width (q11-048), and the GPU conversion into
# DomA's RGBA buffer scales the frame down, so a 4K frame is a 1920x1080 buffer instead
# of a 3840x2160 one that DomA then composes down. Measured on the board (2026-10-16,
# codec CLI, HEVC 3840x2160 60p, -T): 47.3-48.1 fps with V3D 99% -> 56.4-60.5 fps; HEVC
# and H.264 1080p60 unchanged. The width comes from RPI5_DOMA_GPU_RES, as on the RPi4;
# 0 turns it off. qemu 10.0.2's decoder mode ignores the property, so the default is 0
# there and rpi5_doma_hwdec_check stops the build for another value.
RPI5_DOMA_HWDEC_MAX_W ?= "${@int(d.getVar('RPI5_DOMA_GPU_RES').split('xres=')[1].split(',')[0]) if d.getVar('XT_DM_QEMU_VERSION').startswith('11.') else 0}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi5 = "${@'' if d.getVar('RPI5_DOMA_HWDEC_MAX_W') == '0' else ',host-max-width=' + d.getVar('RPI5_DOMA_HWDEC_MAX_W')}"

do_install[prefuncs] += "rpi5_doma_hwdec_check"

rpi5_doma_hwdec_check:raspberrypi5() {
    case "${RPI5_DOMA_HOST_SAND}" in
    0) ;;
    1|2)
        case "${XT_DM_QEMU_VERSION}" in
        11.*) ;;
        *) bbfatal "RPI5_DOMA_HOST_SAND=${RPI5_DOMA_HOST_SAND} needs the qemu 11 device model (XT_DM_QEMU_VERSION is '${XT_DM_QEMU_VERSION}')" ;;
        esac
        ;;
    *) bbfatal "RPI5_DOMA_HOST_SAND must be 0, 1 or 2 (got '${RPI5_DOMA_HOST_SAND}')" ;;
    esac
    case "${RPI5_DOMA_H264}" in
    0) ;;
    1)
        case "${XT_DM_QEMU_VERSION}" in
        11.*) ;;
        *) bbfatal "RPI5_DOMA_H264=1 needs the qemu 11 device model (XT_DM_QEMU_VERSION is '${XT_DM_QEMU_VERSION}')" ;;
        esac
        ;;
    *) bbfatal "RPI5_DOMA_H264 must be 0 or 1 (got '${RPI5_DOMA_H264}')" ;;
    esac
    case "${RPI5_DOMA_HWDEC_MAX_W}" in
    0) ;;
    *[!0-9]*|'') bbfatal "RPI5_DOMA_HWDEC_MAX_W must be 0 or a width (got '${RPI5_DOMA_HWDEC_MAX_W}')" ;;
    *)
        [ "${RPI5_DOMA_HWDEC_MAX_W}" -ge 128 ] || bbfatal "RPI5_DOMA_HWDEC_MAX_W must be 0 or at least 128 (got '${RPI5_DOMA_HWDEC_MAX_W}')"
        case "${XT_DM_QEMU_VERSION}" in
        11.*) ;;
        *) bbfatal "RPI5_DOMA_HWDEC_MAX_W=${RPI5_DOMA_HWDEC_MAX_W} needs the qemu 11 device model (XT_DM_QEMU_VERSION is '${XT_DM_QEMU_VERSION}')" ;;
        esac
        ;;
    esac
}

# The default is a no-op, for the same reason as rpi5_doma_gpu_fhd's.
rpi5_doma_hwdec_check() {
    :
}
