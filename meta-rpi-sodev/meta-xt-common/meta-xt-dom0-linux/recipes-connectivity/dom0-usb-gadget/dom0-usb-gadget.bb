SUMMARY = "Dom0 USB-C ConfigFS Ethernet gadget management interface"
DESCRIPTION = "Creates a CDC ECM USB Ethernet gadget in Linux Dom0, serves DHCP/mDNS to the USB host, and forwards inbound USB TCP services to DomD."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"
PV = "1.0"

SRC_URI = " \
    file://dom0-usb-gadget-up \
    file://dom0-usb-gadget.service \
    file://resolved-usb-gadget.conf \
    file://udhcpd-usb0.conf \
"
S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/dom0-usb-gadget-up ${D}${bindir}/dom0-usb-gadget-up

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dom0-usb-gadget.service ${D}${systemd_system_unitdir}/dom0-usb-gadget.service

    install -d ${D}${sysconfdir}/systemd/resolved.conf.d
    install -m 0644 ${UNPACKDIR}/resolved-usb-gadget.conf ${D}${sysconfdir}/systemd/resolved.conf.d/usb-gadget.conf

    install -d ${D}${sysconfdir}/udhcpd
    install -m 0644 ${UNPACKDIR}/udhcpd-usb0.conf ${D}${sysconfdir}/udhcpd/usb0.conf
}

SYSTEMD_SERVICE:${PN} = "dom0-usb-gadget.service"
FILES:${PN} += " \
    ${bindir}/dom0-usb-gadget-up \
    ${systemd_system_unitdir}/dom0-usb-gadget.service \
    ${sysconfdir}/systemd/resolved.conf.d/usb-gadget.conf \
    ${sysconfdir}/udhcpd/usb0.conf \
"
RDEPENDS:${PN} = " \
    busybox \
    iptables \
    iptables-modules \
    iproute2 \
    kmod \
    systemd \
    kernel-module-ip-tables \
    kernel-module-iptable-filter \
    kernel-module-iptable-nat \
    kernel-module-nf-conntrack \
    kernel-module-nf-defrag-ipv4 \
    kernel-module-nf-nat \
    kernel-module-x-tables \
    kernel-module-xt-nat \
    kernel-module-xt-tcpudp \
    kernel-module-libcomposite \
    kernel-module-u-ether \
    kernel-module-usb-f-ecm \
    kernel-module-usb-f-ncm \
"
