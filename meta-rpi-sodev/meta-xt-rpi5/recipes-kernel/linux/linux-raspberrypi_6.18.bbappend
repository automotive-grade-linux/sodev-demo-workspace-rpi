# Overlay on the PRISTINE meta-xt-rpi5
# recipes-kernel/linux/linux-raspberrypi_6.12.bbappend.
#
# rpi5-0005 + rpi5-0006: Xen device-tree overlay (bcm2712-raspberrypi5-xen.dtso)
# for the Dom0/DomD split:
#   rpi5-0005  DomD GPU passthrough + Dom0 device ownership + 2 GB static-mem
#              (Dom0 owns everything except the V3D/HVS/HDMI complex, which is
#              direct-mapped (GPA==PA) into DomD because BCM2712 has no stage-2
#              IOMMU for V3D).
#   rpi5-0006  raise DomD static memory to 4 GB (16 GB SKU; two qemu
#              device-models + weston + VHAL backend OOM-killed xl devd at 2 GB).
#
# Mechanism: the base meta-xt-rpi5 bbappend pulls the Xen DT overlay into the
# kernel source tree with
#     SRC_URI += " file://${XEN_DT_NAME}.dtso;subdir=git/arch/${ARCH}/boot/dts/broadcom"
# where XEN_DT_NAME = "bcm2712-raspberrypi5-xen". A SRC_URI patch cannot modify a
# WORKDIR-copied source file, so instead this layer SHADOWS the .dtso: its files/
# holds the final (rpi5-0005 + rpi5-0006 applied) bcm2712-raspberrypi5-xen.dtso,
# and FILESEXTRAPATHS:prepend puts this layer's files/ ahead of the base files/
# in the bitbake file search path, so bitbake fetches our copy. The base
# meta-xt-rpi5 .dtso stays pristine; we do not re-declare SRC_URI.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# =============================================================================
# re-host: meta-xt-rpi5 (pristine) linux-raspberrypi_6.12.bbappend body, verbatim.
# Since the pristine _6.12 no longer attaches once we add a proper _6.18.bb, the body is
# moved here (_%). It supplies the DT names / RPI_KERNEL_DEVICETREE / SRC_URI (sdhci+axi
# patch, xen/scmi cfg, DT set) / KERNEL_IMAGETYPES / COMPATIBLE_MACHINE to the 6.18 recipe.
# The shadow xen.dtso keeps the existing files/ via cp -n (the patched version wins via prepend).
# =============================================================================
COMPATIBLE_MACHINE:raspberrypi5 = "(raspberrypi5)"

DOMD_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-domd"
XEN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-xen"
USB_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-usb"
MMC_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-mmc"
PCIE1_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-pcie1"
CAN_DT_NAME = "${RPI_SOC_FAMILY}-${MACHINE}-can-${DOMD_CAN_TYPE}"
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
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_can', 'broadcom/${CAN_DT_NAME}.dtbo', '', d)} \
"

RPI_KERNEL_DEVICETREE:append = " \
    ${@bb.utils.contains('MACHINE_FEATURES', 'domd_hdmi', \
                          ' broadcom/${HDMI_DT_NAME}.dtbo \
                            broadcom/${HDMI_PASSTHROUGH_NAME}.dtbo ', '', d)} \
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
}

# [P1 fix] Apply the shared Dom0/DomD Image config to the Dom0 build as well.
# xen-config-a4b-frontend.cfg (ARM64_4K_PAGES=y, etc.) was applied only by the original
# meta-xt-driver-domain, leaving the Dom0 build's kernel at 16K. full.img boots Dom0 from the p1
# DomD (4K) Image, but the dom0-thin initramfs carries modules from the dom0 build (16K), so
# module_layout CRC mismatches (e.g. ipv6 "disagrees about version") → networkd fails →
# no external IP/SSH. This bbappend is a shared layer parsed by both the dom0/domd builds,
# so add it here to align the Dom0 kernel to 4K too and match the boot Image's CRC with its modules.
SRC_URI:append = " file://xen-config-a4b-frontend.cfg"
