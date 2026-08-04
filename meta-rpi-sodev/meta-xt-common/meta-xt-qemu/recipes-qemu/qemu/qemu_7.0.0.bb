BBCLASSEXTEND = "nativesdk"

# Copied verbatim from OE-Core (poky) meta/recipes-devtools/qemu/qemu_7.0.0.bb (MIT).
# It is carried here only so that the 7.0.0 version this board needs stays
# available after poky moved on; see qemu.inc for the source delta.

require qemu.inc

DEPENDS = "glib-2.0 zlib pixman bison-native ninja-native meson-native"

DEPENDS:append:libc-musl = " libucontext"

CFLAGS += "${@bb.utils.contains('DISTRO_FEATURES', 'x11', '', '-DEGL_NO_X11=1', d)}"

RDEPENDS:${PN}:class-target += "bash"

EXTRA_OECONF:append:class-target = " --target-list=${@get_qemu_target_list(d)}"
EXTRA_OECONF:append:class-target:mipsarcho32 = "${@bb.utils.contains('BBEXTENDCURR', 'multilib', ' --disable-capstone', '', d)}"
EXTRA_OECONF:append:class-nativesdk = " --target-list=${@get_qemu_target_list(d)}"

PACKAGECONFIG ??= " \
    fdt sdl kvm pie slirp \
    ${@bb.utils.filter('DISTRO_FEATURES', 'alsa xen', d)} \
    ${@bb.utils.contains('DISTRO_FEATURES', 'opengl', 'virglrenderer epoxy', '', d)} \
    ${@bb.utils.filter('DISTRO_FEATURES', 'seccomp', d)} \
"
PACKAGECONFIG:class-nativesdk ??= "fdt sdl kvm pie slirp \
    ${@bb.utils.contains('DISTRO_FEATURES', 'opengl', 'virglrenderer epoxy', '', d)} \
"
# ppc32 hosts are no longer supported in qemu
COMPATIBLE_HOST:powerpc = "null"
