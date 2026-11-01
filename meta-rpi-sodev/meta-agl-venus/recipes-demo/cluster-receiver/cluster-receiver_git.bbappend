# xdg-cluster-receiver: show the window from linear gbm buffers handed over as dma-bufs
# instead of a wl_shm buffer redrawn every frame, so agl-compositor can put it on DomU's
# overlay plane (xt-xen-cfg-domu's XT_DOMU_OVERLAY_PLANES) rather than composing it and
# the cluster under it with the GPU. See the patch.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://0001-show-the-window-from-linear-dma-buf-buffers.patch"
DEPENDS += "virtual/libgbm"
# The stream now ends in videoconvert ! videoscale ! appsink instead of waylandsink.
RDEPENDS:${PN} += "gstreamer1.0-plugins-base-videoconvertscale gstreamer1.0-plugins-base-app"
