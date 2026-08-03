#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# sodev-demo-workspace-rpi orchestrator (Docker-based).
# Mirror of AGL sodev-demo-workspace/build.sh:
#   - DomU (AGL Flutter): built OUTSIDE moulin via repo+aglsetup+bitbake in the AGL builder image.
#   - DomA (AAOS): built from AOSP source (--aaos=source; heavy) OR consumed from a
#     prebuilt bundle (--aaos=prebuilt; no AOSP build). rouge assembles the p4 nested
#     GPT either way (V4H android_only style). See --aaos / README "AAOS build modes".
#   - Dom0/DomD (rpi5 base) + final SD image: moulin + ninja in sodev-builder.
# The default build is Dom0(Zephyr)+DomD only; the DomU and DomA guests are opt-in
# (-u / -a), matching upstream sodev-demo-workspace (commit f3f0f8f7 "Disable
# Android and Flatcar guests by default"). All heavy build steps run in Docker (per
# project policy); the build images are defined under docker/ and built on demand.
# Options are V4H build.sh-style flags; the matching env vars are the fallback.
set -euo pipefail

workdir="$(cd "$(dirname "$0")" && pwd)"
cd "$workdir"

# --- knobs (flag defaults; each is overridable by env or by the flags below) ---
DOM0_OS="${DOM0_OS:-zephyr}"                       # --dom0=zephyr|linux
BOARD_RAM="${BOARD_RAM:-16g}"                      # --ram=16g|8g : target Raspberry Pi 5 SKU (16 GiB default; 8g takes DomD and DomA to 3072 MiB each)
ENABLE_DOMU="${ENABLE_DOMU:-no}"                   # -u/--domu    : add DomU (AGL cluster: p1 kernel + p3 rootfs)
ENABLE_ANDROID="${ENABLE_ANDROID:-no}"             # -a/--android : add DomA (AAOS p4 nested GPT; heavy)
NINJA_TARGET="${NINJA_TARGET-image-full}"          # --domains-only => "" (build domains, skip SD assembly)
AAOS_SRC_DIR="${AAOS_SRC_DIR:-}"                    # --aaos-src=<dir>       (reuse an AOSP checkout, source mode)
AAOS_MODE="${AAOS_MODE:-}"                          # --aaos=off|auto|source|prebuilt (empty: derived from -a — off, or auto when -a given)
AAOS_PREBUILT_DIR="${AAOS_PREBUILT_DIR:-}"          # --aaos-prebuilt=<dir>  (prebuilt AAOS bundle: files/ + images/)
AAOS_REQUIRED=""                                    # set by -a/--android: DomA is required, so auto must NOT silently fall back to off
XT_SSTATE_DIR="${XT_SSTATE_DIR:-}"                  # --sstate=<dir>
XT_DL_DIR="${XT_DL_DIR:-}"                          # --dl=<dir>
XT_WEST_CACHE_DIR="${XT_WEST_CACHE_DIR:-}"          # --west-cache=<dir> (west reference workspace: Zephyr Dom0 manifest+projects; DL_DIR analogue)
REBUILD_IMAGES="${REBUILD_IMAGES:-0}"              # --rebuild-images
XT_DOCKER_NETWORK="${XT_DOCKER_NETWORK:-}"         # --network for the build containers, e.g. "host"
XT_DOCKER_RUN_OPTS="${XT_DOCKER_RUN_OPTS:-}"       # extra `docker run` opts for the build containers, e.g. "--memory=48g --cpus=12" (recommended on shared hosts to bound the heavy AOSP/Yocto steps; empty = no limit)
PROXY="${HTTPS_PROXY:-}"                            # --proxy=<url>
MOULIN_YAML="rpi5-sodev.yaml"
AGL_IMAGE="${AGL_IMAGE:-agl-cluster-demo-flutter-guest}"
AGL_MACHINE="${AGL_MACHINE:-virtio-aarch64}"
XT_DOCKER="${XT_DOCKER:-sodev-builder}"                # unified build image: moulin/ninja (Yocto/Xen/Zephyr) + AOSP + AGL bitbake (docker/Dockerfile.builder)
AGL_DOCKER="${AGL_DOCKER:-sodev-builder}"  # DomU AGL bitbake image (defaults to the unified image; set to the AGL-official docker-worker to use it instead)
XT_DOCKER_MEMORY="${XT_DOCKER_MEMORY:-}"           # --memory=<size> : cap build-container RAM (docker --memory + --memory-swap, e.g. 24g). Empty => unlimited (current behavior)

Usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

  RPi5 + Xen 4.21 AGL SoDeV disaggregated cockpit builder.
  Default build = Dom0(Zephyr) + DomD only; guests are opt-in (upstream
  sodev-demo-workspace f3f0f8f7 "disable Android/Flatcar by default").

Domain options:
  -u, --domu             Build DomU (AGL instrument cluster: p1 kernel + p3 AGL rootfs)
  -a, --android          Include DomA (AAOS, p4 nested GPT). Alias for --aaos=auto
                         (how DomA is produced is chosen by --aaos).
      --dom0=<os>        Dom0 OS: zephyr (default) | linux
      --ram=16g|8g       Target Raspberry Pi 5 SKU. 16g (default) = full 4-domain map
                         (Dom0 512 + DomD 4096 + DomU 1024 + DomA 4096 = 9728 MiB).
                         8g = DomD 3072 MiB (static-mem bank4 dropped) and DomA
                         3072 MiB; Dom0/DomU keep their sizes, total 7680 MiB
                         and fit an 8 GB board with ~436 MiB headroom.
      --domains-only     Build the domains but skip SD-image assembly (no full.img;
                         with -a this also skips the DomA p4 nested GPT, which rouge
                         assembles only during SD-image assembly)

DomA (AAOS) options:
      --aaos=<mode>      off | auto | source | prebuilt   (default: off; -a => auto)
                           off      : DomA-less SD (no p4 Android)
                           source   : build AAOS from AOSP source (heavy: ~250GiB, 1-3h)
                           prebuilt : consume a prebuilt AAOS bundle; NO AOSP build (fast)
                           auto     : prebuilt if a bundle is found, else source if an
                                      AOSP checkout is found, else off
      --aaos-prebuilt=<dir>  Prebuilt AAOS bundle (layout: files/ + images/). Used by
                             prebuilt/auto. Default probe: <workspace>/aaos-prebuilt
      --aaos-src=<dir>       Reuse an existing AOSP checkout for source mode (skip repo sync)

Build environment:
      --sstate=<dir>     Reuse an external Yocto sstate cache
      --dl=<dir>         Reuse an external Yocto downloads dir
      --west-cache=<dir> Reuse a west reference workspace (Zephyr Dom0 manifest+projects)
      --proxy=<url>      HTTP(S) proxy for docker builds + fetches
      --rebuild-images   Force-rebuild the docker/ build image (REQUIRED after changing
                         --proxy: the value is baked into the image)
      --memory=<size>    Cap build-container RAM (docker --memory + --memory-swap,
                         e.g. 24g). Default: unlimited.
  -h, --help             Show this usage

Environment (no flag):
      XT_DOCKER_MEMORY   Same as --memory=<size> (cap container RAM; empty = unlimited).
      XT_DOCKER_NETWORK  --network value for the build containers (e.g. "host").
                         Needed when the build must reach a proxy or mirror on the
                         host's loopback. Default: Docker's bridge.
      XT_DOCKER_RUN_OPTS Extra `docker run` opts applied verbatim to every build
                         container, e.g. "--cpus 12" (empty = none).

Examples:
  ./build.sh                                        # Dom0(zephyr)+DomD only (fast; DomU/DomA-less SD)
  ./build.sh -u                                     # + DomU (AGL cluster)
  ./build.sh -u --aaos=prebuilt --aaos-prebuilt=$HOME/aaos-bundle   # + DomU + DomA from prebuilt (no AOSP build)
  ./build.sh -u --aaos=source   --aaos-src=$HOME/aosp    # + DomU + DomA built from AOSP source
  ./build.sh --dom0=linux -u -a                     # Linux Dom0, DomA auto (prebuilt if bundle, else source)
EOF
}

# --- parse V4H-style flags (override the env defaults above) ---
# needval: a space-form value option must have a following value, else fail with a
# clear message (otherwise the option's own shift empties $@ and the loop's trailing
# shift aborts under `set -e` with NO diagnostic — undebuggable in CI).
needval() { [ "$1" -ge 2 ] || { echo "ERROR: option '$2' requires a value" >&2; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--domu)          ENABLE_DOMU=yes ;;
    -a|--android)       ENABLE_ANDROID=yes ;;   # "want DomA"; required-ness is derived below (only when no explicit --aaos)
    --dom0)             needval $# "$1"; DOM0_OS="$2"; shift ;;
    --dom0=*)           DOM0_OS="${1#*=}" ;;
    --ram)              needval $# "$1"; BOARD_RAM="$2"; shift ;;
    --ram=*)            BOARD_RAM="${1#*=}" ;;
    --domains-only)     NINJA_TARGET="" ;;
    --aaos-src)         needval $# "$1"; AAOS_SRC_DIR="$2"; shift ;;
    --aaos-src=*)       AAOS_SRC_DIR="${1#*=}" ;;
    --aaos)             needval $# "$1"; AAOS_MODE="$2"; shift ;;
    --aaos=*)           AAOS_MODE="${1#*=}" ;;
    --aaos-prebuilt)    needval $# "$1"; AAOS_PREBUILT_DIR="$2"; shift ;;
    --aaos-prebuilt=*)  AAOS_PREBUILT_DIR="${1#*=}" ;;
    --sstate)           needval $# "$1"; XT_SSTATE_DIR="$2"; shift ;;
    --sstate=*)         XT_SSTATE_DIR="${1#*=}" ;;
    --dl)               needval $# "$1"; XT_DL_DIR="$2"; shift ;;
    --dl=*)             XT_DL_DIR="${1#*=}" ;;
    --west-cache)       needval $# "$1"; XT_WEST_CACHE_DIR="$2"; shift ;;
    --west-cache=*)     XT_WEST_CACHE_DIR="${1#*=}" ;;
    --proxy)            needval $# "$1"; PROXY="$2"; shift ;;
    --proxy=*)          PROXY="${1#*=}" ;;
    --rebuild-images)   REBUILD_IMAGES=1 ;;
    --memory)           needval $# "$1"; XT_DOCKER_MEMORY="$2"; shift ;;
    --memory=*)         XT_DOCKER_MEMORY="${1#*=}" ;;
    -h|--help)          Usage; exit 0 ;;
    *) echo "ERROR: unknown option '$1'" >&2; Usage; exit 1 ;;
  esac
  shift
done

# Dom0 OS is a moulin parameter of rpi5-sodev.yaml: --DOM0_OS {zephyr,linux}
# selects the whole dom0 component (Zephyr west/zephyr build vs Linux yocto).
case "$DOM0_OS" in zephyr|linux) ;; *) echo "ERROR: --dom0 must be 'zephyr' or 'linux' (got '$DOM0_OS')" >&2; exit 1 ;; esac
# ENABLE_DOMU reaches moulin verbatim and the in-script gate matches "yes" exactly,
# so a stray value would silently mean "no" yet still pass through — validate it.
# (ENABLE_ANDROID is not validated here: it is derived from the resolved --aaos mode.)
case "$ENABLE_DOMU" in no|yes) ;; *) echo "ERROR: ENABLE_DOMU must be 'no' or 'yes' (got '$ENABLE_DOMU'); use -u/--domu" >&2; exit 1 ;; esac

# --- Board RAM size (moulin parameter BOARD_RAM) -------------------------------
# 16g (default) or 8g. See the BOARD_RAM parameter in the yaml for the full rationale;
# in short, the default map wants 10240 MiB with all four domains, which needs the
# 16 GB board, and 8g takes DomD from 4096 to 3072 MiB and DomA from 4096 to 3072 MiB.
# The split is measured: DomD 2048 alone left the DomA device model unable to serve a
# 4 GiB guest and AAOS crash-looped in binder (hardware, 2026-08-03).
# NOTE: 4g is an RPi4 value; it is rejected here rather than silently accepted.
case "$BOARD_RAM" in
  16g|8g) ;;
  *) echo "ERROR: --ram must be 16g or 8g (got '$BOARD_RAM')" >&2; exit 1 ;;
esac

# --- Resolve the AAOS (DomA) build mode: off | auto | source | prebuilt ---
# -a/--android sets ENABLE_ANDROID=yes; with no explicit --aaos that means "include
# DomA, auto-pick how". ENABLE_ANDROID is then DERIVED from the resolved mode below.
if [ -z "$AAOS_MODE" ]; then
  # -a/--android OR env ENABLE_ANDROID=yes both mean "I want DomA" => auto + required.
  if [ "$ENABLE_ANDROID" = "yes" ]; then AAOS_MODE=auto; AAOS_REQUIRED=yes; else AAOS_MODE=off; fi
fi
case "$AAOS_MODE" in off|auto|source|prebuilt) ;; *) echo "ERROR: --aaos must be off|auto|source|prebuilt (got '$AAOS_MODE')" >&2; exit 1 ;; esac
# Default bundle probe: a fresh clone can drop a bundle at <workspace>/aaos-prebuilt.
[ -n "$AAOS_PREBUILT_DIR" ] || AAOS_PREBUILT_DIR="$workdir/aaos-prebuilt"
# Detect what is available for auto resolution.
# A bundle is usable only if ALL six p4 images are present (a partial bundle must
# not win auto and then hard-fail later; fall through to source/off instead).
aaos_have_bundle=no
if [ -d "$AAOS_PREBUILT_DIR/images" ]; then
  aaos_have_bundle=yes
  for im in boot init_boot vendor_boot vbmeta super userdata; do
    [ -f "$AAOS_PREBUILT_DIR/images/$im.img" ] || aaos_have_bundle=no
  done
fi
aaos_have_source=no
{ [ -n "$AAOS_SRC_DIR" ] && [ -f "$AAOS_SRC_DIR/build/envsetup.sh" ]; } && aaos_have_source=yes
[ -f "$workdir/android/build/envsetup.sh" ] && aaos_have_source=yes
if [ "$AAOS_MODE" = auto ]; then
  if   [ "$aaos_have_bundle" = yes ]; then AAOS_MODE=prebuilt
  elif [ "$aaos_have_source" = yes ]; then AAOS_MODE=source
  elif [ "$AAOS_REQUIRED" = yes ]; then
    # -a explicitly requested DomA but nothing to build it from: fail loudly (do
    # NOT silently ship a DomA-less image and exit 0 — a CI/user asked for DomA).
    echo "ERROR: -a/--android requested DomA, but found neither a prebuilt bundle" >&2
    echo "       (6 images at '$AAOS_PREBUILT_DIR/images/') nor an AOSP source checkout." >&2
    echo "       Pass --aaos-prebuilt=<dir> (files/ + images/) or --aaos=source --aaos-src=<dir>," >&2
    echo "       or drop -a for a DomA-less image (use --aaos=auto to allow the silent fall-back)." >&2
    exit 1
  else
    # Explicit --aaos=auto (not via -a): best-effort, silent fall-back to DomA-less.
    echo ">> AAOS auto: no prebuilt bundle at '$AAOS_PREBUILT_DIR' and no AOSP source;" >&2
    echo ">>   building a DomA-less image (pass --aaos-prebuilt=<dir> or --aaos=source to include DomA)." >&2
    AAOS_MODE=off
  fi
fi
# ENABLE_ANDROID is derived from the resolved mode (drives moulin + yaml DomA gating).
if [ "$AAOS_MODE" = off ]; then ENABLE_ANDROID=no; else ENABLE_ANDROID=yes; fi
echo ">> AAOS mode: $AAOS_MODE  (ENABLE_ANDROID=$ENABLE_ANDROID)"

# --- 8 GB SKU: report the memory budget ---------------------------------------
# Informational, not a warning: with dom0_mem=512M the four domains DO fit an 8 GB
# board (7744 of ~8180 MiB) and the 3072/3072 split is verified to boot all four on
# hardware. The margin is printed because the 8180 figure is EXTRAPOLATED from the
# 16 GB board's total_memory=16372 -- no 8 GB Pi 5 has been measured here -- so if
# `xl create doma.cfg` ever fails to allocate, this is the first line to come back
# to. See the BOARD_RAM parameter in the yaml.
if [ "$BOARD_RAM" = "8g" ] && [ "$ENABLE_ANDROID" = "yes" ]; then
  echo ">> --ram=8g memory budget: Dom0 512 + DomD 3072 + DomU 1024 + DomA 3072"
  echo "   = 7680 MiB (+ Xen ~64) of roughly 8180 MiB usable => ~436 MiB headroom."
  echo "   The 8180 MiB figure is extrapolated, not measured on an 8 GB board."
  echo "   It only fits because Dom0 is 512M; at 1024M the same set came to 8256 MiB."
  echo "   The reduction is split across DomD and DomA because DomD 2048 alone was"
  echo "   measured to fail: AAOS crash-looped in binder and never set"
  echo "   sys.boot_completed, with DomD itself still 1.3 GiB free and no OOM kill."
fi

# NG-2 guard: --domains-only sets NINJA_TARGET="" to skip SD-image assembly, but the
# DomA (AAOS) p4 nested GPT is assembled ONLY during that assembly step (rouge) -- in
# BOTH source and prebuilt modes (prebuilt only stages images; rouge still assembles
# p4). The default ninja target builds/stages neither doma nor doma_kernel, so a
# --domains-only build with DomA enabled (source OR prebuilt) would silently produce
# NO DomA at all. Refuse loudly when -a made DomA required (mirrors the "fail loudly
# for -a" policy above); warn otherwise.
if [ -z "$NINJA_TARGET" ] && [ "$AAOS_MODE" != "off" ]; then
  if [ "$AAOS_REQUIRED" = "yes" ]; then
    echo "ERROR: -a/--android (DomA) combined with --domains-only." >&2
    echo "       DomA is built + assembled into the p4 nested GPT only during SD-image" >&2
    echo "       assembly, which --domains-only skips, so no DomA would be produced" >&2
    echo "       (true for --aaos=source and --aaos=prebuilt alike)." >&2
    echo "       Drop --domains-only (build a full.img) or drop -a." >&2
    exit 1
  fi
  echo ">> WARNING: DomA (--aaos=$AAOS_MODE) with --domains-only: DomA is built/staged +" >&2
  echo ">>   assembled into p4 only during SD-image assembly (which --domains-only skips)," >&2
  echo ">>   so this build produces NO DomA. Drop --domains-only to include DomA." >&2
fi

# C2 guard: DomA (p4) requires DomU (p3). The SD partition order is fixed by
# rpi5-sodev.yaml definition order (the ENABLE_DOMU=yes p3 partition is defined BEFORE
# the ENABLE_ANDROID=yes p4). Without -u there is no p3 DomU rootfs, so rouge assembles
# Android as p3 -- but the DomA guest config is hard-wired to p4 (doma.cfg backs the disk
# from /dev/mmcblk0p4; xl-attach-disks p4->xvdc), so the image boots to a broken/DomA-less
# state yet the build exits 0. Refuse loudly (mirrors the "fail loudly for -a" policy).
# Scoped to a full SD-image build ($NINJA_TARGET non-empty): the mismatch can only ship in
# an assembled image; --domains-only builds no image and is already covered by NG-2 above
# (which also lets a legitimate --aaos=source --domains-only artifact-only build proceed).
# DISTINCT from NG-2: NG-2 = "DomA never assembled"; C2 = "DomA assembled at the wrong p#".
if [ "$ENABLE_ANDROID" = "yes" ] && [ "$ENABLE_DOMU" != "yes" ] && [ -n "$NINJA_TARGET" ]; then
  echo "ERROR: DomA (-a/--android or --aaos=source|prebuilt) requires DomU (-u/--domu)." >&2
  echo "       Without -u there is no DomU rootfs at SD p3, so rouge assembles Android at" >&2
  echo "       p3, but the DomA guest config is hard-wired to p4 (doma.cfg /dev/mmcblk0p4," >&2
  echo "       xl-attach-disks p4->xvdc) -> DomA cannot boot. Add -u/--domu, or drop DomA." >&2
  exit 1
fi

# Propagate --proxy to the docker build/run steps (build_img, in_docker) and their
# containers via the standard proxy env vars. Unset => no proxy (any inherited env still wins).
if [ -n "$PROXY" ]; then
  export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY" https_proxy="$PROXY" http_proxy="$PROXY"
fi

cmdcheck() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $1" >&2; exit 1; }; }
cmdcheck docker
cmdcheck git

# Optional extra Docker mounts for a pre-populated cache (DL_DIR / sstate mirror).
# A clean clone needs NONE: the workspace (with its submodules) is mounted at
# $workdir and the cache is repo-relative. To reuse a site cache, export
# XT_CACHE_MOUNTS as a docker -v list, e.g.
#   XT_CACHE_MOUNTS="-v /data/yocto-dl:/data/yocto-dl"
CACHE_MOUNTS=( ${XT_CACHE_MOUNTS:-} )
# Optional host-resource caps for the build containers (default: unlimited — the prior
# behaviour). --memory=<size> (XT_DOCKER_MEMORY) caps container RAM via docker --memory
# *and* --memory-swap set to the same value, so the build cannot spill into host swap and
# OOM the host (an unbounded moulin/AOSP/Yocto build otherwise can). XT_DOCKER_RUN_OPTS
# passes arbitrary extra `docker run` options verbatim (word-split), for anything --memory
# does not cover. Both are applied to every build container (in_docker below).
DOCKER_RUN_OPTS=()
# Container networking. Default is Docker's bridge, which keeps the container
# isolated and works on Docker Desktop / rootless / macOS. Set
# XT_DOCKER_NETWORK=host when the build must reach something bound to the host's
# loopback -- a local proxy or package mirror, typically -- since a bridged
# container's 127.0.0.1 is its own loopback, not the host's. It applies to both
# `docker run` and `docker build` (fetches happen in both).
NET_OPTS=()
[ -n "$XT_DOCKER_NETWORK" ] && NET_OPTS+=( "--network=$XT_DOCKER_NETWORK" )
[ -n "$XT_DOCKER_MEMORY" ] && DOCKER_RUN_OPTS+=( --memory "$XT_DOCKER_MEMORY" --memory-swap "$XT_DOCKER_MEMORY" )
DOCKER_RUN_OPTS+=( ${XT_DOCKER_RUN_OPTS:-} )
# Reuse an external Yocto sstate/downloads cache for faster rebuilds: mount it into
# the containers and let bitbake pick it up via XT_SSTATE_DIR/XT_DL_DIR (rpi5-sodev.yaml
# reads them with os.getenv; passed through below). A dir already under $workdir is
# reachable via the workspace mount, so only external paths get an extra -v.
add_cache_mount() { local d="$1"; [ -n "$d" ] || return 0; mkdir -p "$d"; case "$d/" in "$workdir"/*) return 0;; esac; CACHE_MOUNTS+=( -v "$d":"$d" ); }
add_cache_mount "$XT_SSTATE_DIR"
if [ -n "$XT_DL_DIR" ] && [ "$XT_DL_DIR" != "$XT_SSTATE_DIR" ]; then add_cache_mount "$XT_DL_DIR"; fi
# Zephyr Dom0 west source cache (DL_DIR analogue): a pre-populated west reference
# workspace the fetch-dom0 step pulls from offline (see the zephyr branch below).
add_cache_mount "$XT_WEST_CACHE_DIR"

# When --aaos-src points OUTSIDE the workspace, the ninja doma/doma_kernel
# components (run in the sodev-builder container) reach the AOSP tree via the
# android/ symlink (-> AAOS_SRC_DIR) and ../android_kernel. in_docker only mounts
# $workdir + the cache dirs, so those symlinks dangle in-container and
# `mkdir -p android/.` fails. Mount the external tree (and android_kernel's real
# target) so they resolve. (--aaos-src of an in-workspace dir is a no-op here.)
if [ "${ENABLE_ANDROID}" = "yes" ] && [ "$AAOS_MODE" = "source" ] && [ -n "$AAOS_SRC_DIR" ]; then
  add_cache_mount "$AAOS_SRC_DIR"
  akdir="$(readlink -f "$workdir/android_kernel" 2>/dev/null || true)"
  [ -n "$akdir" ] && [ -d "$akdir" ] && add_cache_mount "$akdir"
  # AOSP soong references ../android_kernel relative to android/ (-> AAOS_SRC_DIR),
  # i.e. AAOS_SRC_DIR's sibling. moulin builds android_kernel INSIDE the workspace
  # ($workdir/android_kernel, created later by the doma_kernel bazel step), so with
  # an external --aaos-src that sibling path is empty in-container and droidcore
  # fails "Image missing". Bind the workspace android_kernel onto the sibling path
  # (both container paths -> the same host dir). Pre-create it so the -v mount works
  # before moulin populates it.
  ak_sib="$(dirname "$AAOS_SRC_DIR")/android_kernel"
  mkdir -p "$workdir/android_kernel"
  case "$ak_sib/" in "$workdir"/*) ;; *) CACHE_MOUNTS+=( -v "$workdir/android_kernel":"$ak_sib" ) ;; esac
fi

# moulin.conf resolves DL_DIR/SSTATE_DIR via os.getenv('XT_DL_DIR'/'XT_SSTATE_DIR');
# in this flow bitbake does not always see those env vars at parse and falls back
# to the (empty) yocto/common_data/{downloads,sstate}, re-fetching everything.
# Symlink the fallback paths to the external caches so reuse works regardless.
if [ -n "$XT_DL_DIR" ] || [ -n "$XT_SSTATE_DIR" ]; then
  mkdir -p yocto/common_data
  # `ln -sfn` onto an existing *real* directory (not a symlink) does not replace it:
  # it drops the symlink *inside* that dir (or errors), silently mislinking the cache.
  # A real dir here is a leftover from a prior in-workspace build; remove it only if
  # empty, else refuse rather than mislink (never touch its contents). An existing
  # symlink (the normal case) is still replaced atomically by ln -sfn as before.
  link_cache() {  # $1=external cache target, $2=link path under yocto/common_data
    local tgt="$1" link="$2"
    # NG-5 self-reference guard: if the external cache already IS the in-workspace
    # path itself (e.g. --dl=$PWD/yocto/common_data/downloads), `ln -sfn` would make
    # the link point at itself (a circular symlink bitbake cannot use). The parent
    # yocto/common_data exists (mkdir -p above), so readlink -f canonicalises both
    # even when $link does not exist yet. Equal => nothing to link; leave it as-is.
    local rtgt rlink
    rtgt="$(readlink -f "$tgt" 2>/dev/null || echo "$tgt")"
    rlink="$(readlink -f "$link" 2>/dev/null || echo "$link")"
    if [ -n "$rtgt" ] && [ "$rtgt" = "$rlink" ]; then
      echo ">> cache: '$link' already resolves to '$tgt'; skipping self-symlink." >&2
      return 0
    fi
    if [ -d "$link" ] && [ ! -L "$link" ]; then
      if [ -z "$(ls -A "$link" 2>/dev/null)" ]; then
        rmdir "$link"
      else
        echo "ERROR: '$link' is a non-empty real directory; refusing to replace it with a symlink to '$tgt'." >&2
        echo "       Move/remove it, or point --dl/--sstate at '$link' itself." >&2
        exit 1
      fi
    fi
    ln -sfn "$tgt" "$link"
  }
  [ -n "$XT_DL_DIR" ]     && link_cache "$XT_DL_DIR"     yocto/common_data/downloads
  [ -n "$XT_SSTATE_DIR" ] && link_cache "$XT_SSTATE_DIR" yocto/common_data/sstate
fi
# Include the optional AAOS guest-kernel/ramdisk md5 pins so a value set in the
# environment (as the README documents, alongside local.conf) actually reaches
# bitbake inside the container (aaos-guest-binaries_1.0.bb reads them as bb vars).
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} XT_SSTATE_DIR XT_DL_DIR AAOS_KERNEL_MD5 AAOS_RAMDISK_MD5"

# Run a command inside a Docker image, mounting the workspace at the same path.
in_docker() {  # $1=image, rest=command
  local img="$1"; shift
  docker run --rm "${NET_OPTS[@]}" \
    "${DOCKER_RUN_OPTS[@]}" \
    -v "$workdir":"$workdir" "${CACHE_MOUNTS[@]}" -w "$workdir" \
    -e HTTPS_PROXY="$PROXY" -e HTTP_PROXY="$PROXY" \
    -e https_proxy="$PROXY" -e http_proxy="$PROXY" \
    -e NO_PROXY="${NO_PROXY:-}" -e no_proxy="${NO_PROXY:-}" \
    -e REPO_SKIP_SELF_UPDATE="${REPO_SKIP_SELF_UPDATE:-}" \
    -e XT_DISABLE_SPDX="${XT_DISABLE_SPDX:-}" \
    -e AAOS_KERNEL_MD5="${AAOS_KERNEL_MD5:-}" -e AAOS_RAMDISK_MD5="${AAOS_RAMDISK_MD5:-}" \
    -e XT_SSTATE_DIR="$XT_SSTATE_DIR" -e XT_DL_DIR="$XT_DL_DIR" \
    -e XT_WEST_CACHE_DIR="$XT_WEST_CACHE_DIR" \
    -e BB_ENV_PASSTHROUGH_ADDITIONS="$BB_ENV_PASSTHROUGH_ADDITIONS" \
    "$img" bash -lc "$*"
}

# Build a docker/ build image on demand (skip if present unless REBUILD_IMAGES=1).
build_img() {  # $1=image tag, $2=dockerfile path relative to workdir
  if [ "${REBUILD_IMAGES}" != "1" ] && docker image inspect "$1" >/dev/null 2>&1; then return 0; fi
  echo ">> docker build $1  (-f $2)"
  docker build "${NET_OPTS[@]}" -f "$workdir/$2" \
    --build-arg USER_ID="$(id -u)" --build-arg USER_GID="$(id -g)" \
    --build-arg HTTP_PROXY="$PROXY" --build-arg HTTPS_PROXY="$PROXY" --build-arg NO_PROXY="${NO_PROXY:-}" \
    -t "$1" "$workdir/docker"
}

# 0) Fetch submodules (base + AGL SoDeV) — only when something is uninitialized, so
#    rebuilds don't re-hit the network or reset a locally-checked-out submodule.
#    Force a refresh by running `git submodule update --init --recursive` by hand.
if git submodule status --recursive 2>/dev/null | grep -q '^-'; then
  git submodule update --init --recursive
else
  echo ">> submodules already initialized; skipping update"
fi

# 0-stage) AAOS artifacts. A DomA build needs TWO independent artifact sets:
#   (Type-1) the five boundary files in meta-xt-doma (the .gitignore'd,
#     aaos-guest-binaries / xt-aaos-host-services SRC_URI files) -> consumed by the DomD
#     Yocto build (p1 guest kernel/ramdisk + DomD host gRPC backends). This is the two
#     guest binaries (kernel, ramdisk) + the two host gRPC backends + the AOSP NOTICE
#     that, per Apache-2.0 section 4(d), must be redistributed with the Apache-2.0
#     host-service binaries (file://NOTICE in xt-aaos-host-services, .gitignore'd like
#     the binaries; without it that recipe fails do_fetch). REQUIRED for ANY DomA build
#     (source OR prebuilt); the aaos-guest-binaries recipe md5 check is opt-in
#     (off by default; set AAOS_KERNEL_MD5/AAOS_RAMDISK_MD5 to assert a validated build).
#   (Type-2) the six AOSP output images (android/out/.../*.img) -> assembled into p4.
#     Built by the AOSP 'doma' component (source mode) or supplied by the bundle (prebuilt).
#   With a bundle (--aaos-prebuilt=<dir> containing files/ + images/) both sets are staged
#   automatically; otherwise the five Type-1 files must be staged by hand (README).
if [ "${ENABLE_ANDROID}" = "yes" ]; then
  aaos_base="meta-rpi-sodev/meta-xt-common/meta-xt-doma"
  gb_dir="$aaos_base/recipes-bsp/aaos-guest-binaries/files"
  hs_dir="$aaos_base/recipes-extended/xt-aaos-host-services/files"
  # Auto-stage a Type-1 boundary file from the bundle when present but not yet in-tree.
  stage_boundary() {  # $1=filename $2=dest_dir
    if [ ! -f "$2/$1" ] && [ -f "$AAOS_PREBUILT_DIR/files/$1" ]; then
      install -D "$AAOS_PREBUILT_DIR/files/$1" "$2/$1" && echo ">> staged boundary file from bundle: $1"
    fi
  }
  stage_boundary aaos-android-kernel-xenbuilt-6.1.118     "$gb_dir"
  stage_boundary aaos-vendor-boot-ramdisk-xenbuilt-padded "$gb_dir"
  stage_boundary vehicle_hal_grpc_server                  "$hs_dir"
  stage_boundary dumpstate_grpc_server                    "$hs_dir"
  # AOSP NOTICE (Apache-2.0 sec 4d): a SRC_URI file of xt-aaos-host-services, .gitignore'd
  # like the binaries, so do_fetch fails without it. Stage it alongside the host binaries.
  stage_boundary NOTICE                                   "$hs_dir"
  # Verify all five are present (pre-staged by hand or just staged from the bundle).
  aaos_missing=0
  for f in \
    "$gb_dir/aaos-android-kernel-xenbuilt-6.1.118" \
    "$gb_dir/aaos-vendor-boot-ramdisk-xenbuilt-padded" \
    "$hs_dir/vehicle_hal_grpc_server" \
    "$hs_dir/dumpstate_grpc_server" \
    "$hs_dir/NOTICE" ; do
    [ -f "$f" ] || { echo "   missing: $f" >&2; aaos_missing=1; }
  done
  if [ "$aaos_missing" = "0" ]; then
    echo ">> AAOS boundary prebuilts present (5/5); continuing."
  else
    echo "ERROR: DomA requested but the five AAOS boundary prebuilts are not staged (see above)." >&2
    echo "       Provide them via --aaos-prebuilt=<dir> (a bundle with files/), stage by hand" >&2
    echo "       (README: 'Staging the AAOS prebuilts'), or drop -a/--aaos for a DomA-less image." >&2
    exit 1
  fi
  # prebuilt mode: place the six AOSP output images (Type-2) where rouge expects them,
  # so 'ninja dom0 domd domu' + rouge assemble p4 WITHOUT running the AOSP build (m)/bazel.
  if [ "$AAOS_MODE" = prebuilt ]; then
    # Integrity: if the bundle ships a MANIFEST.md5, verify files/ + images/ against it
    # (the recipe's kernel/ramdisk md5 check is opt-in/off by default; the six p4 images
    # are otherwise unverified). No MANIFEST => proceed with a NOTE.
    if [ -f "$AAOS_PREBUILT_DIR/MANIFEST.md5" ]; then
      echo ">> verifying prebuilt bundle against MANIFEST.md5"
      ( cd "$AAOS_PREBUILT_DIR" && md5sum -c MANIFEST.md5 ) \
        || { echo "ERROR: prebuilt bundle failed MANIFEST.md5 (corrupt/wrong bundle)" >&2; exit 1; }
      # Coverage: a partial MANIFEST (md5sum -c only checks listed lines) must NOT read
      # as "verified" — require every expected artifact to be listed.
      for req in \
        files/aaos-android-kernel-xenbuilt-6.1.118 files/aaos-vendor-boot-ramdisk-xenbuilt-padded \
        files/vehicle_hal_grpc_server files/dumpstate_grpc_server files/NOTICE \
        images/boot.img images/init_boot.img images/vendor_boot.img images/vbmeta.img \
        images/super.img images/userdata.img ; do
        grep -q " ${req}\$" "$AAOS_PREBUILT_DIR/MANIFEST.md5" \
          || { echo "ERROR: MANIFEST.md5 does not cover '$req' (incomplete manifest)" >&2; exit 1; }
      done
    else
      echo ">> NOTE: bundle has no MANIFEST.md5; the six p4 images are NOT integrity-checked (guest kernel/ramdisk md5 is checked only if you set AAOS_KERNEL_MD5/AAOS_RAMDISK_MD5 — opt-in, off by default)."
    fi
    img_dst="$workdir/android/out/target/product/xenvm_trout_arm64"
    [ -L "$workdir/android" ] && rm -f "$workdir/android"   # drop a stale --aaos-src symlink
    mkdir -p "$img_dst"
    for im in boot init_boot vendor_boot vbmeta super userdata; do
      src="$AAOS_PREBUILT_DIR/images/$im.img"
      [ -f "$src" ] || { echo "ERROR: --aaos=prebuilt needs image: $src" >&2; exit 1; }
      cp -f "$src" "$img_dst/$im.img"   # unconditional: never keep a stale/corrupt same-size image
    done
    echo ">> AAOS prebuilt images staged into android/out (AOSP build will be skipped)."
  fi
fi

# Build the unified build image if missing (moulin/ninja + AOSP + AGL bitbake host).
# The DomA (AAOS) moulin build (step 2) runs inside this same image via ninja.
build_img "$XT_DOCKER"  docker/Dockerfile.builder
# The DomU AGL build uses the same unified image by default. build_img is idempotent
# (skips when present), so this is a no-op when AGL_DOCKER == the image just built.
# If AGL_DOCKER points at a pre-built image (e.g. the AGL-official docker-worker),
# it is not our default tag, so it is left for the user to `docker pull`.
if [ "$ENABLE_DOMU" = "yes" ] && [ "$AGL_DOCKER" = "sodev-builder" ]; then
  build_img "$AGL_DOCKER" docker/Dockerfile.builder
fi

# 0a) DomA (AAOS). `ninja image-full` (step 2) builds the doma_kernel (bazel) + doma
#     (android) moulin components inside sodev-builder and rouge assembles their outputs
#     into the SD image p4 as a nested GPT (V4H android_only style; see rpi5-sodev.yaml
#     ENABLE_ANDROID). There is no prebuilt combined-disk and no separate warm step: the
#     moulin `android` builder runs the full repo sync + lunch + build itself in step 2
#     (the AOSP toolchain is baked into Dockerfile.builder). Budget ~250 GiB free + 1-3 h
#     on first run. --aaos-src reuses an existing checkout (skip the ~100 GiB sync);
#     omit -a for a DomA-less SD.
if [ "${ENABLE_ANDROID}" = "yes" ] && [ "$AAOS_MODE" = "source" ] && [ -n "${AAOS_SRC_DIR}" ] && [ "${AAOS_SRC_DIR}" != "$workdir/android" ]; then
  # rouge + the doma component read the AOSP tree at <repo>/android (the component
  # build-dir). When --aaos-src points at an external tree, symlink it in so ninja reuses it.
  if [ -d "$workdir/android" ] && [ ! -L "$workdir/android" ]; then
    echo "ERROR: $workdir/android is a real directory; --aaos-src would be silently ignored." >&2
    echo "       Remove it (or drop --aaos-src) so the external tree can be symlinked in." >&2
    exit 1
  fi
  ln -sfn "$AAOS_SRC_DIR" "$workdir/android"   # (re)point the symlink at the external AOSP tree
fi

# 1) DomU (AGL Flutter) — same procedure as upstream sodev-demo-workspace/build.sh.
#    AGL branch comes from the V4H submodule so it follows upstream.
#    Gated on -u/--domu (ENABLE_DOMU): the AGL bitbake produces the SD image p3
#    (AGL cluster rootfs); the moulin domu component produces the p1 Xen-aware DomU
#    kernel (linux-virtio-armv8). Omitting -u skips both (DomU-less SD).
if [ "${ENABLE_DOMU}" = "yes" ]; then
  AGL_BRANCH="$(meta-rpi-sodev/scripts/sync-guest-pins.sh --print agl-branch)"
  # Reuse the shared Yocto DL_DIR/SSTATE_DIR (the same cache the moulin/sodev-builder
  # build uses) for the AGL bitbake, so it dedupes source downloads and reuses
  # sstate across rebuilds — and the cache persists beyond the disposable agl/
  # checkout. External --dl/--sstate win; otherwise the in-workspace common_data.
  # Both are reachable in the AGL container: $workdir is mounted, and external
  # cache dirs were added to CACHE_MOUNTS above. sstate is hash-keyed, so the
  # scarthgap-era AGL and wrynose moulin entries coexist in one dir safely.
  AGL_DL_DIR="${XT_DL_DIR:-$workdir/yocto/common_data/downloads}"
  AGL_SSTATE_DIR="${XT_SSTATE_DIR:-$workdir/yocto/common_data/sstate}"
  mkdir -p "$AGL_DL_DIR" "$AGL_SSTATE_DIR"
  echo ">> DomU(AGL) in ${AGL_DOCKER}: branch=${AGL_BRANCH} image=${AGL_IMAGE}"
  echo ">>   AGL cache: DL_DIR=${AGL_DL_DIR}  SSTATE_DIR=${AGL_SSTATE_DIR}"
  in_docker "$AGL_DOCKER" "
    set -e
    mkdir -p agl && cd agl
    # --no-clone-bundle: skip the CDN clone.bundle (a large single HTTPS GET that
    # proxies/firewalls often cut mid-stream) and fetch via plain git. Robustness
    # only; the git transport works regardless.
    repo init --no-clone-bundle -b '${AGL_BRANCH}' -u https://github.com/automotive-grade-linux/AGL-repo.git
    repo sync --no-clone-bundle -j\$(nproc) --retry-fetches=20
    source meta-agl/scripts/aglsetup.sh -m '${AGL_MACHINE}' -b build agl-demo agl-devel agl-kvm agl-ic
    # aglsetup sources oe-init-build-env, so CWD is now the build dir (agl/build)
    # -- the same CWD the bitbake below relies on. Append the shared cache paths to
    # conf/local.conf (relative to the build dir), last so they win over aglsetup's
    # defaults. Values are host-expanded absolute paths.
    printf '%s\n' 'DL_DIR = \"${AGL_DL_DIR}\"' 'SSTATE_DIR = \"${AGL_SSTATE_DIR}\"' >> conf/local.conf
    bitbake '${AGL_IMAGE}'
  "
else
  echo ">> DomU(AGL) SKIPPED (no -u/--domu). SD image omits DomU kernel(p1)+AGL rootfs(p3)."
fi

# 2) Dom0/DomD (rpi5 base) + final image assembly — moulin + ninja in sodev-builder.
#    `ninja image-full` assembles full.img (the flashable SD image) in one step, the same
#    one-command flow as the V4H AGL SoDeV build. The image builder (rouge) is userspace
#    (mkfs.vfat/mkfs.ext4/mtools/simg2img/dd) — no root/loop. With -a it builds the
#    DomA p4 nested GPT from android/out (step 0a); the AGL DomU rootfs (step 1) is the only other
#    input not built here. --domains-only (NINJA_TARGET="") => domains only.
APPLY_ZEPHYR="meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/apply-zephyr-patches.sh"
# In-container build step. prebuilt mode never invokes doma/doma_kernel: it builds the
# domains (dom0/domd[/domu]) then assembles full.img with rouge directly from the staged
# android/out images -> no AOSP (m) / bazel / repo sync runs. Other modes use the normal
# single ninja target (image-full, or "" for --domains-only).
# Split the build into the (retriable) ninja part and the one-shot rouge assembly:
# NINJA_CMD is wrapped in a bounded retry loop below (transient repo-sync aborts),
# ROUGE_CMD (prebuilt mode's direct p4 assembly, else a ':' no-op) runs once after.
if [ "$AAOS_MODE" = prebuilt ]; then
  dom_targets="dom0 domd"; [ "$ENABLE_DOMU" = yes ] && dom_targets="$dom_targets domu"
  NINJA_CMD="ninja $dom_targets"
  if [ "$NINJA_TARGET" = "image-full" ]; then
    ROUGE_CMD="rouge '${MOULIN_YAML}' --DOM0_OS '${DOM0_OS}' --ENABLE_ANDROID yes --ENABLE_DOMU '${ENABLE_DOMU}' --BOARD_RAM '${BOARD_RAM}' -fi full -o full.img"
  else
    ROUGE_CMD=":"
  fi
else
  NINJA_CMD="ninja ${NINJA_TARGET}"; ROUGE_CMD=":"
fi
echo ">> moulin (${MOULIN_YAML}) DOM0_OS=${DOM0_OS} BOARD_RAM=${BOARD_RAM} ENABLE_ANDROID=${ENABLE_ANDROID} ENABLE_DOMU=${ENABLE_DOMU} AAOS_MODE=${AAOS_MODE} ninja='${NINJA_CMD}'${ROUGE_CMD:+ +rouge} in ${XT_DOCKER}"
in_docker "$XT_DOCKER" "
  set -e
  # Regenerate the moulin build dirs' conf from scratch (V4H build.sh parity): a
  # stale build-dom*/conf from an earlier parameter set (e.g. a previous
  # ENABLE_ANDROID=yes run) would otherwise be reused, so a later --dom0/-a/-u
  # change would build against the wrong bblayers.conf.
  rm -rf yocto/build-dom*/conf
  moulin '${MOULIN_YAML}' --DOM0_OS '${DOM0_OS}' --ENABLE_ANDROID '${ENABLE_ANDROID}' --ENABLE_DOMU '${ENABLE_DOMU}' --BOARD_RAM '${BOARD_RAM}'
  if [ '${DOM0_OS}' = zephyr ]; then
    # Zephyr Dom0 source cache (Yocto DL_DIR analogue): when XT_WEST_CACHE_DIR points
    # at a pre-populated west reference workspace, pull the manifest+projects from it
    # so fetch-dom0 runs offline (past a blocking proxy). 'west update' projects come
    # via update.path-cache; the manifest repo that 'west init -m URL' clones is not
    # path-cache-covered, so redirect that URL to the reference workspace via git
    # insteadOf. The URL is the dom0-zephyr manifest pinned in rpi5-sodev.yaml.
    if [ -n \"\$XT_WEST_CACHE_DIR\" ]; then
      west config --global update.path-cache \"\$XT_WEST_CACHE_DIR\"
      git config --global url.\"\$XT_WEST_CACHE_DIR/zephyr-dom0-xt\".insteadOf https://github.com/xen-troops/zephyr-dom0-xt.git
    fi
    # moulin has no patch hook for west sources: fetch-only pass ('fetch-dom0' =
    # west init+update) populates the workspace, apply the Zephyr Dom0 patch
    # series (idempotent), THEN build. Without 0001 guest create fails rc=-3,
    # so this must precede the zephyr.bin build.
    ninja fetch-dom0
    '${APPLY_ZEPHYR}' \"\$PWD/zephyr\"
  fi
  # moulin's generated doma/doma_kernel repo-sync has no built-in retry, so a single
  # transient proxy/network abort can fail the whole ninja run. ninja is incremental
  # and the repo-sync stamp is written only on success, so re-running resumes from the
  # failed step. Wrap the ninja in a small bounded retry loop (a deterministic build
  # error just re-runs the same failing edge and exits after the cap; not masked). The
  # rouge assembly (prebuilt mode) runs ONCE after a successful ninja, never retried.
  tries=0
  until ${NINJA_CMD}; do
    tries=\$((tries+1))
    if [ \$tries -ge 5 ]; then echo \">> ninja failed after \$tries attempts (deterministic error, or too many transient aborts)\" >&2; exit 1; fi
    echo \">> ninja attempt \$tries failed; retrying in 15s (incremental resume; transient fetch/repo-sync abort?)\" >&2
    sleep 15
  done
  ${ROUGE_CMD}
"

echo "Build complete."
[ "${ENABLE_DOMU}" = "yes" ] && echo "  AGL DomU image : agl/build/tmp/deploy/images/${AGL_MACHINE}/"
if [ "${ENABLE_ANDROID}" = "yes" ]; then
  echo "  moulin output  : artifacts/ , yocto/ , android/"
else
  echo "  moulin output  : artifacts/ , yocto/"
fi
if [ "${NINJA_TARGET}" = "image-full" ]; then
  echo "  SD image       : full.img  (flash: sudo dd if=full.img of=/dev/<sd> bs=4M conv=fsync)"
fi
