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
| Disk | **~400 GiB free** for a build including DomA | Measured on Android 17: 334 GiB of workspace — `android/` 277 GiB (of which `out/` 138 GiB), `android_kernel/` 35 GiB, `agl/` 11 GiB, `yocto/` 11 GiB — plus the SD image, ~26 GiB (25.8 GiB = 27.7 GB; its p4 varies with the AOSP output), so ~360 GiB in total; ~400 is that rounded up for headroom. `build.sh` warns before starting when the workspace's filesystem has less than 360 GiB free (60 GiB without `--aaos=source`) (a cold Yocto sstate alone was 31 GiB on 15 against the 11 GiB measured here with a warm one). The Android 15 figure was 272 GiB, so add ~90 GiB if you are following older notes |
| RAM | **64 GiB**, capped at `--memory=48g` (below); the AOSP step is the peak | On Android 17 `soong_build` alone peaked at **42.6 GiB** doing analysis, before any compiling, so the cap has to sit above that and the host has to have room for the cap plus whatever else it runs. (The Android 15 figure was ~19 GiB with `nproc`=16 — the analysis got much heavier, and it is a single process, so `--cpuset-cpus` does not bound it.) Measured on a 64 GiB host: 48g cap left ~14 GiB, which was enough but not generous — a 48 GiB host cannot both grant the cap and stay alive |
| Cores | more is faster, but see the warning below | `soong_ui` sizes its job count from `nproc`, not from any memory cap |
| Docker | engine, usable as a non-root user, **and able to relax its sandbox** (below) | every heavy step runs in a container, and one Android 17 build step runs its own sandbox inside it |
| Network | anonymous HTTPS to `github.com`, `android.googlesource.com`, `boringssl.googlesource.com`, the Yocto/AGL mirrors | no registration, no NDA, no partner Gerrit |

> **Cap the container's RAM, and cap the cores too.** The two limits fix different things
> and you want both:
>
>     XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" ./build.sh --memory=48g ...
>
> `--memory` bounds `soong_build`, which is a single Go process whose appetite comes from
> the size of the module graph, not from any job count -- so `--cpuset-cpus` cannot bound
> it. Without a `--memory` cap its 42.6 GiB peak is charged against the whole host, and on
> a 64 GiB machine the kernel picks a global OOM victim: measured, that killed the editor
> session rather than the build (`oom-kill: constraint=CONSTRAINT_NONE ... global_oom,
> task=soong_build`). With the cap the same overrun is a cgroup kill, i.e. the build dies
> and nothing else does.
>
> `--cpuset-cpus` bounds the *compile* phase: `soong_ui` sets ninja's `-j` from
> `runtime.NumCPU()+2` and never looks at the cgroup limit, so a many-core machine will
> OOM-kill the container no matter what `--memory` you pass. `docker --cpus` does not help
> either -- it leaves `nproc` unchanged.
>
> `build.sh` recognises the kill and stops with this advice rather than retrying, but you
> save a few hours by setting it up front. See *Bounding a cold AOSP build*.

> **Android 17 needs nsjail to work inside the container.** AOSP 17 builds
> `trusty_security_vm_arm64.bin` with a genrule that invokes `prebuilts/build-tools/nsjail`
> directly, and nsjail has to create namespaces, change mount propagation and `pivot_root`.
> Docker's default sandbox blocks all three, so the build fails on that one target after
> hours of otherwise successful compiling:
>
>     [E] initCloneNs():432 pivot_root('/tmp/nsjail.1000.root', ...): Operation not permitted
>
> Three `--security-opt`s are needed, and each one covers a different step (measured
> separately -- dropping any of them moves the failure rather than removing it). They go
> in `XT_DOCKER_RUN_OPTS_AOSP`, which only the container running the AOSP build gets;
> `XT_DOCKER_RUN_OPTS` still carries the limits that apply to every container:
>
>     XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" \
>     XT_DOCKER_RUN_OPTS_AOSP="--security-opt seccomp=unconfined \
>       --security-opt apparmor=unconfined \
>       --security-opt systempaths=unconfined" ./build.sh --memory=48g ...
>
> On a host with `kernel.apparmor_restrict_unprivileged_userns=1` (Ubuntu 24.04 and
> later) `build.sh` refuses `apparmor=unconfined` even in `XT_DOCKER_RUN_OPTS_AOSP`:
> read *Ubuntu 24.04 hosts* below first and use the confining `docker-nsjail-build`
> profile in its place.
>
> | | blocks |
> |---|---|
> | `seccomp=unconfined` | the `clone` namespace flags, and `pivot_root` |
> | `apparmor=unconfined` | `mount('/','/',MS_REC\|MS_PRIVATE)` |
> | `systempaths=unconfined` | the same `mount`, via Docker's masked/read-only paths |
>
> No capability is required: `--cap-add=SYS_ADMIN` gets past `clone` but not `pivot_root`,
> and `--cap-add=ALL` does not help at all. `--privileged` works because it implies all
> three, but it also opens device access, which none of this needs. Android 15 did not
> require any of it -- that build has no nsjail-invoking target.
>
> The target this unblocks is **not part of the image**: nothing in `PRODUCT_PACKAGES`,
> `device/google/trout` or `device/epam/aosp-xenvm-trout` references it. It is pulled in
> because AOSP's default goal check-builds every module, so there is nothing to gain by
> excluding it from the product -- and moulin's android builder always runs a plain
> `m -j`, so the goal is not ours to change.

> **Ubuntu 24.04 hosts: `apparmor=unconfined` and BitBake do not mix.** Ubuntu 24.04 ships
> `kernel.apparmor_restrict_unprivileged_userns = 1`, which forbids user-namespace
> creation to any process that is *not* confined by an AppArmor profile. BitBake's sanity
> check (`sanity.bbclass`) creates one to prove it can isolate tasks from the network, so
> in an unconfined container every Yocto domain dies at startup with
>
>     ERROR: User namespaces are not usable by BitBake, possibly due to AppArmor.
>
> Measured on such a host (Ubuntu 24.04, kernel 7.0, `sodev-builder-rpi`, wrynose poky).
> The probe column does what `sanity.bbclass` `check_userns()` does --
> `unshare(CLONE_NEWNET|CLONE_NEWUSER)`, then write `/proc/self/uid_map`; the BitBake
> column is a real `bitbake -p` in the DomD build directory with the sanity cache cleared
> (the check runs once per build directory, so a passed cache hides it):
>
> | `docker run` options | probe | BitBake |
> |---|---|---|
> | (none) | `unshare` itself fails, EPERM (default seccomp) | **passes** (`bitbake -p` rc=0) -- "cannot unshare" is treated as "no isolation available" |
> | `seccomp=unconfined` | succeeds, uid unchanged | passes (probe; the check's success condition) |
> | `seccomp=unconfined` + `apparmor=unconfined` + `systempaths=unconfined` | **EPERM, uid becomes nobody** | **fails** (`bitbake -p`: "User namespaces are not usable by BitBake", rc=1) |
> | `--privileged` | **EPERM, uid becomes nobody** | fails (probe; privileged implies unconfined) |
>
> Hence the split above: the relaxation goes in `XT_DOCKER_RUN_OPTS_AOSP` and reaches only
> the AOSP container, and `build.sh` refuses `apparmor=unconfined`/`--privileged` in the
> global `XT_DOCKER_RUN_OPTS` on such a host before starting (it used to fail at the DomU
> bitbake, thirty minutes in after the AOSP `repo sync`).
>
> **But `apparmor=unconfined` does not rescue nsjail on such a host either.** nsjail creates
> its own user namespace (its parent writes the child's `uid_map`, which is allowed), and
> with the sysctl at 1 a user namespace created by an *unconfined* process has no
> capabilities -- so nsjail's very next step, `mount('/', '/', MS_REC|MS_PRIVATE)`, is
> denied. Measured with the AOSP prebuilt `nsjail` (`prebuilts/build-tools/linux-x86/bin`)
> in the build container, `--chroot` + bind mounts, on this kernel:
>
> | sysctl | `docker run` AppArmor option | nsjail | BitBake probe |
> |---|---|---|---|
> | 1 | (docker-default), `seccomp=unconfined` | fails: `mount('/','/',MS_REC\|MS_PRIVATE): Permission denied` | passes |
> | 1 | `apparmor=unconfined` (+ seccomp/systempaths unconfined) | **fails, same mount denied** | fails |
> | **0** | `apparmor=unconfined` (+ seccomp/systempaths unconfined) | **passes** | **passes** |
> | **1** | **confining profile below** (+ seccomp/systempaths unconfined) | **passes** | **passes** |
>
> So on Ubuntu 24.04 there are exactly two working setups, and `build.sh` refuses the
> unconfined form in `XT_DOCKER_RUN_OPTS_AOSP` when the AOSP build is going to run:
>
> 1. **Keep the hardening, confine the AOSP container with a profile that allows what
>    nsjail needs** (least privilege; the same idea as the host-side nsjail profile that
>    Ubuntu bug 2063976 and community write-ups use). Load it once on the host:
>
>        sudo tee /etc/apparmor.d/docker-nsjail-build >/dev/null <<'EOF'
>        #include <tunables/global>
>        profile docker-nsjail-build flags=(attach_disconnected,mediate_deleted) {
>          #include <abstractions/base>
>          network,
>          capability,
>          file,
>          umount,
>          mount,
>          pivot_root,
>          userns,
>          signal,
>          ptrace,
>          unix,
>        }
>        EOF
>        sudo apparmor_parser -r /etc/apparmor.d/docker-nsjail-build
>
>    and select it for the AOSP container:
>
>        XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" \
>        XT_DOCKER_RUN_OPTS_AOSP="--security-opt seccomp=unconfined \
>          --security-opt apparmor=docker-nsjail-build \
>          --security-opt systempaths=unconfined" ./build.sh --memory=48g ...
>
>    The profile is broad (it is a build sandbox's sandbox, not a security boundary), but
>    the container stays *confined*, which is what the userns restriction keys on. Since
>    BitBake's probe passes under it too, it would even work as the global option; keeping
>    it in `_AOSP` limits the relaxation to the one container that needs it.
>
> 2. **Lower the sysctl for the duration of the build** (Ubuntu's documented workaround; it
>    does not survive a reboot), and use `apparmor=unconfined` as before:
>
>        sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

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
| `./build.sh -z` | + DomZ (Zephyr RTOS domain) | no |

`-z` adds a second **west** workspace (`zephyr-domz/`) and one more Zephyr build; it
costs a few minutes and no Yocto work, so it combines freely with any of the rows
above. The guest is board-independent (`xenvm`), so the same image is valid under Xen on
either board — see [`domz/README.md`](../domz/README.md) for what the domain is and how
to bring it up.

The rest of this walkthrough uses the third row, which is the full cockpit on the Zephyr
Dom0 (`--dom0=zephyr` is the default, so it needs no flag). `-a` is a synonym for
`--aaos=auto`; name `--aaos=source` explicitly when you have nothing to start from, because
`auto` has nothing to choose between. If you already have an AOSP checkout or a repo object
mirror, see *Which starting point do you have?* -- it saves the sync, not the build.

Every command above builds for a **Raspberry Pi 5**, which is the default. Add
`--board=rpi4` to build for a Raspberry Pi 4 Model B instead; that switches the whole
configuration (`rpi4-sodev.yaml` instead of `rpi5-sodev.yaml`, `meta-xt-rpi4` instead of
`meta-xt-rpi5`, BCM2711 device trees and memory map) and changes what `--ram` accepts --
`8g`/`4g` there, `16g`/`8g` on the Pi 5. Nothing else in this walkthrough differs. What
is verified on that board is listed in `meta-rpi-sodev/meta-xt-rpi4/README.md`.

> **The builder image needs Zephyr SDK 1.0.1 and a python3.12 virtualenv**, because
> Zephyr 4.4 sets `PYTHON_MINIMUM_REQUIRED 3.12` and Ubuntu 22.04 ships 3.10. You do
> not need `--rebuild-images` for that: this series also renames the tag, so
> `sodev-builder-rpi` does not exist yet on your host and the first build creates it
> with both. `--rebuild-images` is for the case where `XT_DOCKER` names an image built
> before that change, which fails in cmake with `Could NOT find Python3: Found
> unsuitable version "3.10.12", but required is at least "3.12"` -- see *A Zephyr build
> cannot find Python 3.12* (`docs/TROUBLESHOOTING.md`).

### 4. Build the container image

Nothing to do -- `build.sh` builds `sodev-builder-rpi` from `docker/Dockerfile.builder` on
first use and reuses it afterwards. The first run prints:

```
>> docker build sodev-builder-rpi  (-f docker/Dockerfile.builder)
```

and later runs print nothing, because `build_img` skips a tag that already exists.

To see whether it is there already:

```sh
docker image inspect sodev-builder-rpi >/dev/null 2>&1 && echo present || echo absent
docker images sodev-builder-rpi
```

To build it yourself -- the same command `build.sh` runs, so the result is
interchangeable with it:

```sh
docker build -f docker/Dockerfile.builder docker/ \
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  -t sodev-builder-rpi
```

Behind a proxy, add the same build args `build.sh` would pass. Pass **only the ones you
actually have a value for**: these are Docker's predefined proxy build args, so the
Dockerfile declares no `ARG` for them and nothing is stored in the image -- but a
*defined-but-empty* `http_proxy` is worse than an unset one (see the note below the
Dockerfile):

```sh
docker build -f docker/Dockerfile.builder docker/ \
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
  --build-arg https_proxy="$HTTPS_PROXY" --build-arg http_proxy="$HTTPS_PROXY" \
  --network=host \
  -t sodev-builder-rpi
```

`--network=host` is only needed when the proxy or a mirror listens on the **host's**
loopback; `build.sh` does the same via `XT_DOCKER_NETWORK=host`.

To force a rebuild -- **required after changing the Dockerfile**, because `build.sh`
reuses an existing tag without checking it. A *proxy* change does not need one: the
proxy reaches the `RUN` layers as a build arg and is never stored in the image:

```sh
./build.sh --rebuild-images -u --aaos=source      # via build.sh
REBUILD_IMAGES=1 ./build.sh -u --aaos=source      # same thing, env form
docker build --no-cache -f docker/Dockerfile.builder docker/ -t sodev-builder-rpi   # by hand
```

To look inside without building anything:

```sh
docker run --rm -it -v "$PWD":"$PWD" -w "$PWD" sodev-builder-rpi
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
| container image built (first run only) | `>> docker build sodev-builder-rpi` |
| DomU (AGL) bitbake, if `-u` | `>> DomU(AGL) in sodev-builder-rpi:` |
| AOSP `repo init` + `repo sync`, ~1379 projects | `[N/M] Initialize repo directory` |
| AAOS guest kernel (bazel) and the AOSP build | `Invoke Android build system` |
| DomD / Dom0 Yocto builds | `Yocto Build: domd`, `Invoke Zephyr build system` |
| SD image assembled | `rouge rpi5-sodev.yaml ...` |
| done | `Build complete.` |

The build is incremental and the `ninja` step is wrapped in a bounded retry, so a transient
network abort resumes rather than restarting. If it stops, read the message: the common
failures each have an entry in [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

### 6. Check what you got

    ls -lL full.img           # ~27.7 GB, sparse (-L follows the symlink)
    sfdisk -l full.img        # four partitions

`build.sh` names the image after the configuration that produced it and points
`full.img` at the newest one:

    <board>-<SKU>-Dom0<Zephyr|Linux>[-DomU][-DomA][-DomZ]-<YYYYmmdd-HHMM>.img

so `rpi4-4GB-Dom0Zephyr-DomA-20260809-1750.img` is a 4 GiB Raspberry Pi 4 image
with a Zephyr Dom0 and DomA (no DomU -- on this SKU that pair is refused, see
BOARD_RAM), built at 17:50 local time. A
guest that was not built leaves its token out, so the name says what is on the
card rather than what was asked for. The point is that a second build does not
overwrite the first, and an image found later can still be identified — nothing
inside a 27 GB file says which board or SKU it was assembled for.

To judge a rebuild against an image that is known to boot — before spending an
SD write and a board on it — see `tools/compare-sd-image.py`; its module
docstring explains what "identical" can and cannot mean per artifact class.

A complete image has four partitions:

| # | Name | Size | Contents |
|---|---|---|---|
| 1 | `boot` | 512 MiB | FAT, populated by rouge from the yaml: RPi firmware (`bootcode.bin`, `start*.elf`, `fixup*.dat`, `config.txt`, `cmdline.txt`; rpi5 adds `armstub8-2712.bin`, rpi4 `bl31.bin`), `u-boot`, `xen`, the DomD kernel `Image` and DTBs (board DTB, the Xen DTBO, `*-domd-vc4.dtb`; rpi5 `overlays/bcm2712d0.dtbo`, rpi4 `overlays/disable-bt.dtbo`), `boot.scr`; then per option: `zephyr.bin` (Zephyr Dom0) or `initramfs-xt-dom0-thin.cpio.gz` (Linux Dom0), `linux-domu` (`-u`), the two DomA boot artifacts `aaos-android-kernel` + `aaos-vendor-boot-ramdisk` (`-a`), `zephyr-domz.bin` (`-z`) |
| 2 | `domd` | 9216 MiB | DomD (driver domain) rootfs |
| 3 | `domu` | 2048 MiB | DomU AGL instrument-cluster rootfs (present with `-u`) |
| 4 | `android` | ~14662 MiB (measured) | DomA as a nested GPT (present with DomA). Not a fixed size: the six explicitly sized members (`*_b` slots, `misc`, `metadata`) total 172 MiB, the four `_a` slots take their image's size, and `super` / `userdata` follow the AOSP output (the yaml omits `size:` for them on purpose) -- so it changes with every AOSP build |

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
| `sodev-builder-rpi` (`XT_DOCKER`) | `docker/Dockerfile.builder` | everything: moulin + ninja (Yocto/Xen/Zephyr; pinned moulin revision), the AOSP/AAOS (DomA) build, and the DomU AGL bitbake |

The tag is `sodev-builder-rpi`, not `sodev-builder`: the V4H `sodev-demo-workspace` builds
a different image under that name, and a host that builds both must not have one
workspace's `--rebuild-images` replace the other's image. Override with `XT_DOCKER`;
`AGL_DOCKER` follows it.

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
> **Where the proxy is configured matters, and there are three places.** `build.sh`
> forwards `HTTPS_PROXY`/`HTTP_PROXY` (or `--proxy`) as Docker's predefined build args and
> as `-e` to every container. Docker has two proxy settings of its own that this does
> *not* replace: the **client** config `~/.docker/config.json` (`proxies.default` --
> injected into containers and builds *only when the caller passes no proxy variables*;
> an explicit value from `build.sh` overrides it), and the **daemon** config
> (`/etc/systemd/system/docker.service.d/http-proxy.conf`, `Environment=HTTPS_PROXY=...`),
> which is what `docker pull` of a base image uses and which `build.sh` cannot set for you.
> Behind a proxy, `FROM ubuntu:22.04` in `docker build` fails until the daemon one is set.
>
> **A proxy bound to the host's loopback** (`127.0.0.1:3128`, `localhost:3128`) is a
> special case: a bridged container's `127.0.0.1` is the container, so the forwarded value
> is unreachable and the symptom is not a proxy error -- `docker build` dies in the first
> `apt-get` with dozens of `Unable to locate package` lines, because `apt-get update`
> fetched nothing. `build.sh` now refuses such a value before starting (unless
> `XT_DOCKER_NETWORK=host`) and prints the ways out: `--proxy=http://<bridge gateway>:<port>`
> (`docker network inspect bridge`, typically `172.17.0.1`; the proxy has to listen on that
> address too -- `ss -lntp`), `XT_DOCKER_NETWORK=host`, or unsetting the variables so the
> client config above applies.
>
> **Proxy changes do not need `--rebuild-images`.** The proxy is not stored in the
> `sodev-builder-rpi` image: `Dockerfile.builder` declares no `ENV` for it -- a
> defined-but-empty `http_proxy` makes the AOSP `repo` launcher proxy through nothing
> and fail every fetch -- and `build.sh` passes the variables that have a value per
> run with the bare `-e VAR` form. A **Dockerfile** change still needs
> `--rebuild-images` once, because `build.sh` reuses an existing image by tag and
> will *not* rebuild it otherwise.
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
  --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" -t sodev-builder-rpi
docker run --rm -it -v "$PWD":"$PWD" -w "$PWD" sodev-builder-rpi
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
workspace's `yocto/common_data/sstate`. Note how they take effect: `build.sh` replaces
`yocto/common_data/downloads` and `yocto/common_data/sstate` with **symlinks** to the
directories you name (an empty existing directory is removed first). If either is a
**non-empty real directory** -- a workspace that has already built once without the
flags -- `build.sh` stops with an error rather than hide that content behind a link; move
it away, or point the flag at that directory itself. `XT_CACHE_MOUNTS` (a list of extra
`docker -v HOST:CONTAINER` specs) is the general-purpose way to make some other host
directory visible inside the containers; the flags above already mount what they name.
This shared cache is used by **both**
the moulin/sodev-builder-rpi build (Dom0/DomD/DomU-kernel/DomA) **and** the DomU AGL
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

This project provides additional parameters; check them with `--help-config`. There is one
yaml per board -- `rpi5-sodev.yaml` and `rpi4-sodev.yaml` -- and they take the same four
parameters, differing only in the SKUs `--BOARD_RAM` accepts:

```
$ moulin rpi5-sodev.yaml --help-config
usage: moulin rpi5-sodev.yaml [--DOM0_OS {zephyr,linux}]
                              [--BOARD_RAM {16g,8g}] [--ENABLE_DOMU {no,yes}]
                              [--ENABLE_ANDROID {no,yes}]

Config file description: Raspberry Pi 5 + Xen 4.22 — AGL SoDeV disaggregated
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
# moulin rpi4-sodev.yaml --BOARD_RAM 8g                       # Raspberry Pi 4 (BOARD_RAM is 8g|4g there)
ninja                # builds the configured domains (takes time and disk)
ninja image-full     # assembles full.img (the GPT SD image)
```

`ninja image-full` writes `full.img` into the build root (the directory you
ran moulin in). The descriptive name is `build.sh`'s doing, not rouge's, so on
the manual path you get plain `full.img` and it is on you not to overwrite the
previous one.

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
| DomA guest kernel | the `doma_kernel` component (bazel, GKI 6.18.32 + `xen-virtual-device`) | SD p1 `aaos-android-kernel` |
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

    ninja fetch-doma_kernel fetch-doma
      && meta-rpi-sodev/meta-xt-common/meta-xt-doma/stage-aosp-device.sh "$PWD/<aosp>" <board>
      && ninja doma_kernel
      && meta-rpi-sodev/meta-xt-common/meta-xt-doma/stage-doma-kernel.sh \
             "$PWD/<kernel>/<deploy dir>" "$PWD/<aosp>" <stage dir>
      && ninja doma
      && ninja image-full

The two staging steps are why this is not a plain `ninja doma_kernel doma`: moulin has no
hook between `repo sync` and the AOSP build, so the board's AAOS product variant
(a no-op on rpi5) and the guest kernel copy Soong insists on have to be inserted between
the goals. The directory names come from the board yaml, which is why the command above
shows them as placeholders; run `build.sh` and it prints the exact line it uses.

Ordering costs nothing here. Every moulin builder rule (yocto, android, bazel, zephyr)
declares ninja's `console` pool, whose depth is 1, so the components are serialised
either way — this only fixes *which* order.

If you drive ninja by hand, run that whole sequence, not just the two goals: skipping
`stage-doma-kernel.sh` builds the AOSP images against a stale kernel copy. See
*Keep the guest kernel and the p4 images coherent*. This also applies to
`--domains-only`: it still builds DomD, and moulin's default ninja target does *not*
include `doma`/`doma_kernel`.

### Keep the guest kernel and the p4 images coherent

The guest kernel, its modules and `super.img`'s `vendor_dlkm` must come from one
consistent pair, or ~97 guest modules fail `disagrees about version of symbol
module_layout` and AAOS never reaches SurfaceFlinger — `sys.boot_completed` still goes
to 1 and `screencap` still returns a real UI, so the only visible symptom is a black
panel.

`doma` consumes `doma_kernel`'s output via `TARGET_PREBUILT_KERNEL` /
`TARGET_PREBUILT_MODULES_DIR`, but since Android 16 it cannot read it where bazel left
it: Soong rejects a source path outside its own tree, so `stage-doma-kernel.sh` copies
the dist into the AOSP checkout and those two variables name the copy
(see *How the DomA artifacts are produced*). **That copy is not a ninja edge** — moulin
owns the ninja file — so the graph cannot keep it fresh, and the two halves can drift
apart: p4's `vendor_dlkm` comes from the copy, p1's kernel from the dist.

Three things hold it together, and only the third one catches drift:

| | catches |
|---|---|
| `build.sh` runs the staging on every invocation, between `ninja doma_kernel` and `ninja doma` | the normal path — the copy is never stale if you use `build.sh` |
| `doma`'s `additional_deps` names both the dist Image and the staged Image | a rebuilt kernel re-runs the AOSP build; a checkout where the staging never ran fails loudly |
| `aaos-guest-binaries` compares the staged copy against the dist byte for byte before shipping either | a copy that exists but is **stale** — the only case the other two miss |

So driving ninja by hand is not enough on its own: `ninja doma_kernel doma` builds the
AOSP images against whatever copy is lying around. If you do it anyway, the recipe stops
the build rather than shipping the mismatch, and names the fix.

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

### Prebuilt bundles are board-specific

A prebuilt AAOS bundle is not portable between boards. The AAOS guest is compiled for the
ISA of the host cores it runs on — a virtio guest still executes on the host's CPUs — and
`xenvm_trout_rpi4_arm64` builds with `TARGET_CPU_VARIANT := cortex-a72` where the upstream
product uses `cortex-a53`, whose LLVM feature set implies the ARMv8 crypto extensions that
a Cortex-A72 does not have.

Nothing about the images makes that visible. `MANIFEST.md5` answers *is this bundle
intact*, not *is this bundle for this board*: a correctly formed bundle for the other
board verifies perfectly, stages, gets assembled into p4, and the build exits 0 — and then
the guest dies in `/init` with SIGILL on the first boot. Yocto has no equivalent hazard
because `PACKAGE_ARCH` is part of every sstate key and `DEPLOY_DIR_IMAGE` is per MACHINE;
a bundle of images has neither.

The board is not the only thing a bundle is specific to. The guest **generation** is the
other. An Android 15 bundle for the *same* device name (the V4H workspace produced those
for `xenvm_trout_arm64`, which is also rpi5's device) passes a board/device check. This
tree stages and verifies Android 17 / GKI 6.18.32 guests only, and the measured failure
in this family is a *mixed* set: a guest kernel and a `vendor_dlkm` from different builds
share no `module_layout`, and the guest boots to a black panel. Until this check existed,
only the staged kernel's file name (`...-6.1.118` vs `...-6.18.32`) happened to catch a
15 bundle.

So a bundle declares what it is, in a `BUNDLE-INFO` file beside `MANIFEST.md5`:

```
board=rpi4
device=xenvm_trout_rpi4_arm64
android=17                      # Android major version of the guest
guest_kernel=6.18.32            # GKI kernel version its kernel/vendor_dlkm were built from
cpu_variant=cortex-a72          # optional, informational
```

`build.sh` refuses a bundle whose `board=` (or `device=`) disagrees with `--board`, and one
whose `android=` / `guest_kernel=` disagree with the generation this tree builds
(`AAOS_GUEST_ANDROID`, default 17; `AAOS_GUEST_KERNEL`, default 6.18.32 -- both
overridable in the environment, and the kernel version also names the staged kernel
artifact the recipe consumes). A `BUNDLE-INFO` written before those two lines existed is
accepted with a note, assuming this tree's generation. The default probe prefers
`<workspace>/aaos-prebuilt-<board>/` over the untagged `<workspace>/aaos-prebuilt/`, so
the two can coexist.

A bundle with **no** `BUNDLE-INFO` is refused. It used to be accepted for `--board=rpi5`
on the reasoning that every untagged bundle predated the second board; that was true of
the bundles this tree had produced and false of the world (the V4H bundles above are
untagged too). Add the file -- it travels with the bundle -- or, for one run, assert what
the bundle is with `AAOS_PREBUILT_ASSUME_BOARD=<board>`; that asserts board, device and
generation alike, unverified.

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
- `<dir>/files/` — `aaos-android-kernel-xenbuilt-6.18.32` (the version is `AAOS_GUEST_KERNEL`) and
  `aaos-vendor-boot-ramdisk-xenbuilt-padded`,
- `<dir>/BUNDLE-INFO` -- required; declares board, device and guest generation (see *Prebuilt
  bundles are board-specific* above), and
- optionally `<dir>/MANIFEST.md5`.

The two `files/` artifacts are needed because **`prebuilt` cannot derive them**: deriving
needs the AOSP checkout (`system/tools/mkbootimg/unpack_bootimg.py`) and the bazel guest
kernel, and skipping the AOSP build is the entire point of the mode. `build.sh` copies
them into `meta-xt-doma/recipes-bsp/aaos-guest-binaries/files/` (`.gitignore`d — build
inputs, never committed) and the recipe then uses them verbatim instead of deriving.
Everything in a bundle -- the two `files/` artifacts and the six `images/` -- must come
from **one** build, for the ABI reason above. (Bundles used to carry two gRPC server
binaries and a NOTICE in `files/` as well; those are built from source and committed now,
so a current bundle has two `files/`, not five.)

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

Measured on Android 17 (24-core host capped to 16 with `--cpuset-cpus`, `--memory=48g`,
warm Yocto sstate, DomA + DomU, Zephyr Dom0): **334 GiB** of workspace — `android/`
277 GiB (of which `out/` 138 GiB), `android_kernel/` 35 GiB, `agl/` 11 GiB, `yocto/`
11 GiB — plus a ~26 GiB (27.7 GB) SD image, ~360 GiB in all. The AOSP step alone is **1 h** once its `out/` is warm;
a cold one is several hours and dominates the total.

The Android 15 equivalent was 272 GiB and 5 h 11 min end to end on a 32-core host, so
17 costs about 90 GiB more. Budget more than either figure: these are one host's, the
AOSP build scales with core count, and a cold Yocto sstate adds to the Yocto share (the
11 GiB above is with a warm one; 15 measured 31 GiB cold). Everything after the first run
is incremental.

**Case B — a repo object mirror.** If your site keeps a mirror (an exported
`*-project-objects` tree, or another repo client), point `--aaos-ref` and
`--aaos-kernel-ref` at it. `build.sh` seeds each checkout with
`repo init --reference=<dir>` before moulin runs, so the sync reads objects locally
instead of over the network:

    ./build.sh -u --aaos=source \
      --aaos-ref=/mirror/aosp --aaos-kernel-ref=/mirror/aosp-kernel

The two mirrors are easy to pass the wrong way round, and the cost is invisible: both
are repo clients full of bare `*.git` repositories, so `repo init --reference` accepts
either, then falls back to the network for every project while the log looks entirely
normal. `build.sh` therefore checks *which* tree each mirror holds, using projects that
only one of the two manifests carries — `platform/bionic.git` for AOSP,
`kernel/common.git` for the guest kernel — and refuses a swap by name. One mirror may
still serve both flags; only a positive swap (the other tree's projects present and this
tree's absent) is an error, and a mirror that carries neither is passed with a note.

The AOSP and guest-kernel checkouts are also board-specific: `rpi4-sodev.yaml` puts them
in `android-rpi4/` and `android_kernel-rpi4/` where the Pi 5 uses the historical
`android/` and `android_kernel/`. Beyond keeping the two boards' trees apart — DomA is
compiled for the host ISA, so they are not interchangeable — this is what makes a wrong
mirror fail *now*: with one shared directory the second board finds the first board's
populated checkout, moulin skips the `repo init`, and the wrong mirror goes unexercised
until someone builds from a clean tree hours later.

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

    XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" ./build.sh -u --aaos=source ... --memory=48g

Measured on a 32-core host: on **Android 17** `soong_build` alone peaks at 42.6 GiB, so
the cap has to be 48g and the host wants 64 GiB (see *Check the host* at the top of this
document, which is the current figure). The Android 15 measurement this section was first
written from — killed at `nproc`=32, peak ~19 GiB at `nproc`=16 with a 44 GiB cap — is
kept only to show that the CPU count, not the cap, is what moves the peak. A warm `--aaos-src` tree does not reproduce it (its `m` finishes in minutes),
so verify on a cold build. `build.sh` recognises the kill and stops instead of spending its
retries on it — see *`ninja failed with: signal: killed`* (`docs/TROUBLESHOOTING.md`).

⚠ The AOSP target is board-specific since the Android 17 move:
`aosp_xenvm_trout_rpi5_arm64-trunk_staging-userdebug` on a Pi 5 and
`aosp_xenvm_trout_rpi4_arm64-trunk_staging-userdebug` on a Pi 4 (ANDROID_LUNCH_TARGET
in the product yaml). The upstream product they derive from is
`xen-troops/android_device_epam_xenvm-trout` (Google's own AOSP tree stops at
`aosp_trout_arm64`).

Each board gets a product of its own, but they arrive differently. The **Pi 4** product
is a repo project: the AOSP manifest names
`automotive-grade-linux/Android_device_sodev_xenvm-cf` at `device/sodev/xenvm-cf` in the
`notdefault,rpi4` group, and `XT_DOMA_SOURCE_GROUP: "default,rpi4"` in
`rpi4-sodev.yaml` makes `repo init` ask for it (repo *replaces* the group set, so
`default` has to be named too). It exists because the Cortex-A72 is not the CPU the
upstream board config assumes, and it needs its own `PRODUCT_DEVICE`. The **Pi 5**
product is still staged into the checkout by `meta-xt-doma/stage-aosp-device.sh`, for
one line -- the `PRODUCT_COPY_FILES` that installs `init.xenvm-buried-eth0.rc`, without
which minradio retries `setupDataCall` at 7-13 Hz. That rc is destined for the upstream
device tree (`device/epam/aosp-xenvm-trout`) in a gated, opt-in form once the maintainer
agrees; until then it is carried here in the exact form the hardware verification ran,
and a copy of it travels with the Pi 4 device for the same reason. `stage-aosp-device.sh`
runs for both boards either way: it stages for the Pi 5 and, for the Pi 4, checks that
the manifest actually delivered the project, because a forgotten group flag otherwise
surfaces as `lunch` reporting "Can't find a product spec".

The two manifests are `yhamamachi/android_manifest` (the AOSP tree: stock public AOSP
`android-17.0.0_r1` plus that device layer and mesa) and
`yhamamachi/android_kernel_manifest` (the GKI guest kernel), both on branch
`android-17-xenvm-sh-main` and both pinned by commit in the product yamls -- the same
arrangement V4H uses for its own two manifests. Three changes are needed on top of those
branches, and they are not all in the same state: Mesa pinned at 25.3.6, which the
Android 17 toolchain needs, is **merged upstream** (it was squashed, so the commit id
differs from the one submitted, but the resulting tree is identical); the pinned kernel
manifest added alongside the branch-tracking one (the kernel component selects it with
`manifest:`) has **an open pull request**; and the Pi 4 device project described above is
**not submitted upstream, deliberately** — it is one `<project>` line naming an
AGL-hosted repository in the `notdefault` group, of no use to anyone not building this
board, so it is carried on a fork rather than asked of the upstream manifest.

⚠ **Both `url:` values therefore point at the author's forks** —
`yuichi-kusakabe/android_manifest` @ `android-17-xenvm-rpi-device` (tag
`rpi4-device-v1`) and `yuichi-kusakabe/android_kernel_manifest` @
`android-17-xenvm-rpi-pinned`. Each is upstream's own branch plus that one commit and
nothing else, so DomA builds from a clean checkout. **Each pin is its own commit at the
end of the series**, so the kernel one can be reverted when its pull request lands
without touching the AOSP one. Those refs are never force-pushed and the fork stays
public, because a pinned revision has to stay fetchable for as long as the yaml names
it — open-ended on the AOSP side, until the merge on the kernel side. The yamls say what
would move each url back. The upstream Google
copy of the trout Yocto layer points at `partner-android.googlesource.com` and
`sso://googleplex-android/`, neither of which is anonymously reachable — the EPAM fork
is what makes a clean build possible.
