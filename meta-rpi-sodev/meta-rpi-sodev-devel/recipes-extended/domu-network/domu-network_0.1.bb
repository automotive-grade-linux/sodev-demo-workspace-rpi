# SPDX-License-Identifier: Apache-2.0
SUMMARY = "Lab network + ssh debug config for DomU (xen-netfront client)"
DESCRIPTION = "Drops systemd-networkd config for DomU eth0 (192.168.10.12/24, \
xen-netfront) and enables empty-password root login for SSH access. \
DomU = AGL Cluster IC. DomU does NOT host the bridge — DomD does."

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

# [R4 net-single-source] DomU's static IP / gateway / DNS mirror the flat-L2 map
# in sodev-net.inc (meta-xt-driver-domain): DomD xenbr0 = router+resolver = .10.10,
# DomU = .10.12. NOTE: DomU is assembled in a SEPARATE bitbake instance (build-domu)
# whose bblayers does NOT include meta-xt-driver-domain, so sodev-net.inc cannot be
# `require`d here; the values are set directly in 20-eth0.network below and kept in
# sync with sodev-net.inc by hand. This replaces the old stale gateway (.10.1) /
# public DNS (8.8.8.8/1.1.1.1).

SRC_URI = " \
    file://20-eth0.network \
    file://xt-debug.conf \
"

S = "${UNPACKDIR}"

# The empty root password is set at image build time by the empty-root-password
# IMAGE_FEATURE (rpi5-image-domu-gfx.bb); this package only ships the sshd drop-in
# (xt-debug.conf) that permits empty-password root login. (Removed a dead
# `extrausers` inherit: EXTRA_USERS_PARAMS is consumed only by an image's do_rootfs
# via set_user_group, never by a package recipe like this one, so it never ran.)
inherit allarch

RDEPENDS:${PN} = "openssh-sshd openssh-sftp-server systemd"

do_install() {
    install -d ${D}${sysconfdir}/systemd/network
    install -m 0644 ${UNPACKDIR}/20-eth0.network \
        ${D}${sysconfdir}/systemd/network/20-eth0.network

    # sshd_config drop-in: PermitRootLogin yes + PermitEmptyPasswords yes
    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0644 ${UNPACKDIR}/xt-debug.conf \
        ${D}${sysconfdir}/ssh/sshd_config.d/xt-debug.conf
}
FILES:${PN} = " \
    ${sysconfdir}/systemd/network/20-eth0.network \
    ${sysconfdir}/ssh/sshd_config.d/xt-debug.conf \
"
