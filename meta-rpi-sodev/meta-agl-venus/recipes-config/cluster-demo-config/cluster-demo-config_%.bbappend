# Fit the receiver window into the 1920x720 cluster output
# (weston-ini-conf.bbappend). meta-agl-demo's AGL.conf.flutter gives it
# 420x472 at (750,290), a place on a 1080-line output. On 720 lines the
# dashboard (with its 0002) draws the warning lamps from about y=560, below
# the clock box. At y=290 the window's bottom 42 lines are off the screen,
# and moved up to y=124 it hid the lamps.
#
# So 356x400, the 420x472 aspect ratio, at (782,141): centred across, and
# between the two vertically. The receiver (with this layer's 0001) scales
# the stream to its window, and a window that is not cut by the screen's
# edge is what DomU's overlay plane (XT_DOMU_OVERLAY_PLANES) can take: it
# shows a buffer whole and unscaled.
#
# Unconditional, unlike the weston-ini-conf append: this recipe is
# allarch, and this layer is in the AGL build only for the DomU guest,
# whose output that append sets to 720 lines (build.sh's AGL_MACHINE
# defaults to virtio-aarch64; another machine would need its own geometry).
do_install:append() {
    sed -i -e 's/^geometry=420x472+750,290$/geometry=356x400+782,141/' \
        ${D}${sysconfdir}/xdg/AGL.conf.flutter
    grep -qxF 'geometry=356x400+782,141' ${D}${sysconfdir}/xdg/AGL.conf.flutter
}
