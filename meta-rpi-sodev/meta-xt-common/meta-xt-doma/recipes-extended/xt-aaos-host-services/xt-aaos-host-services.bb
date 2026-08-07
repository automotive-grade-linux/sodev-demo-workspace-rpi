SUMMARY = "AAOS host-side backend daemons (VHAL / dumpstate / GNSS) for DomA on RPi5"
DESCRIPTION = "\
    AAOS host backend extracted from the V4H reference DomD image \
    and reused as prebuilt binaries, deployed into the RPi5 DomD rootfs. \
    No source build is required (the same aarch64 binaries are installed). \
\
    Components (from V4H /usr/bin + /etc + /usr/share): \
      /usr/bin/vehicle_hal_grpc_server   (AAOS VehicleHAL + power-state forward) \
      /usr/bin/dumpstate_grpc_server     (AAOS dumpstate backend) \
      /usr/bin/gnss_replay.py            (mock GNSS host agent) \
      /etc/aaos.dumpstate.xml            (dumpstate config) \
      /usr/share/gnss/test.csv           (GNSS replay data) \
      /usr/lib/systemd/system/{vehicle_hal_grpc_server,dumpstate_grpc_server,gnss_replay}.service \
\
    Runtime paths (matching doma.cfg): \
      vehicle_hal = vsock cid2:9210 (DomA qemu vhost-vsock-pci guest-cid=3) \
      dumpstate   = vsock cid2:9310 \
      gnss        = /run/gnss-uart (doma.cfg qemu virtconsole server=on,wait=off) \
    The DomD kernel has VSOCK=y / VHOST_VSOCK=y / VHOST=y (no kernel change needed). \
\
    Dependencies (verified with readelf): \
      vehicle_hal_grpc_server = base libs only (grpc/protobuf static link) \
      dumpstate_grpc_server   = + libxml2.so.2 -> RDEPENDS libxml2 \
      gnss_replay.py          = python3 -> RDEPENDS python3 \
\
    The services have no ordering dependency on a vsock unit: the V4H-era \
    Wants/After=coqos-virtio-vsock.service soft refs were dropped (no such unit \
    exists in this build), so the binaries just wait for vsock via Restart=always."
# What this package installs, and under what terms:
#   - our own glue: gnss_replay.py, aaos.dumpstate.xml, test.csv and the three systemd
#     units. MIT, matching the sibling glue recipes in this layer (xt-xen-cfg-doma,
#     xt-xen-cfg-domu).
#   - the AOSP NOTICE, redistributed under Apache-2.0 section 4(d) alongside the gRPC
#     backends. Those backends are NOT in this package: google-trout-agl-services builds
#     and installs them, and declares the licences of the 14 sources they are built from
#     (see the LICENSE note in its sources.inc). This recipe only RDEPENDS on it.
#
# LICENSE was "CLOSED" while the backends were staged prebuilt binaries whose aggregate
# nobody here could state. They are built from source now and this package no longer
# carries them, so CLOSED would misdescribe what is actually installed: our own MIT glue
# plus an Apache-2.0 NOTICE. How the licences of the built binaries combine for
# redistribution remains a legal determination, made against google-trout-agl-services.
LICENSE = "MIT & Apache-2.0"
LIC_FILES_CHKSUM = "\
    file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302 \
    file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10 \
"

# The two gRPC backends are no longer staged binaries: they are built from source by
# google-trout-agl-services (RDEPENDS below). What remains here is the configuration,
# data and unit files that wire them up on DomD.
SRC_URI = " \
    file://gnss_replay.py \
    file://aaos.dumpstate.xml \
    file://test.csv \
    file://NOTICE \
    file://vehicle_hal_grpc_server.service \
    file://dumpstate_grpc_server.service \
    file://gnss_replay.service \
    "

S = "${UNPACKDIR}"

inherit systemd

# As on V4H, auto-start on DomD boot (so the vsock backend is up before DomA boots).
# dumpstate_grpc_server.service is auto-enabled again now that the binary is built
# from source: the prebuilt blob was linked against libxml2.so.2 while wrynose ships
# .so.16, and on hardware the unit crash-looped with "error while loading shared
# libraries: libxml2.so.2". Building in-tree links it against this build's libxml2,
# which removes both that crash loop and the SKIP_FILEDEPS workaround below it.
SYSTEMD_SERVICE:${PN} = "vehicle_hal_grpc_server.service dumpstate_grpc_server.service gnss_replay.service"
SYSTEMD_AUTO_ENABLE = "enable"

# The backends themselves come from google-trout-agl-services; gnss_replay.py needs
# python3. libxml2 is pulled in by that package's own shlib dependency now, but is
# kept explicit because gnss_replay/dumpstate config handling relies on it.
RDEPENDS:${PN} = "google-trout-agl-services libxml2 python3"

# (The prebuilt-binary libxml2.so.2 / SKIP_FILEDEPS workaround is gone: the
#  backends are built against this build's libxml2.)

do_install() {
    # gnss_replay.py -> /usr/bin (the two gRPC backends come from
    # google-trout-agl-services, which installs them into ${bindir} itself)
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/gnss_replay.py          ${D}${bindir}/gnss_replay.py

    # dumpstate config -> /etc
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/aaos.dumpstate.xml ${D}${sysconfdir}/aaos.dumpstate.xml

    # GNSS replay data -> /usr/share/gnss
    install -d ${D}${datadir}/gnss
    install -m 0644 ${UNPACKDIR}/test.csv ${D}${datadir}/gnss/test.csv

    # AOSP NOTICE (Apache-2.0 sec 4d) -> ships with the redistributed binaries
    install -d ${D}${datadir}/licenses/${PN}
    install -m 0644 ${UNPACKDIR}/NOTICE ${D}${datadir}/licenses/${PN}/NOTICE

    # systemd services
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/vehicle_hal_grpc_server.service ${D}${systemd_system_unitdir}/vehicle_hal_grpc_server.service
    install -m 0644 ${UNPACKDIR}/dumpstate_grpc_server.service   ${D}${systemd_system_unitdir}/dumpstate_grpc_server.service
    install -m 0644 ${UNPACKDIR}/gnss_replay.service             ${D}${systemd_system_unitdir}/gnss_replay.service
}

FILES:${PN} = " \
    ${bindir}/gnss_replay.py \
    ${sysconfdir}/aaos.dumpstate.xml \
    ${datadir}/gnss/test.csv \
    ${datadir}/licenses/${PN}/NOTICE \
    ${systemd_system_unitdir}/vehicle_hal_grpc_server.service \
    ${systemd_system_unitdir}/dumpstate_grpc_server.service \
    ${systemd_system_unitdir}/gnss_replay.service \
    "

COMPATIBLE_MACHINE = "raspberrypi5"
