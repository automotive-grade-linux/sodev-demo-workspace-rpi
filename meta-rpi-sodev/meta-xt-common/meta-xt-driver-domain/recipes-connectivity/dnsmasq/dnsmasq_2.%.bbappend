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

    # Static IPs for the demo guests (MACs are fixed in /etc/xen/domX.cfg,
    # shipped by xt-xen-cfg-*). Unconditional: the consolidated build dir
    # does not set XT_GUEST_INSTALL, which silently dropped these on V4H
    # and left DomA without a lease (found on hardware).
    # doma eth1 (vif-emu1) = the AAOS management NIC -> .10.13 (adb)
    echo "dhcp-host=${XT_DOMA_MAC},doma,${XT_DOMA_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf
    echo "dhcp-host=${XT_DOMA_ETH0_MAC},doma-eth0,${XT_DOMA_ETH0_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf
    # domu keeps a static 192.168.10.12 in its rootfs; this mapping is a
    # consistent fallback should it ever DHCP.
    echo "dhcp-host=${XT_DOMU_MAC},domu,${XT_DOMU_IP},infinite" >> ${D}${sysconfdir}/dnsmasq.conf

    # Use resolve.conf provided by systemd-resolved
    echo "resolv-file=/run/systemd/resolve/resolv.conf" >> ${D}${sysconfdir}/dnsmasq.conf

    # Add actual dependencies
    install -d ${D}${sysconfdir}/systemd/system/dnsmasq.service.d
    install -m 0644 ${UNPACKDIR}/depend.conf ${D}${sysconfdir}/systemd/system/dnsmasq.service.d/
}
