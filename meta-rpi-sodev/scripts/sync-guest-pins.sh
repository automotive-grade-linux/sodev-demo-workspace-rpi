#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Follow V4H (AGL SoDeV) pins from the external/sodev-demo-workspace submodule.
# moulin has no cross-file include, so the pins are duplicated into our build.sh /
# rpi5-sodev.yaml; this script reports the upstream values so drift stays visible.
#
# The DomA manifest pins are NO LONGER derived from V4H and --apply refuses to touch
# them, for two reasons. V4H is on Android 15 (yhamamachi/android_manifest @ aff3224d,
# branch android-15-xenvm-trout-ih-main) with an Android 14 era kernel manifest
# (xen-troops/android_kernel_manifest @ 23e08b76, common-android14-6.1-xenvm-trout-main),
# while this workspace is on Android 17 (android-17.0.0_r1) with the GKI android17-6.18
# guest kernel, so copying V4H's revisions over ours would downgrade the guest by two
# releases. The two workspaces also select different entry points: this one asks the
# kernel manifest for its pinned manifest by name (see `manifest:` in the yamls), so a
# revision copied from V4H would be paired with the wrong one. --check still prints
# both sides, which is what keeps the difference auditable; use it, then decide
# deliberately.
#
# --check reads our side by keying on the `manifest:` line rather than on a repository
# URL, because the URL is not stable: the two components currently point at the author's
# forks while the upstream pull requests are open, and they move back to yhamamachi when
# those land (the yamls carry the switch-back procedure).
#
# Usage:
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --print {agl-branch|android-rev|android-kernel-rev}
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --check     # show V4H pins vs our pins (drift)
#   meta-rpi-sodev/scripts/sync-guest-pins.sh --apply     # refuses; see the note above
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
    # Key on the `manifest:` line: both repo components have one, and their names are
    # what distinguishes the AOSP tree from the pinned kernel manifest.
    grep -nE '^ +manifest: [-a-z0-9.]+\.xml' -B2 "$OUR_YAML" 2>/dev/null \
      | grep -E 'rev:|manifest:' || echo "  (no doma pins found yet)" ;;
  --apply)
    cat >&2 <<'EOT'
ERROR: --apply is disabled for the DomA manifest pins.

This workspace pins Android 17 (AOSP android-17.0.0_r1 + GKI android17-6.18); V4H
pins Android 15 with an Android 14 era kernel manifest. Rewriting our revisions to
match V4H would downgrade the Android guest by two releases, and the 17 manifests
are forks that carry changes the V4H ones do not have (Mesa 25.3.6 for the Android 17
toolchain; all 59 kernel projects pinned to a SHA).

Use --check to see both sides, then edit rpi5-sodev.yaml / rpi4-sodev.yaml by hand if
a change is really intended.
EOT
    exit 1 ;;
  *) die "usage: $0 --print <key> | --check | --apply" ;;
esac
