# A second Flutter embedder: flutter-auto's recipe built for Vulkan instead of
# EGL.
#
# Why a separate recipe rather than a PACKAGECONFIG change on flutter-auto: in
# ivi-homescreen the backend is a COMPILE-TIME EXCLUSIVE choice. shell/view/flutter_view.cc
# selects it with an #if/#elif chain (BUILD_BACKEND_HEADLESS_EGL / _WAYLAND_DRM /
# _WAYLAND_EGL / _WAYLAND_VULKAN), and cmake/options.cmake only offers
# BUILD_BACKEND_WAYLAND_VULKAN when BUILD_BACKEND_WAYLAND_EGL is OFF. One binary can
# therefore serve exactly one backend, and comparing the two on the same application needs
# two binaries installed side by side.
#
# Everything except the backend comes from the stock recipe. The toolchain does
# not: meta-flutter's clang-layer flutter-auto_2.0.bbappend (clang and libc++)
# attaches by file name, so it reaches flutter-auto and not this recipe, which
# builds with gcc. The plugin list is NOT touched: the AGL cluster dashboard
# registers its plugins at startup, and a differing plugin set would change what
# the application does, not just how it draws.
#
# The base recipe's EXTRA_OECMAKE already passes -D EXE_OUTPUT_NAME=${PN}, so this builds
# /usr/bin/flutter-auto-vulkan and cannot collide with the shipped /usr/bin/flutter-auto.
# A different PN also means a separate WORKDIR and sstate signature, so adding this recipe
# does not rebuild or perturb the EGL flutter-auto that the image actually ships.

require recipes-graphics/toyota/flutter-auto_2.0.bb

# The patch below lives beside this recipe, not beside the required one, so FILESPATH has
# to be told: `require` restores THISDIR to this file's directory once it returns.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The Vulkan backend is the least-travelled path in this tree and does not compile against
# the Vulkan-Headers AGL scarthgap ships (1.3.275). See the patch header for the full
# reasoning; in short, resultCheck and defaultDispatchLoaderDynamic moved into vk::detail
# in 1.3.296 and this source is written against the post-move layout. The patch is applied
# only here, so the shipped EGL flutter-auto is untouched.
SRC_URI += "file://0001-wayland_vulkan-build-against-Vulkan-Headers-before-1.3.296.patch"

# Mesa's Wayland WSI (24.0) asks for a new swapchain only through vkAcquireNextImageKHR's
# VK_SUBOPTIMAL_KHR, which this backend ignored, so the cluster kept the tiled images it
# started with and the compositor composed them with the GPU every frame. See the patch.
SRC_URI += "file://0002-wayland_vulkan-rebuild-the-swapchain-when-acquiring-says-suboptimal.patch"

SUMMARY = "Toyota IVI Homescreen v2.0, Vulkan backend"
DESCRIPTION = "flutter-auto built against BUILD_BACKEND_WAYLAND_VULKAN. This is the \
embedder the Vulkan lane runs the AGL instrument cluster on (the systemd drop-in in \
recipes-demo/flutter-cluster-dashboard points ExecStart at it); the shipped EGL \
flutter-auto stays installed beside it and is what --gpu=gl uses."

# Copied verbatim from flutter-auto_2.0.bb, with
#   backend-wayland-egl egl-3d egl-transparency egl-multisample
# replaced by
#   backend-wayland-vulkan
# and nothing else changed. The egl-* options are dropped because they are EGL config
# knobs (BUILD_EGL_ENABLE_3D / _TRANSPARENCY / _ENABLE_MULTISAMPLE) that cmake only
# defines inside the BUILD_BACKEND_WAYLAND_EGL branch.
PACKAGECONFIG = "\
    backend-wayland-vulkan \
    \
    client-xdg \
    client-agl-shell \
    \
    ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'wdt_systemd', '', d)} \
    \
    nav_render_view \
    \
    audioplayer_linux \
    go_router \
    secure-storage \
    url_launcher \
    desktop_window_linux \
    rive-text \
    "

# The Vulkan backend needs an ICD at runtime; vulkan-loader is already a build dependency
# via PACKAGECONFIG[backend-wayland-vulkan]. mesa-vulkan-drivers carries the Venus ICD that
# this whole comparison exists to exercise.
RDEPENDS:${PN} += "vulkan-loader mesa-vulkan-drivers"

REQUIRED_DISTRO_FEATURES += "vulkan"
