# Building sodev-demo-workspace-rpi

> **Documentation map** — [`README.md`](../README.md) build and run |
> [`docs/BUILD.md`](BUILD.md) build details |
> [`docs/DESIGN.md`](DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when it does not work

This file carries the build detail that [`README.md`](../README.md)'s *Quick start*
leaves out: the container the build runs in, driving moulin and ninja by hand, and
what the Android guest's prebuilt binaries are and how to stage them.

Read *Quick start* in the README first -- for the common cases you do not need
anything here.

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
>   reach its probe URL through a proxy and will abort the build; set it empty in
>   your build config (e.g. the `LINUX_DOMAIN_CONF` conf list in `rpi5-sodev.yaml`,
>   or a `local.conf` append) to skip the probe (sources come from the caches).
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
                              [--ENABLE_DOMU {no,yes}]
                              [--ENABLE_ANDROID {no,yes}]

Config file description: Raspberry Pi 5 + Xen 4.21 — AGL SoDeV disaggregated
cockpit (Zephyr or thin-Linux Dom0)

options:
  --DOM0_OS {zephyr,linux}
                        Dom0 OS: zephyr (xenstore-only disaggregated Dom0,
                        pinned rpi5-v0.4.0) or linux (thin Linux control Dom0)
                        (default: zephyr)
  --ENABLE_DOMU {no,yes}
                        Build DomU (AGL instrument cluster) kernel + AGL
                        rootfs and add them to the SD image (p1 kernel + p3
                        rootfs). yaml default no (V4H style); build.sh
                        adds it only with -u/--domu. (default: no)
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

## Staging the AAOS prebuilts

Five files — four large AAOS guest binaries plus the AOSP `NOTICE` that, per
Apache-2.0 section 4(d), must be redistributed with the host-service binaries — are
intentionally **not** committed (`.gitignore`d), so a fresh clone must copy them
once into `meta-rpi-sodev/meta-xt-common/meta-xt-doma/` **before** an
`-a`/`--android` build (with them absent the moulin `doma` recipes fail at
`do_fetch`). Copy each file to the relative path shown and verify the pinned md5
(the `NOTICE` has no pinned md5 — stage the authoritative one emitted by your
AOSP build):

| Relative path under `meta-xt-common/meta-xt-doma/` | md5 (first 8) | What it is |
|---|---|---|
| `recipes-bsp/aaos-guest-binaries/files/aaos-android-kernel-xenbuilt-6.1.118` | `c1700f50` | AAOS guest kernel Image (GKI 6.1.118, Xen/virtio-enabled `aosp_xenvm_trout_arm64` build; module_layout CRC 0xea759d7f — coherent with the super.img vendor_dlkm modules) |
| `recipes-bsp/aaos-guest-binaries/files/aaos-vendor-boot-ramdisk-xenbuilt-padded` | `e201569f` | AAOS vendor-boot ramdisk (AVB stripped, 4096-padded, bootconfig trailer; modules CRC 0xea759d7f) |
| `recipes-extended/xt-aaos-host-services/files/vehicle_hal_grpc_server` | `60a3d614` | DomD-side VHAL gRPC backend (aarch64, from the AAOS `agl_services_build`) |
| `recipes-extended/xt-aaos-host-services/files/dumpstate_grpc_server` | `ff890297` | DomD-side dumpstate gRPC backend (same origin) |
| `recipes-extended/xt-aaos-host-services/files/NOTICE` | (build-specific) | AOSP NOTICE for the Apache-2.0 host-service binaries (Apache-2.0 sec 4d); installed to `/usr/share/licenses/xt-aaos-host-services/NOTICE` in the DomD rootfs |

Staging from a prebuilt-AAOS source tree `$SRC` that holds the five files at
those same paths:

```sh
DEST=meta-rpi-sodev/meta-xt-common/meta-xt-doma
for f in \
  recipes-bsp/aaos-guest-binaries/files/aaos-android-kernel-xenbuilt-6.1.118 \
  recipes-bsp/aaos-guest-binaries/files/aaos-vendor-boot-ramdisk-xenbuilt-padded \
  recipes-extended/xt-aaos-host-services/files/vehicle_hal_grpc_server \
  recipes-extended/xt-aaos-host-services/files/dumpstate_grpc_server \
  recipes-extended/xt-aaos-host-services/files/NOTICE ; do
    install -D "$SRC/$f" "$DEST/$f"
done
# verify: the first 8 hex digits must match the table above
( cd "$DEST" && md5sum \
    recipes-bsp/aaos-guest-binaries/files/aaos-* \
    recipes-extended/xt-aaos-host-services/files/{vehicle_hal_grpc_server,dumpstate_grpc_server} )
```

The kernel/ramdisk md5 above are the **reference values for this project's
HW-verified coherent bundle** (guest kernel + super.img vendor_dlkm share ABI
`module_layout` CRC 0xea759d7f). They are environment-specific — a self-built AAOS
will differ — so the `aaos-guest-binaries` recipe does **not** hardcode them: its
md5 check is **opt-in and off by default** (accepts whatever you stage). To assert
a specific validated build, set `AAOS_KERNEL_MD5` / `AAOS_RAMDISK_MD5` in
`local.conf` (or the environment) to the values above. ⚠ Whatever you stage, keep
the **whole bundle from one coherent build**: a stale-kernel / fresh-super mismatch
makes ~97 guest modules fail `disagrees about version of symbol module_layout` and
AAOS never reaches SurfaceFlinger. Verify the two host-service binaries by hand
against the table. **Where do the five files come from?** They are not redistributed in this
repo, so `$SRC` is either (a) an existing tree that already has them at these
paths — e.g. a previously-staged clone or a colleague's build — or (b) your own
from-source build (see *Building the prebuilts from source* below). All five
come out of an `aosp_xenvm_trout_arm64` AAOS build (the same trout/xenvm target
the V4H SoDeV uses; the `NOTICE` is that build's authoritative Apache-2.0 NOTICE).

#### AAOS build modes (`--aaos`) — the prebuilt fast path
DomA needs **two** artifact sets: the five boundary files above (they feed the
DomD p1 guest kernel/ramdisk + host gRPC backends + the Apache-2.0 `NOTICE` — required
for *any* DomA build), and the six p4 partition images. `--aaos=<mode>` chooses how the
p4 images are obtained:

- **`off`** — DomA-less SD (no p4).
- **`source`** — build AAOS from AOSP source (~250 GiB / 1-3 h; `--aaos-src=<dir>` reuses a checkout).
- **`prebuilt`** — consume a prebuilt bundle; **no AOSP build** (minutes).
- **`auto`** (what `-a` selects) — prebuilt if a bundle is found, else source if an
  AOSP checkout is found, else off (or a hard error if DomA was required via `-a`).

A **prebuilt bundle** is a directory (`--aaos-prebuilt=<dir>`, default probe
`<workspace>/aaos-prebuilt`) with:

- `<dir>/files/` — the five files listed above (the four guest/host binaries plus the AOSP `NOTICE`).
- `<dir>/images/` — `super.img`, `userdata.img`, `boot.img`, `init_boot.img`,
  `vendor_boot.img`, `vbmeta.img` (an `aosp_xenvm_trout_arm64` build's output images).
- `<dir>/MANIFEST.md5` — md5 of all eleven files (verified, incl. a completeness check;
  absent ⇒ the six p4 images build with a NOTE; the guest kernel/ramdisk md5 is checked
  only if you opt in via `AAOS_KERNEL_MD5`/`AAOS_RAMDISK_MD5` — off by default, see below).

For `prebuilt`/`auto`-resolved-prebuilt, `build.sh` verifies `MANIFEST.md5`, stages
the five `files/` into the layer, places the six `images/` at the AOSP out path the
SD assembler (`rouge`) reads for the p4 nested GPT, builds only the non-Android
domains (`dom0`/`domd`[/`domu`]), and assembles `full.img` with `rouge` directly —
the `doma` / `doma_kernel` (AOSP + bazel GKI) steps never run. Use this when you have
a colleague's/CI's AAOS bundle and just want the flashable image. `--aaos=prebuilt`
and `--aaos=source` (via `--aaos-src`) are the two mutually-exclusive DomA sources.

    ./build.sh -u --aaos=prebuilt --aaos-prebuilt=$HOME/aaos-bundle   # DomU + DomA from a bundle, no AOSP build

#### Building the prebuilts from source
To (re)create the five files instead of copying them from an existing tree.
**Order matters:** `./build.sh -a` and `ninja image-full` deliberately refuse to
run until all five are staged (the DomD/guest recipes fetch them via `file://`),
so build + stage the five **first** (steps 1–5), then run the full image build
(step 6). Steps 1–4 do **not** need the prebuilts.

1. **AOSP tree** (source for the ramdisk in step 3 and, optionally, the host
   services in step 4) — build the
   `aosp_xenvm_trout_arm64-trunk_staging-userdebug` target directly from AOSP
   (`repo init` + `lunch` + `m`); this is a plain AOSP build and does **not**
   involve `./build.sh`/`ninja image-full`, so the missing prebuilts do not
   block it. It yields the `boot.img`/`vendor_boot.img` (and the
   `super.img`/`userdata.img` used later for SD p4). Budget ~250 GiB / 1–3 h;
   reuse an existing checkout instead of a fresh `repo sync` where possible.
2. **Guest kernel** — build GKI 6.1.118 from the xen-troops
   `android_kernel_manifest` with `CONFIG_XEN=y` / `CONFIG_XEN_VIRTIO=y`
   (`CONFIG_XEN=y` is required to avoid a virtio-pci `vp_interrupt` spurious
   data-abort panic) → `aaos-android-kernel-xenbuilt-6.1.118`.
3. **Vendor-boot ramdisk** — unpack the AAOS `boot.img`/`vendor_boot.img` with
   the AOSP `unpack_bootimg`, concatenate the `init_boot` ramdisk with the
   vendor ramdisk, remove the AVB entries from the fstab, then repack with the
   bootconfig trailer kept **last** and zero padding inserted before it so the
   total size is a multiple of 4096 → `aaos-vendor-boot-ramdisk-xenbuilt-padded`.
4. **Host services** — `vehicle_hal_grpc_server` / `dumpstate_grpc_server`
   are aarch64 binaries reused from the V4H reference DomD image (see
   `xt-aaos-host-services.bb` — no source build required); alternatively
   rebuild them from the AAOS tree's trout `agl_services_build`.
5. When replacing any binary, refresh the reference md5 in the *Staging the AAOS
   prebuilts* table above (and any opt-in `AAOS_KERNEL_MD5`/`AAOS_RAMDISK_MD5` —
   see the coherence/opt-in note there). Always replace the guest kernel, its
   vendor_boot ramdisk, and the super.img **together from one coherent build**.
6. **Stage** the five files into the layer (see *Staging the AAOS prebuilts* (`docs/BUILD.md`)) —
   the four built artifacts above plus the AOSP `NOTICE` from the AOSP tree
   (step 1) — then build the full image: `./build.sh -u -a` (or `ninja
   image-full`). Only now do the guarded full-image recipes find the prebuilts
   and succeed.

**DomD rootfs**: the SD boots DomD from the p2 ext4 built by
`rpi5-image-xt-domd-v4h` — `root=/dev/mmcblk0p2` in the zephyr flavour, or
`root=/dev/xvda` over PV-block in the linux one (see *DomD compositor startup and
rootfs* below). It is a moulin `target_images` output of the DomD build
(`rpi5-sodev.yaml`), so `ninja image-full` writes it to p2 and grafts the DomD
kernel and the `domd-vc4` DTB onto p1 — no separate manual step.

