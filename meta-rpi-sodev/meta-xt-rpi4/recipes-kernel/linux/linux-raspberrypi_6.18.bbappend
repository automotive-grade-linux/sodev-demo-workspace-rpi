# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# Board-specific kernel configuration for Raspberry Pi 4 / BCM2711.
#
# This is the RPi4 counterpart of meta-xt-rpi5's bbappend of the same name. The two
# board layers are never in bblayers together — rpi4-sodev.yaml lists meta-xt-rpi4
# where rpi5-sodev.yaml lists meta-xt-rpi5 — so this file only ever parses with
# MACHINE=raspberrypi4-64 and carries no :raspberrypi5 overrides.
#
# What it supplies to meta-xt-driver-domain's linux-raspberrypi_6.18.bb: the DT names,
# RPI_KERNEL_DEVICETREE / KERNEL_DEVICETREE, the SRC_URI device-tree set and config
# fragments, KERNEL_IMAGETYPES and COMPATIBLE_MACHINE.
#
# The Dom0/DomD split this device tree implements is the one designed on RPi5
# (DomD owns the V3D/HVS/HDMI complex direct-mapped GPA==PA because the SoC has no
# stage-2 IOMMU for V3D; Dom0 owns the rest), reworked onto BCM2711 — see
# BCM2711-DT-TRUTH.md for the measured host-DT values every address here comes from.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# -----------------------------------------------------------------------------
# Reach meta-raspberrypi's OWN files/raspberrypi4/ for rpi4-nvmem.cfg.
# -----------------------------------------------------------------------------
# meta-raspberrypi's recipes-kernel/linux/linux-raspberrypi.inc — which
# meta-xt-driver-domain's linux-raspberrypi_6.18.bb pulls in with a path-form
# `require` — carries
#     SRC_URI:append:raspberrypi4 = " file://rpi4-nvmem.cfg"
# and ships that fragment in ITS OWN recipes-kernel/linux/files/raspberrypi4/.
# FILESPATH is built from the RECIPE's directory, not from the directory of an
# included .inc, and the recipe lives in meta-xt-driver-domain, so on
# raspberrypi4-64 parsing dies with
#     ERROR: .../linux-raspberrypi_6.18.bb: Unable to get checksum for
#            linux-raspberrypi SRC_URI entry rpi4-nvmem.cfg: file could not be found
# This never fired on rpi5: MACHINEOVERRIDES has no `raspberrypi4` there, so the
# append was inert and no rpi5-side layer ever had to satisfy it.
#
# Only the MACHINE-OVERRIDE subdirectory is added, NOT meta-raspberrypi's whole
# files/ dir. base_set_filespath() (poky/meta/classes-global/base.bbclass) splits
# FILESEXTRAPATHS and puts ALL of its entries ahead of the FILE_DIRNAME-derived
# paths — note that this is true for `:append` as well as `:prepend`, because the
# split happens on the final value and the FILE_DIRNAME paths are appended after
# it. So adding files/ wholesale would let upstream's powersave.cfg and
# android-drivers.cfg shadow this project's deliberately different copies (ours
# disables HIBERNATION because mmcblk0p2 is the live rw DomD rootfs).
# files/raspberrypi4/ holds rpi4-nvmem.cfg alone, so nothing of ours can be
# shadowed, and any future rpi4-only fragment upstream adds there is picked up
# automatically.
#
# The directory is located via the very .inc the recipe `require`s (unique to
# meta-raspberrypi across all layers), so the two cannot drift apart: if upstream
# moves the .inc, the `require` fails first with a clear message.
RPI_LINUX_INC_RPI4_FILESDIR := "${@os.path.join(os.path.dirname(bb.utils.which(d.getVar('BBPATH'), 'recipes-kernel/linux/linux-raspberrypi.inc') or '/nonexistent'), 'files/raspberrypi4')}"
FILESEXTRAPATHS:append := ":${RPI_LINUX_INC_RPI4_FILESDIR}"

COMPATIBLE_MACHINE:raspberrypi4-64 = "(raspberrypi4-64)"

DOMD_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-domd"
XEN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-xen"
USB_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-usb"
MMC_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-mmc"
PCIE1_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-pcie1"
CAN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-can-${DOMD_CAN_TYPE}"
# Host-DT marker for the CAN plumbing. RPi4-only, and the reason this layer carries a
# can-passthrough.dtso that meta-xt-rpi5 has no counterpart for: the CAN overlays claim
# on-SoC controllers with real GIC SPIs (gpio 113/114, spi0 118, i2c1 117), so DomD
# cannot take them unless the host DT releases them first. On BCM2712 the same
# controllers lived inside RP1 and were covered by the single RP1 passthrough.
CAN_PASSTHROUGH_NAME = "can-passthrough"
HDMI_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-hdmi"
HDMI_PASSTHROUGH_NAME = "hdmi-passthrough"


RPI_KERNEL_DEVICETREE:append = " \
    broadcom/${DOMD_DT_NAME}.dtb \
    broadcom/${XEN_DT_NAME}.dtbo \
    broadcom/${USB_DT_NAME}.dtbo \
    broadcom/${MMC_DT_NAME}.dtbo \
    broadcom/${PCIE1_DT_NAME}.dtbo \
    broadcom/mmc-passthrough.dtbo \
    broadcom/usb-passthrough.dtbo \
    broadcom/pcie1-passthrough.dtbo \
"
RPI_KERNEL_DEVICETREE:append = " \
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_can', 'broadcom/${CAN_DT_NAME}.dtbo broadcom/${CAN_PASSTHROUGH_NAME}.dtbo', '', d)} \
"

RPI_KERNEL_DEVICETREE:append = " \
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_hdmi', \
                          ' broadcom/${HDMI_DT_NAME}.dtbo \
                            broadcom/${HDMI_PASSTHROUGH_NAME}.dtbo ', '', d)} \
"

# -----------------------------------------------------------------------------
# Restore rpi-base.inc's KERNEL_DEVICETREE formula with a STRONG assignment.
# -----------------------------------------------------------------------------
# Everything appended to RPI_KERNEL_DEVICETREE above reaches the build only through
#     conf/machine/include/rpi-base.inc
#     KERNEL_DEVICETREE ??= " ${RPI_KERNEL_DEVICETREE} ${RPI_KERNEL_DEVICETREE_OVERLAYS} "
# and on raspberrypi4-64 that weak default loses to
#     meta-virtualization/dynamic-layers/raspberrypi/conf/distro/include/
#     xen-raspberrypi4-64.inc:23
#     KERNEL_DEVICETREE ?= "broadcom/bcm2711-rpi-4-b.dtb"
# — a plain `?=`, applied at parse time, while `??=` is only resolved at the end of
# parsing. `bitbake -e linux-raspberrypi` showed the outcome verbatim:
#
#   # $KERNEL_DEVICETREE [2 operations]
#   #   set  rpi-base.inc:114 [_defaultval] " ${RPI_KERNEL_DEVICETREE} ..."
#   #   set? xen-raspberrypi4-64.inc:23 "broadcom/bcm2711-rpi-4-b.dtb"
#   KERNEL_DEVICETREE="broadcom/bcm2711-rpi-4-b.dtb"
#
# So RPI_KERNEL_DEVICETREE was computed correctly and then thrown away: the build
# succeeded but deployed exactly one .dtb, and NONE of the overlays this design
# boots through. rouge then failed at image-assembly time with
#     Can't find file '.../bcm2711-raspberrypi4-64-xen.dtbo'
# and the same would have happened for domd.dtb, the four passthrough overlays and
# — critically for the Xen console — overlays/disable-bt.dtbo, which config.txt
# names and which lives in RPI_KERNEL_DEVICETREE_OVERLAYS.
#
# There is no RPi5 equivalent of this: meta-virtualization ships no
# xen-raspberrypi5.inc, so nothing overrides rpi-base.inc there.
#
# Restating rpi-base.inc's own formula (not a hand-written list) keeps the stock
# overlay set and every future addition to it, and a strong `=` outranks `?=`
# regardless of parse order.
KERNEL_DEVICETREE = " \
    ${RPI_KERNEL_DEVICETREE} \
    ${RPI_KERNEL_DEVICETREE_OVERLAYS} \
"

KERNEL_IMAGETYPES:append = " Image.gz"

SRC_URI:append = " \
    file://${DOMD_DT_NAME}.dts;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${XEN_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${USB_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${MMC_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://${PCIE1_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://mmc-passthrough.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://usb-passthrough.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
    file://pcie1-passthrough.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom \
"

# NOT CARRIED FROM meta-xt-rpi5: the two BCM2712-only kernel patches that layer adds
# to SRC_URI here.
#   0001-drivers-mmc-host-sdhci-brcmstb-fix-no-pinctrl-case.patch
#       fixes sdhci-brcmstb, the BCM2712 SD controller. RPi4's SD is
#       brcm,bcm2711-emmc2 -> sdhci-iproc, a different driver, and it has no
#       pinctrl dependency (the slot pins are fixed-function).
#   0001-dt-Add-the-range-for-axi-to-fix-the-mipX-ranges-issu.patch
#       adds a /axi range so the BCM2712 mipX MSI controllers translate. RPi4 has
#       no /axi bus and no MIP: its PCIe MSI controller lives inside the root
#       complex (/scb/pcie@7d500000, msi-parent = <&pcie0>).
# They patch code this board never compiles (sdhci-brcmstb.c / bcm2712.dtsi), so the
# files are not in this layer either.

# inline-python (${@bb.utils.contains(...)}) inside SRC_URI breaks wrynose's
# fetcher_hashes_dummyfunc[vardepvalue] = get_hashvalue(d)
# -> Fetch(SRC_URI.split()) at finalise (the raw ${@...} survives unexpanded and is
# treated as a URL -> NoMethodError). The feature-conditional SRC_URI additions are
# therefore moved out of SRC_URI into anonymous python so the final SRC_URI value
# contains only literal file:// entries. Effective SRC_URI is unchanged.
python __anonymous() {
    arch = d.getVar('ARCH')
    subdir = "subdir=git/arch/%s/boot/dts/broadcom" % arch
    if bb.utils.contains('DISTRO_FEATURES', 'xen', True, False, d):
        d.appendVar('SRC_URI', ' file://xen-kernel-config.cfg')
        # xen-kernel-config.cfg sets the Xen PV frontends =n
        # and (being appended from __anonymous at parse finalization) lands LAST
        # in SRC_URI, so it overrode xen-config-a4b-frontend.cfg's =y under
        # merge_config (last-wins). Re-force =y AFTER it so the frontends are
        # built-in (DomD blkfront=root, netfront=vif -> both screens). Verified
        # via `bitbake -e` SRC_URI ordering. Must stay strictly after the
        # xen-kernel-config.cfg append above.
        d.appendVar('SRC_URI', ' file://xen-frontend-force.cfg')
    if bb.utils.contains('MACHINE_FEATURES', 'domd_can', True, False, d):
        can = d.getVar('CAN_DT_NAME')
        can_pt = d.getVar('CAN_PASSTHROUGH_NAME')
        d.appendVar('SRC_URI', ' file://%s.dtso;%s file://%s.dtso;%s'
                    % (can, subdir, can_pt, subdir))
    if bb.utils.contains('MACHINE_FEATURES', 'domd_hdmi', True, False, d):
        hdmi = d.getVar('HDMI_DT_NAME')
        hdmi_pt = d.getVar('HDMI_PASSTHROUGH_NAME')
        d.appendVar('SRC_URI', ' file://%s.dtso;%s file://%s.dtso;%s' % (hdmi, subdir, hdmi_pt, subdir))
    # NOT CARRIED FROM meta-xt-rpi5: the `scmi` MACHINE_FEATURE branch that appends
    # scmi-config.cfg. BCM2711 has no SCMI at all -- clocks and power come from the
    # VideoCore firmware mailbox -- so the fragment is not in this layer.
}

# Apply the shared Dom0/DomD Image config to the Dom0 build as well.
# xen-config-a4b-frontend.cfg (ARM64_4K_PAGES=y, etc.) was applied only by
# meta-xt-driver-domain, leaving the Dom0 build's kernel at 16K. full.img boots Dom0 from
# the p1 DomD (4K) Image, but the dom0-thin initramfs carries modules from the dom0 build
# (16K), so module_layout CRC mismatches (e.g. ipv6 "disagrees about version") → networkd
# fails → no external IP/SSH. This bbappend is parsed by both the dom0 and domd builds, so
# add it here to align the Dom0 kernel to 4K too and match the boot Image's CRC with its
# modules.
SRC_URI:append = " file://xen-config-a4b-frontend.cfg"

# -----------------------------------------------------------------------------
# BCM2711 hardware config fragment
# -----------------------------------------------------------------------------
# The shared Dom0/DomD Image has to carry the on-SoC drivers that replace RP1 on
# this board, plus swiotlb-xen for the restricted DMA, plus the built-in vsock
# stack DomA needs. See files/bcm2711-domd-hw.cfg.
SRC_URI:append = " file://bcm2711-domd-hw.cfg"
