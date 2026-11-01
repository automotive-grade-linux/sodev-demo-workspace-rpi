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
#
# Polling cost. Every xenstore-* call here is a fork+exec plus a round trip to the
# Zephyr Dom0's xenstore. Polled every 300 ms with up to three reads per domain, this
# loop (the shell + xenstore-read/-list + usleep) took 9.4 % of DomD's perf -a samples
# across both vCPUs during 1080p60 playback (5.6 % at 720p), about 0.19 of one vCPU,
# and 5.5 min of CPU per 74 min of uptime (RPi4, 2026-10-04) -- CPU taken from the
# DomA device model. So:
#   * a domain whose tty has been seeded is not read again on the frontend side
#     (the tty is never cleared while the domain lives; a new domid starts afresh);
#   * the loop polls every 300 ms only for FAST_S seconds after something happened
#     (a new domid, or a state this script wrote), and every SLOW_S otherwise.
#     Both waits it serves have >= 10 s timeouts in libxl, so a 2 s poll still
#     answers a destroy's Closing(5) and a create's first appearance in time; the
#     create then gets the 300 ms cadence for its tty and state waits.
BE=${1:-1}
FAST_S=60
SLOW_S=2
seen=""
seeded=""
fast_until=0

# $now = uptime in whole seconds, without a fork (read is a shell builtin)
now_s() { read -r up _ < /proc/uptime; now=${up%.*}; }

while true; do
    for d in $(xenstore-list /local/domain 2>/dev/null); do
        [ "$d" = "0" ] && continue
        [ "$d" = "$BE" ] && continue

        # [verified on hardware] xenconsoled's @introduceDomain watch does not
        # fire on the Zephyr xenstore, so a pre-started xenconsoled never picks
        # up new guests (its startup enum_domains only sees domains that already
        # exist). Restart it once per newly seen domid: enum_domains then finds
        # the guest and starts draining its PV console ring within ~2.3 s of
        # creation (up to SLOW_S to notice the domid, plus the 0.3 s gap; it was
        # ~1 s with the old 300 ms poll) - fast enough that the AAOS init
        # device-wait does not time out into recovery (a drain that started ~90s
        # late still lost the race), and the 4KiB ring never wedges the guest's
        # console writes. The domid appears in xenstore at libxl__domain_make,
        # well before the guest is unpaused, so the guest has written nothing yet.
        case " $seen " in *" $d "*) ;; *)
            seen="$seen $d"
            now_s; fast_until=$(( now + FAST_S ))
            # xenconsoled has no signal-based re-enumeration on the Zephyr xenstore,
            # so kill+restart it once per newly-introduced domain to pick up its
            # console (~0.3s gap). verified on hardware. A guest already running
            # (DomA when DomU is created) keeps its log: what it writes in the gap
            # waits in its ring, whose indices the new xenconsoled resumes from.
            # Output the old one held for a pty nobody read goes with it. Revisit
            # if the xenstore ever gains a working @introduceDomain watch.
            busybox kill $(pgrep xenconsoled) 2>/dev/null
            sleep 0.3
            /usr/sbin/xenconsoled --log=guest --log-dir=/var/log/xen/console 2>/dev/null
        ;; esac

        case " $seeded " in *" $d "*) ;; *)
            fe="/local/domain/$d/console"
            if xenstore-read "$fe/ring-ref" >/dev/null 2>&1; then
                cur=$(xenstore-read "$fe/tty" 2>/dev/null)
                if [ -z "$cur" ]; then
                    xenstore-write "$fe/tty" "/dev/pts/seeder$d" 2>/dev/null &&
                        seeded="$seeded $d"
                    now_s; fast_until=$(( now + FAST_S ))
                else
                    seeded="$seeded $d"
                fi
            fi
        ;; esac

        be="/local/domain/$BE/backend/console/$d/0"
        st=$(xenstore-read "$be/state" 2>/dev/null)
        if [ "$st" = "1" ]; then
            xenstore-write "$be/state" "2" 2>/dev/null
            now_s; fast_until=$(( now + FAST_S ))
        elif [ "$st" = "5" ]; then
            xenstore-write "$be/state" "6" 2>/dev/null
            now_s; fast_until=$(( now + FAST_S ))
        fi
    done
    now_s
    if [ "$now" -lt "$fast_until" ]; then
        usleep 300000 2>/dev/null || sleep 1
    else
        sleep "$SLOW_S"
    fi
done
