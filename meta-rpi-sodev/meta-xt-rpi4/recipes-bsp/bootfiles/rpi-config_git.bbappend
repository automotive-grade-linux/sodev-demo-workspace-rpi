# =============================================================================
# config.txt for the RPi4 / BCM2711 Xen cockpit
# =============================================================================
# Consolidated bootfiles bbappend (the RPi5 layer merged three overlays into
# one file; that structure is kept). Everything here is BCM2711-specific, and
# each RPi5 line that was dropped is called out inline so the delta stays
# reviewable.
#
# Boot order this produces:
#   bootcode / start4.elf reads config.txt
#     -> loads `armstub` (TF-A bl31.bin) to DRAM 0 and enters it at EL3, having
#        filled dtb_ptr32 / kernel_entry32 in the armstub header
#     -> TF-A BL31 sets up PSCI + GICv2 and drops to EL2 at the "kernel"
#        address, which is U-Boot
#     -> U-Boot runs boot.scr (boot.cmd.xen.*-dom0.in) and boots Xen
# =============================================================================

do_deploy:append() {
    install -d ${DEPLOYDIR}/${BOOTFILES_DIR_NAME}
    CONFIG=${DEPLOYDIR}/${BOOTFILES_DIR_NAME}/config.txt

    if [ "${RPI_USE_U_BOOT}" = "1" ]; then
        sed -i '/#kernel=/ c\kernel=u-boot' $CONFIG
    fi
    # UART support on bootloader stage
    if [ "${UART_BOOTLOADER}" = "1" ] || [ "${ENABLE_BOOTLOADER}" = "0" ]; then
        echo "# Enable UART on bootloader" >> $CONFIG
        echo "uart_2ndstage=${UART_BOOTLOADER}" >> $CONFIG
    elif [ -n "${UART_BOOTLOADER}" ]; then
        bbfatal "Invalid value for UART_BOOTLOADER [${UART_BOOTLOADER}]. The value for UART_BOOTLOADER can be 0 or 1."
    fi
}

# -----------------------------------------------------------------------------
# EL3 firmware: TF-A BL31 as the armstub, with the GIC-400 enabled.
# -----------------------------------------------------------------------------
# Xen needs PSCI to bring up the secondary A72 cores, and GICv2 for interrupts.
# `armstub=` names a file on the boot partition; the GPU firmware loads it to
# DRAM 0 and enters it at EL3 (TF-A docs/plat/rpi4.rst).
# recipes-bsp/trusted-firmware-a builds it as bl31.bin and rpi4-sodev.yaml copies
# that file into the boot partition.
#
# Written directly instead of going through meta-raspberrypi's ARMSTUB machinery:
# that only fires when MACHINE_FEATURES contains "armstub", writes `enable_gic=1`
# only when the file name matches *-gic.bin, drags in recipes-bsp/armstubs (which
# builds raspberrypi/tools' own much thinner EL3 stub, not TF-A), and only copies
# the stub to the boot partition from classes/sdcard_image-rpi.bbclass, which
# this workspace does not use.
#
# enable_gic defaults to 1 on the RPi4B, but state it explicitly: with 0 the
# interrupts are routed through the legacy per-core controller instead of the
# GIC-400, and TF-A's unconditional gicv2_driver_init() no longer matches the
# hardware.
RPI_EXTRA_CONFIG:append = "\n# --- EL3: TF-A BL31 (PSCI + GICv2) as the armstub ---\narm_64bit=1\nenable_gic=1\narmstub=bl31.bin\ndevice_tree=bcm2711-rpi-4-b.dtb\n"

# -----------------------------------------------------------------------------
# pl011 on the GPIO header — the Xen console.
# -----------------------------------------------------------------------------
# On a stock RPi4 the pl011 (/soc/serial@7e201000) is wired to the Bluetooth
# module and GPIO14/15 carries the mini UART (/soc/serial@7e215040). boot.cmd
# passes dtuart=/soc/serial@7e201000 to Xen, so the two have to be swapped:
# disable-bt gives pl011 the header pins and turns the BT node off. Without it the
# hypervisor console would be talking to the Bluetooth chip.
#
# The alternative is to leave BT alone and point Xen at the mini UART instead,
# which is what meta-virtualization's stock RPi4 boot script does. That path needs
# enable_uart=1 to pin the core clock, since the mini UART derives its baud rate
# from it — set here regardless, because it also gives the firmware stage a
# console.
#
# `dtoverlay=disable-bt` is resolved by the VideoCore firmware, which looks for
# overlays/disable-bt.dtbo on the boot FAT. The pin mux has to be right before any
# of TF-A / U-Boot / Xen runs, so this cannot be folded into the Xen host overlay
# that U-Boot applies with `fdt apply` — by then the firmware has already muxed
# GPIO14/15. rpi4-sodev.yaml therefore carries overlays/disable-bt.dtbo as a p1
# boot item, and the kernel bbappend forces KERNEL_DEVICETREE to include
# RPI_KERNEL_DEVICETREE_OVERLAYS so the file is actually built and deployed.
# If that file is missing the overlay silently does nothing and the hypervisor
# console talks to the Bluetooth chip instead of the header — i.e. a dead G1.
RPI_EXTRA_CONFIG:append = "\n# --- Xen console: pl011 on GPIO14/15 (requires BT off) ---\nenable_uart=1\ndtoverlay=disable-bt\n"

# -----------------------------------------------------------------------------
# Cancel meta-raspberrypi's own `dtoverlay=vc4-kms-v3d`.
# -----------------------------------------------------------------------------
# recipes-bsp/bootfiles/rpi-config_git.bb:217 writes it whenever MACHINE_FEATURES
# contains vc4graphics, which rpi-base.inc sets for this board — so the line above
# saying "no dtoverlay=vc4-kms-v3d here" was true of THIS file but not of the
# config.txt that actually shipped. Enabling that overlay host-side flips hvs /
# hdmi0 / hdmi1 / ddc0 / ddc1 / dvp / aon_intr / txp / v3d / gpu and all five
# pixelvalves to status="okay" in the HOST device tree, i.e. it hands the display
# complex to the control Dom0 — the exact opposite of this design, where DomD
# declares those nodes itself and takes them by direct-map passthrough.
#
# On rpi5 it happened to be harmless because no overlays/ directory was shipped, so
# the firmware could not find the file and skipped it. That is luck, not intent,
# and it stops being true here: RPI_KERNEL_DEVICETREE_OVERLAYS is now built and
# deployed (needed for disable-bt.dtbo), so anyone widening the p1 overlay list
# would silently enable it.
#
# VC4GRAPHICS is a recipe-local variable used at exactly one place (that `if`), so
# clearing it removes the line and nothing else. MACHINE_FEATURES is deliberately
# left alone — DomD's mesa / vc4-drm packaging and the vc4graphics.cfg kernel
# fragment depend on it.
VC4GRAPHICS = "0"

# -----------------------------------------------------------------------------
# Display: hand HDMI to DomD's vc4-drm, not to the firmware.
# -----------------------------------------------------------------------------
# disable_fw_kms_setup=1 stops the firmware from doing the KMS-style setup that
# would program the HDMI pipeline and hand on a configured mode, and
# disable_splash=1 removes the rainbow test pattern. Between them, nothing has
# driven the display by the time DomD's vc4-drm does its modeset.
#
# PRECISION(rpi4): this is not the same as "no framebuffer node is published".
# Two other things do that job, and both are needed:
#   * the boot scripts `fdt rm` the firmware framebuffer nodes before Xen boots;
#     and, because U-Boot's ft_board_setup() re-adds a `/framebuffer` node during
#     `booti` (AFTER those removals), they also set `skip_board_fixup 1`;
#   * the u-boot cfg drops CONFIG_VIDEO_BCM2835 so U-Boot never asks the
#     VideoCore for a framebuffer in the first place.
# See recipes-bsp/u-boot/files/rpi4-bcm2711.cfg for the full chain.
#
# NOTE: no `dtoverlay=vc4-kms-v3d-pi4` here, unlike a normal RPi4 image. That
# overlay flips hvs / hdmi0 / hdmi1 / ddc0 / ddc1 / dvp / aon_intr / txp / v3d /
# gpu and all five pixelvalves to status="okay" in the HOST device tree. DomD does
# not need that — its partial DT declares each of those nodes itself with
# status="okay" — and enabling them host-side would only hand the ones this design
# deliberately does NOT pass through (pixelvalve0/1/3, vec) to the control Dom0.
# The overlay's CMA sizing is not needed either: boot.cmd deletes
# /reserved-memory/linux,cma and DomD takes its CMA from `cma=192M` on its own
# command line.
RPI_EXTRA_CONFIG:append = "\n# --- DomD owns HDMI: keep the firmware out of the display path ---\ndisable_fw_kms_setup=1\ndisable_splash=1\n"

# -----------------------------------------------------------------------------
# Pin gpu_mem so the physical memory map in boot.cmd stays true.
# -----------------------------------------------------------------------------
# The VideoCore carve-out is taken off the top of the first GiB, so it decides
# where the low DRAM bank ends. boot.cmd's map — DomD static-mem bank1 at
# 0x08000000 + 384 MiB and the Dom0 bank[0] hole at 0x20000000-0x30000000 —
# assumes the default gpu_mem=76, i.e. a low bank ending at 0x3b400000. Say it
# out loud so a firmware default change cannot silently move that boundary.
RPI_EXTRA_CONFIG:append = "\n# --- fix the VideoCore carve-out: low DRAM bank ends at 0x3b400000 ---\ngpu_mem=76\n"

# -----------------------------------------------------------------------------
# V3D clock bounds for the firmware DVFS.
# -----------------------------------------------------------------------------
# BCM2711's V3D 4.2 tops out far below BCM2712's (see README.md "Known limitations"), so the RPi5
# 960/500 MHz pair does not apply: 500 MHz is the RPi4 stock v3d_freq. The floor
# keeps the idle clock from dropping so far that the driver domain's compositor
# stutters on wake-up.
#
# REMOVED versus RPi5: usb_max_current_enable=1 — that knob is about the Pi 5's
# 5 A USB-PD budget. RPi4's USB current limit is fixed in hardware and has no
# equivalent config.txt setting, so the RP1 touch-panel force-enumerate rationale
# does not carry over either (see the note in 72-touch-output.rules).
RPI_EXTRA_CONFIG:append = "\n# --- V3D 4.2 firmware DVFS bounds ---\nv3d_freq=500\nv3d_freq_min=250\n"
