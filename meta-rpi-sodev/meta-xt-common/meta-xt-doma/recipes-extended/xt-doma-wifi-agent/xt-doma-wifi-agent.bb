SUMMARY = "DomD-side agent for DomA's shadow-AP Wi-Fi"
DESCRIPTION = "\
    DomD owns the only real radio on the board. DomA does not get it -- its \
    devices are qemu device models, and its wlan0 has to be one that \
    WifiService manages -- so DomA simulates its radios with mac80211_hwsim \
    and beacons the SSIDs this agent reports, while this agent performs the \
    real association. \
\
    Transport: a qemu virtio-serial chardev, /run/android_vm_virtconsole5 (DomA sees \
    /dev/hvc4, because a virtconsole takes an hvc node). doma.cfg creates \
    five virtconsoles and one virtserialport, and this agent takes virts5. \
    Chosen over vsock and TCP because it needs no IP and no routing rules -- \
    DomA's policy routing sends unmarked traffic out a different interface. \
    This side is the client; qemu listens. \
\
    wpa_supplicant is driven directly over its control socket (AF_UNIX/SOCK_DGRAM at \
    /run/wpa_supplicant/wlan0). wpa_cli is not in the image and python3 is, so nothing \
    extra is needed. \
\
    NOTE: a passphrase typed on the AAOS screen crosses this channel in the clear. A \
    shadow AP cannot learn a PSK from a 4-way handshake -- only a MIC crosses the air -- \
    so on-screen entry and a real association cannot both hold without forwarding it. \
    Lab use only. \
\
    The guest half is the AAOS device: init.xenvm-hwsim.rc plus \
    /vendor/bin/doma-shadow-ap and /vendor/bin/doma-wifi-relay. For the Pi 5 that is \
    meta-xt-doma/aosp-device/agl/xenvm-trout-rpi5, staged by stage-aosp-device.sh; \
    the Pi 4 takes its device from the manifest instead (device/sodev/xenvm-cf)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://domd_wifi_agent.py \
    file://domd-wifi-agent.service \
    file://wpa_supplicant-wlan0.conf \
    file://domd-wpa-supplicant.service \
"

S = "${UNPACKDIR}"

inherit systemd

# Two units, both auto-enabled: the supplicant that owns the radio and the agent
# that drives it. The agent already waits for /run/wpa_supplicant/wlan0 in its
# ExecStartPre, so no ordering between them is declared here -- the wait is the
# synchronisation, and it survives a restart of either unit in any order.
SYSTEMD_SERVICE:${PN} = "domd-wpa-supplicant.service domd-wifi-agent.service"
SYSTEMD_AUTO_ENABLE = "enable"

# python3 for the agent, with python3-io for its socket module; wpa-supplicant
# is what it drives; iw is what it reads the driver's station table with (see
# DRIVER RESET in the agent); the DHCP client it calls after a successful
# association is busybox's udhcpc, which the image already has.
RDEPENDS:${PN} = "python3-core python3-io python3-json wpa-supplicant iw"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/domd_wifi_agent.py ${D}${bindir}/domd_wifi_agent.py
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/domd-wifi-agent.service ${D}${systemd_system_unitdir}/domd-wifi-agent.service
    install -m 0644 ${UNPACKDIR}/domd-wpa-supplicant.service ${D}${systemd_system_unitdir}/domd-wpa-supplicant.service
    # 0600: this file carries no secret today, but the agent writes PSKs into
    # wpa_supplicant at runtime and update_config=1 lets a SAVE_CONFIG land them
    # here, so it must not be world-readable.
    install -d ${D}${sysconfdir}
    install -m 0600 ${UNPACKDIR}/wpa_supplicant-wlan0.conf ${D}${sysconfdir}/wpa_supplicant-wlan0.conf
}

FILES:${PN} = " \
    ${bindir}/domd_wifi_agent.py \
    ${systemd_system_unitdir}/domd-wifi-agent.service \
    ${systemd_system_unitdir}/domd-wpa-supplicant.service \
    ${sysconfdir}/wpa_supplicant-wlan0.conf \
"

# The supplicant config is editable state on the target (update_config=1), so mark
# it a conffile: a package upgrade must not silently replace an operator-edited one.
CONFFILES:${PN} = "${sysconfdir}/wpa_supplicant-wlan0.conf"

# Both boards give DomD the onboard Wi-Fi and use the same doma.cfg chardev, so
# allow both rather than gating and re-widening in a bbappend the way
# xt-aaos-host-services had to.
COMPATIBLE_MACHINE = "^(raspberrypi4-64|raspberrypi5)$"
