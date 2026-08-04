require optee-machine.inc

# Start supplicant for /dev/tee0
FILES:${PN} += "${systemd_system_unitdir}/tee-supplicant@.service"
SYSTEMD_SERVICE:${PN} = "tee-supplicant@tee0.service"
