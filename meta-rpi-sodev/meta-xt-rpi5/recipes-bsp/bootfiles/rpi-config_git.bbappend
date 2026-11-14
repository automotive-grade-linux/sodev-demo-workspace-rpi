# RPi5 bootfiles config.txt settings for the Xen Dom0/DomD split.
#
# What this adds and why:
#   kernel=u-boot + UART at the bootloader stage  -- U-Boot loads Xen.
#   disable_fw_kms_setup=1                        -- DomD's vc4-drm owns HDMI.
#   usb_max_current_enable=1                      -- the RP1 USB touch panel
#     over-currents without it (needs a 5 A PSU).
#   V3D firmware DVFS bounds                      -- busy ceiling / idle floor.
#   arm_freq pinned in firmware                   -- see the long note below.
#
# No dtoverlay=vc4-kms-v3d. meta-raspberrypi's rpi-config_git.bb writes that line
# whenever MACHINE_FEATURES has vc4graphics (its `if VC4GRAPHICS = 1` emits the
# comment and the dtoverlay line, nothing else); VC4GRAPHICS = "0" below cancels
# it. The overlay has never been on p1 -- rpi5-sodev.yaml ships only
# overlays/bcm2712d0.dtbo -- so the firmware could not find vc4-kms-v3d.dtbo and
# skipped the line, and the `,cma-256` this file used to sed onto it set nothing.
# DomD's CMA comes from its own bootargs in boot.cmd.xen.{zephyr,linux}-dom0.in
# (cma=640M@0x68000000 with the Zephyr Dom0, cma=128M with the Linux one); the
# host DT's /reserved-memory/linux,cma stays at the firmware's 64 MiB.

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

# VC4GRAPHICS is a recipe-local variable used at exactly one place (the `if` that
# writes dtoverlay=vc4-kms-v3d), so clearing it removes that line and nothing else.
# MACHINE_FEATURES is left alone: DomD's mesa / vc4-drm packaging and the
# vc4graphics.cfg kernel fragment depend on it.
VC4GRAPHICS = "0"

# Bake disable_fw_kms_setup=1. DomD's vc4-drm owns the
# HDMI mode set and framebuffer; suppress the firmware-side KMS auto-attach so no
# leftover Dom0 simplefb framebuffer holds HDMI.
RPI_EXTRA_CONFIG:append = "\n# skip firmware-side KMS attach so DomD vc4-drm owns HDMI from boot\ndisable_fw_kms_setup=1\n"

# Enable USB high-current (>600mA) for the RP1 USB touch
# panel (requires a 5A/27W PSU). Without it the wch.cn touch panel over-currents and
# never enumerates stably -> AAOS touch is dead. Verified on hardware.
RPI_EXTRA_CONFIG:append = "\n# allow >600mA USB (needs 5A PSU) so the RP1 touch panel does not over-current\nusb_max_current_enable=1\n"

# V3D GPU clock bounds for the VideoCore firmware DVFS:
# busy ceiling 960MHz / idle floor 500MHz (native .maximize via firmware_clocks).
RPI_EXTRA_CONFIG:append = "\n# V3D firmware DVFS bounds: busy max 960MHz / idle floor 500MHz\n# (native .maximize via firmware_clocks)\nv3d_freq=960\nv3d_freq_min=500\n"

# Pin the A76 clock to the turbo frequency, in the firmware.
#
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
# (cpufreq_disabled()), which surfaces at boot as:
#
#   cpufreq-dt cpufreq-dt: failed register driver: -19
#
# This applies to DomD too: being the hardware domain does not help, because the
# check is on "am I a Xen guest", not on privilege. So no in-guest governor can
# ever exist on this board.
#
# Everything below cpufreq is healthy, which is what makes the symptom easy to
# misread as a driver bug. Measured on the board:
#   * fw-clk-arm advertises clk_max_rate = 2400000000 and is bound to cpu0
#   * raspberrypi-clk probes and registers the raspberrypi-cpufreq device
#     (drivers/clk/bcm/clk-raspberrypi.c)
#   * raspberrypi-cpufreq binds and populates a complete OPP table --
#     /sys/kernel/debug/opp/cpu{0,1}/ held 10 OPPs, 1.5 to 2.4 GHz in 100 MHz
#     steps
#   * only cpufreq-dt fails, and it fails with no driver-specific message
# Nothing can consume that OPP table, so the firmware simply stays at its idle
# floor arm_freq_min. Measured: fw-clk-arm clk_rate = 1500000000, i.e. 62.5% of
# the 2.4 GHz this SoC is specified for, with no thermal or PSU reason
# (thermal_zone0 was 57 C and the pwm-fan sat at level 2 of 4).
#
# Setting the clock in the firmware is therefore not a workaround but the only
# available layer. min == max additionally removes DVFS jitter, which matters
# because this board is used for real-time latency measurement.
#
# Verified after applying: clk_rate/clk_min_rate/clk_max_rate all 2400000000,
# Dhrystone 21,505,376 -> 34,482,760 dps (1.60x, exactly the clock ratio) with
# DMIPS/MHz unchanged at 8.16 -> 8.18, all five domains up, 61.7 C, fan 2/4.
#
# CAUTION, and the reason the numbers above are worth keeping here: with cpufreq
# disabled the kernel cannot throttle the CPU at all. The thermal framework can
# only drive the fan (cooling_device0 = pwm-fan); thermal_zone0's trip points are
# 50/60/67.5/75 C "active" (fan steps) and 110 C "critical" (shutdown). The
# firmware's own temp_limit (default 85 C) is the effective thermal guard, so
# sustained full-load runs should record temperature.
RPI_EXTRA_CONFIG:append = "\n# A76 clock pinned in firmware: Xen/Arm disables cpufreq in every guest\n# (arch/arm/xen/enlighten.c disable_cpufreq()), so no governor can raise it from\n# the 1.5 GHz idle floor. min == max also removes DVFS jitter for RT\n# measurement.\narm_freq=2400\narm_freq_min=2400\n"
