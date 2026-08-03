SUMMARY = "Internal virtual network"

# Single source of truth for the DomD network topology (IPs / MACs / subnets).
require recipes-connectivity/sodev-net.inc

PV = "0.1"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COREBASE}/meta/COPYING.MIT;md5=3da9cfbcb788c80a0384361b4de20420"

# The RPi5 DomD network is the SSH-reachability design
# proven on hardware, moved OUT of the DomD image postprocess
# (install_domd_network/flatbridge) INTO this recipe (single source):
#   - 00-rp1-eth0.link       : pin the RP1 cdns,macb NIC to "eth0" (DomD only) so
#                              the static 10-eth0.network below always applies.
#   - 10-eth0.network       : RP1 eth0 static .10.11 (boot-time; NOT bridged).
#   - 20-domd-vif.network    : Dom0-link xen-netfront static .0.11 (NOT bridged).
#   - 50-xenbr0.network      : xenbr0 up, addressless (flatbridge assigns .10.10
#                              late; .0.1 here would shadow Dom0's vif .0.1).
#   - bridge.conf            : modules-load bridge.ko (CONFIG_BRIDGE=m).
#   - systemd-networkd-wait-online.conf : --any --timeout=15 (no end0 block).
#   - domd-sshd-fix.service  : /run/sshd + ssh-keygen -A + restart sshd.socket
#                              (host keys generated on first boot; none committed).
#   - domd-flatbridge-up/.service : LATE (post-graphical.target) flat L2 bridge:
#                              xenbr0=.10.10, enslave eth0 + DomU/DomA qemu taps,
#                              serve DomA eth1 DHCP lease .10.13 (dnsmasq). Kept
#                              off the xenstore-critical window (doing it at boot
#                              wedged xenbus).
SRC_URI = " \
    file://bridge-up-notification.service \
    file://00-rp1-eth0.link \
    file://xenbr0.netdev \
    file://10-eth0.network \
    file://20-domd-vif.network \
    file://50-xenbr0.network \
    file://bridge.conf \
    file://xenbr0-systemd-networkd.conf \
    file://systemd-networkd-wait-online.conf \
    file://domd-sshd-fix.service \
    file://domd-flatbridge-up \
    file://domd-flatbridge.service \
"

S = "${UNPACKDIR}"

inherit systemd

# Split into a base package (xenbr0 + generic networkd config, shared by Dom0
# and DomD) and a DomD-only ${PN}-flatbridge package (the late flat-L2-bridge +
# sshd-fix + DomA DHCP/entropy deps). The thin Dom0 installs only the base pkg,
# so the DomD-specific flat-bridge units and their dnsmasq/haveged RDEPENDS no
# longer leak into Dom0 (they are inactive there anyway: Dom0 has no eth0 and
# its default.target is multi-user, not graphical). DomD images install
# ${PN}-flatbridge (which pulls in the base via RDEPENDS).
PACKAGES =+ "${PN}-flatbridge"
SYSTEMD_PACKAGES = "${PN} ${PN}-flatbridge"

SYSTEMD_SERVICE:${PN} = "bridge-up-notification.service"
SYSTEMD_SERVICE:${PN}-flatbridge = "domd-sshd-fix.service domd-flatbridge.service"

# DomD-only artifacts (flat-bridge + the DomD static eth0/netfront addresses).
# The RP1 name-pin .link is DomD-only too (Dom0 has no RP1 NIC; it is passed
# through to DomD), so it lives in this package, not the shared base.
FILES:${PN}-flatbridge = " \
    ${sysconfdir}/systemd/network/00-rp1-eth0.link \
    ${sysconfdir}/systemd/network/10-eth0.network \
    ${sysconfdir}/systemd/network/20-domd-vif.network \
    ${sysconfdir}/modules-load.d/bridge.conf \
    ${systemd_system_unitdir}/domd-sshd-fix.service \
    ${systemd_system_unitdir}/domd-flatbridge.service \
    ${bindir}/domd-flatbridge-up \
"

FILES:${PN} = " \
    ${sysconfdir}/systemd/network/xenbr0.netdev \
    ${sysconfdir}/systemd/network/50-xenbr0.network \
    ${sysconfdir}/systemd/system/systemd-networkd.service.d/xenbr0-systemd-networkd.conf \
    ${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d/systemd-networkd-wait-online.conf \
    ${systemd_system_unitdir}/bridge-up-notification.service \
"

RDEPENDS:${PN} = " \
    ethtool \
    kernel-module-bridge \
    openssh-sshd \
    openssh-sftp-server \
    xen-tools-xenstore \
"

# DomD-only runtime deps: dnsmasq (DomA eth1 DHCP lease on the flat bridge) and
# haveged (entropy for the first-boot ssh-keygen in domd-sshd-fix).
RDEPENDS:${PN}-flatbridge = " \
    ${PN} \
    dnsmasq \
    haveged \
"

# Guest reachability on the flat L2 bridge is handled by the dnsmasq bbappend
# (static leases on xenbr0). The former XT_GUEST_INSTALL-gated NAT DNAT port-
# forward config was inert here (XT_GUEST_INSTALL unset, forward targets stale)
# and has been removed.

do_install() {
    # Install bridge/network artifacts
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/bridge-up-notification.service ${D}${systemd_system_unitdir}

    install -d ${D}${sysconfdir}/systemd/network/
    install -m 0644 ${S}/*.network ${D}${sysconfdir}/systemd/network
    install -m 0644 ${S}/*.netdev ${D}${sysconfdir}/systemd/network
    # .link renames the RP1 cdns,macb NIC to eth0 (DomD-only pkg).
    install -m 0644 ${S}/*.link ${D}${sysconfdir}/systemd/network

    install -d ${D}${sysconfdir}/systemd/system/systemd-networkd.service.d
    install -m 0644 ${S}/xenbr0-systemd-networkd.conf ${D}${sysconfdir}/systemd/system/systemd-networkd.service.d

    install -d ${D}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d
    install -m 0644 ${S}/systemd-networkd-wait-online.conf ${D}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d

    # bridge.ko autoload (CONFIG_BRIDGE=m) so networkd can
    # create xenbr0.
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${S}/bridge.conf ${D}${sysconfdir}/modules-load.d/bridge.conf

    # sshd fix + late flat-bridge services (formerly the DomD
    # image install_domd_network/flatbridge postprocess).
    install -m 0644 ${S}/domd-sshd-fix.service ${D}${systemd_system_unitdir}/domd-sshd-fix.service
    install -m 0644 ${S}/domd-flatbridge.service ${D}${systemd_system_unitdir}/domd-flatbridge.service
    install -d ${D}${bindir}
    install -m 0755 ${S}/domd-flatbridge-up ${D}${bindir}/domd-flatbridge-up
}

# [C2 single source] Enforce the DomD static addresses from sodev-net.inc so the
# topology lives in exactly one place. Only DomD eth0 (flat L2) and the
# Dom0<->DomD vif (xen-netfront) carry a static Address here. xenbr0 stays
# ADDRESSLESS on purpose (50-xenbr0.network) — .10.10 is assigned LATE by
# domd-flatbridge-up, never via a .network Address= — so 50-xenbr0.network is not
# rewritten; the address itself is substituted into domd-flatbridge-up instead,
# together with the uplink gateway it sets the default route to.
# The former end0.network (DHCP uplink) was dropped: RP1 is now
# pinned to eth0 (00-rp1-eth0.link) so no "end0" ever appears on DomD, and the
# thin Dom0 image already rm'd it (rpi5-image-xt-dom0-thin.bb flatten_dom0_network).
do_install:append() {
    sed -i \
        -e 's|^Address=.*|Address=${XT_DOMD_ETH0_IP}/24|' \
        -e 's|^Gateway=.*|Gateway=${XT_DOMD_XENBR0_IP}|' \
        ${D}${sysconfdir}/systemd/network/10-eth0.network
    sed -i 's|^Address=.*|Address=${XT_DOMD_VIF_IP}/24|' \
        ${D}${sysconfdir}/systemd/network/20-domd-vif.network
    sed -i \
        -e 's|^XENBR0_ADDR=.*|XENBR0_ADDR=${XT_DOMD_XENBR0_IP}/24|' \
        -e 's|^UPLINK_GW=.*|UPLINK_GW=${XT_PC_UPLINK_GW_IP}|' \
        ${D}${bindir}/domd-flatbridge-up
    grep -q '^XENBR0_ADDR=${XT_DOMD_XENBR0_IP}/24$' ${D}${bindir}/domd-flatbridge-up || \
        bbfatal "domd-flatbridge-up: XENBR0_ADDR substitution did not take"
    grep -q '^UPLINK_GW=${XT_PC_UPLINK_GW_IP}$' ${D}${bindir}/domd-flatbridge-up || \
        bbfatal "domd-flatbridge-up: UPLINK_GW substitution did not take"
}
