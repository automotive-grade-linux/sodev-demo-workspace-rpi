# BCM2712 / Raspberry Pi 5 kernel delta for the Xen Dom0/DomD split, on
# meta-xt-driver-domain's linux-raspberrypi_6.18.bb.
#
# This file declares its own SRC_URI: the device-tree set in files/ (the Xen host
# overlay bcm2712-raspberrypi5-xen.dtso -- DomD GPU passthrough, Dom0 device
# ownership, 4 GB static-mem; the SCMI host overlay; the base DomD partial DT and
# its feature overlays), the two EPAM kernel patches, and the Kconfig fragments.
# The host overlay's history: a 2 GB static-mem map first, raised to 4 GB when two
# qemu device-models + weston + the VHAL backend OOM-killed xl devd at 2 GB.
#
# Of the device trees only bcm2712-raspberrypi5-xen.dtbo and the SCMI host overlay
# reach p1 and are applied by boot.cmd; the DomD DT that boot.cmd loads is
# recipes-guest/domd-vc4's. The base -domd.dts and the mmc/usb/pcie1/hdmi/can
# overlays are the upstream single-overlay flow, kept building (and, for the
# unconditional ones, deployed) so that path stays available.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

COMPATIBLE_MACHINE:raspberrypi5 = "(raspberrypi5)"

DOMD_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-domd"
XEN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-xen"
USB_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-usb"
MMC_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-mmc"
PCIE1_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-pcie1"
CAN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-can-${DOMD_CAN_TYPE}"
HDMI_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-hdmi"
HDMI_PASSTHROUGH_NAME = "hdmi-passthrough"
# Host (hypervisor) DT overlay that publishes the TF-A SCMI server to Xen. This is
# OURS, not the bcm2712-raspberrypi5-xen-scmi.dtso meta-xt-driver-domain used to ship:
# that one flipped the ROOT node to #size-cells = <1> and wrote the EPAM-downstream
# property name xen,arm_sci, where upstream Xen reads xen,sci_type. The scmi-host
# .dtso header documents both in full.
SCMI_HOST_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-scmi-host"


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
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_can', 'broadcom/${CAN_DT_NAME}.dtbo', '', d)} \
"

RPI_KERNEL_DEVICETREE:append = " \
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_hdmi', \
                          ' broadcom/${HDMI_DT_NAME}.dtbo \
                            broadcom/${HDMI_PASSTHROUGH_NAME}.dtbo ', '', d)} \
"

RPI_KERNEL_DEVICETREE:append = " \
    ${@bb.utils.contains('MACHINE_FEATURES', 'scmi', 'broadcom/${SCMI_HOST_DT_NAME}.dtbo', '', d)} \
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
    file://0001-drivers-mmc-host-sdhci-brcmstb-fix-no-pinctrl-case.patch \
"

SRC_URI:append = " file://0001-dt-Add-the-range-for-axi-to-fix-the-mipX-ranges-issu.patch"

# inline-python (${@bb.utils.contains(...)}) inside
# SRC_URI breaks wrynose's fetcher_hashes_dummyfunc[vardepvalue] = get_hashvalue(d)
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
        d.appendVar('SRC_URI', ' file://%s.dtso;%s' % (can, subdir))
    if bb.utils.contains('MACHINE_FEATURES', 'domd_hdmi', True, False, d):
        hdmi = d.getVar('HDMI_DT_NAME')
        hdmi_pt = d.getVar('HDMI_PASSTHROUGH_NAME')
        d.appendVar('SRC_URI', ' file://%s.dtso;%s file://%s.dtso;%s' % (hdmi, subdir, hdmi_pt, subdir))
    if bb.utils.contains('MACHINE_FEATURES', 'scmi', True, False, d):
        d.appendVar('SRC_URI', ' file://scmi-config.cfg')
        scmi_host = d.getVar('SCMI_HOST_DT_NAME')
        d.appendVar('SRC_URI', ' file://%s.dtso;%s' % (scmi_host, subdir))
}

# [P1 fix] Apply the shared Dom0/DomD Image config to the Dom0 build as well.
# xen-config-a4b-frontend.cfg (ARM64_4K_PAGES=y, etc.) was applied only by the original
# meta-xt-driver-domain, leaving the Dom0 build's kernel at 16K. full.img boots Dom0 from the p1
# DomD (4K) Image, but the dom0-thin initramfs carries modules from the dom0 build (16K), so
# module_layout CRC mismatches (e.g. ipv6 "disagrees about version") → networkd fails →
# no external IP/SSH. This bbappend is a shared layer parsed by both the dom0/domd builds,
# so add it here to align the Dom0 kernel to 4K too and match the boot Image's CRC with its modules.
SRC_URI:append = " file://xen-config-a4b-frontend.cfg"

# DomA/DomU -> internet NAT. This board's defconfig builds none of the legacy
# iptables tables (ip_tables.ko / iptable_nat.ko / iptable_filter.ko), so
# without this fragment domd-flatbridge-up cannot install its rules and DomA
# comes up "connected, no internet" (the wlan0 NetworkAgentInfo never gains
# VALIDATED). The Pi 4 builds the same set from
# meta-xt-rpi4/recipes-kernel/linux/files/bcm2711-domd-hw.cfg, and the
# userspace half (modules-load.d/domd-nat.conf and domd-flatbridge-up) comes
# from meta-xt-common for both boards. See files/bcm2712-domd-nat.cfg for the
# measurements that pinned it down.
SRC_URI:append = " file://bcm2712-domd-nat.cfg"
