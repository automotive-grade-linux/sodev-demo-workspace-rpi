#!/bin/sh
# SPDX-License-Identifier: MIT
# Drop stale /local/domain/<DomD>/device-model/<domid> nodes before creating DomA.
#
# The toolstack never removes these on domain destruction --
# libxl__destroy_device_model() only cleans the path under LIBXL_TOOLSTACK_DOMID
# (Dom0) -- so entries for long-gone guests accumulate in the driver domain's tree
# and confuse anything that enumerates them (notably vhost_xen's guest_domid watch).
#
# This lived inline in xl-create-doma.service as a single ExecStartPre. It is a
# script now because the awk field reference needed a backslash-escaped `$`, which
# systemd rejects: it logged `Ignoring unknown escape sequences: "alive=..."` on
# every boot, so the sweep was running through an Exec line systemd could not parse
# as written. A file has no systemd escaping rules at all, and can be tested on its
# own.
#
# One `xl list` for the whole sweep: a previous per-domid probe issued 29 `xl`
# invocations and took ~4 s on the boot-time CPU0 that DomD's vCPU shares, delaying
# both guest creations by that much.
set -u

SELF=$(xenstore-read domid 2>/dev/null) || SELF=1
[ -n "$SELF" ] || SELF=1
DM="/local/domain/$SELF/device-model"

# Live domids, one per line. Anything short of a complete, trustworthy listing must
# leave the tree alone: removing the device-model node of a domain that IS alive
# breaks its device model, which is strictly worse than leaving a stale node behind.
# Three guards, because `xl list` can fail in ways that still print usable-looking
# output (it prints the header first, then walks the domain list, so a mid-walk
# libxl error yields a header plus a truncated set of domains on stdout and a
# non-zero exit):
#   1. non-zero exit  -> the walk did not complete
#   2. empty result   -> nothing to compare against
#   3. SELF missing   -> DomD is running this script, so it is by definition alive;
#                        if it is not in the listing the listing is not complete.
# Capture and parse in two steps: in `x=$(cmd | awk ...)` the status in $? is awk's,
# not xl's (POSIX sh has no PIPESTATUS), so a piped form would report rc=0 for every
# xl failure and defeat guard 1 -- verified with a stub that exits 3 after printing a
# truncated list.
raw=$(xl list 2>/dev/null)
rc=$?
alive=$(printf '%s\n' "$raw" | awk 'NR > 1 { print $2 }')
if [ "$rc" -ne 0 ]; then
    echo "doma-devmodel-sweep: xl list failed (rc=$rc); leaving $DM untouched"
    exit 0
fi
if [ -z "$alive" ]; then
    echo "doma-devmodel-sweep: xl list returned nothing; leaving $DM untouched"
    exit 0
fi
if ! echo "$alive" | grep -qx "$SELF"; then
    echo "doma-devmodel-sweep: xl list omits self (domid $SELF) => incomplete; leaving $DM untouched"
    exit 0
fi

for id in $(xenstore-list "$DM" 2>/dev/null); do
    if echo "$alive" | grep -qx "$id"; then
        continue
    fi
    xenstore-rm "$DM/$id" 2>/dev/null &&
        echo "doma-devmodel-sweep: removed stale $DM/$id"
done

exit 0
