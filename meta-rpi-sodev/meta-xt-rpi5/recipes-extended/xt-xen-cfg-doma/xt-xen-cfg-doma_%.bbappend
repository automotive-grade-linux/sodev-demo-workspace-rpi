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

# DomA's overlay planes, as on the Raspberry Pi 4 board the display path was measured
# on (2026-10-02 .. 10-13): three overlay planes let drm_hwcomposer scan the app and the
# system bars out as DEVICE layers instead of SurfaceFlinger compositing them on the GPU
# (with two planes on qemu 10.0.2, before the kernel refused a plane not shown whole, a
# 640x360 video in a WebView dropped 25% of its frames instead of 35% there). Both halves
# come from the common recipe; the gl lane (qemu 7.0.0) gets no overlays whatever this
# says. On this board (2026-10-15, with plane scaling as well and no linear scanout
# buffers) SurfaceFlinger still composed one CLIENT layer, so the planes went unused.
# A default (?=), so a local.conf can override it; 0 turns both halves off.
XT_DOMA_OVERLAY_PLANES ?= "3"
