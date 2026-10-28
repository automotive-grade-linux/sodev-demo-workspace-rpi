# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# DomA's guest memory, display size and decoded-frame width on Raspberry Pi 4.
#
# xt-xen-cfg-doma lives in meta-xt-common because DomA's xl configuration is
# board-independent apart from its size, and this port keeps that layer's doma.cfg
# byte-identical. Only the memory size, the virtio-gpu resolution, the
# virtio-media backend's host-max-width and the HDMI audio card change here.
#
# WHY 2560 MiB
# The 8 GiB Pi 4 has to fit four domains into what is left after the boot-time
# carve-outs, and the RPi4 map is not the Pi 5's:
#   Dom0 128 MiB (zephyr) or 256 MiB (linux) of dom0_mem. The linux 256 is NOT
#     one bank and NOT bank[0]'s size: it comes back as 128 MiB at 0x20000000
#     plus 128 MiB at 0x30000000. The Zephyr Dom0 is relinked to 0x20000000,
#     where bank[0] was measured -- see boot.cmd.xen.zephyr-dom0.in.
#   Xen itself 80 MiB, a separate item, measured with `xl info` across three
#     DomD sizes on the 4 GiB board (78/79/80 MiB of frametable + xenheap +
#     image); see boot.cmd.xen.linux-dom0.in.
#   DomD xen,static-mem  384 MiB + 1 GiB + 512 MiB = 1920 MiB, all below 4 GiB
#   gpu_mem=76 for the VideoCore carve-out at the top of the low bank
# 1920 + 256 + 1024 + 2560 + 80 = 5840 MiB of the 8052 MiB usable, which is the
# same arithmetic the BOARD_RAM note in rpi4-sodev.yaml does.
# DomU takes 1024 MiB from the remaining free pool and DomA 2560 MiB. Those two
# numbers are the ones the sending environment booted all four domains with on real
# hardware (2026-08-07); they have NOT been re-measured in this environment.
#
# On the 4 GiB SKU the free pool is 2692 MiB (zephyr Dom0) or 2564 MiB (linux Dom0)
# in the gl lane -- 3956 usable minus DomD 1056, Dom0 128..256 and Xen 80 -- and
# 2308 or 2180 MiB in the Venus lane, where DomD is 1440. That takes DomU 1024 or
# DomA on its own, but not both; DomA's 2560 leaves only 4 MiB with the
# linux Dom0 in the gl lane, which has not been booted, and build.sh warns
# about it. build.sh refuses `--ram=4g` when DomU and DomA are asked for
# TOGETHER, and with -z; a 4 GiB image with DomA alone is allowed, and that is
# the configuration the Venus lane's 2048 below is for.
#
# MECHANISM
# doma.cfg ships as `memory = DOMA_MEM_PLACEHOLDER` and xt-xen-cfg-doma's do_install
# substitutes it, choosing the value from a `case "${BOARD_RAM}"` map over the Pi 5's
# 16g/8g SKUs. Neither the SKU names nor the sizes carry over to this board, so rather
# than sed the substituted result afterwards, this sets the escape hatch that recipe
# provides: a non-empty DOMA_MEM_MiB is used verbatim and the map is not consulted.
# The recipe already has DOMA_MEM_MiB in do_install[vardeps], so switching boards
# cannot reuse a doma.cfg from sstate carrying the other board's value.
# 2048 rather than 2560 in the Venus lane on the 4 GiB SKU. 384 MiB of that moves to
# DomD for the device model's pinned blob memory -- DomD running out kills both
# guests' device models -- and DomD's side of it is in meta-xt-rpi4's
# xt-rpi-u-boot-scr bbappend, gated the same way. `hostmem`, the hard ceiling on
# what the device model can pin, was 128 MiB when this was sized and is 256 MiB now;
# DomD kept ~505 MiB available with 126 MiB of the window in use (2026-09-24).
# The other 128 MiB keep the guest in ONE memory zone. xenpvh maps the first
# 2048 MiB of a guest at GUEST_RAM0 and the rest above 4 GiB (xg_dom_arm.c;
# GUEST_RAM0 is 2 GiB because of this tree's
# 0003-Adjust-guest-memory-map.patch, upstream Xen has 3 GiB), so at 2176 the
# guest had a 1946 MB ZONE_DMA32 plus an 82 MB ZONE_NORMAL. AOSP's
# /system/bin/extra_free_kbytes.sh pairs `grep "min" /proc/zoneinfo` lines with
# zones -- the 6.x per-CPU `high_min:` lines match too -- and divides by
# managed/10000, which is 2 for that small zone; it wrote watermark_scale_factor
# 615 to 1777. kswapd then kept 734 MB free, re-read ~270 MB/s of evicted files
# through the device model, and both DomD and DomA saturated (measured on the
# board 2026-09-23: echo 10 into the sysctl took DomD from 200% to 32%). At 2048
# the guest has DMA32 only and the script wrote 82. With 1080p30 playing, DomA
# used 1420 MB and had ~570 MB available at 2048.
# The 8 GiB SKU is untouched: DomD has 1920 MiB there and the delta is noise.
#
# VENUS_LANE is the same one-line idiom meta-xt-rpi4's xt-rpi-u-boot-scr.bbappend
# uses for DomD's side of the same 384 MiB transfer -- deliberately, so the two
# halves cannot drift into two different readings of "is this the Venus lane".
# The vardeps line is belt-and-braces, not the mechanism: bitbake's codeparser
# already tracks `d.getVar('X')` as a reference to X (bitbake/lib/bb/codeparser.py
# `getvars`), and it records `bb.utils.contains('DISTRO_FEATURES', 'venus', ...)`
# as a *contains* dependency, which enters the signature as the single line
# `DISTRO_FEATURES{venus} = Set|Unset` (bitbake/lib/bb/data.py handle_contains) --
# so the feature test is hashed by its ANSWER, not by the whole feature string.
# What must NOT appear in vardeps is raw DISTRO_FEATURES: that hashes the entire
# string and rehashes this task on distro-feature changes that have nothing to do
# with Venus, defeating the contains() tracking.
VENUS_LANE = "${@bb.utils.contains('DISTRO_FEATURES', 'venus', 'yes', 'no', d)}"
DOMA_MEM_MiB:raspberrypi4-64 = "${@'2048' if (d.getVar('BOARD_RAM') == '4g' and d.getVar('VENUS_LANE') == 'yes') else '2560'}"
do_install[vardeps] += "BOARD_RAM VENUS_LANE"

# DomA's display is 1280x720 on this board: the 1920x1080 Onlap1102I panel on
# HDMI-A-1 is driven at CEA-861 VIC 4 and scales it up. The size was chosen by
# measured GPU load, and the weston side of it (HDMI-A-1's modeline) is this layer's
# weston-init.bbappend -- see there. The guest's resolution is what the device model
# reports as ui_info, i.e. virtio-gpu-gl-pci's xres/yres; AAOS follows it. The two
# must agree: a mismatch does not fail, kiosk-shell just scales the guest surface.
do_install[postfuncs] += "rpi4_doma_gpu_720p"

RPI4_DOMA_GPU_RES_FROM ?= "xres=1920,yres=720"
RPI4_DOMA_GPU_RES ?= "xres=1280,yres=720"

rpi4_doma_gpu_720p:raspberrypi4-64() {
    cfg="${D}${sysconfdir}/xen/doma.cfg"
    [ -f "$cfg" ] || bbfatal "xt-xen-cfg-doma.bbappend (rpi4): $cfg not installed"
    n=$(grep -c "virtio-gpu-gl-pci,.*,${RPI4_DOMA_GPU_RES_FROM}" "$cfg")
    if [ "$n" != "1" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi4): expected one virtio-gpu line with \
'${RPI4_DOMA_GPU_RES_FROM}' in $cfg, found $n"
    fi
    sed -i "/virtio-gpu-gl-pci,/s|,${RPI4_DOMA_GPU_RES_FROM}|,${RPI4_DOMA_GPU_RES}|" "$cfg"
    n=$(grep -c "virtio-gpu-gl-pci,.*,${RPI4_DOMA_GPU_RES}" "$cfg")
    if [ "$n" != "1" ] || grep -q "${RPI4_DOMA_GPU_RES_FROM}" "$cfg"; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi4): the virtio-gpu resolution rewrite did \
not apply cleanly to $cfg"
    fi
    bbnote "xt-xen-cfg-doma.bbappend (rpi4): DomA virtio-gpu -> ${RPI4_DOMA_GPU_RES}"
}

# Default is a no-op: bitbake gives a postfunc its flags from the unsuffixed
# definition, so without it exec_func fails with "'NoneType' object has no
# attribute 'get'".
rpi4_doma_gpu_720p() {
    :
}

do_install[vardeps] += "RPI4_DOMA_GPU_RES_FROM RPI4_DOMA_GPU_RES"

# A stream wider than DomA's display reaches DomA at the display's width: qemu
# 0246's host-max-width scales it down in the NV12 -> RGBA shader, so a 1080p
# stream arrives visible at 1280x720 and SurfaceFlinger composes it 1:1 instead
# of sampling 1920x1088 and scaling it. Measured at 1080p30 (2026-09-24, with
# the guest's frame rate override off): SF 27.1-28.8 -> 29.2-29.7 fps, missed
# 5.3-7.8 -> 0.9-1.3/s. The width comes from RPI4_DOMA_GPU_RES so the two
# cannot disagree; int() stops the parse if xres is not a number. The device
# model must carry 0246: qemu refuses an unknown property and DomA then does
# not start, so this doma.cfg does not go onto a board without the qemu.
RPI4_DOMA_HWDEC_MAX_W ?= "${@int(d.getVar('RPI4_DOMA_GPU_RES').split('xres=')[1].split(',')[0])}"
XT_DOMA_HWDEC_DEVARG:append:raspberrypi4-64 = ",host-max-width=${RPI4_DOMA_HWDEC_MAX_W}"

# DomA's overlay planes, as this board's doma.cfg has run them since its display path
# was measured (2026-10-02 .. 10-13): three overlay planes let drm_hwcomposer scan the
# app and the system bars out as DEVICE layers instead of SurfaceFlinger compositing
# them on the GPU (with two planes on qemu 10.0.2, before the kernel refused a plane not
# shown whole, a 640x360 video in a WebView dropped 25% of its frames instead of 35%).
# Both halves come from the common recipe; the gl lane (qemu 7.0.0) gets no overlays
# whatever this says. The Raspberry Pi 5 sets the same. A default (?=), so a local.conf
# can override it; 0 turns both halves off.
XT_DOMA_OVERLAY_PLANES ?= "3"

# DomA's HDMI audio card. doma.cfg's literal is out.dev=plughw:vc4hdmi1, HDMI-A-2;
# on this board DomA and the panel are on HDMI-A-1, whose card is vc4hdmi0 (the
# 440 Hz tone of 2026-09-23 reached the panel through vc4hdmi0). In the zephyr
# flavour doma-pick-hdmi-audio corrects the literal at boot from the ELDs. In the
# linux flavour it runs in Dom0, which has no HDMI card, finds nothing and leaves
# the literal alone, so DomA would open the dead port and play nothing. Only the
# '-audiodev' line is rewritten: doma.cfg's comments quote out.dev=plughw: too.
do_install[postfuncs] += "rpi4_doma_hdmi_audio_card"

RPI4_DOMA_AUDIO_DEV_FROM ?= "out.dev=plughw:vc4hdmi1,"
RPI4_DOMA_AUDIO_DEV ?= "out.dev=plughw:vc4hdmi0,"

rpi4_doma_hdmi_audio_card:raspberrypi4-64() {
    cfg="${D}${sysconfdir}/xen/doma.cfg"
    [ -f "$cfg" ] || bbfatal "xt-xen-cfg-doma.bbappend (rpi4): $cfg not installed"
    n=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -cF -- "${RPI4_DOMA_AUDIO_DEV_FROM}" || true)
    if [ "$n" != "1" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi4): expected one '-audiodev' line with '${RPI4_DOMA_AUDIO_DEV_FROM}' in $cfg, found $n"
    fi
    sed -i "/^[[:space:]]*'-audiodev',/s|${RPI4_DOMA_AUDIO_DEV_FROM}|${RPI4_DOMA_AUDIO_DEV}|" "$cfg"
    n=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -cF -- "${RPI4_DOMA_AUDIO_DEV}" || true)
    left=$(grep "^[[:space:]]*'-audiodev'," "$cfg" | grep -cF -- "${RPI4_DOMA_AUDIO_DEV_FROM}" || true)
    if [ "$n" != "1" ] || [ "$left" != "0" ]; then
        bbfatal "xt-xen-cfg-doma.bbappend (rpi4): the HDMI audio card rewrite did not apply cleanly to $cfg"
    fi
    bbnote "xt-xen-cfg-doma.bbappend (rpi4): DomA HDMI audio -> ${RPI4_DOMA_AUDIO_DEV}"
}

# Default is a no-op, as for rpi4_doma_gpu_720p above.
rpi4_doma_hdmi_audio_card() {
    :
}

do_install[vardeps] += "RPI4_DOMA_AUDIO_DEV_FROM RPI4_DOMA_AUDIO_DEV"
