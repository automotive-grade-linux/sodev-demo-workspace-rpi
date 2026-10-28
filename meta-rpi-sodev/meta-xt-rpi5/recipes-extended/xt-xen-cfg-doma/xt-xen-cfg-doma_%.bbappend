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
# not get faster (-R 42.1-42.6 -> 38.2, -T 37.3-37.7 -> 38.1 fps); with the display
# switches and linear scanout buffers as well, every layer of a WebView's HEVC 1080p60
# among the HMI went on a plane, five of them (2026-10-19, the product makefile's note
# on vendor.minigbm.scanout_linear).
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

# DomA's sound card writes its buffers out without the BQL (q11-092, the TX thread of
# tx-poll-us): the main loop of DomA's device model holds the BQL for the video's GPU
# work, and the thread then waited for it 15-66 ms while the ALSA output ran dry
# (2026-10-23, H.264 1080p60 in a WebView). tx-no-bql needs the ALSA audiodev with the
# mixing engine off, which also needs the fixed frequency, channels and format gone
# (qemu refuses them without the mixing engine). Measured on the board (2026-10-24, 10
# minutes a run, with the decoder mode's changes of that day, q11-086 and q11-087 among
# them, and with DomD's and DomA's vcpus pinned one per pcpu and DomA's device model on
# DomD's CPU 0, set at run time): the ALSA underruns qemu saw came to 0-3 a run, against
# 138-454 restarts of the ALSA stream with the mixing engine on (2026-10-23). 0 leaves
# both lines as they are; qemu 10.0.2 and 7.0.0 have no tx-no-bql, so the default is 0
# there.
#
# With it the ALSA buffer grows from 60 to 100 ms and the PCM starts once 60 ms are in
# it (threshold=60000, which needs q11-093: without it the threshold came to the whole
# buffer), instead of on the guest's first 40 ms buffer. Starting on that one, the PCM
# ran dry within 0.1 s of the start in three of four runs (the next buffer came 40.5 ms
# later in one of them); and 60 ms left 20 ms beside a 40 ms guest buffer. Measured on
# the board (2026-10-25, 10 minutes a run, a WebView's H.264 beside the HMI, then full
# screen; start threshold 2880 of 4800 frames read back from ALSA): 1 and 1 underruns,
# one at the first write of a playback whose PCM an earlier one had left in XRUN, the
# other mid-playback with no BQL hold over 5 ms before it; starting on the full 100 ms
# gave 0 and 1; 60 ms and no threshold 1-5 a run in four runs. doma.cfg records a 100 ms
# buffer as running but silent with the mixing engine on; here the output ran at 48,140
# frames a second with the buffer kept full. It was not listened to.
RPI5_DOMA_SND_TX_NO_BQL ?= "${@'1' if d.getVar('XT_DM_QEMU_VERSION').startswith('11.') else '0'}"
RPI5_DOMA_AUDIO_FIXED ?= "out.frequency=48000,out.channels=2,out.format=s16,"
do_install[postfuncs] += "rpi5_doma_snd_tx_no_bql"
do_install[vardeps] += "RPI5_DOMA_SND_TX_NO_BQL RPI5_DOMA_AUDIO_FIXED"

rpi5_doma_snd_tx_no_bql:raspberrypi5() {
    [ "${RPI5_DOMA_SND_TX_NO_BQL}" = 1 ] || return 0
    case "${XT_DM_QEMU_VERSION}" in
    11.*) ;;
    *) bbfatal "RPI5_DOMA_SND_TX_NO_BQL=1 needs the qemu 11 device model (XT_DM_QEMU_VERSION is '${XT_DM_QEMU_VERSION}')" ;;
    esac
    cfg="${D}${sysconfdir}/xen/doma.cfg"
    [ -f "$cfg" ] || bbfatal "xt-xen-cfg-doma.bbappend (rpi5): $cfg not installed"
    a=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -cF -- "${RPI5_DOMA_AUDIO_FIXED}" || true)
    v=$(grep "^[[:space:]]*'-device', 'virtio-sound-pci," "$cfg" | grep -cF -- "tx-poll-us=10000," || true)
    if [ "$a" != "1" ] || [ "$v" != "1" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi5): expected one '-audiodev' line with '${RPI5_DOMA_AUDIO_FIXED}' ($a) and one virtio-sound-pci line with tx-poll-us=10000, ($v) in $cfg"
    fi
    b=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -cF -- "out.buffer-length=60000,out.try-poll=off'" || true)
    [ "$b" = "1" ] || bbfatal "xt-xen-cfg-doma.bbappend (rpi5): expected one '-audiodev' line ending in out.buffer-length=60000,out.try-poll=off ($b) in $cfg"
    sed -i -e "/^[[:space:]]*'-audiodev',/s|${RPI5_DOMA_AUDIO_FIXED}|out.mixing-engine=off,|" \
           -e "/^[[:space:]]*'-audiodev',/s|out.buffer-length=60000,out.try-poll=off'|out.buffer-length=100000,out.try-poll=off,threshold=60000'|" \
           -e "/^[[:space:]]*'-device', 'virtio-sound-pci,/s|tx-poll-us=10000,|tx-poll-us=10000,tx-no-bql=on,|" "$cfg"
    a=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -F -- "out.mixing-engine=off," | grep -cF -- "out.buffer-length=100000,out.try-poll=off,threshold=60000'" || true)
    v=$(grep "^[[:space:]]*'-device', 'virtio-sound-pci," "$cfg" | grep -cF -- "tx-poll-us=10000,tx-no-bql=on," || true)
    if [ "$a" != "1" ] || [ "$v" != "1" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi5): the tx-no-bql rewrite did not apply cleanly to $cfg"
    fi
    bbnote "xt-xen-cfg-doma.bbappend (rpi5): DomA's sound card writes without the BQL (tx-no-bql)"
}

# The default is a no-op, for the same reason as rpi5_doma_gpu_fhd's.
rpi5_doma_snd_tx_no_bql() {
    :
}

# The H.264 software decoder's two frame threads (RPI5_DOMA_H264) run at the device
# model's nice value, -19 (q11-094), by decision (2026-10-27): the threads DomA waits for
# are kept ahead of them another way, the ioreq thread at SCHED_FIFO (XT_QEMU_IOREQ_FIFO),
# and the nice value alone does not change how often the frame threads lose the CPU
# (about 27-29 times a frame at -10, -15, -19 and -20; the others wake up far more often
# than they run). With -19, weston at -19 on CPU 0 and the ioreq thread at FIFO 49,
# a WebView's H.264 1080p60 beside the HMI played three runs with no ALSA XRUN and no PCM
# restart in steady playback (DomA and DomD time-aligned, 2026-10-27). Empty leaves
# them at the device model's nice value.
RPI5_DOMA_H264_NICE ?= "${@'-19' if d.getVar('RPI5_DOMA_H264') == '1' else ''}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi5 = "${@',dec-sw-nice=' + d.getVar('RPI5_DOMA_H264_NICE') if d.getVar('RPI5_DOMA_H264_NICE') else ''}"

# The same two frame threads run on both of DomD's CPUs (q11-095), out of the device
# model's CPU 0 (the DomD qemu wrapper's taskset -c 0). Kept to CPU 1, they had CPU 1
# to themselves only in name: DomU's device model, its ioreq thread and DomU's Venus
# ring thread run there too, and Xen takes pcpu 1 to DomU's vcpu as well. On a
# Raspberry Pi 5 (2026-10-27, H.264 1080p60 in a WebView with sound, 60 s a run) CPU 1
# was idle 56 ms a second and stolen 88 ms, CPU 0 idle 710 ms, and each frame thread
# waited 510 ms a second for CPU 1. The decoder then gave 51-52 frames a second
# where the stream has 60, Chromium's video renderer ran out of frames
# (DECODER_UNDERFLOW) and stopped the picture for 1-1.6 s, 15-16 times a minute.
# With 0-1 it gave 54-59 frames a second and stopped 2-12 times. The reason they had
# been kept off CPU 0 is gone: on 2026-10-24 0-1 made the main loop hold the BQL over
# 50 ms 287 and 204 times in 10 minutes; with q11-088, q11-089, q11-090 and DomD
# kernel 0017 it held it over 50 ms 0 times and over 20 ms 5 and 3 times (H.264
# 1080p60 beside the HMI and full screen, 560 s each), with no ALSA under-run. Empty
# leaves them at the device model's affinity.
RPI5_DOMA_H264_CPUS ?= "${@'0-1' if d.getVar('RPI5_DOMA_H264') == '1' else ''}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi5 = "${@',dec-sw-cpus=' + d.getVar('RPI5_DOMA_H264_CPUS') if d.getVar('RPI5_DOMA_H264_CPUS') else ''}"

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
    case "${RPI5_DOMA_H264_NICE}" in
    '') ;;
    -[0-9]|-1[0-9]|-20|[0-9]|1[0-9])
        [ "${RPI5_DOMA_H264}" = 1 ] || bbfatal "RPI5_DOMA_H264_NICE=${RPI5_DOMA_H264_NICE} needs RPI5_DOMA_H264=1 (it is '${RPI5_DOMA_H264}')"
        ;;
    *) bbfatal "RPI5_DOMA_H264_NICE must be empty or a nice value, -20 to 19 (got '${RPI5_DOMA_H264_NICE}')" ;;
    esac
    case "${RPI5_DOMA_H264_CPUS}" in
    '') ;;
    *[!0-9-]*|-*|*-|*-*-*) bbfatal "RPI5_DOMA_H264_CPUS must be empty, a CPU or a range of CPUs, N or N-M (got '${RPI5_DOMA_H264_CPUS}')" ;;
    *)
        [ "${RPI5_DOMA_H264}" = 1 ] || bbfatal "RPI5_DOMA_H264_CPUS=${RPI5_DOMA_H264_CPUS} needs RPI5_DOMA_H264=1 (it is '${RPI5_DOMA_H264}')"
        # DomD has 2 vCPUs (its dom0less node's cpus): CPU 0 and CPU 1
        c="${RPI5_DOMA_H264_CPUS}"
        [ "${c%-*}" -le "${c#*-}" ] && [ "${c#*-}" -le 1 ] || \
            bbfatal "RPI5_DOMA_H264_CPUS must be DomD's CPU 0 or 1, or the range 0-1 (got '${RPI5_DOMA_H264_CPUS}')"
        ;;
    esac
}

# The default is a no-op, for the same reason as rpi5_doma_gpu_fhd's.
rpi5_doma_hwdec_check() {
    :
}
