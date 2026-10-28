# Single source of truth for the DomD network topology (IPs / MACs / DHCP range).
require recipes-connectivity/sodev-net.inc

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://depend.conf \
"

FILES:${PN} += " \
    ${sysconfdir}/systemd/system/dnsmasq.service.d/depend.conf \
"

do_install:append() {
    # Make dnsmasq listen only on bridge interface
    echo "interface=xenbr0" >> ${D}${sysconfdir}/dnsmasq.conf

    # Define DHCP leases range on the RPi5 flat L2 bridge subnet
    # (xenbr0 = 192.168.10.10/24; the V4H 192.168.0.x subnet is the
    # Dom0<->DomD p2p link here). Upper part of the subnet can be used
    # for static configuration.
    echo "dhcp-range=${XT_DHCP_RANGE_START},${XT_DHCP_RANGE_END},12h" >> ${D}${sysconfdir}/dnsmasq.conf
    echo "dhcp-authoritative" >> ${D}${sysconfdir}/dnsmasq.conf
    # Answer only the guests. eth0 is a port of xenbr0, so the wired network behind it
    # reaches this server too, and an authoritative one hands its devices addresses and
    # NAKs the leases they hold from that network's own server. The guests are the
    # dhcp-host lines below (tag known) and DomA's Wi-Fi station, whose MAC is
    # randomized but whose DHCP client sends the vendor class android-dhcp-<release>.
    # An Android device on that wired network sends it too and is still answered:
    # telling it apart needs the bridge port the request came in on, and DomD's
    # kernel has no bridge netfilter (no br_netfilter, ebtables or nft bridge).
    echo "dhcp-vendorclass=set:android,android-dhcp-" >> ${D}${sysconfdir}/dnsmasq.conf
    echo "dhcp-ignore=tag:!android,tag:!known" >> ${D}${sysconfdir}/dnsmasq.conf

    # Static IPs for the demo guests (MACs are fixed in /etc/xen/domX.cfg,
    # shipped by xt-xen-cfg-*). Unconditional: the consolidated build dir
    # does not set XT_GUEST_INSTALL, which silently dropped these on V4H
    # and left DomA without a lease (found on hardware).
    # doma eth1 (vif-emu1) = the AAOS management NIC -> .10.13 (adb)
    echo "dhcp-host=${XT_DOMA_MAC},doma,${XT_DOMA_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf
    echo "dhcp-host=${XT_DOMA_ETH0_MAC},doma-eth0,${XT_DOMA_ETH0_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf
    # doma wlan0 (hwsim station on the in-guest shadow AP) -> .10.15, for the
    # MACs this line lists: the persistent randomized MAC the framework actually
    # uses (only when XT_DOMA_WLAN0_MAC is set; it ships empty) and the hwsim
    # perm_addr it falls back to if randomization is ever turned off. The shadow
    # AP makes eth1 a br-shadow port at boot, so the .13 line above is never
    # answered. See sodev-net.inc for how each MAC is derived and for the SSID
    # dependency of the first one.
    # The randomized MAC is optional (sodev-net.inc explains why it ships empty), and
    # dnsmasq REFUSES TO START on a dhcp-host line whose MAC it cannot parse, so build
    # the address list instead of interpolating a possibly-empty variable into it.
    wlan0_macs="${XT_DOMA_WLAN0_PERM_MAC}"
    if [ -n "${XT_DOMA_WLAN0_MAC}" ]; then
        wlan0_macs="${XT_DOMA_WLAN0_MAC},${XT_DOMA_WLAN0_PERM_MAC}"
    fi
    echo "dhcp-host=$wlan0_macs,doma-wlan0,${XT_DOMA_WLAN0_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf
    # domu: the AGL image takes its address over DHCP (connman) and gets .12 from
    # this line; the devel images' domu-network sets the same .12 statically.
    echo "dhcp-host=${XT_DOMU_MAC},domu,${XT_DOMU_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf

    # Use resolve.conf provided by systemd-resolved
    echo "resolv-file=/run/systemd/resolve/resolv.conf" >> ${D}${sysconfdir}/dnsmasq.conf

    # Add actual dependencies
    install -d ${D}${sysconfdir}/systemd/system/dnsmasq.service.d
    install -m 0644 ${UNPACKDIR}/depend.conf ${D}${sysconfdir}/systemd/system/dnsmasq.service.d/
}
