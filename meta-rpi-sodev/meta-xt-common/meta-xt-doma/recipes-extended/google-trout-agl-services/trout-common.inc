# Common build glue for the two trout-AGL-services recipes (native tool build and
# target build). Ported from the Google/EPAM meta-google layer -- see the header of
# trout-sources.inc for why this is a port rather than a `layers:` entry.
#
# Both recipes compile the SAME source tree, so the fetch happens once in
# google-trout-agl-services-source and the two consumers point `S` at that
# work-shared directory and skip fetch/unpack/patch entirely.

require trout-sources.inc

# The source is provided by google-trout-agl-services-source; do not fetch again.
do_fetch() {
    :
}
do_fetch[noexec] = "1"
deltask do_unpack
deltask do_patch

# Overrides the S from trout-sources.inc: point at the shared checkout instead of
# this recipe's own (never-populated) UNPACKDIR.
# The shared checkout lives under the -source recipe's UNPACKDIR, i.e.
# <work-shared>/<PV>-<PR>/sources/<FETCH_CODE_PREFIX> -- the "sources" element is
# what wrynose inserted (UNPACKDIR ??= "${WORKDIR}/sources"). Upstream's scarthgap
# version unpacked straight into WORKDIR and omits it.
TROUT_SHARED_WORKDIR = "${TMPDIR}/work-shared/google-trout-agl-services-source/${PV}-${PR}"
S = "${TROUT_SHARED_WORKDIR}/sources/${FETCH_CODE_PREFIX}"

do_configure[depends] += "google-trout-agl-services-source:do_patch"
do_populate_lic[depends] += "google-trout-agl-services-source:do_unpack"

# CMakeLists.txt builds more than we ship; compile only what gets installed.
def trout_compile_targets(d):
    install_entries = d.getVar('TROUT_target_install').split()
    return ' '.join(map(lambda x: x.split(':')[0], install_entries))

# TROUT_target_install entries are either "name" or "built_name:installed_name";
# the latter needs a symlink so `install` picks up the renamed artifact.
def trout_do_install(d):
    import os
    entries = d.getVar('TROUT_target_install').split()
    bindir_src = os.path.join(d.getVar('B'), 'bin')
    install_dir = '{}{}'.format(d.getVar('D'), d.getVar('bindir'))
    bb.utils.mkdirhier(install_dir)
    for entry in entries:
        if ':' in entry:
            src, dst = entry.split(':')
            trout_force_symlink(os.path.join(bindir_src, src),
                                os.path.join(bindir_src, dst))
        else:
            dst = entry
        bb.process.run(['install', '-m', '0755',
                        os.path.join(bindir_src, dst), install_dir])

OECMAKE_TARGET_COMPILE = "${@trout_compile_targets(d)}"

# wrynose ships cmake-native 4.x, which removed support for
# `cmake_minimum_required(VERSION <3.5)`. The pinned third-party sources here are from
# the Android 12 era and still declare 3.x minimums (grpc-grpc/CMakeLists.txt:24 is the
# first to trip it), so configuring fails outright. CMake's own escape hatch is to
# state the minimum policy version explicitly; that keeps the old policy defaults
# instead of patching upstream CMake files we do not own.
# Not needed on scarthgap (cmake 3.x), which is why the V4H SoDeV never hit this.
EXTRA_OECMAKE:append = " -DCMAKE_POLICY_VERSION_MINIMUM=3.5"

inherit pkgconfig cmake

python do_install() {
    trout_do_install(d)
}
