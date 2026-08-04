SUMMARY = "Dom0<->DomD vif bring-up (point-to-point management vif)"
DESCRIPTION = "Attaches the Dom0<->DomD vif for the dom0less DomD (domid 1) and \
puts the Dom0 end on the point-to-point 192.168.0.0/24 subnet (Dom0 = \
192.168.0.1; DomD netfront = 192.168.0.11). The flat 192.168.10.0/24 \
management segment lives inside DomD (xenbr0 at .10.10), where DomD / DomU / \
DomA and the PC share one L2 segment; the p2p vif gives Dom0 a route into it \
via DomD. The old RP1 touch evdev forwarder is removed: touch is now \
native in DomD via RP1 USB passthrough (the Xen-ARM MSI-X gap was solved by \
route_msi_ranges_to_domain), so no Dom0-side forwarding is needed."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"
PV = "1.0"

# Single source of truth for the DomD network topology. This .inc lives in
# meta-xt-driver-domain (always co-present with meta-xt-dom0-linux in every
# build that parses this recipe) and is found via BBPATH.
require recipes-connectivity/sodev-net.inc

SRC_URI = " \
    file://dom0-domd-vif-up \
    file://dom0-domd-vif.service \
"
S = "${UNPACKDIR}"

inherit systemd

do_install() {
    install -d ${D}${bindir}
    # Dom0<->DomD vif bring-up for the dom0less DomD (no vif from a config file).
    install -m 0755 ${UNPACKDIR}/dom0-domd-vif-up ${D}${bindir}/dom0-domd-vif-up
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/dom0-domd-vif.service ${D}${systemd_system_unitdir}/dom0-domd-vif.service
}

# [C2 single source] Enforce the point-to-point vif addresses from sodev-net.inc.
# Only the three value assignments are rewritten (anchored ^VAR=); the script
# logic is left untouched.
do_install:append() {
    sed -i \
        -e 's|^IPADDR=.*|IPADDR="${XT_DOM0_VIF_IP}/24"|' \
        -e 's|^PEER=.*|PEER="${XT_DOMD_VIF_IP}"|' \
        -e 's|^DOMD_FLAT=.*|DOMD_FLAT="${XT_DOMD_XENBR0_IP}"|' \
        ${D}${bindir}/dom0-domd-vif-up
}

SYSTEMD_SERVICE:${PN} = "dom0-domd-vif.service"
FILES:${PN} += "${systemd_system_unitdir}/dom0-domd-vif.service"
FILES:${PN} += "${bindir}/dom0-domd-vif-up"
