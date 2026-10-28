# Switch the AGL cluster onto the Vulkan embedder, as a SEPARATE PACKAGE.
#
# flutter-auto-vulkan (this layer's second embedder recipe) only puts a binary in the
# rootfs; nothing runs it, because meta-agl-demo's flutter-cluster-dashboard.service
# hard-codes ExecStart=/usr/bin/flutter-auto. The systemd drop-in installed here
# replaces that ExecStart with the Vulkan binary plus --enable-impeller.
#
# Why a package of its own rather than an edit of the service file: build.sh's
# --gpu=vulkan (the default) adds flutter-cluster-dashboard-conf-vulkan to
# IMAGE_INSTALL and --gpu=gl does not, so the drop-in reaches that image and no
# other image this AGL build produces. (The base package's task hashes still
# differ between the lanes: --gpu=gl takes this layer, and with it this append,
# out of the build.) Same shape as the recipe's own -conf-kvm package, which
# installs kvm.conf into the same .service.d directory.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://vulkan.conf"

# 0002: fill the cluster's 1920x720 output (weston-ini-conf.bbappend); the dashboard
# otherwise lays itself out in a 1280x720 box with black bars at the sides. Numbered after
# meta-agl-demo's own 0001-Implement-dummy-signal.patch, which it applies on top of. See the
# patch.
SRC_URI += "file://0002-home-fill-a-window-wider-than-16-9.patch"

do_install:append() {
    install -D -m 0644 ${WORKDIR}/vulkan.conf \
        ${D}${systemd_system_unitdir}/${BPN}.service.d/vulkan.conf
}

PACKAGE_BEFORE_PN += "${PN}-conf-vulkan"
FILES:${PN}-conf-vulkan += "${systemd_system_unitdir}/flutter-cluster-dashboard.service.d/vulkan.conf"
# flutter-auto-vulkan is what the drop-in's ExecStart points at, so the package that
# carries the drop-in is what must pull the binary in.
RDEPENDS:${PN}-conf-vulkan = "${PN} flutter-auto-vulkan"

# meta-flutter writes pubspec.lock into the app only in do_archive_pub_cache, and that task
# returns early when WORKDIR/PUB_CACHE_ARCHIVE names an archive that already exists. So in a
# workspace that built the dashboard once, a source unpacked again (SRC_URI changed, e.g. by
# the 0002 above) has no pubspec.lock, and do_compile's `flutter pub get --enforce-lockfile
# --offline` fails ("Cannot do `--enforce-lockfile` without an existing `pubspec.lock`").
# The archive keeps a copy of the app under ./.project, lock file included: take it from there.
do_compile[prefuncs] += "sodev_restore_pubspec_lock"
python sodev_restore_pubspec_lock() {
    import os
    import subprocess

    app_root = os.path.join(d.getVar('S'), d.getVar('FLUTTER_APPLICATION_PATH'))
    lock = os.path.join(app_root, 'pubspec.lock')
    if os.path.exists(lock):
        return
    with open(os.path.join(d.getVar('WORKDIR'), 'PUB_CACHE_ARCHIVE')) as f:
        archive = os.path.join(d.getVar('DL_DIR'), f.read().strip())
    with open(lock + '.tmp', 'wb') as out:
        subprocess.check_call(['tar', '-xjf', archive, '-O', './.project/pubspec.lock'],
                              stdout=out)
    os.replace(lock + '.tmp', lock)
    bb.note('pubspec.lock restored from %s' % archive)
}
