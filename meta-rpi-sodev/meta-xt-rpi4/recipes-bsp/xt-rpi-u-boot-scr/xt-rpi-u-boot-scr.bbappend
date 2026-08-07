# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# ${THISDIR}/files is enough here: OE builds FILESPATH from FILESOVERRIDES
# (= ${MACHINEOVERRIDES}:${DISTROOVERRIDES}) and therefore searches files/<machine>/
# automatically, so the templates can live in files/raspberrypi4-64/ while the
# file://boot.cmd.xen.*.in entries stay unchanged. Adding a board means creating
# files/<machine>/ and one SRC_URI:append:<machine>; the recipe body stays untouched.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# =============================================================================
# RPi4 boot-script selection — Dom0-OS aware; BOTH variants use a static
# board-tuned boot.cmd.
# =============================================================================
# The parent recipe's .1/.2/.3.in template assembly is not used: its load
# addresses are sized for tiny demo kernels, so a real 30 MiB DomD Image would
# overrun the DTB/xen/xenpolicy slots and `booti` would run a clobbered
# hypervisor. The two static scripts instead carry the BCM2711 physical memory
# map worked out in bcm2711-raspberrypi4-64-xen.dtso:
#   xen@0x2000000 / xen.dtbo@0x2200000 / Dom0@0x2400000 /
#   DomD dtb@0xa0000000 / DomD kernel@0xa4000000 /
#   Dom0 initramfs@0xb0000000 / DomD initramfs@0xc0000000
# with DomD static-mem at 0x08000000+384M, 0x40000000+1G, 0x80000000+512M and the
# 0x20000000-0x30000000 hole reserved for Dom0's bank[0].
#
#   - DOM0_OS=linux  -> boot.cmd.xen.linux-dom0.in   (Dom0 = Linux Image; Dom0
#                       keeps the SD card, so emmc2's expgpio-backed regulator
#                       phandles are stripped)
#   - DOM0_OS=zephyr -> boot.cmd.xen.zephyr-dom0.in  (Dom0 = zephyr.bin, no
#                       initramfs; the SD card and its regulators go to DomD)
#
# DOM0_OS is injected into this (DomD) build by rpi4-sodev.yaml.
# =============================================================================
SRC_URI:append:raspberrypi4-64 = " file://boot.cmd.xen.linux-dom0.in file://boot.cmd.xen.zephyr-dom0.in"

# Match the branch default; the yaml overrides it per --DOM0_OS.
DOM0_OS ??= "zephyr"

# Board RAM size: 8g (default) or 4g. rpi4-sodev.yaml injects it from the BOARD_RAM
# moulin parameter (build.sh --ram=8g|4g). The boot scripts carry
# `setenv board_ram BOARD_RAM_PLACEHOLDER` and branch on the resulting env var at
# run time, so the whole 4 GiB delta lives in ONE file that
# The memory-map cross-check can validate for both values.
BOARD_RAM ??= "8g"

do_compile:raspberrypi4-64() {
    case "${BOARD_RAM}" in
        4g|8g) ;;
        *) bbfatal "BOARD_RAM must be 4g or 8g (got '${BOARD_RAM}')" ;;
    esac
    if [ "${DOM0_OS}" = "linux" ]; then
        BOOTCMD_SRC="boot.cmd.xen.linux-dom0.in"
    else
        BOOTCMD_SRC="boot.cmd.xen.zephyr-dom0.in"
    fi
    bbnote "rpi4 ${DOM0_OS}-dom0 board_ram=${BOARD_RAM}: using board-tuned ${BOOTCMD_SRC} and re-running mkimage"
    cp ${UNPACKDIR}/${BOOTCMD_SRC} ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}
    # Substitute the single placeholder line. Fail loudly if it is not there: a
    # silently un-substituted script would leave `setenv board_ram
    # BOARD_RAM_PLACEHOLDER`, which matches neither branch, so the 4 GiB board would
    # get the 8 GiB map and Xen would panic on an unsatisfiable dom0_mem.
    if ! grep -q '^setenv board_ram BOARD_RAM_PLACEHOLDER$' ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}; then
        bbfatal "BOARD_RAM_PLACEHOLDER not found in ${BOOTCMD_SRC}"
    fi
    sed -i "s/^setenv board_ram BOARD_RAM_PLACEHOLDER\$/setenv board_ram ${BOARD_RAM}/" \
        ${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}
    rm -f ${B}/${UBOOT_BOOT_SCRIPT}
    cd ${B} && mkimage -A ${UBOOT_ARCH} -T script -C none -n "Boot script" \
        -d "${WORKDIR}/${UBOOT_BOOT_SCRIPT_SOURCE}" ${UBOOT_BOOT_SCRIPT}
}

# The boot script is flavour-dependent, so DOM0_OS must be part of the task hash;
# otherwise building zephyr then linux against one sstate cache reuses the wrong
# boot.scr.
do_compile[vardeps] += "DOM0_OS BOARD_RAM"
