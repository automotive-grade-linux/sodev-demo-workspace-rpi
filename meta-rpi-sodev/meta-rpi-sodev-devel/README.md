# meta-rpi-sodev-devel

Diagnostic, debug and prototype assets for the RPi5 + Xen SoDeV disaggregated
cockpit, kept **out of the shipping PR image** on a maintainer recommendation
(same rationale as `meta-agl-devel`: development-only material is isolated so
the delivered image tree contains only what it ships).

This layer is **opt-in**. The default build (`rpi5-sodev.yaml` / `build.sh`) does
**not** reference it, so none of the recipes below are parsed or installed unless
you explicitly add the layer.

## Opt-in

These recipes are **not** standalone: they extend the normal rpi5-sodev build,
so the layers that build already sets up must be present in `bblayers.conf`
*before* the devel layer. The recipes split by domain:

- The **DomD** diagnostics build on `xt-driver-domain`, whose LAYERDEPENDS chain
  is `xt-driver-domain -> xt-rpi5 -> {core, xt-security, raspberrypi}`. They are
  built for `MACHINE=raspberrypi5`.
- The **DomU** tools (`sdl2-demo`, `domu-network`, `rpi5-image-domu-gfx`)
  additionally need `meta-xt-common/meta-xt-domu` (its `virtio-armv8-xt`
  MACHINE) and are built for `MACHINE=virtio-armv8-xt`.

### Recommended: add on top of the existing build

The default `build.sh` / `rpi5-sodev.yaml` already assembles both build trees
with every base layer (poky, meta-raspberrypi, meta-openembedded,
meta-virtualization — which provides `xen` — meta-xt-common/*, meta-xt-rpi5) in
place. The least error-prone way to opt in is to add the devel layer's path to
the relevant component's `layers:` list in `rpi5-sodev.yaml` (the DomD component
for the DomD tools, the DomU component for the DomU tools) and rebuild, or add it
once to the already-configured build directory:

```sh
bitbake-layers add-layer /path/to/meta-rpi-sodev/meta-rpi-sodev-devel
```

### Manual bitbake environment (base layers first)

If you assemble a bitbake environment by hand, add the base layers the devel
recipes depend on **before** the devel layer, bottom-up. For the **DomD** tools:

```sh
# base layers (normally already added by the rpi5-sodev build):
bitbake-layers add-layer /path/to/poky/meta
bitbake-layers add-layer /path/to/meta-yocto/meta-poky          # DISTRO=poky
bitbake-layers add-layer /path/to/meta-raspberrypi
bitbake-layers add-layer /path/to/meta-rpi-sodev/meta-xt-common/meta-xt-security
bitbake-layers add-layer /path/to/meta-rpi-sodev/meta-xt-rpi5
bitbake-layers add-layer /path/to/meta-rpi-sodev/meta-xt-common/meta-xt-driver-domain
# plus the OE layers that provide the installed packages (xen, dnsmasq, socat):
#   meta-openembedded/{meta-oe,meta-networking,meta-python}, meta-virtualization
# then the devel layer:
bitbake-layers add-layer /path/to/meta-rpi-sodev/meta-rpi-sodev-devel
```

For the **DomU** tools, add `meta-xt-common/meta-xt-domu` (plus the
meta-openembedded layers its Wayland/Mesa/SDL2 dependencies need) instead of the
DomD stack, then the devel layer. Because the full base-layer set is large and
must match the build's configuration, the *recommended* path above (reuse the
configured build) is preferred over assembling it by hand.

## Contents (diagnostic / debug / prototype)

Driver-domain (DomD) tools:
- `recipes-extended/xt-vram-tools` — CMA/VRAM dump and analysis scripts, plus the
  GPU first-check and stripe-noise reproducers. Installed into the DomD rootfs by
  this layer's `rpi5-image-xt-domd-vc4.bbappend` (see *How to use* below).
- `recipes-extended/xt-cluster-shm` — a cluster stand-in that renders through
  wl_shm only, for bringing a display path up without the GPU.
- `recipes-graphics/wayland/weston-init.bbappend` — installs the alternate
  renderer weston.ini variants (`pixman`, `glrender`) and the
  `weston-simple-egl` GPU-validation service (all diagnostics-only).
- `recipes-core/images/rpi5-image-xt-domd-vc4.bbappend` — adds `DEBUG_PACKAGES`
  to the DomD rootfs the shipping image is built from.
- `recipes-core/images/core-image-minimal.bbappend` +
  `recipes-graphics/images/core-image-weston.bbappend` — wiring for hand-built
  debug images, for bisecting a problem down to a plain poky image.

### How to use the DomD tools

Add this layer to `bblayers.conf` and rebuild the DomD image; `xt-vram-tools` and
`xt-cluster-shm` then land in the rootfs. On the board:

```sh
domd-gpu-firstcheck.sh                 # one-shot GPU/display state report
dump-cma.sh /tmp/cma.bin               # dump the CMA region (base probed at run time)
analyze-vram.py /tmp/cma.bin           # look for framebuffer-shaped content in it
verify-stripe-bug.sh                   # modetest colour bars vs weston, to tell an
                                       # HVS/IOMMU fault from a renderer fault
measure-weston-load.sh                 # weston CPU/RSS over time
systemctl start xt-cluster-shm         # GPU-free cluster stand-in on HDMI-A-1
```

`dump-cma.sh` reads `/dev/mem`, which works because the DomD kernel is built with
`CONFIG_STRICT_DEVMEM` unset. `verify-stripe-bug.sh` probes the connector, CRTC and
mode at run time; set `CONN_MODE=<conn>@<crtc>:<WxH>` to override.

DomU tools:
- `recipes-extended/sdl2-demo` — SDL2 OpenGL-ES validation app.
- `recipes-extended/domu-network` — DomU eth0 network + ssh debug drop-in.
- `recipes-core/images-domu/rpi5-image-domu-gfx.bb` — full DomU Wayland+Mesa
  graphics image (the shipping DomU uses only the harvested kernel Image).
- `recipes-core/images-domu/*` + `recipes-graphics/images-domu/core-image-weston.bbappend`
  — DomU debug-image wiring, kept in an `images-domu/` subdir purely for
  organisation (both the DomD and DomU debug images are opt-in and never built in
  the same run; note bitbake applies a `.bbappend` to its target recipe regardless
  of the subdirectory it lives in).

Host / SD tooling:
- `scripts/p4-tool.sh` — inspect / factory-reinit the DomA (AAOS) SD partition 4.
