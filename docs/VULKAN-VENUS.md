# Vulkan in the guests: Venus enablement and verification

> **Documentation map** — [`README.md`](../README.md) build and run |
> [`docs/BUILD.md`](BUILD.md) build details |
> [`docs/DESIGN.md`](DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when it does not work |
> [`docs/VULKAN-VENUS.md`](VULKAN-VENUS.md) Vulkan in the guests

Status: **this is the default configuration.** A plain `./build.sh` (moulin
`--GPU vulkan`) builds the DomD side described here; the guests need `-u` / `-a`
as usual.

`./build.sh --gpu=gl` (moulin `--GPU gl`) rebuilds the pre-Venus OpenGL stack the
tree used to ship, which is also what every measurement below is compared against.
This is the authoritative list of what that means:

| | `--gpu=vulkan` (default) | `--gpu=gl` |
|---|---|---|
| DomD device model | qemu 11.1.2 on both boards (section 4); the fork's 10.0.2-xt (`meta-xt-qemu`, built with `gtk+` and `pixman`) remains selectable | qemu 7.0.0-xt, with its six 7.0.0-only device-model patches |
| DomD rootfs | `mesa-vulkan-drivers`, `vulkan-loader` and `vulkan-tools` installed explicitly | no `vulkan-tools`; the V3DV ICD and the loader arrive only through weston's Vulkan renderer |
| DomD virglrenderer | venus + `render-server` + `minigbm_allocation`, 9 product patches on 1.3.0 on both boards (0009 is upstream there, 0017 is replaced by its 1.3.0 port, and 0024 is 1.3.0's only); 9 on 1.2.0 when 10.0.2 is selected; DomD's weston is 16.0.0 instead of poky's 15.0.0 | oe-core's stock build, no venus, no patches |
| guest cfg (`domu.cfg`/`doma.cfg`) | `hostmem=256M,blob=true,venus=true` on `virtio-gpu-gl-pci`; in `doma.cfg` the Venus `qemu_envs` (`VIRGL_EXTERNAL_GBM`, `V3DV_MAX_BO_CACHE_SIZE`, `VKR_DEVICE_HEAP_MIB`, `VKR_RING_IDLE_WAIT_MS`, `VKR_RING_RELAX`), `VKR_RING_IDLE_WAIT_MS` and `VKR_RING_RELAX` in `domu.cfg`, and `VIRGL_EXTERNAL_GBM` there with DomU overlay planes; the options and renames only the qemu 10 and 11 device models take | `VKR_RING_IDLE_WAIT_MS` and `VKR_RING_RELAX` in `domu.cfg` (unused without venus); none of the others |
| Xen + libxl | `4.22-0007/0008/0009/0010` (p2m direction, 0xc0000000/768 MiB window, 256 MiB slices, one SPI per virtio-pci slot); DomD kernel `0014` + gntdev-dmabuf | the same series without them; no `0014`, no gntdev-dmabuf |
| rpi4 4 GiB SKU memory | DomD 1440 MiB / DomA 2048 MiB | DomD 1056 MiB / DomA 2560 MiB (the 8 GiB SKU and the Pi 5 are the same in both lanes) |
| AGL cluster rootfs | four conf lines + the `meta-agl-venus` layer; cluster on the Vulkan (Impeller) embedder | neither; cluster on the shipped OpenGL embedder |
| DomA hardware decode | `XT_DOMA_HWDEC` is the board yaml's `XT_DOMA_HWDEC_VULKAN`, `true` except with the Raspberry Pi 5's linux Dom0: DomA's device model gets the virtio-media decoder and the AAOS device its c2 HAL settings | `XT_DOMA_HWDEC=false`: not built, because virtio-media exists only in the qemu 10.0.2 and 11.1.2 device models |
| DomA overlay planes | `XT_DOMA_OVERLAY_PLANES` in `xt-xen-cfg-doma`: `0` (the default) to `3`, and a board may set its own; both boards set `3`. It sets both halves in `doma.cfg`, the device model's `overlay-planes=N` (qemu 10.0.2 patch `0250`, qemu 11.1.2 patch `q11-051`) and DomA's `virtio_gpu.overlay_planes=N` (DomA kernel patch `aosp-kernel-patches/common/0001`); drm_hwcomposer then puts the system bars on the overlays instead of SurfaceFlinger compositing them on the GPU | `0` whatever the variable says: qemu 7.0.0 has no `overlay-planes` |
| DomU overlay planes | `XT_DOMU_OVERLAY_PLANES` in `xt-xen-cfg-domu`: `0` (the default) to `3`; the Raspberry Pi 5 sets `1`. The same two halves as DomA's (`overlay-planes=N`, and DomU's `virtio_gpu.overlay_planes=N` from `linux-virtio-armv8`'s `0002`), plus `VIRGL_EXTERNAL_GBM=1`, the gbm device a linear scanout buffer needs on the host to be a linear gbm bo (virglrenderer 1.3.0). With it, xdg-cluster-receiver's window goes on the overlay (section 7f, 2026-10-15) | none: the qemu 7 device model has no overlay planes |

Two things `--gpu=gl` deliberately does NOT revert. **DomD's mesa is 26.2.4 in both
lanes** -- the pin is a v3dv submit-path fix that both lanes' weston benefits from
(section 7e), so splitting the host GL/Vulkan driver by lane would mean shipping two
of them for no gain. And **DomA's AOSP-side Vulkan settings do not follow the
lane**: this tree applies them to the AOSP tree whatever `--gpu` says (section 6),
so a DomA built here still gets the Venus ICD on a `--gpu=gl` DomD, whose device
model has no venus (both products composite with GL). That pairing has not been
measured; a pre-Venus DomA needs those settings reverted. (Its hardware-decode settings do follow the lane,
through `XT_DOMA_HWDEC`, as the table says.)

The diagnostics this work was done with are one more switch away,
`./build.sh --devel`, and are in `meta-rpi-sodev-devel`. One of them is a
hypervisor patch numbered `4.22-0009` that makes Xen's injected-abort paths
print on a release build. It is not the libxl `4.22-0009` of section 7a; the two
series are numbered independently.

**Current state (2026-09-24).** This file is a working record kept in the order the
work happened, so several sections state a conclusion that a later section
overturns. Those are marked *Superseded* where they sit. The standing summary:

1. Venus works in **DomU** on hardware (RPi5 2026-08-31, RPi4 2026-09-12): real
   guest memory, no trapping, the AGL Flutter cluster at 60 fps.
2. Venus works in **DomA**: full-Vulkan AAOS on the RPi4, 2026-09-12.
3. **Defect A** (venus suballocation) is fixed by `meta-agl-venus`' mesa `0002`.
4. **Defect B** (no EGLDisplay for virglrenderer) is fixed by qemu `0117` plus
   virglrenderer `0002`; `MESA_VK_WSI_DEBUG=sw` is no longer needed and is not
   shipped. The defect-B subsection in section 7a opens with the pre-fix reading
   and carries the correction in a box at its top.
5. The host GEM growth that made 0117 look unusable was **Impeller**
   (flutter/flutter#183267), fixed by `meta-agl-venus`' flutter-engine `0001`;
   the image view Impeller left behind each frame on the same path is fixed by
   `0003` (2026-10-20).
6. The **fallback in section 8 is not the current plan** -- it is what the state
   of the board was before the p2m work.
7. On the RPi5, DomA was verified compositing with Vulkan (SkiaVk) on 2026-09-24
   (8 GB SKU), after the p2m work; the product now composites with GL. The DomA measurements in section 7g are the
   RPi4's.

In the `gl` lane DomU (AGL-IC) and DomA (AAOS) render through virtio-gpu + virgl, which
gives them GLES/OpenGL but no Vulkan. This file is how Vulkan was handed to both guests:
what the host and the guest sides each needed, what was measured on hardware, and what
is still open.

---

## 1. Why Venus is the only candidate

- virglrenderer's DRM native context (vDRM) — the mechanism that would forward
  guest ioctls to the host GPU driver — has **no Broadcom V3D implementation**. As
  of 2026-08 the implemented native contexts are Freedreno, AMDGPU, Intel i915 and
  Asahi. RPi5 is VideoCore VII / V3D 7.1, so this path does not exist.
- That leaves **Venus**, the virtio-gpu Vulkan passthrough protocol: the guest
  loads `libvulkan_virtio.so` (Mesa's Venus ICD), the command stream is forwarded
  to the device model, and the device model replays it against the host's Vulkan
  ICD — here V3DV.
- V3DV is Khronos-conformant Vulkan 1.3 (2024-11, Mesa 24.3), but that is about
  *native* use. Whether it can be re-exported to a guest through Venus depends on
  the host extensions in section 3.
- `gfxstream` is recorded as an alternative but is not pursued: its track record is
  ChromeOS/x86-centric and no ARM/V3DV evidence was found.

## 2. What this tree already builds

Measured against the pinned revisions (wrynose oe-core, meta-raspberrypi master,
see [`rpi5-sodev.yaml`](../rpi5-sodev.yaml)). `vulkan` is in wrynose's
`DISTRO_FEATURES_DEFAULTS` and neither product yaml removes it — verified by
evaluating the generated `moulin.conf` lines against `bb.data_smart`, which yields
`... opengl pam pci pulseaudio seccomp vulkan wayland ... xen` for the DomD build.
Two of the four host-side prerequisites came for free, one was actively turned off,
and one was a hard blocker; the table is written from that starting point, and the
"State" column says where each one stands now:

| Component | Version | State | Why |
|---|---|---|---|
| mesa | 26.0.5 in oe-core; **this series pins DomD's to 26.2.4** (ungated, so both lanes) -- section 7e | **V3DV already built AND already installed** | meta-raspberrypi `mesa.bbappend` appends `vulkan broadcom` for `rpi`, so `VULKAN_DRIVERS` gains `broadcom` → `libvulkan_broadcom.so` in `mesa-vulkan-drivers`. And it is already in the shipping rootfs: weston's `vulkan-renderer.so` links `libvulkan.so.1`, so weston RDEPENDS on vulkan-loader, whose `RRECOMMENDS virtual-vulkan-icd` resolves to `mesa-vulkan-drivers` |
| weston | 15.0.0 (oe-core); a 16.0.0 recipe in `meta-xt-driver-domain` is used only if `PREFERRED_VERSION_weston` selects it (both board yamls pin `15.%`, and both boards' `vulkan` lanes select `16.%`) | **Vulkan renderer already built** | `PACKAGECONFIG` filters `vulkan` from `DISTRO_FEATURES` → `-Drenderer-vulkan=true` |
| virglrenderer | 1.2.0 (oe-core); a 1.3.0 recipe in `meta-xt-driver-domain` is used only if `PREFERRED_VERSION_virglrenderer` selects it (both board yamls pin `1.2.%`, and both boards' `vulkan` lanes select `1.3.%`) | **venus and the render server on in the default lane** | oe-core's `PACKAGECONFIG` enables venus from `vulkan`. The tree used to cancel that (`PACKAGECONFIG:remove:pn-virglrenderer = "venus"`) to match the pure-GL known-working image, and a bitbake `:remove` cannot be undone by a later `:append` or by a hard assignment — so the removal is variable-gated (`XT_VIRGL_VENUS_REMOVE`), empty by default and set to `venus` only by `--gpu=gl`. The default lane also turns on the `render-server` PACKAGECONFIG: qemu >= 9.2 passes `VIRGL_RENDERER_RENDER_SERVER` unconditionally with venus, and oe-core defaults that option off. On 1.3.0 a guest resource gets a GBM dma-buf only with `VIRGL_GBM_LAYOUT_ENABLE`, which a Venus-compositing DomA needs and which costs the GL path; the DomD qemu wrapper exports it for DomA's device model when `/etc/qemu-gbm-layout` exists, and the image does not create that file. (`0024` adds one exception: a linear scanout buffer gets a linear GBM bo whenever the device model has a gbm device, `VIRGL_EXTERNAL_GBM=1`.) |
| qemu | **11.1.2** (`qemu_11.1.2.bb`) on both boards, **10.0.2** (xen-troops fork, `meta-xt-qemu`) selectable; **7.0.0** with `--gpu=gl` | was the blocker | `virtio-gpu-gl` grew `venus=` in QEMU **9.2.0**, so the 7.0.0 the tree used to ship has no such property. Raising the device model is what this work turned into the default |

So the host-side work was: raise QEMU, keep virglrenderer's venus backend, install
the ICD into the DomD rootfs, and pass the device-model options. That is what the
default `--GPU vulkan` does, and what `--gpu=gl` undoes.

The weston and virglrenderer pins (`PREFERRED_VERSION_weston = "15.%"`,
`PREFERRED_VERSION_virglrenderer = "1.2.%"`, in the DomD conf of both board yamls)
are what keep poky's versions: `meta-xt-driver-domain` is the higher-priority layer,
so without a pin its newer recipe would win, and `DEFAULT_PREFERENCE` cannot hand the
choice back to poky. A board that wants the newer one sets the variable again, as
both boards' `vulkan` lanes do (weston 16.0.0 and virglrenderer 1.3.0, with
qemu 11.1.2 built against that virglrenderer; a qemu built against 1.3.0 does not
start with the 1.2 library). On virglrenderer 1.3.0 a Venus-compositing DomA needs
`/etc/qemu-gbm-layout` in DomD (the table above), which costs GL compositing. Both
products composite with GL (`debug.renderengine.backend=skiaglthreaded`,
`debug.hwui.renderer=skiagl` in each AAOS device), so the image does not create the
file.

`CONFIG_UDMABUF` needs nothing: the Raspberry Pi kernel's own
`arch/arm64/configs/bcm2712_defconfig` already sets `CONFIG_UDMABUF=y` (line 1489
at 6.18.33), and that is the defconfig kernel-yocto starts from for
`raspberrypi5`. The same is true of `bcm2711_defconfig` for `raspberrypi4-64` --
both verified by reading the generated `.config`, in both lanes -- which matters
because qemu `0121` needs `/dev/udmabuf` on whichever board runs DomD. An
earlier version of this series carried a `venus-udmabuf.cfg` fragment for it; the
build showed it was redundant and it was dropped.

What is **not** available in the pinned layers, and therefore not used by the
procedure below:

- **`vkcube`** — oe-core's `vulkan-tools` recipe configures `-DBUILD_CUBE=OFF`.
  `vulkaninfo` is packaged; `vkcube` is not built at all.
- **`vkmark`** — no recipe in any pinned layer (only in the third-party
  `meta-vulkan`, last branched at honister). Treat it as a manual, out-of-tree
  tool if a benchmark number is needed.

The drawing checks below use weston's own simple clients instead, which are built
(`SIMPLECLIENTS = "all"`). They are run as **clients against the compositor that is
already up**, which needs no display change and no second compositor. A
Vulkan-*rendered* compositor works too, but only once virglrenderer is built with
`minigbm_allocation` -- see section 5.

## 2a. What has been verified, and what has not

The series was built, not just written. On a PC (the `sodev-builder-rpi` build
container, wrynose oe-core, `MACHINE=raspberrypi5`), with `GPU=vulkan`:

- the whole metadata parses in both lanes — 3350 recipes, 0 errors;
- qemu 10.0.2-xt fetches, patches, configures, compiles and packages;
- `rpi5-image-xt-domd-v4h` — the image the board boots — assembles;
- the `gl` lane's rootfs already contains the V3DV ICD and the loader (see the mesa
  row in section 2) — the only package the Venus lane genuinely adds to the image is
  `vulkan-tools`, i.e. `vulkaninfo`, verified absent from the `gl` rootfs and present
  in the Venus one;
- the built rootfs contains `/usr/lib/libvulkan_broadcom.so` (V3DV) with its
  `/usr/share/vulkan/icd.d/broadcom_icd.json` manifest, `libvulkan.so.1` and
  `/usr/bin/vulkaninfo`; the manifest records `mesa-vulkan-drivers 26.0.5`
  (that build predates the 26.2.x pin of section 7e; both lanes resolve 26.2.4
  now, and nothing in this list depends on the version),
  `libvulkan1 1.4.341.0`, `vulkan-tools 1.4.341.0`, `virglrenderer 1.2.0`;
- the shipped `libvirglrenderer.so.1` really has the venus backend compiled in
  (`venus_protocol`, `vn_dispatch_command`) and links `libvulkan.so.1`;
- the shipped `qemu-system-aarch64.bin` really carries the `venus`, `blob` and
  `hostmem` device properties and links `libvirglrenderer.so.1`;
- `domu.cfg` installs with `hostmem=256M,blob=true,venus=true` on the
  `virtio-gpu-gl-pci` line, and with neither the placeholder nor those options in
  the `gl` lane. The `gl` lane's files carry none of the Venus options: with
  `XT_VENUS_GPU_OPTS` empty the recipe's substitution deletes the block of
  comments that documents the token and replaces the token with nothing, and the
  qemu-10 fixups sit behind a `7.*` case that does nothing;
- the `gl` lane still builds the shipping image with qemu 7.0.0 and its six
  device-model patches applied, and its rootfs has no venus anywhere: the qemu
  binary is 7.0.0 without the property, and `libvirglrenderer.so.1` has no
  `venus_protocol`;
- on the guest side, mesa for `virtio-armv8-xt` builds the Venus ICD
  (`libvulkan_virtio.so` + `virtio_icd.json`, `VULKAN_DRIVERS=",gfxstream,virtio"`)
  and the domu build is in the Venus lane. The opt-in devel DomU *image* was not
  parsed: `meta-rpi-sodev-devel` declares `LAYERDEPENDS` on `xt-driver-domain`, so
  checking that image needs the hand-assembled layer set its README describes
  rather than the moulin-generated DomU build dir.

That last point is about the in-tree DomU built by the `domu` moulin component.
The **AGL cluster rootfs that ships on SD p3 is a separate build**: its Yocto
series cannot produce the Venus ICD without four further conf lines and a layer,
which `build.sh --gpu=vulkan` adds. Section 5 lists them with their sources and
records the build and the boot of that image.

So the host-side chain is proven to *exist* end to end: qemu with the venus
property → virglrenderer with venus → the Vulkan loader → V3DV.

**And on the Raspberry Pi 4** (`rpi4-sodev.yaml`, `MACHINE=raspberrypi4-64`, in a
separate workspace — see the board note in that file for why it has to be
separate): the same ten checks pass. 3357 recipes parse with 0 errors, qemu
10.0.2-xt configures, compiles and packages for `cortexa72-nocrypto`, `domu.cfg`
installs with the venus options, and `rpi5-image-xt-domd-v4h` assembles carrying
`libvulkan_broadcom.so` + its ICD manifest, `vulkaninfo`, `weston-simple-vulkan`,
a virglrenderer with `venus_protocol`, and a qemu binary with the `venus`, `blob`
and `hostmem` properties. So the lane is not Pi 5-only in practice, and the Pi 4
configuration meets the "verified by build" bar the product yaml sets for it.

Re-checked at the current head of the series, since everything from the p2m work
onwards landed after that build: the Pi 4 Venus lane's conf still generates as
intended (`XT_VENUS_GPU_OPTS`, `DISTRO_FEATURES:append = " venus"`, and
`PREFERRED_VERSION_qemu` appended last so 10.0.2 wins over the lane default), 3357
recipes parse with 0 errors on `raspberrypi4-64`, `xen`, `xen-tools` and `qemu` all
complete `do_patch` -- which is what actually exercises the patch files the Pi 4
bbappends list, including the hypervisor half of the p2m fix -- and a dry run of
`rpi5-image-xt-domd-v4h` resolves all 6185 tasks. Not a rebuilt image and not
hardware; what it rules out is the failure mode that matters for a second board,
which is a file or a variable that only ever existed for the Pi 5.

**Beyond the build, on a PC:** the Venus path was also run — an emulated arm64
guest on an x86 host with an Intel iGPU. That guest enumerates the host GPU through
Venus, a Vulkan client draws on it for 35 s with the compositor surviving, and a
frame captured mid-draw shows the triangle correctly composited. Section 5a carries
the fps/CPU/GPU numbers with the reasons **no performance figure there transfers to
the board** — emulated guest, Intel host driver rather than V3DV, no Xen. The
rendering-correctness result is the part that stands on its own. Two bugs in this
series were found that way rather than on the board: the missing `render-server`
PACKAGECONFIG, and the gate script's use of a headless backend this tree's weston
does not build.

> **Superseded (sections 7a and 7g).** Both of the questions below were answered on
> hardware afterwards: V3DV does serve Venus, and the Xen path works with this
> series' p2m patches. Kept because the reasoning is why the three-stage plan in
> section 5 exists.

What was still **not** verified at that point, and could not be on a PC:

- **V3DV as the Venus host driver.** Everything above used Intel's Vulkan driver on
  the host side. Phase 1 — does V3DV advertise `VK_EXT_image_drm_format_modifier`
  and the host-visible memory Venus needs — is unchanged as a hardware question,
  and it is the single most likely place for this to stop.
- **The Xen path.** The PC runs plain qemu with no Xen in it. The grant DMA /
  no-IOMMU / DomD-device-model question in section 5 is untouched by any of this,
  which is why section 5's three-stage isolation exists.

`sodev-venus-gate.sh` exists to answer those on the board.

## 3. Phase 1 — does host V3DV meet the Venus requirements

Venus bridges to any host ICD through the standard loader, but it needs:

- **`VK_EXT_image_drm_format_modifier`** — mandatory. Venus does not work on a
  driver that lacks it.
- **`/dev/udmabuf`** (`CONFIG_UDMABUF`) on the host, for blob resources. Already
  satisfied here — see section 2 — but still worth checking at run time, because
  the node's absence with the option set means a devtmpfs/permission problem
  rather than a config one.

Run on DomD, which owns the real GPU. `xt-venus-check` (opt-in
`meta-rpi-sodev-devel` layer) installs a script that performs the whole gate:

```sh
sodev-venus-gate.sh            # phases 0-3, verdict + exit code
sodev-venus-gate.sh --phase 1  # host V3DV requirements only
```

Equivalent by hand:

```sh
export XDG_RUNTIME_DIR=/run WAYLAND_DISPLAY=wayland-0   # or the WSI probe finds nothing
vulkaninfo --summary | grep -iE 'driverName|apiVersion'
vulkaninfo | grep -i drm_format_modifier
ls -l /dev/udmabuf
zcat /proc/config.gz 2>/dev/null | grep UDMABUF || grep UDMABUF /boot/config-$(uname -r)
```

Verdict:

- `VK_EXT_image_drm_format_modifier` present → go to phase 2.
- absent → go straight to **phase 5 (fallback)**, and raise the upstream request
  (Mesa/Igalia) as a separate item. Do not start the guest integration.

## 4. Phase 2 — the QEMU move

`GPU=vulkan` switches `PREFERRED_VERSION_qemu` from `7.0.0` to `11.1.2` on both
boards (below). The first move was to `10.0.2`, built from the xen-troops fork branch
`v10.0.2-xt` (`meta-xt-qemu/recipes-qemu/qemu/qemu_10.0.2.bb`), which stays
selectable and is what this section's 10.0.2 measurements are of. The fork also carries
`v11.0.2-xt`, which is the fallback if a later recipe-body bump makes 10.0.2
sources too old (see the skew note below).

A second device model, qemu 11.1.2 (`qemu_11.1.2.bb`: the upstream release
tarball with the fork's v10.0.2-xt commits and this layer's 10.0.2 series ported
onto it as `q11-NNN` patches), is both boards' `vulkan`-lane device model, with
weston 16.0.0 and virglrenderer 1.3.0. Each board yaml selects it by setting
`PREFERRED_VERSION_qemu` to `"11.1.2"` on the `vulkan` lane's DomD conf line and,
with `--dom0=linux`, `XT_DOM0_QEMU_VERSION` to the same value: that
Dom0 writes the guest cfgs, in the syntax of the qemu it names. `doma.cfg`'s
Bluetooth chardev then gets `reconnect-ms=1000` instead of `reconnect=1`, which
qemu 11.1.2 no longer has. What only qemu 11.1.2 acts on:

- `XT_DOMA_PLANE_SCALING` (`xt-xen-cfg-doma`, `0` by default). `1` gives DomA
  `virtio_gpu.plane_scaling=1` (DomA kernel patch `aosp-kernel-patches/common/0002`),
  so the primary plane may be positioned and scaled through the device's
  `SET_PRIMARY_RECT` (`q11-064`). It needs `XT_DOMA_OVERLAY_PLANES` > 0, and
  `do_install` refuses it with any other device model. Both boards set `1` with
  qemu 11.
- The `/run/qemu-*` display-path switches `q11-063`, `q11-066`, `q11-071`, `q11-081`
  and `q11-082` read, created at boot by each board layer's `xt-qemu-display-toggles`:
  nine on the Raspberry Pi 4 (its ISP and SAND direct scanout among them), ten on the
  Raspberry Pi 5 (the plane handoff, `media-sg-rw`, `fb-invalidate`, the SAND direct
  scanout of the decoder mode's buffers, `q11-071`, and `plane-sand` and `sand-scaled`,
  `q11-081`/`q11-082`, which give a plane the decoder's buffer and offer a frame scaled
  for host-max-width too; only the bcm2835 ISP's `media-isp` is left out, the Pi 5 has
  none).
- `RPI5_DOMA_HOST_SAND` (`meta-xt-rpi5`'s `xt-xen-cfg-doma` append; `1` with qemu
  11.1.2, `0` otherwise): `host-sand=N` on DomA's virtio-media device, so the decoder
  mode's HEVC frames reach the guest on the GPU (`q11-069`); the append refuses a
  non-zero value with any other qemu.
- `RPI5_DOMA_H264` (the same append; `1` with qemu 11.1.2, `0` otherwise):
  `decoder=hevc+h264`, so DomA's H.264 is decoded by libavcodec in software in DomD
  (`q11-072` to `q11-074`) instead of by DomA's own software decoder, on two frame
  threads (`q11-079`) and straight into dma-bufs the GPU reads, without the NV12
  conversion and copy (`q11-080`); the append refuses `1` with any other qemu. A
  stream the decoder mode cannot take is reported to DomA through V4L2 (`q11-077`),
  and with overlay planes the qemu window under them is covered (`q11-078`).
- `RPI5_DOMA_HWDEC_MAX_W` (the same append; DomA's display width from
  `RPI5_DOMA_GPU_RES` with qemu 11.1.2, `0` otherwise): `host-max-width=N`, so a
  stream wider than the display, such as 4K HEVC, reaches DomA scaled down to it by
  the decoder mode's GPU conversion (`q11-076`); the append refuses a non-zero value
  with any other qemu.
- `QEMU_XEN_MAPCACHE_MAX_MB`, which the DomD qemu wrapper exports for every
  device model it starts: it caps the foreign mapcache (`q11-053`) at
  `XT_QEMU_MAPCACHE_MAX_MB` from the DomD image recipe: 4608 on a Raspberry Pi 5,
  with either SKU (DomD's extended regions, the host RAM not given to DomD, are
  about 12 GB with `BOARD_RAM=16g` and 4.9 GB with `8g`; the recipe records the 8 GB
  memory map's measurement), 1024 otherwise. qemu 10.0.2 ignores the variable.
- Two files in DomD switch qemu 11 features, each off unless it exists:
  `/etc/qemu-ioreq-thread` (the wrapper exports `QEMU_XEN_IOREQ_THREAD=1`:
  virtio-pci notify writes are acknowledged, and ISR reads answered, on a dedicated
  ioreq thread, `q11-052`/`q11-054`), which the DomD image creates, so it is on
  unless removed; and `/etc/qemu-lat-diag` (`QEMU_LAT_DIAG=1`: display-command
  latencies are logged, `q11-057`/`q11-058`), which nothing creates.

This matters for scheduling: the fork *does* maintain post-9.2 branches, so the
Xen ARM device-model work does not have to be abandoned to get Venus. It is a
larger jump than the 7.0 -> 8.2 move a virtio-snd update alone would need, and
it makes that move unnecessary.

What the move costs, and what it no longer costs — this is the shipping
configuration now, and the six 7.0.0-only patches are why it was not:

- The six device-model patches in
  `meta-xt-driver-domain/recipes-qemu/qemu/qemu_%.bbappend` are all written
  against 7.0.0 sources and are version-gated off for 10.0.2. All six are now
  accounted for, which is what allowed the default to move:
  - `0111` (virtio-tablet `BTN_TOUCH`) was the one with a user-visible consequence
    -- Android classifies an ABS_X/ABS_Y device as a touchscreen only when it also
    reports `BTN_TOUCH`, so without it DomA got no touch input at all -- and it is
    **rebased as `meta-xt-qemu`'s `0118`**. The 10.0.2 form is much smaller than the
    7.0.0 one: upstream already has `touch` in the `InputButton` enum and
    `[INPUT_BUTTON_TOUCH] = BTN_TOUCH` in `keymap_button`, and because the tablet
    synthesises its advertised `EV_KEY` bitmap from that whole array
    (`virtio_input_extend_config()` in `virtio_tablet_init()`;
    `virtio_tablet_config_v1/v2` declare no `EV_KEY` at all) the device **already
    advertises** `BTN_TOUCH` -- only the send side was missing, where a left press
    goes out as `BTN_LEFT`.
  - `0110` (virtio-pci ISR IOREQ range) is **rebased as `0120`**, against the fork's
    reworked Xen ioreq code.
  - `0112` (vTPM `GUEST_TPM_BASE` guard) is **moot**: 10.0.2 has no
    `hw/arm/xen_arm.c` at all -- the Arm Xen machine is `hw/arm/xen-pvh.c` on the
    `xen-pvh-common` code -- and `GUEST_TPM_BASE` appears nowhere in the tree.
  - `0113` (`struct sched_attr` redefinition) is **fixed upstream**: 10.0.2's own
    `linux-user/syscall.c` already wraps the local definition in
    `#ifndef SCHED_ATTR_SIZE_VER0`.
  - `0101` (RESUME emitted with no QMP monitor) and `0103` (deferred autostart
    `vm_start`) guard a pre-main-loop death in 7.0.0's `softmmu/vl.c`. The code moved
    to `system/vl.c`; both are forward-ported, as `meta-xt-qemu`'s `0201` for 10.0.2
    and `q11-021` for 11.1.2 (see `meta-xt-driver-domain`'s `qemu_%.bbappend`).
- `qemu_10.0.2.bb` reuses oe-core's `qemu_10.2.0.bb` recipe body against 10.0.2
  sources. The two skew risks were checked against the real qemu trees rather than
  assumed: the configure option sets differ only by `igvm`/`mshv`/`passt`/
  `valgrind`/`gdb` (added in 10.2.0) and `avx2`/`avx512bw` (removed), none of which
  the recipe body passes, so **configure is not affected**; the license files *do*
  differ, so `LIC_FILES_CHKSUM` is overridden in the recipe with the md5s measured
  at the pinned SRCREV. If a later SRCREV moves further, `v11.0.2-xt` is the other
  fork branch (11.0.2 > 10.2.0 makes the recipe body older than the sources, which
  qemu's configure tolerates).
- The `venus` device property, and its requirement that `blob` and `hostmem` be
  set too, were confirmed in the fork's own `hw/display/virtio-gpu{,-gl}.c` at the
  pinned SRCREV. Venus additionally needs `VIRGL_VERSION_MAJOR >= 1`, which
  oe-core's virglrenderer 1.2.0 satisfies.
- Regression scope after the move: virtio-snd, the mixed virtio-mmio/virtio-pci
  layout, and the IOREQ/device-model wiring all need re-checking on hardware.

## 5. Phase 3 — Venus bring-up

### Build

```sh
./build.sh            # + the usual -u/-a as needed
```

That gates on `venus` in `DISTRO_FEATURES` and turns on:

- qemu 11.1.2 (with weston 16.0.0 and virglrenderer 1.3.0) instead of 7.0.0-xt;
- virglrenderer's venus backend, by making the domd conf's
  `PACKAGECONFIG:remove:pn-virglrenderer` empty (`XT_VIRGL_VENUS_REMOVE`);
- virglrenderer's **render server** (`PACKAGECONFIG:append:pn-virglrenderer =
  " render-server"`), which is not optional: qemu passes
  `VIRGL_RENDERER_VENUS | VIRGL_RENDERER_RENDER_SERVER` together
  (`hw/display/virtio-gpu-virgl.c`), and without `/usr/libexec/virgl_render_server`
  the venus context is never created -- the guest's first blob allocation comes back
  `VIRTIO_GPU_RESP_ERR_UNSPEC` and `vkCreateInstance` fails with
  `ERROR_OUT_OF_HOST_MEMORY`. This was found on a PC, not on the board (see the
  three-stage plan below);
- `mesa-vulkan-drivers vulkan-loader vulkan-tools` in the DomD rootfs (the V3DV
  ICD, the loader, `vulkaninfo`) and in `rpi5-image-domu-gfx` (the guest's Venus
  ICD, `libvulkan_virtio.so`);
- the device-model options below in `domu.cfg` / `doma.cfg`.

### Device-model options

`XT_VENUS_GPU_OPTS` is substituted into the `virtio-gpu-gl-pci` line of both guest
configs by `xt-xen-cfg-domu` / `xt-xen-cfg-doma`. With `GPU=vulkan`:

```
-device virtio-gpu-gl-pci,...,hostmem=256M,blob=true,venus=true
```

(`256M` is the value that ships, as ONE value for both guest configs -- see section
5c. The `hostmem=1G` that appears in the PC-rig command lines below is that rig's
value, not the product's.)

With `GPU=gl` it substitutes to the empty string, so the installed configs carry
none of the Venus options.

### Checks, host side first

```sh
# is the QEMU actually a Venus-capable build?
qemu-system-aarch64 -device virtio-gpu-gl,help | grep venus

# native Vulkan on DomD (no guest involved): weston 15's Vulkan renderer
weston --renderer=vulkan          # expect a V3DV device in the startup log
weston-simple-dmabuf-feedback     # or another built simple client
```

Run that `weston` line only on a board whose cockpit compositor is stopped: a
second DRM-backend weston fights the running one for the device. On a live system
use `sodev-venus-gate.sh --phase 3` instead, which runs
`weston-simple-dmabuf-vulkan` as a **client against the running compositor**. It
does not start a second weston: this tree's weston has no headless backend (see
section 5's stage-0 findings), and a Vulkan *client* is the more robust thing to gate
on -- it exercises the same host path without depending on the compositor's own
renderer configuration.

### Checks, guest side

```sh
vulkaninfo --summary              # expect driverName = venus / a virtio device
weston-simple-vulkan              # or weston-simple-dmabuf-vulkan
```

Both of those clients are in the built image — verified, along with `vkcube`'s
absence, in the rootfs of `rpi5-image-xt-domd-v4h`.

### The AGL guest rootfs needs four conf lines and a layer, not one change

The in-tree DomU debug image (`rpi5-image-domu-gfx`, devel layer) installs the
guest ICD, and `GPU=vulkan` covers it. **The AGL cluster rootfs that
actually ships on SD p3 does not**: `build.sh` builds it from the AGL manifest in
its own container, on its own Yocto series, and that build has no idea this lane
exists. Adding `mesa-vulkan-drivers` to it — the obvious move, and what an earlier
version of this section said — does not work and in fact breaks the build. Checked
against the pinned revisions rather than assumed:

| Fact | Source |
|---|---|
| the AGL guest is **poky scarthgap** (pinned SHA `72983ac3`), meta-agl `trout-sodev` | `AGL-repo` manifest `default.xml` for that branch |
| AGL's `DISTRO_FEATURES` has **no `vulkan`** — `usrmerge largefile opengl wayland pam bluetooth bluez5 3g polkit` | `meta-agl-core/conf/distro/poky-agl.conf:50` (`AGL_DEFAULT_DISTRO_FEATURES`) |
| so `vulkan-loader` / `vulkan-tools` are **skipped** (`REQUIRED_DISTRO_FEATURES = "vulkan"`), and putting them in `IMAGE_INSTALL` fails the build | oe-core scarthgap `vulkan-loader_1.3.275.0.bb` |
| and even with `vulkan` added, scarthgap's mesa recipe **never puts `virtio` in `VULKAN_DRIVERS`** (only intel/amd on x86, freedreno, broadcom, swrast, imagination), so no `libvulkan_virtio.so` is produced | oe-core scarthgap `mesa.inc:108-117` |
| mesa itself is not the obstacle: 24.0.7 accepts `-Dvulkan-drivers=virtio` and builds `libvulkan_virtio.so` + `virtio_icd.<arch>.json` | mesa `mesa-24.0.7` `meson_options.txt:218-227`, `src/virtio/vulkan/meson.build:18-26` |

So the AGL guest needs these in its build (`agl/build/conf/local.conf`, which is
where `build.sh` already appends `DL_DIR`/`SSTATE_DIR`):

```
DISTRO_FEATURES:append = " vulkan"
VULKAN_DRIVERS:append:pn-mesa = ",virtio"
IMAGE_INSTALL:append = " mesa-vulkan-drivers vulkan-loader vulkan-tools"
IMAGE_INSTALL:append = " flutter-auto-vulkan flutter-cluster-dashboard-conf-vulkan"
```

The fourth line is the cluster's own half (section 7b): the Vulkan embedder binary
and the systemd drop-in that makes the shipped unit run it.

**`build.sh --gpu=vulkan` now applies all four, and they are verified by building.** The
DomU(AGL) step writes them into `conf/local.conf` after the cache paths, so they land
last in the file and win over aglsetup's defaults too. They are handed to the
container as a file rather than a shell variable: the `in_docker` command string is
double-quoted, so lines containing double quotes and newlines cannot survive that
round trip.

Built on this branch (`trout-sodev`, poky scarthgap `72983ac391`, mesa 24.0.7) with
`bitbake mesa vulkan-loader vulkan-tools` — 1799 tasks attempted, all succeeded:

| check | result |
|---|---|
| `vulkan` reaches `DISTRO_FEATURES` | yes, asserted from `bitbake -e mesa` |
| `VULKAN_DRIVERS` | `",virtio"`, and `do_configure` really gets `-Dvulkan-drivers=virtio` |
| the ICD is built and packaged | `packages-split/mesa-vulkan-drivers/usr/lib/libvulkan_virtio.so` |
| its manifest is packaged with it | `.../usr/share/vulkan/icd.d/virtio_icd.aarch64.json` |
| the loader's DISTRO_FEATURES gate is lifted | `vulkan-loader/.../usr/lib/libvulkan.so.1` builds |
| `vulkaninfo` is available in the guest | `vulkan-tools/.../usr/bin/vulkaninfo` builds |

Those builds did not cover the full `agl-cluster-demo-flutter-guest` image,
which is the only thing that exercises the `IMAGE_INSTALL` line and the blast
radius of the first one; the end-to-end run below does. Note that radius:
`vulkan` is a DISTRO feature, so it applies to every image this AGL build
produces, not only the cluster rootfs — which is why `--gpu=gl` removes it again
rather than the AGL build simply always carrying it.

### …and the conf lines are necessary but NOT sufficient

Running the AGL-built binaries found what reading them could not. The four artefacts
(`libvulkan_virtio.so`, `libvulkan.so.1`, `vulkaninfo`, the ICD manifest) were
injected into the arm64 test guest and run against
`virtio-gpu-gl-pci,blob=true,hostmem=1G,venus=true`, with the guest's own wrynose
stack as the control in the same boot:

```
control (guest mesa 26.0.5)   driverName = venus, driverInfo = Mesa 26.0.5,
                              deviceName = Virtio-GPU Venus (Intel(R) Graphics (RPL-S))
AGL     (mesa 24.0.7)         MESA-VIRTIO: required kernel param 5 is missing
                              MESA-VIRTIO: vn_CreateInstance: VK_ERROR_INITIALIZATION_FAILED
```

The AGL ICD loads and then fails inside Venus's own init — identically with the AGL
loader and with the guest's, so it is the ICD, not the loader. Param 5 is
`VIRTGPU_PARAM_CROSS_DEVICE` (`virtgpu_drm.h:97`), and the two Mesa versions differ
in exactly that param:

| mesa | `required_params[]` (`src/virtio/vulkan/vn_renderer_virtgpu.c`) |
|---|---|
| 24.0.7 (AGL/scarthgap) :1489 | `3D_FEATURES, CAPSET_QUERY_FIX, RESOURCE_BLOB, CROSS_DEVICE, CONTEXT_INIT` |
| 26.0.5 (sodev/wrynose) :1602 | the same minus `CROSS_DEVICE` — still queried at :1641, but as an optional capability |

The kernel reports CROSS_DEVICE only when the device model advertises
`VIRTIO_GPU_F_RESOURCE_UUID`, which qemu's virtio-gpu does not. So on the DomU kernel
the AGL rootfs runs on, a 24.0.7 Venus ICD cannot create an instance — and the
in-tree DomU works precisely because wrynose ships 26.0.5.

**So AGL needs a fourth change, and it is not a conf line.** It is now implemented and
proven: `meta-rpi-sodev/meta-agl-venus`, a layer added to the AGL build by
`build.sh --gpu=vulkan`, with one `mesa_%.bbappend` carrying a backport of the change 26.x
made. Upstream's own comment in the code it added says why:

> Cross-device feature is optional. It enables sharing dma-bufs with other virtio
> devices, like virtio-wl or virtio-video used by ChromeOS VMs. **Qemu doesn't support
> cross-device sharing.**

The backport is that change applied to 24.0.7, mirrored rather than re-invented: a
`bool supports_cross_device` on `struct virtgpu`, `CROSS_DEVICE` removed from
`required_params`, an optional `getparam` that sets the bool, and the
`VIRTGPU_BLOB_FLAG_USE_CROSS_DEVICE` blob flag gated on it — which means passing the
virtgpu into `virtgpu_bo_blob_flags()` and updating its two callers (both already have
it in scope). 22 added lines, 7 removed.

**Verified by rebuilding and rerunning**, with the same guest and the same
discriminator (the AGL binaries report Mesa 24.0.7, the guest's own report 26.0.5):

```
Vulkan Instance Version: 1.3.275
GPU0: apiVersion = 1.3.269   driverName = venus   driverInfo = Mesa 24.0.7
      deviceName = Virtio-GPU Venus (Intel(R) Graphics (RPL-S))
      deviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
GPU1: apiVersion = 1.3.269   driverName = venus   driverInfo = Mesa 24.0.7
      deviceName = Virtio-GPU Venus (llvmpipe (LLVM 20.1.2, 256 bits))
MESA-VIRTIO: debug: connected to renderer
MESA-VIRTIO: debug: VK_MESA_venus_protocol spec version 1
MESA-VIRTIO: debug: renderer instance version 1.3.275
```

So the AGL enablement is **four conf lines plus one layer** — and all of it, including
the full image, has now been built and run.

### End to end: the image builds, and the shipping rootfs brings Venus up

`bitbake agl-cluster-demo-flutter-guest` with both parts in place: **10474 tasks, 8427
from sstate, all succeeded, zero ERROR lines.** So `DISTRO_FEATURES:append = " vulkan"`
— the line whose distro-wide radius is the reason `--gpu=gl` takes it back out again
— breaks nothing else in that build's image. Output rootfs: 1.33 GB.

`IMAGE_INSTALL` delivered, read straight out of the ext4 before booting:
`/usr/lib/libvulkan_virtio.so` (1251920 bytes, byte-identical in size to the patched
driver), `/usr/lib/libvulkan.so.1`, `/usr/bin/vulkaninfo`,
`/usr/share/vulkan/icd.d/virtio_icd.aarch64.json`.

Then the image itself was booted on
`virtio-gpu-gl-pci,blob=true,hostmem=1G,venus=true` and ran its own vulkaninfo — not
injected binaries in a test guest, the shipping rootfs:

```
ID=poky-agl   NAME="Automotive Grade Linux"   VERSION="20.0.4 (trout)"

Vulkan Instance Version: 1.3.275
GPU0: apiVersion = 1.3.269   driverName = venus   driverInfo = Mesa 24.0.7
      deviceName = Virtio-GPU Venus (Intel(R) Graphics (RPL-S))
GPU1: apiVersion = 1.3.269   driverName = venus   driverInfo = Mesa 24.0.7
      deviceName = Virtio-GPU Venus (llvmpipe (LLVM 20.1.2, 256 bits))
MESA-VIRTIO: debug: connected to renderer
MESA-VIRTIO: debug: VK_MESA_venus_protocol spec version 1
```

Only the kernel was substituted (the DomU kernel is a moulin component and is not in
this image); the rootfs is what was under test. What remains for AGL is hardware —
V3DV as the host driver rather than Intel's, and Xen rather than plain qemu.

**One practical note for anyone rebuilding this.** The image build needs either ≥200 GB
free for `agl/build/tmp`, or `INHERIT += "rm_work"` in the AGL build's `local.conf`
(with `RM_WORK_EXCLUDE += "mesa"` if the ICD's work dir is wanted afterwards). Measured
both ways: without it, tmp reached 175 GB at about half the tasks and filled a
155 GB-free filesystem; with it, tmp peaked at 36 GB. `build.sh` does not set it — it is
a property of the build host, not of Venus.

Guest kernel requirement is 5.16+ for `VIRTGPU_PARAM_RESOURCE_BLOB` /
`HOST_VISIBLE` / `CONTEXT_INIT`; the DomU kernel is 6.8, so this is satisfied.

### The residual risk, stated plainly

Venus host-visible blob resources map host memory into the guest through the
virtio-gpu PCI BAR. On this platform BCM2712 has **no IOMMU**, the guests use
grant-based virtio DMA (`CONFIG_XEN_VIRTIO_FORCE_GRANT`), and the device model
lives in DomD rather than in the domain that owns the memory. This is the most
likely place for the bring-up to stop even after phase 1 passes, and it is the reason
phase 5 stays on the table.

### Isolating the two unknowns — run it as three stages, not one

The residual risk above and the phase-1 question are *different* unknowns, and the
shipping configuration cannot tell them apart: if a Venus DomU fails to render,
"V3DV cannot do Venus" and "Xen cannot map a host-visible blob" produce the same
symptom. Splitting them costs almost nothing, because the pieces to do it are
already here.

The lever is that **the device model can be run as a plain QEMU, with no Xen in
the graphics path at all**. This is the configuration Linaro documents for booting
an Android Cuttlefish guest directly under QEMU on arm64 (`-device
virtio-gpu-gl-pci,...` + `-display egl-headless`), and the qemu this lane builds
supports it: the binary carries the plain `virt` machine and the `egl-headless`
display backend alongside the Xen bits. The DomU kernel boots there unchanged --
it already has `PCI_HOST_GENERIC`, `SERIAL_AMBA_PL011(_CONSOLE)`, `ARM_GIC_V3`,
`VIRTIO_PCI` and `DRM_VIRTIO_GPU`.

| Stage | Where | What it answers | What it removes from the equation |
|---|---|---|---|
| 0 | PC (x86 host, arm64 guest under TCG), host GPU = whatever the PC has | does *this qemu revision's* Venus path work at all, with a real host Vulkan driver | the board, V3DV, Xen |
| 1 | the board, a **plain** `-M virt` qemu run inside DomD | **does V3DV do Venus** | Xen's device model, grant DMA, the dom-to-dom path |
| 2 | the board, the real Xen DomU | the residual risk above, and nothing else | — |

Stage 1 is the one worth doing first: it is the largest unknown, it needs one
hardware session, and it needs **no SD rewrite**. The runtime difference between
the two lanes is only (a) which qemu binary runs and (b) the device-model options
in the guest cfg, and both are files -- so the whole thing can be staged over ssh:

```sh
# ~18 MB is all that is missing from a `--gpu=gl` rootfs: the ICD
# (libvulkan_broadcom.so), its manifest and the loader are already installed there
# (see the mesa row in section 2).
scp qemu-system-aarch64.bin libvirglrenderer.so.1.* guest.ext4 root@<domd>:/home/root/venus/

# on DomD -- plain qemu, no Xen in this path
export LD_LIBRARY_PATH=/home/root/venus
./qemu-system-aarch64.bin -M virt -cpu cortex-a76 -smp 2 -m 1024 \
  -kernel /mnt/linux-domu -append "root=/dev/vda rw console=ttyAMA0" \
  -drive if=none,id=hd,file=guest.ext4,format=raw -device virtio-blk-pci,drive=hd \
  -device virtio-gpu-gl-pci,blob=true,hostmem=1G,venus=true \
  -display egl-headless -serial mon:stdio
```

Stage 2 needs no SD rewrite either: point the qemu wrapper at the staged binary,
add `,hostmem=256M,blob=true,venus=true` to the `virtio-gpu-gl-pci` line in
`/etc/xen/domu.cfg`, and point that config's `-drive` at the staged guest image
instead of `/dev/mmcblk0p3` (the AGL rootfs cannot serve as the guest here anyway
-- see section 7).

Two notes on borrowing the Cuttlefish recipe:

- **its virtio-gpu line does not enable Venus.** The documented line is
  `-device virtio-gpu-gl-pci,id=gpu0,xres=720,yres=1280`, with no `venus`, `blob`
  or `hostmem` -- and qemu 10.0.2 *rejects* `venus` unless `blob` and `hostmem` are
  both set (`hw/display/virtio-gpu.c`). All three have to be added.
- **its prebuilt guest is Android** (`cuttlefish_drm_virgl_venus.tgz`, arm64
  Android Automotive from ci.android.com). That is useful later as a ready-made
  Vulkan guest for the phase 4-A path, but for phases 1-3 a
  `core-image-minimal` for `virtio-armv8-xt` plus `mesa-vulkan-drivers
  vulkan-loader vulkan-tools` is smaller, boots the same kernel, and is the same
  mesa the real DomU would use -- so the only thing changing between stages is the
  VMM.

### What stage 0 actually found (run 2026-08-29)

Stage 0 was run before any hardware session, with the guest being a
`core-image-minimal` for `virtio-armv8-xt` plus `mesa-vulkan-drivers vulkan-loader
vulkan-tools`, the kernel being the DomU kernel unchanged, and the host being an
x86 PC with an Intel iGPU. It ended at:

```
GPU0:
        apiVersion         = 1.4.307
        driverVersion      = 26.0.5
        deviceName         = Virtio-GPU Venus (Intel(R) Graphics (RPL-S))
```

i.e. an arm64 guest enumerating the host GPU through Venus. Getting there took
three corrections, and **one of them was a bug in this series**:

1. `venus=true` alone is refused -- `blob=true` and `hostmem=<size>` must be set
   too. Already in the series (the guest cfg substitution).
2. **virglrenderer needs its render server, and this series did not enable it.**
   qemu passes `VIRGL_RENDERER_VENUS | VIRGL_RENDERER_RENDER_SERVER` together, so
   without `/usr/libexec/virgl_render_server` the venus context is never created:
   `RESOURCE_CREATE_BLOB (0x10c)` comes back `VIRTIO_GPU_RESP_ERR_UNSPEC (0x1200)`,
   the following MAP/UNREF fail `INVALID_RESOURCE_ID (0x1203)`, and
   `vkCreateInstance` returns `ERROR_OUT_OF_HOST_MEMORY`. oe-core defaults the
   `render-server` PACKAGECONFIG off; the Venus lane now turns it on, and the board
   image was rebuilt to confirm `/usr/libexec/virgl_render_server` ships (1.5 MB in
   the `virglrenderer` package). **Without this the board run would have failed the
   same way and cost a hardware session to find.**
3. `-object memory-backend-memfd` + `-machine memory-backend=` is **not** needed --
   tested both ways, and Venus enumerates identically without it. It is worth
   recording because it is the usual advice for virtio-gpu blob resources: it
   matters for guest-memory blobs (`BLOB_MEM_GUEST`, which qemu exports with
   udmabuf), not for the host-memory blobs Venus uses for its rings. It is also not
   applicable to the Xen lane at all: that option configures *qemu-allocated* guest
   RAM, and under Xen the domain's memory is allocated by libxl and mapped through
   xenforeignmemory, not owned by qemu. So neither guest cfg carries it.

Stage 0 was then pushed past enumeration into a real draw, and that found a
**second bug in this series** -- this time in the gate script itself:

- `vulkaninfo` reports `driverName = venus` for both host devices
  (`Virtio-GPU Venus (Intel(R) Graphics (RPL-S))` and the llvmpipe one), so
  enumeration through Venus is solid.
- The draw attempt failed on `headless-backend.so: cannot open shared object
  file` -- **weston in this tree has no headless backend**. Its PACKAGECONFIG is
  `kms wayland egl clients ... vulkan`, with no `headless`, and the built DomD
  rootfs contains only `drm-backend.so` and `wayland-backend.so`. The gate
  script's phase 3 used `weston --backend=headless --renderer=vulkan`, so on the
  board it could only ever fail -- and would have reported a missing backend as
  if Vulkan were broken.
- Phase 3 now runs `weston-simple-dmabuf-vulkan` as a **client against the
  compositor that is already running**. That needs no second compositor, no
  headless backend and no display change, it exercises Vulkan plus dmabuf export
  (the closest host-side analogue of what Venus does), and both that client and
  `weston-simple-vulkan` are already in the image. The headless path is kept only
  as a fallback for an image that does have the backend.

With that fixed, the guest-side draw ran and **passed** -- as a Vulkan *client* on
the GL compositor. weston 15 inside the arm64 guest, on the virtio-gpu DRM backend,
ran `weston-simple-vulkan` for 35 s: the client exited 0, the compositor survived,
and the frame captured mid-run through `weston-screenshooter` shows the client's
RGB-gradient triangle correctly composited (see section 5a). So a real draw, not
just an enumeration tool, goes through Venus.

One methodological point from that run, and one host build option it uncovered:

- **Check for the socket and for survival, never for a log line.** An early verdict
  here called the compositor's own Vulkan renderer a pass because weston printed
  `Using Vulkan renderer` -- which weston prints *before* the framebuffer import that
  can kill it. The verdict now requires the compositor to still be alive with its
  socket present.
- **`weston --renderer=vulkan` needs virglrenderer's `minigbm_allocation`.** Without
  it, it printed the line and then died (`Aborted`, ~6 s in, socket never appearing),
  with the render server logging
  ```
  vkr: failed to query resource props: invalid res_id 8
  vkr: vkGetMemoryResourcePropertiesMESA resulted in CS error
  vkr: ring_submit_cmd: vn_dispatch_command failed
  ```
  **With `minigbm_allocation` on it runs**: 35 s, compositor alive, socket present,
  ~139.7 fps over six 5-second windows, and zero `vkr:` lines. The PACKAGECONFIG is in
  the venus lane of both product yamls for exactly this reason; the root cause is in
  section 5b.
- **Which code was affected, and which was not.** Vulkan *clients* never hit it:
  `weston-simple-egl` and `weston-simple-vulkan` on the GL compositor logged **zero**
  `vkr:` lines across full 35 s runs, because they allocate their own buffers. What hit
  it was code importing a buffer it did **not** allocate -- a compositor importing a
  KMS framebuffer or a gralloc buffer. Android's SurfaceFlinger on its SkiaVk backend
  produced the same host-side signature in DomA (section 6), in a different guest with
  a different compositor, which is what made the cause look fundamental before it was
  traced. None of it says anything about V3DV directly on DomD (phase 3's host-side
  check), which has no Venus in the path.
- **`memory-backend-memfd` changes nothing, measured cleanly both ways.** With the
  full draw path exercised, memfd off and memfd on give identical results (same
  vkr lines, same verdict). An earlier comparison appeared to show memfd
  removing those errors; that was an artefact -- `/tmp` is on the rootfs in this
  guest image and the image is reused, so a previous run's `weston.log` satisfied
  the wait loop immediately and weston was killed before it did any work. The guest
  script now deletes the log and stamps each run, and the clean comparison shows no
  difference. So the conclusion above stands, on better evidence.

Where a stage fails is the diagnosis:

| Fails at | Conclusion |
|---|---|
| stage 0 | this qemu/virglrenderer build, or something TCG-specific. Compare against the host's own `vulkaninfo`. |
| stage 1 | **V3DV cannot serve Venus.** Go to phase 5 and raise it upstream; nothing about Xen is implicated. |
| stage 2 only | **Xen-specific**: grant DMA, the missing IOMMU, or the DomD-side device model. Feeds the V4H/IOMMU discussion rather than the Mesa one. |

## 5a. Phase 3 — what Venus costs, and proof that it draws correctly

Measured on the same PC stage-0 setup. The caveat is repeated in full below
because two claims in the first version of this section were wrong, and both were
wrong in the direction of flattering Venus.

The comparison changes one thing only. Both lanes use the same guest image, the
same qemu, the same device line
(`virtio-gpu-gl-pci,blob=true,hostmem=1G,venus=true` — Venus stays enabled in
both) and the same compositor renderer (GL, i.e. virgl). Only the workload's API
differs:

| lane | client | path |
|---|---|---|
| GL | `weston-simple-egl` | GLES2 → virgl |
| Vulkan | `weston-simple-vulkan` | Vulkan → Venus |

That is also the realistic DomU shape: an existing GL compositor with a Vulkan
application on it.

|                                  | GL / virgl | Vulkan / Venus | delta |
|----------------------------------|-----------:|---------------:|------:|
| fps (mean of 6x5 s)              |      176.6 |          142.4 | -19.3% |
| guest CPU % (client window)      |     32.8 % |         30.6 % |  -6.6% |
| host CPU cores (all descendants) | 0.68 |     0.73 |  +7.3% |
| host RSS MiB (all descendants)   |        457 |            533 | +16.5% |
| host GPU non-idle %              |     67.7 % |         80.2 % | +18.5% |

Reproduced four times. fps delta -13.0% / -23.3% / -19.3% / -20.1%; the Venus side is
the stable one (138.6-143.5, CV 1.5%) and GL is what varies (161.8-180.8). One pair ran
the Venus lane first, i.e. in reverse order — no order effect. The two host rows the
descendant-summing sampler added agree closely across the pairs that have them: host
CPU +7.3% in both, host RSS +16.5% / +17.3%.

### Two measurement holes that had to be fixed first

- **The host sampler watched only qemu's own PID.** `virgl_render_server` is a
  *separate forked process* (and it forks a worker per context — the Venus lane
  samples 3 processes, the GL lane 2), and it is exactly where the Venus host-side
  work lives. Measured both ways: host CPU +0.5% → **+7.3%**, host RSS -1.1% →
  **+16.5%, sign flipped**. So the earlier "Venus costs the host essentially
  nothing extra" is a *refuted* claim, not an under-supported one. Anything
  sampling qemu alone can only flatter Venus.
- **Guest CPU spanned the whole run**, charging each lane for weston's startup,
  DRM probe and renderer init, which differ between the lanes. It is now measured
  over the client window only.

### Reading it — and the one claim that does not survive

The first version of this section said Venus "moves work off the guest and onto
the host GPU … it is what the RPi5 DomU should show too". **That does not hold.**
It compared raw utilisation at 19–23% different throughput, where absolute
utilisation figures are not interpretable on their own.

Normalising per frame is not automatically the fairer view either: totals contain
a fixed per-second term (the compositor composites at output refresh regardless of
client fps, plus boot idle and kernel ticks), and dividing that by frames
penalises the lower-fps lane. A per-frame sign is trustworthy only when it holds
for *any* fixed term ≥ 0 — which is the case exactly when the lower-fps lane
(Venus) is also higher in absolute terms:

| metric | per-frame delta | robust to the fixed-term split? |
|---|---:|---|
| host GPU non-idle | +46.9% | **yes** |
| host CPU | +33.0% | **yes** |
| guest CPU (client window) | +15.7% | **no** — Venus is *lower* in absolute terms, so the sign depends on the compositor's fixed share, which was not isolated |

So what the numbers support:

- **Per-frame host cost is unambiguously higher for Venus** in this rig — GPU
  non-idle and CPU both, robustly. Plus ~76 MiB more host RAM.
- **Guest-side per-frame cost is indeterminate.** No claim either way.
- **No efficiency claim transfers to the Raspberry Pi 5 in either direction.**
  The guest is TCG-emulated arm64 on x86 and at 140–180 fps both lanes are bounded
  by the emulated guest's command submission; the host Vulkan driver is Intel's,
  not V3DV; and there is no Xen in this path. Every performance row here has to be
  re-measured on the board.

What *does* carry over from this section is the functional half: the protocol path
works, the rendering is correct (below), and the harness that measured it exists.

Two limits of the metrics themselves, before anyone quotes them:

- **RC6 residency is GPU non-idle time, not engine utilisation.** A path that
  submits smaller, more frequent batches can keep the GPU out of RC6 without doing
  more work — plausibly part of what the Venus column shows. It is also
  system-wide, so anything else using the iGPU is inside it. Real engine busy
  needs the i915 PMU, i.e. lowering `perf_event_paranoid`; that was not done.
- Host GPU frequency was not pinned and differed between pairs (700 MHz in one,
  ~490–525 in the others). GL being *faster* at the lower clock is itself evidence
  that both lanes are guest-bound rather than host-GPU-bound.

### The capture, and the two traps in taking one

Both lanes were captured mid-draw with `weston-screenshooter` inside the guest:

```sh
weston --backend=drm --renderer=gl --shell=kiosk-shell.so --debug ... &
weston-simple-vulkan &                    # let it draw
sleep 15 && WAYLAND_DISPLAY=... weston-screenshooter
```

Result: 1280x800 in both lanes, showing the same rotating triangle with the same
vertex colours (red, green, blue at the three corners), on the same base line at
the same screen position with the same apex height. The two frames are caught at
different phases of the rotation — the Venus one near face-on, the GL one nearly
edge-on and past 90 degrees, so its red/green gradient reads mirrored. Same
geometry, same vertex colours, same placement, differing only by rotation phase —
**the Venus path composites correctly**, which is the part `vulkaninfo` cannot
tell you.

Two things that produced wrong answers before they were fixed:

1. **`--debug` is required.** Without it weston 15 refuses the screenshooter
   protocol: `Output capture error: unauthorized`.
2. **The capture must happen WHILE the client draws.** The first version ran
   `weston-screenshooter` after waiting for the client to exit, so every capture
   was a 3075-byte all-black empty desktop — and an all-black PNG looks exactly
   like a Venus failure. If a capture comes back black, check the timing before
   concluding anything about the GPU.

And one that cannot be fixed: **QMP `screendump` does not work in this setup.** It
returns `{"error":{"class":"GenericError","desc":"no surface"}}` with
`-display egl-headless`, with or without `-vnc`. The compositor-side screenshot is
the better evidence anyway — it proves what was actually composited, not what the
device model happens to hold.

## 5b. The host build option a Vulkan-compositing guest needs

Two virglrenderer PACKAGECONFIGs are off by default in oe-core and both are required
for this lane. The first, `render-server`, is covered in section 5's stage-0 findings.
This is the second, and it was found the same way — by running a guest, not by reading
recipes.

### The symptom

Any compositor that renders with Vulkan died within about five seconds of starting:
weston with `--renderer=vulkan` in DomU, Android's SurfaceFlinger on its SkiaVk backend
in DomA. Both printed their "Vulkan renderer up" line first, so both initially looked
like they worked. Vulkan *applications* were never affected.

The host said:

```
virgl_render_server: vkr: failed to query resource props: invalid res_id N
virgl_render_server: vkr: vkGetMemoryResourcePropertiesMESA resulted in CS error
virgl_render_server: vkr: ring_submit_cmd: vn_dispatch_command failed
```

### The chain, and where it broke

The resource lookup that fails is `vkr_context_get_resource()` in
`src/venus/vkr_device_memory.c` — the res_id is not in the **venus context's** table.
Everything upstream of that turned out to be correct:

| link | verdict |
|---|---|
| the guest kernel sends `CTX_ATTACH_RESOURCE` for imported dma-bufs | ok — `virtio_gpu_gem_object_open()` does it, and its own comment names `DRM_IOCTL_PRIME_FD_TO_HANDLE` |
| qemu forwards it | ok — `virgl_cmd_ctx_attach_resource()` → `virgl_renderer_ctx_attach_resource()` |
| qemu registers blob resources with virglrenderer | ok — all blob types go through `virgl_renderer_resource_create_blob()` |
| the render-server proxy forwards the attach | **this is where it stopped** |
| the worker imports it into the vkr context | ok — `render_state_import_resource()` → `vkr_renderer_import_resource()` |

With `VIRGL_LOG_LEVEL=debug` the missing line appears:

```
proxy: exported res 8 to unexpected fd_type -1
```

`proxy_context_attach_resource()` (`src/proxy/proxy_context.c`) must turn the resource
into a dma-buf fd before it can hand it to the worker process. That export goes to
`vrend_pipe_resource_export_fd()` (`src/vrend/vrend_renderer.c`), which is:

```c
#if defined(HAVE_EPOXY_EGL_H) && defined(ENABLE_MINIGBM_ALLOCATION)
   if (res->storage_bits & VREND_STORAGE_GBM_BUFFER) { ... return VIRGL_RESOURCE_FD_DMABUF; }
#endif
   return VIRGL_RESOURCE_FD_INVALID;
```

**Without `ENABLE_MINIGBM_ALLOCATION` the function is compiled down to its failure
return.** No gallium/GL resource can ever be exported, so the attach aborts — and it
aborts *silently*, because `proxy_log` is below the default log level. The venus context
never learns the res_id, and the first `vkGetMemoryResourcePropertiesMESA` on it takes
the context fatal, which is what kills the compositor.

That also explains the split that made this look fundamental: a Vulkan application
allocates its own buffers inside the venus context (`get_blob` →
`RENDER_CONTEXT_OP_CREATE_RESOURCE`, which implies attach), so it never needs the export
path. A compositor imports a framebuffer it did not allocate, so it always does.

### The fix, and what it changed

`PACKAGECONFIG:append:pn-virglrenderer = " minigbm_allocation"` in the venus lane of
both product yamls. oe-core's recipe already defines the option
(`virglrenderer_1.2.0.bb`) and already has `virtual/libgbm` in `DEPENDS`, so it costs no
new dependency — `meson.build:342` needs only `gbm >= 18.0.0`.

Measured before and after on the same host, same guest, same lane:

| | before | after |
|---|---|---|
| `weston --renderer=vulkan` | DEAD after 5 s, socket ABSENT, verdict FAIL | **alive 35 s, socket present, verdict PASS** |
| its fps | none | **139.7 mean** over six 5-second windows (134.2–146.8) |
| host `vkr:` / export errors | every run | **zero** |
| DomA SurfaceFlinger on SkiaVk | ring fatal error, host CS errors | host errors **gone** (a separate Android-side assert remains — section 6) |

And the regression check that matters, because `minigbm_allocation` changes how vrend
*allocates* scanout/shared resources and not only how it exports them: the GL-vs-Vulkan
client pair was re-measured on the rebuilt library (pair E) and lands on top of the four
pairs measured before it — fps delta -18.8% against -13.0/-23.3/-19.3/-20.1%, both lanes
PASS. Verified on the board series too: `bitbake virglrenderer` with the new
PACKAGECONFIG resolves `-Dminigbm_allocation=true` and builds (1544 tasks, all
succeeded).

### For anyone debugging this class of failure

- `proxy_log` and the rest of virglrenderer's diagnostics are invisible at the default
  log level. `VIRGL_LOG_LEVEL=debug` is what turned three rounds of "the compositor just
  aborts" into one line naming the cause.
- `venus` alone is not a sufficient PACKAGECONFIG for a guest that composites with
  Vulkan. It needs `render-server` (without it no venus context is created at all) and
  `minigbm_allocation` (without it no external buffer can enter one).

## 5c. The tuning surface, and which half of it transfers

Surveyed at every layer once the two correctness fixes were in. The framing matters more
than any single number: on a PC rig fps is TCG/guest-submission-bound, and the board runs
its device model under **Xen, not KVM** — so host-side virtio knobs measured on a PC
transfer in neither direction. Two classes, and only one is a product input.

**Product-relevant (guest-side, travels with the images):**

| knob | what it is |
|---|---|
| `debug.renderengine.backend` | GL vs Vulkan compositing in Android. Measured — section 6. |
| `debug.renderengine.graphite` (+ the `graphite_preview*_optin` R/W aconfig flags) | **Skia Graphite**, the Vulkan-first successor to Ganesh, compiled into this AAOS build. Measured — section 6. |
| `debug.renderengine.blur_algorithm` | blur cost/quality; the default (`KawaseDualFilterV2`) is already the cheap one |
| mesa venus ring relax profile | `base_sleep_us=160` plus busy-wait/warn/abort orders — a real latency-vs-CPU tradeoff, but **hard-coded constants** in 26.0.5's `vn_common.c`. 24.0.7 had `VN_RELAX_BASE_SLEEP_US` / `VN_DRAW_CMD_BATCH_LIMIT` as env vars; 26.0.5 replaced them with per-reason profiles, so changing it now needs a patch, not a variable. |
| `XT_XEN_NO_BLOB_EXPORT` | **diagnostic, in `qemu_envs`** — a non-empty value other than `0` makes the device model skip the blob export, so a dma-buf blob falls to the `/proc/self/pagemap` path and is withdrawn. Use it to attribute a withdrawal to the export half or to the p2m insert half; the log says which path ran (`(dma-buf)` vs `(pagemap)` -- and since `0121` a memfd-backed blob is wrapped in a udmabuf, so it reports `(dma-buf)` too). Not a tuning knob — leaving it set disables guest Vulkan on dma-buf backed blobs, and it also skips `0121`'s udmabuf pin, so a memfd-backed blob is shared through pagemap under `mlock()` alone, which is the page-migration corruption `0121` fixes; a failed blob export does the same. (qemu `0116`.) |
| `VKR_DEVICE_HEAP_MIB` | **product, in `qemu_envs`** — forces the device-local heap size vkr advertises to the guest (virglrenderer `0021`). `1088` ships in `doma.cfg`: v3dv reports a share of DomD's system RAM (645 MiB on a 1408 MiB DomD) and the guest's Skia/VMA then sizes its block pool as heap/8 for any heap of 1 GiB or less, so HWUI took heap/8 blocks by the handful (96 MiB each on a 1664 MiB DomD) and DomD fell into a memory-reclaim livelock. Above 1 GiB VMA uses the 4 MiB block size Skia asks for. Expected reading with it set: **zero** guest allocations of 64 MiB or more (the `0019` diagnostic in `meta-rpi-sodev-devel` is what prints them) and DomD `MemAvailable` never below ~460 MiB. |
| `VKR_RING_IDLE_WAIT_MS` | **product, in `qemu_envs`** (DomA's Venus lane and DomU) — how long an idle Venus ring thread waits before it looks again for a missed notification (virglrenderer `0022` bounds the wait, `0023` makes the bound this variable; default 10). `1000` ships: on the RPi4 idle wake-ups went from 975 to about 10 a second, with one rescue in 15 minutes and no stall. |
| `VKR_RING_RELAX` | **product, in `qemu_envs`** (DomA's Venus lane and DomU) — the ring thread's busy-wait between commands, `<order>,<first sleep in us>` (virglrenderer `0025`; unset = upstream's 15 yields, then sleeps from 10 us; a value that does not parse is logged and ignored). `0,100` ships: on the Raspberry Pi 5 the cluster's ring thread made about 24,000 yields and 9,000 sleeps a second, about 3,000 and 1,500 with `0,100` (the yields left are V3DV's), and H.264 1080p60 playback in a WebView showed 55.0 frames a second against 52.7 (two alternating sessions, full screen and HMI each; single runs spread 50 to 57). The cost is latency: Mesa's guest asks for a 1 ms idle timeout, so the ring goes idle about 1.3 ms after its last command and the guest's notify wakes it from then on, and a command that arrives in that window waits up to 0.4 ms instead of 40 us; the cluster drew 25.1 frames a second against 26.3. On the Raspberry Pi 4 (2026-10-21) a WebView's 720p60 H.264 in DomA showed the same frame rates with it and without it; the ring's calls were not counted there, and that board runs no cluster. |
| `V3DV_MAX_BO_CACHE_SIZE` | **product, in `qemu_envs`** — MiB of freed GEM BOs each render server keeps for reuse (Mesa v3dv, default 64). Nine Venus render servers retained ~0.5 GiB of DomD memory that way; `8` ships. |
| `hostmem=<size>` | a **capacity** knob whose floor is a rendering constraint, not a free dial: venus takes ~25 MiB of it and a 1920x1080 swapchain needs most of the rest — at 32M that swapchain failed with `VK_ERROR_OUT_OF_DEVICE_MEMORY`, and 128M ran out in DomA once a full-Vulkan AAOS had its resident apps up (every process rendering with HWUI on Venus maps its own blocks: 103 MiB of 128 in use by SurfaceFlinger and five apps on the rpi4, after which a WebView failed to allocate). **256M ships, as ONE value substituted into both guest configs** (it is not per-SKU; the 4 GiB rpi4 adjustment is DomD/DomA RAM, not this). The value becomes the virtio-gpu BAR as it is, so it must be a power of two no larger than libxl's per-host slice (256 MiB, `4.22-0009`). Raising it does not change how a dma-buf blob is shared: that is the DomD kernel's `0014` and qemu `0116` (§7a). |

**Rig-relevant only (deliberately not measured, and not to be applied from PC data):**
`ioeventfd=on` (eventfd/KVM notify plumbing — the board is Xen/IOREQ);
virglrenderer's `render-server-worker` = process/thread (venus rings are polled on shared
memory, so the socket is the control path and a steady-state effect is not expected —
and `process` is upstream's isolation default, so `thread` would trade security for a
gain there is no reason to predict); `-accel tcg,tb-size=…` (tunes the rig, not Vulkan).

**Two dead ends worth recording so nobody re-walks them:**

- **`VN_PERF` cannot tune anything up.** All 14 of its flags are `no_*` — they *disable*
  optimisations, and the default (`perf=0x0`) already has every one enabled. It is a
  bisection tool, not a tuning knob.
- **`max_hostmem` is unrelated to Venus.** Its default of 256 MB looks alarming next to
  the `hostmem=1G` the PC rig uses (the board ships `hostmem=256M`, the same as that
  default), but `virtio-gpu.c:287` uses it only in the 2D `resource_create_2d`
  path.

Anything measured here has to clear a noise floor: across five baseline DomU pairs the
Venus lane has CV 1.5% and the GL lane 5.8%, so roughly ±3% on the Venus lane is the
threshold below which a result is not reportable.

## 6. Phase 4-A — DomA (AAOS)

The DomA side is AOSP-tree work, which this tree carries as patches and device
definitions (see the end of this section). What follows is measured, not
sketched, because a DomA AAOS guest was booted on a PC against this series' own
device line.

### DomA has no Vulkan at all today, by build configuration

| where | measurement |
|---|---|
| Mesa build (`obj/MESON_MESA3D/.../intro-buildoptions.json`) | `vulkan-drivers = []`, `gallium-drivers = ['virgl']`, Mesa 24.3.0 — the meson log shows `-Dvulkan-drivers=` with nothing after it. The AOSP variable is `MESA3D_VULKAN_DRIVERS`, unset for this product. |
| `/vendor/lib64/hw/` | one graphics HAL only: `gralloc.default.so`. `/system/lib64/libvulkan.so` is the Vulkan *loader*, not a driver. **But see the correction below: two Vulkan ICDs and the minigbm gralloc do ship, inside APEXes** — the flat `/vendor` tree is the wrong place to look on this image. |
| live guest | `ro.hardware.vulkan` **empty** (so the loader looks for nothing), `ro.hardware.gralloc` empty, `ro.hardware.egl = mesa`, `ro.boot.cpuvulkan.version = 0` |
| live guest, framework level | `pm list features \| grep vulkan` → **empty**: no Vulkan feature is advertised to applications at all |

So a GL-vs-Vulkan comparison of the kind section 5a runs on DomU **cannot be run on
DomA** — there is no Vulkan side to it.

### What the Venus device options do to DomA: nothing measurable

`GPU=vulkan` substitutes `XT_VENUS_GPU_OPTS` into **doma.cfg too**, so DomA's
device line gains `hostmem=256M,blob=true,venus=true` (the PC rig below ran it
with `hostmem=1G`). Both lanes were booted with the real DomA images, identical
in everything else, and measured over a 60 s window at the same guest uptime.
The guest kernel's own enumeration shows the lanes really do differ:

```
base   [drm] features: +virgl +edid -resource_blob -host_visible
venus  [drm] features: +virgl +edid +resource_blob +host_visible
```

|                              | base | venus | delta |
|------------------------------|-----:|------:|------:|
| SurfaceFlinger totalFrames   | 1729 |  1756 | +1.6% |
| SurfaceFlinger averageFPS    | 27.87 | 28.43 | +2.0% |
| missedFrames                 |  251 |   222 | -11.6% |
| guest CPU busy %             | 67.4 |  67.9 | +0.7% |
| host CPU cores (all descendants) | 2.41 | 2.45 | +1.4% |
| host RSS MiB (all descendants)   | 7083 | 7080 | -0.0% |
| host GPU non-idle %          | 11.1 |  11.2 | +0.6% |

Every difference is at or below run-to-run noise, the largest being 29 frames out of
~1700 and in the Venus lane's favour. Zero `vkr:`/virgl/drm errors either side. The
runtime `ro.*` properties and SurfaceFlinger's `GLES: Mesa, virgl (…), OpenGL ES 3.2
Mesa 24.3.0-devel` line are identical between lanes. DomA composites every frame on
the GPU (`drm_hwcomposer` in `client` mode; TimeStats confirms
`clientCompositionFrames == totalFrames`), so this is not a path that was bypassed.

One real structural difference: qemu spawns `virgl_render_server` **only** when the
venus flag is set, so the base lane samples one process and the Venus lane two. A
first pair read the accompanying **+1.4%** host CPU as the render server's isolated
cost. A second pair gives **-4.0%** on that same row, so **that was noise** — along
with `missedFrames`, which went -11.6% then +17.2%. The honest statement is that the
render server's cost, when nothing in the guest creates a Venus context, is **below
this measurement's noise floor**; the `hostmem=1G` region is never touched either. The
rows that do agree across both pairs to within 0.5% — frame counters, RSS and GPU
non-idle — are what make the negative headline solid.

Second pair, for the record: totalFrames 1734 → 1735 (+0.1%), averageFPS 28.03 →
28.02, guest CPU 68.9 → 66.6 %, host RSS 7080 → 7084 MiB, host GPU non-idle 11.0 →
11.0 %.

Caveat on the numbers, same shape as section 5a's: TCG-emulated guest, Intel host
driver rather than V3DV, no Xen. What transfers is the *negative* result — the option
does not disturb DomA — not the absolute figures. Also: full AAOS boot did not reach
`sys.boot_completed` in usable time here (BootAnimation still the only SurfaceFlinger
layer at 973 s of guest uptime, 4 vCPU threads 63% busy, overlay 75 MB so not I/O),
which is why the window sits in the bootanimation phase and why there is no
post-boot UI measurement. The screenshot is not evidence either way: the expected
bootanimation frame is a solid black 480x420 PNG, and the capture is uniformly
RGB(0,0,0) with alpha 0, so a correct render and an empty buffer are
indistinguishable.

### The home screen, rendered correctly on the Venus device line

The A17 DomA image never reaches its home screen on the PC, for a reason unrelated
to graphics: system_server dies deterministically constructing `BluetoothService`
(`FATAL: Conflicting system configuration` — `FEATURE_BLUETOOTH` is declared in
`vendor/etc/permissions/car_core_hardware.xml`, `Bluetooth.apk` is present inside the
mounted `/apex/com.android.bt`, yet PackageManager never installs it) and zygote
restarts it forever. That, not slowness, is why BootAnimation stays the only
SurfaceFlinger layer.

The **A15 DomA image** — the other image the board carries — boots through on the
Venus device line and gives the capture: `boot_completed` at 133 s,
`com.android.launcher3/.uioverrides.QuickstepLauncher` focused, 73 SurfaceFlinger
layers, and a 1280x800 frame with 2316 distinct colours showing the AAOS automotive
launcher rendered correctly — nav rail, four app cards with gradient accent bars and
icons, the user chip and connectivity panel, antialiased text throughout. **That is
the DomA counterpart to section 5a's triangle: proof that the Venus-enabled device
model composites correctly**, which the bootanimation frame could not give.

Two things that capture taught, both worth knowing before reading any DomA screenshot:

- A screenshot taken shortly after `boot_completed` can be **legitimately
  black**. This product image's `<Vendor>` anti-flicker overlay goes up
  unconditionally, and its only removal paths are the image's boot-completion
  broadcast (not bundled here) or a 10 s `STATE_ON` timer. The first of three
  captures was uniformly black; the next two, 16 s and 33 s later, carried the
  UI.
- A **static** home screen composites at **1.0 fps** (30 frames in 30 s, all client
  composition). Nothing is animating, so that is correct behaviour and not a
  performance number — and it is why the A/B above uses the bootanimation phase.

The A15 guest also confirms item 4 below from the other side: `ro.hardware.gralloc`
is `minigbm` on A15 and **empty on A17**, so the software-gralloc situation is a
regression between the two DomA generations rather than something never present.
Both report `ro.hardware.vulkan` empty.

### Measured: DomA on Vulkan initialises, then the Venus ring dies

The two lines were carried through to a running Vulkan DomA on the PC, and the result
is a functional finding rather than a performance number.

**The ICD had to be built outside soong.** `m vulkan.virtio` cannot run: soong analysis
fails on defects in the product's own vendor tree that predate this change. Two are
mechanical (a missed rename in a 23-module `-4_25_8` set; a missing versioned
`*VehicleHalInterfaceDefaults-V4` AIDL module that upstream carries as a
versioned/unversioned pair) and are fixed. The third is a **host-variant mismatch** —
the vendor's `android.hardware.automotive.vehicle@default-grpc-server-lib-*` asks for
`os:linux_glibc` variants of deps that exist only as `os:android,image:vendor` — a
`host_supported` design question in that vendor's VHAL grpc setup. Analysis is global,
so it blocks every target.

So the ICD was built by driving **meson directly**, reusing the product's own generated
cross file (`<OUT_DIR>/.../obj/MESON_MESA3D_GEN/aosp_cross`) and the flags
`mesa3d_cross.mk:87-100` uses, adding only `-Dvulkan-drivers=virtio`. Same clang,
sysroot, SDK level and mesa (24.3.0) as the shipping image. Worth recording:
**DomA's mesa 24.3.0 needs no CROSS_DEVICE backport** — its `required_params[]` already
excludes it — so that fix landed between 24.0.7 and 24.3.0, not in 26.x as an earlier
note in this document said.

**Two non-obvious installation steps.** `adb root` works on this userdebug image and
`adb remount` gives overlayfs on `/vendor`. But `ro.hardware.vulkan=virtio` alone is not
enough: with `ro.vulkan.apex` set (the `com.google.cf.vulkan` APEX sets it in its own
`on init`), Android's Vulkan loader searches **only that APEX's linker namespace** and
fails with `Could not load vulkan.virtio.so from com_google_cf_vulkan namespace` —
that namespace has no `libui.so`, which this ICD needs and which the product's own
`libEGL_mesa.so` resolves fine in the *vendor* namespace. Deactivating the APEX makes
the loader fall back to `/vendor/lib64/hw`. **Anyone doing this properly in the product
build has to decide between the two paths** — ship the Venus ICD inside a vendor APEX
with the libraries it needs, or drop the APEX driver path.

**With that done, SurfaceFlinger comes up on Vulkan.** It does not yet *stay* up, and
the two reasons it fell over are worth separating, because only one of them was ours.

**First failure — and it was a host build-configuration defect, now fixed.** SF logged
`Threaded RenderEngine with SkiaVk Backend (Ganesh)` and then died within ~5 s:

```
D MESA-VIRTIO: stuck in ring seqno wait with iter at 4096
D MESA-VIRTIO: aborting on ring fatal error at iter 4096
```
with, on the host at the same moment:
```
virgl_render_server: vkr: failed to query resource props: invalid res_id 94
virgl_render_server: vkr: vkGetMemoryResourcePropertiesMESA resulted in CS error
```

That is the same signature as weston's Vulkan renderer in section 5, and the cause was
the same: virglrenderer built without `minigbm_allocation`, so no gallium/GL resource
could be exported as a dma-buf and the compositor's framebuffer never reached the venus
context. With the PACKAGECONFIG on, **every one of those host-side errors is gone from
the DomA run too** — the export and attach path works, and only the render server's
ordinary shutdown notices remain. Root cause in section 5b.

**Second failure — and it was the guest driver advertising a feature it cannot back.**
With the host side fixed, SF still restarted every ~5 s, but the crash moved entirely
inside SurfaceFlinger — no `MESA-VIRTIO` message, no `vkr:` error:

```
Abort message: 'Failed to preallocate protected GraphicBuffer for intermediate blur
surface: UNKNOWN_ERROR. Is protected memory supported? (i:0, 1280x800, RGBA_8888, ...)'
  #03 KawaseBlurDualFilterV2... #04 SkiaRenderEngine::onActiveDisplaySizeChanged
```

The chain in AOSP is four steps, each one a grep:

| step | code |
|---|---|
| the blur filter preallocates *protected* buffers iff the context says protected content is supported, and treats failure as fatal | `KawaseBlurDualFilterV2.cpp:304`, `:320` |
| for Vulkan that means "did a protected VkDevice get created" | `SkiaVkRenderEngine.cpp:144` |
| which SF attempts **unconditionally** — no property, no arg | `SkiaVkRenderEngine.cpp:55-60` |
| and that init succeeds or fails on exactly one bit | `VulkanInterface.cpp:493` — `if (protectedContent && !mProtectedMemoryFeatures.protectedMemory) BAIL(...)` |

That bit comes from the **guest Vulkan driver**. Venus forwards the renderer's features
verbatim (`vn_physical_device.c:221`), the host driver here is Intel's, which does
support protected memory — so the ICD advertised it. **Venus cannot honour it:**
protected memory needs secure buffers and virtio-gpu has no secure allocation path at
all. So Android believed the claim, committed to protected GraphicBuffers, gralloc could
not produce them, and `LOG_ALWAYS_FATAL` turned an unsupported optional feature into a
boot-blocking crash loop.

Fix, in the guest driver where venus already corrects features it cannot support:

```c
/* vn_physical_device.c, beside the existing deviceMemoryReport / ExtendedDynamicState3
   adjustments */
VN_SET_CORE_VALUE(feats, protectedMemory, false);
```

It is the correct layer — a driver that cannot back a feature should not advertise it —
and the only one available, since SurfaceFlinger offers no knob and the blur filter's
crash is unconditional. `debug.sf.disable_blurs 1` does **not** help: it gates whether
blur is *used*, while this is the unconditional display-size preallocation path.

With that in the ICD, SurfaceFlinger runs on Vulkan:

```
------------RE Vulkan (Ganesh)----------
Vulkan device initialized: 1
Vulkan protected device initialized: 0
E SurfaceFlinger: Could not initialize protected content Vulkan RenderEngine.  <- intended
D SurfaceFlinger: (Re)allocated 544000 bytes of unprotected memory for intermediate
                  blur surfaces (1280x800 display)                             <- the fix
```

no restarts for the rest of the session, and zero host-side errors.

### DomA: Vulkan vs OpenGL, measured

Same boot, same workload (the bootanimation), only `debug.renderengine.backend`
differing. 60 s windows:

|                          | OpenGL (skiaglthreaded) | Vulkan (skiavkthreaded) | delta |
|--------------------------|------------------------:|------------------------:|------:|
| SurfaceFlinger totalFrames |                  1777 |                    1800 | +1.3% |
| averageFPS               |                   28.27 |                   28.51 | +0.8% |
| **missedFrames**         |                 **207** |                  **15** | **-92.8%** |
| guest CPU busy %         |                    66.0 |                    67.7 | +2.6% |
| host CPU cores (all descendants) |             2.43 |                    2.40 | -1.2% |
| host RSS MiB (all descendants)   |             7106 |                    7252 | +2.1% |
| host GPU non-idle %      |                    12.4 |                    12.3 | -0.8% |

### …and Skia Graphite is better again

Section 5c's survey turned up one knob that changes a product decision:
`debug.renderengine.graphite`. Graphite — Skia's Vulkan-first successor to Ganesh — is
compiled into this AAOS build, and reaching it needs one non-obvious step:
`debug.renderengine.backend` must be **cleared**, because
`SurfaceFlinger.cpp:912-916` only consults `shouldUseGraphiteIfSupported()` in its `else`
branch. Setting the property to any of the four explicit values pins Ganesh. The flag
itself is a R/W aconfig flag overridable by that sysprop
(`FlagManager.cpp:291`), so no rebuild is needed.

All three backends, one boot, same workload, 60 s windows:

| backend | frames | missedFrames | missed % | guest CPU | host CPU | host RSS | host GPU non-idle |
|---|------:|------:|------:|------:|------:|------:|------:|
| GL (skiaglthreaded) | 1782 | **355** | 19.92% | 67.1% | 2.43 | 7116 MiB | 12.5% |
| Vulkan / Ganesh | 1782 | **18** | 1.01% | 67.3% | 2.39 | 7260 MiB | 13.3% |
| Vulkan / **Graphite** | 1788 | **9** | 0.50% | 66.2% | 2.39 | 7258 MiB | 18.3% |

`GraphiteVkRenderEngine::create: successfully initialized`, `RE Vulkan (Graphite)`, its
pipeline disk cache populated, full window with no restarts. Frame counts are
refresh-bound and identical within noise; missedFrames is what separates the three.

**The GL row above is confounded — do not quote it alone.** Its window opened with **35
SurfaceFlinger layers against 2 for both Vulkan rows**, because the guest was still
churning through the Bluetooth-crash-loop service cycle, so 355 partly reflects a heavier
transient layer set. The sound GL baseline is the five independent settled windows (2
layers each) measured across this work: **251, 222, 215, 252, 207 — i.e. 207-252, mean
~229**, against Vulkan/Ganesh **15-18** and Graphite **9**. That is roughly **14x fewer
missed frames**; the ordering and the order of magnitude are the result, not the exact
percentages.

Guest and host CPU are flat across all three backends. Graphite keeps the host GPU busier
(18.3% vs 13.3%) for the same delivered frames — a cost masked here by an overpowered
Intel iGPU and one to watch on V3D.

So the ordering for a Vulkan-composited DomA is **Graphite > Ganesh > GL** on deadline
misses, at no CPU cost. Both Vulkan rows are guest-side properties, so both travel to the
board — and both should be re-measured there before they change anything, with V3DV
underneath instead of Intel and no TCG in the path.

fps is refresh-bound in both lanes (the bootanimation targets ~28), so the frame counts
are not the interesting column. **`missedFrames` is: 207 → 15.** With
`clientCompositionFrames == totalFrames` in both, every frame goes through the renderer
under test, so that is a real difference in how reliably the compositor hits its
deadline — and the first evidence in this exercise of Venus *helping* rather than
costing. Host cost is flat; the +146 MiB RSS is the extra `virgl-N-gpu_render` workers.

The usual caveat holds for the absolute figures (emulated guest, Intel host driver, no
Xen). The `missedFrames` direction is what to re-test on the board.

Reverting `debug.renderengine.backend` to `skiaglthreaded` in the same boot brings SF
straight back, which is how the GL side of the comparison above was measured. The guest
is healthy on either backend.

What this means for the series: a Vulkan application on the existing GL compositor
remains the lowest-risk target (section 5a measures it, and it works in both guests),
but a Vulkan-*composited* DomA is now demonstrated rather than ruled out — and its
`missedFrames` result suggests it may be the better option once validated on hardware.
Both fixes travel with it: the PACKAGECONFIG is in this series, and the venus
`protectedMemory` override is a patch this tree applies to the AOSP tree's mesa
-- see "What DomA needs in the AOSP tree" at the end of this section.

### What enabling Vulkan in DomA requires — two lines, not four items

> **Superseded (the end of this section).** This subsection is the PC experiment
> on the vendor device of the time. The devices this tree ships need six
> settings, not two, and they build: see "What DomA needs in the AOSP tree".

An earlier version of this section listed four items and called replacing the
gralloc "the substantial one". **That was wrong.** It read `/vendor/lib64/hw/`,
found only `gralloc.default.so`, and concluded minigbm was absent — but this image's
graphics HALs ship **inside APEXes**, and both are already present:

    vendor/apex/com.google.cf.gralloc.apex  bin/hw/android.hardware.graphics.allocator-service.minigbm
                                            lib64/hw/mapper.minigbm.so
                                            etc/vintf/{allocator,mapper}.minigbm.xml
    vendor/apex/com.google.cf.vulkan.apex   lib64/hw/vulkan.ranchu.so   (gfxstream)
                                            lib64/hw/vulkan.pastel.so   (SwiftShader)
                                            etc/permissions/android.hardware.vulkan.{compute-0,level-1,version-1_3}.prebuilt.xml

They arrive through an inheritance chain that was not traced the first time:
`device/epam/aosp-xenvm-trout/aosp_xenvm_trout_arm64.mk:219` →
`device/google/trout/aosp_trout_arm64.mk:20` →
`cuttlefish/vsoc_arm64_only/auto/aosp_cf.mk` →
`cuttlefish/shared/auto/device_vendor.mk:27` →
`cuttlefish/shared/graphics/device_vendor.mk` — which is where
`TARGET_VULKAN_SUPPORT` (`:= true` in `trout/aosp_trout_common.mk`) gates
`com.google.cf.vulkan`, and where lines 76-77 add the minigbm allocator and mapper.

**What DomA actually lacks is a usable ICD.** Neither shipped driver can serve this
architecture:

| shipped ICD | why not |
|---|---|
| `vulkan.ranchu.so` (gfxstream) | needs a host-side gfxstream backend — crosvm has one, QEMU would need `virtio-gpu-rutabaga`. Measured on this series' own qemu 10.0.2: `-device help` lists `virtio-gpu{,-gl}{,-pci}` and **zero** rutabaga/gfxstream devices. DomA's device model is qemu on DomD. |
| `vulkan.pastel.so` (SwiftShader) | CPU rendering, and deliberately off (`androidboot.cpuvulkan.version=0`, `xenvm_trout_arm64/BoardConfig.mk:90`) |
| `vulkan.virtio.so` (Venus) | **not built** — and it is the one matching the host side this series already ships (virglrenderer with venus + the render server) |

So: two lines, both inside `device/epam/aosp-xenvm-trout/`. Nothing under
`device/google/` needs editing.

```
# xenvm_trout_arm64/BoardConfig.mk — beside BOARD_MESA3D_GALLIUM_DRIVERS (line 109)
BOARD_MESA3D_VULKAN_DRIVERS := virtio

# aosp_xenvm_trout_arm64.mk — beside line 36's ro.hardware.egl=mesa
PRODUCT_VENDOR_PROPERTIES += ro.hardware.vulkan=virtio
```

**Not `build/graphics.mk`.** An earlier version of this section said to put the
property there "beside line 24's `ro.hardware.vulkan=powervr`". That would have been
a silent no-op twice over: those lines sit inside
`ifneq (,$(filter r8a7795 r8a7796 r8a779g x5h, $(TARGET_BOARD_PLATFORM)))`, and this
product does not include `graphics.mk` at all — `aosp_xenvm_trout_arm64.mk:216` is a
comment recording that the native PowerVR DDK path was replaced by cuttlefish. The
property that IS live on the guest, `ro.hardware.egl=mesa`, is set at
`aosp_xenvm_trout_arm64.mk:36`, and `vendor/build.prop` in the shipping image
contains exactly that one `ro.hardware.*` graphics line — so that is the file and
the neighbourhood.

The machinery behind the first line already exists: `mesa3d_cross.mk:94` turns it
into `-Dvulkan-drivers=virtio`, `mesa3d_upstream/android/Android.mk:43` maps
`MESA_VK_LIB_SUFFIX_virtio := virtio`, and `Android.mk:183-185` installs the result
as `/vendor/lib64/hw/vulkan.virtio.so`. The Yocto side already builds the same driver
for DomU, so this is the aligned choice rather than a new integration.

**Applied and blocked on a pre-existing tree defect.** Both lines are in the AOSP
checkout this work used, and both files pass a
make syntax check. The build cannot be run to completion: soong analysis fails on
defects that have nothing to do with this change —

```
error: <vendor>/external/protobuf/Android.bp:40:1:
  "protobuf-full-availability-defaults-4_25_8" depends on undefined module
  "protobuf-lite-availability-defaults-4_25_8".
error: <vendor>/hardware/.../vhal_aidl/1.0/default/generated_lib/4/cpp/Android.bp:29:1:
  "<Vendor>IVehicleGeneratedHeaders-V4" depends on undefined module
  "<Vendor>VehicleHalInterfaceDefaults-V4".
```

That file defines 23 `-4_25_8` modules but not `protobuf-lite-availability-defaults-4_25_8`,
which upstream carries unsuffixed at `external/protobuf/Android.bp:69` — a rename
missed when the versioned copy was made. **Measured to be pre-existing**: reverting
both changes (md5 back to the original) and rerunning the same
`lunch <product>-trunk_staging-userdebug` + `m` reproduces both errors identically. So DomA's Vulkan enablement is verified at source level, not by build.

For whoever runs that build: the release is named through
`aconfig_value_set-platform_build_release-trunk_staging` in the product's
`soong.*.variables`, and `TARGET_BOARD_PLATFORM` is set with `override` in its
`BoardConfig.mk`, so it needs no env export.

Two things need one boot rather than a code change:

- whether the vulkan APEX's permission XMLs actually get scanned — the live guest
  advertised no Vulkan feature (`pm list features | grep vulkan` empty) even though
  they ship. Note also that `level-1` / `version-1_3` (0x402000) describe
  *gfxstream's* capability, so they need re-checking against what Venus over V3DV
  reports rather than being inherited unchanged.
- which allocator is live. `com.google.cf.gralloc.rc` defines
  `service vendor.graphics.allocator` pointing at the minigbm AIDL binary in the
  APEX, and `ro.hardware.gralloc` only ever selected the *legacy passthrough*
  module — so it can be empty while minigbm serves everything. `lshal` or
  `ps | grep allocator` on a booted guest would settle it. It matters because
  Venus's Android WSI needs the window buffers to be virtio-gpu resources; if
  minigbm is already live, that requirement is met.

A15 DomA reported `ro.hardware.gralloc = minigbm` / `ro.hardware.hwcomposer = ranchu`
because it was built on the Cuttlefish device config (`ro.hardware = cutf_cvm`); A17
moved to EPAM's `xenvm_trout_arm64` config with `drm_hwcomposer`. A configuration
change between generations, not evidence that minigbm was dropped.

Also worth recording: **Mesa version skew across the domains**, which is four
versions and matters whenever a mesa source file is read to explain a symptom:
DomA's AOSP tree builds **24.3.0**; the AGL cluster rootfs on SD p3 is scarthgap's
**24.0.7**; the in-tree DomU (the `domu` moulin component, which does not carry
`meta-xt-driver-domain`) is wrynose's **26.0.5**; and DomD is **26.2.4**, pinned
ahead of poky by this series (section 7e).

### What DomA needs in the AOSP tree

Three changes live in the AOSP tree rather than in the Yocto layers, and this
tree carries all three. They apply whatever `--gpu` says, so a `--gpu=gl` image
still gets a DomA with the Venus ICD (both products composite with GL):

| change | where this tree carries it |
|---|---|
| `BOARD_MESA3D_VULKAN_DRIVERS := virtio`, `PRODUCT_PACKAGES += vulkan.virtio`, `ro.hardware.vulkan=virtio`, `TARGET_VULKAN_SUPPORT := false` | each board's AAOS device: the RPi4's `device/sodev/xenvm-cf`, patched from `meta-xt-doma/aosp-patches/device/sodev/xenvm-cf/`, and the RPi5's `meta-xt-doma/aosp-device/agl/xenvm-trout-rpi5`, which `stage-aosp-device.sh` copies into the AOSP tree |
| `VN_SET_CORE_VALUE(feats, protectedMemory, false)` | `meta-xt-doma/aosp-patches/vendor/epam/mesa3d_upstream/`, against the guest Venus ICD; without it SurfaceFlinger's blur preallocation kills it in a loop |
| `debug.renderengine.backend=skiaglthreaded`, `debug.hwui.renderer=skiagl` | each board's AAOS device, as in the first row: both products composite with GL. `skiavkthreaded` and `skiavk` are what would turn Vulkan compositing on (with `/etc/qemu-gbm-layout` in DomD on virglrenderer 1.3.0) |

`apply-aosp-patches.sh` applies the patch sets after the AOSP fetch (source
mode); a prebuilt bundle carries whatever DomA it was built with.

### Linear scanout buffers: when `vendor.minigbm.scanout_linear` is needed

`meta-xt-doma/aosp-patches/external/minigbm/0003` adds the property. With it
`true`, the virgl backend of DomA's minigbm asks the host for a linear resource
(`VIRGL_BIND_LINEAR`) for every buffer allocated with `BO_USE_SCANOUT`
(`GRALLOC_USAGE_HW_COMPOSER`: SurfaceFlinger's client target, the app layers the
composer is handed, and a video decoder's output buffer it is handed). It is read
once, when the gralloc library initialises, so it takes a restart of the graphics
services to change. The
Raspberry Pi 5 product sets it (`aosp_xenvm_trout_rpi5_arm64.mk`); the Raspberry
Pi 4 product leaves it off. The bos are v3d's (system memory, which the Pi 5's HVS
reaches through its IOMMU), so they take no CMA.

On the host, virglrenderer `0024` (1.3.0 only) gives such a resource a linear GBM
bo when the device model has a gbm device (`VIRGL_EXTERNAL_GBM=1`), and qemu
11.1.2's plane handoff (`/run/qemu-plane-handoff`) passes it to weston as a
subsurface. vc4's RGB planes take only LINEAR and T_TILED, so without the property
the buffer is UIF, the plane rejects it, and weston composites DomA with the GPU
("mixed") instead of putting it on a plane ("plane-only").

| situation (Raspberry Pi 5, DomA composited with GL) | needed? | measured |
|---|---|---|
| HMI only | for plane-only, yes (the client target is a scanout buffer) | V3D 17.6 -> 17.0% (2026-10-15); weston's state not compared |
| H.264 in DomA, 720p60 / 1080p60 | yes | V3D 67-71 -> 42-44% / 85-88 -> 52-54%, same frame rate, weston mixed -> plane-only (2026-10-15) |
| HEVC 1080p60, SAND direct scanout | no: the decoder's SAND buffer goes to a plane from the device model directly | V3D 17.0 -> 16.6%, 61.07 -> 61.04 fps (2026-10-15) |
| HEVC 4K scaled to 1080p, alone full screen | no, expected: with qemu `q11-082` the decoder's 4K SAND buffer goes to a plane and the HVS scales it (the property's effect not compared there) | display 60.2 on, 57.2-59.5 off (2026-10-17, before `q11-082`); with `q11-082` and the property, codec -T 59.6 fps at V3D 41% (2026-10-19). An earlier 59-60 -> 50.5 (2026-10-16) did not reproduce |
| WebView HEVC 1080p60 with the HMI, qemu `q11-081` (`/run/qemu-plane-sand`) | yes: the app's and HMI's layers go on planes beside the decoder's SAND frame | V3D 58.5 -> 18.6%, weston 86% -> 0, 57.3 -> 58.0 shown per second, five planes (2026-10-19, CMA 384 MiB then) |
| WebView H.264 1080p60 with the HMI | yes, together with qemu `q11-078` (opaque plane 0 and a backdrop) | weston mixed -> plane-only, DomA's steal 44/38 -> 27/23, 45.6/42.5 -> 51.2/46.5 shown per second (2026-10-17, decoder output not linear then) |
| WebView H.264 1080p60 decoded in qemu, decoder output linear too (the property on in both runs compared; only the decoder's buffers differ) | yes: the decoder's RGBA output is the video layer | DomD's DRM state shows the frame's own buffer on the primary plane in place of weston's GPU composite; V3D render 80-84% -> about 50-57%; full screen 40.2/55.9 -> 58.7-59.1 shown per second in three runs of four (51.2 in the fourth), among the HMI 56.6 -> 59.2/59.3, ten minutes a run (2026-10-23) |
| Vulkan composition with `/etc/qemu-gbm-layout` | redundant (gbm-layout makes DomA's resources linear already) | not measured |

The cost is in decode speed when nothing is shown: `-S` of HEVC 1080p fell about
5% (2026-10-15), and from 178-182 fps in four runs to 105-157 in six when decoder
output was made linear too (2026-10-23; a test build on 2026-10-16, with an older
device model, had measured about 11%). Shown frame rates did not fall: codec `-T`
of HEVC 4K and 1080p 59.7-60.7 fps, within 0.3 fps of the runs without, and HEVC
1080p60 in a WebView among the HMI 59.6 shown per second either way.

Where qemu 10.0.2 and virglrenderer 1.2.0 are selected instead (no `0024`, no
plane handoff) it changes nothing.

It is set where DomA should go to a plane: the Raspberry Pi 5 on qemu 11.1.2 and
virglrenderer 1.3.0, where HEVC 1080p60 in a WebView among the HMI went from V3D
58.5% to 18.6% with every layer on a plane (2026-10-19, with qemu's
`/run/qemu-plane-sand` and `/run/qemu-sand-scaled`, DomD's CMA 384 MiB then). The
Raspberry Pi 4 has the same path (qemu 11.1.2, virglrenderer 1.3.0 and `0024`, the
plane handoff) but is left off: its HVS has no IOMMU, so a linear v3d bo is not
expected to go on a plane there and only the cost would remain (the property was not
measured there; on 2026-09-23 weston composed such a buffer on the GPU after `gbm bo
get handle failed`). It is not needed with gbm-layout. The allocator cannot tell at
allocation time whether the composer will put a buffer on a plane, so the property
stays a global switch.

## 7. Phase 4-B — DomU (AGL-IC)

**Which DomU:** the in-tree one (the `domu` moulin component) needs nothing. Its
Venus ICD is built and packaged in the `GPU=vulkan` lane — `libvulkan_virtio.so`
+ `virtio_icd.json` in `mesa-vulkan-drivers`, verified in the build tree — and
section 5a's benchmarks ran exactly that guest stack. The conf lines above (section 5)
are
for the **AGL cluster rootfs on SD p3**, a separate build that moulin never sees.

This phase needs no recipe change on the weston side — only a guest with the Venus
ICD. What it should aim at, though, is **a Vulkan application on the existing GL
compositor**, not a Vulkan-rendered compositor:

```sh
# the compositor stays on its GL renderer; the workload is the Vulkan one
weston-simple-vulkan              # or weston-simple-dmabuf-vulkan
```

- Confirm the client runs and the compositor survives it (not just that a log line
  was printed).
- Capture a frame while it draws — `weston-screenshooter` (weston needs `--debug`)
  — and look at it. A screenshot taken after the client exits is an empty desktop
  and proves nothing.
- An IC application that demands Vulkan directly (Qt6 RHI Vulkan backend, say) is
  the same shape as this and is the real target.

Caveats:

- **weston's own Vulkan renderer (`--renderer=vulkan`) does work over Venus, but only
  with virglrenderer's `minigbm_allocation` PACKAGECONFIG** (section 5b — without it
  weston aborts importing the KMS framebuffer). Measured with it on: 35 s, compositor
  alive, ~139.7 fps. It is still the secondary target rather than the primary one:
  upstream calls the renderer experimental, and a Vulkan application on the existing GL
  compositor is the lower-risk shape.
- wlroots-based Vulkan renderers require `VK_EXT_queue_family_foreign`, which V3DV
  does not appear to implement. If the AGL compositor is wlroots-based, a
  Vulkan-rendered compositor is a dead end there too; the steps above apply to
  libweston (upstream Weston).
- The Vulkan renderer is explicitly experimental upstream (that is weston's own
  assessment of its renderer, not this tree's position on Venus).

## 7a. Phase 4-B on real hardware (RPi5, 2026-08-31) — what actually happens

Everything above section 7 was established on a PC (plain qemu, `-M virt`, no Xen)
or on DomD itself. This section is the board: a Raspberry Pi 5 (16 GB SKU) running
the `GPU=vulkan` SD image, Zephyr Dom0 (dom0less), DomD as domain 1 with the
toolstack, DomU created by `xl create /etc/xen/domu.cfg`. Three results, in the
order they were reached.

### 1. DomU did not boot at all — and it was never about Venus

`xl create` succeeded, the guest ran, and then stopped forever with 0.3 s of CPU
consumed. Diagnosis order that worked, and is worth reusing, because the guest
console is silent in this lane (see the note at the end of this section):

```sh
xenctx <domid>                     # PC/LR/TTBR1 of the stuck vcpu
# PC=cpu_do_idle+0x8, LR=arch_cpu_idle+0x10  -> the guest is idle, not crashed
# System.map: swapper_pg_dir VA - TTBR1  = kimage_voffset (0xffff800040000000 here)
#             __log_buf VA ffff800081717268 - voffset = PA 0x41717268
{ printf 'pmemsave 0x41717268 131072 "/tmp/logbuf.bin"\n'; sleep 5; } \
    | nc 127.0.0.1 1235            # the cfg's -monitor telnet port
tr -c '[:print:]\n' '\n' < logbuf.bin   # the whole guest dmesg, readable
```

The filename argument must be quoted or HMP rejects it (`invalid char 't' in
expression`). This works in the qemu 10.0.2 and 11.1.2 lanes because guest RAM is in the
device model's address space; under 7.0.0-xt the same reads return zeros.

What it showed: xenbus dead, from an upstream Linux bug the 6.8.0-rc1 DomU
kernel predates
(`genirq: Flags mismatch irq 0 ... xenbus: request irq failed -16`), so no
frontend connected, `/dev/vda` never appeared and `rootwait` never returned.
That run got past it with a backport of Linux a3607581cd49 ("drivers/xen:
Improve the late XenStore init protocol"), whose commit message has the
mechanism. This tree's DomU kernel (6.8.0-rc1, `meta-xt-domu`) does not carry
that backport, and whether it needs it with the current toolstack has not been
re-established. The identical hang was measured with the **default** qemu
7.0.0-xt device model as well, so this was never a Venus or device-model problem
— it means DomU on this board had not booted before this series, in any lane.

A second, separate gap kept it off the network even after it booted: its qemu
tap was not a port of `xenbr0` (qemu ignores `br=` when `script=no`, and
`domd-flatbridge-up`'s window had closed). Fixed in `domd-flatbridge-up`, which
enslaves each guest tap as it appears, DomU's `vif-emu2` included.

What the backport does **not** fix, and what is left open: the guest's xenbus never
*connects*. The backport removes the fatal double-bind, so the guest proceeds
instead of dying, but it proceeds down the "late init" path and waits for a
connection that never arrives — measured in DomU afterwards: no `xenbus:` line in
dmesg at all, `/sys/bus/xen/devices` empty, and `control/feature-poweroff` still the
empty node libxl created rather than the `1` the guest writes when its shutdown
watcher registers. The practical consequences are that `xl shutdown` fails
(`guest didn't acknowledge control request: -9` after 60 s; `xl destroy` is needed,
and a lingering guest makes the next `xl create` fail on the duplicate name) and
that no PV frontend — including the PV console, hence the truncated boot logs above
— works in DomU. Everything the guest actually uses is virtio-pci with
`XEN_VIRTIO_FORCE_GRANT`, which needs no xenstore lookup, which is why the guest is
otherwise fully functional.

The mechanism is worth recording because it is asymmetric between guest kinds, and
it is in the toolstack, not the guest. In `tools/xenstored/domain.c` the dom0less /
xenstored-startup path (`init_domain()`) sets
`domain->interface->connection = XENSTORE_CONNECTED` unconditionally, while the
`xl create` path (`do_introduce()`) sets it only when it already reads
`XENSTORE_RECONNECT` — otherwise it relies on the ring page being zero. The zeroing
is `xc_clear_domain_page(..., dom->xenstore_pfn)` in
`tools/libs/guest/xg_dom_arm.c:74`, **whose return value is ignored**. So anything
that leaves that page non-zero silently costs an xl-created guest its whole PV
stack, with no message on either side. Which of the two — a failed clear, or a
later writer — applies here is not yet established; it needs instrumenting the
toolstack, and it is a Xen/fork-side question rather than a workspace one.

With both, DomU boots to systemd, mounts its AGL ext4 root off `/dev/vda`, takes
its dnsmasq lease (192.168.10.12) and answers ssh.

### 2. The GL path works in DomU on hardware

```sh
# in DomU, as the compositor's user
XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-0 weston-simple-egl
```
survives its full run, and agl-compositor activates and then removes the surface on
output Virtual-1 — i.e. virtio-gpu + virgl GLES rendering from DomU through DomD's
V3D is functional on the board. That is the path section 8 calls the continuing one.

`weston-screenshooter` inside DomU (agl-compositor already runs with `--debug`)
captures the running cluster to confirm it is drawing correctly rather than merely
running: a 1920x1080 frame of the AGL Flutter instrument cluster, both gauges live
(61 km/h, 2982 rpm), gear D and the telltale row rendered.

### 3. Venus in DomU is blocked by Xen, not by Mesa, qemu or V3DV

The ICD is present and loads, and with `hostmem` sized to fit (section 5c / the
`XT_VENUS_GPU_OPTS` comment in the yamls) the protocol handshake completes:

```
[drm] features: +virgl +edid +resource_blob +host_visible +context_init
MESA-VIRTIO: debug: connected to renderer / wire format version 1
MESA-VIRTIO: debug: VK_MESA_venus_protocol spec version 1
MESA-VIRTIO: debug: supports blob id 0: 1
```

and then `vulkaninfo` dies. `strace` puts the death at the first access to the
venus ring, immediately after it is mapped:

```
ioctl(3, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB, ...) = 0
ioctl(3, DRM_IOCTL_VIRTGPU_MAP, ...)                 = 0
mmap(NULL, 131268, PROT_READ|PROT_WRITE, MAP_SHARED, 3, 0x101048000) = 0xffff9c05f000
+++ killed by SIGKILL +++
```

and `xl dmesg` says why:

```
(XEN) d20v0 unhandled Arm instruction 0x3d800000
(XEN) d20v0 Unable to decode instruction
(XEN) d20v0 Rn should not be equal to Rt except for r31
```

`0x3d800000` is a 128-bit SIMD store (`str q0, [x0]`). Under Xen the host-visible
blob BAR is **IOREQ-emulated MMIO**, not memory in the guest's p2m, so every access
to the venus ring traps into Xen for emulation. The path below was read in Xen 4.21,
which is what the tree carried when this was first diagnosed; 4.22 (what it ships
with now, and what the RPi4 run used) is unchanged in all three places:

- `xen/arch/arm/io.c:172` — *"Armv8 processor does not provide a valid syndrome for
  decoding some instructions. So in order to process these instructions, Xen must
  decode them."* A SIMD/FP access is one of those (`dabt.valid` == ISV == 0), so Xen
  falls back to decoding the instruction itself;
- `xen/arch/arm/decode.c` — `decode_arm64()` accepts only the post-indexed
  general-purpose load/store forms (`POST_INDEX_FIXED_MASK`, and the `str`/`strb`/
  `strh` immediate comment at line 98); anything else takes `bad_loadstore` and logs
  `unhandled Arm instruction`;
- `xen/arch/arm/traps.c:1910` — a decode failure sets `INSTR_ERROR` and the handler
  does `goto inject_abt`, i.e. **Xen injects the abort into the guest**, which kills
  the faulting task.

Mesa writes the venus ring with `memcpy`, and aarch64 `memcpy` is SIMD, so the very
first ring write lands in that path. A Xen-side fix therefore has to reach the
guest's FP/SIMD register state from the MMIO emulation path, not just add an opcode.

This is the host-visible-blob risk this document flagged from the start, landing at
the hypervisor layer. Three ways out, in increasing order of value:

1. **Extend Xen's MMIO decoder to SIMD/FP accesses.** Unblocks Venus, but every
   128-bit store to the ring stays a trap into qemu — correctness without usable
   performance. Useful only to prove the rest of the stack.
2. **Map the blob into the guest p2m** so the ring is real memory and never traps.
   This is what makes Venus fast on KVM. **This is what the series now does** — see
   below.
3. **A guest-memory blob path** (`VIRTGPU_PARAM_GUEST_VRAM`, Mesa's alternative to
   `HOST_VISIBLE`): blobs in guest RAM, which Xen maps natively. qemu does not
   implement it today (crosvm does), so this is an upstream qemu proposal.

### The fix: a patch on each side of the hypercall, and four more behind them

The two below are the core of it. Four more, each added when the next failure was
reached, complete it -- so a reader looking for "the p2m fix" should expect six
patches, not two:

| patch | what it adds |
|---|---|
| qemu `0116` | implements `arch_xen_set_memory()` for Arm: learn the frames, insert them, withdraw the window if that fails |
| Xen `4.22-0007` | permits the direction, and resolves `DOMID_SELF` (see below) |
| Xen `4.22-0008` | moves the guest's prefetchable PCI window to 0xc0000000 and grows it to 768 MiB |
| Xen `4.22-0009` (libxl) | hands that window out in 256 MiB slices, so one BAR can hold a swapchain and the resident apps' blocks with room for a WebView |
| DomD kernel `0014` | `IOCTL_GNTDEV_DMABUF_IMP_TO_GFNS`, for the dma-buf case pagemap cannot answer |
| qemu `0121` | pins a shmem-backed blob through udmabuf first, because `mlock()` does not stop page migration |

**Why it needs both.** On Arm `arch_xen_set_memory()` is an empty stub
(`hw/arm/xen-stubs.c`), so device-model RAM in the guest's address space is only
ever registered with the IOREQ server. x86 is no better for this purpose: its
implementation calls `xen_add_to_physmap()`, which *relocates guest RAM* with
`xendevicemodel_relocate_memory()` and is gated on `mr == framebuffer` — it moves
the VGA framebuffer around, it does not share device-model memory. So no
architecture does what a host-visible blob needs today.

* **qemu — `0116-hw-arm-share-device-model-RAM-into-the-guest-s-physma.patch`.**
  Implements the hook: reads the guest frame numbers of its own pages from
  `/proc/self/pagemap`, `mlock()`s them, and puts them into the guest's p2m with
  `xc_domain_add_to_physmap_batch(XENMAPSPACE_gmfn_foreign, DOMID_SELF, …)` in
  chunks of at most `UINT16_MAX` pages, withdrawing the whole region if a chunk
  fails; removes them again on `region_del`.
* **Xen — `4.22-0007-arm-let-a-device-model-share-its-own-memory-into-its-.patch`.**
  `xsm_map_gmfn_foreign(XSM_TARGET, d, od)` asks whether the domain *receiving* the
  mapping is privileged over the page owner. That is the right question for a
  control domain mapping a guest's page into itself, and the wrong one here, where
  the guest receives and the driver domain owns. The patch allows the case where
  the caller owns the pages; the caller is already required to be privileged over
  the target by `xsm_add_to_physmap()`, and the guest cannot initiate any of it.

  On **Xen 4.22 this patch has a second half**, and it is the half no patch
  application check can see. Until 4.22 the owner lookup was `get_pg_owner()`,
  which resolves `DOMID_SELF` to `current->domain` -- that is how the device model
  above names its own pages. 4.22 replaced it with
  `rcu_lock_remote_domain_by_id()`, which cannot name the caller at all:
  `DOMID_SELF` (0x7FF0) is above `DOMID_FIRST_RESERVED` so `domid_to_domain()`
  returns NULL and the caller gets `-ESRCH`, and passing the real domid instead
  trips that function's own `*d == current->domain` test and gets `-EPERM`. Both
  happen *before* the XSM relaxation above, so on 4.22 the patch must also resolve
  `DOMID_SELF` itself. A patch that only refreshes the surrounding context applies
  with zero fuzz, compiles, and never runs.

**Measured with the qemu half alone** (deployed by scp onto the running board, no
card rewrite), which is exactly the evidence that the remaining blocker is the one
line of XSM policy and nothing else:

```
xen-arm: 33 of 33 pages of device RAM at 0x3a000000 were not shared into dom25
         (first error -1)
```

33 pages is the venus ring blob (131268 bytes), 0x3a000000 is the blob's guest
address, and -1 is `-EPERM` per page. The pagemap lookup, the batching and the
teardown path all work; Xen refuses the direction.

### Measured with both halves: Vulkan works in DomU

The board was reset into the patched hypervisor (Xen's own `R` debug key does a full
machine restart from DomD — `xl debug-keys R`; the UART carries both U-Boot's and
Xen's console, so the boot is visible), and in DomU:

```
$ vulkaninfo --summary
GPU0:
        apiVersion         = 1.3.269
        driverVersion      = 24.0.7
        deviceName         = Virtio-GPU Venus (V3D 7.1.10.2)
        driverID           = DRIVER_ID_MESA_VENUS
        driverName         = venus
        driverInfo         = Mesa 24.0.7
```

with the device model reporting the mapping it no longer has to emulate:

```
xen-arm: shared 33 pages of device RAM into dom2 at 0x3a000000 (no IOREQ emulation for this range)
xen-arm: shared 256 pages of device RAM into dom2 at 0x3a021000 (no IOREQ emulation for this range)
```

and `xl dmesg` showing **zero** `unhandled Arm instruction` aborts, where before
there was a stream of them. The venus ring and its pool blob are real guest memory
now, so the ring is on the fast path rather than trapping per access.

The guest's prefetchable PCI window also had to grow for the BAR to be useful: it
was one eighth of the guest's 64 MiB region (8 MiB), of which venus already holds
~1.2 MiB. **The first version of `4.22-0009` handed that region out in 32 MiB slices
and the lane ran `hostmem=32M`** (BAR 4 at 0x3a000000-0x3bffffff, the six 16 KiB
virtio BARs moving to the non-prefetchable window). That was an intermediate step,
not what ships: 32 MiB turned out to be too small and both the window and the slice
grew again a few paragraphs below. Everything in this paragraph is therefore in the
past tense on purpose -- the 8 MiB ceiling and the 0x3a000000 address are the
pre-`4.22-0008` world, which a patch in this same series removed.

### Closing the dma-buf case: the kernel does the translation

The gap above -- venus's dedicated and exportable allocations are dma-buf backed,
and a device model cannot read a dma-buf mapping's frame numbers -- is closed by
letting the kernel answer that question:

* **DomD kernel `0014`** adds `IOCTL_GNTDEV_DMABUF_IMP_TO_GFNS`. gntdev-dmabuf
  already attaches an imported dma-buf, maps the attachment and walks the sg
  table's dma addresses to build a frame-number array (that is how it makes grant
  references); the new ioctl hands that array back instead. The import is kept, so
  the buffer's pages stay in place until `IMP_RELEASE` -- a stronger guarantee than
  an `mlock()`. `venus-gntdev-dmabuf.cfg` turns on `XEN_GNTDEV_DMABUF` and the
  `XEN_GRANT_DMA_ALLOC` it needs; both are gated on the venus DISTRO_FEATURE.
* **qemu `0116`** uses it: before the region goes in it exports the blob
  (`virgl_renderer_resource_export_blob`) and, for a dma-buf, translates the fd
  through that ioctl, releasing the import when the region goes away. A blob
  that does not export as a dma-buf takes the pagemap route (`0121` wraps shared
  memory in a udmabuf first, so that arrives as a dma-buf too).

And the window had to grow to be useful. 32 MiB was the ceiling of its old home
(64 MiB at 0x3a000000, between the magic pages and RAM), and venus takes ~25 MiB of
it, so a 1920x1080 swapchain failed with `VK_ERROR_OUT_OF_DEVICE_MEMORY`.
**`4.22-0008`** moves the guest's prefetchable virtio-PCI window to **0xc0000000**
and gives it **768 MiB**, and **`4.22-0009`** hands it out in per-host slices: 128 MiB
at first (six of them, against the two the first attempt allowed), 256 MiB (three)
since a full-Vulkan AAOS with its resident apps ran the 128 MiB window out on
2026-09-24. The lane runs `hostmem=256M`.

The first attempt put the window in what looks like an empty 256 MiB hole at
0x10000000 -- and that was wrong, which is worth recording because the neighbours
say nothing about it. `GUEST_VPCI_ECAM_BASE`/`SIZE` is exactly 0x10000000/256 MiB,
and it is live code: `xen/arch/arm/vpci.c` registers an ECAM MMIO handler over it
for any domain created with vPCI and `libxl_arm.c` emits it into that guest's DT.
Because blob pages go into the guest p2m as *real memory* they never take a stage-2
fault, so `do_trap_stage2_abort_guest()` -- the only path to `try_handle_mmio()` --
never runs and the handler never sees the access: a guest with a passthrough PCI
device would read blob contents instead of PCI config space, and only where a blob
happened to be mapped, so intermittently. No guest in this tree has a `pci=` line,
so nothing ever failed; it was found by auditing the map rather than by a symptom.
0xc0000000 is the hole between the top of `GUEST_RAM0` and the 4 GiB mark: nothing
in the header falls in it, no guest's RAM can reach it (RAM beyond 2 GiB goes to
`GUEST_RAM1` at 0x200000000), and it is still below 4 GiB so a 32-bit BAR can
address it. Its last 256 MiB is deliberately left unused so the window does not end
exactly on the 4 GiB boundary, which is untested here.

Measured in DomU after that (board reset into the new hypervisor):

(measured with the window at 0x10000000, before the collision above was found; the
addresses move with the window, the sizes do not)

```
device-model/<domid>/virtio_pci_host: prefetch_mem_base 0x10000000, size 0x8000000
guest: pci 0000:00:04.0: BAR 4 [mem 0x10000000-0x17ffffff 64bit pref]: assigned
guest: [drm] features: +virgl +edid +resource_blob +host_visible
xen-arm: shared 33 pages ... (pagemap)      <- venus ring
xen-arm: shared 256 pages ... (pagemap)     <- venus pool
xen-arm: shared 2025 pages ... (dma-buf) x4 <- 1920x1080 swapchain images
xl dmesg: unhandled Arm instruction -> 0
```

`vulkaninfo` enumerates Venus over V3D, the swapchain allocates, and
`weston-simple-vulkan` runs its full 25 s and gets its surface onto the compositor
(`agl-compositor: Activation completed for app_id
org.freedesktop.weston.simple-vulkan`).

### Venus draws in DomU — and the two defects that were hiding behind one symptom

`weston-simple-vulkan` renders in DomU (a screenshot shows the AGL cluster
with the client's gradient triangle composited on top; 33871 distinct colours, and the
diff against a GL-only baseline is exactly the client's window). It needs two environment
workarounds, and each is a separate defect. They were originally read as one — "the client
waits forever because the frame never comes back" — and that reading was wrong: the client
hang happens with the compositor entirely out of the picture, and the compositor failure
happens while the client is healthy.

**Take a GL control screenshot before believing any Venus screenshot.** The compositor
failure below kills agl-compositor's virgl context, after which a plain `weston-simple-egl`
screenshots black too. Without the control shot this looks like "Venus does not draw".

#### Defect A — venus suballocation aliased every buffer to the pool base (FIXED)

The symptom was a Vulkan client spinning in `vn_relax` forever ("stuck in client wait with
iter at 4096"; 54 ioctl / 8737 clock_nanosleep per 2 s), cured at the time by
`VN_PERF=no_fence_feedback`. `vulkaninfo` worked either way, so the ring was fine and only
the shared-memory answer never arrived.

It was not a lost wakeup. It was memory corruption, and the minimal reproducers in
`xt-venus-diag` are what showed it.

All three (`vk-fence-test`, `vk-gl-import-test`, `vk-suballoc-probe`) share one exit
convention, and it is three-valued on purpose so a wrapper can tell an unusable
environment from a real reproduction:

| exit | meaning |
|---|---|
| 0 | ran and did **not** reproduce the defect (for `vk-suballoc-probe`, "the fence signalled" — read its `layout:` / `reading:` lines, which are the measurement) |
| 1 | **setup or API failure**: no Vulkan/EGL device, a missing extension or entry point, no suitable memory type. Nothing was measured; the `VERDICT` line says `=ERROR` and names the stage. |
| 2 | ran and the defect **reproduced** |

An exit of 1 usually means the Venus ICD is not installed, which is why
`xt-venus-diag` RDEPENDS on `mesa-vulkan-drivers` — a missing ICD is otherwise
indistinguishable from a real Venus failure.

`vk-fence-test` submits one `vkCmdFillBuffer` with a fence and reports the fence status
*and* whether the fill actually arrived in the guest's mapping, twice. Three lanes, read
together — `VN_PERF=no_fence_feedback` reporting `fill=ok` is what proves GPU-written
memory does reach the guest, so the baseline's `fill=MISSING` is not a wrong-pages problem:

| lane | fence | fill |
|---|---|---|
| baseline | STUCK | MISSING — and *exactly one* dword of 1024 wrong: dword 0, holding `VK_SUCCESS` |
| `no_fence_feedback` | ok | ok |
| `no_memory_suballoc` | ok | ok |

`vk-suballoc-probe` then named it. Three 4 KiB HOST_VISIBLE|HOST_COHERENT buffers with
distinct sentinels, mapped 64 KiB apart as sub-ranges of one pool blob, and a fill aimed at
the middle one — **annotated summary below, not verbatim output**: the real run also prints
the per-dword `buf<i> dword <n> (offset <o>) = 0x… expected 0x…` lines, a three-field
`VERDICT: probe fence=… target_dword0=… stray_in_decoys=…`, and the `layout:` / `reading:`
lines quoted further down:

```
buf0: 1024 of 1024 dwords unexpected      <- the fill landed here, entirely
buf0 dword 0 = VK_SUCCESS                 <- and so did venus' fence feedback
buf1: still holds its own sentinel        <- the buffer that was actually asked for
buf2: intact
VERDICT: probe fence=STUCK
```

**Every buffer bound to a sub-range of venus' 16 MiB `vn_device_memory` pool ends up at the
pool base on the host, so two suballocated buffers alias.** The fence hang is a symptom:
venus polls its feedback slot where it belongs while the host writes the status at the pool
base. Worse than the hang, any client with more than one small host-visible buffer silently
corrupts its own data.

**Fixed** by `meta-agl-venus/.../mesa/0002-venus-do-not-suballocate-device-memory.patch`.
Upstream deletes the pool rather than fixing it — `vn_device_memory.c` has 45 mentions of
"pool" at 24.0.7 and **none** at 26.0.5, and `vn_device_memory::base_memory`/`base_offset`
are gone — so the in-tree DomU on wrynose was never affected, and the one-line equivalent
for AGL's 24.0.7 is to stop suballocating. Verified on hardware with the patched ICD and
**no environment workaround**: the probe reports `layout: irregular spacing` (the pool is
gone) and a clean pass, `vk-fence-test`'s baseline lane reports `fence=ok fill=ok`, and
`weston-simple-vulkan` draws.

Two things ruled out on the way, both by reading the sources rather than guessing, and both
worth keeping because they are the obvious suspects:

* **a memory-attribute alias** — Xen maps foreign pages `MATTR_MEM` (cacheable) at stage 2
  (`xen/arch/arm/mmu/p2m.c`, `p2m_map_foreign_rw` falls to the `default:` arm), the guest
  honours the blob's cache attribute (`virtgpu_vram.c` only downgrades to writecombine for
  `VIRTIO_GPU_MAP_CACHE_WC`), and V3D BOs are `map_wc = true` unconditionally on the host,
  so host and guest agree on non-cacheable;
* **this series' p2m sharing** — positively, not by elimination: the guest's own writes, the
  GPU's fill and the feedback write all reach the same physical memory and the guest reads
  them back. What was wrong is which offset inside the shared pool the host bound to.

And one methodological trap worth more than the bug: **the PC cannot reproduce this**, and
for a while it looked as though it had exonerated the guest Mesa.
`vn_device_memory_should_suballocate()` returns false when the renderer reports
`has_guest_vram`, which it does under plain qemu — so venus never suballocates there and the
path is not exercised at all. The tell was in the output from the first run: the mapped
addresses are 64 KiB apart and ascending when the pool is live, and irregular when it is
not. `vk-suballoc-probe` now prints a `layout:` line saying which, because "same binary,
same options" does not mean "same code path".

#### Defect B — qemu never gives virglrenderer an EGL context (FIXED; this subsection is the investigation)

> **Read the end first.** This subsection is written in the order the work happened
> and its opening reading -- "root-caused, belongs upstream, nothing in this series
> touches it" -- is wrong as of 2026-09-04. The fix is qemu `0117` (adopt SDL's
> EGLDisplay) plus virglrenderer `0002` (do not initialise the global gbm while
> doing so). The guest's Vulkan images reach the compositor as dma-bufs,
> `MESA_VK_WSI_DEBUG=sw` is not needed and is not shipped, and the OpenGL lane keeps
> its 60 fps. The two "must not ship yet" notes below were both about the Impeller
> memory growth, which `meta-agl-venus`' flutter-engine `0001` fixes.

```
context 2 failed to dispatch PIPE_RESOURCE_SET_TYPE: 22
vrend_decode_ctx_submit_cmd: context error reported 2 "agl-compositor" Illegal command buffer 655409
```

22 is EINVAL; 655409 is the command-buffer position, not a resource id. Three
message-less `EINVAL` returns could produce it, so each was given a distinct
`virgl_error()` in a diagnostic virglrenderer build — and one board run named
it:

```
XT-DIAG set_type: no GL_EXT_memory_object support
```

That is the branch taken when virglrenderer's `egl` is **NULL**:

```c
      if (egl) { ... virgl_egl_image_from_dmabuf() ... }   /* not taken */
      else     { ... needs GL_EXT_memory_object[_fd] ... }
```

and `egl` is set only under `flags & VIRGL_RENDERER_USE_EGL` (`vrend_winsys.c:57`), which
`virtio_gpu_virgl_init()` never passes — it builds `VENUS | RENDER_SERVER` (and, on
Windows, `D3D11_SHARE_TEXTURE`) and nothing else (`virtio-gpu-virgl.c:1156-1176`). So the
import falls back to `GL_EXT_memory_object[_fd]`, which V3D's GL driver does not implement.

**That also explains why a PC reproduces nothing:** the same NULL `egl` takes the same
fallback there, but Intel's iris *does* implement those extensions, so it succeeds. The PC
pass was never evidence that the EGL path works.

> **2026-09-03: this is fixed at the mechanism level.** The missing piece was neither
> virglrenderer nor V3D: qemu never sets `qemu_egl_display` under `-display sdl`, so the v4
> `get_egl_display` callback below is never installed and virglrenderer never reaches
> `vrend_winsys_init_external()`. Patch `0117-ui-sdl2-adopt-SDL-s-EGLDisplay-*` adopts the
> display SDL already created, the way `ui/gtk.c` does for GtkGLArea. On hardware the guest's
> Vulkan images then reach the compositor as **dma-bufs** — 32 `zwp_linux_buffer_params` and
> zero `wl_shm` buffers, against 0 and 8 for the same client with the workaround — with zero
> import refusals and Venus still alive.
>
> It is **not yet cleared for use**, and measuring why turned up something bigger than defect
> B: **Venus leaks host GEM memory at 24-37 MiB/s while any Vulkan client runs**, on *both*
> WSI paths — 590→1311 MiB in 45 s with `MESA_VK_WSI_DEBUG=sw`, 746→2392 MiB in 60 s
> zero-copy, and no growth at all for the same cluster on GL. The leak is therefore
> pre-existing; 0117 aggravates it by about 1.5x. It is released when `virgl_render_server`
> exits, and *that* mass `drm_gem_close` is what livelocks DomD's V3D free path
> (`drm_vma_offset_remove` starving on the vma-offset rwlock, spinning with preemption off,
> starving `rcu_preempt` for ~300000 jiffies and taking the domain with it — kernel
> 6.18.33-v8-16k). So **no long-lived Vulkan client is viable in DomU today on either path**,
> and the leak, not defect B, is now the blocker. 0117 stays: it is not the cause and it
> removes a per-frame CPU copy. Recovering the board from the Xen console:
> `CTRL-a` three times, then `w`/`R`.
> **Localised since:** it is a host-side object leak in `vkr` (inside `virgl_render_server`),
> exposed by Flutter Impeller's per-frame Vulkan object churn — a trivial client
> (`weston-simple-vulkan`) holds 5076 KiB flat, the guest's `MemAvailable` does not move while
> the host grows 38.5 MiB/s, and DomU only has 1 GiB so it cannot be the one holding it. Not
> blob churn (0.8-1.2/s) and not virglrenderer's EGLImages (already cached per resource). The
> two failed attempts below are kept because they explain what does *not* work, but neither
> refuted the approach.
>
> **Named (same day):** a census patch on virglrenderer, counting live `vkr_device` objects by
> `VkObjectType` on the add path, shows exactly two classes growing over a 30 s cluster run —
> `DESCRIPTOR_POOL` 0 → **1540** (~2 per frame) and `IMAGE_VIEW` 2 → **857** (~1.2 per frame),
> with `DEVICE_MEMORY` and `IMAGE` flat. vkr's destroy dispatch for both is correct, so the
> host is never *told* to destroy them — and descriptor pools plus image views are precisely
> what Flutter's Impeller allocates per frame and hands to its own recycler, nearly free in
> the guest (handles) but real backing memory on the host, which is the asymmetry measured.
> **So the owner is Impeller, not Venus, virglrenderer or qemu** — and it is a documented
> bug (and the "not a patch in this series" verdict a few lines above did not survive: the
> one-line backport below is carried as `meta-agl-venus`'
> `recipes-graphics/flutter-engine/files/0001-impeller-trim-thread-local-pool-caches-in-RenderToTarget.patch`):
> **flutter/flutter#183267** reports that Impeller's Vulkan backend caches command pools
> and descriptor pools thread-locally and grows unbounded unless
> `DisposeThreadLocalCachedResources()` is called each frame, which PRs **#182265** and
> **#182402** added for two paths. `ivi-homescreen` installs no `FlutterCompositor` and the
> engine logs `embedder_surface_vulkan_impeller.cc(80)`, so this board is on the
> `GPUSurfaceVulkanImpeller` path that **#182265 already fixed** — and the engine here is
> **3.32.5**, which predates it. The remedy is an engine bump, not a patch in this series:
> `/usr/share/flutter/` is versioned, so a fixed engine installs beside 3.32.5 and is selected
> by `FLUTTER_VERSION` in `/etc/default/flutter`. Nothing in this series causes the leak and
> nothing in it can fix it. Guest side checked and exonerated: mesa 24.0.7's
> `vn_DestroyDescriptorPool`/`vn_DestroyImageView` both emit to the ring unconditionally.
>
> **Fixed and measured, and 0117 must not ship yet.** The one line was backported to engine
> 3.32.5 (commit 695f51d): `DESCRIPTOR_POOL` 1540 → **6** over a run twice as long, and host
> GEM **flat at ~157 MB** where it had grown +38.5 MiB/s. With the leak gone the four lanes
> are finally comparable: zero-copy Vulkan **28.0 fps** against the workaround's **19.0**
> (+47 %, dma-buf 20 / shm 0 versus 0 / 5). **But the GL controls moved** — gl-skia
> **60.0 → 29.0**, gl-impeller 33.0 → 24.0 — and rolling qemu back to `.pre-0117` with the
> engine patch held constant returns gl-skia to **60.0 fps, 0.34 DomD cores, 82.8 % GPU**. The
> **mechanism is not yet identified.** A first answer blamed `vrend_renderer.c:12704` (a
> non-NULL `egl` advertises `VIRGL_CAP_V2_UNTYPED_RESOURCE`) and that is **disproven**: the
> guest's only use of the bit, `virgl_resource.c:765`, is `host_feature_check_version >= 18 ||
> (cap & ...)`, and virglrenderer 1.2.0 reports 23 — so the bit is inert here — and it is
> gated on `res->blob_mem`, while the GL cluster creates 0.0 blob resources/s. The other
> `egl`-gated site is blob-only too. Context creation is also *not* diverted
> (`virglrenderer.c:604` keys on `winsys_initialized`, which the external path does not set).
> What is established is the effect, reproducing across three runs: GL loses half its frame
> rate while GPU utilisation halves and DomD CPU rises.
> **SOLVED.** Four candidates were eliminated first — the `UNTYPED_RESOURCE` capability bit
> (inert: `host_feature_check_version` is 23 ≥ 18), qemu's own display path
> (`qemu_egl_has_dmabuf()` has only a gtk consumer), the colorspace gate on
> `srgb_write_control`, and the EGL fence mechanism; the last two by building probes and
> measuring 29.0 fps in each case. The cause is that `virgl_egl_init_external()` **also
> initialises the global `gbm`**, which removes the early return in
> `vrend_resource_gbm_init()` and so routes *every* guest resource onto minigbm allocation
> instead of a plain GL texture — trading away V3D's UIF tiling. It also explains the second
> DRM client the device model grew under 0117. The import never needed gbm
> (`virgl_egl_image_from_dmabuf()` works from `EGL_LINUX_DMA_BUF_EXT`), so dropping that init
> gives **60.0 fps GL and zero-copy Vulkan at the same time** — 60.0 / 0.32 cores / 81.2 % GPU
> against a 60.0 / 0.34 / 82.8 % baseline, with dma-buf 32 / wl_shm 0, zero refusals,
> `vk-fence-test` fence=ok fill=ok and `vk-gl-import-test` import=ok. Committed as
> `meta-xt-driver-domain/recipes-graphics/virglrenderer/files/0002-vrend-initialise-GBM-for-an-external-EGLDisplay-only-.patch`
> (DomD's virglrenderer, not the AGL guest's -- `meta-agl-venus` has no
> virglrenderer). gtk (upstream's documented venus display) is *not* the answer
> here: it needs `GDK_GL=gles` on V3D and even then measures 18.0 fps. The
> `IMAGE_VIEW` growth that remained after the engine fix (one view a frame) was
> the view `GPUSurfaceVulkanImpeller::AcquireFrame` created for the embedder's
> onscreen image and never destroyed. It cost no GPU memory but host heap: the
> renderer's anonymous memory grew about 1.76 MB a minute (2026-10-20) and had
> run DomD out of memory after about 14 hours (2026-10-18). flutter-engine
> `0003` destroys the view with the frame
> (`meta-agl-venus/recipes-graphics/flutter-engine/`).

The gbm initialisation is **not** a one-line fix — two candidates were built, deployed
and reverted on hardware:

* handing virglrenderer qemu's own EGL display through the `get_egl_display` callback (by
  calling `egl_init()` when `qemu_egl_display` is unset): the display came up, but the
  device model then failed every fence (`Failed to create fence sync object`) and the
  import was **still** refused;
* adding `VIRGL_RENDERER_USE_EGL | USE_SURFACELESS | USE_GLES` to the init flags, which is
  what `vrend_winsys.c` keys on: **Venus stopped working entirely** —
  `vkCreateInstance = -1` in the guest.

Structurally, the GL half is in the device model's own process: virglrenderer's render
server is venus-only (`server/render_state.c:145` requires
`VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL` and initialises only `vkr_renderer`), so
nothing about the server can supply vrend's EGL — but the qemu-side renderer cannot be
asked for both venus and an EGL GL winsys the way these flags are structured. Closing this
needs a virglrenderer change, or `GL_EXT_memory_object` in V3D's GL driver. Both are
upstream.

`MESA_VK_WSI_DEBUG=sw` remains the working way to run a Vulkan client under a GL
compositor here. It is a guest-side environment variable rather than a patch.

**What it actually does**, traced in mesa 24.0.7 (the AGL rootfs' own version) and confirmed
against the `WAYLAND_DEBUG` logs of both lanes:

* `wsi_common.c:82` sets `wsi->sw`, and `wsi_common_wayland.c:783` then binds **only
  `wl_shm`** from the registry, never `zwp_linux_dmabuf_v1`. That is how it sidesteps defect
  B: no dma-buf is exported, so vrend's import path — the one that needs
  `GL_EXT_memory_object` — is never reached.
* Which shm variant is used turns on `VK_EXT_external_memory_host`
  (`wsi_common.c:142` → `has_import_memory_host`). Venus on this DomU does **not** expose it,
  so `wsi_common_wayland.c:2314` selects `WSI_WL_BUFFER_SHM_MEMCPY`, the copying variant,
  rather than `WSI_WL_BUFFER_GPU_SHM` where the shm pages would *be* the image memory.
* `wsi_cpu_image_needs_buffer_blit()` returns true unless `wants_linear`, which only
  `MESA_VK_WSI_DEBUG=linear` sets — so the swapchain is `WSI_SWAPCHAIN_BUFFER_BLIT`: a normal
  tiled device-local image **plus** a host-visible linear buffer.

Per frame, therefore: `vkCmdCopyImageToBuffer` over the whole surface
(`wsi_common.c:1908`), then a **blocking** `WaitForFences(..., ~0ull)` that exists only under
`wsi->sw` (`wsi_common.c:1469`) and removes any CPU/GPU overlap, then
`memcpy(image->shm_ptr, image->base.cpu_map, rowPitch * height)`
(`wsi_common_wayland.c:1990`), and finally the compositor uploads the `wl_shm` buffer as a
texture — which is why the cost also lands in DomD.

The protocol logs show it exactly. Vulkan lane:
`wl_shm@29.create_pool(fd 9, 8294400)` and
`wl_shm_pool@28.create_buffer(1920, 1080, 7680, 1)` — 7.91 MiB per frame, stride 1920x4 —
with **zero** `zwp_linux_buffer_params`. GL lane: 68 `zwp_linux_buffer_params` and
`create_immed(1920, 1080, 875713089 /* XR24 */)`, i.e. dma-buf, and no shm buffer at all.
At the 24.0 fps measured, the guest memcpy alone moves **~190 MiB/s**.

Its cost **is** now quantified, twice: 56.4 → 19.6 fps on `weston-simple-*` and, on the real
AGL cluster, 33.0 → 24.0 fps with the renderer held constant, plus 0.18 → 0.57 cores in DomD.
See section 7b. The clients do print a frame rate; over ssh it can be lost to
stdio block buffering.

Also worth knowing, found on the way: `vkr_device_memory.c` decides the guest's cache
attribute with a comment that says `/* XXX guessed */`, and on V3DV — COHERENT but not
HOST_CACHED — that guess always yields WC.

Where that leaves the lane:

* Vulkan in DomU **initialises, allocates, submits and renders** — device, queries, ring,
  pools and full-size swapchain images, all on real guest memory with no trapping, and a
  correct picture on screen.
* **Both defects are fixed in this series.** Defect A by a one-line mesa backport in
  `meta-agl-venus` (`0002`); defect B by qemu `0117` plus virglrenderer `0002`, which is
  what the box at the top of the defect-B subsection records. Neither needs an
  environment workaround, and `MESA_VK_WSI_DEBUG=sw` is not in the shipped drop-in.
* The fallback that was sketched here -- a Vulkan-rendered compositor in DomU, or an
  offscreen workload with no WSI -- is therefore not needed. `weston --renderer=vulkan`
  over Venus on DomD (section 5b) remains proven and remains the secondary target.

**How to switch the hypervisor on the board.** Copy the other lane's hypervisor
over SD p1's `xen`; the switch takes effect on the next reset (`xl debug-keys R`
from DomD does one). If a hypervisor does not come up, U-Boot's console is on
the same UART with an interruptible autoboot.

That paragraph is where this section's account of 2026-08-31 ends. **Vulkan now works
in both guests** -- sections 7b to 7e for DomU on the RPi5, section 7g for both guests
on the RPi4 -- so the "DomD-native Vulkan is the only working Vulkan on this board"
conclusion that used to close this section is superseded, and so is the fallback in
section 8.

### Note: the qemu 10.0.2 lane hides the guest console

`/var/log/xen/qdisk-<domid>.log` carries

```
failed to create 'console' device '0': declining to handle console type 'xenconsoled'
```

and after that xenconsoled serves nothing for that guest — `xl console` and
`/var/log/xen/console/guest-*.log` both stay empty, which is why the boot log had
to come out of RAM. qemu's xen-bus backend enumeration only started running once
the 0115 patch called `setup_xen_backend_ops()`; it then claims console 0, declines
it because the toolstack assigned it to xenconsoled, and leaves it unusable. The
default 7.0.0 lane is unaffected (its console works). Diagnosis is cheap with the
pmemsave recipe above, so this is filed rather than fixed.

## 7b. The AGL instrument cluster on Venus, measured (2026-09-03)

Everything above measures Venus with test clients. This measures the application that
ships: the **AGL Flutter cluster dashboard** (`flutter-cluster-dashboard.service`,
ivi-homescreen v2.0 + Flutter engine 3.32.5, 1080x1920 fullscreen).

**It runs on Venus, and it draws correctly** — verified by screenshot, not by an
absence of errors (gauges, tick marks, gradients, warning icons and typography
are identical to the GL lane).

It needs a **second embedder binary**, not a configuration change. In ivi-homescreen the
backend is a compile-time exclusive choice: `shell/view/flutter_view.cc` selects it with an
`#if/#elif` chain, and `cmake/options.cmake` only offers `BUILD_BACKEND_WAYLAND_VULKAN` when
`BUILD_BACKEND_WAYLAND_EGL` is OFF. Hence
`meta-agl-venus/recipes-graphics/flutter-auto-vulkan/`, which requires meta-flutter's recipe
and swaps the EGL backend and its three EGL-only PACKAGECONFIG items for
`backend-wayland-vulkan`, installing `/usr/bin/flutter-auto-vulkan`
beside the shipped `/usr/bin/flutter-auto`.

**How the default lane runs it.** A binary in the rootfs changes nothing on its
own: meta-agl-demo's `flutter-cluster-dashboard.service` hard-codes
`ExecStart=/usr/bin/flutter-auto`. The Vulkan lane therefore also ships a
systemd drop-in,
`meta-agl-venus/recipes-demo/flutter-cluster-dashboard/files/vulkan.conf`, which
clears that `ExecStart` and sets
`/usr/bin/flutter-auto-vulkan ... --enable-impeller`. It is packaged separately
as `flutter-cluster-dashboard-conf-vulkan` (the same shape as the recipe's own
`-conf-kvm` package) and `build.sh --gpu=vulkan` adds it, plus the embedder, to
`IMAGE_INSTALL`; `--gpu=gl` adds neither, so the drop-in reaches only the image
that lists it (the base package's task hashes still differ between the lanes,
because `--gpu=gl` takes this layer out of the AGL build). `--enable-impeller`
is in the drop-in because the engine's Skia Vulkan backend does not work here
(next bullet), and `MESA_VK_WSI_DEBUG=sw` is NOT: defect B is fixed (section
7a), and the unit already reads `/etc/default/flutter-cluster-dashboard` if a
board ever needs the workaround back.

Two constraints found on the way:

* **The engine's Skia Vulkan backend does not work here.** Every command buffer begin/end
  returns `VK_ERROR_OUT_OF_HOST_MEMORY` and nothing is drawn. `--enable-impeller` — Flutter's
  actual Vulkan path — works. Recorded, not root-caused.
* **AGL scarthgap's Vulkan-Headers are too old for this source.** 1.3.296 moved `resultCheck`
  and `defaultDispatchLoaderDynamic` into `vk::detail`; scarthgap ships 1.3.275. One
  `VK_HEADER_VERSION`-guarded alias patch, applied only to the new recipe.

| lane | renderer, from the engine's own log | fps | V3D render | DomD CPU | DomU CPU | DomU steal |
|---|---|---|---|---|---|---|
| `flutter-auto` (ships) | Skia, OpenGL (virgl) | **60.0** | 84.5 % | 0.36 cores | 0.66 cores | 28.0 % |
| `flutter-auto --enable-impeller` | Impeller (OpenGL) | **33.0** | 100.4 % | 0.18 cores | 0.29 cores | 16.6 % |
| `flutter-auto-vulkan --enable-impeller` | Impeller (Vulkan) | **24.0** | 51.8 % | **0.57 cores** | **0.80 cores** | **43.0 %** |

CPU is cores over the window for the processes that serve the workload: in DomD
`qemu-system-aarch64.bin` + `virgl_render_server` + `weston`, in DomU `flutter-auto*` +
`agl-compositor`. DomD has 2 vcpus and DomU 1, so cores rather than percentages are the
comparable figure.

Read the middle row as the control: it holds the renderer constant with the
Vulkan lane, so **33.0 → 24.0 is the cost of moving to Venus** and 60.0 → 33.0
is the cost of Impeller on V3D. Most of the loss is the renderer, not the
virtualisation. The two embedder binaries also differ in toolchain:
meta-flutter's clang-layer append builds `flutter-auto` with clang and libc++
and does not reach `flutter-auto-vulkan`, which builds with gcc; both load the
same `flutter-engine`.

**The three rows above are the 2026-09-03 measurement, before defect B was fixed**, so the
Vulkan lane there still carries its workaround (`MESA_VK_WSI_DEBUG=sw`, one CPU copy per
frame at 1080x1920 on a **single-vcpu** guest). The load figures show it plainly: GL/Impeller
is GPU-bound at 100 % render utilisation, while the Vulkan lane's render utilisation *falls*
to 51.8 % as guest CPU and steal rise — the bottleneck moves off the GPU and onto the guest's
one vcpu. With a zero-copy WSI the expectation is Vulkan at or above the GL/Impeller row.

**And the workaround is paid on both sides of the boundary.** DomD's serving processes go
from 0.18 to 0.57 cores — 3.2x — while delivering *fewer* frames, because DomD then has to
take the compositor's upload of the guest's `wl_shm` buffers plus Venus command processing in
`virgl_render_server`. Per delivered frame that is 5.5 mcore on GL/Impeller and 6.0 on
Skia/GL against **23.7 on Vulkan**, i.e. 4.3x either GL lane. DomD's own steal stays under
4 % throughout, so DomU's 16-43 % is its single vcpu, not a full machine.

Note also that the Vulkan lane splits the GPU accounting: the guest's drawing is billed to
`virgl_render_server` (32.6 %) and only the compositing to qemu (19.1 %), where the GL lanes
put both in qemu's virgl context.

## 7c. Why Vulkan draws more GPU than GL on the same application (2026-09-04)

With defect B fixed, the Vulkan lane runs at 54.0 fps against the shipped Skia/GL lane's 60.0
while showing slightly *higher* V3D render utilisation (84.8 % against 80.1 %). Percentages of
wall time cannot explain that at different frame rates, so it was normalised and then measured
at the job level.

Per frame, the picture inverts twice:

| lane | render ms/frame | bin ms/frame |
|---|---|---|
| gl-skia (Skia/GL) | **13.35** | 1.300 |
| gl-impeller (Impeller/GL) | **29.76** | 2.152 |
| vk-impeller (Impeller/VK) | **15.70** | 2.093 |

Binning is an **Impeller** property, not an API one — 2.09 and 2.15 ms in both APIs against
Skia's 1.30 — and Impeller's fragment cost **halves** moving GL → Vulkan. So the API is not the
problem; the renderer is, and Vulkan recovers most of it.

The mechanism is render-pass count. V3D is tile-based, so one pass is one bin job plus one
render job, and DRM fdinfo counts both:

| lane | fps | jobs/frame | ms/job | ms/frame | tfu/frame |
|---|---|---|---|---|---|
| gl-skia | 60.0 | **3.28** | **4.18** | 13.72 | 0.00 |
| gl-impeller | 33.0 | 4.08 | 7.44 | 30.32 | 0.00 |
| vk-impeller | 54.0 | **13.07** | **1.25** | 16.34 | **0.98** |

**CORRECTION (2026-09-04).** This section originally read that column as *"Impeller's Vulkan
backend uses ~13 render passes per frame"*. **That is wrong, and section 7e disproves it with
the guest's own numbers: Impeller issues exactly ONE 1920x1080 render pass per frame.** The
13 is a host-side job count, and a job counter cannot see a pass's geometry — thirteen
full-screen passes and one pass split thirteen ways produce the identical reading. The
measured numbers below stand; only the sentence that turned them into a pass count does not.

The "19 % above Skia/GL" total that this section originally derived from those columns does not
survive either: section 7e shows that about seven of the thirteen jobs are **empty no-op jobs**
v3dv submits to signal semaphores, and they cost almost no GPU time. So `ms/job` here is an
average over one real render pass and seven near-free jobs, and must not be read as the cost of
a pass. Measured against the same picture, the two renderers spend the same GPU time
(13.1 ms/frame on Vulkan against 13.8 on Skia/GL), and Vulkan's utilisation is the *lower* of
the two. The **TFU is active only on Vulkan** (0.98 jobs/frame, exactly zero on GL) — one
format conversion or re-tile per frame that GL does not pay — and section 7d removes it.

Two levers follow from that table, and they are independent. The TFU column is a *host*
re-tile, not a pass; section 7d closes it and takes the frame rate to 60.0. The jobs/frame
column was attributed to Impeller's pass structure and to upstream **subpass consolidation**
(flutter/flutter#128911); section 7e shows that attribution was wrong — the guest emits one
pass, so there is nothing to consolidate, and the splitting happens inside the host's v3dv.

## 7d. Closing the TFU column: explicit modifiers (2026-09-04)

**Result: the Vulkan lane reaches the OpenGL lane's 60.0 fps, at a lower host GPU load than
OpenGL** (V3D render 75.3 % against 80.4 %).

The 0.98 TFU jobs/frame that appeared only on Vulkan was the host converting a *linear*
scanout image to its tiled layout once per frame — 1920x1080, about 7.9 MiB, 2122 times in
40 s under `V3D_DEBUG=perf`. The chain behind it:

1. `agl-compositor` advertised no explicit DRM format modifier at all —
   `weston-simple-dmabuf-feedback` showed all 34 formats as `modifier NONE_INVALID` and
   nothing else.
2. Guest Venus' WSI, finding none, took the legacy path in `vn_wsi.c:130-141`, which forces
   `DRM_FORMAT_MOD_LINEAR` on scanout images. (`wsi_info->scanout` is set by common WSI
   *only* on that legacy path, which is what makes its presence diagnostic.)
3. The host GPU is tiled, so it re-tiled every frame to sample it.
4. The cause was one level lower than the compositor: **gallium's virgl driver never
   implemented `pipe_screen::query_dmabuf_modifiers`**, so it stayed NULL and
   `dri2_query_dma_buf_modifiers()` (`src/gallium/frontends/dri/dri2.c:1745`) answered a count
   of zero for every format. virgl already had `virgl_is_dmabuf_modifier_supported()` — which
   returns true for *any* modifier, with a comment saying so — and
   `virgl_get_dmabuf_modifier_planes()`. Enumeration was the only missing piece. Upstream knows
   the hole: mesa 26.0.5's `vn_wsi.c` carries the comment *"Venus + Virgl only sees the
   compositor injected LINEAR mod since Virgl doesn't support explicit modifiers on the driver
   side."*

The fix is `meta-agl-venus/recipes-graphics/mesa/mesa/0003-virgl-enumerate-dma-buf-format-modifiers.patch`.

| | before | after | gl-skia (regression control) |
|---|---|---|---|
| fps (median, `wl_surface.commit`) | 54.0 | **60.0** | 60.0 → 60.0 |
| negotiated modifier | `DRM_FORMAT_MOD_INVALID` | **`BROADCOM_UIF`** | LINEAR |
| TFU jobs/frame | 0.98 | **0.00** | 0.00 |
| ms per render job | 1.25 | **0.95** | 4.15 |
| DomD V3D render | 84.8 % | **75.3 %** | 80.4 % |

Three points of method, each of which would otherwise have produced a wrong answer:

* **The DomU image runs mesa 24.0.7**, not the 26.0.5 in `yocto/build-domu` — read from the
  strings in the deployed `libvulkan_virtio.so`. Reading the wrong tree makes the venus WSI
  code look unrecognisable.
* **The absence of `forcing scanout image linear` is only meaningful against a control.** With
  `VN_DEBUG=wsi` alone, "the path is gone" and "the environment variable never arrived" look
  identical. `VN_DEBUG=init,wsi` settles it: the init and swapchain lines print, the
  linear-forcing line does not.
* **Which modifier was actually chosen has to be read separately.** Skipping the legacy path
  does not prove a *tiled* modifier was picked. It comes off the wire:
  `zwp_linux_buffer_params_v1@N.add(fd, plane, offset, stride, mod_hi, mod_lo)` under
  `WAYLAND_DEBUG=1` — `117440512, 6` is `BROADCOM_UIF`, `16777215, 4294967295` is
  `DRM_FORMAT_MOD_INVALID`.

**And the check that no counter can replace: a screenshot.** A UIF/linear mismatch corrupts the
image while *every* number above improves — TFU zero, cheaper render jobs, higher frame rate are
all consistent with scrambled output. Shots taken mid-draw on both lanes show the cluster
rendering correctly, and the
OpenGL lane, which shares this same driver through the compositor, holds 60.0 fps unchanged.

**The limit, stated plainly.** The advertised list is hard-coded to LINEAR plus this platform's
Broadcom UIF. The correct list is the *host* renderer's and virgl cannot ask for it — `union
virgl_caps` carries no modifier table — so this guest driver would advertise UIF on a host that
cannot import it. Productising needs a caps addition on the virglrenderer side. The patch header
says so.

## 7e. The jobs/frame column is a host split, not a pass count (2026-09-04)

**One render pass goes in per frame; eleven V3D jobs come out — and there is no
split.** v3dv builds exactly one job per command buffer; the extra jobs are
**empty no-op jobs that v3dv submits to signal semaphores**, one for every
`vkQueueSubmit` that signals. They cost job count but almost no GPU time, so the
whole "Vulkan issues more passes and therefore more GPU work" reading was wrong
twice over. So flutter/flutter#128911 (subpass consolidation) is not a lever
here.

Measured with a diagnostic virglrenderer that censuses the guest's commands in
vkr — the last place the guest's own numbers are visible before they become V3D
jobs (a diagnostic build, not in this series). VK cluster lane, 58.3 render-pass
begins per second at 60 fps:

| what the guest issues, per frame | | what the host runs, per frame |
|---|---|---|
| `vkCmdBeginRenderPass` | **1.0** (all 1920x1080; no other extent, and `vkCmdBeginRenderPass2` and `vkCmdBeginRendering` are both zero) | bin jobs **11.1** |
| `vkCmdNextSubpass` | 0 | |
| barriers **inside** a render pass | **0** | |
| barriers between passes | 5.1 | |
| `vkCmdDraw` + `vkCmdDrawIndexed` | **98** | |
| copies, blits, clears, resolves | 0.12 | |

The per-client attribution is what makes "the host is splitting" a measurement
rather than an inference — the job counts above had summed every DRM client of
qemu and the render server together:

| DRM client | what it is | bin jobs/s | per frame |
|---|---|---|---|
| qemu's vrend context | the guest **compositor's** GL | 148.7 | 2.48 |
| `virgl_render_server` | the guest's **Vulkan** | **665.8** | **11.1** |

Four candidate causes were eliminated, each against the source of the mesa version DomD
actually runs (26.0.5, read from the strings in its `libvulkan_broadcom.so` — *not* the 24.0.7
that the DomU image carries; that mix-up cost a round):

* **Barriers.** `v3dv_cmd_buffer_emit_pipeline_barrier()` does end the recording job
  unconditionally, ignoring `dependencyFlags` and whether a pass is open — a real mechanism,
  and the first hypothesis. But zero barriers are issued inside a pass, so it never fires
  here. Impeller declares a BY_REGION self-dependency for framebuffer fetch and does not use
  it in this configuration.
* **Per-draw flushing.** `cmd_buffer_pre_draw_split_job()` gives every draw its own job when
  `job->always_flush` is set — but that flag is set *only* by `V3D_DEBUG=always_flush`, and 98
  draws against 11 jobs rules it out arithmetically anyway.
* **The MSAA job restart** (`cmd_buffer_restart_job_for_msaa_if_needed`) returns early once
  `draw_count > 0`, so it can cost at most one restart per pass.
* **Copies and clears**, which v3dv does give their own jobs: 0.12 per frame.

### What the jobs actually are

Instrumenting the host's own v3dv settled it (a diagnostic build of DomD's
mesa):

```
XT-V3DV cmdbufs=1536 jobs=1536 cl_submits=10691 queue_submits=6109
        submitted_cmdbufs=4582 cmdbufs_per_queue_submit=0.75 jobs_per_cmdbuf=1.00
        pid=864736 fd=7 drm_client=426 kernel_jobs(bin=10691 render=10691 tfu=0)
        jobs_per_cmdbuf_hist: 1=1536
        finish_job sites: cmd_buffer:v3dv_CmdEndRenderPass2=1528 x_meta_common:v3dX=8
```

`jobs_per_cmdbuf` is exactly 1.00 and the histogram has a single bucket, so nothing is being
split. The counts add up instead:

**`cl_submits 10691 = submitted_cmdbufs 4582 + queue_submits 6109`**

because of the tail of v3dv's queue submit:

```c
   /* Handle signaling now */
   if (submit->signal_count > 0) {
      /* Finish by submitting a no-op job that synchronizes across all queues. ... */
      return queue_submit_noop_job(queue, submit->perf_pass_index, &sync_info, true);
   }
```

Every signalling `vkQueueSubmit` costs one extra `V3DV_JOB_TYPE_GPU_CL` job, carrying
`serialize = V3DV_BARRIER_ALL`. The guest makes ~3.4 submits per frame and only 0.75 of them
carry a command buffer at all — the rest are pure semaphore signals, and each became a V3D job.

Note also what made this measurable: `kernel_jobs(bin=10691)` printed from inside v3dv matches
`cl_submits` exactly, which is what turns "client 426 is v3dv's" from an assumption into a
measurement. The per-client attribution done from outside could not establish it, because the
render server holds several DRM clients.

### The lever, and why it is not the default

`VN_PERF=no_fence_feedback,no_timeline_sem_feedback,no_query_feedback,no_event_feedback` in the
guest reduces how often it submits. Measured on clean binaries, 40 s window, frame rate from
`wl_surface.commit`:

| lane | fps | bin jobs/s | jobs/frame | ms/render job | DomD V3D render | DomD cores | DomU cores |
|---|---|---|---|---|---|---|---|
| gl-skia (ships) | 60.0 | 196.5 | 3.28 | 4.21 | 83.2 % | 0.31 | 0.65 |
| vk-impeller | 60.0 | 807.8 | 13.5 | 0.97 | 78.4 % | 0.37 | 0.37 |
| vk-impeller-nofb | 60.0 | **506.0** | 8.43 | 1.52 | **75.7 %** | 0.43 | 0.54 |

37 % fewer jobs, and **the GPU time is conserved**: 807.8 x 0.97 ms = 0.783 s/s against
506.0 x 1.52 ms = 0.769 s/s. That is the proof that the removed jobs were nearly free.

So it buys 2.7 points of GPU utilisation and costs CPU on both sides, because venus falls back
to synchronous paths. Measured per process, with the render server's **worker** included (its
comm is `virgl-<ctx>-gpu_ren...` after the fork, not `virgl_render_server`, and matching the
parent name reports the idle supervisor at 0.000 cores):

| | baseline | `VN_PERF=no_fence_feedback` |
|---|---|---|
| venus bin jobs/s | 663.0 | 359.8 (**-46 %**) |
| DomU client, user / sys | 0.175 / 0.108 | 0.240 / **0.231** |
| DomU client, voluntary ctxsw/s | 62.7 | 63.0 (**flat**) |
| DomD qemu, user / sys | 0.074 / 0.055 | 0.075 / **0.080** |
| DomD render server, user / sys | 0.090 / 0.111 | 0.129 / **0.162** |
| DomD render server, involuntary ctxsw/s | 5.1 | **78.0** |
| DomD total cores | 0.330 | 0.446 (**+35 %**) |

The added CPU is **system time** everywhere, and the client's voluntary context switches do not
move: it is not sleeping more, it is inside syscalls more. `vkGetFenceStatus` stops being a read
of a mapped coherent slot (`vn_feedback_get_status`) and becomes
`vn_call_vkGetFenceStatus` — a synchronous ring round trip (`vn_queue.c:1696`) — while
`vkWaitForFences` is a polling loop whose first 256 iterations are `thrd_yield()` (`vn_relax`,
`vn_common.c:198`), which on a one-vcpu guest returns without switching. `no_fence_feedback`
alone accounts for essentially the whole effect; the other three flags add little.

**And it is not a usable setting.** With feedback off the client dies with
`ErrorOutOfDeviceMemory` after a few client restarts on the same DomU (3/3), where the baseline
survives the same conditions; only the first client after a DomU recreate is reliable. So this
is an experimental condition that explains the mechanism, not a tuning option.

**DomU has one vcpu, so CPU is the scarcer resource there** in any case.

### The durable fix existed upstream, and is now in: host mesa 26.2.x

This section originally ended "the durable fix is host-side: v3dv signalling without submitting
an empty CL job. That is upstream v3dv work and is not a deliverable here." **It had already
been done.** mesa MR !42407 ("v3dv: Re-implement noop jobs as cpu jobs", Igalia, merged
2026-06-29) replaces the dummy job with CPU-side syncobj merging
(`drmSyncobjExportSyncFile` → `sync_merge` → `drmSyncobjImportSyncFile`) and deletes
`queue_submit_noop_job`/`job_emit_noop`. It first ships in **26.2.0** — not backported to
26.0.x or 26.1.x, and the four commits do not apply to 26.0.5 — so DomD's mesa is pinned ahead
of poky in `meta-xt-driver-domain/recipes-graphics/mesa/mesa.bbappend`. 26.2.0 also carries the
required follow-up `d4ee4a62885` ("honor wait dependencies for job-less submissions"), whose
own description is this workload exactly: *semaphore chaining with an empty command buffer*.

Measured with both the Vulkan ICD and the GL side at 26.2.2:

| | 26.0.5 | 26.2.2 |
|---|---|---|
| vk-impeller bin jobs/s | 807.8 | **207.9** (13.5 → 3.47 per frame) |
| vk-impeller V3D render | 78.5 % | **77.0 %** |
| vk-impeller fps median / min | 60.0 / 31-36 | 60.0 / **36** |
| gl-skia bin jobs/s | 196.5 | 196.2 |
| gl-skia V3D render | 83.2 % | **78.9 %** |

**The frame rate does not move, and that is the expected result** — this section already
measured that the removed jobs cost almost no GPU time. What it buys is 600 submit ioctls,
kernel schedulings and cross-queue serialisations per second, a better *minimum* frame rate,
and about 1.5 points of GPU headroom. 26.2.2 also moves some small internal copies from CL jobs
to the TFU (240 jobs/s appear where there were none) — that engine was idle and the work is
effectively free: 0.14 % utilisation, 5.7 µs per job.

This also retires `VN_PERF=no_fence_feedback` as a lever: 26.2.2 gets more than
that flag was reaching for (−74 % against −45 %) with the guest untouched, no
CPU cost, and no crash. An eight-cycle client-restart soak showed zero errors
and flat render-server GEM and RSS.

Two method points worth keeping:

* **An absent debug message needs a control before it counts as evidence.** `V3D_DEBUG=db,perf`
  was set as a drop-in on `xl-create-domu.service` and no v3dv `perf_debug` line appeared —
  but `/proc/<dm-pid>/environ` showed plain `V3D_DEBUG=db`. The device model is launched by
  **xendriverdomain** (libxl's daemon, which carries the existing
  `V3D_DEBUG=db` drop-in), not by the unit that runs `xl create`. So that negative result is
  void, not a finding. Same shape as the `VN_DEBUG=wsi` trap in 7d, one layer down.
* **Recreating DomU is the only way to change a DomD binary the device model
  execs**, and `systemctl restart xl-create-domu.service` does not do it: its
  `ExecStop` is `xl shutdown -w DomU`, this guest never acknowledges the
  pvcontrol request, and the following `xl create` then fails on the name still
  being taken while the old domain keeps running. What works is: quiesce the GPU
  clients, let the guest power itself off, release the device model, reap, then
  create -- and the unit is `RemainAfterExit=yes`, so `systemctl start` on it is
  a silent no-op until it is stopped.

## 7f. Where the remaining GPU time goes, and the one saving that is blocked (2026-09-04)

Both APIs sit at the 60 Hz ceiling, so what is left to improve is GPU headroom, not frame rate.
Attributing the GPU by DRM client says where it goes, and it is not where section 7c assumed:

| DRM client | what it is | V3D render | bin |
|---|---|---|---|
| qemu's vrend context | the **guest compositor's** GL, plus qemu's present | **45.2 %** | 3.1 % |
| `virgl_render_server` | the guest **application's** Vulkan | 33.3 % | 4.6 % |
| total | | 78.5 % | 7.7 % |

**Getting the finished frame onto the panel costs more GPU than drawing it.** Each of those
~2.5 passes per frame is a full-screen 1080p blit at roughly 3 ms, which is near V3D's floor —
so the only way to win is to remove a pass, not to speed one up.

**The host side is already optimal.** DomD's weston direct-scans-out qemu's window on an
overlay plane — `plane-4` carries `imported=yes`, and weston's own GPU usage is 0.0 %.

**The guest side does not direct-scanout, and it never can — the guest kernel's
virtio-gpu advertises no plane format modifiers.** An instrumented weston says
so directly (its output goes to a file because agl-compositor is
socket-activated, so systemd hands it the Wayland socket as fd 1 and 2 and every
`weston_log` line is written into that socket instead of the journal):

```
XT-SCANOUT mode=PLANES_ONLY view=1 surf=1920x1080 buf_type=1 opaque=1 \
           on_plane=0 why=0x0[] reasons=0x2[FB_FORMAT_INCOMPATIBLE]
XT-PLANE idx=0 type=primary pairs=1
XT-PLANE   idx=0 fourcc=XR24 (0x34325258) nmods=1 [0xffffffffffffff]
```

* `why=0x0` — **none of the six `force_renderer` conditions fires.** Both surviving guesses
  ("occluded by renderer views", "requires colour transform") were wrong.
* `view=1` — one view per repaint while the cluster draws, so nothing sits above it. The black
  curtain appears only in repaints where the client is unmapped (`buf_type=3`
  = `WESTON_BUFFER_SOLID`).
* weston does try the plane, and the plane refuses. `FB_FORMAT_INCOMPATIBLE` is set at
  `fb.c:765` **after the DRM FB was created successfully** — `drmModeAddFB2` works; what fails
  is `fb->plane_mask == 0`, no plane matching the buffer.
* `drm_fb_compatible_with_plane()` needs the plane's format entry to carry the fb's modifier.
  Its one shortcut — accept any fb whose modifier is `DRM_FORMAT_MOD_INVALID` — is unreachable
  for a `zwp_linux_dmabuf` client, because `drm_fb_get_from_dmabuf()` never promotes a
  MOD_INVALID dmabuf. So such a client's fb always carries an explicit modifier.
* The guest's primary plane advertises **one** pair: XR24 with `0xffffffffffffff`, i.e.
  `DRM_FORMAT_MOD_INVALID` and no explicit modifier at all (no `IN_FORMATS` property). An
  explicit modifier can therefore never match.

Forcing a LINEAR swapchain gives the **same** reason, which fully explains the earlier A/B
(still `imported=no`, and worse: application GPU 33.8 % → 43.4 %, TFU 0 → 54.5 jobs/s, total
79.6 % → 88.1 %). **The problem is not which modifier — it is having an explicit one at all.**
That also proves section 7d's `virgl` modifier enumeration did not break scanout: explicit
LINEAR is refused identically, so nothing was promotable before it either.

**And the modifier advertisement is only the doorway — opening it does not get direct scanout.**
That was tested rather than assumed: a diagnostic weston that accepts an explicit modifier when
the driver advertises none makes weston
promote the client correctly — `on_plane=1` with zero failure reasons in PLANES_ONLY — and
**the promoted state never reaches the hardware.** The guest's plane keeps the compositor's own
framebuffer (`allocated by = agl-compositor`, `imported=no`) while weston believes the client is
on the plane, and the panel goes **pure black** (a 4117-byte capture against 170-200 KB for a
real frame), so the buffer was never presented — not presented wrongly. **A LINEAR swapchain
behaves identically**, byte-for-byte, so this is not modifier-specific. No error appears
anywhere: the guest kernel logs no scanout failure, and the device-model log shows only the
one-time sharing of the five swapchain blobs, with no per-frame churn.

So the guest-kernel one-liner would **not** be sufficient: it buys promotion, which the patch
above already demonstrates, and the commit still fails. What is missing is for virtio-gpu's
scanout path to accept a client-allocated, render-only blob as a scanout framebuffer, and it
does not. That is not root-caused to a line — weston's commit-failure message goes through
`weston_log`, which is invisible here for the reason above — and it is not worth instrumenting
the guest kernel to find out, because **the LINEAR baseline is already 89.6 % GPU at 54.0 fps**
against UIF's 77.0 % at 60.0: even a free compositing pass would not pay for the LINEAR
swapchain. **Direct scanout is not worth pursuing on this stack; the thread is closed.**

> **Superseded (2026-10-15, the update at the end of this section).** Direct scanout
> was taken after all, with three fixes this paragraph did not have.

One instrument lesson from that experiment, recorded because it is load-bearing: while the panel
was black, total GPU read 62.1 % (from 77.0) and **fps min read 58 (from 36)** — every counter
moved the right way. The frame-rate instrument counts the *client's* `wl_surface.commit` calls,
which **rise** when the compositor stops presenting, so it is blind to this failure by
construction. On any experiment that touches the guest's drawing path, the DomD-side screenshot
comes before the numbers; a guest-side screenshot reads the renderer and can look correct while
the plane is broken.

### The blocked saving: the guest renders 1.5x the pixels the panel shows

| where | resolution | source |
|---|---|---|
| physical cluster panel (DomD HDMI-A-1) | **1920x720** | explicit modeline in DomD's `weston.ini` |
| virtio-gpu device | **1920x720** | `domu.cfg`: `xres=1920,yres=720` |
| **guest output** | **1920x1080** | DomU's `weston.ini`, from upstream AGL's generic `virtual-90.cfg` fragment |

So the guest draws 2,073,600 pixels and qemu scales every frame down to 1,382,400. Measured by
changing the guest mode to 1920x720 (before/after inside one DomU instance):

| | 1920x1080 | 1920x720 |
|---|---|---|
| application GPU | 33.3 % | **18.3 %** |
| total V3D render | **78.5 %** | **65.4 %** |
| fps median | 60.0 | 60.0 |
| modifier / TFU | UIF / 0 | UIF / 0 |

**13.1 points of GPU headroom, and it also fixes a visible defect** — the 1.5x vertical squash
is why the gauges are elliptical on the physical panel (compare a DomD-side
capture of the shipping GL cluster at 1920x720 with any DomU capture at
1920x1080).

**It is not shippable yet, and the change was rolled back.** The Flutter cluster bundle's layout
does not adapt to a 720-high viewport: the warning-lamp row and the P/R/N/D gear indicator fall
off the bottom. A `pixel_ratio` of 0.6667 in the bundle's `config.toml` was accepted by
ivi-homescreen and did not help. Missing warning lamps and gear state are worse than a squashed
picture, so both edits were reverted and verified on the board.

> **Superseded (2026-10-15, the update at the end of this section).** 1920x720 ships,
> with the dashboard and the receiver window fitted to it. The lamps and the gear were
> most likely hidden by the receiver's window, which on 720 lines covers them, rather
> than cut off; that was not checked at the time.

The saving therefore depends on **application-side work: laying the dashboard
out for 1920x720**. Done there, it fixes the aspect-ratio defect and the 13.1
points together.

### Update (2026-10-15): both savings are taken

Measured on the Raspberry Pi 5 8GB with DomA idle, V3D render queue over 10 s.

**1920x720.** `meta-agl-venus`' `weston-ini-conf.bbappend` gives Virtual-1 a 1920x720
modeline at 59.86 Hz (a plain `mode=1920x720` picks qemu's 75 Hz EDID mode). The
dashboard lays itself out in a 16:9 box, 1280x720 on this output; its `0002` keeps the
full width, and the sizes follow the height, so nothing falls off the bottom. The
receiver window (420x472 at y=290 in `AGL.conf.flutter`, between the clock box and the
warning lamps of 1080 lines) cannot fit between them on 720 lines; `cluster-demo-config`
makes it 356x400 at (782,141). On a test build earlier that day, with the window
already 356x400, a DomD-side screenshot showed the clock, the stream, the warning lamps
and P/R/N/D. V3D render 74% -> 57%.

**Direct scanout.** The black panel above was not root-caused then, and three things
stood in the way, each found on the board:
- flutter-auto-vulkan rebuilt its swapchain only on a suboptimal *present*; Mesa 24.0's
  WSI reports the compositor's scanout tranche only as a suboptimal *acquire*, so the
  swapchain stayed UIF. Its `0002` acts on the acquire.
- libweston 13 offers a modifier-less KMS device's planes only `DRM_FORMAT_MOD_INVALID`,
  so the scanout tranche says INVALID, and then it refuses an INVALID buffer
  (`fb.c:397`). `meta-agl-venus`' weston `0001` adds LINEAR.
- With the cluster on the guest's primary, its scanout is a Venus blob, and qemu blitted
  it into its window: V3D cannot sample linear, so Mesa converted it with the TFU on every
  frame (40.7%, 331 jobs/s) -- likely the cost the LINEAR baseline above paid too, not
  checked. qemu `q11-070` hands the blob to weston instead.

With the three, and the receiver stopped, V3D render is 17.5% (60 jobs/s) and TFU 0.1%;
both compositors scan out. The receiver needed its own work: its wl_shm window over the
cluster made agl-compositor compose everything (54.0%, 198 jobs/s, idle). Its `0001`
shows linear gbm buffers through zwp_linux_dmabuf (version 3, or the modifier is
dropped), DomU gets one overlay plane (`XT_DOMU_OVERLAY_PLANES`), and the buffer stays
linear on the host (mesa `0004`, virglrenderer `0024`, `VIRGL_EXTERNAL_GBM=1`). Then
17.8% with the receiver idle and 17.5-17.7% while it receives a 30 fps MJPEG stream.
agl-compositor reports plane-only composition, DomD's weston too (239 of 239 repaints in
4 s, about 60 a second), with the cluster and the receiver on two vc4 planes; by fdinfo
(a separate counter, over 10 s on a test build earlier the same day) DomU's Venus render
server was the only DRM client above 0.05% of V3D's render engine.

## 7g. The Raspberry Pi 4 board run (2026-09-12)

Everything from 7a to 7f is the Raspberry Pi 5. The Pi 4 4 GiB SKU was then brought
up on the same series, and it is the more complete run of the two: it is the only one
with **both** guests on Vulkan at once, and it is what the current default lane was
flipped on.

What worked: Xen 4.22 with this series, the 0xc0000000/768 MiB guest window,
`hostmem=128M` (the value then; 256M since 2026-09-24, see 5c), Venus in DomU (the AGL Flutter cluster) and **full-Vulkan AAOS in
DomA** -- SurfaceFlinger on SkiaVk with HWUI on Vulkan, which no Pi 5 run had.

Four defects were found here rather than on the Pi 5, and all four are fixed in
this series. Three are in the p2m path:

- **`DOMID_SELF` stopped resolving on 4.22.** The owner lookup behind
  `XENMAPSPACE_gmfn_foreign` became `rcu_lock_remote_domain_by_id()`, which cannot
  name the caller at all, so the hypervisor half refused every page before reaching
  the XSM relaxation. This is the "second half" of `4.22-0007` -- and the reason a
  patch that applies with zero fuzz and compiles can still never run.
- **The IOREQ MMIO rangeset lost a 4 KiB hole.** Venus multiplies the
  memory-topology commits, the per-FlatRange map/unmap churn makes a partial-overlap
  `map` return `-EEXIST`, and qemu discarded the return code -- so three PCI
  functions' ISR/notify pages stopped being covered and the guest took Xen's
  synthesised abort (ESR 0x96000000, ISS=0). Twelve panics. Fixed by qemu `0120`,
  which is the 7.0.0 lane's `0110` rebased.
- **Page migration corrupted the Venus ring.** `mlock()` keeps pages resident but
  not in place, and DomD compacts constantly under Venus load, so a shared frame
  moved and the render server decoded an all-zero command. Fixed by qemu `0121`
  (udmabuf as a real pin).

The fourth is outside that path: **adding the blob's MemoryRegion drove the vhost
MemoryListener**, and `vhost_commit()` re-verified every vring against addresses
that are pseudo-hvas under Xen, so the device model `abort()`ed the instant Mesa
created its first Venus context. Fixed by qemu `0119`.

Also from this run: the memory redistribution the 4 GiB SKU needs (in that
run DomD 1408 MiB / DomA 2176 MiB in the Vulkan lane; this tree's map is
DomD 1440 / DomA 2048), and the `VKR_DEVICE_HEAP_MIB` and
`V3DV_MAX_BO_CACHE_SIZE` values in section 5c. `meta-rpi-sodev/meta-xt-rpi4/README.md` carries the per-SKU
reasoning for the split.

The Pi 5, which shares all of this code, was verified afterwards: DomA
compositing with Vulkan (SkiaVk) on the 8 GB SKU, 2026-09-24 (the Pi 5
product now composites with GL). The two boards
differ in the memory map and in their board-specific Xen patches and config
fragments (`4.22-0002` for RP1 MSI routing, `xen-scmi.cfg`, and `CONFIG_TEE`/
`CONFIG_OPTEE` in `xen-hyp-config.cfg`, which the Pi 4 drops, on the Pi 5;
`4.22-0011`/`4.22-0012` on the Pi 4; and each board's passthrough config), none
of which is in the Venus path.

## 8. Phase 5 — the fallback, and why it is not needed

> **Superseded (sections 7a-7g).** This list was written when a Venus DomU died
> inside the hypervisor's MMIO emulation, which the p2m patches then fixed; Vulkan
> works in DomU and DomA on hardware. It is kept because the last two items are
> still worth doing on their own terms, and because the first two describe what to
> fall back TO if a board ever fails phase 1.

- Formalise virgl (GLES) as the continuing path for DomU and DomA.
- Keep native Vulkan use, and any vkmark-based SDV measurement, to the backend
  domain only.
- Raise a Broadcom V3D vDRM native context as a long-term upstream proposal to the
  AGL/Igalia community.
- Revisit an IOMMU-backed dedicated Vulkan passthrough domain when the V4H
  migration makes one possible.

## 9. References

- Mesa — [V3D driver](https://docs.mesa3d.org/drivers/v3d.html),
  [Virtio-GPU Venus](https://docs.mesa3d.org/drivers/venus.html)
- [Mesamatrix](https://mesamatrix.net/) — driver feature matrix
- Collabora — [The state of GFX virtualization using virglrenderer (2025)](https://www.collabora.com/news-and-blog/blog/2025/01/15/the-state-of-gfx-virtualization-using-virglrenderer/)
- QEMU — [VirtIO GPU](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
- [How to enable VirtIO-GPU Venus on QEMU explained (2025)](https://tm23forest.com/contents/how-to-enable-virtio-gpu-venus-on-qemu-explained)
- AOSP — [Cuttlefish: GPU graphics acceleration](https://source.android.com/docs/devices/cuttlefish/gpu)
- Linaro — [Booting an Android Cuttlefish guest directly with QEMU](https://linaro.atlassian.net/wiki/spaces/ORKO/pages/29093823191/)
- Collabora — [Weston 15.0 is here: Lua shells, Vulkan rendering, and a smoother display stack (2026)](https://www.collabora.com/news-and-blog/news-and-events/weston-15-here-lua-shells-vulkan-rendering-smoother-display-stack.html)
- Phoronix — [The State Of The Vulkan Renderer For Wayland's Weston 15.0 Compositor (2025)](https://www.phoronix.com/news/Weston-15.0-Vulkan-Renderer)
- FreeBSD Ports — [wlroots: document Vulkan runtime requirements (VK_EXT_queue_family_foreign)](https://gitlab.com/FreeBSD/freebsd-ports/commit/507dbffa521a9ca9e5a2baacc81262b9bb9da13a)
- Raspberry Pi — [Vulkan update: version 1.2 conformance for Raspberry Pi 4 (2022)](https://www.raspberrypi.com/news/vulkan-update-version-1-2-conformance-for-raspberry-pi-4/)
