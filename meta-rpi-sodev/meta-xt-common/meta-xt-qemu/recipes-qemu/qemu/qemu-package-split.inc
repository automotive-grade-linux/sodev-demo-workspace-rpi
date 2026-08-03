PACKAGES:prepend:class-target = "${PN}-system-aarch64 "
# QEMU_TARGETS = "aarch64" (set in this layer's qemu_%.bbappend) builds BOTH
# aarch64 binaries, so both need a package. This file only has to add
# ${PN}-system-aarch64, because ${PN}-aarch64 already comes from
# meta-virtualization's split.
#
# Both splits are in effect at once, which is worth spelling out: two bbappends
# carry the same `require ${BPN}-package-split.inc` line -- meta-virtualization's
# and this layer's -- and each resolves to the copy sitting next to it, so both
# files are parsed and both PACKAGES:prepend apply. Confirmed with `bitbake -e
# qemu`: the expanded PACKAGES lists qemu-system-aarch64 first (from here) and
# qemu-aarch64 further down (from meta-virtualization), and both .inc paths appear
# in the -e output.
#
# The two FILES assignments that give each package exactly one binary live in
# meta-xt-driver-domain/recipes-qemu/qemu/qemu_%.bbappend. They are load-bearing:
# meta-virtualization assigns BOTH binaries to ${PN}-aarch64, so without the
# override ${PN}-system-aarch64 would ship empty. Confirmed the same way --
# `bitbake -e` reports FILES:qemu-aarch64 = "/usr/bin/qemu-aarch64" -- and against
# the built pkgdata: qemu-aarch64 -> /usr/bin/qemu-aarch64, qemu-system-aarch64 ->
# /usr/bin/qemu-system-aarch64.

FILES:${PN}-system-aarch64:class-target = "${bindir}/qemu-system-aarch64"
RDEPENDS:${PN}-system-aarch64:append:class-target = "${PN}"
INSANE_SKIP:${PN}-system-aarch64:class-target = "file-rdeps"
