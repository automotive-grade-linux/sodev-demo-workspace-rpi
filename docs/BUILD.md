# Building sodev-demo-workspace-rpi

> **Documentation map** — [`README.md`](../README.md) build and run |
> [`docs/BUILD.md`](BUILD.md) build details |
> [`docs/DESIGN.md`](DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when it does not work

This file carries the build detail that [`README.md`](../README.md)'s *Quick start*
leaves out: a first build walked through end to end, the container the build runs in,
driving moulin and ninja by hand, and how the Android guest's artifacts are produced.

Read *Quick start* in the README first -- for the common cases you do not need
anything here.

---

## Your first build, end to end

This walks from a machine with nothing installed to a flashable `full.img` carrying all
four domains on the Zephyr Dom0. It is the long form of the README's *Quick start*, with
the checkpoints that tell you a step worked.

Nothing has to be staged by hand at any point: every DomA artifact is produced by the
build (see *How the DomA artifacts are produced*).

### 0. Check the host

| | Needed | Why |
|---|---|---|
| Disk | **~300 GiB free** for a build including DomA | One measured from-scratch run used 272 GiB of workspace, of which `android/` was 231 GiB |
| RAM | 32 GiB is comfortable; the AOSP step is the peak | A cold AOSP build peaked at ~19 GiB with `nproc`=16 |
| Cores | more is faster, but see the warning below | `soong_ui` sizes its job count from `nproc`, not from any memory cap |
| Docker | engine, usable as a non-root user | every heavy step runs in a container |
| Network | anonymous HTTPS to `github.com`, `android.googlesource.com`, `boringssl.googlesource.com`, the Yocto/AGL mirrors | no registration, no NDA, no partner Gerrit |

> **If the host has many cores, cap them for the AOSP step.** `soong_ui` sets its `-j` from
> `runtime.NumCPU()+2` and never looks at the cgroup limit, so a 32-core machine will
> OOM-kill the container no matter what `--memory` you pass. `docker --cpus` does not help
> either -- it leaves `nproc` unchanged. Use `--cpuset-cpus`:
>
>     XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" ./build.sh ...
>
> `build.sh` recognises the kill and stops with this advice rather than retrying, but you
> save a few hours by setting it up front. See *Bounding a cold AOSP build*.

### 1. Install Docker

Follow *Docker usage* below -- in particular the post-install step that lets you run
`docker` without `sudo`. Check:

    docker run --rm hello-world

### 2. Get the sources

    git clone <this repository> && cd sodev-demo-workspace-rpi
    git submodule update --init --recursive

**Checkpoint** -- both submodules must be populated, not empty:

    ls external/meta-xt-prod-devel-rpi5 external/sodev-demo-workspace

### 3. Decide what to build

| Command | Domains on the SD card | AOSP build |
|---|---|---|
| `./build.sh` | Dom0(Zephyr) + DomD | no |
| `./build.sh -u` | + DomU (AGL instrument cluster) | no |
| `./build.sh -u --aaos=source` | + DomA (AAOS) = **all four** | **yes** |

The rest of this walkthrough uses the third row, which is the full cockpit on the Zephyr
Dom0 (`--dom0=zephyr` is the default, so it needs no flag). `-a` is a synonym for
`--aaos=auto`; name `--aaos=source` explicitly when you have nothing to start from, because
`auto` has nothing to choose between. If you already have an AOSP checkout or a repo object
mirror, see *Which starting point do you have?* -- it saves the sync, not the build.

### 4. Build the container image

Nothing to do -- `build.sh` builds `sodev-builder` from `docker/Dockerfile.builder` on
first use and reuses it afterwards. The first run prints:

```
>> docker build sodev-builder  (-f docker/Dockerfile.builder)
```

and later runs print nothing, because `build_img` skips a tag that already exists.

To see whether it is there already:

```sh
docker image inspect sodev-builder >/dev/null 2>&1 && echo present || echo absent
docker images sodev-builder
```

To build it yourself -- the same command `build.sh` runs, so the result is
interchangeable with it:

```sh
docker build -f docker/Dockerfile.builder docker/ \
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  -t sodev-builder
```

Behind a proxy, add the same values `build.sh` would pass (they are baked in, see below):

```sh
docker build -f docker/Dockerfile.builder docker/ \
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  --build-arg HTTP_PROXY="$HTTPS_PROXY" --build-arg HTTPS_PROXY="$HTTPS_PROXY" \
  --build-arg NO_PROXY="${NO_PROXY:-}" \
  --network=host \
  -t sodev-builder
```

`--network=host` is only needed when the proxy or a mirror listens on the **host's**
loopback; `build.sh` does the same via `XT_DOCKER_NETWORK=host`.

To force a rebuild -- **required after changing `--proxy` or the Dockerfile**, because the
proxy value is baked into the image and `build.sh` reuses an existing tag without
checking it:

```sh
./build.sh --rebuild-images -u --aaos=source      # via build.sh
REBUILD_IMAGES=1 ./build.sh -u --aaos=source      # same thing, env form
docker build --no-cache -f docker/Dockerfile.builder docker/ -t sodev-builder   # by hand
```

To look inside without building anything:

```sh
docker run --rm -it -v "$PWD":"$PWD" -w "$PWD" sodev-builder
```

Inside, the build drivers are on `PATH`:

```sh
command -v moulin rouge ninja repo git python3     # /usr/local/bin/moulin, ...
ninja --version                                    # 1.10.1
moulin rpi5-sodev.yaml --help-config               # the parameters this yaml offers
```

`bitbake` is deliberately **not** on `PATH`: it comes from the Yocto checkout, so it only
appears after sourcing the build environment, which is what the moulin-generated rules do:

```sh
source yocto/poky/oe-init-build-env yocto/build-domd
bitbake --version
```

`repo` is present as the launcher only; it downloads the rest into whichever checkout it
initialises.

The DomU (AGL) step uses the same image by default. `XT_DOCKER` and `AGL_DOCKER` select
the tags if you want to point either at something else -- see *Docker usage*.

### 5. Run the build

    ./build.sh -u --aaos=source

Behind a proxy, add the site settings from *Docker usage* first, e.g.

    export HTTPS_PROXY=http://proxy.example:3128
    export REPO_SKIP_SELF_UPDATE=1 CONNECTIVITY_CHECK_URIS=""
    XT_DOCKER_NETWORK=host ./build.sh -u --aaos=source

What happens, in order, and roughly how long. Measured end to end: **5 h 11 min** on a
32-core host with a warm Yocto sstate; your mileage will differ, and the AOSP step
dominates either way.

| Phase | Log line to look for |
|---|---|
| container image built (first run only) | `>> docker build sodev-builder` |
| DomU (AGL) bitbake, if `-u` | `>> DomU(AGL) in sodev-builder:` |
| AOSP `repo init` + `repo sync`, ~1379 projects | `[N/M] Initialize repo directory` |
| AAOS guest kernel (bazel) and the AOSP build | `Invoke Android build system` |
| DomD / Dom0 Yocto builds | `Yocto Build: domd`, `Invoke Zephyr build system` |
| SD image assembled | `rouge rpi5-sodev.yaml ...` |
| done | `Build complete.` |

The build is incremental and the `ninja` step is wrapped in a bounded retry, so a transient
network abort resumes rather than restarting. If it stops, read the message: the common
failures each have an entry in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### 6. Check what you got

    ls -l full.img            # ~27.7 GB, sparse
    sfdisk -l full.img        # four partitions

A complete image has four partitions:

| # | Name | Size | Contents |
|---|---|---|---|
| 1 | `boot` | 512 MiB | FAT: firmware, U-Boot, `xen`, `zephyr.bin`, the DomD kernel and DTBs, `boot.scr`, `linux-domu`, and the two DomA boot artifacts |
| 2 | `domd` | 9216 MiB | DomD (driver domain) rootfs |
| 3 | `domu` | 2048 MiB | DomU AGL instrument-cluster rootfs (present with `-u`) |
| 4 | `android` | 14662 MiB | DomA as a nested GPT (present with DomA) |

**Checkpoint** -- the build should not have left anything staged in the tree:

    git status --porcelain          # empty
    ls meta-rpi-sodev/meta-xt-common/meta-xt-doma/recipes-bsp/aaos-guest-binaries/files/
                                    # no such directory, in source mode

### 7. Flash and boot

    sudo dd if=full.img of=/dev/<sd-dev> bs=4M conv=fsync status=progress

Check `<sd-dev>` twice. For what to expect on the displays and consoles, and for the
`Ctrl-A x3` UART multiplexing, see *Testing / console access* in the README and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

---

## Docker usage

All heavy builds run in containers (`build.sh` builds the images on demand and
re-runs itself inside them). To use Docker directly, first install it:

- <https://docs.docker.com/engine/install/ubuntu/>
- <https://docs.docker.com/engine/install/linux-postinstall/> — pay attention
  to *Manage Docker as a non-root user*; it is required for proper use of the
  containers.

A single build image is provided under `docker/`:

| Image | Dockerfile | Used for |
|---|---|---|
| `sodev-builder` | `docker/Dockerfile.builder` | everything: moulin + ninja (Yocto/Xen/Zephyr; pinned moulin revision), the AOSP/AAOS (DomA) build, and the DomU AGL bitbake |

The DomU AGL build uses the same image by default; to use the AGL-official
docker-worker instead, pass `AGL_DOCKER=<official-image> ./build.sh`.

> **Note — this Dockerfile is a sample.** It is a reference build environment
> that assumes direct outbound network access and is not tailored to any
> particular site. **If your network requires an HTTP(S) proxy, add your own
> proxy configuration** to the Dockerfile and to the build environment — it is
> intentionally left out here because it is site-specific
> (`HTTP_PROXY`/`HTTPS_PROXY` build-args and env are honoured as a starting
> point; `build.sh` passes them through).
>
> **Proxy changes need `--rebuild-images`.** The proxy setting is baked into the
> `sodev-builder` image at build time; `build.sh` reuses an existing image by tag
> and will *not* rebuild it when the flag changes. After changing `--proxy` (or
> the Dockerfile), pass `--rebuild-images` once so the new setting takes effect.
>
> On a **restricted / proxy network**, two more site settings are commonly
> needed beyond the proxy itself:
> - `CONNECTIVITY_CHECK_URIS = ""` — bitbake's connectivity sanity-check may not
>   reach its probe URL through a proxy and will abort the build; set it empty to
>   skip the probe (sources come from the caches). Either **export it** — `build.sh`
>   forwards it into the build containers and adds it to
>   `BB_ENV_PASSTHROUGH_ADDITIONS`, so it reaches bitbake — or set it in your build
>   config (e.g. the `LINUX_DOMAIN_CONF` conf list in `rpi5-sodev.yaml`, or a
>   `local.conf` append). Exporting it is preferable: it leaves the tree pristine.
> - `REPO_SKIP_SELF_UPDATE=1` — export it so the AOSP `repo` tool does not try to
>   self-update over the network (which can fail/hang behind a proxy). `build.sh`
>   forwards it (via `docker run -e`) into the build container where `repo` runs.
> - **AOSP `repo sync` has no built-in retry** in moulin's generated `doma` /
>   `doma_kernel` rule, so a single transient proxy abort can fail a `ninja` step
>   (the `build.sh` AGL step passes `--retry-fetches=20`, but the moulin `repo`
>   fetcher does not). `build.sh` therefore wraps its `ninja` invocation in a small
>   **bounded retry loop** (up to 5 attempts): the build is incremental and the
>   repo-sync stamp is written only on success, so each retry resumes from the
>   failed step, and a genuine (deterministic) build error still surfaces after the
>   cap. Running `ninja` by hand you get the same effect by just re-running it.
>   (Adding a retry key to `rpi5-sodev.yaml` does not work — moulin ignores unknown
>   keys; retry has to live in the `ninja` wrapper or the moulin `repo sync` command.)
>
> These are site-specific and intentionally not defaulted; they are what this
> workspace's own proxied CI uses.

Build and enter the builder manually:

```sh
docker build -f docker/Dockerfile.builder docker/ \
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" -t sodev-builder
docker run --rm -it -v "$PWD":"$PWD" -w "$PWD" sodev-builder
#   add --network=host only if the build has to reach a proxy or mirror on the
#   host's loopback (build.sh does this via XT_DOCKER_NETWORK=host)
# inside the container, proceed with the manual build below:
#   moulin rpi5-sodev.yaml && ninja image-full
# (see *Manual build* (`docs/BUILD.md`) for its caveats, incl. reusing an older build root)
```

(If your uid/gid is 1000 the `--build-arg` parameters may be omitted.)
`build.sh` knobs: `XT_DOCKER`/`AGL_DOCKER` select the image tags,
`REBUILD_IMAGES=1` forces an image rebuild, `HTTPS_PROXY` is passed
through into both `docker build` and the build containers, and
`XT_SSTATE_DIR`/`XT_DL_DIR` point bitbake at an existing sstate/downloads
cache (absolute paths) for much faster rebuilds — e.g. reuse another
workspace's `yocto/common_data/sstate`. This shared cache is used by **both**
the moulin/sodev-builder build (Dom0/DomD/DomU-kernel/DomA) **and** the DomU AGL
bitbake — `build.sh` points the AGL build's `DL_DIR`/`SSTATE_DIR` at the same
cache (`XT_DL_DIR`/`XT_SSTATE_DIR` when set, else the in-workspace
`yocto/common_data/{downloads,sstate}`), so AGL source downloads are
deduplicated with the rest of the build and its sstate persists across rebuilds
(beyond the disposable `agl/` checkout).

`XT_WEST_CACHE_DIR` (`--west-cache=<dir>`) is the **source-download cache for the
Zephyr Dom0** (the DL_DIR analogue for the west side of the build). Point it at a
pre-populated **west reference workspace** and the `fetch-dom0` step (`west init` +
`west update`) pulls the manifest and all projects from it — no network — for
offline / air-gapped builds or faster, repeatable rebuilds. Create the reference
workspace once on a machine with connectivity, then reuse/copy it:
```
west init -m https://github.com/xen-troops/zephyr-dom0-xt.git --mr rpi5-v0.4.0 west-ref
cd west-ref && west update            # populates zephyr-dom0-xt + zephyr + modules
# then, offline:
./build.sh --dom0=zephyr --west-cache=/abs/path/to/west-ref  ...
```
`build.sh` wires this via west's `update.path-cache` (the `west update` projects)
plus a git `insteadOf` redirect of the pinned manifest URL to the cache (the
manifest repo `west init` clones is not path-cache-covered). Note Zephyr has **no
sstate-style build-artifact cache** — only the *source* cache above. For faster
recompiles in the manual build (below), set `CCACHE_DIR` (Zephyr's CMake
auto-enables ccache when present). The docker-wrapped `build.sh` does not wire
ccache: it runs the container with `--rm`, does not forward `CCACHE_DIR` in its
`-e` allowlist, and mounts no ccache dir, so any ccache is discarded with the
container.

## Manual build (moulin + ninja, upstream style)

The docker-wrapped `build.sh` above is the recommended path (it automates the
staging and patching steps). The underlying flow is the same as the upstream
[`meta-xt-prod-devel-rpi5`](https://github.com/xen-troops/meta-xt-prod-devel-rpi5)
project: **moulin** generates a Ninja build file, **ninja** builds the domains
and assembles the SD image.

Moulin is not on PyPI — install it from the xen-troops repository, pinned to
the same known-good revision the Docker image uses (`docker/Dockerfile.builder`):
```sh
pip install git+https://github.com/xen-troops/moulin.git@83e80587c4b1348714237d3ff53129857288a420
```

This project provides additional parameters; check them with `--help-config`:

```
$ moulin rpi5-sodev.yaml --help-config
usage: moulin rpi5-sodev.yaml [--DOM0_OS {zephyr,linux}]
                              [--BOARD_RAM {16g,8g}] [--ENABLE_DOMU {no,yes}]
                              [--ENABLE_ANDROID {no,yes}]

Config file description: Raspberry Pi 5 + Xen 4.21 — AGL SoDeV disaggregated
cockpit (Zephyr or thin-Linux Dom0)

options:
  --DOM0_OS {zephyr,linux}
                        Dom0 OS: zephyr (xenstore-only disaggregated Dom0,
                        pinned rpi5-v0.4.0) or linux (thin Linux control Dom0)
                        (default: zephyr)
  --BOARD_RAM {16g,8g}  Target Raspberry Pi 5 SKU: 16g (default; full 4-domain
                        cockpit) or 8g (DomD and DomA 3072 MiB each; the four
                        domains then total 7680 MiB and fit an 8 GB board --
                        see the comment above) (default: 16g)
  --ENABLE_DOMU {no,yes}
                        Build DomU (AGL instrument cluster) kernel + AGL
                        rootfs and add them to the SD image (p1 kernel + p3
                        rootfs). yaml default no (V4H style); build.sh adds it
                        only with -u/--domu. (default: no)
  --ENABLE_ANDROID {no,yes}
                        Build Android (AAOS) as a guest VM and add it as the
                        full SD image p4 (nested GPT) (default: no)
```

Moulin will generate a `build.ninja` file; then run ninja to build and to
assemble the image:

```sh
moulin rpi5-sodev.yaml                                        # defaults: DOM0_OS=zephyr, ENABLE_DOMU=no, ENABLE_ANDROID=no
# moulin rpi5-sodev.yaml --DOM0_OS linux --ENABLE_ANDROID no  # other flavours
ninja                # builds the configured domains (takes time and disk)
ninja image-full     # assembles full.img (the GPT SD image)
```

`ninja image-full` writes `full.img` into the build root (the directory you
ran moulin in).

Manual-path caveats (all handled automatically by `build.sh`):
- stage the AAOS prebuilts **before** the first build (see *Staging the AAOS
  prebuilts* below);
- with `DOM0_OS=zephyr`, populate the west workspace with a fetch-only pass and
  apply the patch series **before** building Dom0:
  `ninja fetch-dom0 && meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/apply-zephyr-patches.sh "$PWD/zephyr"`
  (workspace root = `<build-root>/zephyr`; the script is idempotent — see *Zephyr Dom0* (`docs/DESIGN.md`)).
- **if you are reusing a build root created by an older revision of this workspace,
  delete the generated bitbake configs first**: `rm -rf yocto/build-dom*/conf`.
  Moulin writes `yocto/build-*/conf/{bblayers.conf,local.conf}` only when they are
  absent (`oe-setup-builddir` keeps an existing `bblayers.conf`, and
  `bitbake-layers add-layer` only appends), so a stale `bblayers.conf` can keep
  pointing at layer paths that no longer exist and bitbake then aborts with
  *"The following layer directories do not exist"*. A fresh clone is unaffected,
  and `build.sh` removes those configs for you.

## How the DomA artifacts are produced

A DomA build needs two sets of artifacts, and in `--aaos=source` **both are produced by
this workspace from public sources — nothing is staged by hand and nothing is
redistributed here.** (`--aaos=prebuilt` takes the two boot artifacts from a bundle
instead; see *AAOS build modes* below.)

| Artifact | Produced by | Consumed as |
|---|---|---|
| six p4 images (`super`, `userdata`, `boot`, `init_boot`, `vendor_boot`, `vbmeta`) | the `doma` moulin component (AOSP `m`) | SD p4 nested GPT, assembled by rouge |
| DomA guest kernel | the `doma_kernel` component (bazel, GKI 6.1.118 + `xen-virtual-device`) | SD p1 `aaos-android-kernel` |
| DomA vendor-boot ramdisk | derived from `vendor_boot.img` by `aaos-guest-binaries` | SD p1 `aaos-vendor-boot-ramdisk` |
| `vehicle_hal_grpc_server`, `dumpstate_grpc_server`, `garage_mode_helper` | built from source by `google-trout-agl-services` | DomD rootfs `/usr/bin` |

The only file of AOSP origin committed to this repository is the Apache-2.0 `NOTICE`
that accompanies the host-service binaries (Apache-2.0 section 4d); it has to be in
git because `xt-aaos-host-services` fetches it with `file://NOTICE`.

### The DomD-side gRPC backends

`google-trout-agl-services` (in `meta-xt-doma/recipes-extended/`) builds the trout
host services that the AAOS guest talks to over vsock. It fetches 14 public git
sources — `device/google/trout` itself plus the 13 third-party projects its CMake
build needs (protobuf, grpc-grpc, boringssl, fmtlib, jsoncpp, zlib, c-ares, gflags,
googletest, `hardware/interfaces`, `system/{core,libbase,logging}`) — all pinned to
the revisions the AOSP manifest resolves, and reproduces the `<linkfile>` layout that
`agl_services_build/repo_manifest.xml` would create.

This is a **port** of the Yocto layer that ships inside the AOSP checkout at
`device/epam/aosp-xenvm-trout/agl_services_build/yocto-layer/meta-google`, not a
`layers:` entry pointing at it (which is what the V4H SoDeV does). The reasons are
recorded in `trout-sources.inc`; briefly:

- that layer declares `LAYERSERIES_COMPAT_meta-google = "kirkstone scarthgap"`, and
  bitbake rejects a series mismatch with `bb.fatal` **before** `conf/bitbake.conf` is
  parsed, so neither `local.conf` nor a bbappend can relax it;
- it sets `S` the pre-`UNPACKDIR` way, which does not resolve on Wrynose;
- its `LICENSE = "CLOSED"` (a TODO from the original author) would put Apache-2.0
  material into the image's license manifest as CLOSED;
- consuming a layer from inside the AOSP checkout couples the DomD Yocto build to the
  AOSP build. Fetching `device/google/trout` by git instead removes that ordering
  constraint entirely.

`TOOLCHAIN = "clang"` is required (the sources are written against Android's
toolchain), so `meta-clang` is in this build's layers — pinned to its **wrynose**
branch. Two Wrynose-specific build fixes live in the recipes: cmake 4 rejects the
`cmake_minimum_required(VERSION <3.5)` that nine of the pinned third-party projects
still declare (`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`), and a newer clang rejects a
`const void *` return in BoringSSL's `crypto/fipsmodule/internal.h`
(`-Wno-error=incompatible-pointer-types-discards-qualifiers`). Expect this
`-Wno-error` list to need extending when the toolchain moves again.

### The guest kernel and vendor-boot ramdisk

`aaos-guest-binaries` derives both from the AAOS build outputs
(`aaos-guest-binaries-derive.inc`). `AAOS_SRC_TREE` / `AAOS_KERNEL_TREE` default to
the moulin layout and can be pointed elsewhere for an out-of-tree AOSP checkout.

The kernel is the bazel `Image` copied verbatim. The ramdisk is rebuilt from
`vendor_boot.img`:

1. `unpack_bootimg` (from the AOSP checkout) → `vendor_ramdisk00` + `bootconfig`
2. decompress to cpio and extract
3. **strip the AVB entries from `fstab.trout` and `fstab.trout_xenvm`** — vbmeta and
   dm-verity are not used for this guest, and leaving them makes first-stage init fail
   to mount. The `fstab.cf.*` files in the same directory are cuttlefish leftovers and
   are left alone.
4. repack as cpio `newc` with **uid/gid 0** (`cpio --owner 0:0`, standing in for
   AOSP's `mkbootfs`) and compress with **lz4 legacy** framing — ONE stream
5. append zero padding, then the bootconfig section and its trailer
   (`[params][size 4B LE][csum 4B LE]["#BOOTCONFIG\n"]`) so the **total** size is a
   multiple of 4096

Step 5's alignment is load-bearing: libxl rounds the initrd up to 4096 and advertises
`initrd_end`, but Linux only looks for the magic at `initrd_end-12`. A non-aligned
total hides the trailer and no `androidboot.*` reaches the guest. On hardware the
guest logs `Load bootconfig: 1187 bytes 63 nodes` when this is right.

⚠ **Only `vendor_boot`'s ramdisk is used — do not merge `init_boot`'s.**
`vendor_ramdisk00` already carries `/init` (a symlink to `/system/bin/init`) and
`first_stage_ramdisk/fstab.trout{,_xenvm}`, and is a superset of every file in a
known-good ramdisk. Merging `init_boot` on top replaces that symlink with
`init_boot`'s generic first-stage init binary, and the guest then reaches `/init` and
immediately issues `reboot bootloader` (measured: DomA entered shutdown 0.2 s after
"Run /init as init process"). The recipe asserts the symlink and fails the build if it
is not one.

### Build order: the AOSP components must run before DomD

The derivation reads files that the `doma` and `doma_kernel` moulin components produce,
but that dependency lives inside a bitbake recipe, so **ninja cannot see it**. Given a
single goal it picks DomD first — observed as `[8/13] Yocto Build: domd` ahead of
`[11/13] Invoke Android build system` — and on a tree where the AOSP build has not run
yet, `do_compile` then aborts with the paths it could not find.

`build.sh` handles this: in `source` mode it runs

    ninja doma_kernel doma && ninja image-full

Ordering costs nothing here. Every moulin builder rule (yocto, android, bazel, zephyr)
declares ninja's `console` pool, whose depth is 1, so the components are serialised
either way — this only fixes *which* order.

If you drive ninja by hand, build those two goals first. This also applies to
`--domains-only`: it still builds DomD, and moulin's default ninja target does *not*
include `doma`/`doma_kernel`.

### Keep the guest kernel and the p4 images coherent

The guest kernel, its modules and `super.img`'s `vendor_dlkm` must come from one
consistent pair, or ~97 guest modules fail `disagrees about version of symbol
module_layout` and AAOS never reaches SurfaceFlinger — `sys.boot_completed` still goes
to 1 and `screencap` still returns a real UI, so the only visible symptom is a black
panel. The build wires this up automatically: `doma` consumes `doma_kernel`'s output
via `TARGET_PREBUILT_KERNEL` / `TARGET_PREBUILT_MODULES_DIR`, so the modules baked into
`vendor_dlkm` and the kernel deployed to p1 are from the same tree.

**Judge coherence by the ABI, not by md5.** The GKI bazel build is not reproducible —
three builds of the same source produced three different `Image` md5s — but all
exported `module_layout = 0xea759d7f`. Compare `module_layout` in a module's
`__versions` section and the `vermagic` string; md5 equality is neither necessary nor
sufficient. For that reason the `aaos-guest-binaries` md5 check is **opt-in and off by
default**: set `AAOS_KERNEL_MD5` / `AAOS_RAMDISK_MD5` only to pin one specific
validated build.

### Which starting point do you have?

Four starting points, and what each needs. Nothing has to be staged by hand in any of
them: the DomA guest kernel and vendor-boot ramdisk are derived from the build, and the
DomD-side gRPC backends are fetched from public git — except in `prebuilt`, which has no
AOSP checkout to derive from and so takes those two artifacts out of the bundle.

| You have | Command | AOSP build | Notes |
|---|---|---|---|
| **Nothing at all** | `./build.sh -u --aaos=source` | yes | moulin runs its own `repo init` + `repo sync`. See *Case A* below |
| **A `.repo` object mirror** | `./build.sh -u --aaos=source --aaos-ref=<mirror> --aaos-kernel-ref=<mirror>` | yes | objects come from the mirror instead of the network. See *Case B* below |
| **An AOSP checkout** | `./build.sh -u --aaos=source --aaos-src=<dir>` | yes | skips the sync; `<dir>` is symlinked in as `<workspace>/android` |
| **A prebuilt bundle** | `./build.sh -u --aaos=prebuilt --aaos-prebuilt=<dir>` | **no** | minutes instead of hours. Bundle contract below |

`-a` is `--aaos=auto` and resolves to `prebuilt` if a bundle is found, else `source` if a
checkout **or** a mirror is found, else it fails (or, for an explicit `--aaos=auto`, falls
back to a DomA-less image). The first row is the one case `-a` cannot reach — with nothing
to go on it has nothing to choose — so name `--aaos=source` explicitly there.

### AAOS build modes (`--aaos`)

`--aaos=<mode>` chooses how the six p4 images are obtained:

- **`off`** — DomA-less SD (no p4).
- **`source`** — build AAOS from AOSP source (see *Starting with no AOSP checkout* for
  measured disk and time; `--aaos-src=<dir>` reuses a checkout). Everything else is
  derived from that build.
- **`prebuilt`** — consume a bundle; **no AOSP build** (minutes).
- **`auto`** (what `-a` selects) — prebuilt if a bundle is found, else source if an
  AOSP checkout is found, else off (or a hard error if DomA was required via `-a`).

A **prebuilt bundle** is a directory (`--aaos-prebuilt=<dir>`, default probe
`<workspace>/aaos-prebuilt`) with:

- `<dir>/images/` — the six p4 images, and
- `<dir>/files/` — `aaos-android-kernel-xenbuilt-6.1.118` and
  `aaos-vendor-boot-ramdisk-xenbuilt-padded`,
- optionally `<dir>/MANIFEST.md5`.

The two `files/` artifacts are needed because **`prebuilt` cannot derive them**: deriving
needs the AOSP checkout (`system/tools/mkbootimg/unpack_bootimg.py`) and the bazel guest
kernel, and skipping the AOSP build is the entire point of the mode. `build.sh` copies
them into `meta-xt-doma/recipes-bsp/aaos-guest-binaries/files/` (`.gitignore`d — build
inputs, never committed) and the recipe then uses them verbatim instead of deriving. All
four artifacts in a bundle must come from **one** build, for the ABI reason above.

There is **no public download of such a bundle**; it is something a colleague or a CI
produces. A third party with nothing uses `--aaos=source`, which needs only anonymously
reachable public repositories — no registration, no NDA, no partner access.

    ./build.sh -u --aaos=source                       # everything from public sources
    ./build.sh -u --aaos=source --aaos-src=$HOME/aosp # reuse an AOSP checkout
    ./build.sh -u --aaos=prebuilt --aaos-prebuilt=$HOME/aaos-bundle

### Starting with no AOSP checkout

`--aaos=prebuilt` needs no AOSP source at all. This section is for `--aaos=source` when
you do not already have a working checkout — either because you have nothing, or because
what you have is a repo *object mirror* rather than a tree.

Nothing has to be staged by hand in either case: the two boot artifacts are derived from
the build (see above) and the gRPC backends are fetched from public git.

**Case A — nothing at all.** Pass `--aaos=source` without `--aaos-src`. The moulin `doma`
and `doma_kernel` components run their own `repo init` + `repo sync` into
`<workspace>/android` and `<workspace>/android_kernel`.

Measured on one from-scratch run (32-core host, warm Yocto sstate, DomA + DomU, Zephyr
Dom0): **5 h 11 min** end to end and **272 GiB** of workspace — `android/` 231 GiB (of
which `out/` 106 GiB), `android_kernel/` 18 GiB, `yocto/` 9 GiB. Budget more than that:
those figures are one host's, the AOSP build dominates and scales with core count, and a
cold Yocto sstate adds to the Yocto share. Everything after the first run is incremental.

**Case B — a repo object mirror.** If your site keeps a mirror (an exported
`*-project-objects` tree, or another repo client), point `--aaos-ref` and
`--aaos-kernel-ref` at it. `build.sh` seeds each checkout with
`repo init --reference=<dir>` before moulin runs, so the sync reads objects locally
instead of over the network:

    ./build.sh -u --aaos=source \
      --aaos-ref=/mirror/aosp --aaos-kernel-ref=/mirror/aosp-kernel

This is the AOSP analogue of `--west-cache`. Details worth knowing:

- The manifest URL, revision and depth come from `rpi5-sodev.yaml`, so the pins are not
  duplicated. moulin's own later `repo init` preserves the recorded `repo.reference`, so
  its syncs stay local too.
- A bare `*-project-objects` tree is not itself a repo client; `build.sh` wraps it in a
  throw-away shim under `.aaos-ref-shim/<component>/` (a symlink, `.gitignore`d). The shim
  is named after the component, not the mirror, because both mirrors are commonly exported
  under the same basename.
- The mirror does most, not all, of the work. Measured on the run above: `info/alternates`
  was written for **1379 of 1379** projects and pointed at the mirror, and the client's own
  `.repo/project-objects` came to 28 GiB against a 217 GiB mirror — 702 projects still
  fetched a small incremental pack. So expect a fraction of a full sync, not zero traffic.
- Even with most objects local, `repo` still runs one `git fetch` per project to resolve
  refs, and `android.googlesource.com` rate-limits that. The default concurrency is
  therefore 4, with serial retries on failure; raise it with `XT_AAOS_SYNC_JOBS` if your
  mirror server is unthrottled. Measured on a 32-core host: `-j16` failed 12 of 1379
  projects with `RESOURCE_EXHAUSTED`, `-j8` failed 1, and a retry fixed both.
- A mirror that does not exist, or holds no bare `*.git`, is rejected up front — an empty
  directory would silently turn into a full network sync, which is what the flag exists to
  avoid.

### Bounding a cold AOSP build

A cold AOSP build can OOM-kill the container regardless of `--memory`. `soong_ui` sizes
`ninja -j` from `runtime.NumCPU()+2` and never looks at the cgroup limit, so on a
many-core host the job count — not the memory cap — decides the peak. Cap the CPUs the
container can see; `docker --cpus` does **not** help, because it leaves `nproc` unchanged:

    XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" ./build.sh -u --aaos=source ... --memory=44g

Measured on a 32-core host with a 44 GiB cap: killed at `nproc`=32, peak ~19 GiB at
`nproc`=16. A warm `--aaos-src` tree does not reproduce it (its `m` finishes in minutes),
so verify on a cold build. `build.sh` recognises the kill and stops instead of spending its
retries on it — see *`ninja failed with: signal: killed`* (`docs/TROUBLESHOOTING.md`).

⚠ The AOSP target is `aosp_xenvm_trout_arm64-trunk_staging-userdebug`, provided by
`xen-troops/android_device_epam_xenvm-trout` (Google's own AOSP tree stops at
`aosp_trout_arm64`). The manifest is `yhamamachi/android_manifest`, which pins stock
public AOSP plus that device layer, mesa and `xen-troops/lisot`. The upstream Google
copy of the trout Yocto layer points at `partner-android.googlesource.com` and
`sso://googleplex-android/`, neither of which is anonymously reachable — the EPAM fork
is what makes a clean build possible.
