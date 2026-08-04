# RPi5 bootfiles config.txt settings for the Xen Dom0/DomD split.
#
# What this adds and why:
#   kernel=u-boot + UART at the bootloader stage  -- U-Boot loads Xen.
#   CMA via the vc4-kms-v3d overlay parameter     -- a cmdline `cma=` kills the
#     RPi5 firmware mailbox (raspberrypi/linux#7230), so CMA has to be attached
#     to the dtoverlay line instead.
#   disable_fw_kms_setup=1                        -- DomD's vc4-drm owns HDMI.
#   usb_max_current_enable=1                      -- the RP1 USB touch panel
#     over-currents without it (needs a 5 A PSU).
#   V3D firmware DVFS bounds                      -- busy ceiling / idle floor.

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

    # Rewrite the vc4-kms-v3d overlay line to carry
    # cma-256 (runs after the dtoverlay=vc4-kms-v3d line already exists).
    sed -i 's|^dtoverlay=vc4-kms-v3d$|dtoverlay=vc4-kms-v3d,cma-256|' $CONFIG
}

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
RPI_EXTRA_CONFIG:append = "\n# V3D firmware DVFS bounds: busy max 960MHz / idle floor 500MHz (native .maximize via firmware_clocks)\nv3d_freq=960\nv3d_freq_min=500\n"
