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
# enable_gic=1 is already in config.txt: meta-virtualization's
# dynamic-layers/raspberrypi/conf/distro/include/xen-raspberrypi4-64.inc appends it
# to RPI_EXTRA_CONFIG for every xen build of this MACHINE, so it is not repeated
# here. It matters all the same (the RPi4B default is 1): with 0 the interrupts
# are routed through the legacy per-core controller instead of the GIC-400, and
# TF-A's unconditional gicv2_driver_init() no longer matches the hardware.
RPI_EXTRA_CONFIG:append = "\n# --- EL3: TF-A BL31 (PSCI + GICv2) as the armstub ---\narm_64bit=1\narmstub=bl31.bin\ndevice_tree=bcm2711-rpi-4-b.dtb\n"

# -----------------------------------------------------------------------------
# UART assignment: pl011 -> Bluetooth, mini UART -> the Xen console.
# -----------------------------------------------------------------------------
# BCM2711 has six UARTs, but only uart0 (pl011) and uart1 (mini UART) can be
# muxed to the two pin groups that matter here: GPIO14/15 (the 40-pin header) and
# GPIO30-33 (the on-board CYW43455 Bluetooth). uart2..uart5 are confined to
# GPIO0-15 and cannot reach the BT pins at all
# (arch/arm/boot/dts/broadcom/bcm283x.dtsi, and overlays/uart[2-5]-overlay.dts).
#
# The two pin groups are disjoint and uart0/uart1 are separate devices, so BOTH
# consumers can be served at once — which is what the stock, no-overlay
# configuration does. What is forced is only the PAIRING: whichever UART drives
# the BT module, the console gets the other one.
#
#   overlays          GPIO14/15 (header)          GPIO30-33 (BT module)
#   ----------------  --------------------------  ---------------------------
#   none (stock)      mini UART  (ttyS0)          pl011 @ 3 Mbaud
#   disable-bt        pl011                       nothing — BT is dead
#   miniuart-bt       pl011                       mini UART @ 230400
#
# The numbers decide the pairing. A UART at 8N1 carries baud/10 bytes per second,
# so the mini UART's 230400 gives 184 kbps of HCI payload while A2DP SBC needs
# 229 kbps (standard) to 328 kbps (high quality). miniuart-bt is therefore out —
# its own overlays/README says it "should only be used with low-bandwidth
# peripherals" — and disable-bt sacrifices Bluetooth entirely. pl011's 3 Mbaud
# (2400 kbps) is the only pairing that carries A2DP, so BT gets pl011 and the
# console gets the mini UART.
#
# No overlay at all is exactly that pairing: stock already puts pl011 on the BT
# module and lets the firmware mux GPIO14/15 to the mini UART as the primary
# UART. boot.cmd points Xen at the mini UART (dtuart=/soc/serial@7e215040), which
# is also the path meta-virtualization's stock RPi4 boot script takes. Measured on
# the board: hci0 binds under fe201000.serial, DomD's device tree reports
# max-speed = 3000000, and the controller answers with chip id 107,
# BCM4345C0 build 0382.
#
# enable_uart=1 is written by meta-raspberrypi's rpi-config_git.bb from
# ENABLE_UART = "1", which rpi4-sodev.yaml's DomD conf and meta-virtualization's
# xen-raspberrypi4-64.inc both set, so it is not repeated here. The mini UART
# is the primary UART, so that line is what gives the
# firmware stage a console on the header at 115200. Xen's ns16550 driver supports
# brcm,bcm2835-aux-uart directly (the compatible is in ns16550.c's DT match
# table, and ns16550_uart_dt_init() sets reg_width=4/reg_shift=2 from it) and
# uses BAUD_AUTO on the DT path, i.e. it reads the divisor the firmware
# programmed rather than reprogramming it.
#
# force_turbo=1 is NOT optional, and the coupling is documented upstream. The mini
# UART's parent clock is aux@7e215000 -> cprman index 20 = BCM2835_CLOCK_VPU, so
# its baud rate moves with the core frequency. Raspberry Pi's own documentation
# (configuration/interfaces.adoc, "Mini UART and core frequency") gives:
#
#   Mini UART set to | Core clock              | Result
#   -----------------+-------------------------+--------------------------------
#   Primary          | Variable                | Mini UART DISABLED
#   Primary          | Fixed (enable_uart=1)   | enabled; core fixed at 250 MHz
#                    |                         | (or turbo frequency if forced)
#   Secondary        | Variable                | Mini UART DISABLED
#   Secondary        | Fixed (core_freq=250)   | enabled
#
# So enable_uart=1 is itself what fixes the VPU clock, and it fixes it at 250 MHz
# — half the Pi 4's default core_freq of 500. That is not acceptable here: the
# core clock drives HVS (display composition), the VideoCore H.264 codec, and the
# L2 cache and memory bus, and this design hands the whole display complex to
# DomD. (V3D is separately clocked — v3d_freq/v3d_freq_min below — so it is not
# affected directly.) The documented escape is the parenthesis in the table,
# "or turbo frequency if forced".
#
# force_turbo=1 on its own does NOT set the warranty bit: upstream is explicit
# that "the overclock bit sets when force_turbo is set to 1 AND any of the
# over_voltage_* options are set to a value of more than 0", and nothing here sets
# over_voltage_*. It is also not overclocking — turbo is the stock maximum. Cost:
# all clocks stay at maximum even when idle, so idle power and temperature go up.
# Residual risk worth knowing: overclock/overvoltage are disabled at runtime when
# the SoC reaches temp_limit (85 C default), so under sustained thermal load the
# core can drop and the console baud with it — watch for garbled console output
# correlating with load.
#
#   https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/computers/configuration/interfaces.adoc
#   https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/computers/config_txt/overclocking.adoc
#
# The pin mux for GPIO30-33 is done TWICE, and the duplication is deliberate.
# boot.cmd read-modify-writes GPFSEL3 and both PUP_PDN_CNTRL registers for all four
# lines before Xen starts, which is a strict superset of what the two `gpio=` lines
# below can do -- a config.txt `gpio=` reaches only GPIO32/33, and DomD's DT asserts
# uart-has-rtscts, so CTS0/RTS0 on GPIO30/31 have to be muxed as well.
#
# The `gpio=` lines are kept anyway because the configuration that was measured
# working on the board has both, and dropping one half of it has NOT been measured.
# Rewriting the SD card is the expensive step here, so the reduction is not worth
# spending a boot on; remove them only together with a board test that shows the
# read-modify-write alone brings the controller up (`chip id 107, BCM4345C0`).
#
# overlays/disable-bt.dtbo is still deployed as a p1 boot item (rpi4-sodev.yaml)
# and the kernel bbappend still forces KERNEL_DEVICETREE to build the overlay set.
# Nothing references the file, and keeping it means reverting this UART assignment
# costs one config.txt line plus boot.scr with no change to the FAT layout —
# rewriting the SD card is the expensive step on this board.
RPI_EXTRA_CONFIG:append = "\n# --- Xen console: mini UART on GPIO14/15; pl011 belongs to Bluetooth ---\nforce_turbo=1\ngpio=30,33=a3,pu\ngpio=31,32=a3,pn\n"

# -----------------------------------------------------------------------------
# Pin the A72 clock in firmware, for the same reason the Pi 5 layer pins the A76.
# -----------------------------------------------------------------------------
# Xen/Arm disables cpufreq in EVERY guest, unconditionally, inside
# xen_guest_init():
#
#   arch/arm/xen/enlighten.c:511-514  (arm64 shares this file via
#                                      arch/arm64/xen/Makefile)
#     /* Making sure board specific code will not set up ops for
#      * cpu idle and cpu freq. */
#     disable_cpuidle();
#     disable_cpufreq();
#
# cpufreq_register_driver() then returns -ENODEV at its first check
# (cpufreq_disabled()). DomD is not exempt -- the check asks "am I a Xen guest",
# not "am I privileged" -- so no in-guest governor can ever raise the clock, and
# the firmware's setting is the only layer that decides it. Measured on this
# board: `cpufreq-dt cpufreq-dt: failed register driver: -19` at boot and no
# /sys/devices/system/cpu/cpu0/cpufreq directory at all.
#
# THE CLOCK IS ALREADY AT MAXIMUM TODAY, and these two lines do not change it.
# Measured on the board with the configuration above:
#   /sys/kernel/debug/clk/fw-clk-arm/clk_rate     1500000000
#   /sys/kernel/debug/clk/fw-clk-arm/clk_min_rate 1500000000
#   /sys/kernel/debug/clk/fw-clk-arm/clk_max_rate 1500000000
# i.e. pinned at this board's own maximum, at 34.5 C.
#
# What these lines buy is that the CPU clock stops being a SIDE EFFECT of a
# setting chosen for the console. force_turbo=1 above is there for the mini
# UART's parent clock; it also keeps the ARM clock at turbo regardless of load,
# which is why the numbers above look right. But reverting the UART assignment is
# a deliberately cheap operation here (drop force_turbo=1 and bring back
# `dtoverlay=disable-bt`, whose .dtbo is still on the boot FAT), and doing that
# would silently drop the CPU to arm_freq_min -- 600 MHz on a Pi 4B, 40% of
# 1500 -- with no governor left to raise it again. Naming arm_freq explicitly
# makes the two independent.
#
# 1500/1500 is the stock maximum, not an overclock: upstream's default arm_freq
# for a Pi 4B R1.4+ is 1500 MHz. arm_boost=1 would raise it to 1800 MHz on that
# revision and is deliberately NOT set -- it is a different operating point, with
# its own thermal behaviour, and nothing here has been measured at it.
#
# CAUTION, the same one the Pi 5 layer records: with cpufreq disabled the kernel
# cannot throttle the CPU at all, so the firmware's temp_limit (default 85 C) is
# the effective thermal guard. Sustained full-load runs should record
# temperature.
RPI_EXTRA_CONFIG:append = "\n# A72 clock pinned in firmware: Xen/Arm disables cpufreq in every guest\n# (arch/arm/xen/enlighten.c disable_cpufreq()), so no governor can raise it from\n# arm_freq_min. 1500 is the stock maximum for a Pi 4B R1.4+, not an overclock.\narm_freq=1500\narm_freq_min=1500\n"

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
# On rpi5 it was harmless by luck: p1's overlays/ holds only bcm2712d0.dtbo, so
# the firmware could not find vc4-kms-v3d.dtbo and skipped the line (that layer
# now cancels it the same way). Luck is not intent,
# and it stops being true here: RPI_KERNEL_DEVICETREE_OVERLAYS is built and
# deployed and overlays/disable-bt.dtbo is on the boot FAT as the rollback path
# for the UART assignment above, so anyone widening the p1 overlay list would
# silently enable it.
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
# /reserved-memory/linux,cma and DomD takes its CMA from `cma=` on its own command
# line (the value and its reason are at the DomD bootargs in boot.cmd).
RPI_EXTRA_CONFIG:append = "\n# --- DomD owns HDMI: keep the firmware out of the display path ---\ndisable_fw_kms_setup=1\ndisable_splash=1\n"

# -----------------------------------------------------------------------------
# Pin gpu_mem so the physical memory map in boot.cmd stays true.
# -----------------------------------------------------------------------------
# The VideoCore carve-out is taken off the top of the first GiB, so it decides
# where the low DRAM bank ends. boot.cmd's map — DomD static-mem bank1 at
# 0x08000000 + 384 MiB (0x06000000 + 416 MiB on the 4 GiB SKU; both end at
# 0x20000000) and the Dom0 bank[0] hole at 0x20000000-0x30000000 —
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
# does not carry over either (see the note in 72-rp1-touch-output.rules).
RPI_EXTRA_CONFIG:append = "\n# --- V3D 4.2 firmware DVFS bounds ---\nv3d_freq=500\nv3d_freq_min=250\n"
