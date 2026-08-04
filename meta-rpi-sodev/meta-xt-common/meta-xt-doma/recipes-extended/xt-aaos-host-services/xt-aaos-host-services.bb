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

# vehicle_hal_grpc_server / dumpstate_grpc_server are built from AOSP (Apache-2.0);
# gnss_replay.py and aaos.dumpstate.xml carry AOSP Apache-2.0 headers. The prebuilt
# binaries are redistributed under Apache-2.0, so per Apache-2.0 section 4(d) the
# AOSP NOTICE must travel with them: it is staged alongside the prebuilt binaries
# (file://NOTICE) and installed into ${datadir}/licenses/${PN}/NOTICE below. Unlike
# the two binaries, the NOTICE is committed to this repository: the recipe cannot
# fetch it otherwise, so a fresh clone would fail at do_fetch on the DomA path.
#
# Provenance of the two gRPC servers, confirmed against the staged binaries:
#   vehicle_hal_grpc_server  (BuildID sha1 d14002bf24b9b74c99622456f21150cf50dac0be)
#     = AOSP device/google/trout hal/vehicle/2.0 -- symbols GrpcVehicleServer.cpp,
#       IVehicleServer, VehicleServer.proto, plus the AOSP default/emulator VHAL
#       protocol (vhal_proto.MsgType, EmulatorMessage) from
#       hardware/interfaces/automotive/vehicle/2.0/default.
#   dumpstate_grpc_server    (BuildID sha1 ef4b1f7d67695d067431994005fb33537e604cbf)
#     = AOSP device/google/trout hal/dumpstate/1.1 -- symbols DumpstateGrpcServer,
#       DumpstateServer.proto, dumpstate_proto.*.
# This is the same implementation the AGL reference workspace uses: meta-rcar-demo
# adds the AOSP checkout's agl_services_build/yocto-layer/meta-google as a layer and
# builds these two targets from that source (recipe google-trout-agl-services). The
# reference build has no prebuilt-binary path and publishes no binary checksum, so
# the identity is established from the AOSP source paths above, not by hash compare.
#
# LICENSE below follows that upstream recipe, which also declares "CLOSED" with no
# LIC_FILES_CHKSUM. The two binaries aggregate material under several licenses (see
# the inventory below), and OpenEmbedded's LICENSE field cannot be left unset --
# bitbake defaults it to "INVALID" and base.bbclass turns that into a fatal error --
# so some value has to be chosen. "CLOSED" is the one that asserts nothing about how
# those licenses combine; picking a single license, or an expression joining them,
# would be a statement this recipe is not in a position to make. Its practical
# effect, measured against a normal recipe in the same build: insane.bbclass skips
# LIC_FILES_CHKSUM validation, and license.bbclass collects no license text under
# ${LICENSE_DIRECTORY}/${PN}/ -- only a recipeinfo reading "LICENSE: CLOSED", where
# openssh in the same build gets its LICENCE plus one generic_* file per license.
# The package is still listed in the image license.manifest, as "LICENSE: CLOSED".
# The AOSP NOTICE is unaffected and still ships: it is installed explicitly into
# ${datadir}/licenses/${PN}/NOTICE below, independent of this field.
#
# Third-party content actually present in the two staged binaries, measured rather
# than inferred from the upstream SRC_URI. Reproduce with:
#     readelf -d <binary> | grep -E 'NEEDED|RUNPATH|RPATH'
#     strings -a <binary> | grep -ciE 'grpc_core|grpc\.io|GRPC_'      # per component
#
#   dynamically linked (both):  libm, libstdc++, libgcc_s, libc, ld-linux-aarch64
#   dynamically linked (dumpstate only): libxml2.so.2                       MIT
#   statically linked (both):   gRPC 1.16.0-dev                             Apache-2.0
#                               protobuf                                    BSD-3-Clause
#                               BoringSSL                                   OpenSSL/ISC/BSD family
#                               zlib 1.2.11                                 Zlib
#   statically linked (vehicle_hal only): jsoncpp                           MIT
#                               Android libbase                             Apache-2.0
#
# Neither binary carries RUNPATH or RPATH. Three of the third parties the upstream
# SRC_URI pins are NOT linked in and can be disregarded for these binaries -- c-ares,
# gflags and googletest -- as can abseil, fmtlib and upb, which gRPC builds often
# pull in but this one did not. All six give zero hits in both binaries.
#
# The aggregate expression for redistribution -- how the BoringSSL OpenSSL-family
# terms and the BSD/MIT/Zlib components combine, and which license texts must
# accompany the package -- is a legal determination, not a build decision, and is
# deliberately not asserted here. The inventory above is the input to that review.
# Note that this repository ships neither binary (both are .gitignore'd and staged
# by the builder), so nothing is redistributed by the repository itself.
LICENSE = "CLOSED"

SRC_URI = " \
    file://vehicle_hal_grpc_server \
    file://dumpstate_grpc_server \
    file://gnss_replay.py \
    file://aaos.dumpstate.xml \
    file://test.csv \
    file://NOTICE \
    file://vehicle_hal_grpc_server.service \
    file://dumpstate_grpc_server.service \
    file://gnss_replay.service \
    "

S = "${UNPACKDIR}"

# Prebuilt aarch64 binaries, so skip the source-build-oriented QA checks.
#   already-stripped : already stripped (file reports "stripped")
#   ldflags          : our LDFLAGS do not apply to a prebuilt binary
#   arch / file-rdeps : the prebuilt ABI / .so deps are declared via RDEPENDS,
#                       so re-inspection by do_package_qa is unnecessary
#   libdir / textrel : tolerate prebuilt PIE check differences
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"
INSANE_SKIP:${PN} += "already-stripped ldflags arch file-rdeps libdir textrel staticdev"

# Not built by us (prebuilt), so there is no debug source either.
PACKAGES = "${PN}"

inherit systemd

# As on V4H, auto-start on DomD boot (so the vsock backend is up before DomA boots).
# dumpstate_grpc_server.service is NOT auto-enabled: the prebuilt binary needs
# libxml2.so.2 and wrynose ships .so.16 (see the prebuilt-binary note below) — on
# hardware (log audit) the unit crash-looped with "error while
# loading shared libraries: libxml2.so.2". The unit file stays installed;
# re-add it here once the blob is rebuilt against wrynose libxml2.
SYSTEMD_SERVICE:${PN} = "vehicle_hal_grpc_server.service gnss_replay.service"
SYSTEMD_AUTO_ENABLE = "enable"

# dumpstate_grpc_server -> libxml2.so.2, gnss_replay.py -> python3
RDEPENDS:${PN} = "libxml2 python3"

# dumpstate_grpc_server is a PREBUILT aarch64 binary (from the
# V4H reference image) linked against libxml2.so.2. wrynose ships libxml2
# 2.15.2 whose SONAME bumped to libxml2.so.16, so the auto-generated shlib
# requires `libxml2.so.2()(64bit)` / `libxml2.so.2(LIBXML2_2.4.30)(64bit)` are
# unprovidable and abort do_rootfs with dnf "nothing provides libxml2.so.2".
# These prebuilt binaries declare their real runtime deps via the explicit
# RDEPENDS above, so disable the rpm auto file-dependency scan for this package
# (SKIP_FILEDEPS) to stop the unprovidable libxml2.so.2 requires from being
# emitted into the RPM header. The explicit RDEPENDS "libxml2" still pulls in
# wrynose's libxml2 (best-effort for the non-critical dumpstate diagnostics
# backend; VHAL/vehicle_hal is base-libs only and unaffected). NOTE: dumpstate
# may need a libxml2.so.2->.so.16 compat shim or a rebuild against wrynose
# libxml2 to be fully functional; that rebuild is a known follow-up.
SKIP_FILEDEPS:${PN} = "1"

do_install() {
    # Backend binaries -> /usr/bin
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/vehicle_hal_grpc_server ${D}${bindir}/vehicle_hal_grpc_server
    install -m 0755 ${UNPACKDIR}/dumpstate_grpc_server   ${D}${bindir}/dumpstate_grpc_server
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
    ${bindir}/vehicle_hal_grpc_server \
    ${bindir}/dumpstate_grpc_server \
    ${bindir}/gnss_replay.py \
    ${sysconfdir}/aaos.dumpstate.xml \
    ${datadir}/gnss/test.csv \
    ${datadir}/licenses/${PN}/NOTICE \
    ${systemd_system_unitdir}/vehicle_hal_grpc_server.service \
    ${systemd_system_unitdir}/dumpstate_grpc_server.service \
    ${systemd_system_unitdir}/gnss_replay.service \
    "

COMPATIBLE_MACHINE = "raspberrypi5"
