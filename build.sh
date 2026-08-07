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
BOARD="${BOARD:-rpi5}"                             # --board=rpi5|rpi4 : which product yaml to build (selects <board>-sodev.yaml)
DOM0_OS="${DOM0_OS:-zephyr}"                       # --dom0=zephyr|linux
BOARD_RAM="${BOARD_RAM:-}"                         # --ram=<sku> : board SKU. rpi5: 16g(default)|8g. rpi4: 8g(default)|4g. Resolved after --board, below.
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
XT_AAOS_REF="${XT_AAOS_REF:-}"                      # --aaos-ref=<dir>        (repo object mirror for the AOSP tree; the AAOS analogue of --west-cache)
XT_AAOS_KERNEL_REF="${XT_AAOS_KERNEL_REF:-}"        # --aaos-kernel-ref=<dir> (repo object mirror for the AAOS guest-kernel tree)
REBUILD_IMAGES="${REBUILD_IMAGES:-0}"              # --rebuild-images
XT_DOCKER_NETWORK="${XT_DOCKER_NETWORK:-}"         # --network for the build containers, e.g. "host"
XT_DOCKER_RUN_OPTS="${XT_DOCKER_RUN_OPTS:-}"       # extra `docker run` opts for the build containers, e.g. "--memory=48g --cpus=12" (recommended on shared hosts to bound the heavy AOSP/Yocto steps; empty = no limit)
PROXY="${HTTPS_PROXY:-}"                            # --proxy=<url>
# Set from BOARD once the flags are parsed (see "Board selection" below). Assigning it
# here would freeze the rpi5 yaml before --board is read.
MOULIN_YAML=""
AGL_IMAGE="${AGL_IMAGE:-agl-cluster-demo-flutter-guest}"
AGL_MACHINE="${AGL_MACHINE:-virtio-aarch64}"
XT_DOCKER="${XT_DOCKER:-sodev-builder}"                # unified build image: moulin/ninja (Yocto/Xen/Zephyr) + AOSP + AGL bitbake (docker/Dockerfile.builder)
AGL_DOCKER="${AGL_DOCKER:-sodev-builder}"  # DomU AGL bitbake image (defaults to the unified image; set to the AGL-official docker-worker to use it instead)
XT_DOCKER_MEMORY="${XT_DOCKER_MEMORY:-}"           # --memory=<size> : cap build-container RAM (docker --memory + --memory-swap, e.g. 24g). Empty => unlimited (current behavior)

Usage() {
  cat <<'EOF'
Usage: ./build.sh [options]

  Raspberry Pi + Xen 4.21 AGL SoDeV disaggregated cockpit builder.
  Default build = Raspberry Pi 5, Dom0(Zephyr) + DomD only; guests are opt-in
  (upstream sodev-demo-workspace f3f0f8f7 "disable Android/Flatcar by default").

Board options:
      --board=<board>    rpi5 (default) | rpi4. Selects <board>-sodev.yaml and with it
                         the SoC, MACHINE, Zephyr Dom0 board, passthrough set, physical
                         memory map and board layer. Raspberry Pi 5 is the reference
                         platform; the Raspberry Pi 4 (BCM2711) configuration is
                         verified by build and by the sending environment's hardware
                         run, not re-verified on hardware here.

Domain options:
  -u, --domu             Build DomU (AGL instrument cluster: p1 kernel + p3 AGL rootfs)
  -a, --android          Include DomA (AAOS, p4 nested GPT). Alias for --aaos=auto
                         (how DomA is produced is chosen by --aaos).
      --dom0=<os>        Dom0 OS: zephyr (default) | linux
      --ram=<sku>        Board SKU. Valid values and the default depend on --board.
                         rpi5: 16g (default) = full 4-domain map (Dom0 512 +
                           DomD 4096 + DomU 1024 + DomA 4096 = 9728 MiB); 8g =
                           DomD 3072 MiB (static-mem bank4 dropped) and DomA 3072 MiB,
                           Dom0/DomU unchanged, total 7680 MiB, ~436 MiB headroom.
                         rpi4: 8g (default) = Dom0 256 + DomD 1920 MiB (three static-mem
                           banks) + DomU 1024 + DomA 2560; 4g = DomD 1024 MiB (bank2
                           dropped, bank0 640 MiB); DomA and DomU then cannot RUN at
                           the same time (each fits alone) -- build.sh says so and both
                           still go on the SD, so pick one at run time.
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
      --aaos-prebuilt=<dir>  Prebuilt AAOS bundle (layout: files/ + images/, plus an
                             optional MANIFEST.md5 and BUNDLE-INFO). Used by
                             prebuilt/auto. Default probe:
                             <workspace>/aaos-prebuilt-<board>, then
                             <workspace>/aaos-prebuilt.
                             A bundle is BOARD-SPECIFIC (the guest is compiled for the
                             host CPU), so it should declare itself in BUNDLE-INFO:
                                 board=rpi4
                                 device=xenvm_trout_rpi4_arm64
                             A mismatch against --board is refused. An untagged bundle
                             is accepted for rpi5 only (they all predate multi-board
                             support); AAOS_PREBUILT_ASSUME_BOARD=<board> overrides.
      --aaos-src=<dir>       Reuse an existing AOSP checkout for source mode (skip repo sync)
      --aaos-ref=<dir>       Repo OBJECT MIRROR for the AOSP tree: seed the checkout with
                             'repo init --reference=<dir>' so the sync is local. Accepts a
                             repo client, or a bare '*-project-objects' tree (a shim is
                             made for it). The AAOS analogue of --west-cache
      --aaos-kernel-ref=<dir>  Same, for the AAOS guest-kernel tree (android_kernel)

Build environment:
      --sstate=<dir>     Reuse an external Yocto sstate cache
      --dl=<dir>         Reuse an external Yocto downloads dir
      --west-cache=<dir> Reuse a west reference workspace (Zephyr Dom0 manifest+projects)
                         (the AAOS equivalents are --aaos-ref / --aaos-kernel-ref above)
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
  ./build.sh -u --aaos=source --aaos-ref=/mirror/aosp --aaos-kernel-ref=/mirror/aosp-kernel
                                                    # DomA from source off a local repo mirror
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
    --board)            needval $# "$1"; BOARD="$2"; shift ;;
    --board=*)          BOARD="${1#*=}" ;;
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
    --aaos-ref)         needval $# "$1"; XT_AAOS_REF="$2"; shift ;;
    --aaos-ref=*)       XT_AAOS_REF="${1#*=}" ;;
    --aaos-kernel-ref)  needval $# "$1"; XT_AAOS_KERNEL_REF="$2"; shift ;;
    --aaos-kernel-ref=*) XT_AAOS_KERNEL_REF="${1#*=}" ;;
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

# --- Board selection (which product yaml) --------------------------------------
# One yaml per board, named <board>-sodev.yaml. They are siblings, not variants of one
# file: the SoC, the machine, the Zephyr Dom0 board, the passthrough set and the whole
# physical memory map differ, and each yaml lists its own board layer (meta-xt-rpi5 or
# meta-xt-rpi4 — never both, they provide the same recipe names).
case "$BOARD" in
  rpi5|rpi4) ;;
  *) echo "ERROR: --board must be rpi5 or rpi4 (got '$BOARD')" >&2; exit 1 ;;
esac
MOULIN_YAML="${BOARD}-sodev.yaml"
if [ ! -f "$MOULIN_YAML" ]; then
  echo "ERROR: --board=$BOARD selects '$MOULIN_YAML', which is not in $workdir" >&2
  exit 1
fi

# PRODUCT_DEVICE of the AAOS product this board builds. Read from the yaml so there is ONE
# source of truth: rpi4 uses its own product variant (see the ANDROID_DEVICE comment there)
# and its out/target/product/ directory is named after it. Resolved HERE, next to the board,
# because the prebuilt staging path reads it long before the ninja command is assembled.
AAOS_PRODUCT_DEVICE=$(sed -n 's/^[[:space:]]*ANDROID_DEVICE:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$MOULIN_YAML" | head -1)
[ -n "$AAOS_PRODUCT_DEVICE" ] || { echo "ERROR: could not read ANDROID_DEVICE from $MOULIN_YAML" >&2; exit 1; }

# The AOSP checkout and the AAOS guest-kernel checkout live under names the yaml owns,
# and they are board-specific: rpi4 uses android-rpi4 / android_kernel-rpi4 where rpi5
# uses the historical android / android_kernel. Read them here rather than hard-coding
# "android", so build.sh cannot disagree with the yaml about where the tree is.
AAOS_DIR_NAME=$(sed -n 's/^[[:space:]]*DOMA_DIR:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$MOULIN_YAML" | head -1)
AAOS_KERNEL_DIR_NAME=$(sed -n 's/^[[:space:]]*ANDROID_KERNEL_DIR:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$MOULIN_YAML" | head -1)
[ -n "$AAOS_DIR_NAME" ] || { echo "ERROR: could not read DOMA_DIR from $MOULIN_YAML" >&2; exit 1; }
[ -n "$AAOS_KERNEL_DIR_NAME" ] || { echo "ERROR: could not read ANDROID_KERNEL_DIR from $MOULIN_YAML" >&2; exit 1; }

# --- Board RAM size (moulin parameter BOARD_RAM) -------------------------------
# The SKUs are per-board and so are the domain sizes; see the BOARD_RAM parameter in
# the corresponding yaml for the full rationale.
#
# rpi5: 16g (default) or 8g. The default map wants 10240 MiB with all four domains,
#   which needs the 16 GB board; 8g takes DomD from 4096 to 3072 MiB and DomA likewise.
#   The split is measured: DomD 2048 alone left the DomA device model unable to serve a
#   4 GiB guest and AAOS crash-looped in binder (hardware, 2026-08-03).
# rpi4: 8g (default) or 4g. 4g drops DomD static-mem bank2 and shrinks bank0 to 640 MiB,
#   taking DomD to 1024 MiB. DomA still fits there (verified on hardware with 158 MiB
#   of Xen free memory left) -- what does not fit is DomA and DomU running together.
case "$BOARD" in
  rpi5) BOARD_RAM_VALID="16g 8g"; BOARD_RAM_DEFAULT="16g" ;;
  rpi4) BOARD_RAM_VALID="8g 4g";  BOARD_RAM_DEFAULT="8g"  ;;
esac
[ -n "$BOARD_RAM" ] || BOARD_RAM="$BOARD_RAM_DEFAULT"
# Word-boundary match, so "8g" does not match inside some future "18g".
case " $BOARD_RAM_VALID " in
  *" $BOARD_RAM "*) ;;
  *) echo "ERROR: --ram for --board=$BOARD must be one of: $BOARD_RAM_VALID (got '$BOARD_RAM')" >&2; exit 1 ;;
esac

# --- Resolve the AAOS (DomA) build mode: off | auto | source | prebuilt ---
# -a/--android sets ENABLE_ANDROID=yes; with no explicit --aaos that means "include
# DomA, auto-pick how". ENABLE_ANDROID is then DERIVED from the resolved mode below.
if [ -z "$AAOS_MODE" ]; then
  # -a/--android OR env ENABLE_ANDROID=yes both mean "I want DomA" => auto + required.
  if [ "$ENABLE_ANDROID" = "yes" ]; then AAOS_MODE=auto; AAOS_REQUIRED=yes; else AAOS_MODE=off; fi
fi
case "$AAOS_MODE" in off|auto|source|prebuilt) ;; *) echo "ERROR: --aaos must be off|auto|source|prebuilt (got '$AAOS_MODE')" >&2; exit 1 ;; esac
# Default bundle probe: prefer a board-tagged bundle, then the untagged legacy path.
# A prebuilt AAOS bundle is board-specific -- the guest is compiled for the ISA of the
# host cores it runs on -- but it is an opaque set of images with no arch in its name, so
# one shared default directory invites staging the wrong board's guest. Yocto has no such
# hazard: PACKAGE_ARCH is part of every sstate key and DEPLOY_DIR_IMAGE is per MACHINE.
if [ -z "$AAOS_PREBUILT_DIR" ]; then
  if [ -d "$workdir/aaos-prebuilt-$BOARD/images" ]; then
    AAOS_PREBUILT_DIR="$workdir/aaos-prebuilt-$BOARD"
  else
    AAOS_PREBUILT_DIR="$workdir/aaos-prebuilt"
  fi
fi
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
[ -f "$workdir/$AAOS_DIR_NAME/build/envsetup.sh" ] && aaos_have_source=yes
# A repo object mirror is a way to OBTAIN the source, so it counts as source being available
# even though no checkout exists yet -- build.sh seeds one from it below. Without this,
# `-a --aaos-ref=<mirror>` resolved auto to a hard error ("found neither a prebuilt bundle
# nor an AOSP source checkout") while holding exactly what it needed.
{ [ -n "$XT_AAOS_REF" ] || [ -n "$XT_AAOS_KERNEL_REF" ]; } && aaos_have_source=yes
if [ "$AAOS_MODE" = auto ]; then
  if   [ "$aaos_have_bundle" = yes ]; then AAOS_MODE=prebuilt
  elif [ "$aaos_have_source" = yes ]; then AAOS_MODE=source
  elif [ "$AAOS_REQUIRED" = yes ]; then
    # -a explicitly requested DomA but nothing to build it from: fail loudly (do
    # NOT silently ship a DomA-less image and exit 0 — a CI/user asked for DomA).
    echo "ERROR: -a/--android requested DomA, but found neither a prebuilt bundle" >&2
    echo "       (6 images at '$AAOS_PREBUILT_DIR/images/') nor an AOSP source checkout." >&2
    echo "       Pass --aaos-prebuilt=<dir> (files/ + images/), --aaos=source --aaos-src=<dir>," >&2
    echo "       or --aaos-ref=<repo object mirror> (build.sh seeds a checkout from it)," >&2
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
# DomA (p4) requires DomU (p3), on both boards. The SD partition order is fixed by the
# yaml's definition order: the ENABLE_DOMU=yes `domu` partition is defined BEFORE the
# ENABLE_ANDROID=yes `android` one. Without -u there is no p3 DomU rootfs, so rouge
# assembles Android as p3 -- while the DomA guest config is hard-wired to p4 (doma.cfg
# backs qemu's disk from /dev/mmcblk0p4 directly). The image then boots to a DomA-less
# state and the build still exits 0. Refuse loudly instead.
#
# Scoped to a full SD-image build (NINJA_TARGET non-empty): the mismatch can only ship
# in an assembled image, and --domains-only is already covered by the NG-2 guard below.
# Distinct from NG-2: NG-2 = "DomA never assembled"; this = "DomA assembled at the
# wrong partition number".
if [ "$ENABLE_ANDROID" = "yes" ] && [ "$ENABLE_DOMU" != "yes" ] && [ -n "$NINJA_TARGET" ]; then
  echo "ERROR: DomA (-a/--android or --aaos=source|prebuilt) requires DomU (-u/--domu)." >&2
  echo "       Without -u there is no DomU rootfs at SD p3, so rouge assembles Android at" >&2
  echo "       p3, but the DomA guest config is hard-wired to p4 (doma.cfg reads" >&2
  echo "       /dev/mmcblk0p4) -> DomA cannot boot. Add -u/--domu, or drop DomA." >&2
  exit 1
fi

# --- 4 GiB Raspberry Pi 4: DomA fits, but not AT THE SAME TIME as DomU ---------
# A notice, not a refusal. On the 4 GiB SKU Dom0 (256) + DomD (1024) + DomA (2560) has
# been booted on hardware with 158 MiB of Xen free memory left; DomU alone fits too.
# What does not fit is DomU and DomA together. Since DomA's p4 requires DomU's p3 (the
# guard just above), both have to be BUILT into the image regardless -- the constraint
# is purely at run time, and refusing here would block the only 4 GiB configuration
# that can run DomA at all.
#
# No arithmetic is restated here on purpose: the sizes live in
# boot.cmd.xen.*-dom0.in (the 4 GiB DomD override and dom0_mem) and in the DomU/DomA
# guest configs plus the meta-xt-rpi4 bbappends that override them.
if [ "$BOARD" = "rpi4" ] && [ "$BOARD_RAM" = "4g" ] && [ "$ENABLE_ANDROID" = "yes" ]; then
  echo ">> NOTE: on a 4 GiB Raspberry Pi 4, DomA and DomU cannot RUN at the same time." >&2
  echo ">>   Each fits alone; together they exceed the free pool. Both are on the SD" >&2
  echo ">>   anyway (DomA's p4 needs DomU's p3), so pick one at run time:" >&2
  echo ">>     systemctl disable --now xl-create-domu   # then start DomA" >&2
  echo ">>   Use --ram=8g if you need all four domains up together." >&2
fi

if [ "$BOARD" = "rpi5" ] && [ "$BOARD_RAM" = "8g" ] && [ "$ENABLE_ANDROID" = "yes" ]; then
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
  echo ">> WARNING: DomA (--aaos=$AAOS_MODE) with --domains-only: the p4 nested GPT is" >&2
  echo ">>   assembled only during SD-image assembly (which --domains-only skips), so this" >&2
  echo ">>   build produces NO bootable DomA. Drop --domains-only to include DomA." >&2
  echo ">>   NOTE: in source mode the AOSP components still run -- the DomD bitbake derives" >&2
  echo ">>   the DomA kernel/ramdisk from their outputs -- so this is not a short build." >&2
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
# docker rejects two -v with the same container path ("Duplicate mount point"), and the
# flags legitimately overlap: --aaos-ref and --aaos-kernel-ref can name one mirror, and the
# android_kernel sibling mount derived from --aaos-src below can land on the same path a
# --aaos-kernel-ref already claimed. So record every container path that has been mounted
# and skip repeats instead of letting `docker run` fail after the build has already started.
MOUNTED_AT=()
mount_at() {  # $1=host path  $2=container path
  local h="$1" c="$2" m
  for m in ${MOUNTED_AT[@]+"${MOUNTED_AT[@]}"}; do [ "$m" = "$c" ] && return 0; done
  MOUNTED_AT+=( "$c" ); CACHE_MOUNTS+=( -v "$h":"$c" )
}
add_cache_mount() { local d="$1"; [ -n "$d" ] || return 0; mkdir -p "$d"; case "$d/" in "$workdir"/*) return 0;; esac; mount_at "$d" "$d"; }
# A cache path that does not exist is, in practice, a typo. add_cache_mount's `mkdir -p`
# used to create it silently, and nothing later in the run said so: the build simply
# rebuilt everything from scratch against an empty cache, turning a 20-minute build into a
# multi-hour one with a log that looks entirely normal. So require the directory to exist,
# and name the remedy for the case where a fresh cache really was intended. An existing but
# EMPTY directory is legitimate (first use, and the build populates it) -- that only gets a
# note, so a cold cache is at least visible in the log.
check_cache_dir() {  # $1=dir  $2=flag name  $3=what it holds
  local d="$1" flag="$2" what="$3"
  [ -n "$d" ] || return 0
  if [ ! -d "$d" ]; then
    echo "ERROR: $flag: no such directory: $d" >&2
    echo "       This is almost always a typo -- a mistyped cache silently rebuilds" >&2
    echo "       everything. If a fresh $what really was intended, create it first:" >&2
    echo "         mkdir -p '$d'" >&2
    exit 1
  fi
  [ -n "$(ls -A "$d" 2>/dev/null)" ] || \
    echo ">> NOTE: $flag: '$d' is empty -- cold $what, expect a long first build."
}
check_cache_dir "$XT_SSTATE_DIR"     --sstate     "sstate cache"
check_cache_dir "$XT_DL_DIR"         --dl         "downloads dir"
check_cache_dir "$XT_WEST_CACHE_DIR" --west-cache "west reference workspace"
add_cache_mount "$XT_SSTATE_DIR"
if [ -n "$XT_DL_DIR" ] && [ "$XT_DL_DIR" != "$XT_SSTATE_DIR" ]; then add_cache_mount "$XT_DL_DIR"; fi
# Zephyr Dom0 west source cache (DL_DIR analogue): a pre-populated west reference
# workspace the fetch-dom0 step pulls from offline (see the zephyr branch below).
add_cache_mount "$XT_WEST_CACHE_DIR"
# AAOS repo object mirrors (the --west-cache analogue for the AOSP side). Validate BEFORE
# add_cache_mount: that helper does `mkdir -p`, which would turn a typo into a silently
# created empty directory -- repo would then quietly fall back to full network fetches,
# i.e. exactly the failure these flags exist to avoid. A mirror must exist and must hold
# at least one bare repo, either directly or under .repo/project-objects.
check_repo_mirror() {  # $1=dir $2=flag name
  local d="$1" flag="$2" root="$1"
  [ -n "$d" ] || return 0
  [ -d "$d" ] || { echo "ERROR: $flag: no such directory: $d" >&2; exit 1; }
  [ -d "$d/.repo/project-objects" ] && root="$d/.repo/project-objects"
  # No -maxdepth: repo nests project-objects by manifest path, and AOSP's is deep
  # (platform/frameworks/opt/telephony.git is already 4 levels down, and a mirror exported
  # under an extra prefix is deeper still). A bounded search rejected valid mirrors. The
  # walk is cheap when a mirror IS valid (-quit stops at the first hit); only the error
  # path pays for a full traversal, and it exits immediately after.
  if [ -z "$(find "$root" -type d -name '*.git' -print -quit 2>/dev/null)" ]; then
    echo "ERROR: $flag: '$d' holds no bare '*.git' repositories, so it cannot serve as a" >&2
    echo "       repo --reference. Expected either a repo client (with .repo/project-objects/)" >&2
    echo "       or an exported '*-project-objects' tree." >&2
    exit 1
  fi
  # A mirror that was ITSELF seeded with --reference carries an objects/info/alternates
  # chain pointing outside itself. Only the named mirror gets bind-mounted, so inside the
  # container git resolves that chain to a path that is not there and prints
  # "object directory ... does not exist; check .git/objects/info/alternates" -- for every
  # project, from a step that has already started. Catch it here and name the root instead.
  local alt chain
  alt="$(find "$d" -path '*/objects/info/alternates' -print -quit 2>/dev/null)"
  if [ -n "$alt" ]; then
    chain="$(head -1 "$alt" 2>/dev/null)"
    case "${chain%/}/" in
      "$d"/*|"$workdir"/*) ;;   # self-contained, or reachable via the workspace mount
      *)
        echo "ERROR: $flag: '$d' is itself referenced against another mirror:" >&2
        echo "         $alt" >&2
        echo "         -> $chain" >&2
        echo "       Only '$d' is mounted into the build container, so that chain would not" >&2
        echo "       resolve there. Point $flag at the ROOT mirror instead (the one with no" >&2
        echo "       objects/info/alternates), or detach the chain first:" >&2
        echo "         git -C <each repo> repack -a -d && rm <its objects/info/alternates>" >&2
        exit 1 ;;
    esac
  fi

  # WHICH tree is this mirror for? Everything above is satisfied by either mirror -- both
  # are repo clients full of bare *.git repos -- so passing them the wrong way round is
  # accepted here and then costs hours: repo falls back to the network for every project
  # and the log looks entirely normal.
  #
  # Discriminate on projects that only one of the two manifests carries. Measured against
  # both mirrors: platform/build/bazel_common_rules.git and kernel/configs.git appear in
  # BOTH and are useless for this; the ones below appear in exactly one.
  #
  # One mirror may legitimately serve both flags (see the mount de-duplication below), so
  # only a POSITIVE swap is an error: the other tree's marker present AND this tree's
  # absent. A mirror carrying neither marker is an exported subset that cannot be
  # classified, so it gets a note instead -- a note is enough, because the cost of being
  # wrong there is a slow build, not a wrong image.
  local kind="$3" has_aosp="" has_kern="" p
  for p in platform/bionic.git platform/art.git platform/build/soong.git; do
    [ -n "$(find "$root" -type d -path "*/$p" -print -quit 2>/dev/null)" ] && { has_aosp=yes; break; }
  done
  for p in kernel/common.git kernel/common-modules/virtual-device.git \
           xen-troops/android_kernel_xen-virtual-device.git; do
    [ -n "$(find "$root" -type d -path "*/$p" -print -quit 2>/dev/null)" ] && { has_kern=yes; break; }
  done
  case "$kind" in
    aosp)
      if [ -z "$has_aosp" ] && [ -n "$has_kern" ]; then
        echo "ERROR: $flag names the AOSP mirror, but '$d' is the AAOS guest-kernel mirror:" >&2
        echo "       it has kernel/common.git and none of platform/bionic.git," >&2
        echo "       platform/art.git, platform/build/soong.git." >&2
        echo "       --aaos-ref and --aaos-kernel-ref look swapped." >&2
        exit 1
      fi
      [ -n "$has_aosp" ] || echo ">> NOTE: $flag: '$d' carries none of the projects that identify the AOSP tree; it cannot be verified as the right mirror." >&2
      ;;
    kernel)
      if [ -z "$has_kern" ] && [ -n "$has_aosp" ]; then
        echo "ERROR: $flag names the AAOS guest-kernel mirror, but '$d' is the AOSP mirror:" >&2
        echo "       it has platform/bionic.git and none of kernel/common.git," >&2
        echo "       kernel/common-modules/virtual-device.git," >&2
        echo "       xen-troops/android_kernel_xen-virtual-device.git." >&2
        echo "       --aaos-ref and --aaos-kernel-ref look swapped." >&2
        exit 1
      fi
      [ -n "$has_kern" ] || echo ">> NOTE: $flag: '$d' carries none of the projects that identify the guest-kernel tree; it cannot be verified as the right mirror." >&2
      ;;
  esac
}
check_repo_mirror "$XT_AAOS_REF"        --aaos-ref        aosp
check_repo_mirror "$XT_AAOS_KERNEL_REF" --aaos-kernel-ref kernel
# Mounted so the seeding step below, which runs inside the builder, can read them.
add_cache_mount "$XT_AAOS_REF"
add_cache_mount "$XT_AAOS_KERNEL_REF"

# When --aaos-src points OUTSIDE the workspace, the ninja doma/doma_kernel
# components (run in the sodev-builder container) reach the AOSP tree via the
# android/ symlink (-> AAOS_SRC_DIR) and ../android_kernel. in_docker only mounts
# $workdir + the cache dirs, so those symlinks dangle in-container and
# `mkdir -p android/.` fails. Mount the external tree (and android_kernel's real
# target) so they resolve. (--aaos-src of an in-workspace dir is a no-op here.)
if [ "${ENABLE_ANDROID}" = "yes" ] && [ "$AAOS_MODE" = "source" ] && [ -n "$AAOS_SRC_DIR" ]; then
  add_cache_mount "$AAOS_SRC_DIR"
  akdir="$(readlink -f "$workdir/$AAOS_KERNEL_DIR_NAME" 2>/dev/null || true)"
  [ -n "$akdir" ] && [ -d "$akdir" ] && add_cache_mount "$akdir"
  # AOSP soong references ../android_kernel relative to android/ (-> AAOS_SRC_DIR),
  # i.e. AAOS_SRC_DIR's sibling. moulin builds android_kernel INSIDE the workspace
  # ($workdir/android_kernel, created later by the doma_kernel bazel step), so with
  # an external --aaos-src that sibling path is empty in-container and droidcore
  # fails "Image missing". Bind the workspace android_kernel onto the sibling path
  # (both container paths -> the same host dir). Pre-create it so the -v mount works
  # before moulin populates it.
  ak_sib="$(dirname "$AAOS_SRC_DIR")/$AAOS_KERNEL_DIR_NAME"
  mkdir -p "$workdir/$AAOS_KERNEL_DIR_NAME"
  case "$ak_sib/" in "$workdir"/*) ;; *) mount_at "$workdir/$AAOS_KERNEL_DIR_NAME" "$ak_sib" ;; esac
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
# CONNECTIVITY_CHECK_URIS is in the list because the README tells proxied sites to set
# it empty to skip bitbake's connectivity probe; without it in BOTH the docker -e list
# (below) and here, exporting it on the host had no effect at all inside the container.
# It is forwarded with the bare `-e CONNECTIVITY_CHECK_URIS` form on purpose: that
# passes the variable only when it is actually set, so "unset" (keep bitbake's default
# probe) stays distinct from "set to empty" (disable the probe). `-e VAR="${VAR-}"`
# would define it unconditionally and silently disable the probe for everyone.
export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} XT_SSTATE_DIR XT_DL_DIR AAOS_KERNEL_MD5 AAOS_RAMDISK_MD5 CONNECTIVITY_CHECK_URIS"

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
    -e CONNECTIVITY_CHECK_URIS \
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

# 0-stage) AAOS artifacts. A DomA build needs the six AOSP output images
#   (android/out/.../*.img) assembled into p4. They come from the AOSP build in
#   `source` mode, or from a bundle in `prebuilt` mode.
#
#   The guest kernel and vendor-boot ramdisk that DomA boots from are DERIVED from
#   those outputs by the aaos-guest-binaries recipe (see
#   meta-xt-doma/recipes-bsp/aaos-guest-binaries/aaos-guest-binaries-derive.inc), and
#   the two DomD-side gRPC backends are BUILT from public sources by
#   google-trout-agl-services. Nothing has to be staged by hand any more, so the
#   boundary-file check that used to gate this step is gone. `prebuilt` mode is the one
#   exception: it has no AOSP checkout to derive the two boot artifacts from, so they
#   come out of the bundle -- copied in below, not by hand.
if [ "${ENABLE_ANDROID}" = "yes" ]; then
  # prebuilt mode: place the six AOSP output images (Type-2) where rouge expects them,
  # so 'ninja dom0 domd domu' + rouge assemble p4 WITHOUT running the AOSP build (m)/bazel.
  if [ "$AAOS_MODE" = prebuilt ]; then
    # PROVENANCE, before integrity. MANIFEST.md5 answers "is this bundle intact"; it
    # cannot answer "is this bundle for THIS board", because the md5s of a correctly
    # formed bundle for the OTHER board verify perfectly. Getting that wrong is silent
    # and expensive: the images stage, rouge assembles p4, the build exits 0, and the
    # guest dies in /init with SIGILL on the first boot because its userspace was
    # compiled for a CPU variant this host does not implement.
    #
    # A bundle therefore declares what it is, in a BUNDLE-INFO file next to MANIFEST.md5:
    #     board=rpi4
    #     device=xenvm_trout_rpi4_arm64
    #     cpu_variant=cortex-a72          # optional, informational
    # Lines starting with # and blank lines are ignored.
    binfo="$AAOS_PREBUILT_DIR/BUNDLE-INFO"
    if [ -f "$binfo" ]; then
      b_board=$(sed -n 's/^board=[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$binfo" | head -1)
      b_device=$(sed -n 's/^device=[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$binfo" | head -1)
      [ -n "$b_board" ] || { echo "ERROR: $binfo has no 'board=' line." >&2; exit 1; }
      if [ "$b_board" != "$BOARD" ]; then
        echo "ERROR: prebuilt bundle is for board '$b_board', this build is --board=$BOARD." >&2
        echo "       '$AAOS_PREBUILT_DIR'" >&2
        echo "       The AAOS guest is compiled for the host CPU, so the two are not" >&2
        echo "       interchangeable. Use the bundle built for this board, or --aaos=source." >&2
        exit 1
      fi
      if [ -n "$b_device" ] && [ "$b_device" != "$AAOS_PRODUCT_DEVICE" ]; then
        echo "ERROR: prebuilt bundle names device '$b_device'; this board builds '$AAOS_PRODUCT_DEVICE'." >&2
        echo "       '$AAOS_PREBUILT_DIR'" >&2
        exit 1
      fi
      echo ">> prebuilt bundle provenance OK (board=$b_board device=${b_device:-unset})"
    else
      # Legacy bundle with no provenance. Bundles predate this check, and every one of
      # them was built before a second board existed -- i.e. for rpi5. Accept that for
      # rpi5 so existing workflows keep working, and refuse it for any other board rather
      # than stage a guest that cannot run. AAOS_PREBUILT_ASSUME_BOARD is the escape hatch
      # for someone who knows their untagged bundle was built for this board.
      if [ -n "${AAOS_PREBUILT_ASSUME_BOARD:-}" ]; then
        if [ "$AAOS_PREBUILT_ASSUME_BOARD" != "$BOARD" ]; then
          echo "ERROR: AAOS_PREBUILT_ASSUME_BOARD=$AAOS_PREBUILT_ASSUME_BOARD but --board=$BOARD." >&2
          exit 1
        fi
        echo ">> NOTE: bundle has no BUNDLE-INFO; proceeding on AAOS_PREBUILT_ASSUME_BOARD=$BOARD (unverified)."
      elif [ "$BOARD" = rpi5 ]; then
        echo ">> NOTE: bundle has no BUNDLE-INFO ('$AAOS_PREBUILT_DIR'). Treating it as rpi5,"
        echo ">>   which is what every bundle predating this check was built for. Add a"
        echo ">>   BUNDLE-INFO with 'board=rpi5' to make that explicit."
      else
        echo "ERROR: prebuilt bundle has no BUNDLE-INFO and --board=$BOARD is not rpi5." >&2
        echo "       '$AAOS_PREBUILT_DIR'" >&2
        echo "       Untagged bundles predate multi-board support and were built for rpi5;" >&2
        echo "       staging one here would produce a guest that dies in /init with SIGILL." >&2
        echo "       Add a BUNDLE-INFO file with 'board=$BOARD' (and optionally" >&2
        echo "       'device=$AAOS_PRODUCT_DEVICE'), or set AAOS_PREBUILT_ASSUME_BOARD=$BOARD" >&2
        echo "       if you built it for this board, or use --aaos=source." >&2
        exit 1
      fi
    fi
    # Integrity: if the bundle ships a MANIFEST.md5, verify files/ + images/ against it
    # (the recipe's kernel/ramdisk md5 check is opt-in/off by default; the six p4 images
    # are otherwise unverified). No MANIFEST => proceed with a NOTE.
    if [ -f "$AAOS_PREBUILT_DIR/MANIFEST.md5" ]; then
      echo ">> verifying prebuilt bundle against MANIFEST.md5"
      ( cd "$AAOS_PREBUILT_DIR" && md5sum -c MANIFEST.md5 ) \
        || { echo "ERROR: prebuilt bundle failed MANIFEST.md5 (corrupt/wrong bundle)" >&2; exit 1; }
      # Coverage: a partial MANIFEST (md5sum -c only checks listed lines) must NOT read
      # as "verified" — require every expected artifact to be listed.
      # The list is exactly what this mode consumes: the six p4 images and the two boot
      # artifacts. It used to also demand files/vehicle_hal_grpc_server,
      # files/dumpstate_grpc_server and files/NOTICE -- the gRPC servers are built from
      # source now (nothing stages or reads them) and the NOTICE is committed, so
      # requiring them would reject a correctly formed bundle for carrying only what is
      # still used.
      for req in \
        files/aaos-android-kernel-xenbuilt-6.1.118 files/aaos-vendor-boot-ramdisk-xenbuilt-padded \
        images/boot.img images/init_boot.img images/vendor_boot.img images/vbmeta.img \
        images/super.img images/userdata.img ; do
        grep -q " ${req}\$" "$AAOS_PREBUILT_DIR/MANIFEST.md5" \
          || { echo "ERROR: MANIFEST.md5 does not cover '$req' (incomplete manifest)" >&2; exit 1; }
      done
    else
      echo ">> NOTE: bundle has no MANIFEST.md5; the six p4 images are NOT integrity-checked (guest kernel/ramdisk md5 is checked only if you set AAOS_KERNEL_MD5/AAOS_RAMDISK_MD5 — opt-in, off by default)."
    fi
    img_dst="$workdir/$AAOS_DIR_NAME/out/target/product/$AAOS_PRODUCT_DEVICE"
    [ -L "$workdir/$AAOS_DIR_NAME" ] && rm -f "$workdir/$AAOS_DIR_NAME"   # drop a stale --aaos-src symlink
    mkdir -p "$img_dst"
    for im in boot init_boot vendor_boot vbmeta super userdata; do
      src="$AAOS_PREBUILT_DIR/images/$im.img"
      [ -f "$src" ] || { echo "ERROR: --aaos=prebuilt needs image: $src" >&2; exit 1; }
      cp -f "$src" "$img_dst/$im.img"   # unconditional: never keep a stale/corrupt same-size image
    done
    echo ">> AAOS prebuilt images staged into android/out (AOSP build will be skipped)."
    # The DomA kernel/ramdisk are normally DERIVED from the AOSP outputs, but that needs
    # the AOSP checkout itself (system/tools/mkbootimg/unpack_bootimg.py) and the bazel
    # kernel Image -- neither of which exists in prebuilt mode, which is the whole point
    # of the mode. So stage the bundle's two boot artifacts and let the recipe use them
    # verbatim instead of deriving (see aaos-guest-binaries-derive.inc). Staged, not
    # required: without them prebuilt mode fails in the recipe with an actionable message.
    fdir="$workdir/meta-rpi-sodev/meta-xt-common/meta-xt-doma/recipes-bsp/aaos-guest-binaries/files"
    staged=0
    for f in aaos-android-kernel-xenbuilt-6.1.118 aaos-vendor-boot-ramdisk-xenbuilt-padded; do
      if [ -f "$AAOS_PREBUILT_DIR/files/$f" ]; then
        mkdir -p "$fdir"
        cp -f "$AAOS_PREBUILT_DIR/files/$f" "$fdir/$f"   # unconditional: never keep a stale copy
        staged=$((staged + 1))
      fi
    done
    if [ "$staged" = 2 ]; then
      echo ">> AAOS prebuilt guest kernel + ramdisk staged into meta-xt-doma (derivation will be skipped)."
    else
      echo ">> ERROR: --aaos=prebuilt needs both boot artifacts in '$AAOS_PREBUILT_DIR/files/':" >&2
      echo ">>   aaos-android-kernel-xenbuilt-6.1.118 and aaos-vendor-boot-ramdisk-xenbuilt-padded." >&2
      echo ">>   They cannot be derived here: deriving them needs the AOSP checkout" >&2
      echo ">>   (system/tools/mkbootimg) and the bazel guest kernel, which prebuilt mode" >&2
      echo ">>   deliberately does not have. Use --aaos=source --aaos-src=<AOSP checkout>," >&2
      echo ">>   which produces them from the build." >&2
      exit 1
    fi
  else
    # Any non-prebuilt mode DERIVES the two artifacts, so a copy left behind by an
    # earlier --aaos=prebuilt run has to go. The recipe prefers a staged file over
    # deriving (it has to: prebuilt mode cannot derive), so leaving them would make
    # `--aaos=source` silently keep shipping the old bundle's kernel and ramdisk while
    # building a fresh p4 from source -- the exact kernel/vendor_dlkm ABI mismatch that
    # boots to a black panel with sys.boot_completed=1.
    fdir="$workdir/meta-rpi-sodev/meta-xt-common/meta-xt-doma/recipes-bsp/aaos-guest-binaries/files"
    for f in aaos-android-kernel-xenbuilt-6.1.118 aaos-vendor-boot-ramdisk-xenbuilt-padded; do
      if [ -e "$fdir/$f" ]; then
        rm -f "$fdir/$f"
        echo ">> removed a stale prebuilt-staged artifact ($f); --aaos=$AAOS_MODE derives it"
      fi
    done
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
#     (the AOSP toolchain is baked into Dockerfile.builder). Budget ~300 GiB free; one
#     measured from-scratch run took 5 h 11 min. --aaos-src reuses an existing checkout
#     (skips the sync); --aaos-ref seeds it from a repo object mirror; omit -a for a
#     DomA-less SD.
if [ "${ENABLE_ANDROID}" = "yes" ] && [ "$AAOS_MODE" = "source" ] && [ -n "${AAOS_SRC_DIR}" ] && [ "${AAOS_SRC_DIR}" != "$workdir/$AAOS_DIR_NAME" ]; then
  # rouge + the doma component read the AOSP tree at the component build-dir, which the
  # yaml names per board (DOMA_DIR). When --aaos-src points at an external tree, symlink
  # it in so ninja reuses it.
  if [ -d "$workdir/$AAOS_DIR_NAME" ] && [ ! -L "$workdir/$AAOS_DIR_NAME" ]; then
    echo "ERROR: $workdir/$AAOS_DIR_NAME is a real directory; --aaos-src would be silently ignored." >&2
    echo "       Remove it (or drop --aaos-src) so the external tree can be symlinked in." >&2
    exit 1
  fi
  ln -sfn "$AAOS_SRC_DIR" "$workdir/$AAOS_DIR_NAME"   # (re)point the symlink at the external AOSP tree
fi

# 0b) AAOS repo object mirrors (--aaos-ref / --aaos-kernel-ref) — the AOSP analogue of
#     --west-cache. moulin's generated `repo init` carries no --reference (and a
#     `reference:` key in the yaml would be silently ignored, like every key moulin does
#     not know), so seed the checkout HERE with the reference applied. moulin's later
#     `repo init` preserves the recorded repo.reference, so every sync it runs stays
#     local. Nothing is pinned twice: the manifest URL/rev/depth are read out of
#     rpi5-sodev.yaml, which remains the single source of truth.
if [ "${ENABLE_ANDROID}" = "yes" ] && [ "$AAOS_MODE" = "source" ] &&
   { [ -n "$XT_AAOS_REF" ] || [ -n "$XT_AAOS_KERNEL_REF" ]; }; then
  # `repo --reference` wants a repo client: <ref>/.repo/project-objects/<name>.git.
  # An exported mirror is usually a bare '*-project-objects' tree, so wrap that shape in
  # a shim instead of making every caller do it by hand. The shim lives in the workspace
  # (so it is visible in-container) and only contains a symlink to the real mirror, which
  # in_docker mounts at the same path.
  ref_root() {  # $1=user dir  $2=component -> reference root (validated by check_repo_mirror)
    local d="$1"
    [ -d "$d/.repo/project-objects" ] && { echo "$d"; return 0; }
    # Name the shim after the COMPONENT, not basename "$d": --aaos-ref and
    # --aaos-kernel-ref routinely point at two mirrors with the same basename (both are
    # exported as '<something>-project-objects'), and a shared shim name would make the
    # second `ln -sfn` retarget the first one -- seeding both trees from one mirror.
    local shim="$workdir/.aaos-ref-shim/$2"
    mkdir -p "$shim/.repo"; ln -sfn "$d" "$shim/.repo/project-objects"
    echo "$shim"
  }
  # Sync concurrency. Deliberately NOT $(nproc): even with every object available locally,
  # repo still runs one `git fetch` per project against the real remote to resolve refs and
  # tags, and android.googlesource.com rate-limits that. Measured on a 32-core host:
  # -j16 => 12 of 1379 projects failed with 'remote: RESOURCE_EXHAUSTED', -j8 => 1 failed,
  # and a plain retry fixed it in both cases. So: a modest default, then serial retries.
  # XT_AAOS_SYNC_JOBS overrides it for sites with their own (unthrottled) mirror server.
  AAOS_SYNC_JOBS="${XT_AAOS_SYNC_JOBS:-4}"
  seed_repo() {  # $1=component name in the yaml  $2=checkout dir  $3=mirror dir
    local comp="$1" dir="$2" mirror="$3" ref
    [ -n "$mirror" ] || return 0
    ref="$(ref_root "$mirror" "$comp")"
    if [ -d "$dir/.repo" ]; then
      # Do not rewrite an existing client's config (its reference, if any, is kept), but DO
      # run the sync: an interrupted or rate-limited seed leaves a partial tree, and repo
      # sync is incremental -- a complete tree costs a couple of seconds. The `repo init`
      # below is skipped in-container for exactly that reason.
      echo ">> $comp: '$dir' already has a .repo; keeping its config and completing the sync."
    else
      echo ">> $comp: seeding '$dir' from mirror '$mirror' (reference root '$ref')"
    fi
    mkdir -p "$dir"
    in_docker "$XT_DOCKER" "
      set -e
      # single source of truth: take url/rev/manifest/depth from the yaml's repo source
      eval \"\$(python3 - '${MOULIN_YAML}' '${comp}' <<'PYEOF'
import sys, yaml, shlex
d = yaml.safe_load(open(sys.argv[1]))
s = [x for x in d['components'][sys.argv[2]]['sources'] if x.get('type') == 'repo'][0]
for k, v in (('R_URL', s['url']), ('R_REV', s['rev']),
             ('R_MANIFEST', s.get('manifest', 'default.xml')),
             ('R_DEPTH', str(s.get('depth', '')))):
    print('%s=%s' % (k, shlex.quote(v)))
PYEOF
)\"
      cd '$dir'
      if [ ! -d .repo ]; then
        repo init --reference='$ref' --no-clone-bundle -u \"\$R_URL\" -m \"\$R_MANIFEST\" -b \"\$R_REV\" \${R_DEPTH:+--depth=\$R_DEPTH}
      fi
      jobs=${AAOS_SYNC_JOBS}
      tries=0
      until repo sync -j\$jobs --no-clone-bundle --retry-fetches=20 --optimized-fetch; do
        tries=\$((tries+1))
        if [ \$tries -ge 3 ]; then
          echo \"ERROR: $comp: repo sync did not complete after \$tries attempts.\" >&2
          echo \"       If the errors say RESOURCE_EXHAUSTED the remote is rate-limiting the\" >&2
          echo \"       per-project ref fetch; lower XT_AAOS_SYNC_JOBS and re-run (the sync is\" >&2
          echo \"       incremental, so nothing already fetched is lost).\" >&2
          exit 1
        fi
        jobs=1   # de-parallelise: a rate-limited remote recovers when asked serially
        echo \">>   $comp: repo sync incomplete (attempt \$tries); retrying serially in 30s\" >&2
        sleep 30
      done
      echo \">>   reference recorded: \$(git -C .repo/manifests.git config --get repo.reference)\"
    "
  }
  # Both live under names the yaml owns and that differ per board (DOMA_DIR /
  # ANDROID_KERNEL_DIR), so a second board starts from an empty directory instead of
  # inheriting the first board's checkout -- which is what makes a wrong --aaos-ref
  # fail immediately rather than silently on some later clean build.
  # doma is a symlink to --aaos-src when that points outside the workspace.
  seed_repo doma        "$workdir/$AAOS_DIR_NAME"        "$XT_AAOS_REF"
  seed_repo doma_kernel "$workdir/$AAOS_KERNEL_DIR_NAME" "$XT_AAOS_KERNEL_REF"
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
STAGE_AOSP_DEVICE="meta-rpi-sodev/meta-xt-common/meta-xt-doma/stage-aosp-device.sh"
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
  # source mode: the AOSP components MUST finish before the DomD bitbake, because
  # aaos-guest-binaries derives the DomA kernel/ramdisk from their outputs
  # (android/out/.../vendor_boot.img and the bazel Image). ninja does not know that --
  # the dependency lives inside a bitbake recipe, not in the moulin graph -- and with a
  # single goal it picks DomD first (observed: "[8/13] Yocto Build: domd" ahead of
  # "[11/13] Invoke Android build system"), so a clean tree fails do_compile.
  #
  # Ordering here costs nothing: every moulin builder rule (yocto/android/bazel/zephyr)
  # declares ninja's `console` pool, whose depth is 1, so the components are already
  # serialised -- this only fixes WHICH order.
  #
  # `ninja doma_kernel doma` is not a substitute for the graph edge if someone runs
  # `ninja image-full` by hand; that case is covered by the recipe's do_compile bb.fatal,
  # which names the build.sh invocation to use.
  #
  # Not gated on NINJA_TARGET: --domains-only (NINJA_TARGET="") still builds DomD, and
  # moulin's default ninja target does NOT include doma/doma_kernel, so without this the
  # AOSP outputs would be missing there too. See the NG-2 guard above.
  if [ "$ENABLE_ANDROID" = yes ]; then
    # NINJA_TARGET may be empty (--domains-only); `ninja` with no goal builds the
    # default target, which is what the un-prefixed command did, so keep it unquoted
    # and unguarded rather than dropping the second invocation.
    # moulin has no hook between `repo sync` and the AOSP build, so split it: the
    # fetch-only pass populates the checkout, stage-aosp-device.sh adds this board's
    # AAOS product variant (a no-op on rpi5), THEN the AOSP build runs. Without the
    # staging the rpi4 lunch target does not exist and `m` fails immediately, so the
    # order is load-bearing rather than an optimisation.
    NINJA_CMD="ninja fetch-doma_kernel fetch-doma && '${STAGE_AOSP_DEVICE}' \"\$PWD/${AAOS_DIR_NAME}\" '${BOARD}' && ninja doma_kernel doma && ninja ${NINJA_TARGET}"
  fi
fi
echo ">> moulin BOARD=${BOARD} (${MOULIN_YAML}) DOM0_OS=${DOM0_OS} BOARD_RAM=${BOARD_RAM} ENABLE_ANDROID=${ENABLE_ANDROID} ENABLE_DOMU=${ENABLE_DOMU} AAOS_MODE=${AAOS_MODE} ninja='${NINJA_CMD}'${ROUGE_CMD:+ +rouge} in ${XT_DOCKER}"
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
  # An OOM kill is NOT transient: the AOSP step dies, and every retry re-dies within
  # seconds, so the loop would burn all its attempts and blame the network. soong_ui
  # sizes ninja -j from nproc+2 and ignores the cgroup limit, so on a many-core host a
  # cold AOSP build overruns any --memory. Detect it and stop with the real remedy.
  # The kill surfaces in soong's output rather than as a 137 exit status (moulin's ninja
  # turns it into a plain rc=1), so the output is what we check; rc 137 is checked too,
  # for a ninja killed directly. Match soong_ui's own wording -- 'ninja failed with:
  # signal: killed' -- and not a bare 'signal: killed', which any build log is free to
  # contain for reasons that have nothing to do with an OOM. The capture file is
  # truncated per attempt (tee, not tee -a) so one attempt's output can never condemn a
  # later one; the complete log is on stdout regardless.
  ninja_out=\$(mktemp)
  # The brace group is load-bearing. NINJA_CMD is substituted into this script as TEXT and
  # can be a compound command ('ninja doma_kernel doma && ninja image-full'), and
  # 'A && B 2>&1 | tee f' parses as 'A && (B 2>&1 | tee f)' -- so without the braces the
  # FIRST ninja's output bypasses the capture entirely. That is the AOSP build, i.e. the one
  # step where the OOM actually happens, so the detector below would never fire for it and
  # the loop would spend all five attempts blaming the network. Verified over the three
  # failure positions (first fails / second fails / both succeed).
  run_ninja() { { ${NINJA_CMD}; } 2>&1 | tee \"\$ninja_out\"; return \${PIPESTATUS[0]}; }
  tries=0
  until run_ninja; do
    rc=\$?
    if [ \$rc -eq 137 ] || grep -q 'ninja failed with: signal: killed' \"\$ninja_out\"; then
      echo \">> ninja was KILLED (rc=\$rc). This is the container OOM killer, not a transient\" >&2
      echo \">>   fetch: retrying cannot help. Confirm on the host with\" >&2
      echo \">>   'dmesg -T | grep -i oom-kill' (constraint=CONSTRAINT_MEMCG => the container).\" >&2
      echo \">>   Cap build parallelism and re-run; the build resumes incrementally:\" >&2
      echo \">>     XT_DOCKER_RUN_OPTS=\\\"--cpuset-cpus=0-15\\\" ./build.sh ...\" >&2
      echo \">>   (--cpus does NOT help: it leaves nproc, and therefore ninja -j, unchanged.)\" >&2
      echo \">>   See 'Bounding a cold AOSP build' in docs/BUILD.md.\" >&2
      exit 1
    fi
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
