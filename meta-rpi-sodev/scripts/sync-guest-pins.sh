#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Follow V4H (AGL SoDeV) DomU/DomA pins from the external/sodev-demo-workspace submodule.
# moulin has no cross-file include, so DomU/DomA pins are duplicated into our build.sh /
# rpi5-sodev.yaml; this script keeps them in sync with the upstream submodule.
#
# Usage:
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --print {agl-branch|android-rev|android-kernel-rev}
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --check     # show V4H pins vs our pins (drift)
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --apply     # rewrite our pins to match V4H
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
SDW="$here/external/sodev-demo-workspace"
RCAR_YAML="$SDW/external/meta-rcar-demo/prod-devel-rcar4_new.yaml"
SDW_BUILD="$SDW/build.sh"
OUR_YAML="$here/rpi5-sodev.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$SDW_BUILD" ] || die "submodule not initialized: $SDW (run: git submodule update --init --recursive)"
[ -f "$RCAR_YAML" ] || die "rcar yaml not found: $RCAR_YAML"

# AGL branch from the V4H build.sh (e.g. agl_branch="trout-sodev").
agl_branch() {
  sed -nE 's/^[[:space:]]*agl_branch=["'"'"']?([^"'"'"' ]+).*/\1/p' "$SDW_BUILD" | head -n1
}
# First `rev:` that appears after a line containing the given manifest URL.
rev_for() {
  awk -v u="$1" '
    index($0, u) { found=1 }
    found && $1 == "rev:" { print $2; exit }
  ' "$RCAR_YAML"
}
android_rev()        { rev_for "yhamamachi/android_manifest"; }
android_kernel_rev() { rev_for "android_kernel_manifest"; }

case "${1:-}" in
  --print)
    case "${2:-}" in
      agl-branch)          b="$(agl_branch)"; echo "${b:-trout-sodev}" ;;
      android-rev)         android_rev ;;
      android-kernel-rev)  android_kernel_rev ;;
      *) die "usage: --print {agl-branch|android-rev|android-kernel-rev}" ;;
    esac ;;
  --check)
    echo "[V4H submodule]"
    echo "  agl-branch         : $(agl_branch)"
    echo "  android rev        : $(android_rev)"
    echo "  android-kernel rev : $(android_kernel_rev)"
    echo "[our rpi5-sodev.yaml]"
    grep -nE 'yhamamachi/android_manifest|android_kernel_manifest' -A2 "$OUR_YAML" 2>/dev/null \
      | grep -E 'rev:' || echo "  (no doma pins found yet)" ;;
  --apply)
    a="$(android_rev)"; k="$(android_kernel_rev)"
    [ -n "$a" ] && [ -n "$k" ] || die "could not read V4H android revs"
    # Rewrite the rev: line that follows each manifest URL line.
    awk -v ar="$a" -v kr="$k" '
      { print_line=$0 }
      prev ~ /yhamamachi\/android_manifest/      && $1=="rev:" { sub($2, ar) }
      prev ~ /android_kernel_manifest/           && $1=="rev:" { sub($2, kr) }
      { print; prev=print_line }
    ' "$OUR_YAML" > "$OUR_YAML.tmp" && mv "$OUR_YAML.tmp" "$OUR_YAML"
    echo "applied: android rev=$a / android-kernel rev=$k -> $OUR_YAML"
    echo "NOTE: also confirm build.sh AGL_BRANCH default matches: $(agl_branch)" ;;
  *) die "usage: $0 --print <key> | --check | --apply" ;;
esac
