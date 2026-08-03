# Remove desktop OpenGL from SDL2 (V4H reference parity), for the DomU display.
#
# When the qemu device-model (disaggregated DomD, -M xenpv qdisk-backend, no QMP
# monitor, before the main loop) uses `-display sdl,gl=on` and SDL has desktop
# opengl, SDL itself calls eglInitialize/eglCreateContext on V3D. That SDL-EGL
# init blocks synchronously, so qemu cannot signal ready and hangs, libxl reports
# "Qdisk backend not ready", and the DomU is paused.
#
# fix = drop the `opengl` PACKAGECONFIG, as V4H does. `wayland gles2`
# (SDL_OPENGLES=ON + EGL on wayland) is kept, so the `-display sdl,gl=on`
# GLES/dmabuf path still works and GL is isolated to qemu's virglrenderer path.
#
# `arm-neon` is added in the same place because SDL's aarch64 tune features do not
# carry `neon`, so SDL's NEON blit and YUV conversion paths would otherwise be
# compiled out. Those are on the guest-surface blit path, which is the one that
# matters for the cluster. Both changes are gated on the enable_virtio
# DISTRO_FEATURE so a non-virtio build keeps stock SDL behaviour.
PACKAGECONFIG:append = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' arm-neon', '', d)}"
PACKAGECONFIG:remove = "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' opengl', '', d)}"
