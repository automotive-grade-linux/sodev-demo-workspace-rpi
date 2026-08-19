#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Stage the DomA guest kernel (bazel dist) INTO the AOSP checkout, so Soong can read it.
#
# WHY THIS EXISTS
# The guest kernel is built by a separate moulin component (doma_kernel, bazel/kleaf) whose
# output lands outside the AOSP checkout, and the AOSP build is told where it is with two
# environment variables the yaml sets on the doma component:
#     TARGET_PREBUILT_KERNEL       -> device/epam/aosp-xenvm-trout/aosp_xenvm_trout_arm64.mk
#                                     assigns it to TARGET_KERNEL_PATH, and trout turns that
#                                     into the PRODUCT_COPY_FILES entry whose dest is "kernel"
#     TARGET_PREBUILT_MODULES_DIR  -> xenvm_trout_arm64/BoardConfig.mk assigns it to
#                                     SYSTEM_DLKM_SRC / KERNEL_MODULES_PATH and globs the
#                                     *.ko out of it for BOARD_VENDOR_RAMDISK_KERNEL_MODULES
#
# Up to Android 15 those could be "../<kernel checkout>/..." because the filesystem images
# were assembled by Make, which does not care where a path points. Android 16 moved image
# assembly into Soong (build/soong/fsgen, module "soong_filesystem_creator"), and Soong
# validates every source path it is handed:
#
#     build/soong/android/paths.go   (validatePathInternal)
#       path := filepath.Clean(path)
#       if path == ".." || strings.HasPrefix(path, "../") || strings.HasPrefix(path, "/") {
#               return "", fmt.Errorf("Path is outside directory: %s", path)
#       }
#
# So on Android 17 the old form fails during soong analysis, once per artefact:
#
#     error: build/soong/fsgen/Android.bp:41:1: module "soong_filesystem_creator":
#            Path is outside directory: ../android_kernel/out/deploy/.../Image
#
# Note BOTH escapes are rejected: a "../" relative path and an absolute path. The path has
# to be relative AND inside the AOSP source tree. Hence this script: it puts the dist where
# Soong will accept it, and the yaml then names it with a tree-relative path.
#
# WHY A COPY RATHER THAN A SYMLINK
# A symlink whose target leaves the source tree does pass the validation above (it is a
# string check on the path, and the stat that follows succeeds) -- measured. It was not
# chosen because it makes the artefacts invisible to the build system as *files*: Soong and
# siso would track the link, not the Image behind it, so a rebuilt kernel could be missed
# and a stale one shipped. A copy costs ~55 MiB per build and is refreshed unconditionally
# on every run.
#
# THE STAGED COPY IS STILL NOT IN NINJA'S GRAPH -- AND THAT IS GUARDED ELSEWHERE
# moulin generates the ninja file, so this script cannot become a ninja edge. The doma
# component therefore lists BOTH the dist Image (so a rebuilt kernel re-runs the AOSP
# build) and this staged Image (so a checkout that never ran the staging fails loudly
# instead of building against nothing) in additional_deps. Neither edge can detect a
# staged copy that is merely STALE, so aaos-guest-binaries compares the two byte for byte
# before it ships either one -- see its AAOS_KERNEL_STAGE_DIR check. That matters because
# p1's kernel comes from the dist while p4's vendor_dlkm modules come from this copy: if
# they disagree, module_layout does too, ~97 modules fail to load and the guest never
# reaches SurfaceFlinger while still setting sys.boot_completed=1.
#
# WHY THE AOSP ROOT AND NOT device/
# The stage directory is created at the TOP of the AOSP checkout, not under device/epam/...,
# because everything under device/ is a repo-managed project: `repo sync` would delete the
# staged copy (and staging into a project would also mean modifying upstream, which this
# workspace does not do -- see stage-aosp-device.sh). A directory of its own at the root is
# not part of any project, so repo leaves it alone. That is a property of the NAME, not of
# this script, so the name is checked against .repo/project.list below rather than assumed.
#
# Usage: stage-doma-kernel.sh <KERNEL_DIST_DIR> <AOSP_ROOT> <STAGE_DIR_NAME>
#   KERNEL_DIST_DIR = the doma_kernel bazel dist dir (holds Image and the *.ko)
#   AOSP_ROOT       = the AOSP repo checkout root
#   STAGE_DIR_NAME  = directory to create inside AOSP_ROOT (tree-relative, no slashes)
#
# Runs AFTER `ninja doma_kernel` and BEFORE `ninja doma`; build.sh sequences it the same way
# it sequences stage-aosp-device.sh between `ninja fetch-doma` and the AOSP build.
set -eu

DIST="${1:-}"
ROOT="${2:-}"
NAME="${3:-}"

if [ -z "$DIST" ] || [ -z "$ROOT" ] || [ -z "$NAME" ]; then
	echo "usage: $0 <KERNEL_DIST_DIR> <AOSP_ROOT> <STAGE_DIR_NAME>" >&2
	exit 1
fi

# The name is about to be the argument of `rm -rf`, so validate it before anything else.
# A single path component of [A-Za-z0-9._-], not "." or "..", not starting with "-" (which
# would be read as an option by the tools below).
case "$NAME" in
*/*)          echo "ERROR: STAGE_DIR_NAME must be a single directory name, got '$NAME'." >&2; exit 1 ;;
. | ..)       echo "ERROR: STAGE_DIR_NAME must not be '$NAME'." >&2; exit 1 ;;
-*)           echo "ERROR: STAGE_DIR_NAME must not start with '-', got '$NAME'." >&2; exit 1 ;;
*[!A-Za-z0-9._-]*) echo "ERROR: STAGE_DIR_NAME may only contain A-Za-z0-9._- , got '$NAME'." >&2; exit 1 ;;
esac
# Names the AOSP build owns. `out` is the one that matters: it is not a repo project and it
# does not exist yet before the first build, so neither of the two guards below would stop
# `rm -rf out` from discarding every build artefact. The others are cheap to list while here.
case "$NAME" in
out | .repo | build | development | prebuilts | vendor | device | external | system | frameworks | packages | hardware | kernel | toolchain | art | bionic | libcore)
	echo "ERROR: STAGE_DIR_NAME must not be '$NAME' -- that is an AOSP tree name." >&2
	echo "       Pick something the AOSP build does not own (ANDROID_KERNEL_STAGE_DIR" >&2
	echo "       in the board yaml; the default is xt-doma-kernel)." >&2
	exit 1 ;;
esac

[ -d "$ROOT/.repo" ] || { echo "ERROR: $ROOT is not a repo checkout (run 'ninja fetch-doma' first)." >&2; exit 1; }
[ -d "$DIST" ] || {
	echo "ERROR: $DIST does not exist -- the guest kernel has not been built." >&2
	echo "       Run 'ninja doma_kernel' before this script (build.sh does)." >&2
	exit 1; }

DST="$ROOT/$NAME"
MARKER=".xt-doma-kernel-stage"

# Refuse to rm -rf anything that is not ours. Two independent checks, because either alone
# leaves a hole:
#
#   1. repo's own project list. A project is nested UNDER the name that would be removed
#      (project.list has "external/boringssl", never a bare "external"), so this has to be
#      a prefix match -- an exact match would not notice that `rm -rf external` destroys
#      557 projects. Measured: without this check, STAGE_DIR_NAME=external deleted the
#      whole tree and still printed a success line.
#   2. a marker file we write ourselves. That covers a directory the user created at the
#      AOSP root for their own reasons, which repo knows nothing about.
if [ -f "$ROOT/.repo/project.list" ] &&
   grep -q -e "^$NAME\$" -e "^$NAME/" "$ROOT/.repo/project.list"; then
	echo "ERROR: '$NAME' is (or contains) a repo-managed project in $ROOT." >&2
	echo "       Refusing to delete it. Pick a name that is not in .repo/project.list" >&2
	echo "       (ANDROID_KERNEL_STAGE_DIR in the board yaml)." >&2
	exit 1
fi
if [ -e "$DST" ] && [ ! -e "$DST/$MARKER" ]; then
	echo "ERROR: $DST already exists but carries no $MARKER, so this script will" >&2
	echo "       not delete it. Either it is not ours -- move it aside, or pick" >&2
	echo "       another ANDROID_KERNEL_STAGE_DIR in the board yaml -- or a previous" >&2
	echo "       run of this script was interrupted between creating the directory" >&2
	echo "       and writing the marker, in which case deleting it is safe." >&2
	exit 1
fi

# Prove the inputs are there before touching the destination, so a half-built kernel is
# reported here instead of surfacing as a Soong error about a missing source file.
[ -f "$DIST/Image" ] || { echo "ERROR: $DIST/Image is missing." >&2; exit 1; }

# A symlink in the dist would defeat the whole point of copying (see above): cp -a would
# preserve it and a plain `-type f` count would not even see it, so the checks below would
# pass while the tree pointed outside itself. rules_pkg does not produce any today; fail
# loudly if that ever changes rather than silently staging a link.
LINKS="$(find "$DIST" -maxdepth 1 -type l -print 2>/dev/null || true)"
[ -z "$LINKS" ] || {
	echo "ERROR: $DIST contains symlinks, which must not be staged:" >&2
	printf '  %s\n' $LINKS >&2
	exit 1; }

# Count via a file, not a pipe: `find | wc -l` reports wc's exit status, so a find that
# fails (permissions, say) would silently become "0 modules" and blame the module build.
KO_LIST="$(mktemp)"
trap 'rm -f "$KO_LIST"' EXIT INT TERM
find "$DIST" -maxdepth 1 -type f -name '*.ko' > "$KO_LIST"
n_ko=$(wc -l < "$KO_LIST")
[ "$n_ko" -gt 0 ] || { echo "ERROR: no *.ko in $DIST -- the module build produced nothing." >&2; exit 1; }

# Replace rather than merge: a module dropped from the kernel's module_outs must not linger
# in the staged tree and keep being loaded into vendor_ramdisk. Idempotent -- re-running
# restages the same content.
rm -rf "$DST"
mkdir -p "$DST"
: > "$DST/$MARKER"
# Copy the dist verbatim (Image, the *.ko, System.map, .config, the uapi headers tarball).
# Not just Image+*.ko: TARGET_PREBUILT_MODULES_DIR is handed to SYSTEM_DLKM_SRC as a
# DIRECTORY, so keeping the dist's exact content is what preserves the pre-17 behaviour.
cp -a "$DIST"/. "$DST"/

# Prove the result rather than trust the copy. diff -r covers every file's content in one
# go -- a truncated .ko (disk full) would pass a name/count comparison. The marker is ours,
# so it is the only expected difference.
if ! diff -r --no-dereference -x "$MARKER" "$DIST" "$DST" >/dev/null; then
	echo "ERROR: $DST does not match $DIST after the copy:" >&2
	diff -r --no-dereference -x "$MARKER" "$DIST" "$DST" >&2 || true
	exit 1
fi
echo ">> stage-doma-kernel: staged $NAME/ in the AOSP checkout (Image + $n_ko modules)"
