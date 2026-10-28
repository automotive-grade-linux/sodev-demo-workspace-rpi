# -----------------------------------------------------------------------------
# Name the GENET NIC eth0 (see files/00-genet-eth0.link for why this is needed)
# -----------------------------------------------------------------------------
# The shared recipe ships 00-rp1-eth0.link, which matches Driver=macb — RP1's NIC.
# BCM2711 has no RP1, so nothing pins the interface name without this. The rp1 file
# stays installed and simply never matches on this board.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:raspberrypi4-64 = " file://00-genet-eth0.link"

# No do_install override is needed: the shared recipe has S = "${UNPACKDIR}" and
# installs ${S}/*.link wholesale, so adding the file to SRC_URI is enough to get it
# into ${D}. Only the packaging has to be declared.
#
# ${PN}-flatbridge, not ${PN}: that is the package the shared recipe puts
# 00-rp1-eth0.link in, and the naming rule is only wanted where the bridge is. Without
# this the file would trip the installed-vs-shipped QA check.
FILES:${PN}-flatbridge:append:raspberrypi4-64 = " ${sysconfdir}/systemd/network/00-genet-eth0.link"
