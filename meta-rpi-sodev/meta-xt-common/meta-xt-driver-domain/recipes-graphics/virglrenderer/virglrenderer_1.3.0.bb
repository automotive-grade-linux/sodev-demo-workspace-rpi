# From openembedded-core (fb79a14212d8, "virglrenderer: upgrade 1.2.0 -> 1.3.0"), unchanged apart
# from these comments, BBCLASSEXTEND (target only) and the render-server line at the end. Not
# used unless PREFERRED_VERSION_virglrenderer selects it: both boards' vulkan lanes do
# (rpi4-sodev.yaml and rpi5-sodev.yaml, "1.3.%"); the gl lane keeps poky's 1.2.0, as does
# a build that sets nothing (the layer's conf/layer.conf).

SUMMARY = "VirGL virtual OpenGL renderer"
DESCRIPTION = "Virgil is a research project to investigate the possibility of \
creating a virtual 3D GPU for use inside qemu virtual machines, that allows \
the guest operating system to use the capabilities of the host GPU to \
accelerate 3D rendering."
HOMEPAGE = "https://virgil3d.github.io/"

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://COPYING;md5=c81c08eeefd9418fca8f88309a76db10"

DEPENDS = "libdrm libepoxy python3-pyyaml-native virtual/egl virtual/libgbm"
SRCREV = "ca50e008863837e094747a69974dde3ae148aeaa"
SRC_URI = "git://gitlab.freedesktop.org/virgl/virglrenderer.git;branch=main;protocol=https;tag=${PV} \
           file://0001-meson.build-use-python3-directly-for-python.patch \
           file://986b5fc57b07c06b5e0b3a3694d06898ebc80163.patch \
           "

inherit meson pkgconfig features_check

PACKAGECONFIG ?= "${@bb.utils.contains('DISTRO_FEATURES', 'vulkan', 'venus', '', d)}"

PACKAGECONFIG[venus] = "-Dvenus=true,-Dvenus=false,vulkan-loader vulkan-headers"
PACKAGECONFIG[va] = "-Dvideo=true,-Dvideo=false,libva"
PACKAGECONFIG[minigbm_allocation] = "-Dminigbm_allocation=true,-Dminigbm_allocation=false"
PACKAGECONFIG[tests] = "-Dtests=true,-Dtests=false,libcheck"

# Target only: PREFERRED_VERSION_virglrenderer does not reach virglrenderer-native or
# nativesdk-virglrenderer, which as this higher-priority layer's recipe would otherwise
# take 1.3.0 (oe-core declares "native nativesdk" here).
BBCLASSEXTEND = ""

REQUIRED_DISTRO_FEATURES = "opengl"

# The yamls' vulkan lane appends PACKAGECONFIG "render-server" (a 1.2.0 option). 1.3.0 removed the
# option and always builds the render server together with Venus (meson.build: with_render_server = with_venus),
# so accept the name as a no-op instead of failing the invalid-packageconfig QA check.
PACKAGECONFIG[render-server] = ",,"
