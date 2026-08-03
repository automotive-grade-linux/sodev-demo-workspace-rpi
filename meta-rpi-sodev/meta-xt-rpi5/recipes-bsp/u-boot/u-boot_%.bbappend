# RPi5 16GB SKU full-memory support:
#
# 1) 0001-bcm2712-expand-MMU-to-16GB-for-dom0less-DomU.patch
#    Expand BCM2712 first mem_map region 1GB -> 16GB so U-Boot can fatload
#    DomU/DomA images anywhere in DRAM without Synchronous Abort
#    (Translation fault, level 1). U-Boot-internal access only; does not by
#    itself change what Xen sees.
#
# 2) rpi5-16gb-dram-banks.cfg (CONFIG_NR_DRAM_BANKS=16)
#    The real 8GB cap for Xen: firmware DT lists DRAM >4GB in 2GB banks and
#    the default NR_DRAM_BANKS=4 truncates both bi_dram
#    (fdtdec_setup_memory_banksize) and the /memory node re-written into the
#    DTB passed to Xen (arch_fixup_fdt -> fdt_fixup_memory_banks), capping
#    visible RAM at exactly 4 banks = 8GB on the 16GB board.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://0001-bcm2712-expand-MMU-to-16GB-for-dom0less-DomU.patch \
            file://rpi5-16gb-dram-banks.cfg \
            "
