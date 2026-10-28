# RPi5: give DomU's display one overlay plane (xt-xen-cfg-domu's
# XT_DOMU_OVERLAY_PLANES), so xdg-cluster-receiver's window is scanned out over
# the cluster instead of making both DomU's and DomD's compositors draw with the
# GPU.
#
# Measured on the Raspberry Pi 5 8GB (2026-10-15, with q11-070 and DomA's video patches
# of later commits of this series, the AGL cluster on Venus at 1920x720@59.9, the output
# and receiver window place that a later commit of this series sets, DomA idle, V3D
# render queue over 10 s): 17.8% with the receiver window idle, 17.5-17.7% while it
# receives a 30 fps MJPEG RTP stream, 17.5% with the receiver stopped; the upstream
# wl_shm receiver idle, 54.0% (198 jobs/s).
XT_DOMU_OVERLAY_PLANES ?= "1"
