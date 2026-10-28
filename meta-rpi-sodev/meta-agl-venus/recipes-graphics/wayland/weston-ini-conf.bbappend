# Run the cluster's Virtual-1 output at the size the device model shows, 1920x720 at
# 59.9 Hz. meta-agl's virtual-*.cfg ask for 1920x1080, while domu.cfg gives the guest a
# 1920x720 virtio-gpu (xres=1920,yres=720) and qemu a 1920x720 window, so the
# cluster drew 1.5 times the pixels it shows and qemu scaled every frame down again.
#
# A modeline, not "mode=1920x720": weston then takes qemu's EDID mode for that size,
# 75 Hz (its preferred one), and the cluster draws 75 frames a second for a 60 Hz panel.
# The modeline is the 1920x720 CVT timing (59.86 Hz) that meta-xt-driver-domain's
# weston.ini gives the Raspberry Pi 5's HDMI-A-1. In the guest it only sets the size and
# the rate the cluster draws at; the board's own panel timing stays DomD's weston.ini.
#
# Measured on the Raspberry Pi 5 only (2026-10-15, AGL cluster on Venus, GL
# SurfaceFlinger in DomA idle): V3D render busy 74% -> 57% (3.9 -> 2.9 ms a job).
#
# The grep after the sed stops the build if meta-agl's fragments stop saying
# mode=1920x1080, rather than shipping them unchanged; it also passes on a rerun of
# do_compile over fragments this already rewrote. The fragments are rewritten in
# place, so a new VIRTUAL_OUTPUT_MODE has to unpack them afresh: do_unpack depends on it.
VIRTUAL_OUTPUT_MODE = "111.75 1920 2016 2208 2496 720 723 733 748 -hsync +vsync"
do_unpack[vardeps] += "VIRTUAL_OUTPUT_MODE"

do_compile:prepend:virtio-aarch64() {
    for f in ${WORKDIR}/virtual-0.cfg ${WORKDIR}/virtual-90.cfg \
             ${WORKDIR}/virtual-180.cfg ${WORKDIR}/virtual-270.cfg; do
        sed -i -e 's/^mode=1920x1080$/mode=${VIRTUAL_OUTPUT_MODE}/' $f
        grep -qxF 'mode=${VIRTUAL_OUTPUT_MODE}' $f
    done
}
