# SPDX-License-Identifier: MIT
#
# Raspberry Pi 4 additions to the DomD image. Board-specific software only; the
# base recipe is
# meta-xt-common/meta-xt-driver-domain/recipes-core/images/rpi5-image-xt-domd-v4h.bb.

# ---------------------------------------------------------------------------
# Wi-Fi in DomD.
#
# Why DomD and not DomA: AAOS apps have to reach the internet, and the
# guest's RRO declares the wired vif's capabilities without
# NET_CAPABILITY_NOT_RESTRICTED, so an ordinary app cannot use it no matter how
# it is NATed. The supported way to hand AAOS an unrestricted network is a wlan0 that
# WifiService manages, so DomD owns the real radio and NATs for it. DomA's own
# wlan0 comes from mac80211_hwsim behind a shadow AP that re-beacons the SSIDs
# the agent reports (persist.vendor.doma.shadow_ap, default true); a virt_wifi
# wlan0 on top of the vif is the fallback that property switches to.
#
# The hardware side is in place: the boot script marks /soc/mmcnr@7e300000
# xen,passthrough and removes /soc/mmc@7e300000, the disabled duplicate that
# would otherwise take GIC SPI 126 (shared with emmc2); it also passes through
# the legacy DMA controller /soc/dma-controller@7e007000 for the SDIO DREQ, and
# bcm2711-raspberrypi4-64-domd-vc4.dts carries the mmcnr node with its wifi@1
# child. That is the zephyr Dom0 flavour: with DOM0_OS=linux mmcnr and its DMA
# engine stay with Dom0, domd-vc4.bb strips both out of DomD's partial DT, and
# the packages below are inert.
#
# No kernel rebuild for the radio (the NAT modules below are another matter).
# bcm2711_defconfig already carries CFG80211=m, BRCMFMAC=m and RFKILL=m, and
# BRCMFMAC_SDIO is `default y` with MMC=y, so the modules are already built --
# they were simply never packaged into this image, which installs
# packagegroup-core-boot rather than packagegroup-base and so never sees
# MACHINE_EXTRA_RRECOMMENDS. Verified on the built artefact: brcmfmac.ko carries
# 24 SDIO aliases, the BCM43455's (sdio:c*v02D0dA9BF*) and the BCM4345's
# (sdio:c*v02D0d4345*) among them, zero PCI aliases, depends on brcmutil and
# cfg80211, and requests brcm/brcmfmac43455-sdio.bin plus .clm_blob.

# The base recipe excludes the Cypress firmware for all machines. On this board
# it IS needed, and PACKAGE_EXCLUDE is not merely advisory -- it turns an
# explicit IMAGE_INSTALL entry into a build error -- so the 43455 entry has to
# come back out of both lists. 43456 and 43430 stay excluded: neither part is on
# this board, and both are licence-restricted.
BAD_RECOMMENDATIONS:remove = "linux-firmware-rpidistro-bcm43455"
PACKAGE_EXCLUDE:remove = "linux-firmware-rpidistro-bcm43455"

# linux-firmware-rpidistro declares LICENSE_FLAGS = "synaptics-killswitch"
# (meta-raspberrypi's docs/ipcompliance.md explains the flag), and this layer
# does not accept it on the user's behalf: bitbake builds the recipe only when
# LICENSE_FLAGS_ACCEPTED names the flag, which build.sh
# --accept-synaptics-killswitch arranges. As meta-raspberrypi does by only
# recommending the package from the machine configuration, the image installs
# the firmware only then; otherwise it builds without Wi-Fi firmware, and DomD
# brings up no wlan0. The flag may be named alone or as
# synaptics-killswitch_<pn>, the two forms bitbake accepts.
DOMD_WIFI_FW = "${@'linux-firmware-rpidistro-bcm43455' \
    if bb.utils.filter('LICENSE_FLAGS_ACCEPTED', \
    'synaptics-killswitch synaptics-killswitch_linux-firmware-rpidistro', d) \
    else ''}"

# linux-firmware-rpidistro-bcm43455, not linux-firmware-bcm43455. The rpidistro
# recipe RCONFLICTS/RREPLACES the poky one, is what meta-raspberrypi's own
# raspberrypi4-64.conf recommends, and its do_install wildcard is what brings in
# the NVRAM blob (brcmfmac43455-sdio.raspberrypi,4-model-b.txt) alongside the
# .bin and .clm_blob. It also drops /etc/modprobe.d/rpi-brcmfmac.conf.
#
# The brcmfmac-{bca,cyw,wcc} split modules are all installed. 6.18 moved the
# per-vendor firmware-interface code out of brcmfmac.ko into these three, and
# which one the chip needs follows the SDIO device ID it reports: brcmfmac's
# bcmsdh.c maps the BCM4345 ID (0x4345) to cyw and the BCM43455 ID (0xa9bf) to
# wcc. All three are a few KiB, cheaper to ship than to be wrong about at
# runtime.
#
# wireless-regdb-static, not wireless-regdb, is the package that carries
# /lib/firmware/regulatory.db and .p7s, which is where cfg80211 loads regulatory
# data from. Without it the radio is clamped to the world-roaming channel set.
# The two xt_ modules are the NAT half, and they need naming here even though
# bcm2711_defconfig already has NETFILTER_XT_TARGET_MASQUERADE=m and
# NETFILTER_XT_MATCH_CONNTRACK=m: =m builds the module and puts it in its own
# kernel-module-* package, and nothing in this image RDEPENDS on either, so both
# were built and left out. Measured in the rootfs of a full build: iptable_nat,
# nf_nat and nf_conntrack present, xt_MASQUERADE and xt_conntrack absent.
#
# xt_MASQUERADE is not optional. /etc/modules-load.d/domd-nat.conf names it, so
# without it systemd-modules-load fails at boot, and domd-flatbridge-up's
# `-t nat -A POSTROUTING -j MASQUERADE` then fails too, leaving DomA with no
# route out (ping 100% loss, DNS still answering because dnsmasq is local).
#
# xt_conntrack turns the stateful return rule from a logged skip into a real
# rule. domd-flatbridge-up treats it as optional because FORWARD policy is
# ACCEPT, and says so in a note; with the module present the note stops.
#
# xt_TCPMSS (the TCPMSS target) and xt_tcpudp (the tcp match its -p tcp needs) are for
# the MSS cap DomD's NAT puts on forwarded TCP; neither is pulled in by anything else.
DOMD_WIFI_PACKAGES = ""
DOMD_WIFI_PACKAGES:raspberrypi4-64 = " \
    kernel-module-cfg80211 \
    kernel-module-rfkill \
    kernel-module-brcmutil \
    kernel-module-brcmfmac \
    kernel-module-brcmfmac-cyw \
    kernel-module-brcmfmac-bca \
    kernel-module-brcmfmac-wcc \
    kernel-module-xt-masquerade \
    kernel-module-xt-conntrack \
    kernel-module-xt-tcpmss \
    kernel-module-xt-tcpudp \
    ${DOMD_WIFI_FW} \
    wireless-regdb-static \
    wpa-supplicant \
    iw \
    "
IMAGE_INSTALL:append = " ${DOMD_WIFI_PACKAGES}"

# ---------------------------------------------------------------------------
# Hardware H.264 decode in DomD.
#
# WHAT THIS IS. The only H.264 decode hardware on BCM2711 lives inside VideoCore
# and is reached through VCHIQ/MMAL by bcm2835-codec, which presents it as a V4L2
# M2M decoder -- a STATEFUL one, which is why the guest can talk to it almost
# directly once the device model proxies the node. This stanza gives DomD the
# /dev/videoN that virtio-media is pointed at (XT_DOMA_HWDEC_DEVARG in
# xt-xen-cfg-doma).
#
# The DT side is in place, and all of it is a prerequisite for any of these
# modules binding: bcm2835-codec reaches VideoCore through VCHIQ, so
# /soc/mailbox@7e00b840 is marked xen,passthrough in
# bcm2711-raspberrypi4-64-xen.dtso and DomD's partial DT carries the vchiq node;
# and vchiq on BCM2711 fails its probe without the 40-bit DMA controller, so the
# same overlay marks /scb/dma@7e007b00 and DomD's DT carries dma40 as well.
#
# The dedicated codec@7eb10000 block is HEVC-only and is not enabled here. This
# stanza is Pi 4 only because the BCM2711 decoder is the stateful VCHIQ/MMAL one;
# the Pi 5 has no vchiq node, and its only decode block, the HEVC-only
# codec@800000, is a stateless one that rpi-hevc-dec drives.
#
# No kernel rebuild: every module below is already built and sitting in deploy,
# exactly like the Wi-Fi ones. The list is the full RDEPENDS closure taken from
# the RPMs themselves, not a guess --
#   bcm2835-codec        -> bcm2835-mmal-vchiq, mc, v4l2-mem2mem,
#                           videobuf2-{common,v4l2,dma-contig}, videodev
#   bcm2835-mmal-vchiq   -> vc-sm-cma
#   videobuf2-dma-contig -> videobuf2-memops
# vchiq itself is CONFIG_BCM2835_VCHIQ=y, i.e. built in, so it binds as soon as
# its DT node and dma40's are there rather than needing a module here.
#
# v4l-utils supplies v4l2-ctl, which is how the result is judged on hardware
# (`v4l2-ctl --list-formats-out` on the decoder node). It is not in the base
# image and has to be built, same as wpa-supplicant was.
DOMD_HWDEC_PACKAGES = ""
DOMD_HWDEC_PACKAGES:raspberrypi4-64 = " \
    kernel-module-vc-sm-cma \
    kernel-module-bcm2835-mmal-vchiq \
    kernel-module-videodev \
    kernel-module-mc \
    kernel-module-videobuf2-common \
    kernel-module-videobuf2-v4l2 \
    kernel-module-videobuf2-dma-contig \
    kernel-module-videobuf2-memops \
    kernel-module-v4l2-mem2mem \
    kernel-module-bcm2835-codec \
    v4l-utils \
    "
IMAGE_INSTALL:append = " ${DOMD_HWDEC_PACKAGES}"

# ---------------------------------------------------------------------------
# Bluetooth in DomD, so DomA can use it.
#
# The BT side of the CYW43455 hangs off the pl011 (/soc/serial@7e201000) at
# 3 Mbaud, the Xen host overlay marks that pl011 xen,passthrough, and DomD's
# partial DT claims it with a brcm,bcm43438-bt child. The hypervisor console is
# on the mini UART, which is what frees the pl011 for this.
#
# WHY 3 Mbaud AND NOT miniuart-bt: a UART at 8N1 carries baud/10 bytes per
# second. The mini UART's 230400 gives 184 kbps of HCI payload, and A2DP SBC
# needs 229 kbps (standard) to 328 kbps (high quality) -- which is why
# overlays/README says miniuart-bt "should only be used with low-bandwidth
# peripherals". pl011's 3 Mbaud gives 2400 kbps.
#
# No kernel rebuild, same as the Wi-Fi and codec stanzas above: the kernel
# built from bcm2711_defconfig already has BT=m, BT_BCM=m, BT_HCIUART=m,
# BT_HCIUART_SERDEV=y, BT_HCIUART_H4=y and BT_HCIUART_BCM=y. The defconfig names
# BT, BT_HCIUART and BT_HCIUART_BCM; Kconfig's select and default supply the
# rest. So kernel-module-{bluetooth,btbcm,hci-uart} are already in
# tmp/deploy/rpm. They were never packaged, because this image installs
# packagegroup-core-boot rather than packagegroup-base and so never sees
# MACHINE_EXTRA_RRECOMMENDS.
#
# bluez-firmware-rpidistro-bcm4345c0-hcd is /lib/firmware/brcm/BCM4345C0.hcd, the
# patchram hci_bcm downloads during bcm_setup(). It is a DIFFERENT recipe from
# linux-firmware-rpidistro, which carries the Wi-Fi blobs. No PACKAGE_EXCLUDE
# surgery is needed -- the base recipe only excludes linux-firmware-rpidistro-* --
# and unlike the Wi-Fi firmware there is no LICENSE_FLAGS to accept; the Cypress
# licence file comes along via RDEPENDS.
#
# bluez5-noinst-tools is here for ONE binary, /usr/bin/btproxy, which bridges
# hci0 to a Unix socket speaking H4 (see xt-domd-bt-proxy). Checked with
# `rpm -qp --requires`: it needs only libc, libdbus, libglib, libreadline and
# libudev -- NOT libbluetooth. So it does not drag in bluez5 itself, and
# therefore neither pi-bluetooth nor bluetoothd. That is deliberate, not luck:
# bluetoothd would power hci0 up, and hci_sock_bind() in
# net/bluetooth/hci_sock.c then refuses the HCI_CHANNEL_USER bind with -EBUSY;
# that user channel is exactly the interface btproxy needs.
DOMD_BT_PACKAGES = ""
DOMD_BT_PACKAGES:raspberrypi4-64 = " \
    kernel-module-bluetooth \
    kernel-module-btbcm \
    kernel-module-hci-uart \
    bluez-firmware-rpidistro-bcm4345c0-hcd \
    bluez5-noinst-tools \
    xt-domd-bt-proxy \
    "
IMAGE_INSTALL:append = " ${DOMD_BT_PACKAGES}"

# The DomA device model's display-path switches (/run/qemu-*), created at boot by tmpfiles.d:
# ISP / SAND direct scanout (q11-063) and the HMI plane handoff (q11-066); only qemu 11 reads them.
IMAGE_INSTALL:append:raspberrypi4-64 = " xt-qemu-display-toggles"
