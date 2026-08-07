# Shared source fetch for the trout AGL host services (the DomD-side gRPC backends
# that the AAOS guest talks to over vsock).
#
# Ported from the Google/EPAM Yocto layer that ships inside the AOSP checkout at
#   device/epam/aosp-xenvm-trout/agl_services_build/yocto-layer/meta-google
# (itself a fork of device/google/trout/agl_services_build/yocto-layer/meta-google).
#
# Why ported instead of consuming that layer directly, the way the V4H SoDeV does
# (`layers:` entry pointing into the AOSP checkout):
#
#   1. That layer declares `LAYERSERIES_COMPAT_meta-google = "kirkstone scarthgap"`.
#      This project is on Wrynose 6.0, and bitbake refuses such a layer outright --
#      bitbake/lib/bb/cookerdata.py checks the intersection against
#      LAYERSERIES_CORENAMES and calls bb.fatal() BEFORE conf/bitbake.conf is parsed,
#      so neither local.conf nor a bbappend can relax it. (The gate is not in
#      Google's upstream copy; EPAM added it for the R-Car product.)
#   2. It sets `S` the pre-UNPACKDIR way (`${WORKDIR}/src`). Wrynose unpacks into
#      ${UNPACKDIR} (= ${WORKDIR}/sources), so `S` would point at nothing.
#   3. Its `LICENSE = "CLOSED"` (with a TODO from the original author) propagates to
#      every recipe that requires it, so the three binaries land in the image's
#      license manifest as CLOSED even though the material is not. For an AGL
#      contribution that has to be stated correctly -- see the LICENSE note below.
#   4. Consuming a layer from inside the AOSP checkout couples the DomD Yocto build
#      to the AOSP build (V4H needs an `additional_deps` on android/out/.../boot.img
#      just to make the layer directory exist). Fetching the same sources by git
#      removes that ordering constraint entirely.
#
# All 14 sources are public and anonymously reachable; revisions are pinned to the
# same commits the AOSP manifest (yhamamachi/android_manifest @ aff3224d) resolves,
# so the binaries match what the AAOS guest in this workspace expects.

# The 14 sources are NOT all Apache-2.0, so neither is this recipe. What each tree
# actually carries, read from the fetched trees rather than assumed:
#
#   Apache-2.0    device/google/trout, hardware/interfaces, grpc-grpc,
#                 system/libbase, system/logging, system/core
#                 (the AOSP repos without a top-level file follow the AOSP default;
#                  the NOTICE files that do exist are the Apache-2.0 text verbatim)
#   BSD-3-Clause  protobuf, gflags, googletest
#   MIT           fmtlib, c-ares, jsoncpp (jsoncpp is dual MIT / public domain)
#   OpenSSL & ISC boringssl -- its own LICENSE says "a fork of OpenSSL. As such, large
#                 parts of it fall under OpenSSL licensing. Files that are completely
#                 new have a Google copyright and an ISC license." Both are named; its
#                 third_party/fiat is MIT, which the MIT above already covers.
#   Zlib          zlib -- the conditions are in zlib.h (there is no separate licence
#                 file), so the checksum pins those lines, not the README, which changes
#                 for reasons unrelated to licensing
#
# LIC_FILES_CHKSUM points at each tree's own text where it has one, so a licence change
# upstream breaks the build instead of passing silently. The three AOSP trees without a
# top-level file are covered by the nearest NOTICE they do ship. The generic Apache-2.0
# text is referenced once for the trout layer itself, which ships no licence file.
#
# This states what the material is; it is not a judgement on how the licences combine
# in a redistributed image. Whoever redistributes one is the party that has to make that
# determination, and this list is the input to it.
LICENSE = "Apache-2.0 & BSD-3-Clause & MIT & OpenSSL & ISC & Zlib"
LIC_FILES_CHKSUM = "\
    file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10 \
    file://hardware/interfaces/NOTICE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
    file://third_party/grpc-grpc/LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
    file://third_party/android/libbase/NOTICE;md5=e832036c59491b20e1665b084eaee6cf \
    file://third_party/android/logging/liblog/NOTICE;md5=2754aa537525e0fed3d297e8379b6d81 \
    file://third_party/android/system_core/libkeyutils/NOTICE;md5=5a20e9c46481c759dd83a5f0b44a437c \
    file://third_party/protobuf/LICENSE;md5=37b5762e07f0af8c74ce80a8bda4266b \
    file://third_party/gflags/COPYING.txt;md5=c80d1a3b623f72bb85a4c75b556551df \
    file://third_party/googletest/LICENSE;md5=cbbd27594afd089daa160d3a16dd515a \
    file://third_party/fmtlib/LICENSE.rst;md5=af88d758f75f3c5c48a967501f24384b \
    file://third_party/cares/LICENSE.md;md5=f4b026880834eb01c035c5e5cb47ccac \
    file://third_party/jsoncpp/LICENSE;md5=fa2a23dd1dc6c139f35105379d76df2b \
    file://third_party/boringssl/LICENSE;md5=9b082148f9953258347788edb83e401b \
    file://third_party/zlib/zlib.h;beginline=4;endline=23;md5=627e6ecababe008a45c70e318ae7014e \
"

ANDROID_REMOTE   = "git://android.googlesource.com"
BORINGSSL_REMOTE = "git://boringssl.googlesource.com"
GITHUB_REMOTE    = "git://github.com"

# Where the manifest-like layout is assembled. Kept as a plain name (not an absolute
# path) so it composes with UNPACKDIR below.
FETCH_CODE_PREFIX = "src"

# Wrynose: the fetcher unpacks into UNPACKDIR, not WORKDIR. The upstream layer still
# assumes the old layout; that difference alone makes it unusable here.
S = "${UNPACKDIR}/${FETCH_CODE_PREFIX}"

def trout_git_uri(d, remote, name, path, revision):
    return '{}/{};protocol=https;nobranch=1;destsuffix={}/{};rev={}'.format(
        d.getVar(remote), name, d.getVar('FETCH_CODE_PREFIX'), path, revision)

# device/google/trout is fetched as a git source here. The upstream layer instead
# ships a committed symlink (mode 120000) pointing 11 levels up into the enclosing
# AOSP checkout -- which is why it only works when the layer lives inside that
# checkout. Pinned to the revision AOSP tag android-15.0.0_r12 resolves for
# platform/device/google/trout.
SRC_URI = "\
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'device/google/trout', 'device/google/trout', '9da712e8261c80c7377d93e4517d09bf223b4fae')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/external/fmtlib', 'third_party/fmtlib', '75cbc736e0160e1a6b3d841c18e7a65938a7347c')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/external/grpc-grpc', 'third_party/grpc-grpc', '8428b748ea53814c5eb4751196f76586571b0146')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/external/jsoncpp', 'third_party/jsoncpp', '1b2c7506fd0ea96c1ffa5de4fc0342ceed420416')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/external/protobuf', 'third_party/protobuf', '564fd16025f8d7913e19b15dd94ac3fec1bdf999')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/hardware/interfaces', 'hardware/interfaces', '6e3c5921c4572758e0af20749c9a60f87d9e0746')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/system/core', 'third_party/android/system_core', 'de29eec33a2f5cba9cd7b481f8ffe5886f2e5e35')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/system/libbase', 'third_party/android/libbase', '988723798df152824c20a4d5e13290d4690df00a')} \
    ${@trout_git_uri(d, 'ANDROID_REMOTE', 'platform/system/logging', 'third_party/android/logging', '16ee30b1f2a84dde0d6d3084fb2fc891397e150c')} \
    ${@trout_git_uri(d, 'BORINGSSL_REMOTE', 'boringssl', 'third_party/boringssl', '0b710a305b42b67522003a314dea3e3868485665')} \
    ${@trout_git_uri(d, 'GITHUB_REMOTE', 'c-ares/c-ares', 'third_party/cares', '3be1924221e1326df520f8498d704a5c4c8d0cce')} \
    ${@trout_git_uri(d, 'GITHUB_REMOTE', 'gflags/gflags', 'third_party/gflags', '28f50e0fed19872e0fd50dd23ce2ee8cd759338e')} \
    ${@trout_git_uri(d, 'GITHUB_REMOTE', 'madler/zlib', 'third_party/zlib', 'cacf7f1d4e3d44d871b605da3b647f07d718623f')} \
    ${@trout_git_uri(d, 'GITHUB_REMOTE', 'google/googletest', 'third_party/googletest', '1fb1bb23bb8418dc73a5a9a82bbed31dc610fec7')} \
"

# device/google/trout/agl_services_build/repo_manifest.xml expresses these as
# <linkfile>; repo is not used here, so the same links are made after unpack.
# (That manifest also points at sso://googleplex-android/, i.e. Google-internal --
# another reason it cannot be used directly.)
SRC_SYMLINKS = "\
    device/google/trout/agl_services_build/build.sh:build.sh \
    device/google/trout/agl_services_build/CMakeLists.txt:CMakeLists.txt \
    device/google/trout/agl_services_build/cmake:cmake \
    device/google/trout/agl_services_build/toolchain:toolchain \
    device/google/trout/hal/audiocontrol:audiocontrol \
    device/google/trout/hal/dumpstate/1.1:dumpstate_server \
    device/google/trout/hal/vehicle/2.0:vehicle_hal_server \
    device/google/trout/hal/common/agl/watchdog:watchdog_test_server \
    hardware/interfaces/automotive/vehicle/2.0/default:third_party/default_native_vehicle_hal \
"

def trout_force_symlink(src, dst):
    src = os.path.relpath(src, os.path.dirname(dst))
    tmplink = '{}.templink'.format(dst)
    if os.path.lexists(tmplink):
        os.unlink(tmplink)
    os.symlink(src, tmplink)
    os.rename(tmplink, dst)

python do_unpack:append() {
    import os
    s = d.getVar('S')
    for rule in d.getVar('SRC_SYMLINKS').split():
        src, dst = rule.split(':')
        # os.symlink happily creates a dangling link, so an upstream path that moved
        # would surface much later as a confusing CMake error about a missing target.
        # Fail here instead, naming the rule that no longer matches the sources.
        if not os.path.exists(os.path.join(s, src)):
            bb.fatal("SRC_SYMLINKS: '%s' does not exist in the fetched sources "
                     "(rule '%s'). A pinned revision moved it -- update SRC_URI and "
                     "SRC_SYMLINKS together." % (src, rule))
        dst = os.path.join(s, dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        trout_force_symlink(os.path.join(s, src), dst)
}
