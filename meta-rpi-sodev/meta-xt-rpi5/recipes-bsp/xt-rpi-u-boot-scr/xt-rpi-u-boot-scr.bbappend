FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# RPi5 boot script selection — Dom0-OS aware, BOTH variants use a static
# board-tuned boot.cmd. The parent .1/.2/.3.in assembly was always discarded on
# rpi5 (this override re-ran mkimage over it), so those three template fragments
# were removed and this is now the SOLE do_compile on rpi5 — the only machine
# COMPATIBLE_MACHINE (^raspberrypi5$) allows.
#
# WHY NOT the assembled .2.in template for zephyr: its module load addresses are
# template values for tiny demo kernels (zephyr.bin@0xe00000, DomD Image@0x1200000,
# domd.dtb@0x1d00000, xen@0x2000000, xenpolicy@0x2300000). Our DomD Image is ~27 MB
# and loaded at 0x1200000 it OVERRUNS domd.dtb/xen/xenpolicy, so `booti` runs a
# clobbered Xen -> crash -> reset -> reboot loop (observed on real hardware).
# It also fatloads "Image.gz" (our file is "Image") and never loads the DomD
# initramfs. Root-caused from the on-SD boot.scr.
#
# FIX: use board-tuned static scripts with proven, non-overlapping addresses
# (xen@0x2000000 / DomD kernel@0xc000000 / dtb@0xa000000; 0x10000000 = former DomD
#  initramfs slot, now unused):
#   - DOM0_OS=linux  -> boot.cmd.xen.linux-dom0.in   (Dom0 = Linux Image@0x4000000)
#   - DOM0_OS=zephyr -> boot.cmd.xen.zephyr-dom0.in      (/chosen/dom0 =
#                       zephyr.bin@0x4000000)
# The two scripts share the DomD dom0less block, the GPU/HDMI/RP1 passthrough set
# and xsm=dummy, but they are not byte-identical. Three deliberate differences,
# each explained where it appears in the scripts:
#   - the Dom0 kernel (Image vs zephyr.bin);
#   - who owns the SoC SDHCI. The zephyr script marks mmc@fff000
#     xen,passthrough so DomD gets it; the linux script leaves it with Dom0;
#   - consequently DomD's root=. zephyr -> /dev/mmcblk0p2 (DomD owns the SD),
#     linux -> /dev/xvda (Dom0 block-attaches p2), and only the linux script
#     loads a Dom0 initramfs as /chosen/dom0/module@1.
# DOM0_OS is injected into this (DomD) build by rpi5-sodev.yaml.
SRC_URI:append:raspberrypi5 = " file://boot.cmd.xen.linux-dom0.in file://boot.cmd.xen.zephyr-dom0.in"

# Match the branch default; the yaml overrides it per --DOM0_OS.
DOM0_OS ??= "zephyr"

# Board RAM size: 16g (default) or 8g. rpi5-sodev.yaml injects it from the BOARD_RAM
# moulin parameter (build.sh --ram=16g|8g). Both boot scripts carry
# `setenv board_ram BOARD_RAM_PLACEHOLDER` and branch on the resulting env var at run
# time, so the whole 8 GiB delta lives in the boot scripts (two `fdt set` lines) and
# tools/check-memory-map.py can validate both values without building anything.
BOARD_RAM ??= "16g"

do_compile:raspberrypi5() {
    case "${BOARD_RAM}" in
        8g|16g) ;;
        *) bbfatal "BOARD_RAM must be 16g or 8g (got '${BOARD_RAM}')" ;;
    esac
    if [ "${DOM0_OS}" = "linux" ]; then
        BOOTCMD_SRC="boot.cmd.xen.linux-dom0.in"
    else
        BOOTCMD_SRC="boot.cmd.xen.zephyr-dom0.in"
    fi
    bbnote "rpi5 ${DOM0_OS}-dom0 board_ram=${BOARD_RAM}: using board-tuned ${BOOTCMD_SRC} and re-running mkimage"
    cp ${UNPACKDIR}/${BOOTCMD_SRC} ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}
    # Substitute the single placeholder line. Fail loudly if it is not there: a
    # silently un-substituted script would leave `setenv board_ram
    # BOARD_RAM_PLACEHOLDER`, which matches neither branch, so an 8 GiB board would
    # get the 16 GiB map -- DomD's static-mem would stay 4096 MiB and the SD would
    # boot into an over-committed layout with no diagnostic.
    if ! grep -q '^setenv board_ram BOARD_RAM_PLACEHOLDER$' ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}; then
        bbfatal "BOARD_RAM_PLACEHOLDER not found in ${BOOTCMD_SRC}"
    fi
    sed -i "s/^setenv board_ram BOARD_RAM_PLACEHOLDER\$/setenv board_ram ${BOARD_RAM}/" \
        ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}
    rm -f ${B}/${UBOOT_BOOT_SCRIPT}
    cd ${B} && mkimage -A ${UBOOT_ARCH} -T script -C none -n "Boot script" \
        -d "${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}" ${UBOOT_BOOT_SCRIPT}
}

# The boot script is flavour- AND board-dependent, so both must be part of the task
# hash; otherwise building 16g then 8g (or zephyr then linux) against one sstate
# cache reuses the wrong boot.scr.
do_compile[vardeps] += "DOM0_OS BOARD_RAM"
