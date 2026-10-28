#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Stage (Pi 5) or verify (Pi 4) the board-specific AAOS guest device in an AOSP checkout.
#
# moulin's repo fetcher has no hook between `repo sync` and the AOSP build, so this runs
# AFTER `ninja fetch-doma` and BEFORE `ninja doma`. build.sh sequences it the same way it
# sequences meta-xt-dom0-zephyr/apply-zephyr-patches.sh after `ninja fetch-dom0`.
#
# Usage: stage-aosp-device.sh <AOSP_ROOT> <board>
#   AOSP_ROOT = the repo checkout root (contains .repo/ and device/)
#   board     = rpi5 | rpi4
#
# WHERE EACH BOARD'S DEVICE COMES FROM
# rpi4: a repo-managed project. The AOSP manifest names
#       automotive-grade-linux/Android_device_sodev_xenvm-cf at device/sodev/xenvm-cf
#       with groups="notdefault,rpi4", and the yaml's XT_DOMA_SOURCE_GROUP makes
#       `repo init` pass -g default,rpi4 so the checkout gets it. NOTHING is staged for
#       this board. What is left here is the checking: without the group flag the project
#       is simply absent and `lunch` fails with "Can't find a product spec", which points
#       at neither the manifest nor the flag.
# rpi5: staged from this layer. The Pi 5 has a product of its own,
#       aosp_xenvm_trout_rpi5_arm64, with its own device and BoardConfig.mk
#       (xenvm_trout_rpi5_arm64; the rpi5 branch below says why), extending
#       device/epam/aosp-xenvm-trout. That project is repo-managed, so a line
#       added there is undone by the next `repo sync`; what the Pi 5 adds --
#       init.xenvm-buried-eth0.rc, the overlay and the DomA feature set -- is
#       installed by this layer's product makefile instead.
#
# WHY THE PI 4 HAS A DEVICE OF ITS OWN
# The Raspberry Pi 4 needs a different compiler ISA baseline for the guest: a virtio
# guest still executes on the host's CPUs, and the upstream board config resolves to
# TARGET_CPU_VARIANT := cortex-a53, which is not the Cortex-A72 of a BCM2711. The
# variant is ADDITIVE -- it includes the upstream board config and overrides one line
# after it -- and AOSP finds it on its own, because board_config.mk searches
#     find -L device -maxdepth 4 -path '*/$(TARGET_DEVICE)/BoardConfig.mk'
# Note that same search errors out with "Multiple board config files for TARGET_DEVICE"
# if two configs claim ONE device name, which is why the variant has its own
# PRODUCT_DEVICE (xenvm_trout_rpi4_arm64) rather than overriding the existing one. That
# also gives each board its own out/target/product/ tree: with a shared device name,
# switching --board in an existing checkout would reuse object files compiled for the
# other CPU, with nothing to warn about it. The full argument is in that repository.
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
	echo "ERROR: $ROOT/device/epam/aosp-xenvm-trout is missing -- the manifest this device" >&2
	echo "       extends is not in the checkout, so the build would fail later and further away." >&2
	exit 1; }

# XML that a product feeds to aapt2 is checked here rather than in the build: a malformed
# overlay fails ~2.5 minutes into the AOSP build with only
#   defaults.xml:0: error: xml parser error: not well-formed (invalid token)
# and no line number. The first version of this file failed exactly that way -- XML
# comments may not contain a double hyphen, and the rationale comment used several.
check_overlay_xml() {
	python3 - "$1" <<'EOF' || { echo "ERROR: $1 is not well-formed XML." >&2; exit 1; }
import sys, xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
EOF
}

case "$BOARD" in
rpi4)
	DEVICE="xenvm_trout_rpi4_arm64"
	DEV="$ROOT/device/sodev/xenvm-cf"
	[ -d "$DEV" ] || {
		echo "ERROR: $DEV is missing." >&2
		echo "       The Pi 4 device is a repo project in the notdefault,rpi4 group, so the" >&2
		echo "       checkout only has it when repo init was given the group. Check that" >&2
		echo "       XT_DOMA_SOURCE_GROUP in the board yaml is 'default,rpi4' -- repo" >&2
		echo "       REPLACES the group set, so 'default' has to be named too -- and that" >&2
		echo "       the pinned manifest revision carries the project." >&2
		exit 1; }
	[ -f "$DEV/$DEVICE/BoardConfig.mk" ] || { echo "ERROR: $DEV/$DEVICE/BoardConfig.mk is missing." >&2; exit 1; }
	[ -f "$DEV/init.xenvm-buried-eth0.rc" ] || { echo "ERROR: $DEV/init.xenvm-buried-eth0.rc is missing." >&2; exit 1; }
	OVERLAY_XML="$DEV/overlay/frameworks/base/packages/SettingsProvider/res/values/defaults.xml"
	# A missing overlay does not fail the build, it just silently ships the AOSP
	# default for every value it sets, so say so here where it is cheap to notice.
	[ -f "$OVERLAY_XML" ] || { echo "ERROR: $OVERLAY_XML is missing." >&2; exit 1; }
	check_overlay_xml "$OVERLAY_XML"
	# Every XML under the overlay root, as for rpi5 below: it also carries
	# framework-res values (config_defaultDialer), and aapt2 names neither a line
	# nor the overlay when one of them is malformed. The same `for` form, for the
	# same subshell reason.
	for x in $(find "$DEV/overlay" -name '*.xml'); do
		check_overlay_xml "$x"
	done
	DIALER_XML="$DEV/overlay/frameworks/base/core/res/res/values/config.xml"
	# Named explicitly for the same reason as on rpi5: a MISSING file is silent.
	[ -f "$DIALER_XML" ] || { echo "ERROR: $DIALER_XML is missing." >&2; exit 1; }
	# The device installs DomaWifiRelay and DomaSettingsProviderRRO from its own
	# copies. A checkout that was staged for rpi5 still has device/agl/doma-common
	# with the same module names, and soong rejects a duplicate module name.
	for m in DomaWifiRelay DomaSettingsProviderRRO; do
		n=$(grep -rl --include=Android.bp "name: \"$m\"" "$ROOT/device" 2>/dev/null | wc -l)
		if [ "$n" != "1" ]; then
			echo "ERROR: found $n Android.bp defining $m under $ROOT/device (expected 1)." >&2
			echo "       soong rejects a duplicate module name, and a stage for rpi5 leaves" >&2
			echo "       device/agl/doma-common behind in a checkout both boards share." >&2
			exit 1
		fi
	done
	echo ">> stage-aosp-device: board=rpi4 device/sodev/xenvm-cf comes from the manifest (device $DEVICE)"
	;;
rpi5)
	# rpi5's product exists to install what device/epam/aosp-xenvm-trout cannot carry
	# (it is repo-managed): the shared init.xenvm-buried-eth0.rc and overlay, and the
	# DomA feature set. It owns a BoardConfig.mk, because some of those features are
	# BoardConfig-only variables -- BOARD_VENDOR_SEPOLICY_DIRS for the shadow-AP policy
	# among them -- and owning a BoardConfig means owning a PRODUCT_DEVICE, since
	# AOSP's board_config.mk rejects two configs for one device name.
	DEVICE="xenvm_trout_rpi5_arm64"
	SRC="$here/aosp-device/agl/xenvm-trout-rpi5"
	DST="$ROOT/device/agl/xenvm-trout-rpi5"
	[ -d "$SRC" ] || { echo "ERROR: missing device source $SRC" >&2; exit 1; }

	# device/agl/common holds what the product copies from; the product names that path,
	# so a checkout that skipped it would fail the build outright.
	rm -rf "$ROOT/device/agl/common"
	mkdir -p "$ROOT/device/agl"
	cp -a "$here/aosp-device/agl/common" "$ROOT/device/agl/common"
	[ -f "$ROOT/device/agl/common/init.xenvm-buried-eth0.rc" ] || {
		echo "ERROR: device/agl/common/init.xenvm-buried-eth0.rc not staged." >&2; exit 1; }
	OVERLAY_XML="$ROOT/device/agl/common/overlay/frameworks/base/packages/SettingsProvider/res/values/defaults.xml"
	[ -f "$OVERLAY_XML" ] || {
		echo "ERROR: device/agl/common/overlay SettingsProvider defaults not staged." >&2; exit 1; }
	# Every XML under the overlay root, not just that one file: the root now also
	# carries framework-res values (config_defaultDialer), and aapt2's diagnostic for
	# a malformed overlay names neither a line nor which overlay it came from, so an
	# unchecked file would cost the same ~2.5 minutes of build to find.
	# `for` over a substitution, NOT `find | while read`: a pipeline runs the loop in
	# a subshell, so the `exit 1` inside check_overlay_xml would leave that subshell
	# and the script would carry on and stage a broken overlay. The paths are this
	# layer's own and contain no whitespace.
	for x in $(find "$ROOT/device/agl/common/overlay" -name '*.xml'); do
		check_overlay_xml "$x"
	done
	DIALER_XML="$ROOT/device/agl/common/overlay/frameworks/base/core/res/res/values/config.xml"
	# Named explicitly rather than left to the find above: a MISSING file is the
	# failure mode here, and it is silent. Without it the DIALER role has no holder,
	# Telecom binds no InCallService, and an incoming HFP call produces no screen and
	# no ringtone -- which reads as a Bluetooth fault. See common/DEFAULT-DIALER.md.
	[ -f "$DIALER_XML" ] || {
		echo "ERROR: device/agl/common/overlay framework-res config.xml not staged." >&2; exit 1; }

	# device/agl/doma-common holds the modules the product installs by
	# MODULE name (DomaWifiRelay, DomaSettingsProviderRRO, DomaWifiOverlay).
	# soong rejects a duplicate module name across the whole tree, so there
	# must be exactly one Android.bp defining each. The rpi4 does not stage
	# this directory: its device repository carries its own copies of the
	# modules it installs, kept identical to these by hand.
	rm -rf "$ROOT/device/agl/doma-common"
	cp -a "$here/aosp-device/agl/doma-common" "$ROOT/device/agl/doma-common"
	for m in DomaWifiRelay DomaSettingsProviderRRO DomaWifiOverlay; do
		# --include=Android.bp: without it a comment in an .rc file that merely names
		# the module would count as a second definition.
		n=$(grep -rl --include=Android.bp "name: \"$m\"" "$ROOT/device" 2>/dev/null | wc -l)
		if [ "$n" != "1" ]; then
			echo "ERROR: found $n Android.bp defining $m under $ROOT/device (expected 1)." >&2
			echo "       soong rejects a duplicate module name and the build would fail." >&2
			exit 1
		fi
	done

	# Replace rather than merge, so a file deleted here does not linger in the checkout
	# and keep taking part in the build. Idempotent: re-running restages the same content.
	rm -rf "$DST"
	cp -a "$SRC" "$DST"

	# The BoardConfig has to BE there: without it build/make/core/board_config.mk
	# stops `lunch` with "No config file found for TARGET_DEVICE
	# xenvm_trout_rpi5_arm64", which names neither this script nor the staged
	# directory. See the DEVICE comment above for why rpi5 owns one.
	[ -f "$DST/$DEVICE/BoardConfig.mk" ] || {
		echo "ERROR: $DST/$DEVICE/BoardConfig.mk not staged." >&2; exit 1; }
	echo ">> stage-aosp-device: board=rpi5 staged device/agl/xenvm-trout-rpi5 + device/agl/common + device/agl/doma-common (device $DEVICE)"
	;;
*)
	echo "ERROR: unknown board '$BOARD' (expected rpi5 or rpi4)." >&2
	exit 1
	;;
esac

# Prove the result rather than trust it, for both boards: exactly one board config may
# claim the device name, whether it came from the manifest or from this script.
n=$(cd "$ROOT" && find -L device vendor -maxdepth 4 -path "*/$DEVICE/BoardConfig.mk" 2>/dev/null | wc -l)
if [ "$n" != "1" ]; then
	echo "ERROR: found $n BoardConfig.mk for device '$DEVICE' in $ROOT (expected exactly 1)." >&2
	echo "       AOSP's board_config.mk rejects more than one." >&2
	exit 1
fi
