#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Stage the board-specific AAOS guest device configuration into an AOSP repo checkout.
#
# moulin's repo fetcher has no hook between `repo sync` and the AOSP build, so this runs
# AFTER `ninja fetch-doma` and BEFORE `ninja doma`. build.sh sequences it the same way it
# sequences meta-xt-dom0-zephyr/apply-zephyr-patches.sh after `ninja fetch-dom0`.
#
# Usage: stage-aosp-device.sh <AOSP_ROOT> <board>
#   AOSP_ROOT = the repo checkout root (contains .repo/ and device/)
#   board     = rpi5 | rpi4
#
# WHY A COPIED DEVICE RATHER THAN A PATCH
# The Raspberry Pi 4 needs a different compiler ISA baseline for the guest (see
# aosp-device/agl/xenvm-trout-rpi4/xenvm_trout_rpi4_arm64/BoardConfig.mk). Patching
# device/epam/aosp-xenvm-trout would mean modifying a repo-managed project: `repo sync`
# resets it, the patch has to be re-applied every time, and it silently rots when the
# pinned manifest revision moves. Adding a SEPARATE device instead touches nothing
# upstream — the file it needs is an include of the upstream board config plus two
# assignments — and AOSP finds it on its own, because board_config.mk searches
#     find -L device -maxdepth 4 -path '*/$(TARGET_DEVICE)/BoardConfig.mk'
# Note that same search errors out with "Multiple board config files for TARGET_DEVICE"
# if two configs claim ONE device name, which is why the variant has its own
# PRODUCT_DEVICE (xenvm_trout_rpi4_arm64) rather than overriding the existing one.
#
# The distinct PRODUCT_DEVICE also gives each board its own out/target/product/ tree. With
# a shared device name, switching --board in an existing checkout would reuse object
# files compiled for the other CPU, with nothing to warn about it.
#
# rpi5 needs no staging: it uses the upstream product as-is.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-}"
BOARD="${2:-}"

if [ -z "$ROOT" ] || [ -z "$BOARD" ]; then
	echo "usage: $0 <AOSP_ROOT> <rpi5|rpi4>" >&2
	exit 1
fi
[ -d "$ROOT/.repo" ] || { echo "ERROR: $ROOT is not a repo checkout (run 'ninja fetch-doma' first)." >&2; exit 1; }
[ -d "$ROOT/device/epam/aosp-xenvm-trout" ] || {
	echo "ERROR: $ROOT/device/epam/aosp-xenvm-trout is missing — the manifest this device" >&2
	echo "       extends is not in the checkout, so the staged config would not build." >&2
	exit 1; }

case "$BOARD" in
rpi5)
	echo ">> stage-aosp-device: board=rpi5 uses the upstream product; nothing to stage."
	exit 0
	;;
rpi4)
	SRC="$here/aosp-device/agl/xenvm-trout-rpi4"
	DST="$ROOT/device/agl/xenvm-trout-rpi4"
	DEVICE="xenvm_trout_rpi4_arm64"
	;;
*)
	echo "ERROR: unknown board '$BOARD' (expected rpi5 or rpi4)." >&2
	exit 1
	;;
esac

[ -d "$SRC" ] || { echo "ERROR: missing device source $SRC" >&2; exit 1; }

# Replace rather than merge, so a file deleted here does not linger in the checkout and
# keep taking part in the build. Idempotent: re-running restages the same content.
rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -a "$SRC" "$DST"

# Prove the result rather than trust the copy. Both checks catch a real failure mode:
# a missing BoardConfig.mk means `lunch` fails with "Can't find a product spec", and a
# second config for the same device name makes board_config.mk error out.
[ -f "$DST/$DEVICE/BoardConfig.mk" ] || { echo "ERROR: $DST/$DEVICE/BoardConfig.mk not staged." >&2; exit 1; }
n=$(cd "$ROOT" && find -L device vendor -maxdepth 4 -path "*/$DEVICE/BoardConfig.mk" 2>/dev/null | wc -l)
if [ "$n" != "1" ]; then
	echo "ERROR: found $n BoardConfig.mk for device '$DEVICE' in $ROOT (expected exactly 1)." >&2
	echo "       AOSP's board_config.mk rejects more than one." >&2
	exit 1
fi
echo ">> stage-aosp-device: board=$BOARD staged device/agl/xenvm-trout-rpi4 (device $DEVICE)"
