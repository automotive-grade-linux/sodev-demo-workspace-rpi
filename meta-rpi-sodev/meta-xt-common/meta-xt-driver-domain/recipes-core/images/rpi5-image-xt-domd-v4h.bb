SUMMARY = "DomD ext4 image with full driver-domain IMAGE_INSTALL pattern"
DESCRIPTION = "\
    DomD ext4 image building on rpi5-image-xt-domd-vc4.bb with the full \
    driver-domain package set (xen tools, qemu virtio backend, \
    weston GPU stack). \
\
    Adds: glmark2, \
          coreutils, xen-tools-xencommons \
    \
    Note: the core-image-weston base cannot be used directly (X11 fetch fails); \
    the vc4 base (core-image-minimal based) is reused and weston is pulled in \
    via GFX_PACKAGES instead."

# Base: rpi5-image-xt-domd-vc4 (xen bits + xt-rpi5-domain etc.)
require recipes-core/images/rpi5-image-xt-domd-vc4.bb

# Additional driver-domain packages.
IMAGE_INSTALL:append = " \
    xen-tools-xencommons \
    "

# Install qemu when the enable_virtio DISTRO_FEATURE is set. This line is the
# sole supplier of the thin qemu-system-aarch64 package (the full `qemu` was
# removed from the vc4 base); the vmsep DISTRO_FEATURE splits it out.
# Note: qemu-keymaps is excluded (not packaged in meta-xt-qemu).
# kernel-module-vhost-net = CONFIG_VHOST_NET=m, installed explicitly for /dev/vhost-net.
IMAGE_INSTALL:append = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' qemu-system-aarch64 kernel-module-vhost-net', '', d)}"

# Standard tools
IMAGE_INSTALL:append = " \
    glmark2 \
    coreutils \
    "

# xt-rpi5-domain (boot-time vCPU pinning) already comes from the vc4 base above.

# Exclude license-restricted packages (RPi5 Wi-Fi firmware not needed).
BAD_RECOMMENDATIONS += "linux-firmware-rpidistro-bcm43455 linux-firmware-rpidistro-bcm43456 linux-firmware-rpidistro-bcm43430"
PACKAGE_EXCLUDE += "linux-firmware-rpidistro-bcm43455 linux-firmware-rpidistro-bcm43456 linux-firmware-rpidistro-bcm43430"

# NOTE: xen-network's /etc/systemd/network/{xenbr0.netdev,50-xenbr0.network} must
# NOT be removed from this image. They are load-bearing: domd-flatbridge-up
# does NOT create the bridge (it starts at `ip link set xenbr0 up`), it only moves
# the address onto an existing xenbr0 that systemd-networkd built from
# xenbr0.netdev. Without the netdev the script flushes eth0's 192.168.10.11 first
# and then fails to add 192.168.10.10 to a nonexistent xenbr0 -- silently, because
# every command is 2>/dev/null -- which drops DomD off the network entirely.
# Verified on hardware: DomD answered on .10.11 early in boot and then became
# unreachable on both addresses once the flat bridge ran.

# NOTE: no 99-bind-input-devices.rules here, and none must be added. A catch-all `SUBSYSTEM=="input", KERNEL=="event*",
# ENV{WL_OUTPUT}="HDMI-A-1"`, to make sure the DomD kiosk-shell captured every input
# device. udev applies rules in lexical filename order, so that 99- rule ran AFTER
# rp1-touch-bridge's 72-rp1-touch-output.rules and overwrote the touchscreen's
# WL_OUTPUT="HDMI-A-2" with HDMI-A-1 -- every touch on the AAOS panel was delivered
# to the DomU cluster instead.
#
# It went unnoticed because it only ever shipped in this ext4 image, which used to be
# an unused fallback; the RAM initramfs image that used to be the shipping DomD rootfs
# never carried the rule. It became live the moment this image became the rootfs.
# Verified on hardware: /dev/input/event0 (ID_INPUT_TOUCHSCREEN=1) came up with
# WL_OUTPUT=HDMI-A-1, and touching the AAOS panel moved a pointer on the cluster.
#
# 72-rp1-touch-output.rules already routes by device identity (touchscreen ->
# HDMI-A-2, with the mouse-emulation duplicates ignored via LIBINPUT_IGNORE_DEVICE),
# which is the correct and sufficient policy. Do not add a catch-all back.
