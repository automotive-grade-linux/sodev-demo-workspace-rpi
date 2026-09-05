# sodev-demo-workspace-rpi

> **Documentation map** — [`README.md`](README.md) build and run |
> [`docs/BUILD.md`](docs/BUILD.md) build details |
> [`docs/DESIGN.md`](docs/DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) when it does not work
A **Raspberry Pi 5** port of the AGL (Automotive Grade Linux) SoDeV
disaggregated-cockpit demo (R-Car V4H / Sparrow Hawk): **Xen 4.22** running a
minimal control Dom0 (Zephyr by default, thin Linux as an alternative), a GPU
driver domain, an AGL instrument cluster and Android Automotive OS — dual
display, one board. **The build produces a bootable SD-card image (`full.img`)**
containing all four virtual machines.

This workspace complements
[`xen-troops/meta-xt-prod-devel-rpi5`](https://github.com/xen-troops/meta-xt-prod-devel-rpi5)
(whose default demo is a Zephyr Dom0 with Zephyr/Unikraft guests): here the
upstream layer set is extended into a full **SoDeV cockpit** on the same RPi5 BSP,
with two selectable Dom0 flavours (see *Build configuration*).

If you come from the V4H AGL SoDeV
([`automotive-grade-linux/sodev-demo-workspace`](https://github.com/automotive-grade-linux/sodev-demo-workspace)),
see *Differences vs the V4H AGL SoDeV* (`docs/DESIGN.md`) below for exactly what changed and what
was kept identical.

```
  Xen 4.22.0 (interim local 4.22 recipe + RPi5/virtio patch series)
  on Yocto Wrynose 6.0 LTS / Linux 6.18.33

  DOM0_OS=zephyr (default — disaggregated control plane)
  |- Dom0 : Zephyr, xenstore server only (no toolstack, no drivers)      [1 vCPU  @ pCPU 0]
  |- DomD : dom0less direct-mapped driver domain — vc4/v3d GPU, RP1,
  |         SDHCI, Mesa 26.0.5 + weston 15.0.0 + qemu 7.0.0 device-models,
  |         AND the xl toolstack that creates DomU/DomA/DomZ             [2 vCPUs @ pCPU 0-1]
  |- DomU : AGL instrument cluster (Flutter cluster demo) -> HDMI-A-1    [1 vCPU  @ pCPU 1]
  |- DomA : Android Automotive OS (trout/xenvm)           -> HDMI-A-2    [2 vCPUs @ pCPU 2-3]
  |- DomZ : Zephyr RTOS domain (xenvm board)                             [1 vCPU  @ pCPU 0]

  DOM0_OS=linux (alternative — classic control plane)
  |- Dom0 : thin Linux control domain (xl toolstack, SD owner); DomD is
            still dom0less; Dom0's xl service chain creates DomU/DomA/DomZ.
```
The diagram shows the full 5-domain cockpit; **the default build is Dom0 + DomD
only** — the DomU, DomA and DomZ guests are opt-in (`-u`/`-a`/`-z`, see *Build
configuration*).

## Quick start (build the SD image)

Everything runs inside Docker: `build.sh` builds the container image on demand,
then runs moulin + ninja inside it. You only need **Docker** on the host (see
*System requirements*).

```sh
# 1. Get the sources (this repo uses git submodules)
git clone <this repository> && cd sodev-demo-workspace-rpi
git submodule update --init --recursive

# 2. Build the SD image  ->  full.img   (build.sh applies the Zephyr Dom0 patches for you)
./build.sh                       # DEFAULT: Raspberry Pi 5, Dom0(Zephyr) + DomD   (guest-less, fast)
# ./build.sh -u                  # + DomU (AGL instrument cluster)
# ./build.sh -u -a               # + DomU + DomA (AAOS) = the 4-domain cockpit
# ./build.sh -z                  # + DomZ (Zephyr RTOS domain)
# ./build.sh --dom0=linux -u -a  # thin Linux control Dom0 instead of Zephyr
# ./build.sh --board=rpi4 -u -a  # Raspberry Pi 4 (BCM2711) instead of Pi 5

# 3. Flash it to an SD card (double-check <sd-dev>!)
sudo dd if=full.img of=/dev/<sd-dev> bs=4M conv=fsync status=progress
```

The image is named after the configuration it contains, so building a second one
does not replace the first and a card you flashed months ago can still be
identified:

```
rpi5-16GB-Dom0Zephyr-DomU-DomA-20260809-1750.img
^^^^ ^^^^ ^^^^^^^^^^ ^^^^^^^^^ ^^^^^^^^^^^^^
board SKU  Dom0       guests    build date and time (local)
                      present
```

`full.img` is a symlink to the newest one, so the `dd` line above — and anything
else that refers to `full.img` — keeps working.

Before you build:
- The **default** image is guest-less (Dom0 + DomD): it boots but shows **no
  instrument cluster / Android** on the displays. The full dual-display demo
  needs `-u -a`.
- **`-a` (Android) = `--aaos=auto`**: how DomA is produced is chosen by `--aaos`
  (`off` | `auto` | `source` | `prebuilt`). **Nothing has to be staged by hand.**
  `--aaos=source` builds AAOS from public sources (measured: 5 h 11 min and 272 GiB of
  workspace on a 32-core host — see *Starting with no AOSP checkout* in `docs/BUILD.md`)
  and the DomA
  guest kernel, its vendor-boot ramdisk and the DomD-side gRPC backends are all
  derived or built from that; `--aaos=prebuilt --aaos-prebuilt=<dir>` consumes a
  bundle instead and skips the AOSP build (minutes). See *How the DomA artifacts are
  produced* (`docs/BUILD.md`).
- **Behind an HTTP(S) proxy / restricted network?** Set `HTTPS_PROXY` (that is the
  variable `build.sh` reads; `--proxy=<url>` does the same) and you will usually also
  need `CONNECTIVITY_CHECK_URIS=""` and `REPO_SKIP_SELF_UPDATE=1` (see *Docker
  usage*).
- **Proxy on the host's loopback (`127.0.0.1:3128`, `localhost`)?** A bridged container
  cannot reach it (its `127.0.0.1` is itself), and `build.sh` refuses to start rather than
  let `docker build` fail on `apt-get` with no mention of the proxy. Either point
  `--proxy` at the Docker bridge gateway (`docker network inspect bridge`, usually
  `http://172.17.0.1:3128`, if your proxy listens there too), set `XT_DOCKER_NETWORK=host`,
  or leave the proxy variables unset and let Docker's own client config
  (`~/.docker/config.json` → `proxies.default`) supply it -- an explicit value in the
  environment overrides that config. Details in *Docker usage* (`docs/BUILD.md`).
- To vary the build, run moulin/ninja by hand, or share an sstate cache, see
  *Build configuration*, *Docker usage* (`docs/BUILD.md`) and *Manual build* (`docs/BUILD.md`).

## System requirements
- **Docker** on the host — the build runs inside `docker/Dockerfile.builder`
  (rouge image assembly; no root, no loop devices). **[moulin](https://github.com/xen-troops/moulin)
  and ninja run *inside* that container**, so the host does not need them for the
  Docker path; install moulin on the host only for the *Manual build* (`docs/BUILD.md`) below.
- **git** and **bash** on the host — `build.sh` checks for git, initialises the
  `external/` submodules, and runs `meta-rpi-sodev/scripts/sync-guest-pins.sh`
  before entering any container.
- **Disk**: ~400 GiB free for a full `-a` (AAOS) build — one measured Android 17 run used 336 GiB
  of workspace and AOSP dominates it; the
  guest-less default build (no AOSP) needs far less. Do not build on a
  filesystem with filename-length limits (e.g. ecryptfs).
- **RAM**: an AOSP/Yocto build is memory-hungry — for `-a` on Android 17, `soong_build`
  alone peaks at 42.6 GiB, so this tree is built with **64 GiB** and `--memory=48g`;
  32 GiB is not enough for `-a` (it is killed during soong analysis).
- Host is assumed Debian/Ubuntu (the Docker install links below are Ubuntu).

## Build configuration
`build.sh` drives moulin + ninja inside Docker. It takes V4H `build.sh`-style
flags (run `./build.sh -h`); the matching env vars are the fallback. **The
default build is Dom0(Zephyr) + DomD only — the DomU and DomA guests are
opt-in** (matching upstream `sodev-demo-workspace` commit `f3f0f8f7`, which
disables the heavy Android/Flatcar guests by default).

| Flag (env var) | Default | Effect |
|---|---|---|
| `--board=<board>` (`BOARD`) | **rpi5** | Which board to build: `rpi5` or `rpi4`. Selects `<board>-sodev.yaml`, and with it the SoC, MACHINE, Zephyr Dom0 board, passthrough set, physical memory map and board layer (`meta-xt-rpi5` or `meta-xt-rpi4` — never both). Raspberry Pi 5 is the reference platform; see *meta-xt-rpi4/README.md* for what the Raspberry Pi 4 configuration is verified against |
| `--dom0=<os>` (`DOM0_OS`) | **zephyr** | Selects the entire Dom0 component body: Zephyr xenstore-only Dom0 (disaggregated; DomD owns the toolstack) or the thin Linux control Dom0 (classic; Dom0 owns xl). Both flavours are HW-verified on a real RPi5, at both `--ram` values; the Zephyr flavour is the shipping default. See the verification note in *Boot process* (`docs/DESIGN.md`). |
| `--ram=<sku>` (`BOARD_RAM`) | **16g** (rpi5) / **8g** (rpi4) | Board SKU; the valid values and the default depend on `--board`. **rpi5: `16g`\|`8g`.** `16g` = the full 4-domain map (Dom0 512 + DomD 4096 + DomU 1024 + DomA 4096 = 9728 MiB). `8g` takes **DomD to 3072 MiB** (static-mem bank4 at `0x180000000` dropped) **and DomA to 3072 MiB**; Dom0/DomU keep their sizes, so the four total 7680 MiB and fit an 8 GB board. Splitting the reduction is measured, not a preference — see *Board RAM size* (`docs/DESIGN.md`). **rpi4: `8g`\|`4g`.** `8g` = Dom0 256 + DomD 1920 + DomU 1024 + DomA 2560; `4g` takes DomD to 1024 MiB (bank2 dropped, bank0 to 640 MiB) and DomA and DomU can no longer RUN at the same time — each fits alone, and `build.sh` says so |
| `-u`, `--domu` (`ENABLE_DOMU`) | **off** | Adds the AGL instrument-cluster DomU: Xen-aware kernel `linux-virtio-armv8` (p1) + AGL rootfs (p3). V4H-aligned minimal domu layer set (kernel via moulin; AGL rootfs via `build.sh`'s AGL bitbake) |
| `-a`, `--android` (`ENABLE_ANDROID`) | **off** | Include DomA (AAOS, p4 nested GPT). Alias for `--aaos=auto` — the mode chooses how DomA is produced |
| `-z`, `--domz` (`ENABLE_DOMZ`) | **off** | Adds DomZ, the Zephyr RTOS domain: Zephyr built for its own Xen-guest board (`xenvm`, GICv2, Xen PV console) out of a second west workspace, staged on p1 as `zephyr-domz.bin` and started by the xl toolstack from `/etc/xen/domz.cfg`. 16 MiB / 1 vCPU, no rootfs and **no new partition**, so the p2/p3/p4 layout is unchanged. Console: `xl console DomZ`. See [`domz/README.md`](domz/README.md) |
| `--domains-only` (`NINJA_TARGET=""`) | off | Build the domains but skip SD-image assembly |
| `--aaos=<mode>` (`AAOS_MODE`) | off (`-a`⇒auto) | `off` \| `auto` \| `source` \| `prebuilt`. **auto** = prebuilt if a bundle is found (default probe `<workspace>/aaos-prebuilt`), else source if an AOSP checkout is found, else off (or a hard error when DomA was required via `-a`) |
| `--aaos-prebuilt=<dir>` (`AAOS_PREBUILT_DIR`) | `<ws>/aaos-prebuilt` | Prebuilt AAOS bundle (`files/` + `images/` + `BUNDLE-INFO`, plus an optional `MANIFEST.md5`); consumed by `prebuilt`/`auto`. **Skips the AOSP source build entirely.** See *AAOS build modes* |
| (`AAOS_PREBUILT_ASSUME_BOARD`) | — | Accept a prebuilt bundle that has **no** `BUNDLE-INFO`, asserting -- unverified -- that it was built by this tree for this `--board`. A bundle without `BUNDLE-INFO` is otherwise refused; add the file instead (`board=`, `device=`, `android=`, `guest_kernel=`) |
| (`AAOS_GUEST_ANDROID`) / (`AAOS_GUEST_KERNEL`) | **17** / **6.18.32** | The DomA guest generation this tree builds and stages. A prebuilt bundle's `android=` / `guest_kernel=` are checked against them; the kernel version also names the staged kernel artifact (`aaos-android-kernel-xenbuilt-<ver>`, the recipe reads the same variable). Override only for a bundle whose p4 images were built against that other kernel |
| `--aaos-src=<dir>` (`AAOS_SRC_DIR`) | — | Reuse an existing AOSP checkout for `source` mode (skip the repo sync; still builds AOSP from it) |
| `--aaos-ref=<dir>` (`XT_AAOS_REF`) / `--aaos-kernel-ref=<dir>` (`XT_AAOS_KERNEL_REF`) | — | Repo **object mirrors** for the AOSP and AAOS-guest-kernel trees. `build.sh` seeds each checkout with `repo init --reference=<dir>` (manifest URL/rev/depth read from `rpi5-sodev.yaml`, so nothing is pinned twice) and moulin preserves the reference, so the syncs stay local. Accepts a repo client or a bare `*-project-objects` export. The AAOS analogue of `--west-cache` — see *Starting with no AOSP checkout* (`docs/BUILD.md`) |
| (`XT_AAOS_SYNC_JOBS`) | 4 | Parallelism of the **reference-mirror pre-sync** (only with `--aaos-ref`/`--aaos-kernel-ref`); raise it on a fast link, lower it behind a rate-limited proxy. The plain `source`-mode sync is moulin's own `repo` fetch and is not affected |
| (`XT_CACHE_MOUNTS`) | — | Extra `docker -v` mount specs (space-separated) bind-mounted into the builders, e.g. to share an sstate/downloads cache |
| `--rebuild-images` | off | Force-rebuild the `XT_DOCKER` image (`sodev-builder-rpi`). It never touches the V4H workspace's `sodev-builder` -- the two workspaces use different Dockerfiles and, since this series, different tags. Not needed for the Zephyr SDK 1.0.1 / python3.12 move that this series makes: the new tag has no pre-existing image, so the first build creates it already up to date. You need it only when `XT_DOCKER` points at an older image (a pre-rename `sodev-builder`, say), which fails the Zephyr build with `Could NOT find Python3: Found unsuitable version "3.10.12"` (Zephyr 4.4 sets `PYTHON_MINIMUM_REQUIRED 3.12`) |
| `--west-cache=<dir>` (`XT_WEST_CACHE_DIR`) | — | Point the Zephyr west fetches at a pre-populated reference workspace, so `west update` runs offline (the AAOS analogue is `--aaos-ref`). Used for both west workspaces: Dom0's and DomZ's |
| `--memory=<size>` (`XT_DOCKER_MEMORY`) | — (unlimited) | Cap each build container's RAM via docker `--memory` **and** `--memory-swap` (equal ⇒ no host-swap spill, so an unbounded moulin/AOSP/Yocto build cannot OOM the host), e.g. `24g` |
| (`XT_DOCKER_NETWORK`) | — (Docker bridge) | `--network` value for the build containers, e.g. `host`. Needed when the build has to reach a proxy or package mirror bound to the **host's** loopback: a bridged container's `127.0.0.1` is its own, not the host's. Applies to `docker run` and `docker build` |
| (`XT_DOCKER_RUN_OPTS`) | — | Extra `docker run` options applied verbatim to every builder, for anything `--memory` does not cover (e.g. `--cpus 8`) |
| (`XT_DOCKER`) | `sodev-builder-rpi` | Tag of the unified build image. Deliberately not `sodev-builder`, the tag the V4H `sodev-demo-workspace` uses: on a host that builds both, one shared name would let `--rebuild-images` here replace the V4H image |
| (`AGL_DOCKER`) | `$XT_DOCKER` | Image for the DomU AGL bitbake. Follows `XT_DOCKER`; set it to the AGL-official `docker-worker` to use that instead (then `docker pull` it yourself -- `build.sh` builds only its own tag) |
| `--sstate=<dir>` (`XT_SSTATE_DIR`) | — | Reuse an external Yocto sstate cache; bind-mounted into the builders Must name an **existing** directory (a typo would otherwise rebuild everything against an empty cache); an existing but empty one is accepted with a note. |
| `--dl=<dir>` (`XT_DL_DIR`) | — | Reuse an external Yocto downloads dir; bind-mounted into the builders Must name an existing directory, as `--sstate`. |
| (`BB_HASHSERVE`) | — (bitbake `auto`: a private server per build) | Hash-equivalence server for **every** bitbake in this build -- the moulin Yocto domains and the DomU AGL bitbake alike (both containers get the variable) -- so equivalent tasks are reused across workspaces and machines: `unix:///path/to/hashserve.sock` (bind-mount the socket's directory with `XT_CACHE_MOUNTS`) or `host:port` (reachable from the container's network). Passed through to bitbake as-is; bitbake already excludes it from task hashes |

DomU / DomA gating follows the V4H `prod-devel-rcar4_new.yaml` idiom: the
`meta-xt-doma` layer is always in `bblayers`, and `ENABLE_ANDROID=no` masks all
its recipes via `BBMASK` (`XT_DOMA_BBMASK`), so a guest-less build never parses
the AAOS-prebuilt SRC_URI and never references an unbuildable provider. See the
in-file comments of `rpi5-sodev.yaml` (the authoritative documentation).

## Build — details & options
The *Quick start* above is the happy path (`./build.sh` → `full.img`); *Build
configuration* lists the flags/flavours. This section covers the Docker build
environment, running moulin + ninja by hand, and staging the AAOS prebuilts for
`-a`.

The Yocto domains — DomD, the thin Linux Dom0 flavour and the DomU kernel — generate an SPDX 3.0.1
SBOM: poky enables `create-spdx` by default (`INHERIT_DISTRO` in `defaultsetup.conf`) and this
workspace keeps it on. Each domain writes its documents to `tmp/deploy/spdx/3.0.1/` in that build
directory, plus a per-image SBOM beside the image. They are deploy artifacts and are never part of a
rootfs. The DomU AGL rootfs is a separate bitbake with its own poky and emits SPDX 2.2. If a local
build ever needs the SBOM off, add `INHERIT:remove = "create-spdx"` to that build's `conf/local.conf`
and run bitbake inside the builder. Note the two builds differ in how long that edit lives: `build.sh`
deletes and regenerates `yocto/build-dom*/conf` on every run, so an edit there is gone next run, while
`agl/build/conf/local.conf` keeps it: `aglsetup.sh` skips configuration generation altogether once a
`conf/local.conf` is there, and only `-f` overwrites it.


See also:

- [Docker usage](docs/BUILD.md) — the container the build runs in, proxies, offline mirrors and shared caches.
- [Manual build (moulin + ninja, upstream style)](docs/BUILD.md) — driving moulin and ninja directly instead of through build.sh.
- [How the DomA artifacts are produced](docs/BUILD.md) — where the Android guest kernel, ramdisk, p4 images and the DomD-side gRPC backends come from, and the three --aaos modes.
## Flashing the SD card
```sh
sudo dd if=full.img of=/dev/<sd-dev> bs=4M conv=fsync status=progress
```
**NOTE:** Be sure to identify `<sd-dev>` correctly. To identify the SD card,
plug/unplug it and check `/dev/` for devices that were added/removed.

**NOTE:** If auto-mount is enabled, make sure any existing SD-card partitions
are unmounted before writing.

The image is GPT: a FAT boot partition (RPi firmware, u-boot + `boot.scr`, Xen,
Zephyr Dom0 binary, domain kernels/initramfs, device trees and guest boot
payloads), rootfs partitions for the Linux domains, and — when
`ENABLE_ANDROID=yes` — an Android partition (`PARTLABEL=android`, nested GPT
assembled the V4H way from the `doma`/`doma_kernel` moulin components).

## Hardware & displays
- Raspberry Pi 5 (BCM2712 + RP1) — the reference platform. Both the **16 GB** and the
  **8 GB** SKU are supported; `--ram=16g|8g` selects which (16g is the default). The
  full 4-domain build comes to 9728 MiB on 16g and 7680 MiB on 8g — see *Board RAM size*
  (`docs/DESIGN.md`). Official 27 W (5 A) PSU required — 3 A supplies negotiate low
  current and corrupt the HDMI scanout.
- Raspberry Pi 4 Model B (BCM2711), via `--board=rpi4`. **8 GB** and **4 GB** SKUs;
  four domains need the 8 GB board. Every USB-A port is behind the VL805 xHCI, so the
  touch panel depends on passing that controller through. What is and is not verified on
  this board, and the open items, are listed in
  `meta-rpi-sodev/meta-xt-rpi4/README.md`.
- HDMI-A-1: 1920x720 cluster panel (forced CVT modeline — its EDID does not come through).
- HDMI-A-2: 1920x720 IVI panel (forced modeline transcribed from its EDID). This panel
  answers the EDID read **3.7 s late**, which used to leave it dark for the whole
  session; weston's start is held until the DRM mode lists settle. See *Late EDID on
  HDMI-A-2* below.
- Native USB touch on the IVI panel (RP1 passthrough + virtio-tablet forward).

## Domain / CPU map

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — which domain owns which pCPU and which hardware block.

## Board RAM size

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — the 16 GB and 8 GB memory maps, and why the 8 GB reduction is split across DomD and DomA.

## Software versions
| Component | Version |
|---|---|
| Yocto / OpenEmbedded | Wrynose 6.0 LTS (bitbake 2.18, oe-core `wrynose`, meta-raspberrypi master @6d81e22c) |
| Hypervisor | **Xen 4.22.0 — interim local `xen_4.22.bb`** (meta-virtualization master at `526c9725` stops at 4.21; the copy lives in `meta-xt-common/meta-xt-domx` so both board products see it, and is to be submitted upstream and deleted once accepted) + an ordered patch series in the shared `recipes-extended/xen-common` recipe (29 `.patch` files, required by both Dom0 flavours' Xen bbappends) plus the `0025` dom0less static-mem xenstore-page patch, which each board layer carries a copy of and both apply (**30 applied on rpi5, 29 on rpi4** -- that board excludes `4.22-0002`, which routes the BCM2712 MIP MSI it has no equivalent of; the exclusion and its reasoning are in `meta-xt-rpi4`'s bbappend). Of the 29, **23 come from the xen-troops fork** — 14 carried verbatim and 9 (`0004`, `0008`, `0010`, `0013`, `0016`, `0018`, `0019`, `0022`, `0024`) with local modifications declared on a `Local-Modifications:` line — and **6 are authored here** (`4.22-000{1..6}`). Moving 4.21 → 4.22 left 25 of the 29 untouched: `0008`/`0018` were regenerated against stable-4.22 (context drift only, emitted code identical) and `0022`/`4.22-0001` were rebased, each recording it on its `Local-Modifications:` line. The fork-derived patches keep their original authors and carry `Upstream-Status: Inappropriate` with an `Origin:` line naming the fork commit, because xen-troops is a downstream fork and not the upstream of Xen. The six authored here are build-verified (compile+link clean on arm64 Xen 4.22.0); three carry `Upstream-Status: Pending` (`0002`, `0005`, `0006` -- `0006` is the 4.22 dom0less phandle regression fix this series exists on top of, measured on hardware) and three carry `Upstream-Status: Inappropriate` because they are deliberately downstream: `0001` is the RPi5/BCM2712 working delta, `0003` reverts upstream hardening `2fbd7e609e` to re-permit bufioreq on Arm for this virtio-heavy configuration -- a security relaxation for the demo, not for upstream -- and `0004` locks a field that only the fork's legacy-PCI series (`0013`/`0019`) creates, so it cannot be submitted as-is |
| Virtualization layer | **meta-virtualization, pinned** (`781735b9`) — fetched by moulin at build time, not vendored. It supplies `xen.inc`/`xen-hypervisor.inc`/`xen-tools.inc` but **not** a 4.22 version recipe, so `xen_4.22.bb` / `xen-tools_4.22.bb` (PV `4.22.0+stable` / `4.22+stable`, xenbits `stable-4.22` @ `d45d5687f1`) are carried locally in `meta-xt-common/meta-xt-domx` and selected via `PREFERRED_VERSION_xen` / `PREFERRED_VERSION_xen-tools`. Both are interim, pending upstream acceptance |
| Dom0 (zephyr) | Zephyr xenstore server (patch series under `meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/`, applied on the upstream Zephyr Dom0 tree) |
| Dom0 (linux) / DomD kernel | Linux 6.18.33 (`linux-raspberrypi`) |
| DomD graphics | Mesa 26.0.5, weston 15.0.0 (kiosk-shell), libdrm 2.4.131 |
| DomD device-model | QEMU 7.0.0 (Xen IOREQ, virtio-gpu-gl, vhost-net/-vsock) |
| DomU guest | AGL SoDeV instrument cluster (`agl-cluster-demo-flutter-guest`, kernel 6.8.0-rc1 — historically aligned with the V4H AGL SoDeV DomU kernel: torvalds linux `6613476e` + the single Xen backend-domid patch, plus the RPi5-specific `xen-force-grant.cfg`; the current V4H submodule has since moved to a 6.12-series DomU kernel; MACHINE virtio-aarch64) |
| DomA guest | AAOS (`aosp_xenvm_trout_rpi5_arm64` / `aosp_xenvm_trout_rpi4_arm64`), Xen virtio (CONFIG_XEN / XEN_VIRTIO). A V4H-built AAOS image boots unmodified (portability proof) |
| DomZ guest | Zephyr 4.4.1 (the same manifest and pins as Dom0 — its own west workspace, brought to 4.4.1 by `apply-zephyr-patches.sh --manifest-only`), board `xenvm` (GICv2, Xen PV console), Zephyr SDK 1.0.1 / `aarch64-zephyr-elf`. Application in [`domz/`](domz/README.md) |


See also:

- [Patch trailers](docs/DESIGN.md) — what Upstream-Status / Origin / Local-Modifications on the in-tree patches mean.
## Repository layout
```
.
├── build.sh                 # orchestrator (Docker; mirror of AGL sodev-demo-workspace/build.sh)
├── rpi5-sodev.yaml          # moulin entry (Raspberry Pi 5): Dom0/DomD/DomU/DomA/DomZ build + SD-image wiring
├── rpi4-sodev.yaml          # moulin entry (Raspberry Pi 4 / BCM2711), same domain set; ./build.sh --board=rpi4
├── docker/                  # unified sodev-builder-rpi build image (built on demand)
├── docs/                    # BUILD.md (build detail) / DESIGN.md (why) / TROUBLESHOOTING.md
├── domz/                    # DomZ = the Zephyr RTOS guest (-z)
│   ├── app/                 #   Zephyr application for the `xenvm` board
│   ├── tools/               #   QEMU harness (xl create on a PC) + its Yocto layer
│   └── README.md            #   what the domain is, and how to bring it up
├── external/
│   ├── meta-xt-prod-devel-rpi5/   # submodule: pristine xen-troops base (byte-identical)
│   └── sodev-demo-workspace/      # submodule: AGL SoDeV — DomU/DomA source of truth (V4H)
├── meta-rpi-sodev/          # ALL RPi5/Xen delta, consolidated on the upstream meta-xt-* layout
│   ├── meta-xt-common/
│   │   ├── meta-xt-dom0-linux/      # thin LINUX Dom0 image, xl-create service chain, xen-tools cfg
│   │   ├── meta-xt-dom0-zephyr/     # ZEPHYR Dom0 patch series (Zephyr 4.4.1 +
│   │   │                            #   zephyrproject-rtos xenlib, xenstore server, dom_cfg,
│   │   ├── meta-xt-driver-domain/   # DomD image (p2 rootfs), kernel (vhost_xen/vc4), weston, qemu, xen-network
│   │   ├── meta-xt-domu/            # DomU xl cfg + cluster recipes + virtio kernel
│   │   ├── meta-xt-domz/            # DomZ xl cfg (domz.cfg) + xl-create-domz.service
│   │   ├── meta-xt-doma/            # DomA xl cfg + AAOS host services + guest binaries
│   │   ├── meta-xt-domx/            # shared cross-guest recipes (libc-headers, base-files, ...)
│   │   ├── meta-xt-{qemu,security}/ # vendored upstream
│   │   └── recipes-extended/xen-common/   # shared Xen 4.22 hypervisor patch series (both Dom0 flavours)
│   ├── meta-xt-rpi5/                # RPi5 BSP: u-boot/TFA/boot.scr, Xen 4.22 bbappend + patch series, xen dtso, kernel DT/cfg
│   ├── meta-xt-rpi4/                # RPi4 BSP, the sibling of the above (BCM2711). Mutually exclusive with it
│   ├── xt-prod-devel-rpi5-domd/     # vendored upstream DomD product layer
│   ├── meta-rpi-sodev-devel/        # opt-in diagnostic/debug/prototype layer (NOT in the shipping build; p4-tool etc.)
│   └── scripts/                     # helpers: guest-pin sync (sync-guest-pins)
└── tools/                    # PC-side checks that need no build (run before a board).
    │                            Workspace-level: they read build.sh/rpi5-sodev.yaml and
    │                            more than one layer, so they are NOT under
    │                            meta-rpi-sodev/scripts/ (which is layer-scoped). No
    │                            recipe references them; they are developer/CI tools.
    ├── check-memory-map.py         # DomD static-mem + Dom0 bank[0] placement, both --ram values
    ├── check-yaml-drift.py         # the two product yamls share ~750 lines by copy; fails on
    │                                   unrecorded divergence (yaml-drift-baseline.txt records the
    │                                   74 differences that are there by design)
    ├── check-domz.sh               # every DomZ check that works without hardware, in one
    │                               #   command (check-yaml-drift + the domz.cfg memory invariant +
    │                               #   checkpatch + moulin graph + the xenvm guest build).
    │                               #   To go further and actually BOOT DomZ on a PC, see
    │                               #   domz/tools/qemu-xen-domz.sh (Xen + Dom0 in QEMU)
    └── compare-sd-image.py         # compare a fresh SD image against one that booted, judging
                                        deterministic / timestamp-contaminated / deliberately-
                                        different artifacts by different criteria
```

## Zephyr Dom0 (DOM0_OS=zephyr, the default)

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — what the default Dom0 does and does not do.

## Boot process

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — the order the four domains come up in, per flavour.

## Differences vs the V4H AGL SoDeV (`sodev-demo-workspace`)

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — what this port changed relative to the R-Car V4H reference.

## Testing / console access
| Target | Access |
|---|---|
| Dom0 (zephyr) | UART: the RPi5 debug UART is muxed — press `Ctrl-A` three times to cycle consoles; Zephyr shell (`xu list`, `xu console <id>`) |
| Dom0 (linux) | **UART**: physical debug UART — press `Ctrl-A` three times to cycle input to `DOM0` (Linux login). **SSH**: Dom0 sits on the private point-to-point link `192.168.0.1` (the DomD netfront is deliberately *not* bridged into the flat segment — bridging wedges DomD's xenbus). `sshd` is socket-activated. Reach it from the bench PC via DomD's IP forwarding: `sudo ip route add 192.168.0.0/24 via 192.168.10.10 && ssh root@192.168.0.1` |
| DomD | **SSH** (primary): `ssh root@192.168.10.10` — DomD runs the toolstack, so `xl list` / `xl console <domU/domA>` run from here. **UART**: DomD is a dom0less **vpl011** domain (console → hypervisor ring), so `xl console 1` / `xu console 1` cannot attach it (no PV console ring/evtchn is allocated for dom0less vpl011). On the debug UART press `Ctrl-A` three times to cycle input to `DOM1` (`raspberrypi5-domd login:`); or read its log with `xl dmesg \| grep DOM1`. |
| DomU (AGL) | `ssh root@192.168.10.12`; or `xl console 3` from the toolstack domain (`domu login:`) |
| DomZ (Zephyr) | **`xl console DomZ`** from the toolstack domain (DomD in the zephyr flavour, Dom0 in the linux one) — Zephyr's Xen **PV console**, which is why the `xenvm` board is used rather than a vpl011 dom0less domain. `xenconsole` needs a tty, so over ssh use `ssh -tt root@192.168.10.10 'xl console DomZ'`. No network, no display: this console is the only interface. Exit with `Ctrl-]` |
| DomA (AAOS) | `adb connect 192.168.10.13:5555` (Android has no sshd); `adb logcat` for logcat. Serial console: **`xl console 2`** from the toolstack domain — DomA's `hvc0` is the Xen **PV console**, and AAOS init's `console` service puts a shell on it (prompt `console:/ $`, uid 2000 `shell`). `xenconsole` calls `tcsetattr()` on stdin, so it needs a tty: over ssh use `ssh -tt root@192.168.10.10 'xl console 2'`. The `virtconsole` sockets in `doma.cfg` are **inert** — see the note below. |


See also:

- [Serial console — the single debug UART is Xen-multiplexed (Ctrl-A x3)](docs/TROUBLESHOOTING.md) — reaching each domain's console, and why xl console needs a tty.
- [Health checks (xenstore / teardown regression sanity)](docs/TROUBLESHOOTING.md) — quick checks to run after a change.
## Build & hardware verification (RPi5)
**Both Dom0 flavours build end-to-end** from a clean checkout to a complete,
loopback-verified 4-domain SD image: the single `sodev-builder-rpi` image produces
`full.img` with the four-partition GPT (p1 boot carrying the flavour's Dom0
payload — `zephyr.bin` or the thin-Linux Dom0 initramfs, p2/p3 ext4 domain
rootfs, p4 the AAOS 12-partition nested GPT), verified for both `--dom0=zephyr`
and `--dom0=linux`.

On **hardware**, the default **Zephyr-Dom0** disaggregated stack is verified
(dual display, guest create from DomD's toolstack, the *Health checks* (`docs/TROUBLESHOOTING.md`) above):
the AGL cluster renders on HDMI-A-1 and the shipping **`--aaos=prebuilt` AAOS**
renders on HDMI-A-2 (all guest modules load, SurfaceFlinger up) — the guest
kernel and the `super.img` vendor_dlkm modules must come from one coherent build
(same `module_layout` ABI; see *How the DomA artifacts are produced* (`docs/BUILD.md`)). The **thin Linux-Dom0** flavour
has since been booted end to end on both boards on this tree (P2 and P3 below).
The Zephyr full-image HW checklist. **[4.22] The list below was first measured on Xen
4.21.** On **Xen 4.22** the four verification patterns of this tree were run on hardware
on 2026-08-18 and all passed -- RPi4 and RPi5 x Zephyr-Dom0 and thin-Linux-Dom0 -- with
`xu list` answering in the Zephyr-Dom0 flavour, which is the one place a missed
domctl-ABI bump would show. What that campaign did **not** re-measure, and is therefore
still open: the dual display was confirmed only as configuration (both connectors
`connected`, weston defining two outputs), **adb over TCP could not be reached on the
RPi5 guest**, and touch input was not exercised. The per-item list:
- Xen 4.21 boots (0 panics); all 4 domains auto-start; qemu device-models auto-spawn.
- Dual display + native touch, no scanout artifacts.
- SSH from the PC to DomD/DomU, adb to DomA; consoles for all domains.
- DomA management IP (192.168.10.13) via dnsmasq static lease — no manual step.
- Full 4-domain + hypervisor log audit performed; the actionable items are
  fixed in-tree (legacy Dom0 qdisk unit masked; prebuilt dumpstate backend not
  auto-enabled until rebuilt against wrynose libxml2).

As a portability proof, the **V4H-built DomA image boots unmodified**
on this stack (guest kernel/ramdisk/super swapped as binaries — no rebuild).

**DomZ (`-z`) is verified on hardware in all four verification patterns** (RPi4 and
RPi5, Zephyr-Dom0 and thin-Linux-Dom0): `xl list` shows the domain at 16 MiB / 1 vCPU,
`xl console DomZ` prints `DomZ up: Zephyr 4.4.1 as Xen DomU (AGL SoDeV)` and the
heartbeat, and the interval measured 10 s with no missed ticks. The unit that creates it
lands in the toolstack domain of either flavour (DomD for Zephyr-Dom0, the thin Dom0 for
the Linux one) and is `active` in both.

On a PC, before that:

- the moulin graph resolves for every flag combination (`-z`, both Dom0 flavours, with
  and without `-u`/`-a`, both `--ram` values) and `ninja image-full` has a rule for
  every artifact;
- the DomZ image builds through the real path (`moulin` + `ninja domz`, second west
  workspace, Zephyr SDK 1.0.1) for the `xenvm` board -- 304 KB of the domain's 16 MiB
  (1.86%; the figure is Zephyr's own RAM report, not the size of zephyr.bin, which is
  44 KB);
- bitbake parses the whole layer set with the new layer in it (3350 recipes, 0 errors)
  and builds `xt-xen-cfg-domz`;
- **the whole SD image builds end to end** (`./build.sh -z` -> `full.img`) and its
  contents check out without root or loop devices: p1 (FAT) carries `zephyr-domz.bin`
  byte-identical to the built artifact (same md5), and the DomD rootfs that becomes p2
  carries `/etc/xen/domz.cfg`, `/usr/lib/systemd/system/xl-create-domz.service` and the
  `multi-user.target.wants` symlink that auto-enables it;
- **DomZ was created and booted under QEMU first** -- aarch64 with Xen 4.21.1-pre and a
  minimal Linux Dom0 (`domz/tools/qemu-xen-domz.sh`): `xl create` accepted the image,
  `xl list` showed `DomZ ... -b----` (idle, i.e. healthy) and `xl console DomZ` printed
  the banner (that run predates the move to 4.4.1). The image format holds for the
  reason libxc's loaders say it should: Zephyr's arm64 output carries a Linux arm64
  Image header (`"ARM\x64"` at offset 0x38), which `xc_dom_probe_zimage64_kernel()`
  claims (the multiboot `bin` loader would have rejected a bare blob).

The bring-up order and how to iterate over `scp` **without reflashing the SD card** are
in [`domz/README.md`](domz/README.md); the failure signatures are in *DomZ does not
start* (`docs/TROUBLESHOOTING.md`).

## Known issues

Moved to [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptom -> cause -> what to do, with the logs each was diagnosed from.

## DomD compositor startup and rootfs (V4H-aligned)

Moved to [`docs/DESIGN.md`](docs/DESIGN.md) — why weston is a systemd unit and why the DomD rootfs is SD p2.

## Security note (review before deploying outside a closed lab)
The image sets dev-convenience IMAGE_FEATURES (`empty-root-password`,
`allow-empty-password`, `allow-root-login`; a debug-tweaks-equivalent posture) and
lab RFC1918 addresses in the network configs. No private keys or
credentials are committed (SSH host keys are generated on device, not shipped).
This posture is a deliberate lab/demo configuration matching the AGL
`agl-devel` feature and the V4H SoDeV reference implementation it derives from;
it is not intended for production. Harden these (real root credentials,
`PermitRootLogin no`, no empty passwords) before any non-lab deployment.

Two further lab-only interfaces are worth calling out explicitly, because they are
not password-protected at all:

- **qemu monitor.** `doma.cfg` and `domu.cfg` each expose a qemu HMP monitor on a
  loopback TCP port (`-monitor telnet:127.0.0.1:<port>,server,nowait`). Anything that
  can reach DomD's loopback has full control of that guest's device model, including
  the ability to terminate it. Bind it to a permission-restricted unix socket, or
  remove it, before any non-lab deployment.
- **DomA console.** `doma.cfg` exposes six `virtconsole` backends as unauthenticated
  UNIX sockets in DomD (`/run/android_vm_virtconsole*`). They currently carry no data
  (the Xen PV console takes `hvc0` first — see *Serial console* (`docs/TROUBLESHOOTING.md`) above), so they are not
  a live exposure today, but nothing authenticates a connection and the intended
  mapping was an in-guest shell. Remove them, or move them to a permission-restricted
  path, before any non-lab deployment. Note that DomA's actual shell — `xl console 2`,
  prompt `console:/ $` — is reachable by anything that can run the toolstack in DomD,
  and `adb` is open on `192.168.10.13:5555` with no authentication.

`xen,static-mem`-related hypervisor hardening is also relaxed for the demo: the
`4.22-0003` patch reverts an upstream restriction on buffered ioreq for Arm so the
DomD device model can serve the guests. That revert is deliberate and is documented in
the patch header; it should not be carried into a production hypervisor.

## References
- V4H AGL SoDeV (DomU/DomA source of truth): <https://github.com/automotive-grade-linux/sodev-demo-workspace>
- RPi5 Xen base project: <https://github.com/xen-troops/meta-xt-prod-devel-rpi5>
- Zephyr Dom0: <https://github.com/xen-troops/zephyr-dom0-xt>
- meta-virtualization (stock Xen recipes): <https://git.yoctoproject.org/meta-virtualization>
- moulin build system: <https://github.com/xen-troops/moulin>
