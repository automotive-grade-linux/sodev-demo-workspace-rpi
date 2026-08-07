# =============================================================================
# Raspberry Pi 4 / BCM2711 U-Boot delta
# =============================================================================
# The recipe still builds the xen-troops fork (see u-boot-src.inc): its
# rpi5-2024.04-xt branch carries the Xen-oriented changes this workspace relies
# on, and arch/arm/mach-bcm283x/init.c board_ids already contains a
# "brcm,bcm2711" entry, so the right MMU map is selected at run time from the
# firmware device tree. Three RPi4-specific adjustments are layered on top:
#
# 1) rpi4-bcm2711.cfg
#    The fork's rpi_arm64_defconfig hard-sets CONFIG_BCM2712=y. Switch to
#    CONFIG_BCM2711_64B so the RP1-over-PCIe probe in board_late_init() and the
#    arm64 Image header that CONFIG_BCM2712 pulls in both go away.
#
# 2) rpi4-dram-banks.cfg (CONFIG_NR_DRAM_BANKS=8)
#    The 8 GiB RPi4 firmware DT describes DRAM in four banks, exactly at
#    U-Boot's default limit. bi_dram feeds both the LMB bounds checks used by
#    fatload and the /memory node arch_fixup_fdt() rewrites into the DTB Xen
#    reads, so a truncation there silently caps the RAM Xen sees.
#
# 3) 0001-bcm2711-map-DRAM-above-4GB-for-dom0less-modules.patch
#    bcm2711_mem_map stops at 0xfc000000, so U-Boot cannot fatload into the
#    upper 4 GiB of an 8 GiB board. The current boot.cmd keeps every module
#    below that line on purpose, but the whole low 4 GiB is also where Dom0's and
#    DomD's static memory lives, so this reopens the >4 GiB region for future
#    dom0less guests. Same motivation as the RPi5 port's "expand MMU to 16 GB"
#    patch, which was BCM2712-only and has been dropped.
#
# REMOVED versus the RPi5 layer:
#   0001-bcm2712-expand-MMU-to-16GB-for-dom0less-DomU.patch  (BCM2712 mem_map)
#   rpi5-16gb-dram-banks.cfg                                 (superseded by 2)
# =============================================================================

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:raspberrypi4-64 = " \
    file://0001-bcm2711-map-DRAM-above-4GB-for-dom0less-modules.patch \
    file://rpi4-bcm2711.cfg \
    file://rpi4-dram-banks.cfg \
    "
