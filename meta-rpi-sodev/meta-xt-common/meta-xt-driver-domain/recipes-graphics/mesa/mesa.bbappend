# wrynose: renamed from mesa_%.bbappend. wrynose mesa is versionless (mesa.bb),
# which a _% (underscore-version) bbappend does NOT match; mesa.bbappend does
# (cf. meta-raspberrypi/meta-selinux both use mesa.bbappend).
#
# Enable glvnd in mesa so the vendor-neutral GL dispatch libraries
# (libOpenGL.so.0 / libEGL.so.1 / libGLESv2.so.2 via libglvnd) are produced.
# The DomD qemu device-model (-display sdl,gl=on + virtio-gpu-gl/virgl) probes
# "libGL.so.1 or libOpenGL.so.0"; without glvnd this wayland-only (x11 removed)
# mesa builds neither, so the GL display init fails. With glvnd, libglvnd provides
# libOpenGL.so.0 (libGL.so.1 needs glx/x11, not built here) which satisfies the probe,
# and libegl-mesa ships the egl_vendor.d JSON so weston's EGL still routes to mesa V3D.
PACKAGECONFIG:append = " glvnd"
