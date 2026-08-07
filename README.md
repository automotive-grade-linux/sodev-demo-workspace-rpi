# sodev-demo-workspace-rpi

> **Documentation map** — [`README.md`](README.md) build and run |
> [`docs/BUILD.md`](docs/BUILD.md) build details |
> [`docs/DESIGN.md`](docs/DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) when it does not work
A **Raspberry Pi 5** port of the AGL (Automotive Grade Linux) SoDeV
disaggregated-cockpit demo (R-Car V4H / Sparrow Hawk): **Xen 4.21** running a
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
  Xen 4.21.0 (stock meta-virtualization recipe + RPi5/virtio patch series)
  on Yocto Wrynose 6.0 LTS / Linux 6.18.33

  DOM0_OS=zephyr (default — disaggregated control plane)
  |- Dom0 : Zephyr, xenstore server only (no toolstack, no drivers)      [1 vCPU  @ pCPU 0]
  |- DomD : dom0less direct-mapped driver domain — vc4/v3d GPU, RP1,
  |         SDHCI, Mesa 26.0.5 + weston 15.0.0 + qemu 7.0.0 device-models,
  |         AND the xl toolstack that creates DomU/DomA                  [2 vCPUs @ pCPU 0-1]
  |- DomU : AGL instrument cluster (Flutter cluster demo) -> HDMI-A-1    [1 vCPU  @ pCPU 1]
  |- DomA : Android Automotive OS (trout/xenvm)           -> HDMI-A-2    [2 vCPUs @ pCPU 2-3]

  DOM0_OS=linux (alternative — classic control plane)
  |- Dom0 : thin Linux control domain (xl toolstack, SD owner); DomD is
            still dom0less; Dom0's xl service chain creates DomU/DomA.
```
The diagram shows the full 4-domain cockpit; **the default build is Dom0 + DomD
only** — the DomU and DomA guests are opt-in (`-u`/`-a`, see *Build configuration*).

## Quick start (build the SD image)

Everything runs inside Docker: `build.sh` builds the container image on demand,
then runs moulin + ninja inside it. You only need **Docker** on the host (see
*System requirements*).

```sh
# 1. Get the sources (this repo uses git submodules)
git clone <this repository> && cd sodev-demo-workspace-rpi
git submodule update --init --recursive

# 2. Build the SD image  ->  full.img   (build.sh applies the Zephyr Dom0 patches for you)
./build.sh                       # DEFAULT: Dom0(Zephyr) + DomD   (guest-less, fast)
# ./build.sh -u                  # + DomU (AGL instrument cluster)
# ./build.sh -u -a               # + DomU + DomA (AAOS) = full 4-domain cockpit
# ./build.sh --dom0=linux -u -a  # thin Linux control Dom0 instead of Zephyr

# 3. Flash it to an SD card (double-check <sd-dev>!)
sudo dd if=full.img of=/dev/<sd-dev> bs=4M conv=fsync status=progress
```

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
  usage*). If the proxy listens on the **host's** loopback, also set
  `XT_DOCKER_NETWORK=host` — a bridged container cannot reach it otherwise.
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
- **Disk**: ~300 GiB free for a full `-a` (AAOS) build — one measured run used 272 GiB
  of workspace and AOSP dominates it; the
  guest-less default build (no AOSP) needs far less. Do not build on a
  filesystem with filename-length limits (e.g. ecryptfs).
- **RAM**: an AOSP/Yocto build is memory-hungry — 16 GiB is marginal, ≥32 GiB is
  comfortable for `-a`.
- Host is assumed Debian/Ubuntu (the Docker install links below are Ubuntu).

## Build configuration
`build.sh` drives moulin + ninja inside Docker. It takes V4H `build.sh`-style
flags (run `./build.sh -h`); the matching env vars are the fallback. **The
default build is Dom0(Zephyr) + DomD only — the DomU and DomA guests are
opt-in** (matching upstream `sodev-demo-workspace` commit `f3f0f8f7`, which
disables the heavy Android/Flatcar guests by default).

| Flag (env var) | Default | Effect |
|---|---|---|
| `--dom0=<os>` (`DOM0_OS`) | **zephyr** | Selects the entire Dom0 component body: Zephyr xenstore-only Dom0 (disaggregated; DomD owns the toolstack) or the thin Linux control Dom0 (classic; Dom0 owns xl). Both flavours are HW-verified on a real RPi5, at both `--ram` values; the Zephyr flavour is the shipping default. See the verification note in *Boot process* (`docs/DESIGN.md`). |
| `--ram=16g\|8g` (`BOARD_RAM`) | **16g** | Target Raspberry Pi 5 SKU. `16g` = the full 4-domain map (Dom0 512 + DomD 4096 + DomU 1024 + DomA 4096 = 9728 MiB). `8g` takes **DomD to 3072 MiB** (static-mem bank4 at `0x180000000` dropped) **and DomA to 3072 MiB**; Dom0/DomU keep their sizes, so the four total 7680 MiB and fit an 8 GB board. Splitting the reduction is measured, not a preference — see *Board RAM size* (`docs/DESIGN.md`) |
| `-u`, `--domu` (`ENABLE_DOMU`) | **off** | Adds the AGL instrument-cluster DomU: Xen-aware kernel `linux-virtio-armv8` (p1) + AGL rootfs (p3). V4H-aligned minimal domu layer set (kernel via moulin; AGL rootfs via `build.sh`'s AGL bitbake) |
| `-a`, `--android` (`ENABLE_ANDROID`) | **off** | Include DomA (AAOS, p4 nested GPT). Alias for `--aaos=auto` — the mode chooses how DomA is produced |
| `--domains-only` (`NINJA_TARGET=""`) | off | Build the domains but skip SD-image assembly |
| `--aaos=<mode>` (`AAOS_MODE`) | off (`-a`⇒auto) | `off` \| `auto` \| `source` \| `prebuilt`. **auto** = prebuilt if a bundle is found (default probe `<workspace>/aaos-prebuilt`), else source if an AOSP checkout is found, else off (or a hard error when DomA was required via `-a`) |
| `--aaos-prebuilt=<dir>` (`AAOS_PREBUILT_DIR`) | `<ws>/aaos-prebuilt` | Prebuilt AAOS bundle (`files/` + `images/` + `MANIFEST.md5`); consumed by `prebuilt`/`auto`. **Skips the AOSP source build entirely.** See *AAOS build modes* |
| `--aaos-src=<dir>` (`AAOS_SRC_DIR`) | — | Reuse an existing AOSP checkout for `source` mode (skip the repo sync; still builds AOSP from it) |
| `--aaos-ref=<dir>` (`XT_AAOS_REF`) / `--aaos-kernel-ref=<dir>` (`XT_AAOS_KERNEL_REF`) | — | Repo **object mirrors** for the AOSP and AAOS-guest-kernel trees. `build.sh` seeds each checkout with `repo init --reference=<dir>` (manifest URL/rev/depth read from `rpi5-sodev.yaml`, so nothing is pinned twice) and moulin preserves the reference, so the syncs stay local. Accepts a repo client or a bare `*-project-objects` export. The AAOS analogue of `--west-cache` — see *Starting with no AOSP checkout* (`docs/BUILD.md`) |
| (`XT_CACHE_MOUNTS`) | — | Extra `docker -v` mount specs (space-separated) bind-mounted into the builders, e.g. to share an sstate/downloads cache |
| `--memory=<size>` (`XT_DOCKER_MEMORY`) | — (unlimited) | Cap each build container's RAM via docker `--memory` **and** `--memory-swap` (equal ⇒ no host-swap spill, so an unbounded moulin/AOSP/Yocto build cannot OOM the host), e.g. `24g` |
| (`XT_DOCKER_NETWORK`) | — (Docker bridge) | `--network` value for the build containers, e.g. `host`. Needed when the build has to reach a proxy or package mirror bound to the **host's** loopback: a bridged container's `127.0.0.1` is its own, not the host's. Applies to `docker run` and `docker build` |
| (`XT_DOCKER_RUN_OPTS`) | — | Extra `docker run` options applied verbatim to every builder, for anything `--memory` does not cover (e.g. `--cpus 8`) |
| `--sstate=<dir>` (`XT_SSTATE_DIR`) | — | Reuse an external Yocto sstate cache; bind-mounted into the builders Must name an **existing** directory (a typo would otherwise rebuild everything against an empty cache); an existing but empty one is accepted with a note. |
| `--dl=<dir>` (`XT_DL_DIR`) | — | Reuse an external Yocto downloads dir; bind-mounted into the builders Must name an existing directory, as `--sstate`. |
| (`XT_DISABLE_SPDX`) | — (SBOM on) | Set to any non-empty value to drop `create-spdx` from `INHERIT` for the Yocto components. SBOM generation is **on by default** — the images ship SPDX documents — so this is only an escape hatch for a faster iteration cycle or for working around an SPDX-tool problem, never for a release build |

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
- Raspberry Pi 5 (BCM2712 + RP1). Both the **16 GB** and the **8 GB** SKU are
  supported; `--ram=16g|8g` selects which (16g is the default). The full 4-domain
  build comes to 9728 MiB on 16g and 7680 MiB on 8g — see *Board RAM size* (`docs/DESIGN.md`).
  Official 27 W (5 A) PSU required — 3 A supplies negotiate low current and
  corrupt the HDMI scanout.
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
| Hypervisor | **Xen 4.21.0 — stock meta-virtualization recipe** + an ordered patch series in the shared `recipes-extended/xen-common` recipe (28 `.patch` files, required by both Dom0 flavours' Xen bbappends) plus the RPi5-only `0025` dom0less static-mem xenstore-page patch in `meta-xt-rpi5` (29 applied to the hypervisor). Of the 28, **23 come from the xen-troops fork** — 16 carried verbatim and 7 (`0004`, `0008`, `0010`, `0013`, `0016`, `0019`, `0024`) with local modifications declared on a `Local-Modifications:` line — and **5 are authored here** (`4.21-000{1..5}`). The fork-derived patches keep their original authors and carry `Upstream-Status: Inappropriate` with an `Origin:` line naming the fork commit, because xen-troops is a downstream fork and not the upstream of Xen. The five authored here are build-verified (compile+link clean on arm64 Xen 4.21.0); three carry `Upstream-Status: Pending` (`0002`, `0004`, `0005`) and two carry `Upstream-Status: Inappropriate` because they are deliberately downstream: `0001` is the RPi5/BCM2712 working delta, and `0003` reverts upstream hardening `2fbd7e609e` to re-permit bufioreq on Arm for this virtio-heavy configuration -- a security relaxation for the demo, not for upstream |
| Virtualization layer | **meta-virtualization, pinned** (`781735b9`) — fetched by moulin at build time, not vendored; the stock `xen_4.21.bb` (PV `4.21.0+stable`, xenbits `stable-4.21` @ `1c72306b`) is selected via `PREFERRED_VERSION_xen` |
| Dom0 (zephyr) | Zephyr xenstore server (patch series under `meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/`, applied on the upstream Zephyr Dom0 tree) |
| Dom0 (linux) / DomD kernel | Linux 6.18.33 (`linux-raspberrypi`) |
| DomD graphics | Mesa 26.0.5, weston 15.0.0 (kiosk-shell), libdrm 2.4.131 |
| DomD device-model | QEMU 7.0.0 (Xen IOREQ, virtio-gpu-gl, vhost-net/-vsock) |
| DomU guest | AGL SoDeV instrument cluster (`agl-cluster-demo-flutter-guest`, kernel 6.8.0-rc1 — historically aligned with the V4H AGL SoDeV DomU kernel: torvalds linux `6613476e` + the single Xen backend-domid patch, plus the RPi5-specific `xen-force-grant.cfg`; the current V4H submodule has since moved to a 6.12-series DomU kernel; MACHINE virtio-aarch64) |
| DomA guest | AAOS (`aosp_xenvm_trout_arm64`), Xen virtio (CONFIG_XEN / XEN_VIRTIO). A V4H-built AAOS image boots unmodified (portability proof) |


See also:

- [Patch trailers](docs/DESIGN.md) — what Upstream-Status / Origin / Local-Modifications on the in-tree patches mean.
## Repository layout
```
.
├── build.sh                 # orchestrator (Docker; mirror of AGL sodev-demo-workspace/build.sh)
├── rpi5-sodev.yaml          # moulin entry: Dom0/DomD/DomU/DomA build + SD-image wiring
├── docker/                  # unified sodev-builder build image (built on demand)
├── docs/                    # BUILD.md (build detail) / DESIGN.md (why) / TROUBLESHOOTING.md
├── external/
│   ├── meta-xt-prod-devel-rpi5/   # submodule: pristine xen-troops base (byte-identical)
│   └── sodev-demo-workspace/      # submodule: AGL SoDeV — DomU/DomA source of truth (V4H)
├── meta-rpi-sodev/          # ALL RPi5/Xen delta, consolidated on the upstream meta-xt-* layout
│   ├── meta-xt-common/
│   │   ├── meta-xt-dom0-linux/      # thin LINUX Dom0 image, xl-create service chain, xen-tools cfg
│   │   ├── meta-xt-dom0-zephyr/     # ZEPHYR Dom0 patch series (xenstore server, dom_cfg, altp2m,
│   │   │                            #   static-mem xenstore page fix)
│   │   ├── meta-xt-driver-domain/   # DomD image (p2 rootfs), kernel (vhost_xen/vc4), weston, qemu, xen-network
│   │   ├── meta-xt-domu/            # DomU xl cfg + cluster recipes + virtio kernel
│   │   ├── meta-xt-doma/            # DomA xl cfg + AAOS host services + guest binaries
│   │   ├── meta-xt-domx/            # shared cross-guest recipes (libc-headers, base-files, ...)
│   │   ├── meta-xt-{qemu,security}/ # vendored upstream
│   │   └── recipes-extended/xen-common/   # shared Xen 4.21 hypervisor patch series (both Dom0 flavours)
│   ├── meta-xt-rpi5/                # RPi5 BSP: u-boot/TFA/boot.scr, Xen 4.21 patch series, xen dtso, kernel DT/cfg
│   ├── xt-prod-devel-rpi5-domd/     # vendored upstream DomD product layer
│   ├── meta-rpi-sodev-devel/        # opt-in diagnostic/debug/prototype layer (NOT in the shipping build; p4-tool etc.)
│   └── scripts/                     # helpers: guest-pin sync (sync-guest-pins)
└── tools/                    # PC-side checks that need no build (run before a board).
    │                            Workspace-level: they read build.sh/rpi5-sodev.yaml and
    │                            more than one layer, so they are NOT under
    │                            meta-rpi-sodev/scripts/ (which is layer-scoped). No
    │                            recipe references them; they are developer/CI tools.
    └── check-memory-map.py         # DomD static-mem + Dom0 bank[0] placement, both --ram values
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
| DomA (AAOS) | `adb connect 192.168.10.13:5555` (Android has no sshd); `adb logcat` for logcat. Serial console: **`xl console 2`** from the toolstack domain — DomA's `hvc0` is the Xen **PV console**, and AAOS init's `console` service puts a shell on it (prompt `console:/ $`, uid 2000 `shell`). `xenconsole` calls `tcsetattr()` on stdin, so it needs a tty: over ssh use `ssh -tt root@192.168.10.10 'xl console 2'`. The `virtconsole` sockets in `doma.cfg` are **inert** — see the note below. |


See also:

- [Serial console — the single debug UART is Xen-multiplexed (Ctrl-A x3)](docs/TROUBLESHOOTING.md) — reaching each domain's console, and why xl console needs a tty.
- [Health checks (xenstore / teardown regression sanity)](docs/TROUBLESHOOTING.md) — quick checks to run after a change.
## Build & hardware verification (RPi5)
**Both Dom0 flavours build end-to-end** from a clean checkout to a complete,
loopback-verified 4-domain SD image: the single `sodev-builder` image produces
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
is build- and wiring-complete, but its end-to-end boot has not been re-validated
on the current tree (see the *Verification status* note under *Boot process* (`docs/DESIGN.md`)).
The Zephyr full-image HW checklist:
- Xen 4.21 boots (0 panics); all 4 domains auto-start; qemu device-models auto-spawn.
- Dual display + native touch, no scanout artifacts.
- SSH from the PC to DomD/DomU, adb to DomA; consoles for all domains.
- DomA management IP (192.168.10.13) via dnsmasq static lease — no manual step.
- Full 4-domain + hypervisor log audit performed; the actionable items are
  fixed in-tree (legacy Dom0 qdisk unit masked; prebuilt dumpstate backend not
  auto-enabled until rebuilt against wrynose libxml2).

As a portability proof, the **V4H-built DomA image boots unmodified**
on this stack (guest kernel/ramdisk/super swapped as binaries — no rebuild).

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
`4.21-0003` patch reverts an upstream restriction on buffered ioreq for Arm so the
DomD device model can serve the guests. That revert is deliberate and is documented in
the patch header; it should not be carried into a production hypervisor.

## References
- V4H AGL SoDeV (DomU/DomA source of truth): <https://github.com/automotive-grade-linux/sodev-demo-workspace>
- RPi5 Xen base project: <https://github.com/xen-troops/meta-xt-prod-devel-rpi5>
- Zephyr Dom0: <https://github.com/xen-troops/zephyr-dom0-xt>
- meta-virtualization (stock Xen recipes): <https://git.yoctoproject.org/meta-virtualization>
- moulin build system: <https://github.com/xen-troops/moulin>
