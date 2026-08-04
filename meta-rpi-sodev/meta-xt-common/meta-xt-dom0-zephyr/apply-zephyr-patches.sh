#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Apply the Zephyr Dom0 hybrid migration patches to a west workspace.
#
# moulin's git/west fetchers have no apply_patch support and `west update`
# checks out the pinned revs clean, so this must run AFTER `west update` and
# BEFORE building the dom0 (zephyr) component.
#
# Usage: apply-zephyr-patches.sh [ZEPHYR_WS]
#   ZEPHYR_WS = west workspace root containing zephyr/ + zephyr-dom0-xt/ + .west/
#               (defaults to $XT_ZEPHYR_SRC, else error).
#
# The patch set is self-contained: on a clean checkout of the pinned revs it
# adds every symbol the SoDeV guests need (Kconfig DOM_CFG_SODEV, the xenlib
# storage initrd callbacks, and the rpi_5 dom_cfg entries). CONFIG_DOM_CFG_SODEV
# is turned on by the moulin builder var in rpi5-sodev.yaml, not here.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
WS="${1:-${XT_ZEPHYR_SRC:-}}"
if [ -z "$WS" ]; then
	echo "ERROR: pass the west workspace root, or set XT_ZEPHYR_SRC." >&2
	exit 1
fi

for d in zephyr zephyr-dom0-xt zephyr-xenlib zephyr-xrun; do
	[ -d "$WS/$d/.git" ] || { echo "ERROR: $WS/$d is not a git checkout (run 'west update' first)." >&2; exit 1; }
	# Reset each west project to its manifest-pinned rev BEFORE (re)applying so the
	# series is idempotent. `git apply` is a working-tree change (no commit), so the
	# per-patch reverse-check idempotency probe below is unreliable for the sequential
	# xenlib series: 0005-0007 then 0012/0014-0016 edit the same files, so a later
	# patch breaks an earlier patch's reverse-check -> on a re-run (build.sh
	# reinvocation where `ninja fetch-dom0` is already stamped, so `west update`
	# does NOT re-clean the tree) apply_one hits "neither applies nor already
	# applied" at 0007 and the dom0 build fails. A clean reset avoids that.
	git -C "$WS/$d" checkout -- . 2>/dev/null || true
	git -C "$WS/$d" clean -fdq 2>/dev/null || true
done

# Apply one patch idempotently and with an actionable message on drift.
apply_one() {
	repo="$1"; patch="$2"; dir="$WS/$repo"
	# Already fully applied? (reverse applies cleanly) -> skip. Safe under `set
	# -e`: the test lives in an `if` condition, which is exempt.
	if git -C "$dir" apply --reverse --check "$here/$patch" >/dev/null 2>&1; then
		echo "SKIP  $repo <- $patch (already applied)"
		return 0
	fi
	# Cleanly applicable forward? -> apply.
	if git -C "$dir" apply --check "$here/$patch" >/dev/null 2>&1; then
		git -C "$dir" apply "$here/$patch"
		echo "APPLY $repo <- $patch"
		return 0
	fi
	# Neither reverse- nor forward-clean: a partially-applied tree or a pinned
	# rev that has drifted. Surface the exact failing hunks instead of letting
	# `set -e` abort with no context.
	echo "ERROR: $patch neither applies to nor is already applied in '$repo'." >&2
	echo "       The checkout likely drifted from the pinned rev (see west.yaml)," >&2
	echo "       or a previous run left it partially applied. Failing hunks:" >&2
	git -C "$dir" apply --check --verbose "$here/$patch" >&2 || true
	echo "       Fix: 'git -C $dir checkout -- .' to the pinned rev and re-run," >&2
	echo "       or refresh this patch against the current rev." >&2
	return 1
}

apply_one zephyr         0001-xen-public-domctl-add-altp2m-field-4.21-abi.patch
apply_one zephyr-dom0-xt 0002-Kconfig-add-DOM_CFG_SODEV-and-AAOS.patch
apply_one zephyr-dom0-xt 0003-xenlib-storage-optional-initrd-loading.patch
apply_one zephyr-dom0-xt 0004-dom_cfg-rpi_5-add-sodev-domu-doma.patch
apply_one zephyr-xenlib  0005-xenlib-optional-initrd-loading.patch
apply_one zephyr-xenlib  0006-xenlib-xenstore-toolstack-domid.patch
apply_one zephyr-xenlib  0007-xenlib-domd-toolstack.patch
apply_one zephyr-dom0-xt 0008-rpi5-board-domd-owns-sd.patch
apply_one zephyr-xrun    0009-xrun-sdhc-fallback.patch
apply_one zephyr         0010-zephyr-sysctl-interface-version-0x16.patch
apply_one zephyr-dom0-xt 0011-dom0-xt-doma-builtin-ramdisk-slot.patch
apply_one zephyr-xenlib  0012-xenlib-xs-introduce-no-clobber.patch
apply_one zephyr         0013-zephyr-regions-null-init-ptr.patch
apply_one zephyr-xenlib  0014-xenlib-xenstore-srv-wedge-reply-hardening.patch
apply_one zephyr-xenlib  0015-xenlib-toolstack-teardown-and-xsring-diag.patch
apply_one zephyr-xenlib  0016-xenlib-toolstack-destroy-ownership-guards.patch
apply_one zephyr-xenlib  0017-xenlib-guard-xu-console-unmanaged-domain.patch
apply_one zephyr         0018-xen-domctl-zero-createdomain-hypercall-arg.patch
echo "Zephyr Dom0 hybrid patches applied to $WS."
