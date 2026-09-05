#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Everything about DomZ that can be checked on a PC, in one command.
#
# DomZ is a plain unprivileged Xen guest: Zephyr on the `xenvm` board, 16 MiB, one
# vCPU, no rootfs, no device model, no network. Its only interface is the Xen PV
# console. So the checks that a PC can run are the static ones plus the guest build:
#
#   1. static invariants          - the two product yamls carry DomZ by copy (moulin has
#      no cross-file include), so an edit to one that misses the other is silent:
#      tools/check-yaml-drift.py catches that. Plus the one DomZ invariant that is
#      spread across two files: domz.cfg's `memory` has to match the RAM bank the
#      xenvm board links against. Only needs python3.
#   2. checkpatch                 - Zephyr coding style on the DomZ sources.
#      Needs the west workspace (for scripts/checkpatch.pl) and perl.
#   3. moulin graph               - every flag combination resolves, on BOTH boards,
#      and `ninja` has a rule for the domz target. Needs Docker + sodev-builder-rpi.
#   4. DomZ build                 - the xenvm image builds. The guest is
#      board-independent (it never sees the SoC), so one build covers both boards.
#      Needs Docker + sodev-builder-rpi.
#
# What is NOT covered, and cannot be: booting the domain (`xl create domz.cfg`) and
# the Xen PV console. See domz/README.md for the bring-up order and for how to iterate
# over scp without reflashing.
#
# Usage: tools/check-domz.sh [--quick]
#   --quick   only step 1 (no Docker, no build; a couple of seconds)

set -uo pipefail

workdir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workdir"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

XT_DOCKER="${XT_DOCKER:-sodev-builder-rpi}"
WEST_WS="${WEST_WS:-zephyr-domz}"

# Zephyr's xenvm board links against a RAM bank at 0x40000000 whose size is in
# boards/xen/xenvm/xenvm.dts. domz.cfg must ask Xen for exactly that: more is
# wasted, less puts the bank the image was linked for outside the domain. The size
# is read from that board dts when the workspace is present, so a change on the
# Zephyr side cannot pass unnoticed; the literal below is only a fallback for a
# --quick run on a tree that has never built DomZ, and is reported as such.
XENVM_RAM_MIB_FALLBACK=16
XENVM_DTS_REL="boards/xen/xenvm/xenvm.dts"
DOMZ_CFG="meta-rpi-sodev/meta-xt-common/meta-xt-domz/recipes-extended/xt-xen-cfg-domz/files/domz.cfg"

pass=0 fail=0 skip=0

step()  { printf '\n=== %s ===\n' "$1"; }
ok()    { echo "PASS: $1"; pass=$((pass + 1)); }
bad()   { echo "FAIL: $1"; fail=$((fail + 1)); }
skipit(){ echo "SKIP: $1"; skip=$((skip + 1)); }

in_docker() {  # run a command in the builder image, workspace mounted at the same path
  docker run --rm -v "$workdir":"$workdir" -w "$workdir" "$XT_DOCKER" bash -lc "$*"
}

# ---------------------------------------------------------------- 1. static checks
step "1. static invariants"
if python3 tools/check-yaml-drift.py >/dev/null 2>&1; then
  ok "check-yaml-drift.py (no unrecorded divergence between the product yamls)"
else
  python3 tools/check-yaml-drift.py 2>&1 | tail -20
  bad "check-yaml-drift.py reported drift (above)"
fi

mem="$(sed -n 's/^memory[[:space:]]*=[[:space:]]*\([0-9]\+\)[[:space:]]*$/\1/p' "$DOMZ_CFG")"
XENVM_DTS="$WEST_WS/zephyr/$XENVM_DTS_REL"
if [ -f "$XENVM_DTS" ]; then
  bank="$(sed -n '/memory@40000000/,/};/p' "$XENVM_DTS" | sed -n 's/.*DT_SIZE_M(\([0-9]\+\)).*/\1/p' | head -1)"
  src="$XENVM_DTS_REL"
else
  bank="$XENVM_RAM_MIB_FALLBACK"
  src="fallback literal; $WEST_WS is not populated, so this pair was NOT checked against the board dts"
fi
if [ -z "$bank" ]; then
  bad "could not read the xenvm RAM bank size from $XENVM_DTS"
elif [ "$mem" = "$bank" ]; then
  ok "domz.cfg memory = ${bank} MiB matches the xenvm RAM bank ($src)"
else
  bad "domz.cfg memory = '${mem:-unreadable}' but the xenvm board links against ${bank} MiB at 0x40000000 ($src)"
fi

if [ "$QUICK" = 1 ]; then
  printf '\n%d passed, %d failed, %d skipped (--quick)\n' "$pass" "$fail" "$skip"
  exit $((fail > 0))
fi

# ---------------------------------------------------------------- 2. coding style
step "2. checkpatch on the DomZ sources"
CHECKPATCH="$WEST_WS/zephyr/scripts/checkpatch.pl"
if [ ! -f "$CHECKPATCH" ]; then
  skipit "checkpatch: no west workspace at $WEST_WS (run './build.sh -z' first)"
elif ! command -v perl >/dev/null; then
  skipit "checkpatch: perl not installed"
else
  # BRACES/TRAILING_SEMICOLON/SPLIT_STRING are Linux rules that Zephyr contradicts:
  # Zephyr follows MISRA-C 15.6 (braces on every if/for/while body) and its device
  # instantiation macros conventionally end in a semicolon.
  # Keep the tool's own failure apart from a style finding: checkpatch exiting
  # non-zero for its own reasons (missing dictionary, bad argument) prints nothing
  # and would otherwise be indistinguishable from "clean".
  cp_out="$(perl "$CHECKPATCH" --no-tree --show-types \
        --ignore=SPDX_LICENSE_TAG,FILE_PATH_CHANGES,GERRIT_CHANGE_ID,COMMIT_MESSAGE,VOLATILE,BRACES,TRAILING_SEMICOLON,SPLIT_STRING \
        -f domz/app/src/*.c 2>&1)"
  cp_rc=$?
  cp_hits="$(printf '%s\n' "$cp_out" | grep -cE "^(WARNING|ERROR)")"
  if [ "$cp_rc" -ne 0 ] && [ "$cp_hits" = "0" ]; then
    skipit "checkpatch did not run (exit $cp_rc): $(printf '%s' "$cp_out" | head -1)"
  elif [ "$cp_hits" != "0" ]; then
    printf '%s\n' "$cp_out" | grep -E "^(WARNING|ERROR)"
    bad "checkpatch reported $cp_hits finding(s) (above)"
  else
    ok "checkpatch clean"
  fi
fi

# ---------------------------------------------------------------- 3. moulin graph
step "3. moulin graph for every flag combination"
if ! command -v docker >/dev/null; then
  skipit "moulin/build steps: docker not installed"
  printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
  exit $((fail > 0))
elif ! docker image inspect "$XT_DOCKER" >/dev/null 2>&1; then
  skipit "moulin/build steps: image '$XT_DOCKER' absent (build.sh builds it on demand)"
  printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
  exit $((fail > 0))
else
  # One yaml per board, and DomZ is in both. The --BOARD_RAM values differ per board
  # (rpi5: 16g|8g, rpi4: 8g|4g), so the SKU combination is spelled per board.
  combos_rpi5=(
    ""
    "--ENABLE_DOMZ yes"
    "--DOM0_OS linux --ENABLE_DOMZ yes"
    "--ENABLE_DOMU yes --ENABLE_ANDROID yes --ENABLE_DOMZ yes --BOARD_RAM 8g"
  )
  combos_rpi4=(
    "--ENABLE_DOMZ yes"
    "--DOM0_OS linux --ENABLE_DOMZ yes"
    "--ENABLE_DOMU yes --ENABLE_DOMZ yes --BOARD_RAM 4g"
  )
  graph_ok=1 n=0
  for board in rpi5 rpi4; do
    eval "combos=(\"\${combos_${board}[@]}\")"
    for c in "${combos[@]}"; do
      n=$((n + 1))
      # Drop the previous combination's conf first, for the reason build.sh gives
      # where it does the same: moulin writes yocto/build-dom*/conf only when it is
      # absent, so a conf left by a DIFFERENT parameter set is reused and the next
      # combination would be resolved against the wrong bblayers/machine.
      if in_docker "rm -rf yocto/build-dom*/conf; moulin ${board}-sodev.yaml $c >/dev/null 2>&1" ; then
        : # the ninja file was generated; the DomZ artifacts are asserted by step 4
      else
        bad "moulin failed for ${board} '${c:-(defaults)}'"
        graph_ok=0
      fi
    done
  done
  [ "$graph_ok" = 1 ] && ok "moulin resolves all $n flag combinations across both boards"

  # The domz component is declared unconditionally, so `domz: phony` exists even
  # without --ENABLE_DOMZ and asserting it proves nothing. What the flag has to do
  # is put zephyr-domz.bin on p1, so check the generated graph for that item -- and
  # check it is absent without the flag, or a dropped partitions.boot.items
  # override would pass unnoticed.
  dz_ok=1
  for board in rpi5 rpi4; do
    # The image rule names the artifact by its build path, not by the p1 filename, so
    # that is what is grepped for -- inside the `build full.img:` block only, since
    # the zephyr_build rule mentions the same path unconditionally.
    fullimg_deps="sed -n '/^build full.img:/,/^\$/p' build.ninja"
    if ! in_docker "rm -rf yocto/build-dom*/conf; moulin ${board}-sodev.yaml --ENABLE_DOMZ yes >/dev/null 2>&1 && $fullimg_deps | grep -q 'zephyr-domz/build-domz-'"; then
      bad "full.img does not depend on the DomZ image after ${board} --ENABLE_DOMZ yes"
      dz_ok=0
    fi
    if ! in_docker "rm -rf yocto/build-dom*/conf; moulin ${board}-sodev.yaml >/dev/null 2>&1 && ! $fullimg_deps | grep -q 'zephyr-domz/build-domz-'"; then
      bad "full.img depends on the DomZ image for ${board} even WITHOUT --ENABLE_DOMZ"
      dz_ok=0
    fi
  done
  [ "$dz_ok" = 1 ] && ok "full.img pulls the DomZ image with --ENABLE_DOMZ and only then, on both boards"

  # The loop above left build.ninja pointing at whichever board ran last. Regenerate
  # the default one, so a plain `ninja` after this script builds what the developer
  # expects rather than the other board.
  in_docker "rm -rf yocto/build-dom*/conf; moulin rpi5-sodev.yaml >/dev/null 2>&1" ||
    bad "could not restore the default (rpi5) moulin graph"
fi

# ---------------------------------------------------------------- 4. DomZ build
step "4. DomZ image build (xenvm)"
if [ ! -d "$WEST_WS/zephyr" ]; then
  skipit "DomZ build: no west workspace at $WEST_WS (run './build.sh -z' once)"
else
  # Own build dir (build-check-domz), separate from moulin's build-domz-<board>: this
  # is a -p always build and would otherwise wipe the directory a `ninja domz` just
  # populated.
  bl="$(mktemp)"
  if in_docker "set -e; cd $WEST_WS; source zephyr/zephyr-env.sh; \
                west build -p always -b xenvm -d build-check-domz ../domz/app; \
                test -f build-check-domz/zephyr/zephyr.bin" >"$bl" 2>&1; then
    ok "the DomZ image builds for the xenvm board"
  else
    # Show the tail: the usual failure is environmental (a builder image whose west
    # runs on python3.10 while Zephyr 4.4 requires >= 3.12), and silence makes that
    # indistinguishable from a real build break.
    tail -20 "$bl"
    bad "the DomZ image failed to build (last 20 lines above)"
  fi
  rm -f "$bl"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
exit $((fail > 0))
