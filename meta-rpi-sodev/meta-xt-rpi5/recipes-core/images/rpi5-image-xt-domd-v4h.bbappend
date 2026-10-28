# SPDX-License-Identifier: MIT
#
# Raspberry Pi 5 additions to the DomD image. Board-specific software only; the
# base recipe is
# meta-xt-common/meta-xt-driver-domain/recipes-core/images/rpi5-image-xt-domd-v4h.bb.

# ---------------------------------------------------------------------------
# Bluetooth in DomD, so DomA can use it.
#
# BCM2712 makes this far simpler than BCM2711. Bluetooth has its own UART
# (/soc@107c000000/serial@7d50c000, brcm,bcm7271-uart, GIC SPI 276, 3 Mbaud
# declared in the DT), the hypervisor console has its own pl011 on dedicated
# pins, and the 40-pin header's UARTs are in the RP1 behind PCIe. Three
# independent paths, so unlike the Pi 4 there is no console/Bluetooth trade-off
# to make here.
#
# The hardware side is in this layer: the boot script marks that UART
# xen,passthrough, and bcm2712-raspberrypi5-domd-vc4.dts gives DomD the UART with
# its brcm,bcm43438-bt child (BT_ON on gio line 29) and the uarta pin group, which
# TF-A muxes over SCMI. Without the passthrough hci0 never appears and btproxy has
# nothing to open.
#
# No kernel rebuild. The kernel built from bcm2712_defconfig already has BT=m,
# BT_HCIUART=m and BT_HCIUART_BCM=y, which the defconfig names, and
# SERIAL_8250_BCM7271=y, which comes from its Kconfig's `default ARCH_BRCMSTB`
# with ARCH_BRCMSTB=y. So the modules and the UART driver are already built. They
# were simply never packaged, because this image installs packagegroup-core-boot
# rather than packagegroup-base and so never sees MACHINE_EXTRA_RRECOMMENDS --
# the same reason every kernel-module-* below has to be named explicitly.
#
# bluez-firmware-rpidistro-bcm4345c0-hcd is /lib/firmware/brcm/BCM4345C0.hcd, the
# patchram hci_bcm downloads during bcm_setup(). It is the same part as on the
# Pi 4: raspberrypi5.conf recommends both 4345c0 and 4345c5, and the 43455
# firmware package contains brcmfmac43455-sdio.raspberrypi,5-model-b.bin, so this
# board's radio is the 43455. No PACKAGE_EXCLUDE surgery and no LICENSE_FLAGS
# acceptance are needed here: the base recipe only excludes
# linux-firmware-rpidistro-*, and bluez-firmware-rpidistro declares no
# LICENSE_FLAGS. The Cypress licence file arrives via RDEPENDS.
#
# bluez5-noinst-tools is here for one binary, /usr/bin/btproxy, which bridges
# hci0 to a Unix socket speaking H4 (see xt-domd-bt-proxy). It requires no
# libbluetooth, so it does not drag in bluez5 -- and therefore neither
# pi-bluetooth nor bluetoothd. That is deliberate: bluetoothd would power hci0
# up, and hci_sock_bind() in net/bluetooth/hci_sock.c then refuses the
# HCI_CHANNEL_USER bind with -EBUSY; that user channel is exactly the
# interface btproxy needs.
DOMD_BT_PACKAGES = ""
DOMD_BT_PACKAGES:raspberrypi5 = " \
    kernel-module-bluetooth \
    kernel-module-btbcm \
    kernel-module-hci-uart \
    bluez-firmware-rpidistro-bcm4345c0-hcd \
    bluez5-noinst-tools \
    xt-domd-bt-proxy \
    "
IMAGE_INSTALL:append = " ${DOMD_BT_PACKAGES}"

# ---------------------------------------------------------------------------
# Wi-Fi in DomD.
#
# Why DomD owns the radio and not DomA: the guest's RRO declares the wired vif's
# capabilities without NET_CAPABILITY_NOT_RESTRICTED, so an ordinary app in DomA
# cannot use that interface however it is NATed. The supported way to give AAOS
# an unrestricted network is a wlan0 that WifiService manages, so DomD drives
# the real BCM43455 and NATs for DomA, whose own wlan0 comes from mac80211_hwsim
# behind a shadow AP that re-beacons the SSIDs the agent reports
# (persist.vendor.doma.shadow_ap, default true); a virt_wifi wlan0 on top of the
# vif is the fallback that property switches to. Identical to the Pi 4.
#
# This file supplies the SOFTWARE. The hardware side is in this layer: the boot
# script marks the SDIO controller (/axi/mmc@1100000) xen,passthrough, and
# bcm2712-raspberrypi5-domd-vc4.dts gives DomD the mmc node with its wifi@1
# child, wl_on_reg, the shared gio bank and the sdio2 pin group that TF-A muxes
# over SCMI. That is the zephyr Dom0 flavour: with DOM0_OS=linux the controller
# stays with Dom0, domd-vc4.bb strips those nodes out of DomD's partial DT, and
# the packages below are inert.
#
# No kernel rebuild. bcm2712_defconfig carries CFG80211=m, RFKILL=m, BRCMUTIL=m,
# BRCMFMAC=m and BRCMFMAC_SDIO=y with MMC=y, so every module already exists in
# deploy. They were never packaged because this image installs
# packagegroup-core-boot rather than packagegroup-base, so MACHINE_EXTRA_RRECOMMENDS
# never applies; every kernel-module-* below is named for that reason.
#
# The base recipe excludes the Cypress firmware for all machines, and
# PACKAGE_EXCLUDE is not advisory -- it turns an explicit IMAGE_INSTALL entry into
# a build error -- so the 43455 entry has to come out of both lists. 43456 and
# 43430 stay excluded: neither part is on this board and both are
# licence-restricted.
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

# linux-firmware-rpidistro-bcm43455, not linux-firmware-bcm43455: the rpidistro
# recipe RCONFLICTS/RREPLACES the poky one and its do_install wildcard is what
# brings the NVRAM blob along with the .bin and .clm_blob. Measured on the built
# rpm, it ships brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,clm_blob,txt} -- the
# same package serves both boards, each with its own suffix.
#
# The brcmfmac-{bca,cyw,wcc} split modules are all installed. 6.18 moved the
# per-vendor firmware-interface code out of brcmfmac.ko into these three, and
# which one the chip needs follows the SDIO device ID it reports: brcmfmac's
# bcmsdh.c maps the BCM4345 ID (0x4345) to cyw and the BCM43455 ID (0xa9bf) to
# wcc. All three are a few KiB, cheaper to ship than to be wrong about at
# runtime.
#
# wireless-regdb-static, not wireless-regdb, carries /lib/firmware/regulatory.db
# and .p7s, which is where cfg80211 loads regulatory data from. Without it the
# radio is clamped to the world-roaming channel set.
DOMD_WIFI_PACKAGES = ""
DOMD_WIFI_PACKAGES:raspberrypi5 = " \
    kernel-module-cfg80211 \
    kernel-module-rfkill \
    kernel-module-brcmutil \
    kernel-module-brcmfmac \
    kernel-module-brcmfmac-cyw \
    kernel-module-brcmfmac-bca \
    kernel-module-brcmfmac-wcc \
    kernel-module-xt-masquerade \
    kernel-module-xt-conntrack \
    ${DOMD_WIFI_FW} \
    wireless-regdb-static \
    wpa-supplicant \
    iw \
    "
IMAGE_INSTALL:append = " ${DOMD_WIFI_PACKAGES}"

# ---------------------------------------------------------------------------
# brcmfmac firmware: the GENERIC file names have to exist in a dom0less guest.
#
# linux-firmware-rpidistro-bcm43455 ships only board-suffixed symlinks,
# brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,clm_blob,txt}, and
# brcmf_fw_alloc_request() builds that suffix from the DT ROOT node compatible. A
# dom0less guest has none -- /proc/device-tree/compatible in DomD is empty, the
# same property that makes of_have_populated_dt() false and costs this guest its
# regulator dummies -- so brcmfmac skips the board-specific name entirely and asks
# for the plain brcm/brcmfmac43455-sdio.bin, which the package does not contain.
#
# Measured before this fix, with the SDIO bus otherwise fully working (card
# enumerated, F1 signature read back 0x15264345 = BCM4345/6):
#   brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43455-sdio.bin
#                         failed with error -2
#   brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50
# and no wlan0. After it: "Firmware: BCM4345/6 wl0: ... version 7.45.265" and a
# wlan0 that scans 16 real APs.
#
# Point the generic names at the same targets the board-suffixed symlinks use.
# The .txt NVRAM already exists under the generic name, so only .bin and
# .clm_blob are created, with relative targets so they stay correct inside the
# image.
#
# DomD's wifi@1 node carries brcm,board-type as well, which brcmfmac reads
# before the root compatible, so with it the board-suffixed names resolve
# directly; that property alone is what the Pi 4 uses. Which of the two this
# board needs has not been told apart on the board: the firmware load was
# measured working here with both in place, so both stay.
brcmfmac_generic_fw_names() {
    d=${IMAGE_ROOTFS}/lib/firmware/brcm
    if [ ! -e $d/brcmfmac43455-sdio.raspberrypi,5-model-b.bin ]; then
        bbfatal "brcmfmac_generic_fw_names: board-suffixed 43455 firmware missing from the rootfs"
    fi
    ln -sfn ../cypress/cyfmac43455-sdio-standard.bin $d/brcmfmac43455-sdio.bin
    ln -sfn ../cypress/cyfmac43455-sdio.clm_blob     $d/brcmfmac43455-sdio.clm_blob
    for f in brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob brcmfmac43455-sdio.txt; do
        [ -e $d/$f ] || bbfatal "brcmfmac_generic_fw_names: $f still missing"
    done
}
# Only with the firmware installed; without it there is nothing to link.
ROOTFS_POSTPROCESS_COMMAND:append:raspberrypi5 = \
    "${@' brcmfmac_generic_fw_names;' if d.getVar('DOMD_WIFI_FW') else ''}"

# ---------------------------------------------------------------------------
# HEVC hardware decode in DomD (codec@800000, driver rpi-hevc-dec).
#
# WHY THIS IS NOT THE PI 4 STANZA UNDER A NEW NAME. On BCM2711 the decoder is
# reached through VCHIQ/MMAL and bcm2835-codec, and it does H.264. Neither
# applies here: BCM2712 has no vchiq node -- measured, zero hits in the shipped
# bcm2712-rpi-5-b.dtb against two in bcm2711-rpi-4-b.dtb -- and codec@800000 is
# an HEVC-only block with its own memory-mapped registers. The two boards share
# nothing but the words "hardware decode", so the Pi 4's DOMD_HWDEC_PACKAGES must
# not be copied here.
#
# WHAT THIS BUYS. It gives DomD the driver and the userspace. The DT side is in
# this layer: bcm2712-raspberrypi5-xen.dtso marks &hevc_dec xen,passthrough and the
# DomD partial DT carries the codec@800000 node, so rpi-hevc-dec binds and DomD gets
# /dev/videoN plus /dev/mediaN. (&dma40, marked in the same overlay, is HDMI audio's
# DMA engine, not the decoder's.)
#
# Even then it does not by itself make the guest able to use the block:
# rpi-hevc-dec is a STATELESS V4L2 decoder and virtio-media has no media-device
# or request-fd concept, which is why the device model synthesises a stateful
# decoder and drives this one through libavcodec.
#
# WHY videodev AND videobuf2 ARE LISTED EXPLICITLY. CONFIG_VIDEO_DEV ends up =m
# (Kconfig derives it from CONFIG_MEDIA_SUPPORT=m rather than it being in
# bcm2712_defconfig), and the rootfs had NONE of the V4L2 module packages --
# measured: zero hits for videodev, videobuf2, v4l2 or hevc in the 2026-08-27
# manifest -- even though the .ko files were built. Relying on RRECOMMENDS is
# what produced that state.
#
# ffmpeg resolves to rpidistro-ffmpeg here (PREFERRED_PROVIDER in the DomD
# configuration of rpi5-sodev.yaml), which is the only ffmpeg that can drive this
# decoder: poky's has no v4l2-request knob and upstream FFmpeg has no v4l2request
# hwaccel at all.
# It brings three things nothing else in the tree provides:
#   - the stateless HEVC hwaccel: media device and request fd handling,
#     /dev/mediaN discovery, generation-specific HEVC control layouts
#   - HEVC parsing, POC and reference-picture-set management from libavcodec
#     proper -- the genuinely hard part, and the reason this is a dependency
#     rather than a hand-rolled parser
#   - COL128/SAND detiling with an AArch64 NEON implementation, gated on the
#     `sand` PACKAGECONFIG this layer's rpidistro-ffmpeg bbappend switches back on
# It is a runtime dependency and not only a bring-up tool: the device model links
# libavcodec, so these libraries have to be in the DomD rootfs regardless.
#
# v4l-utils is here for v4l2-ctl, which is how the decoder is judged on hardware:
# --all must show V4L2_PIX_FMT_HEVC_SLICE on OUTPUT and the COL128 formats on
# CAPTURE, and --list-ctrls must show the V4L2_CID_STATELESS_HEVC_* controls.
# Without it the only evidence is dmesg, which cannot tell "bound" from "usable".
DOMD_HEVC_PACKAGES = ""
DOMD_HEVC_PACKAGES:raspberrypi5 = " \
    kernel-module-rpi-hevc-dec \
    kernel-module-videodev \
    kernel-module-mc \
    kernel-module-videobuf2-common \
    kernel-module-videobuf2-v4l2 \
    kernel-module-videobuf2-dma-contig \
    kernel-module-videobuf2-memops \
    kernel-module-v4l2-mem2mem \
    v4l-utils \
    ffmpeg \
    "
IMAGE_INSTALL:append = " ${DOMD_HEVC_PACKAGES}"

# The DomA device model's display-path switches (/run/qemu-*), created at boot by tmpfiles.d:
# the plane handoff (q11-066), media-sg-rw and fb-invalidate (q11-063) and the
# direct-scanout switches (q11-063, q11-071), plane-sand and sand-scaled (q11-081,
# q11-082); only qemu 11 reads them.
IMAGE_INSTALL:append:raspberrypi5 = " xt-qemu-display-toggles"
