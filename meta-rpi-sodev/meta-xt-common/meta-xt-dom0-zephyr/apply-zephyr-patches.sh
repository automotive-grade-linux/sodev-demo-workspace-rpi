#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Apply the Zephyr Dom0 hybrid migration patches to a west workspace.
#
# moulin's git/west fetchers have no apply_patch support and `west update`
# checks out the pinned revs clean, so this must run AFTER `west update` and
# BEFORE building the dom0 (zephyr) component.
#
# Usage: apply-zephyr-patches.sh [--manifest-only] [ZEPHYR_WS]
#   ZEPHYR_WS       = west workspace root containing zephyr/ + zephyr-dom0-xt/ +
#                     .west/ (defaults to $XT_ZEPHYR_SRC, else error).
#   --manifest-only = apply [1] (the west manifest pins) and stop. This is what the
#                     DomZ workspace wants: it shares this manifest repository, so it
#                     needs the 4.4.1 pins, but it builds none of the Dom0 sources
#                     sections [2]-[5] patch.
#
# The patch set is self-contained: on a clean checkout of the pinned revs it
# adds every symbol the SoDeV guests need (Kconfig DOM_CFG_SODEV, the xenlib
# storage initrd callbacks, and the rpi_5 dom_cfg entries). CONFIG_DOM_CFG_SODEV
# is turned on by the moulin builder var in rpi5-sodev.yaml, not here.
#
# This script also runs `west update` itself, once, in the middle: 0021 rewrites
# zephyr-dom0-xt/west.yml (Zephyr 4.4.1 + zephyrproject-rtos xenlib + the
# matching fatfs), and those pins only take effect on the next update. See the
# comment above the 0021 call for why the ordering cannot be changed.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
# --manifest-only: apply [1] (the west manifest pins) and stop. Used for the DomZ
# workspace, which shares this manifest repository but builds none of the Dom0
# sources the later sections patch.
MANIFEST_ONLY=no
if [ "${1:-}" = "--manifest-only" ]; then
	MANIFEST_ONLY=yes
	shift
fi
WS="${1:-${XT_ZEPHYR_SRC:-}}"
if [ -z "$WS" ]; then
	echo "ERROR: pass the west workspace root, or set XT_ZEPHYR_SRC." >&2
	exit 1
fi
# Normalise: a trailing slash or a `..` component would make the "$WS"/* prefix
# tests below fail to match west's already-normalised {abspath}, silently skipping
# the remote reconciliation.
WS="$(cd "$WS" 2>/dev/null && pwd -P)" || {
	echo "ERROR: '${1:-$XT_ZEPHYR_SRC}' is not a directory." >&2
	exit 1
}
[ -d "$WS/.west" ] || {
	echo "ERROR: $WS is not a west workspace (no .west/). Run 'west init'/'west update' first." >&2
	exit 1
}

# Ask west for the project list BEFORE touching anything, and use '|' as the
# separator so a path containing spaces cannot split across fields. A pipeline's
# exit status is its last stage, so capture into a variable instead of piping -
# otherwise `west list` failing would be ignored and every check below skipped.
list_projects() {
	(cd "$WS" && west list -f '{name}|{abspath}|{url}')
}
projects="$(list_projects)" || {
	echo "ERROR: 'west list' failed in $WS (bad manifest, or west not on PATH)." >&2
	exit 1
}

# If a previous run died between a fetch and its checkout, a project directory can
# be missing. Recover instead of failing: this is exactly the state build.sh cannot
# get out of on its own, because `ninja fetch-dom0` is already stamped and will not
# re-run west for us.
#
# Command substitution, not a /tmp scratch file: the loop runs in a subshell either
# way (so a plain `missing="$missing $name"` inside it would be lost), and a
# predictable name like /tmp/.xt-missing-projects.$$ can be pre-created as a symlink
# by anything sharing the machine, turning this into an arbitrary-file write.
missing="$(printf '%s\n' "$projects" | while IFS='|' read -r name abspath url; do
	case "$abspath" in "$WS"/?*) ;; *) continue ;; esac
	[ -d "$abspath/.git" ] || echo "$name"
done)"
if [ -n "$missing" ]; then
	echo "Missing project checkouts ($(echo $missing)); running 'west update' to restore them ..."
	(cd "$WS" && west update)
	projects="$(list_projects)"
fi

# Reset every project BEFORE (re)applying so the series is idempotent. `git apply`
# is a working-tree change (no commit), so the per-patch
# reverse-check idempotency probe below is unreliable for the sequential xenlib
# series: 0005-0007 then 0012/0014-0016 edit the same files, so a later patch breaks
# an earlier patch's reverse-check -> on a re-run (build.sh reinvocation where
# `ninja fetch-dom0` is already stamped, so `west update` does NOT re-clean the
# tree) apply_one hits "neither applies nor already applied" at 0007 and the dom0
# build fails. A clean reset avoids that.
#
# `reset --hard`, not `checkout -- .`: the latter restores from the index, so a
# staged partial application survives it and the reset silently does nothing.
# Failures are fatal rather than `|| true` - a reset that did not happen (dubious
# ownership, permissions) would be misdiagnosed further down as "the pinned rev
# drifted".
#
# The target is west's `manifest-rev` branch where it exists, so a *committed*
# partial application is undone too; bare `git reset --hard` only moves the working
# tree and index to HEAD and would leave such a commit in place. west writes
# manifest-rev in every project it manages; the manifest repository has none (west
# never updates it), so that one falls back to HEAD - which is correct, because the
# manifest repo is at the rev moulin's west fetcher checked out and its only local
# change is 0021, which the working-tree reset removes.
#
# The list comes from west so a project added to west.yml, or one with an explicit
# `path:`, is covered without editing this script.
#
# The manifest repository is included. `west list` reports it as name=manifest with
# url=N/A, and it is where most of this series lands (0002-0004, 0008, 0011, 0021,
# 0025-0028) - skipping it because it has no URL leaves the previous run's patches
# in place, and the next run then fails at 0002 with "neither applies to nor is
# already applied". Only the remote reconciliation below cares about the URL.
#
# This loop is the LAST place the tree may be reset: everything from the 0021 call
# onwards would be discarded by another reset.
printf '%s\n' "$projects" | while IFS='|' read -r name abspath url; do
	case "$abspath" in "$WS"/?*) ;; *) continue ;; esac
	[ -d "$abspath/.git" ] || continue
	rev="$(git -C "$abspath" rev-parse --verify -q refs/heads/manifest-rev || echo HEAD)"
	git -C "$abspath" reset --hard -q "$rev"
	git -C "$abspath" clean -fdq
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
	echo "       Fix: 'git -C $dir reset --hard manifest-rev && git -C $dir clean -fd'" >&2
	echo "       (zephyr-dom0-xt is the manifest repository and has no manifest-rev" >&2
	echo "        branch -- reset it to the rev west.yaml's self: pins instead.)" >&2
	echo "       and re-run. Name the rev: a bare 'reset --hard' only rewinds the" >&2
	echo "       working tree and index to HEAD, so a committed partial application" >&2
	echo "       survives it, and 'checkout -- .' restores from the index and so" >&2
	echo "       undoes even less. Or refresh this patch against the current rev." >&2
	return 1
}

# --- [1] The manifest first, then re-run `west update` ------------------------
#
# moulin's west source can only pin the manifest repository's url/rev, so the
# project revisions live in zephyr-dom0-xt/west.yml and the only way to change
# them is to patch that file and update again. Ordering is load-bearing:
#
#   * `west update` hard-resets every project to its pinned rev, so it MUST run
#     before any other patch. Running it later throws all of them away.
#   * The reset loop above must NOT run after this point for the same reason -
#     it would revert 0021 itself.
#   * zephyr-dom0-xt is the manifest repository (`self: path:` in west.yml), not
#     a project, so `west update` leaves it - and 0021 - alone.
apply_one zephyr-dom0-xt 0021-west-manifest-zephyr-4.4.1-and-upstream-xenlib.patch

# `west update` moves an existing checkout to the new revision, but it does NOT
# re-point that checkout's git remote when the manifest changes a project's
# remote/url - it only ever adds a remote when cloning. 0021 moves zephyr-xenlib
# from xen-troops to zephyrproject-rtos, so without this the tree would build from
# the right commit while `git remote -v` still named xen-troops. Switching to the
# upstream repository is the point of this series, so fix it up explicitly.
#
# Rewrite the URL rather than deleting the checkout. An earlier version did
# `rm -rf` and let west clone again, which is correct but far too sharp an
# instrument: any cosmetic change to west.yml's url-base (dropping the trailing
# slash, adding `.git`) flips the string comparison and would have deleted the
# ~1 GiB zephyr checkout, and if the following `west update` then failed the
# workspace was left in a state build.sh could not recover from on its own.
#
# URLs are compared normalised (trailing '/', the '//' that url-base + name
# produces, and a trailing '.git' removed) so only a genuine change of upstream
# counts. The comparison is normalised; what gets *written* is the manifest URL
# verbatim, doubled slash included, because that is exactly what west itself
# computes (url-base + '/' + name, and this manifest's url-base already ends in a
# slash) and a fresh clone would therefore show the same string.
#
# Only the leading '//' after a scheme is collapsed, so file:///srv/mirror/x keeps
# its empty authority and an scp-style remote (git@host:org/x) is left alone: the
# `[^:]` guard stops the collapse from eating the '//' in 'https://' and there is no
# '//' to collapse in the scp form at all.
norm_url() {
	printf '%s' "$1" | sed -e 's#//*$##' -e 's#\.git$##' -e 's#\([^:/]\)//*#\1/#g'
}

# The remote NAME comes from the manifest's `remotes:` list, which is what west uses
# when it clones - not from the URL's org segment. Those differ here (`xentroops`
# vs. the URL's `xen-troops`), and an earlier version derived it from the URL, so it
# renamed the remotes of projects whose upstream had not moved at all, to a name
# west would never have chosen. `west manifest --resolve` inlines remotes into plain
# URLs and so cannot answer this; read the manifest file.
manifest_remote_of() {
	awk -v want="$1" '
		/^[[:space:]]*projects:[[:space:]]*$/ { inproj = 1; next }
		inproj && /^[[:space:]]*(self|remotes|group-filter):[[:space:]]*$/ { inproj = 0 }
		inproj && $1 == "-" && $2 == "name:" { cur = $3; next }
		inproj && $1 == "name:" { cur = $2; next }
		inproj && $1 == "remote:" && cur == want { print $2; exit }
	' "$WS/zephyr-dom0-xt/west.yml"
}

# Re-read the list: $projects was captured before 0021 was applied (deliberately -
# the sanity check has to run before anything is reset), so it still holds the OLD
# manifest's URLs. Comparing against those would find every remote already correct
# and change nothing, which is exactly the bug this block exists to prevent.
projects="$(list_projects)" || {
	echo "ERROR: 'west list' failed after applying 0021 - is the patched west.yml valid?" >&2
	exit 1
}

printf '%s\n' "$projects" | while IFS='|' read -r name abspath url; do
	# The manifest repository itself reports url=N/A and has no remote to check.
	case "$url" in N/A | "") continue ;; esac
	case "$abspath" in "$WS"/?*) ;; *) continue ;; esac
	[ -d "$abspath/.git" ] || continue

	want="$(norm_url "$url")"
	org="$(manifest_remote_of "$name")"

	# A remote already carrying this URL means the upstream did not move. Leave it
	# entirely alone, name included.
	matched=
	for r in $(git -C "$abspath" remote); do
		have="$(norm_url "$(git -C "$abspath" remote get-url "$r")")"
		[ "$have" = "$want" ] && { matched=$r; break; }
	done
	[ -n "$matched" ] && continue

	# The upstream moved. Repoint a remote and, only now, give it the name the
	# manifest asks for. Prefer the remote west would have created; fall back to the
	# sole remote if there is exactly one, and refuse to guess between several.
	r=
	if [ -n "$org" ] && git -C "$abspath" remote get-url "$org" >/dev/null 2>&1; then
		r="$org"
	elif [ "$(git -C "$abspath" remote | wc -l)" = "1" ]; then
		r="$(git -C "$abspath" remote)"
	fi

	if [ -n "$r" ]; then
		echo "REMOTE $name: $r -> $url"
		git -C "$abspath" remote set-url "$r" "$url"
		if [ -n "$org" ] && [ "$r" != "$org" ]; then
			git -C "$abspath" remote rename "$r" "$org"
		fi
	else
		echo "REMOTE $name: adding ${org:-origin} -> $url"
		git -C "$abspath" remote add "${org:-origin}" "$url"
	fi
done

echo "west update: re-fetching the pins from the patched manifest ..."
(cd "$WS" && west update)

# --manifest-only stops here. The DomZ workspace is initialised from the SAME
# manifest repository as Dom0's, so without 0021 it stays on the manifest's
# Zephyr 3.6 pin -- which wants Zephyr SDK 0.16.5 while this tree's builder image
# ships 1.0.1 for 4.4.1, and the DomZ build then dies in
# FindZephyr-sdk.cmake:57 (find_package) before compiling anything. What it must
# NOT get is sections [2]-[5]: those patch the Dom0 application, xenlib and xrun,
# none of which the DomZ guest builds (its drivers are the out-of-tree module in
# its application, which carries no Zephyr source patches at all). So the split is exactly "the pins, and nothing else".
if [ "$MANIFEST_ONLY" = yes ]; then
	echo "--manifest-only: pins updated; skipping the Dom0-only patches [2]-[5]."
	exit 0
fi

# --- [2] zephyr --------------------------------------------------------------
#
# 0022-0024 are upstream backports, applied in the order their diffs were generated
# in, so every hunk lands at offset 0:
#   0022 31d2bd60ff29  sysctl interface version range
#   0023 26d1dce50e01  Xen extended regions driver  (adds include/zephyr/xen/regions.h)
#   0024 d58fbb8cfc58  drop the vendored xen public headers -> use zephyr-xenlib
#
# This is NOT upstream's topological order, which is 0023 -> 0022 -> 0024
# (26d1dce5 is an ancestor of 31d2bd60, which is an ancestor of d58fbb8c). The order
# does not matter here: 0022 and 0024 touch different lines of different files from
# 0023, and none of the three shares a hunk with another. An earlier version of this
# comment claimed 0024 had to follow 0023 because it added
# <zephyr/xen/regions.h> to drivers/xen/gnttab.c - that include was a stray addition
# that is not in the upstream commit and has been removed, so no such dependency
# exists.
apply_one zephyr         0022-xen-increase-xen-sysctl-interface-version-range.patch
# 0033 widens the DOMCTL range in the same file 0022 touches, but a different hunk
# (the domctl block at line 37, the sysctl block at line 48), so it lands at offset
# 0 right after it. Its position relative to 0008/0019/0026 does not matter for
# APPLYING it -- those patch zephyr-dom0-xt, this one patches zephyr -- what matters
# is that it is in the series at all: they set
# CONFIG_XEN_DOMCTL_INTERFACE_VERSION=0x18 in the board .conf files, and out of
# range kconfiglib discards a user value with a warning rather than failing, so
# without 0033 the build stays green while the symbol silently keeps 0x17 -- and the
# only symptom is a Dom0 whose `xu list` prints nothing on Xen 4.22.
apply_one zephyr         0033-zephyr-domctl-interface-version-0x18.patch
apply_one zephyr         0023-drivers-xen-add-xen-extended-regions-driver.patch

# 0024 upstream also deletes include/zephyr/xen/public/ (14 files). Do the removal
# here instead of in the patch: the reset loop above restores tracked files, so a
# deletion expressed as a patch hunk would be undone on every re-run and 0024 would
# then fail its forward check. Keeping 0024 to the include rewrites plus the doc
# entry is also what makes it reviewable against the upstream commit.
if [ -d "$WS/zephyr/include/zephyr/xen/public" ]; then
	rm -rf "$WS/zephyr/include/zephyr/xen/public"
	echo "RM    zephyr <- include/zephyr/xen/public (superseded by zephyr-xenlib)"
fi
apply_one zephyr         0024-xen-public-remove-and-migrate-to-zephyr-xenlib.patch

apply_one zephyr         0018-xen-domctl-zero-createdomain-hypercall-arg.patch

# --- [3] zephyr-dom0-xt ------------------------------------------------------
apply_one zephyr-dom0-xt 0002-Kconfig-add-DOM_CFG_SODEV-and-AAOS.patch
apply_one zephyr-dom0-xt 0003-xenlib-storage-optional-initrd-loading.patch
apply_one zephyr-dom0-xt 0004-dom_cfg-rpi_5-add-sodev-domu-doma.patch
apply_one zephyr-dom0-xt 0008-rpi5-board-domd-owns-sd.patch
apply_one zephyr-dom0-xt 0011-dom0-xt-doma-builtin-ramdisk-slot.patch
apply_one zephyr-dom0-xt 0025-prj-conf-mp-max-num-cpus.patch
# 0026 renames CONFIG_FS_MULTI_PARTITION, whose old spelling is context in both
# 0002 and 0008 -> it has to come after them.
apply_one zephyr-dom0-xt 0026-fatfs-kconfig-renames-for-zephyr-4.4.patch
# [rpi4] board + guest configs for rpi_4b. They only ADD files
# (boards/rpi_4b.{conf,overlay}, src/dom_cfg/rpi_4b.c) and never touch rpi_5.
# Without them the rpi_4b build configures with no Xen support at all --
# CONFIG_DT_HAS_XEN_XEN_ENABLED never gets set because the board overlay that
# declares the xen,xen node is missing, so CONFIG_XEN and everything under it stay
# off and xen-dom-mgmt.c fails to compile on GUEST_RAM0_BASE and friends.
#
# They used to sit at the very END of the series, on the grounds that adding files
# cannot disturb anything. That no longer holds: 0027 rewrites the
# <zephyr/xen/public/domctl.h> include in src/dom_cfg/rpi_4b.c, which 0020 is what
# creates. So they go here, immediately before it.
apply_one zephyr-dom0-xt 0019-boards-rpi_4b-zephyr-dom0-board.patch
apply_one zephyr-dom0-xt 0020-dom_cfg-rpi_4b-add-guest-configs.patch
apply_one zephyr-dom0-xt 0027-use-xenlib-xen-public-headers.patch
apply_one zephyr-dom0-xt 0028-rpi5-board-4.4-devices-and-xen-config.patch

# --- [4] zephyr-xenlib ------------------------------------------------------
apply_one zephyr-xenlib  0005-xenlib-optional-initrd-loading.patch
apply_one zephyr-xenlib  0006-xenlib-xenstore-toolstack-domid.patch
apply_one zephyr-xenlib  0007-xenlib-domd-toolstack.patch
apply_one zephyr-xenlib  0012-xenlib-xs-introduce-no-clobber.patch
apply_one zephyr-xenlib  0014-xenlib-xenstore-srv-wedge-reply-hardening.patch
# 0030 is placed after 0005 only because they are adjacent in the same file; it does
# not depend on it (verified: 0030 applies to a pristine checkout with offsets, and
# its three hunks have distinct pre-images so they cannot mis-apply).
apply_one zephyr-xenlib  0030-xenlib-dcache-flush-takes-a-byte-count.patch
apply_one zephyr-xenlib  0015-xenlib-toolstack-teardown-and-xsring-diag.patch
apply_one zephyr-xenlib  0016-xenlib-toolstack-destroy-ownership-guards.patch
apply_one zephyr-xenlib  0017-xenlib-guard-xu-console-unmanaged-domain.patch
# 0031/0032: defects found by adversarial review; they build on the whole xenlib
# series above, so they go last.
apply_one zephyr-xenlib  0031-xenlib-xenstore-input-validation-and-resource-bounds.patch
apply_one zephyr-xenlib  0032-xenlib-single-xen-public-header-tree.patch

# --- [5] zephyr-xrun -------------------------------------------------------
apply_one zephyr-xrun    0009-xrun-sdhc-fallback.patch
apply_one zephyr-xrun    0029-xrun-use-xenlib-xen-public-headers.patch
echo "Zephyr Dom0 hybrid patches applied to $WS."
