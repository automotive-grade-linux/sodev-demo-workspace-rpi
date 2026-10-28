SUMMARY = "DomD-side HCI bridge that hands the board's Bluetooth controller to DomA"
DESCRIPTION = "\
    DomD owns the only Bluetooth radio on the board. Which UART it hangs off is \
    board-specific -- on RPi4 the pl011 (/soc/serial@7e201000) at 3 Mbaud, on RPi5 a \
    dedicated brcm,bcm7271-uart (/soc@107c000000/serial@7d50c000) also at 3 Mbaud -- but \
    everything above the UART is identical: DomD's partial DT claims it with a \
    brcm,bcm43438-bt child and hci_uart/hci_bcm bring it up as hci0 after downloading \
    brcm/BCM4345C0.hcd (the same patchram on both boards). This unit then republishes \
    that controller to DomA. \
\
    THERE IS NO CODE HERE ON PURPOSE. BlueZ's btproxy already does exactly the right \
    thing: it opens hci0 as an HCI *user channel* and speaks raw H4 (1-byte packet type \
    + header + payload) on a Unix socket, in both directions and for every packet class \
    -- command, ACL, SCO and ISO (tools/btproxy.c host_read_callback). A2DP therefore \
    rides the ACL path and HFP the SCO path with no help from us. \
\
    The DomA end needs nothing written either. Its HCI HAL is \
    android.hardware.bluetooth-service.cuttlefish, a Rust binary that reads and writes \
    raw H4 straight onto a serial device (device/google/cuttlefish/guest/hals/bluetooth/ \
    src/hci.rs) -- no /dev/vhci, no bt_vhci_forwarder, no guest BT kernel modules. Its \
    --serial default and the vendor.ser.bt-uart property are both already /dev/hvc5, \
    which is what doma.cfg's sixth virtio-serial port becomes in the guest. \
\
    Transport: doma.cfg points its virts6 chardev at /run/bt-hci.sock as a CLIENT \
    (server=off,reconnect=1), because btproxy's --unix is itself the server. reconnect=1 \
    makes start order irrelevant, and btproxy survives a DomA restart -- server_callback() \
    only quits on an error of the listening fd, and each accept() re-opens the user \
    channel. \
\
    Why the HCI user channel is the right interface, and why bluetoothd must NOT be \
    installed: the user channel takes the controller exclusively, and hci_sock_bind() \
    (net/bluetooth/hci_sock.c) refuses the HCI_CHANNEL_USER bind with -EBUSY if the \
    device is already up, which is what bluetoothd would do. The profile \
    implementations (A2DP, AVRCP, HFP) all live in DomA's Bluetooth apex, so DomD \
    has no use for a local daemon. bluez5-noinst-tools happens to need no libbluetooth, \
    so installing btproxy does not drag bluez5 or pi-bluetooth in. \
\
    hdev->setup still runs on this path (net/bluetooth/hci_sync.c:5052 precedes every \
    HCI_USER_CHANNEL test), so hci_bcm's patchram download and the switch to the DT's \
    max-speed both happen before DomA sees the controller."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://domd-bt-proxy.service"

S = "${UNPACKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "domd-bt-proxy.service"
SYSTEMD_AUTO_ENABLE = "enable"

# btproxy lives in bluez5-noinst-tools (/usr/bin/btproxy) and needs no libbluetooth.
# hci-uart pulls bluetooth + btbcm; the .hcd is the patchram hci_bcm downloads.
RDEPENDS:${PN} = " \
    bluez5-noinst-tools \
    kernel-module-hci-uart \
    bluez-firmware-rpidistro-bcm4345c0-hcd \
"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/domd-bt-proxy.service ${D}${systemd_system_unitdir}/domd-bt-proxy.service
}

FILES:${PN} = "${systemd_system_unitdir}/domd-bt-proxy.service"

# Both boards. Nothing in this recipe is board-specific: btproxy addresses hci0 by
# index and the unit is started by hci0's device unit
# (sys-subsystem-bluetooth-devices-hci0.device), so which UART produced the
# controller never reaches here. The board-specific parts are the UART assignment
# (config.txt + boot.cmd) and the partial-DT node, and those stay in the per-board
# layers. Same shape as xt-doma-wifi-agent.
#
# It lives in meta-xt-driver-domain rather than a per-board layer for a concrete
# reason: meta-xt-rpi4 and meta-xt-rpi5 are mutually exclusive in bblayers, so a
# recipe in one of them is invisible to the other board. It is also outside
# meta-xt-doma on purpose -- XT_DOMA_BBMASK masks that layer wholesale when
# ENABLE_ANDROID=no, and the consumers here are machine-scoped image bbappends, so a
# masked recipe would leave those IMAGE_INSTALL entries dangling.
COMPATIBLE_MACHINE = "^(raspberrypi4-64|raspberrypi5)$"
