#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# p4-tool.sh - inspect (check) or factory-reinit (reinit) SD p4, the DomA AAOS
# combined GPT disk (the moulin ENABLE_ANDROID doma android sub-image).
#
# p4 is an AOSP-style *nested GPT* (a whole android disk laid inside the SD's p4).
# Its partition set and offsets are AOSP-build-dependent (AVB/init_boot slots,
# partition order and sizes all change between AOSP trees), so this tool does NOT
# hard-code any LBA. It reads the nested GPT at runtime and locates the userdata,
# metadata, misc and super partitions BY NAME (`gpt_find`). This is intentionally
# safe: a layout change no longer makes 'check' report a false NG (which would
# otherwise tempt an unnecessary SD reflash).
#
# For reference, the layout as assembled by the current build (the full SD image
# p4, sizes in 512B sectors, p4-relative) is:
#   boot_a 2048.. boot_b.. init_boot_a/b vendor_boot_a/b vbmeta_a/b misc metadata
#   super userdata     (misc/metadata precede super; userdata is the last extent)
# The tool discovers the actual first/last LBA of each named partition itself, so
# the exact numbers above are informational only.
#
# userdata is encrypted block-by-block with AES-256-XTS (after the first boot) via
# the fstab keydirectory=/metadata/vold/metadata_encryption, so an external fsck is
# fundamentally impossible. 'check' only judges state at the superblock level;
# 'reinit' restores userdata+metadata to the factory state without touching super.
#
# Usage:
#   ./p4-tool.sh check                        # inspect via ssh to DomD (read-only)
#   ./p4-tool.sh check --image /path/to.img   # inspect a p4 image file (the nested-GPT disk)
#   ./p4-tool.sh check --local                # run directly on DomD (busybox od/dd only)
#   ./p4-tool.sh reinit                        # factory-reinit userdata+metadata (double confirm)
#   ./p4-tool.sh reinit --dry-run              # show the plan only
#   ./p4-tool.sh reinit --with-misc            # also zero misc
#
# SSH auth: the ssh/reinit paths use plain `ssh $DOMD` (set up keys/agent). For
# the closed-lab empty-root image, prefix with sshpass via the env, e.g.:
#   SSH_PREFIX="sshpass -e" SSHPASS= ./p4-tool.sh check
set -u

# 192.168.10.10 is DomD (the toolstack domain), not Dom0: DomD owns xenbr0 and is
# where xl / dd / od run. Dom0 is 192.168.0.1 and in the zephyr flavour has no
# shell at all. DOM0 is kept as a deprecated alias for existing callers.
DOMD="${DOMD:-${DOM0:-root@192.168.10.10}}"
DEV="${DEV:-/dev/mmcblk0p4}"
# DomD domid that owns the p4 block device (xvdc). Fixed at 1 in the SoDeV
# disaggregated layout (Dom0=Zephyr, DomD=domid 1); overridable via env if the
# toolstack assigns a different id.
DOMD_ID="${DOMD_ID:-1}"
# SSH transport prefix. Default: plain ssh (use keys/agent). For the closed-lab
# empty-root image, run non-interactively with:  SSH_PREFIX="sshpass -e" SSHPASS= ...
SSH_PREFIX="${SSH_PREFIX:-}"

# Access mode for readhex: ssh (default) | image | local. $DEV / $IMG is the p4
# disk itself, so all sector numbers below are p4-relative (nested-GPT LBAs).
MODE="ssh"
IMG=""

usage() {
  cat >&2 <<'EOF'
usage: p4-tool.sh <command> [options]
  check  [--image <file> | --local]     non-destructive inspection of p4
  reinit [--dry-run] [--with-misc]       reinitialize userdata+metadata to factory state
EOF
  exit 1
}

# readhex <sector> <count512> -> hex string (no spaces/newlines). p4-relative.
readhex() {
  case "$MODE" in
    image) dd if="$IMG" bs=512 skip="$1" count="$2" 2>/dev/null | od -An -v -tx1 | tr -d ' \n';;
    local) dd if="$DEV" bs=512 skip="$1" count="$2" 2>/dev/null | od -An -v -tx1 | tr -d ' \n';;
    ssh)   $SSH_PREFIX ssh "$DOMD" "dd if=$DEV bs=512 skip=$1 count=$2 2>/dev/null" | od -An -v -tx1 | tr -d ' \n';;
  esac
}
# hexat <hexstr> <byte_off> <len> -> substring
hexat() { printf '%s' "${1:$((  $2 * 2 )):$(( $3 * 2 ))}"; }
iszero() { case "$1" in *[1-9a-f]*) return 1;; *) return 0;; esac; }

# le_to_dec <hexstr> <nbytes> : little-endian hex -> decimal (LBAs fit in 63 bits).
le_to_dec() {
  local h="$1" n="$2" be="" i
  for (( i=n-1; i>=0; i-- )); do be="$be${h:$(( i*2 )):2}"; done
  echo $(( 16#$be ))
}
# gpt_name <hexstr(144)> : GPT UTF-16LE name field (72 bytes) -> ASCII name.
gpt_name() {
  local h="$1" i b ch out=""
  for (( i=0; i<72; i+=2 )); do
    b="${h:$(( i*2 )):2}"
    [ "$b" = "00" ] && break
    printf -v ch "\\x$b"; out="$out$ch"
  done
  printf '%s' "$out"
}

# --- nested-GPT reader ------------------------------------------------------
# gpt_load : read the nested GPT header (LBA1) + entry array; caches the entry
#            array hex. rc 0 on a valid 'EFI PART' header, else rc 1.
GPT_ENTRIES=""; GPT_NUM=0; GPT_ESIZE=128; GPT_PLBA=2
gpt_load() {
  local hdr secs
  hdr=$(readhex 1 1)
  [ "$(hexat "$hdr" 0 8)" = "4546492050415254" ] || return 1   # 'EFI PART'
  GPT_PLBA=$(le_to_dec "$(hexat "$hdr" 72 8)" 8)   # partition-entry starting LBA
  GPT_NUM=$(le_to_dec "$(hexat "$hdr" 80 4)" 4)    # number of entries
  GPT_ESIZE=$(le_to_dec "$(hexat "$hdr" 84 4)" 4)  # bytes per entry
  # sanity clamp (a corrupt header must not make us read gigabytes)
  { [ "$GPT_NUM" -ge 1 ] && [ "$GPT_NUM" -le 512 ] && [ "$GPT_ESIZE" -ge 128 ] && [ "$GPT_ESIZE" -le 512 ]; } || return 1
  secs=$(( (GPT_NUM * GPT_ESIZE + 511) / 512 ))
  GPT_ENTRIES=$(readhex "$GPT_PLBA" "$secs")
  return 0
}
# gpt_find <name> : echo "<first_lba> <last_lba>" (decimal, p4-relative); rc 0 if found.
gpt_find() {
  local want="$1" i off e nm
  for (( i=0; i<GPT_NUM; i++ )); do
    off=$(( i * GPT_ESIZE ))
    e="${GPT_ENTRIES:$(( off*2 )):$(( GPT_ESIZE*2 ))}"
    [ -n "$e" ] || break
    case "${e:0:32}" in 00000000000000000000000000000000) continue;; esac   # empty type GUID
    nm=$(gpt_name "${e:$(( 56*2 )):$(( 72*2 ))}")
    if [ "$nm" = "$want" ]; then
      echo "$(le_to_dec "${e:$(( 32*2 )):16}" 8) $(le_to_dec "${e:$(( 40*2 )):16}" 8)"
      return 0
    fi
  done
  return 1
}

# ============================================================================
# check - non-destructive inspection
#     PLAIN_F2FS = unencrypted f2fs (virgin / pre-first-boot = factory state)
#     BLANK      = all zero (uninitialized)
#     ENCRYPTED  = random-looking data (booted at least once; health cannot be
#                  judged externally)
# ============================================================================
cmd_check() {
  case "${1:-}" in
    --image) MODE="image"; IMG="${2:?--image <file>}";;
    --local) MODE="local";;
    "") ;;
    *) echo "usage: p4-tool.sh check [--image <file> | --local]"; exit 1;;
  esac

  local fail=0
  note() { printf '  %-46s %s\n' "$1" "$2"; }
  bad()  { printf '  %-46s %s\n' "$1" "$2"; fail=1; }

  echo "== p4-tool check ($MODE) $(date '+%F %T') =="

  # 1. GPT header (LBA1) + entry array
  if gpt_load; then
    note "GPT header (LBA1) 'EFI PART'" "OK (entries=$GPT_NUM x ${GPT_ESIZE}B @LBA$GPT_PLBA)"
  else
    bad  "GPT header (LBA1)" "NG (signature/geometry) -> p4 is corrupt / not deployed"
    echo; echo "VERDICT: NG items found. See above."; exit 1
  fi

  # 2. Locate the load-bearing partitions BY NAME (layout-agnostic).
  local ud md misc sup ba
  ud=$(gpt_find userdata) && note "userdata partition (name)" "OK  first=${ud% *} last=${ud#* }" \
                          || bad  "userdata partition" "NG (no 'userdata' in nested GPT)"
  md=$(gpt_find metadata) && note "metadata partition (name)" "OK  first=${md% *} last=${md#* }" \
                          || bad  "metadata partition" "NG (no 'metadata' in nested GPT)"
  sup=$(gpt_find super)   && note "super partition (name)"    "OK  first=${sup% *} last=${sup#* }" \
                          || bad  "super partition" "NG (no 'super' in nested GPT)"
  misc=$(gpt_find misc)   || misc=""    # optional / informational
  ba=$(gpt_find boot_a)   || ba=""

  # 3. boot_a magic "ANDROID!" (only if we found it)
  if [ -n "$ba" ]; then
    h=$(readhex "${ba% *}" 1)
    [ "$(hexat "$h" 0 8)" = "414e44524f494421" ] && note "boot_a 'ANDROID!' magic" "OK" || bad "boot_a magic" "NG"
  fi

  # 4. super: LP metadata geometry magic 'gDla' @ +4096 (super_first + 8 sectors)
  if [ -n "$sup" ]; then
    h=$(readhex $(( ${sup% *} + 8 )) 1)
    [ "$(hexat "$h" 0 4)" = "67446c61" ] && note "super LP geometry magic" "OK" || bad "super LP geometry magic" "NG -> super likely damaged (redeploy)"
  fi

  # 5. userdata state (f2fs superblock magic @ +1024B from partition start)
  if [ -n "$ud" ]; then
    h=$(readhex "${ud% *}" 16)
    f2fs=$(hexat "$h" 1024 4)        # f2fs magic 0xF2F52010 (LE: 1020f5f2)
    if [ "$f2fs" = "1020f5f2" ]; then
      note "userdata state" "PLAIN_F2FS (virgin / pre-first-boot)"
    elif iszero "$h"; then
      note "userdata state" "BLANK (all zero / uninitialized)"
    else
      note "userdata state" "ENCRYPTED/USED (booted; external fsck not possible = expected)"
    fi
  fi

  # 6. metadata state (ext4 magic @1080, state @1082; 1=clean)
  if [ -n "$md" ]; then
    h=$(readhex "${md% *}" 4)
    m=$(hexat "$h" 1080 2)
    s=$(hexat "$h" 1082 2)
    if [ "$m" = "53ef" ]; then
      if [ "$s" = "0100" ]; then
        note "metadata (ext4)" "OK (clean, state=1)"
      else
        bad  "metadata (ext4)" "DIRTY (state=$s != 0100) -> unclean-shutdown trace. fstab 'check' runs e2fsck on next boot, but reinit is advised if boot stalls"
      fi
    elif iszero "$h"; then
      note "metadata" "BLANK (init auto-runs mke2fs via formattable; normal)"
    else
      bad  "metadata" "UNKNOWN data (neither ext4 nor blank) -> likely damaged; reinit advised"
    fi
  fi

  # 7. misc (bootloader-message area; usually zero)
  if [ -n "$misc" ]; then
    h=$(readhex "${misc% *}" 8)
    iszero "$h" && note "misc" "ZERO (normal)" || note "misc (nonzero)" "$(hexat "$h" 0 16) (BCB present? info)"
  fi

  echo
  if [ $fail -eq 0 ]; then
    echo "VERDICT: structure OK. When userdata=ENCRYPTED, the internal f2fs health cannot be judged externally."
    echo "  If a boot stall (no scanout + avc flood) recurs, 'p4-tool.sh reinit' reliably"
    echo "  restores userdata+metadata to the factory state (super and other system partitions stay unchanged)."
  else
    echo "VERDICT: NG items found. See above."
  fi
  exit $fail
}

# ============================================================================
# reinit - reinitialize only userdata + metadata in SD p4 to factory state
#
#   - userdata partition: write a pristine plain-f2fs image to the first ~64MiB
#       (all data extents are within the first 64MiB; older encrypted data beyond
#       that is treated as f2fs free blocks and is effectively wiped once the key
#       is lost = no write needed)
#   - metadata partition: all zero (fstab 'formattable' makes init auto-run
#       mke2fs on the next boot; the old FBE/metadata encryption key is also lost
#       = old userdata is cryptographically erased)
#   - misc: all zero only when --with-misc is given
#
# All offsets/sizes are discovered from the nested GPT at runtime (gpt_find), so
# this adapts to the actual AOSP p4 layout. super/boot/vendor_boot/vbmeta are
# never touched (system side unchanged).
#
# Prerequisites:
#   - p4 must not be in use by DomA / DomD (xl destroy DomA + xl block-detach 1 xvdc done)
#   - pristine material: $PRISTINE_GZ (gzip of the first 64MiB of userdata.pristine.raw)
# ============================================================================
cmd_reinit() {
  set -eo pipefail

  # PRISTINE_GZ is the first 64 MiB of a freshly built (never-booted) AAOS
  # userdata image, gzipped. Produce it once from the build output with:
  #   dd if=<aaos>/userdata.img bs=1M count=64 | gzip -9 > userdata-pristine-head64m.gz
  # Only the head is needed: that is where the pristine data extents live.
  PRISTINE_GZ="${PRISTINE_GZ:?set PRISTINE_GZ=<path to userdata-pristine-head64m.gz>}"
  # Optional integrity pin. Leave unset to skip the check; set it to the md5 of
  # your own artifact to catch a truncated or wrong file.
  PRISTINE_GZ_MD5="${PRISTINE_GZ_MD5:-}"
  UD_WRITE_B=67112960       # 64MiB+4096: covers all pristine data extents

  local DRY=0 WITH_MISC=0
  for a in "$@"; do case "$a" in
    --dry-run) DRY=1;; --with-misc) WITH_MISC=1;;
    *) echo "usage: p4-tool.sh reinit [--dry-run] [--with-misc]"; exit 1;;
  esac; done

  SSH=($SSH_PREFIX ssh "$DOMD")

  echo "== p4-tool reinit =="
  echo "  target : $DOMD $DEV"

  # ---- pre-checks -----------------------------------------------------------
  [ -f "$PRISTINE_GZ" ] || { echo "NG: pristine material missing: $PRISTINE_GZ"; exit 1; }
  if [ -n "$PRISTINE_GZ_MD5" ]; then
    echo "$PRISTINE_GZ_MD5  $PRISTINE_GZ" | md5sum -c - \
      || { echo "NG: pristine md5 mismatch"; exit 1; }
  else
    echo "[pre] PRISTINE_GZ_MD5 unset; skipping the integrity check"
  fi

  echo "[pre] DomD reachability + p4 existence..."
  "${SSH[@]}" "ls $DEV" >/dev/null || { echo "NG: cannot reach $DEV"; exit 1; }

  echo "[pre] check p4 is not in use (xl list / block list)..."
  "${SSH[@]}" "xl list" | sed 's/^/    /'
  if "${SSH[@]}" "xl block-list $DOMD_ID 2>/dev/null" | grep -q xvdc; then
    echo "NG: xvdc (=p4) is still attached to DomD (domid $DOMD_ID). Run xl destroy DomA && xl block-detach $DOMD_ID xvdc first."
    exit 1
  fi

  # ---- discover the p4 layout from the nested GPT (over ssh) ----------------
  echo "[pre] read nested GPT + locate userdata/metadata/misc by name..."
  gpt_load || { echo "NG: p4 nested GPT header invalid ('EFI PART' missing). Aborting (no writes)."; exit 1; }
  local ud md misc
  ud=$(gpt_find userdata) || { echo "NG: no 'userdata' partition in p4 nested GPT. Aborting."; exit 1; }
  md=$(gpt_find metadata) || { echo "NG: no 'metadata' partition in p4 nested GPT. Aborting."; exit 1; }
  local UD_FIRST="${ud% *}" UD_LAST="${ud#* }" MD_FIRST="${md% *}" MD_LAST="${md#* }"
  local MD_CNT=$(( MD_LAST - MD_FIRST + 1 ))
  local UD_CNT=$(( UD_LAST - UD_FIRST + 1 ))
  # Pristine head occupies ceil(UD_WRITE_B / 512) sectors starting at UD_FIRST.
  local UD_WRITE_SECTORS=$(( (UD_WRITE_B + 511) / 512 ))
  local MISC_FIRST="" MISC_CNT=0
  if misc=$(gpt_find misc); then MISC_FIRST="${misc% *}"; MISC_CNT=$(( ${misc#* } - MISC_FIRST + 1 )); fi

  # ---- boundary guard: never write past the userdata partition -------------
  # UD_WRITE_B is a fixed 64MiB+4096B head. If a future AOSP layout makes userdata
  # smaller than that (or not the last extent), a blind write from UD_FIRST would
  # overrun into the nested-GPT backup / a following partition and corrupt it.
  # Assert the write stays within [UD_FIRST .. UD_LAST]; abort (no writes) if not.
  local UD_WRITE_END=$(( UD_FIRST + UD_WRITE_SECTORS - 1 ))
  if [ "$UD_WRITE_END" -gt "$UD_LAST" ]; then
    echo "NG: userdata too small for the pristine head image -> would overrun."
    echo "    userdata : first=$UD_FIRST last=$UD_LAST ($UD_CNT sectors)"
    echo "    pristine : $UD_WRITE_SECTORS sectors (${UD_WRITE_B}B) from $UD_FIRST -> ends at $UD_WRITE_END"
    echo "    Aborting with NO writes ($UD_WRITE_END > userdata last $UD_LAST)."
    exit 1
  fi

  echo "  step1  : userdata @sector $UD_FIRST..$UD_LAST ($UD_CNT sectors) <- pristine f2fs first ${UD_WRITE_B}B / $UD_WRITE_SECTORS sectors ($PRISTINE_GZ)"
  echo "  step2  : metadata @sector $MD_FIRST  <- /dev/zero ($MD_CNT sectors)"
  if [ $WITH_MISC -eq 1 ] && [ -n "$MISC_FIRST" ]; then echo "  step3  : misc @sector $MISC_FIRST <- /dev/zero ($MISC_CNT sectors)"; fi
  echo "  unchanged: super / boot_a,b / vendor_boot_* / vbmeta_* / init_boot_* (system side)"
  echo

  [ $DRY -eq 1 ] && { echo "[dry-run] stop here. No writes performed."; exit 0; }

  # ---- double confirmation --------------------------------------------------
  echo
  echo "!!! This will erase and reinitialize userdata/metadata in $DEV on $DOMD (AAOS /data fully wiped) !!!"
  read -r -p "Continue? (yes): " a1
  [ "$a1" = "yes" ] || { echo "aborted"; exit 1; }
  read -r -p "Type REINIT-USERDATA to confirm: " a2
  [ "$a2" = "REINIT-USERDATA" ] || { echo "aborted"; exit 1; }

  # ---- execute (all seeks/counts in 512B sectors = layout-safe) -------------
  echo "[1/3] userdata <- pristine f2fs (stream gz, gunzip|dd on DomD)..."
  # `head -c` closes the pipe once satisfied, so gzip may exit via SIGPIPE (141).
  # Under `set -eo pipefail` tolerate ONLY that benign case (a real dd failure still
  # propagates: pipefail reports the rightmost non-zero exit).
  # `set -o pipefail` on the REMOTE side so a dd write failure (I/O error) is not
  # masked by tail's exit 0 -- it propagates as the ssh exit code (caught below).
  # count=$UD_WRITE_SECTORS bounds dd to the asserted-safe span even if the gz
  # were unexpectedly larger than UD_WRITE_B (belt-and-suspenders on top of head -c).
  gzip -dc "$PRISTINE_GZ" | head -c "$UD_WRITE_B" | \
    "${SSH[@]}" "set -o pipefail; dd of=$DEV bs=512 seek=$UD_FIRST count=$UD_WRITE_SECTORS conv=notrunc 2>&1 | tail -1" \
    || { rc=$?; [ "$rc" -eq 141 ] || exit "$rc"; }

  echo "[2/3] metadata <- zero ($MD_CNT sectors)..."
  "${SSH[@]}" "set -o pipefail; dd if=/dev/zero of=$DEV bs=512 seek=$MD_FIRST count=$MD_CNT conv=notrunc 2>&1 | tail -1"

  if [ $WITH_MISC -eq 1 ] && [ -n "$MISC_FIRST" ]; then
    echo "[3/3] misc <- zero ($MISC_CNT sectors)..."
    "${SSH[@]}" "set -o pipefail; dd if=/dev/zero of=$DEV bs=512 seek=$MISC_FIRST count=$MISC_CNT conv=notrunc 2>&1 | tail -1"
  else
    echo "[3/3] misc: skip (--with-misc not given or no misc partition)"
  fi

  "${SSH[@]}" "sync"

  # ---- post-verification ----------------------------------------------------
  echo "[verify] userdata f2fs magic / metadata zero..."
  v=$("${SSH[@]}" "dd if=$DEV bs=512 skip=$(( UD_FIRST + 2 )) count=1 2>/dev/null" | od -An -v -tx1 | tr -d ' \n')
  [ "${v:0:8}" = "1020f5f2" ] && echo "    userdata: PLAIN_F2FS OK" || { echo "    userdata: NG (magic=${v:0:8})"; exit 1; }
  m=$("${SSH[@]}" "dd if=$DEV bs=512 skip=$MD_FIRST count=8 2>/dev/null" | od -An -v -tx1 | tr -d ' \n')
  case "$m" in *[1-9a-f]*) echo "    metadata: NG (nonzero)"; exit 1;; *) echo "    metadata: ZERO OK";; esac

  echo
  echo "DONE: the next DomA boot is equivalent to a first boot (metadata key regeneration + /data rebuild)."
  echo "      Duration is comparable to the first boot (measured: scanout ~62s)."
}

case "${1:-}" in
  check)  shift; cmd_check "$@";;
  reinit) shift; cmd_reinit "$@";;
  *) usage;;
esac
