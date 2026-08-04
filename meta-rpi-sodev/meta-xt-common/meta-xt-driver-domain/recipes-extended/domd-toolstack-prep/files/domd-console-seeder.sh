#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# DomD console seeder (HW-verified)
# ------------------------------------------------------------------
# The Zephyr Dom0 has no xenconsoled-equivalent, and DomD's own xenconsoled
# does not serve guest consoles in this topology, so `xl create` would time
# out on its two console waits. This seeder satisfies exactly those waits
# without providing real console I/O (harmless: the demo guests use
# virtio-console / hvc0 via qemu, not the PV console):
#   (1) frontend /local/domain/<id>/console/tty      -> non-empty
#       (libxl_create.c console_xswait, 10s timeout)
#   (2) backend  /local/domain/<BE>/backend/console/<id>/0/state
#       Initialising(1) -> InitWait(2)   satisfies libxl__wait_device_connection
#       Closing(5)      -> Closed(6)     satisfies destroy-side device removal
#       Other states are never touched (writing 2 over Closing wedges destroy).
BE=${1:-1}
seen=""

while true; do
    for d in $(xenstore-list /local/domain 2>/dev/null); do
        [ "$d" = "0" ] && continue
        [ "$d" = "$BE" ] && continue

        # [verified on hardware] xenconsoled's @introduceDomain watch does not
        # fire on the Zephyr xenstore, so a pre-started xenconsoled never picks
        # up new guests (its startup enum_domains only sees domains that already
        # exist). Restart it once per newly seen domid: enum_domains then finds
        # the guest and starts draining its PV console ring within ~1s of
        # creation - fast enough that the AAOS init device-wait does not time
        # out into recovery (a drain that started ~90s late still lost the
        # race), and the 4KiB ring never wedges the guest's console writes.
        case " $seen " in *" $d "*) ;; *)
            seen="$seen $d"
            # xenconsoled has no signal-based re-enumeration on the Zephyr xenstore,
            # so kill+restart it once per newly-introduced domain to pick up its
            # console (~0.3s gap). verified on hardware; the gap sits between two
            # already-seeded domains (not a live console), so it is safe. Revisit if
            # the xenstore ever gains a working @introduceDomain watch.
            busybox kill $(pgrep xenconsoled) 2>/dev/null
            sleep 0.3
            /usr/sbin/xenconsoled --log=guest --log-dir=/var/log/xen/console 2>/dev/null
        ;; esac

        fe="/local/domain/$d/console"
        if xenstore-read "$fe/ring-ref" >/dev/null 2>&1; then
            cur=$(xenstore-read "$fe/tty" 2>/dev/null)
            [ -z "$cur" ] && xenstore-write "$fe/tty" "/dev/pts/seeder$d" 2>/dev/null
        fi

        be="/local/domain/$BE/backend/console/$d/0"
        st=$(xenstore-read "$be/state" 2>/dev/null)
        if [ "$st" = "1" ]; then
            xenstore-write "$be/state" "2" 2>/dev/null
        elif [ "$st" = "5" ]; then
            xenstore-write "$be/state" "6" 2>/dev/null
        fi
    done
    usleep 300000 2>/dev/null || sleep 1
done
