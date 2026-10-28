SUMMARY = "Xen runtime cfg for the DomA (AAOS) guest (xl create)"
DESCRIPTION = "\
    /etc/xen/doma.cfg + doma.dtb + xl-create-doma.service, plus the \
    DomA-augmented /etc/xen/domd.cfg (adds xvdc=p4 = the AAOS super.img to the \
    DomD config). DomA is created before DomU so the DomD vhost_xen module \
    latches the correct guest domid. Boot order is encoded in the unit files. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://doma.cfg \
    file://domd.cfg \
    file://doma.dts \
    file://xl-create-doma.service \
    file://doma-devmodel-sweep.sh \
    file://doma-pick-hdmi-audio \
    "

S = "${UNPACKDIR}"

inherit systemd

DEPENDS = "dtc-native"

SYSTEMD_SERVICE:${PN} = "xl-create-doma.service"
SYSTEMD_AUTO_ENABLE = "enable"

# The unit's ExecStart/ExecStartPre chain needs `xl` and the xenstore CLI; the sweep
# script additionally uses awk and grep, which busybox provides.
RDEPENDS:${PN} = "xen-tools-xl xen-tools-xenstore"

# Which Raspberry Pi 5 SKU this image is for. Set from the moulin BOARD_RAM
# parameter through the domd builder's conf: meta-xt-doma is in that builder's
# layers, and doma.cfg ships in the DomD image because DomD runs the toolstack.
# The default matches moulin's own default so a standalone bitbake still works.
BOARD_RAM ??= "16g"

# Board layers whose SKUs are not the Pi 5's 16g/8g set this to DomA's size in MiB
# and the BOARD_RAM map in do_install is not consulted. Empty means "use the map".
DOMA_MEM_MiB ??= ""

# DomA's vCPU count and its physical-core mask: 2 vCPUs on pcpu 2-3 on every board,
# off the pcpus DomD and its device model run on. The measurements behind it are in
# doma.cfg next to the two tokens. Board layers can still override either.
DOMA_VCPUS ?= "2"
DOMA_CPUS ?= "2-3"

# [Venus] virtio-gpu-gl device-model options, from the moulin GPU parameter (see
# do_install). Defaulted for the same reason BOARD_RAM is defaulted a few lines above:
# a standalone bitbake outside moulin must still install a working config. The default
# is the pre-Venus content even though the product default is GPU=vulkan, because a
# standalone build cannot know which device model is installed and `venus=true` on a
# qemu without the property is a config qemu REJECTS outright; the empty string works
# on either. moulin always sets the value explicitly.
XT_VENUS_GPU_OPTS ??= ""
# [Venus] Device-model environment for the Venus lane's memory behaviour on a
# shared-memory guest. Both go into doma.cfg qemu_envs next to VIRGL_EXTERNAL_GBM,
# under the same gate (see the substitution in do_install). Measured on the RPi4
# 4g SKU with AAOS HWUI on Vulkan, 2026-09-12/13:
#  - V3DV_MAX_BO_CACHE_SIZE (MiB, Mesa v3dv, default 64): freed GEM BOs each render
#    server keeps for reuse. Nine Venus render servers retained ~0.5 GiB of DomD
#    memory that way; 8 is enough for reuse.
#  - VKR_DEVICE_HEAP_MIB (virglrenderer 0021, inert when unset): the device-local
#    heap size vkr advertises to the guest, forced to this value. v3dv reports a
#    percentage of DomD's system RAM (645 MiB on a 1408 MiB DomD) and the guest's
#    Skia/VMA sizes its block pool as heap/8 for heaps of 1 GiB or less -- every
#    block a fully populated v3d BO in DomD -- so HWUI RenderThreads allocated
#    96 MiB blocks (and, with an earlier clamp-only variant at 512 MiB, still 64) by the
#    handful and DomD fell into a memory-reclaim livelock (device model stalled,
#    guest soft-locked). Above 1 GiB VMA switches to the 4 MiB block size Skia asks
#    for and large images become dedicated allocations of their real size; 1088
#    is the smallest round value above that threshold. With it the cold-start and
#    screen-transition stresses that stalled DomD pass with DomD MemAvailable never
#    below ~460 MiB and no guest allocation of 64 MiB or more.
XT_VENUS_V3DV_BO_CACHE_MIB ??= "8"
XT_VENUS_VKR_DEVICE_HEAP_MIB ??= "1088"
# [qemu 10] The qemu version the guests' device model is built from. It comes from
# PREFERRED_VERSION_qemu, which the moulin conf sets per lane: in the default
# GPU=vulkan lane 11.1.2 on both boards (qemu_11.1.2.bb; docs/VULKAN-VENUS.md), or
# 10.0.2 where a board selects meta-xt-qemu/qemu_10.0.2.bb instead,
# 7.0.0 for --gpu=gl -- which is the yaml's base value, left standing.
#
# The '7.0.0' fallback below is deliberately the OLDER of the two, because the
# 7.0.0-only syntax is the conservative choice: every qemu in this tree parses
# the config it produces, whereas the 10.x form makes a 7.0.0 device model exit
# on an unknown property. It is not a safe default in general, though: a build
# that leaves PREFERRED_VERSION_qemu unset gets meta-xt-qemu's newest default qemu
# (10.0.2 at the time of writing) while this fallback still emits the 7.0.0-only
# syntax, and that device model exits on it. Such a build must set
# XT_DM_QEMU_VERSION itself. Inside moulin the variable is always set, so the
# fallback only ever applies to a bare `bitbake` in this tree's own conf.
XT_DM_QEMU_VERSION ??= "${@d.getVar('PREFERRED_VERSION_qemu') or '7.0.0'}"

# [hardware decode] Whether DomA is given a virtio-media device. Comes from the
# moulin GPU parameter through the domd and dom0 component confs, for a reason that
# is a hard dependency and not a policy: the decoder the guest talks to IS a
# virtio-media device, which only the qemu 10.0.2 and 11.1.2 device models have, so
# GPU=gl is false, and GPU=vulkan gives whatever the board yaml sets for that lane:
# true, except in a Dom0 flavour whose DomD has no decoder (the Pi 5's linux one).
# The same parameter sets it on the AOSP side, where it gates the c2 HAL and its
# seccomp policy (the HAL's sepolicy is built in every lane) -- the two halves must
# agree or the guest declares a HAL for a device that is not on the bus.
#
# Defaulted for the same reason BOARD_RAM is: a standalone bitbake outside moulin
# must still install a working config, and "no decoder" is the one configuration
# every device model in this tree can run. moulin always sets the value explicitly.
XT_DOMA_HWDEC ??= "false"

# [hardware decode] What the virtio-media device is pointed at. Per board, because
# the two boards' decode hardware has nothing in common beyond the words "hardware
# decode":
#
#   RPi4  v4l2-device=/dev/video10 -- proxy bcm2835-codec, which is a STATEFUL
#         H.264 decoder, so the guest talks to it almost directly. video10 because
#         bcm2835-v4l2-codec registers decode/encode/isp/deinterlace as
#         video10..13 in that order.
#   RPi5  decoder=hevc -- there is no stateful device to proxy. BCM2712 has no
#         vchiq node (measured: zero occurrences in the shipped
#         bcm2712-rpi-5-b.dtb) so bcm2835-codec cannot bind, and its only decode
#         block, codec@800000/rpi-hevc-dec, is STATELESS: it needs a media device
#         and a request fd per frame, neither of which virtio-media can carry.
#         qemu patches 0217-v10/0218-v10 therefore synthesise a stateful decoder
#         and drive the stateless side through libavcodec's v4l2request hwaccel.
#         With qemu 11.1.2 meta-xt-rpi5 makes it decoder=hevc+h264: the same
#         device decodes H.264 too, in software (q11-072..074).
#
# The default is the RPi4 value and only raspberrypi5 overrides it, so the boards
# that do not set it keep the generated file they had.
#
# The RPi4 value also switches on the two levers of qemu patch 0242 (both default
# off). Measured on that board with 1080p hardware decode running:
#
#   phase        default        with both levers
#   gpu-cap      avg 449 us     avg  43 us
#   ioctl-out    avg 593 us *   avg 224 us
#   qbuf-cap     avg 953 us     avg 401 us      max 36730 us -> 14176 us
#
#   * measured over both queues together, not OUTPUT alone
#
# That matters for AUDIO, not for the decode rate: virtio-snd's TX and virtio-media's
# QBUF are serviced by the same device-model main loop, so a 37 ms QBUF starves the
# audio device. With the levers on and the ALSA buffer at doma.cfg's 60 ms the host
# PCM ran 99.0% of nominal with 0 restarts over 20 s; a 40 ms buffer without them
# XRUN-ed 125 times in 25 s. (doma.cfg quotes the earlier run that chose its 60 ms,
# which counted 1-2 XRUNs per 20 s at 40 ms, before these levers existed; the two
# runs' other conditions were not recorded.)
#   output-coherent  coherent OUTPUT queue, so vb2 stops syncing 512 KB per 8 KB
#                    access unit;
#   gpu-fence-fd     export the blit fence as a sync_file and poll it, instead of two
#                    eglMakeCurrent calls per CAPTURE QBUF.
XT_DOMA_HWDEC_DEVARG ?= "v4l2-device=/dev/video10,output-coherent=on,gpu-fence-fd=on"
# meta-xt-rpi5 appends +h264 (RPI5_DOMA_H264), its host-sand and gpu-fence-fd
# (RPI5_DOMA_HOST_SAND) and host-max-width (RPI5_DOMA_HWDEC_MAX_W) to this.
XT_DOMA_HWDEC_DEVARG:raspberrypi5 = "decoder=hevc"

# [display] Extra virtio-gpu-gl-pci properties, substituted only on the qemu 10
# device model (see XT_DOMA_GPU_PROPS_PLACEHOLDER in doma.cfg).
#
# refresh_rate=60000 pins the EDID refresh the device model reports to the guest at
# 60 Hz (the value is mHz; qemu patch 0236). Without it qemu's EDID advertises 75 Hz
# and the guest's SurfaceFlinger runs its vsync at 75 Hz against a 60 Hz panel:
# measured on the RPi4 2026-09-05, a 60 fps video layer could then only be served at
# 37.5 Hz. The RPi5 verification image ran with the same value (2026-09-21). Both
# boards' DomA panels are 60 Hz, so it is the default rather than a board override.
XT_DOMA_GPU_PROPS ??= "refresh_rate=60000,"

# [overlay planes] How many overlay planes DomA's display gets.
# It is a pair, and both halves come from here: the device model's virtio-gpu
# overlay-planes=N (qemu 10.0.2 patch 0250-v10-virtio-gpu-gl-sdl2-overlay-planes, q11-051)
# and DomA's virtio_gpu.overlay_planes=N (aosp-kernel-patches/common/0001-drm-virtio-
# overlay-planes-on-output-0). With them drm_hwcomposer scans the app out on the
# primary plane and the system bars on the overlays, so SurfaceFlinger stops
# compositing on the GPU. Measured on the RPi4 2026-10-02 (a 640x360 video playing
# in a WebView): all three layers DEVICE, dropped frames 35% -> 25% (Vulkan HWUI) and
# 21% -> 13.5% (GL HWUI).
# 0 (the default here) turns both off; a board may set its own value in its
# xt-xen-cfg-doma bbappend. The qemu 7.0.0 device model (GPU=gl lane) has no such property,
# so that lane gets neither, whatever this says. Only the SDL GL display draws the
# overlays; doma.cfg uses -display sdl,gl=es on both boards.
# Keep the halves together: a guest kernel without the patch would treat the extra
# scanouts as extra (disconnected) connectors; a kernel with it and
# a device model without overlay-planes simply finds too few scanouts and falls back.
XT_DOMA_OVERLAY_PLANES ??= "0"

# [plane scaling] 1 = DomA's virtio_gpu.plane_scaling=1 (aosp-kernel-patches/common/
# 0002-drm-virtio-primary-plane-rect): the primary plane may be positioned and scaled,
# its destination going to the device in VIRTIO_GPU_CMD_SET_PRIMARY_RECT. Needs a device
# model with the handler, which only qemu 11.1.2 has (its patch q11-064), so it
# is off here and do_install refuses it with any other device model. Measured on
# the RPi4 2026-10-12/13 with XT_DOMA_OVERLAY_PLANES = "3": the non-fullscreen WebView
# ("HMI + video", the scaled video underlay on the primary) goes from all four layers
# CLIENT to all DEVICE, local 720p60 40 -> 52-55 fps; fullscreen 1080p60 and Gallery
# unchanged. Without overlays it does nothing useful, so it requires XT_DOMA_OVERLAY_PLANES > 0.
XT_DOMA_PLANE_SCALING ??= "0"


do_compile() {
    dtc -I dts -O dtb -o ${WORKDIR}/doma.dtb ${UNPACKDIR}/doma.dts
}

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/doma.cfg ${D}${sysconfdir}/xen/doma.cfg
    install -m 0644 ${UNPACKDIR}/domd.cfg ${D}${sysconfdir}/xen/domd.cfg

    # DomA's size is board-dependent. On the 8 GB SKU the four domains have to fit
    # 7680 MiB, and DomD cannot absorb the whole reduction alone: DomD 2048 was
    # measured to leave the DomA device model unable to serve a 4 GiB guest (AAOS
    # crash-looped in binder while DomD itself still had 1.3 GiB free and was never
    # OOM-killed). 3072/3072 keeps the same total and boots all four domains. The
    # measurement and its history are in doma.cfg next to this value.
    # A board whose SKUs are not 16g/8g sets DOMA_MEM_MiB and bypasses the map
    # entirely. meta-xt-rpi4 does: the Raspberry Pi 4 SKUs are 8g and 4g, and its
    # 8 GiB budget puts DomA at a different size than the Pi 5's, so neither the
    # sizes nor the SKU names carry over. The map below stays literal because
    # tools/check-memory-map.py cross-checks these numbers against its own budget
    # table for the Pi 5.
    if [ -n "${DOMA_MEM_MiB}" ]; then
        doma_mem="${DOMA_MEM_MiB}"
    else
        case "${BOARD_RAM}" in
            16g) doma_mem=4096 ;;
            8g)  doma_mem=3072 ;;
            *)   bbfatal "BOARD_RAM must be 8g or 16g (got '${BOARD_RAM}'), or the board layer must set DOMA_MEM_MiB" ;;
        esac
    fi
    # Fail loudly rather than ship the placeholder: `xl create` rejects a
    # non-numeric `memory`, so DomA would simply never start -- and the same
    # applies if a future edit renames the token.
    if ! grep -q '^memory = DOMA_MEM_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "DOMA_MEM_PLACEHOLDER not found in doma.cfg"
    fi
    # $doma_mem, not ${doma_mem}: inside a bitbake shell function ${...} is bitbake's
    # own expansion, and doma_mem is a shell local. It happens to survive today only
    # because bitbake leaves unknown names untouched -- a bitbake variable of that
    # name appearing later would silently substitute the wrong value.
    sed -i "s/^memory = DOMA_MEM_PLACEHOLDER\$/memory = $doma_mem/" \
        ${D}${sysconfdir}/xen/doma.cfg

    # Same treatment for the vCPU count and the pCPU mask: `xl create` rejects a
    # non-numeric `vcpus`, so DomA would never start -- and the same applies if a
    # future edit renames either token.
    if ! grep -q '^vcpus = DOMA_VCPUS_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "DOMA_VCPUS_PLACEHOLDER not found in doma.cfg"
    fi
    if ! grep -q '^cpus = "DOMA_CPUS_PLACEHOLDER"$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "DOMA_CPUS_PLACEHOLDER not found in doma.cfg"
    fi
    sed -i -e "s/^vcpus = DOMA_VCPUS_PLACEHOLDER\$/vcpus = ${DOMA_VCPUS}/" \
           -e "s/^cpus = \"DOMA_CPUS_PLACEHOLDER\"\$/cpus = \"${DOMA_CPUS}\"/" \
        ${D}${sysconfdir}/xen/doma.cfg

    # [Venus] Substitute the virtio-gpu-gl device-model options. XT_VENUS_GPU_OPTS
    # comes from the moulin GPU parameter through the domd component conf:
    # ",hostmem=256M,blob=true,venus=true" for the default Vulkan lane, "" for --gpu=gl
    # (docs/VULKAN-VENUS.md). With --gpu=gl the token is replaced with nothing,
    # so that lane's installed file carries none of the Venus options.
    #
    # Fail loudly rather than ship the placeholder: qemu exits on an unknown
    # -device property, so the guest's device model would never start -- and the
    # same applies if a future edit renames the token.
    if ! grep -q 'virtio-gpu-gl-pci.*XT_VENUS_GPU_OPTS_PLACEHOLDER' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_VENUS_GPU_OPTS_PLACEHOLDER not found in doma.cfg"
    fi
    # The value contains ',' and '=' but no '/', so '/' stays usable as the sed
    # delimiter. Deleting the comment block that documents the token as well: it
    # explains a build-time mechanism and has no meaning in the installed file.
    sed -i -e '/^    # XT_VENUS_GPU_OPTS_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # See docs\/VULKAN-VENUS.md.$/d' \
           -e "s/XT_VENUS_GPU_OPTS_PLACEHOLDER/${XT_VENUS_GPU_OPTS}/" \
        ${D}${sysconfdir}/xen/doma.cfg

    # [Venus] Substitute the qemu_envs entries: the one that switches on
    # virglrenderer's global gbm, and the two memory knobs next to it. Same lane as
    # XT_VENUS_GPU_OPTS -- keyed on it rather than on a second
    # variable so the two can never disagree: pinned blob memory without the export
    # path (or the reverse) is not a configuration anyone wants.
    #
    # This is a SEPARATE token from the device-model options because it lives in
    # qemu_envs, not in device_model_args, and because the non-Venus lane must DELETE
    # the line rather than empty it: `''` would be a valid but useless env entry, and
    # bare whitespace inside the list is not valid Python for xl's config parser.
    if ! grep -q '^    XT_VENUS_QEMU_ENV_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_VENUS_QEMU_ENV_PLACEHOLDER not found in doma.cfg"
    fi
    # VKR_RING_IDLE_WAIT_MS=1000: an idle Venus ring thread wakes once a second
    # instead of every 10 ms to look for a missed notification (virglrenderer 0022
    # bounds the wait, 0023 makes the bound this variable). Measured on the RPi4:
    # idle wake-ups 975 -> about 10 a second. VKR_RING_RELAX=0,100: between commands
    # the ring thread sleeps from 100 us instead of yielding 15 times and sleeping from
    # 10 us (virglrenderer 0025; measured on the Raspberry Pi 5 only).
    if [ -n "${XT_VENUS_GPU_OPTS}" ]; then
        venus_env="    'VIRGL_EXTERNAL_GBM=1', 'V3DV_MAX_BO_CACHE_SIZE=${XT_VENUS_V3DV_BO_CACHE_MIB}', 'VKR_DEVICE_HEAP_MIB=${XT_VENUS_VKR_DEVICE_HEAP_MIB}', 'VKR_RING_IDLE_WAIT_MS=1000', 'VKR_RING_RELAX=0,100',"
    else
        venus_env=""
    fi
    # Delete the comment block documenting the token in both lanes -- it explains a
    # build-time mechanism and has no meaning in the installed file.
    sed -i -e '/^    # XT_VENUS_QEMU_ENV_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # See docs\/VULKAN-VENUS.md.$/d' \
        ${D}${sysconfdir}/xen/doma.cfg
    if [ -n "$venus_env" ]; then
        sed -i -e "s|^    XT_VENUS_QEMU_ENV_PLACEHOLDER$|$venus_env|" \
            ${D}${sysconfdir}/xen/doma.cfg
    else
        sed -i -e '/^    XT_VENUS_QEMU_ENV_PLACEHOLDER$/d' \
            ${D}${sysconfdir}/xen/doma.cfg
    fi

    # [hardware decode] Substitute, or delete, the two tokens that carry the
    # virtio-media device: one in the libxl virtio list (the 09.0 host slot) and one
    # in device_model_args (the device itself). They are driven by the SAME variable
    # so DomA can never get a slot with no device on it, or a device with no slot.
    #
    # Two tokens rather than one because they live in different lists, and the
    # non-decode lane must DELETE both lines rather than empty them: bare whitespace
    # inside either list is not valid Python for xl's config parser.
    case "${XT_DOMA_HWDEC}" in
    true)  doma_hwdec=yes ;;
    false) doma_hwdec=no ;;
    *)     bbfatal "XT_DOMA_HWDEC must be 'true' or 'false' (got '${XT_DOMA_HWDEC}')" ;;
    esac
    # A 7.0.0 device model has no virtio-media device at all, so it would exit on
    # the -device line and DomA would never start. Keyed on XT_DM_QEMU_VERSION,
    # the version every other section of this file writes the device-model
    # syntax for: a conf that names no qemu gets the 7.0.0 fallback there, and
    # fails here.
    if [ "$doma_hwdec" = "yes" ]; then
        case "${XT_DM_QEMU_VERSION}" in
        7.*) bbfatal "XT_DOMA_HWDEC=true with a qemu ${XT_DM_QEMU_VERSION} device model: virtio-media exists only in the 10.0.2 and 11.1.2 ones" ;;
        esac
    fi
    # Fail loudly rather than ship a placeholder: xl's parser would reject the bare
    # name, so DomA would never start -- and the same applies if a future edit
    # renames a token.
    for doma_tok in XT_DOMA_HWDEC_VIRTIO_PLACEHOLDER XT_DOMA_HWDEC_DEVICE_PLACEHOLDER; do
        grep -q "^    $doma_tok\$" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "$doma_tok not found in doma.cfg"
    done
    # Delete the comment blocks that document the tokens in both lanes -- they
    # explain a build-time mechanism and have no meaning in the installed file.
    sed -i -e '/^    # XT_DOMA_HWDEC_VIRTIO_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # rootfs\.$/d' \
           -e '/^    # XT_DOMA_HWDEC_DEVICE_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # exit on an unknown -device and DomA would never start\.$/d' \
        ${D}${sysconfdir}/xen/doma.cfg
    if [ "$doma_hwdec" = "yes" ]; then
        sed -i -e "s|^    XT_DOMA_HWDEC_VIRTIO_PLACEHOLDER\$|    'backend=1, type=virtio,device, transport=pci, bdf=0000:00:09.0, grant_usage=0, backend_type=qemu',|" \
               -e "s|^    XT_DOMA_HWDEC_DEVICE_PLACEHOLDER\$|    '-device', 'virtio-media-pci,${XT_DOMA_HWDEC_DEVARG},disable-legacy=on,ioeventfd=off,iommu_platform=on,bus=pcie.0,addr=9',|" \
            ${D}${sysconfdir}/xen/doma.cfg
        grep -q "bdf=0000:00:09.0" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: the 09.0 virtio list entry did not get substituted"
        grep -q "virtio-media-pci,${XT_DOMA_HWDEC_DEVARG}," ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: the backend argument '${XT_DOMA_HWDEC_DEVARG}' did not reach the -device line"
    else
        sed -i -e '/^    XT_DOMA_HWDEC_VIRTIO_PLACEHOLDER$/d' \
               -e '/^    XT_DOMA_HWDEC_DEVICE_PLACEHOLDER$/d' \
            ${D}${sysconfdir}/xen/doma.cfg
        if grep -q "virtio-media-pci\|bdf=0000:00:09.0" ${D}${sysconfdir}/xen/doma.cfg; then
            bbfatal "doma.cfg: a virtio-media device was left in with XT_DOMA_HWDEC=false"
        fi
    fi

    # [audio] Substitute the virtio-snd device-model property that only the patched
    # qemu 10.0.2 and 11.1.2 have, and empty the token on 7.0.0.
    #
    # tx-poll-us comes from qemu patch
    # 0243-v10-virtio-snd-drain-tx-from-a-dedicated-thread.patch: it drains the TX
    # queue from a thread of the device model's own every N microseconds. The device
    # model cannot hand a virtio queue to an iothread on Xen (xen_io_listener has no
    # .eventfd_add), and the single main loop that serves the audio backend also runs
    # virtio-media's QBUF work for the video, so without the thread the audio
    # callback arrives late under video load and the guest blocks in its own PCM
    # write. 10000 is half the 20000 us period doma.cfg asks for; 0 would disable the
    # thread.
    #
    # Keyed on the device model's version, like the argument fixups below, and for
    # the same kind of reason in the other direction: a 7.0.0 device model exits with
    # "Property 'virtio-snd-pci.tx-poll-us' not found" and DomA then dies as a (null)
    # domain with "Qdisk backend didn't respond in time" (measured on the board
    # 2026-09-20).
    if ! grep -q 'streams=1,XT_DOMA_SND_PROPS_PLACEHOLDER' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_DOMA_SND_PROPS_PLACEHOLDER not found in doma.cfg"
    fi
    case "${XT_DM_QEMU_VERSION}" in
    7.*) doma_snd_props="" ;;
    *)   doma_snd_props="tx-poll-us=10000," ;;
    esac
    # Delete the comment block documenting the token in both lanes -- it explains a
    # build-time mechanism and has no meaning in the installed file. The token is
    # substituted in place rather than by line, because it sits inside the -device
    # argument string and the empty lane has to close the gap, not leave a hole.
    sed -i -e '/^    # XT_DOMA_SND_PROPS_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # at the substitution in xt-xen-cfg-doma\.$/d' \
           -e "s/XT_DOMA_SND_PROPS_PLACEHOLDER/$doma_snd_props/" \
        ${D}${sysconfdir}/xen/doma.cfg
    if grep -q XT_DOMA_SND_PROPS_PLACEHOLDER ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "doma.cfg: XT_DOMA_SND_PROPS_PLACEHOLDER was not substituted"
    fi
    if [ -n "$doma_snd_props" ]; then
        grep -q "streams=1,$doma_snd_props" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: '$doma_snd_props' did not reach the virtio-snd -device line"
    elif grep -q 'tx-poll-us' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "doma.cfg: tx-poll-us left in for qemu ${XT_DM_QEMU_VERSION}, whose device model has no such property"
    fi

    # [bluetooth] The HCI chardev's retry option, keyed on the device model's version
    # like tx-poll-us above. doma.cfg spells it reconnect=1, which 7.0.0 and 10.0.2
    # take; qemu removed `reconnect` in 10.2, so 11.1.2 only has reconnect-ms
    # (chardev/char.c) and its device model refuses the option and exits, taking
    # DomA's disk with it (one device model serves every DomA virtio device).
    bt_from="socket,path=/run/bt-hci.sock,server=off,reconnect=1,"
    grep -q "$bt_from" ${D}${sysconfdir}/xen/doma.cfg || \
        bbfatal "doma.cfg: the Bluetooth chardev '$bt_from' not found"
    case "${XT_DM_QEMU_VERSION}" in
    11.*)
        sed -i "s|$bt_from|socket,path=/run/bt-hci.sock,server=off,reconnect-ms=1000,|" \
            ${D}${sysconfdir}/xen/doma.cfg
        grep -q "socket,path=/run/bt-hci.sock,server=off,reconnect-ms=1000," ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: reconnect-ms=1000 did not reach the Bluetooth chardev"
        if grep -v '^[[:space:]]*#' ${D}${sysconfdir}/xen/doma.cfg | grep -q 'reconnect='; then
            bbfatal "doma.cfg: a chardev reconnect= left in for qemu ${XT_DM_QEMU_VERSION}, which has no such option"
        fi
        ;;
    esac

    # [display] Substitute the board's extra virtio-gpu-gl-pci properties on the
    # qemu 10 device model, and empty the token on 7.0.0. Keyed on the device
    # model's version for the same reason as tx-poll-us above: the properties this
    # carries come from patches only the 10.0.2 and 11.1.2 device models have
    # (refresh_rate is 0236 / q11-039), and a 7.0.0 device model exits on an unknown
    # property.
    if ! grep -q 'virtio-gpu-gl-pci,XT_DOMA_GPU_PROPS_PLACEHOLDER' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "XT_DOMA_GPU_PROPS_PLACEHOLDER not found in doma.cfg"
    fi
    case "${XT_DM_QEMU_VERSION}" in
    7.*) doma_gpu_props="" ;;
    *)   doma_gpu_props="${XT_DOMA_GPU_PROPS}" ;;
    esac
    sed -i -e '/^    # XT_DOMA_GPU_PROPS_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # xt-xen-cfg-doma\.$/d' \
           -e "s/XT_DOMA_GPU_PROPS_PLACEHOLDER/$doma_gpu_props/" \
        ${D}${sysconfdir}/xen/doma.cfg
    if grep -q XT_DOMA_GPU_PROPS_PLACEHOLDER ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "doma.cfg: XT_DOMA_GPU_PROPS_PLACEHOLDER was not substituted"
    fi
    if [ -n "$doma_gpu_props" ]; then
        grep -q "virtio-gpu-gl-pci,$doma_gpu_props" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: '$doma_gpu_props' did not reach the virtio-gpu -device line"
    fi

    # [overlay planes] both halves of XT_DOMA_OVERLAY_PLANES, or neither.
    case "${XT_DOMA_OVERLAY_PLANES}" in
    0|1|2|3) ;;
    *) bbfatal "XT_DOMA_OVERLAY_PLANES='${XT_DOMA_OVERLAY_PLANES}': expected 0..3" ;;
    esac
    case "${XT_DM_QEMU_VERSION}" in
    7.*) doma_overlays=0 ;;
    *)   doma_overlays="${XT_DOMA_OVERLAY_PLANES}" ;;
    esac
    if [ "$doma_overlays" != 0 ]; then
        sed -i -e "s/'virtio-gpu-gl-pci,$doma_gpu_props/&overlay-planes=$doma_overlays,/" \
               -e "s/^\(extra = \".*\)\"\$/\1 virtio_gpu.overlay_planes=$doma_overlays\"/" \
            ${D}${sysconfdir}/xen/doma.cfg
        grep -q "virtio-gpu-gl-pci,${doma_gpu_props}overlay-planes=$doma_overlays," ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: overlay-planes=$doma_overlays did not reach the virtio-gpu -device line"
        grep -q "^extra = \".* virtio_gpu.overlay_planes=$doma_overlays\"\$" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: virtio_gpu.overlay_planes=$doma_overlays did not reach DomA's command line"
    fi

    # [plane scaling] DomA's half only (the device model's half is qemu 11's q11-064).
    case "${XT_DOMA_PLANE_SCALING}" in
    0) ;;
    1)
        [ "$doma_overlays" != 0 ] || \
            bbfatal "XT_DOMA_PLANE_SCALING=1 needs XT_DOMA_OVERLAY_PLANES > 0 (and not the qemu 7 lane)"
        case "${XT_DM_QEMU_VERSION}" in
        11.*) ;;
        *) bbfatal "XT_DOMA_PLANE_SCALING=1 needs the qemu 11 device model (XT_DM_QEMU_VERSION='${XT_DM_QEMU_VERSION}')" ;;
        esac
        sed -i -e "s/^\(extra = \".*\)\"\$/\1 virtio_gpu.plane_scaling=1\"/" \
            ${D}${sysconfdir}/xen/doma.cfg
        grep -q "^extra = \".* virtio_gpu.plane_scaling=1\"\$" ${D}${sysconfdir}/xen/doma.cfg || \
            bbfatal "doma.cfg: virtio_gpu.plane_scaling=1 did not reach DomA's command line"
        ;;
    *) bbfatal "XT_DOMA_PLANE_SCALING='${XT_DOMA_PLANE_SCALING}': expected 0 or 1" ;;
    esac

    # [qemu 10] Device-model argument fixups. Two of the options in doma.cfg are
    # 7.0.0-xt-only and qemu 10 EXITS on either one -- both measured on RPi5:
    #   virtio-snd-pci        -> "'virtio-snd-pci' is not a valid device model name"
    #                            (upstream calls it virtio-sound-pci, alias virtio-sound)
    #   virtio-blk-pci,scsi=  -> "Property 'virtio-blk-pci.scsi' not found"
    #                            (the property was removed upstream)
    # `-vga std` only warns there ("this machine type does not use that option";
    # the xenpvh machine creates no VGA device at all), and is dropped with them so
    # the emitted config has no dead options for that device model.
    #
    # Keyed on the device model's version, not on the GPU parameter: the incompatibility
    # belongs to qemu 10, so a later qemu bump outside the Venus lane is covered
    # too, and this step leaves the 7.0.0 (--gpu=gl) lane untouched (the case
    # does nothing there).
    case "${XT_DM_QEMU_VERSION}" in
    7.*)
        ;;
    *)
        sed -i -e "s/'virtio-snd-pci,/'virtio-sound-pci,/" \
               -e "s/'virtio-blk-pci,scsi=off,/'virtio-blk-pci,/" \
               -e "/^    '-vga', 'std',$/d" \
            ${D}${sysconfdir}/xen/doma.cfg
        # Fail loudly rather than ship a config the device model will reject.
        if grep -qE "virtio-snd-pci|virtio-blk-pci,scsi=|'-vga'" ${D}${sysconfdir}/xen/doma.cfg; then
            bbfatal "qemu ${XT_DM_QEMU_VERSION} device-model incompatibility left in doma.cfg"
        fi
        ;;
    esac

    install -d ${D}/usr/lib/xen/boot
    install -m 0644 ${WORKDIR}/doma.dtb ${D}/usr/lib/xen/boot/doma.dtb

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-doma.service ${D}${systemd_system_unitdir}/xl-create-doma.service

    # ExecStartPre of xl-create-doma.service. A script rather than an inline Exec
    # line because the awk field reference needs a backslash-escaped `$`, which
    # systemd rejects with "Ignoring unknown escape sequences".
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/doma-devmodel-sweep.sh ${D}${libexecdir}/doma-devmodel-sweep

    # ALSO an ExecStartPre, and it has to be the LAST one: it edits doma.cfg and
    # ExecStart is what reads the result.
    #
    # doma.cfg names the HDMI card the qemu audio backend opens, and which
    # vc4hdmi card is the connected one depends on the cable, among the cards DomD
    # has (one per HDMI node its DT gives `dmas`). The script reads
    # /proc/asound/card*/eld*, picks the card
    # whose ELD reports sad_count > 0 -- the one a display actually answered on --
    # and rewrites out.dev, keeping a .hdmiaudio.bak. At boot rather than at build
    # time because the answer changes when the cable moves. It sees only the
    # toolstack domain's cards: in the linux flavour that is Dom0, which has none,
    # so there the literal out.dev doma.cfg was built with is what DomA opens.
    install -m 0755 ${UNPACKDIR}/doma-pick-hdmi-audio ${D}${libexecdir}/doma-pick-hdmi-audio
}

# doma.cfg now depends on BOARD_RAM, so switching SKUs must not reuse a doma.cfg
# from sstate that still carries the other board's `memory` value. The same reason
# BOARD_RAM is in xt-rpi-u-boot-scr's do_compile[vardeps].
do_install[vardeps] += "BOARD_RAM"
# Same reason, for the board-layer override that bypasses the BOARD_RAM map.
do_install[vardeps] += "DOMA_MEM_MiB"
# Same reason for the two CPU tokens, which a board layer may override.
do_install[vardeps] += "DOMA_VCPUS DOMA_CPUS"
# Same reason again, for the Venus device-model options substituted into doma.cfg.
do_install[vardeps] += "XT_VENUS_GPU_OPTS"
# Same reason for the two memory knobs substituted into the same qemu_envs line.
do_install[vardeps] += "XT_VENUS_VKR_DEVICE_HEAP_MIB XT_VENUS_V3DV_BO_CACHE_MIB"
# Same reason for the device-model version that selects the argument fixups and
# the virtio-snd property.
do_install[vardeps] += "XT_DM_QEMU_VERSION"
# Same reason for the hardware-decode gate and the backend it selects: switching
# lanes or boards must not reuse a doma.cfg from sstate that carries the other
# lane's device, or the other board's backend argument.
do_install[vardeps] += "XT_DOMA_HWDEC XT_DOMA_HWDEC_DEVARG"
do_install[vardeps] += "XT_DOMA_GPU_PROPS"
do_install[vardeps] += "XT_DOMA_OVERLAY_PLANES XT_DOMA_PLANE_SCALING"

FILES:${PN} = " \
    ${sysconfdir}/xen/doma.cfg \
    ${sysconfdir}/xen/domd.cfg \
    /usr/lib/xen/boot/doma.dtb \
    ${systemd_system_unitdir}/xl-create-doma.service \
    ${libexecdir}/doma-devmodel-sweep \
    ${libexecdir}/doma-pick-hdmi-audio \
    "
