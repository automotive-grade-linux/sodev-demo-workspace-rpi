require recipes-kernel/linux-libc-headers/linux-libc-headers.inc

# The DomU/DomA guest libc headers track the 6.8 series (MACHINE=virtio-armv8-xt
# selects this via LINUXLIBCVERSION in meta-xt-domu's machine conf).
# Repinned from a torvalds/linux master rc SRCREV (6.8.0-rc1, 6613476e...) to
# the official linux-6.8 release tarball from kernel.org: an rc-version ABI
# must not be treated as a release ABI, and the git clone pulled the full tree.
# linux-libc-headers.inc already sets, for PV=6.8:
#   SRC_URI = "${KERNELORG_MIRROR}/linux/kernel/v6.x/linux-${PV}.tar.xz"
#   S       = "${UNPACKDIR}/linux-${PV}"
# so no source-fetch overrides are needed here beyond the release checksum.

LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

# sha256 of linux-6.8.tar.xz from the PGP-signed kernel.org v6.x sha256sums.asc.
SRC_URI[sha256sum] = "c969dea4e8bb6be991bbf7c010ba0e0a5643a3a8d8fb0a2aaa053406f1e965f3"
