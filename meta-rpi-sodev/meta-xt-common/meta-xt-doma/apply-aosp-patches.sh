#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Apply one of this workspace's patch sets to a repo checkout.
#
# moulin's repo source has no apply_patch support, and `repo sync` hard-resets
# every project, so this must run AFTER the fetch and BEFORE the build that reads
# the tree. That is the same shape as apply-zephyr-patches.sh, which runs after
# `ninja fetch-dom0` for the same reason.
#
# Usage: apply-aosp-patches.sh ROOT [PATCH_SET [OUTPUT]]
#   ROOT      = the repo checkout (the directory holding .repo/)
#   PATCH_SET = a directory beside this script (default: aosp-patches)
#   OUTPUT    = a ninja output built from ROOT, removed when a file the set
#               touches is newer than it (see the end of this script)
#
# Two patch sets exist, and they go to two different checkouts:
#   aosp-patches         -> the DomA AOSP tree        (after `ninja fetch-doma`)
#   aosp-kernel-patches  -> the DomA guest kernel tree (after `ninja fetch-doma_kernel`)
# Keeping one script for both is deliberate: the mechanism is identical and the
# idempotency argument below is the part that is easy to get wrong.
#
# Why the patches live here rather than in the fetched trees: they are
# repo-managed, so anything edited in place is undone by the next sync. This
# layer already keeps its qemu, Xen, mesa and TF-A deltas as patch files that a
# recipe applies; these are the same idea for the guest's own sources. The AAOS
# device tree is the one exception and it is handled differently, by
# stage-aosp-device.sh copying aosp-device/agl/ over device/agl/ -- a directory
# this workspace owns outright can be copied, whereas these patches touch
# upstream projects that repo owns.
#
# Directory layout: <patch set>/<project path>/NNNN-*.patch, where the project
# path is repo's own -- external/v4l2_codec2, packages/modules/Bluetooth,
# common-modules/virtio-media -- so no encoding is needed and none can be
# ambiguous (a path flattened with underscores cannot tell external/v4l2_codec2
# from external/v4l2/codec2). Patches are applied in `sort` order within a
# project. Projects are independent; the order between them does not matter.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
SET="${2:-aosp-patches}"
# A path would work but is not accepted: the sets are this layer's own directories,
# and taking one from the caller would make the script apply anything anywhere.
case "$SET" in
aosp-patches|aosp-kernel-patches) ;;
*)
	echo "ERROR: unknown patch set '$SET' (expected aosp-patches or aosp-kernel-patches)." >&2
	exit 1 ;;
esac
PATCHDIR="$here/$SET"
# Read now: the loop below reuses the positional parameters for each project's
# patches.
OUTPUT="${3:-}"

ROOT="${1:-${AAOS_SRC_DIR:-}}"
if [ -z "$ROOT" ]; then
	echo "ERROR: pass the checkout root, or set AAOS_SRC_DIR." >&2
	exit 1
fi
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || {
	echo "ERROR: '${1:-$AAOS_SRC_DIR}' is not a directory." >&2
	exit 1
}
[ -d "$ROOT/.repo" ] || {
	echo "ERROR: $ROOT has no .repo/ -- that is not a repo checkout." >&2
	echo "       This script is for the trees the ninja fetch-doma and" >&2
	echo "       fetch-doma_kernel targets populate." >&2
	exit 1
}
[ -d "$PATCHDIR" ] || {
	echo "ERROR: $PATCHDIR is missing." >&2
	exit 1
}

applied=0
skipped=0
# The files the sets touch, one absolute path a line, for the OUTPUT check below.
touched=""
nl='
'

# Apply one patch idempotently, with an actionable message on drift. Same
# three-way test as apply-zephyr-patches.sh: reverse-clean means it is already
# in, forward-clean means apply it, neither means the checkout moved.
apply_one() {
	proj="$1"; patch="$2"; dir="$ROOT/$proj"
	if git -C "$dir" apply --reverse --check "$patch" >/dev/null 2>&1; then
		echo "SKIP  $proj <- $(basename "$patch") (already applied)"
		skipped=$((skipped + 1))
		return 0
	fi
	if git -C "$dir" apply --check "$patch" >/dev/null 2>&1; then
		git -C "$dir" apply "$patch"
		echo "APPLY $proj <- $(basename "$patch")"
		applied=$((applied + 1))
		return 0
	fi
	echo "ERROR: $(basename "$patch") neither applies to nor is already applied" >&2
	echo "       in '$proj'. The checkout drifted from the manifest this" >&2
	echo "       workspace pins, or a previous run left it partially applied." >&2
	echo "       Failing hunks:" >&2
	git -C "$dir" apply --check --verbose "$patch" >&2 || true
	echo "       Fix: 'git -C $dir reset --hard && git -C $dir clean -fd'" >&2
	echo "       then re-run, or refresh the patch against the current rev." >&2
	return 1
}

# How much of this project's series is already applied? Answered WITHOUT
# writing anything to the checkout, and without `git apply --reverse`.
#
# The obvious test -- reverse-apply the series and see if it is clean -- does not
# work, and the way it fails is quiet. `git apply` given several patch files does
# NOT apply them one after another: it reads them all and matches each one's
# post-image against the CURRENT file. So for a series where a later patch edits
# lines an earlier one added, no single combined reverse can match, and the same
# is true of the per-patch test. A series whose patches touch separate regions
# passes either test, which is why the failure is easy to miss.
#
# What is asked instead is a content question. The series is applied one patch
# at a time to a TEMPORARY index (git apply --cached with GIT_INDEX_FILE, which
# writes blobs to the object store but leaves the real index and the working
# tree alone), and at HEAD and after each patch the files the series touches are
# compared with the checkout:
#
#   they match the result of all N patches -> N, already applied, skip
#   they match the result of the first K   -> K, apply the other N-K: the series
#                                             grew since the last run, or a run
#                                             stopped part way
#   they match HEAD                        -> 0, apply the series
#   they match none of these               -> drift, report and stop
#
# A patch that does not apply to the temporary index -- HEAD with the patches
# before it -- is out of date whatever the checkout holds, so the answer is
# "stale:<its number>": git's failing hunks are printed and the build stops,
# asking for the patch to be refreshed, without the reset advice, since a reset
# would bring the checkout back to the HEAD the patch already fails on.
#
# When the question cannot be asked at all -- no temporary index of HEAD, or no
# file name found in the patches -- the answer is "error": the build stops
# with the failing tool's own message and without the reset advice, since the
# checkout may be fine.
#
# Drift is reported with the reset command as ADVICE, for a human to run: the
# projects are repo-owned but the working tree may hold local work, and a build
# script must not silently discard it.
series_state() {  # $1=project dir, $@=patches -> 0..N, drift, stale:K or error
	sdir="$1"; shift
	# The files the series touches, as the patches name them: both sides of
	# each diff, so that a deletion or a rename is compared too.
	sfiles="$(cat "$@" | sed -n -e 's|^+++ b/||p' -e 's|^--- a/||p' \
		-e 's|^rename from ||p' -e 's|^rename to ||p' \
		-e 's|^copy from ||p' -e 's|^copy to ||p' |
		sed 's/\t.*$//' | LC_ALL=C sort -u)"
	[ -n "$sfiles" ] || {
		echo "ERROR: no file names found in the patches for $sdir." >&2
		echo error; return; }
	# The checkout's content of those files, in the form `git ls-files -s`
	# gives for the temporary index below ("<blob> <path>", absent files left
	# out), so that one string comparison decides each step.
	scur="$(for sf in $sfiles; do
		[ -e "$sdir/$sf" ] || continue
		echo "$(git -C "$sdir" hash-object -- "$sdir/$sf") $sf"
	done)"
	sidx="$(mktemp "${TMPDIR:-/tmp}/aosp-patch-idx.XXXXXX")" || {
		echo error; return; }
	GIT_INDEX_FILE="$sidx" git -C "$sdir" read-tree HEAD || {
		rm -f "$sidx"; echo error; return; }
	sn=0; smatch=drift
	while :; do
		# shellcheck disable=SC2086  # one pathspec per file, as intended
		sexp="$(GIT_INDEX_FILE="$sidx" git -C "$sdir" --literal-pathspecs \
			ls-files -s -- $sfiles | awk '{ print $2, $4 }')"
		[ "$sexp" != "$scur" ] || smatch=$sn
		[ $# -gt 0 ] || break
		GIT_INDEX_FILE="$sidx" git -C "$sdir" apply --cached "$1" >/dev/null 2>&1 || {
			GIT_INDEX_FILE="$sidx" git -C "$sdir" apply --cached --check \
				--verbose "$1" >&2 || true
			smatch="stale:$((sn + 1))"; break; }
		shift; sn=$((sn + 1))
	done
	rm -f "$sidx"
	echo "$smatch"
}

projects="$(cd "$PATCHDIR" && find . -name '*.patch' -exec dirname {} \; | sed 's|^\./||' | sort -u)"
[ -n "$projects" ] || {
	echo "ERROR: no patches under $PATCHDIR." >&2
	exit 1
}
for proj in $projects; do
	pdir="$PATCHDIR/$proj"
	if [ ! -d "$ROOT/$proj/.git" ]; then
		# The set is shared by both boards, but not every project in it is in every
		# board's checkout: device/sodev/xenvm-cf is the Raspberry Pi 4's own device,
		# an opt-in project (groups="notdefault,rpi4") that the Pi 5 does not fetch.
		# repo lists every project it synced in .repo/project.list, so a project
		# missing from that list belongs to another board and is skipped. One that IS
		# listed but has no .git is a broken checkout and still stops the build.
		if ! grep -qxF "$proj" "$ROOT/.repo/project.list" 2>/dev/null; then
			echo "SKIP  $proj (not in this checkout's .repo/project.list: another board's project)"
			continue
		fi
		echo "ERROR: $ROOT/$proj is not a git project." >&2
		echo "       The manifest this workspace pins should provide it; a" >&2
		echo "       checkout synced from a different manifest may not." >&2
		exit 1
	fi
	set -- "$pdir"/*.patch
	[ -e "$1" ] || continue
	# Both sides of each diff, as series_state() reads them, so that a deletion
	# or a rename counts too.
	touched="$touched$(cat "$@" | sed -n -e 's|^+++ b/||p' -e 's|^--- a/||p' \
		-e 's|^rename from ||p' -e 's|^rename to ||p' \
		-e 's|^copy from ||p' -e 's|^copy to ||p' |
		sed 's/\t.*$//' | LC_ALL=C sort -u | sed "s|^|$ROOT/$proj/|")$nl"
	state="$(series_state "$ROOT/$proj" "$@")"
	case "$state" in
	drift)
		echo "ERROR: '$proj' is neither at its pinned revision nor carrying this" >&2
		echo "       series or its first part: some of the files the $# patch(es)" >&2
		echo "       touch match neither HEAD nor the result of applying the" >&2
		echo "       first K of them, for any K. The checkout drifted from the" >&2
		echo "       manifest this workspace pins, or it carries a different" >&2
		echo "       version of this series (a patch was changed, removed or" >&2
		echo "       reordered after a run applied it)." >&2
		echo "       Fix: 'git -C $ROOT/$proj reset --hard && git -C $ROOT/$proj clean -fd'" >&2
		echo "       then re-run, or refresh the patches against the current rev." >&2
		exit 1 ;;
	"$#")
		echo "SKIP  $proj <- $# patch(es) (series already applied)"
		skipped=$((skipped + $#))
		continue ;;
	0) ;;
	[1-9]*)
		echo "SKIP  $proj <- the first $state of $# patch(es) (already applied)"
		skipped=$((skipped + state))
		shift "$state" ;;
	stale:*)
		sk="${state#stale:}"
		sp="$(printf '%s\n' "$@" | sed -n "${sk}p")"
		if [ "$sk" -gt 1 ]; then at="HEAD with the $((sk - 1)) patch(es) before it applied"; else at="HEAD"; fi
		echo "ERROR: $(basename "$sp") (patch $sk of $#) does not apply to '$proj' at" >&2
		echo "       $at; git's failing hunks are above. The patch is out of" >&2
		echo "       date: refresh it against the revision this workspace's manifest" >&2
		echo "       pins, which HEAD should be. '$proj' was not changed." >&2
		exit 1 ;;
	*)  # error: the check itself failed, and said why on stderr
		echo "ERROR: could not tell how much of its series '$proj' carries:" >&2
		echo "       the check itself failed (see the message above). '$proj'" >&2
		echo "       was not changed." >&2
		exit 1 ;;
	esac
	for p in "$@"; do apply_one "$proj" "$p"; done
done

echo "apply-aosp-patches[$SET]: $applied applied + $skipped already applied," \
     "across $(printf '%s\n' "$projects" | wc -l) project(s) in $ROOT"

# A ninja output that is older than the sources it is built from. moulin's rules
# for the DomA guest kernel and for the AOSP build depend on the repo-sync stamp
# (and the AOSP one on the kernel), so a patch added to a set after the first
# build is applied here and then never compiled: `ninja doma_kernel` / `ninja doma`
# see their outputs and do nothing. Removing the output makes ninja run the build
# again; bazel and Soong are incremental. Checked
# on every run, not only when something was applied just now, so a run that
# applied a patch and stopped before the build is caught by the next one.
# A file a patch deleted or renamed away is judged by the nearest directory that
# is still there: its mtime changed with the deletion (git apply also removes a
# directory the deletion left empty, which changes its parent's). Not by ROOT
# itself, whose mtime changes whenever a project is added to the checkout.
if [ -n "$OUTPUT" ] && [ -e "$OUTPUT" ]; then
	printf '%s\n' "$touched" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		while [ ! -e "$f" ] && [ "$f" != "$ROOT" ] && [ "$f" != / ]; do
			f="$(dirname "$f")"
		done
		case "$f" in "$ROOT"|/) continue ;; esac
		if [ "$f" -nt "$OUTPUT" ]; then
			rm -f "$OUTPUT"
			echo "STALE $OUTPUT: older than $f, removed so that it is rebuilt"
			break
		fi
	done
fi
