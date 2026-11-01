#!/vendor/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# /vendor/bin/doma-wifi-relay -- the DomA half of the shadow-AP Wi-Fi relay.
#
# WHAT IT CLOSES
# doma-shadow-ap beacons whatever is in /data/vendor/wifi/shadow/aps.conf, and the
# DomD-side agent (domd_wifi_agent.py) already publishes the real scan results and
# already performs the real association on request. Nothing on this side consumed
# either half, so the AP list was static and the passphrase the user typed never
# reached DomD. This daemon is that consumer.
#
# WHY BOTH HALVES ARE ONE PROGRAM, NOT TWO
# The `aps` message the agent sends carries {ssid, bssid, sec, freq, dbm} and NO
# psk (see the PROTOCOL block of domd_wifi_agent.py) -- a scan cannot reveal a
# PSK. So "write aps.conf from the real scan" on its own would leave hostapd
# with no passphrase for the new SSIDs, and the first attempt against one would
# fail the 4-way handshake locally. That failure is NOT retried:
# config_wifiDisableReasonByWrongPasswordThreshold is 1 and
# config_wifiDisableReasonByWrongPasswordDurationMs is -1 in
# ServiceWifiResources/res/values/config.xml, so the network is disabled permanently
# (WifiConfiguration.NetworkSelectionStatus.DISABLED_BY_WRONG_PASSWORD). Publishing a
# list is therefore only safe together with a way to learn the PSK, which is what the
# companion app supplies over $REQ below.
#
# THE TWO INPUTS
#   $CHAN  /dev/hvc4         virtio-serial to DomD. Newline-delimited JSON both ways.
#                            The INBOUND format is json.dumps() output, so it has a
#                            space after every colon -- written out in full here because
#                            a pattern for the compact form never matches it:
#                            in : {"t": "aps", "v": [{"ssid": "X", "bssid": ..,
#                                  "sec": "wpa2", ..}, ..]}
#                                 ("sec" "open" makes an open row; every other
#                                  value -- wpa, wpa2, sae, sae-psk -- a WPA2 one)
#                                 {"t": "state", "ssid": "X", "state": "COMPLETED", "ip": ..,
#                                  "id": ..}
#                                 {"t": "state", "ssid": "X", "state": "FAILED", "error": ..,
#                                  "id": ..}
#                                 {"t": "state", "ssid": "X", "state": "LOST", "error": ..}
#                                 {"t": "state", "ssid": "X", "state": "BACK", "ip": ..}
#                                 (COMPLETED and FAILED answer a connect, with its id;
#                                  LOST and BACK come unasked -- see handle_state)
#                            out: {"t":"connect","id":"N","ssid":"X","psk":"Y"}   (ours,
#                                  compact; the id, see PENDING)
#   $REQ   .../relay.req     one line per request from DomaWifiRelay (the priv-app):
#                                 psk<TAB><SSID><TAB><PSK>
#                            The app has NETWORK_SETTINGS + READ_WIFI_CREDENTIAL and
#                            reads the PSK with WifiManager.getPrivilegedConfiguredNetworks().
#
# WHY A REQUEST FILE AND NOT A SOCKET
# mksh cannot select() over two descriptors. `read -t` on $CHAN plus a stat of $REQ
# polls both with one loop and no helper process. $REQ lives in $CONF_DIR/req
# (the owner, mode and label of that directory are explained where REQ_DIR is set).
#
# IT FOLLOWS THE SETTINGS WI-FI TOGGLE. init.xenvm-hwsim.rc starts it at
# sys.boot_completed while persist.vendor.doma.wifi_relay is unset or "true", and while
# the toggle is off it asks DomD for nothing -- see sta_is_up().
set -u
# /vendor's tools only. init's default PATH puts /system/bin first, and this runs in a
# vendor domain, which may not execute /system's programs (a neverallow), so a bare
# `ls` or `brctl` would resolve to one it cannot run. DOMA_PATH is for the PC tests.
PATH=${DOMA_PATH:-/vendor/bin:/vendor/xbin}
export PATH

TAG=doma-wifi-relay
# THE TRAILING `:` IS MANDATORY. Without it, LOG()'S EXIT STATUS IS THAT OF
#   /vendor/bin/log, which turns the `A && log ... || die ...` idiom into "A
#   succeeded, yet die fired" (log normally succeeds, but if it fails you get a bogus
#   FATAL).
log() { echo "$TAG: $*"; /vendor/bin/log -t "$TAG" "$*" 2>/dev/null; :; }

# THE PATHS CAN BE OVERRIDDEN FROM THE ENVIRONMENT, so the script also runs on a
#   PC against a scratch directory. Nothing sets them on the device.
CONF_DIR=${CONF_DIR:-/data/vendor/wifi/shadow}
APS=${APS:-$CONF_DIR/aps.conf}
CONF=${CONF:-$CONF_DIR/hostapd.conf}
# The request drop-box. A SUBDIRECTORY, not a file in $CONF_DIR, because of DAC:
# $CONF_DIR is wifi:wifi 0771 (init.xenvm-hwsim.rc creates it and doma-shadow-ap
# keeps the mode), and the app that writes requests runs as uid/gid system, so
# it could not create a file there. This
# directory is created wifi:system 0770 by init.xenvm-hwsim.rc, which lets the app
# create and replace the request file while
# keeping the passphrase out of reach of everything else. Its label is
# doma_wifi_req_file (file_contexts), not $CONF_DIR's hostapd_data_file, for the
# same reason: the app is given this directory and not hostapd's files.
# The files in it cross uid wifi and uid system both ways, so each is 0640 and its
# group is the other side's: the app makes $REQ group system (the relay is in that
# group), and this script makes $STATE_FILE group system (uid wifi is a member, so
# chgrp needs no capability).
REQ_DIR=${REQ_DIR:-$CONF_DIR/req}
REQ=${REQ:-$REQ_DIR/relay.req}
# For DomaWifiRelay: one line "<kind><TAB><seq><TAB><SSID>", rewritten when this
#   script starts and each time DomD reports it joined, lost or could not join an
#   SSID (see state_publish).
STATE_FILE=${STATE_FILE:-$REQ_DIR/relay.state}
# $CHAN is the hvc node, not /dev/vport2p4. The Wi-Fi channel in doma.cfg is
#   declared as `-device virtconsole,chardev=virts_chardev5`, i.e. AS A CONSOLE
#   PORT. virtio_console only assigns an hvc to ports the host declared
#   VIRTIO_CONSOLE_CONSOLE_PORT, and the generic /dev/vportXpY node of a port
#   that got an hvc CANNOT BE OPENED (port_fops_open returns -ENXIO): init then
#   restarts this script every 10 s, and it dies before it can log anything.
#
#   Why this number (same as the corresponding comment in doma.cfg): hvc_alloc()
#   takes the lowest free vtermnos[] slot, and Xen's PV console has taken 0, so
#   the five virtconsoles land ON hvc1..hvc5 IN PORT ORDER.
#     virts1 -> hvc1   virts2 -> hvc2   virts4 -> hvc3
#     virts5 -> hvc4  <- Wi-Fi (this script)
#     virts6 -> hvc5
#   (virts3 is a virtserialport, so it takes no hvc and stays /dev/vport2p2.)
#   Measured 2026-09-07: on /dev/hvc4 the JSON from DomD's agent arrives, and a
#   connect to <SSID-A> reached COMPLETED on the DomD side.
CHAN=${CHAN:-/dev/hvc4}
AP_IF=${AP_IF:-wlan2}
BR=${BR:-br-shadow}
# The two things used to detect a station. See the stations_present() comment.
STA_IF=${STA_IF:-wlan0}
# NETDEV_DIR / STA_CARRIER / STA_FLAGS / STA_UPCOUNT / IW can be overridden like
#   the paths above, so stations_present(), sta_is_up() and mirror_station() also
#   run without hardware. On
#   the device the defaults apply.
NETDEV_DIR=${NETDEV_DIR:-/sys/class/net}
STA_CARRIER=${STA_CARRIER:-$NETDEV_DIR/$STA_IF/carrier}
STA_FLAGS=${STA_FLAGS:-$NETDEV_DIR/$STA_IF/flags}
STA_UPCOUNT=${STA_UPCOUNT:-$NETDEV_DIR/$STA_IF/carrier_up_count}
IW=${IW:-/vendor/bin/iw}
# Passphrase a newly discovered SECURED SSID gets until the user types the real
# one. An SSID DomD publishes with "sec" "open" gets an EMPTY PSK instead, i.e. an
# open shadow BSS (wpa=0); see handle_aps.
#
# A SECURED SSID MUST GET THIS, NOT AN EMPTY PSK. An open BSS optimises away the
# exact event the password path depends on: the AAOS Wi-Fi screen shows no lock
# and NEVER PROMPTS FOR A PASSWORD, the association succeeds locally,
# DISABLED_BY_WRONG_PASSWORD never fires, DomaWifiRelay never learns a
# passphrase, and the connect the mirror forwards carries none, so DomD cannot
# join the real AP -- a permanent "connected, no internet" dead end with no way
# out. The failure is load-bearing: the BSS must be WPA2 so the UI prompts, the
# handshake fails against this placeholder, and the app can then read the typed
# value and repair. Any 8..63 character string works; it is never meant to match
# anything. WPA3 APs ("sae", "sae-psk") are beaconed as WPA2 as well: the local
# handshake only collects the passphrase, and DomD's agent picks the real key
# management from its own scan.
#
# CONSEQUENCE TO EXPECT ON SCREEN: a secured SSID the relay discovered but nobody
# has typed a password for yet shows a lock icon, and the first attempt fails for
# a few seconds before the repair completes. An open one joins at once; nothing
# fails locally, so the app never sees it, and mirror_station forwards its
# connect (with an empty PSK) on every association instead.
PLACEHOLDER_PSK=${PLACEHOLDER_PSK:-doma-relay-unprovisioned-0000}
# The SSID of the one BSS write_hostapd_conf emits when $APS has no usable row.
#   hostapd needs a primary BSS with an SSID to start, and the shipped seed has no
#   row, so on a first boot -- or with nothing in range -- there is nothing else to
#   beacon. It is HIDDEN (ignore_broadcast_ssid=1: the beacon carries an empty SSID
#   and hostapd answers only a probe that names it), so the Wi-Fi screen never lists
#   it, and WPA2 with $PLACEHOLDER_PSK, so only something that knows both published
#   values can join it -- and the medium is mac80211_hwsim's, inside this guest. A
#   station that does join it is not one stations_present() protects. It is never
#   written into $APS. doma-shadow-ap.sh carries the same value.
IDLE_SSID=${IDLE_SSID:-doma-shadow-idle}
# What hostapd is beaconing: a copy of $CONF taken when hostapd last (re)started on
#   it -- by doma-shadow-ap at boot, by restart_hostapd() here. $CONF itself can be
#   ahead of it while a restart waits for a station to leave, so mirror_station()
#   reads this one, and a $CONF that comes back to it cancels the pending restart.
LIVE=${LIVE:-$CONF.live}
# Passphrases the user has typed, kept apart from $APS: "<SSID>TAB<PSK>" per line,
#   most recent last, at most LEARNED_MAX rows. A row leaves $APS when its AP goes
#   out of range (handle_aps), and without this its PSK went with it, so the AP came
#   back with the placeholder and the saved network failed the local handshake.
#   A passphrase typed on screen is recorded here once DomD reports COMPLETED for its
#   SSID (handle_state; until then handle_psk keeps it in PENDING_PSK), so one that
#   DomD's AP rejects is never kept. handle_aps() records a real PSK of a row it drops
#   and takes the PSK from here when the SSID is published again. wifi 0600, unlike
#   $APS and $CONF, which hostapd and the wifi group read: only this script reads
#   it. Never logged.
LEARNED=${LEARNED:-$CONF_DIR/learned.conf}
LEARNED_MAX=${LEARNED_MAX:-64}
# At most this many rows in $APS, i.e. shadow BSSes and SSIDs on the Wi-Fi screen.
#   It is also how many entries of a publication are read (DomD's agent sends its
#   --top, 20). See handle_aps for which rows win when there are more.
APS_MAX=${APS_MAX:-20}
# A complete line longer than this is dropped unread: the parsers below are in the
#   shell and slow down quadratically, and a 20-entry publication is ~3 KiB at most.
LINE_MAX=${LINE_MAX:-16384}

# --- boot-time mirror --------------------------------------------------------
# After a reboot DomD's real association is gone (its wpa_supplicant starts
# INACTIVE) while DomA's station re-associates with the shadow AP on its own,
# because the saved PSK is already in aps.conf and the framework auto-connects.
# Nothing in the UI path fires -- the LOCAL handshake succeeds -- so no
# connect() would be forwarded and DomA would sit on a Wi-Fi with no upstream.
#
# So mirror_station() (main loop, every tick) reads the SSID the station is
# associated with (`iw dev wlan0 link`, decoded by iw_ssid()) and forwards
# connect(ssid, psk) to DomD, with the PSK of that SSID's BSS in $LIVE (what hostapd
# beacons, so what the station joined). It never sends the same (boot, ssid, psk) as
# the connect sent last: the marker file holds that last one only, so going B, A, B
# sends B again, which is right -- DomD went to A in between. The marker lives
# in $CONF_DIR (persistent) but carries the kernel boot_id, so a daemon restart does not
# re-forward and a reboot does. handle_psk() writes the same marker after its own
# forward, so the UI repair path and the mirror never send the same connect twice. A
# placeholder PSK is never forwarded, and neither is an SSID $LIVE has no BSS for.
# AN OPEN ROW IS FORWARDED ONCE PER ASSOCIATION instead, because it is the only
# thing that ever tells DomD to join an open AP: the app has nothing to repair there
# (see PLACEHOLDER_PSK), so a user who taps the same open SSID again after DomD went
# elsewhere needs the mirror to send it again. Its marker adds the station's
# carrier_up_count to the boot_id -- see mirror_station.
# Kill switch:  setprop persist.vendor.doma.wifi_relay_mirror false
MIRROR_MARK=${MIRROR_MARK:-$CONF_DIR/mirror.mark}
BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOTID" ] || BOOTID=noboot-$$
STA_LAST_SSID=""
# carrier_up_count when STA_LAST_SSID was taken, and a per-process association count
# used in its place when the file cannot be read. See mirror_station.
STA_LAST_UPC=""
MIRROR_SEQ=0
# 1 when hostapd.conf has changes that hostapd has not picked up yet, because a
# station was associated at the time. See flush_pending_restart().
RESTART_PENDING=0
# The shipped seed. Why handle_aps consults it: see the seed_psk_of() comment.
SEED=${SEED:-/vendor/etc/doma-shadow-aps.conf}
# Whether an incoming aps message may restart hostapd. THE DEFAULT IS auto.
#   auto (unset / default): restart only when stations_present() is false. While a
#     station is associated, do not restart; set RESTART_PENDING instead and apply it
#     on the first tick after it leaves (flush_pending_restart), so an
#     unattended restart does not drop the user's connection.
#   false: never touch hostapd on aps ($APS only), unless BOUNCE_MIN_S (below)
#     asks for a rate-limited restart. A new SSID starts beaconing at
#     the next boot (regenerated by doma-shadow-ap) or on a PSK repair. ONE
#     EXCEPTION: while hostapd beacons only the hidden idle BSS (a first boot, or
#     nothing was in range), the conf is written and hostapd restarted anyway --
#     there is no AP anyone uses to disrupt, and otherwise the screen would stay
#     empty until the next boot. A restart an earlier publication deferred is
#     dropped, since the conf it would apply is no longer current.
#   true : restart even with a station present. THIS CAN DROP DomA'S ONLY WAY IN, so
#     use it only while sitting in front of the screen.
#
# THE VALUE IS getprop'd BY handle_aps FOR EVERY MESSAGE, so a `setprop` takes
#   effect from the next publication without restarting the relay. The
#   environment variable BOUNCE_ON_APS takes precedence if set.
# (A PSK repair -- the restart after the user types a passphrase on screen -- always
#  happens, independently of this flag.)
BOUNCE_ON_APS=${BOUNCE_ON_APS:-}
# With BOUNCE_ON_APS false, the least number of seconds between two hostapd restarts
#   for AP-list changes; 0 or unset keeps false as described above. With it set, an
#   aps message restarts hostapd as auto does (only while no station is associated),
#   but at most once per this many seconds: a change that comes sooner is deferred
#   (RESTART_PENDING) and flush_pending_restart applies it once the time has passed
#   and the station has left. So a new SSID reaches the screen within this time, and
#   the restarts that took 17% of DomA's CPU on the RPi4 (2026-10-11) are cut to one
#   per interval. getprop'd per message, like the flag:
#   persist.vendor.doma.wifi_relay_bounce_min_s; the environment variable
#   BOUNCE_MIN_S takes precedence if set. Measured with mksh's $SECONDS.
BOUNCE_MIN_S=${BOUNCE_MIN_S:-}
# $SECONDS at the last hostapd restart for an AP-list change, empty before the
#   first (a restart for a passphrase or for DomD's state does not count, so it
#   does not hold the list back); and the interval a deferred restart is waiting
#   for (0: none).
LAST_BOUNCE=""
BOUNCE_WAIT=0
RESTART_FOR_LIST=0  # 1 while the deferred restart is one for a list change
# The connects sent that DomD has not answered yet, "<id>TAB<SSID>TAB<since>TAB<kind>
#   TAB<PSK>" per line, newline-framed, oldest first. Each connect carries an id that
#   DomD's answer (COMPLETED or FAILED) carries back, so an answer is matched to its
#   own connect: counting answers instead goes wrong whenever one is lost (a write
#   that failed, the agent restarting mid-join, this daemon restarting). The id is
#   "<pid>-<n>", so an answer to a connect from before a restart of this daemon
#   matches nothing. kind is "u" for a passphrase typed on screen (handle_psk) and
#   "m" for the row's own PSK (mirror_station). A typed one is put in $APS at once
#   (the local handshake needs it), but into $LEARNED only on DomD's COMPLETED for it
#   (see handle_state). DomD handles the connects one at a time, in order, so an
#   answer also means every connect sent before it has been answered: those entries
#   go. An entry no answer has come for in PENDING_TTL_S (300 s) goes as well.
PENDING=""          # newline-framed; set once NL is defined below
PENDING_SEQ=0
# The agent takes up to about 75 s per connect (a 30 s join, a DHCP of up to ~18 s, the
#   lease drop and a scan of up to 15 s), so 300 s covers four queued ones.
PENDING_TTL_S=${PENDING_TTL_S:-300}
case "$PENDING_TTL_S" in ''|*[!0-9]*) PENDING_TTL_S=300;; esac
# The last passphrase DomD rejected with WRONG_KEY, and when: the app asks again with
#   the same one once the framework has joined the shadow BSS with it, and taking it
#   again would restart hostapd and make DomD try for 30 s, round after round.
#   Dropped for FAIL_HOLD_S seconds, or until DomD joins the SSID.
REJECT_SSID=""
REJECT_PSK=""
REJECT_T=0
# SSIDs DomD failed to join for a reason other than the key, or lost, while DomA's
#   station was on them, "<SSID>TAB<$SECONDS>" per line: handle_state removed their
#   rows, and handle_aps does not add one back for FAIL_HOLD_S seconds, or until it
#   leaves DomD's scans and returns to them (FAIL_HOLDS_GONE), or for a lost one until
#   DomD reports it BACK. Without this the next publication brings it
#   straight back -- DomD's scans keep reporting a vanished AP for a while -- with a
#   hostapd restart, and the screen lists a network that is gone.
FAIL_HOLD_S=${FAIL_HOLD_S:-300}
case "$FAIL_HOLD_S" in ''|*[!0-9]*) FAIL_HOLD_S=300;; esac
FAIL_HOLDS=""       # newline-framed; set once NL is defined below
# The held SSIDs the last publication left out, newline-framed: one that a later
#   publication names again is back in DomD's scans after its stale BSS expired there,
#   so the AP has returned and the hold goes (holds_seen) -- also when DomD has moved
#   to another network meanwhile and no BACK will come.
FAIL_HOLDS_GONE=""  # set once NL is defined below
# 1 when handle_state has changed $APS and hostapd must restart although a station is
#   associated, but doma_shadow_ap was still bringing the shadow AP up (see the main
#   loop).
STATE_RESTART=0
TAB="$(printf '\t')"
NL='
'
PENDING=$NL
FAIL_HOLDS=$NL
FAIL_HOLDS_GONE=$NL
# Drop hysteresis for handle_aps. DomD's scans jitter by one AP (+1 -1) on most
#   publications, and each change rewrote aps.conf and hostapd.conf (~0.6 CPU-s on this guest
#   every 20 s, which costs 1080p60 video ~40 frames a clip). With APS_HYST=1 (the default) a
#   row that a publication does not mention is kept until it has been missing from three in
#   a row (~60 s); APS_HYST=0 drops it at once, as before. APS_MISS1/2: the SSIDs missing
#   from the last one / two publications, newline-framed.
#   The same three-in-a-row rule holds for a row's SECURITY (see handle_aps): one SSID
#   with an open and a secured BSS is published with whichever is strongest, and
#   without this the row flipped, and hostapd restarted, on every publication.
#   APS_FLIP1/2: the SSIDs published with the other security in the last one / two.
APS_HYST=${APS_HYST:-1}
APS_MISS1=$NL
APS_MISS2=$NL
APS_FLIP1=$NL
APS_FLIP2=$NL

# NOT IN THE virt_wifi FALLBACK. With persist.vendor.doma.shadow_ap not true,
# doma-shadow-ap hands wlan0 to virt_wifi and creates no shadow AP (no wlan2, no
# br-shadow), so there is nothing to relay: a publication would only crash-loop hostapd,
# and the mirror would forward the VirtWifi association to DomD. Idle rather than exit,
# since init restarts a service that exits. Same property and default as doma-shadow-ap.
if [ "$(getprop persist.vendor.doma.shadow_ap true)" != "true" ]; then
    log "persist.vendor.doma.shadow_ap is not true (virt_wifi fallback) -- nothing to relay; idling"
    while :; do sleep 3600; done
fi

[ -d "$CONF_DIR" ] || { log "FATAL: $CONF_DIR missing -- start vendor.doma_shadow_ap first"; exit 1; }
[ -e "$CHAN" ]     || { log "FATAL: $CHAN missing -- is the doma.cfg virtio-serial chardev there?"; exit 1; }

# $REQ_DIR: init.xenvm-hwsim.rc creates it wifi:system 0770 in `on post-fs-data`.
# No $LIVE yet (the first start after an upgrade): hostapd runs on $CONF, which
# doma-shadow-ap wrote just before starting it.
if [ ! -e "$LIVE" ] && [ -e "$CONF" ]; then
    cp "$CONF" "$LIVE" 2>/dev/null && chmod 0600 "$LIVE" 2>/dev/null
fi

# --- helpers -------------------------------------------------------------------------

# psk_of <ssid> -- the PSK currently recorded for an SSID: empty for an open row;
# returns 1 when $APS has no row for it.
#
# THE _k/_v NAMES ARE LOAD-BEARING. Shell functions share one namespace, so a
# `while read -r s p` in here would overwrite a caller's $s: a caller that loops
# over SSIDs and calls this on each would see every SSID after the first come
# back EMPTY (reproduced on the PC). Every variable a helper touches here is
# _-prefixed for that reason.
psk_of() {
    # `|| [ -n "$_k" ]`: aps.conf may be hand-edited (see the seed's header), so a
    #   last line without a newline counts, as in both hostapd.conf generators
    while IFS="$TAB" read -r _k _v || [ -n "${_k:-}" ]; do
        case "$_k" in ''|'#'*) continue;; esac
        [ "$_k" = "$1" ] && { print -nr -- "${_v:-}"; return 0; }
    done < "$APS"
    return 1
}

# learned_psk_of <ssid> -- the passphrase $LEARNED holds for it; returns 1 if none.
learned_psk_of() {
    [ -s "$LEARNED" ] || return 1
    _lr=1
    while IFS="$TAB" read -r _lk _lv || [ -n "${_lk:-}" ]; do
        # the last row for the SSID wins (learned_put keeps one, but be safe)
        [ "$_lk" = "$1" ] && [ -n "${_lv:-}" ] && { _lp=$_lv; _lr=0; }
    done < "$LEARNED"
    [ "$_lr" = 0 ] && print -nr -- "$_lp"
    return $_lr
}

# learned_put <ssid> <psk> -- record a passphrase in $LEARNED: replaces the SSID's row,
# appends it last, keeps the newest LEARNED_MAX. Called on a repair or when a row
# with a real PSK leaves $APS, never per tick. Values through ENVIRON, as in
# handle_psk, so a backslash survives.
learned_put() {
    case "$2" in ''|"$PLACEHOLDER_PSK") return 0;; esac
    [ -e "$LEARNED" ] || ( umask 077; : > "$LEARNED" ) 2>/dev/null
    ( umask 077
      RELAY_SSID=$1 RELAY_PSK=$2 RELAY_MAX=$LEARNED_MAX awk -F'\t' '
        BEGIN { OFS="\t"; s=ENVIRON["RELAY_SSID"]; p=ENVIRON["RELAY_PSK"]; m=ENVIRON["RELAY_MAX"]+0 }
        NF && $1 != s { k[n++]=$0 }
        END { k[n++]=s OFS p; for (i = (n > m ? n - m : 0); i < n; i++) print k[i] }' \
        "$LEARNED" > "$LEARNED.new" ) 2>/dev/null \
        || { rm -f "$LEARNED.new"; log "WARNING: cannot write $LEARNED.new"; return 0; }
    chmod 0600 "$LEARNED.new" 2>/dev/null
    mv -f "$LEARNED.new" "$LEARNED" 2>/dev/null || { rm -f "$LEARNED.new"; log "WARNING: cannot replace $LEARNED"; }
}

# learned_del <ssid> -- forget the passphrase $LEARNED holds for it (DomD's AP
# rejected it). Same writing as learned_put.
learned_del() {
    [ -s "$LEARNED" ] || return 0
    ( umask 077
      RELAY_SSID=$1 awk -F'\t' 'BEGIN { s=ENVIRON["RELAY_SSID"] } NF && $1 != s' \
        "$LEARNED" > "$LEARNED.new" ) 2>/dev/null \
        || { rm -f "$LEARNED.new"; log "WARNING: cannot write $LEARNED.new"; return 0; }
    chmod 0600 "$LEARNED.new" 2>/dev/null
    mv -f "$LEARNED.new" "$LEARNED" 2>/dev/null || { rm -f "$LEARNED.new"; log "WARNING: cannot replace $LEARNED"; }
}

# live_psk_of <ssid> -- what the BSS hostapd beacons for this SSID ($LIVE) takes:
# prints the passphrase or raw PSK, or nothing for an open BSS; returns 1 when no
# BSS has the SSID. Builtin only: it runs once per association.
live_psk_of() {
    [ -r "$LIVE" ] || return 1
    _in=0; _lp=""; _lr=1
    while IFS= read -r _ll || [ -n "${_ll:-}" ]; do
        case "$_ll" in
            ssid=*)  [ "$_in" = 1 ] && break
                     [ "${_ll#ssid=}" = "$1" ] && { _in=1; _lr=0; };;
            bss=*)   [ "$_in" = 1 ] && break;;
            wpa_passphrase=*) [ "$_in" = 1 ] && _lp=${_ll#wpa_passphrase=};;
            wpa_psk=*)        [ "$_in" = 1 ] && _lp=${_ll#wpa_psk=};;
        esac
    done < "$LIVE"
    [ "$_lr" = 0 ] && print -nr -- "$_lp"
    return $_lr
}

# conf_is_idle <file> -- is it a conf whose (only) BSS is the hidden idle one? The idle
# BSS is only ever written alone, so the first ssid= line decides.
conf_is_idle() {
    [ -r "$1" ] || return 1
    while IFS= read -r _cl; do
        case "$_cl" in ssid=*) [ "${_cl#ssid=}" = "$IDLE_SSID" ]; return;; esac
    done < "$1"
    return 1
}

# seed_psk_of <ssid> -- the PSK the shipped seed holds for that SSID; returns 1
# if there is none.
#
# WHY handle_aps CONSULTS THE SEED. A publication that names an SSID $APS lacks
# gets the seed's PSK for it rather than $PLACEHOLDER_PSK, so a lost $APS cannot
# turn a seeded AP -- possibly the one DomA's own station is using -- into a
# placeholder the moment hostapd restarts. doma-shadow-ap's merge brings seed
# rows back at boot, but it leaves an existing row alone, placeholder or not, so
# it cannot do this. The committed seed carries no row, and a build's seed rows
# hold the placeholder or an empty PSK (see its header), which count as "no seed
# PSK" (seed_real_psk_of): what the seed then protects is the row being there.
seed_psk_of() {
    [ -s "$SEED" ] || return 1
    # `|| [ -n "$_sk" ]`: the seed is hand-edited, so do not drop the last line when
    # it has no trailing newline
    while IFS="$TAB" read -r _sk _sv || [ -n "${_sk:-}" ]; do
        case "$_sk" in ''|'#'*) continue;; esac
        [ "$_sk" = "$1" ] && { print -nr -- "${_sv:-}"; return 0; }
    done < "$SEED"
    return 1
}

# json_esc <string> -- escape a value for embedding in the JSON sent to DomD.
#
# NEEDED, NOT COSMETIC. A WPA passphrase is any 8..63 printable ASCII
# characters, so it may legally contain \ or ". The connect message is parsed on
# the far side by json.loads() (parse_line() in domd_wifi_agent.py), which
# rejects or mis-decodes an unescaped one, and the failure would look like "the
# password is wrong" rather than "the message was malformed". Only \ and " need
# handling: control characters cannot appear in a passphrase, and DomD's agent
# publishes no SSID that has one. The \ substitution must run FIRST or it would
# double the backslashes " introduces.
json_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# write_hostapd_conf -- regenerate $CONF from $APS.
#
# THIS IS A SECOND COPY of the generation loop in step 3 of doma-shadow-ap.sh,
# and the two MUST be kept in sync: both skip the same rows (ssid_hostapd_safe,
# psk_valid), write the same stanzas, and write the same hidden idle BSS when no
# row is left (IDLE_SSID, PLACEHOLDER_PSK). It is duplicated rather than factored
# out on purpose: doma-shadow-ap is the path every boot depends on, and making
# it source one would add a new way for that path to fail. If you change the
# stanza format, change both and say so in the commit message.
write_hostapd_conf() {
    {
        echo "interface=$AP_IF"
        echo "bridge=$BR"
        echo "driver=nl80211"
        echo "ctrl_interface=$CONF_DIR/sockets"
        echo "hw_mode=g"
        echo "channel=6"
        echo "ieee80211n=1"
        # Emit `bridge=` in every BSS stanza (see step 3 of doma-shadow-ap.sh).
        #   Primary sources (this apex is not a prebuilt, IT IS BUILT FROM THIS TREE:
        #   the binaries at
        #   device/google/cuttlefish/apex/com.google.cf.wpa_supplicant/Android.bp:28-29
        #   are //external/wpa_supplicant_8/wpa_supplicant/wpa_supplicant:hostapd):
        #     external/wpa_supplicant_8/hostapd/config_file.c:2240-2241
        #         `bridge` is os_strlcpy(bss->bridge, ...), i.e. A PER-BSS FIELD
        #     same file :871-906, hostapd_config_bss()
        #         only os_zalloc + hostapd_config_defaults_bss + copying iface/vlan,
        #         AND IT DOES NOT COPY bridge (nor is a default set anywhere in
        #         src/ap/ap_config.c)
        #     src/ap/hostapd.c:1510  conf->bridge[0] ? conf->bridge : NULL
        #     src/drivers/driver_nl80211.c:9706  the `bridge &&` gate
        #   => Written once at the top, every BSS after the first has no bridge, so a
        #   station joining it never completes DHCP. Measured on the board,
        #   2026-09-07: with the seed SSID sixth, association reached COMPLETED
        #   / RSSI -30 but IP: null; moved back to the front, wlan0 got
        #   192.168.10.134/24.
        _first=1
        _idx=0
        # `|| [ -n "$_ssid" ]`: see psk_of
        while IFS="$TAB" read -r _ssid _psk || [ -n "${_ssid:-}" ]; do
            case "$_ssid" in ''|'#'*) continue;; esac
            # log() writes to stdout, i.e. into $CONF.new here: use stderr.
            if ! ssid_hostapd_safe "$_ssid"; then
                log "conf: skip SSID hostapd would reject: $_ssid" >&2
                continue
            fi
            if [ -n "${_psk:-}" ] && ! psk_valid "$_psk"; then
                log "conf: skip $_ssid: PSK neither 8..63 bytes nor 64 hex" >&2
                continue
            fi
            if [ "$_first" = 1 ]; then
                _first=0
            else
                _idx=$((_idx+1))
                echo "bss=${AP_IF}_$_idx"
                echo "bridge=$BR"
            fi
            echo "ssid=$_ssid"
            if [ -n "${_psk:-}" ]; then
                echo "wpa=2"
                echo "wpa_key_mgmt=WPA-PSK"
                echo "rsn_pairwise=CCMP"
                if psk_is_hex "$_psk"; then
                    echo "wpa_psk=$_psk"
                else
                    echo "wpa_passphrase=$_psk"
                fi
            else
                echo "wpa=0"
            fi
        done < "$APS"
        # No usable row (an empty or unreadable $APS, or every row skipped above):
        #   the hidden idle BSS, so hostapd still has a primary BSS to start with.
        #   See IDLE_SSID.
        if [ "$_first" = 1 ]; then
            log "conf: no usable row in $APS; only the hidden idle BSS" >&2
            echo "ssid=$IDLE_SSID"
            echo "ignore_broadcast_ssid=1"
            echo "wpa=2"
            echo "wpa_key_mgmt=WPA-PSK"
            echo "rsn_pairwise=CCMP"
            echo "wpa_passphrase=$PLACEHOLDER_PSK"
        fi
    } > "$CONF.new" || { log "WARNING: cannot write $CONF.new"; return 1; }
    # SET THE MODE BEFORE THE mv (rename(2) keeps it), so no instant has a file holding
    #   a wpa_passphrase readable more widely. This daemon and hostapd both run as uid
    #   wifi (init.xenvm-hwsim.rc), so the file is the reader's own.
    chmod 0660 "$CONF.new" 2>/dev/null || log "WARNING: chmod $CONF.new failed"
    mv "$CONF.new" "$CONF" || { log "WARNING: cannot replace $CONF"; return 1; }
}

# stations_present -- 0 if any station is associated with the shadow AP.
# Used to avoid bouncing hostapd under a connected user; hostapd has no way to add or
# remove a BSS without a restart, and SIGHUP does not apply bss= changes.
#
# hostapd_cli IS NOT IN THIS IMAGE (measured on the board: the apex's bin/hw
#   holds hostapd and wpa_supplicant only, and no hostapd_cli or wpa_cli exists
#   under /apex, /vendor or /system; the `binaries` at Android.bp:28-29 is the
#   single hostapd). So two other methods are tried, cheapest first, and IF
#   NEITHER CAN BE READ THE ANSWER IS "A STATION IS PRESENT" (i.e. do not
#   restart -- fall to the safe side).
#
#   Why the safe side: with the seed PSK unchanged, `setprop ctl.restart` on the
#   hostapd service under a connected station was measured on the board to leave
#   DomA's Wi-Fi not coming back. Whether a restart with the same PSK can be
#   survived is not established: dnsmasq has a MAC-pinned lease (43200 s), so
#   the same IP is expected to return, but in that measurement it did not.
#     1. $STA_CARRIER (/sys/class/net/wlan0/carrier) -- DomA's own station. THIS IS THE
#        ONLY STATION THERE IS TO PROTECT (DomA's external connectivity is this one
#        BSS). mac80211 raises carrier on a successful association. Primary source:
#        netif_carrier_on(sdata->dev) at :3987, the end of ieee80211_set_associated()
#        (:3908) in the guest kernel's net/mac80211/mlme.c. THIS IS NOT AN INFERENCE:
#        it reads 1 whichever BSS the station is joined to.
#     2. $IW (/vendor/bin/iw, the iw_vendor build of external/iw the products install;
#        a vendor domain may not execute /system/bin/iw). It station-dumps the AP-side
#        netdev. A STATION ON A SECONDARY BSS DOES NOT SHOW UP in the wlan2 dump, so
#        $AP_IF and the generated ${AP_IF}_N are enumerated from $NETDEV_DIR.
#        If neither 1 nor 2 can be read, it falls back to "a station is present", i.e.
#        no restart.
#   An image that ships hostapd_cli could add it, but these two are sufficient.
# sta_carrier_up -- does $STA_CARRIER read 1? With the builtin `read`, not
# $(cat ...): this runs on every 2 s tick, and an external command costs 30-60 ms
# of CPU on this guest. Unreadable (-EINVAL while the interface is down) reads
# empty, as cat did.
sta_carrier_up() {
    _cr=""
    { IFS= read -r _cr < "$STA_CARRIER"; } 2>/dev/null
    [ "$_cr" = 1 ]
}

stations_present() {
    _known=0
    # 1. DomA's own station -- unless mirror_station saw it on the hidden idle BSS,
    #    which carries no AP anyone uses: a restart there loses nothing, and counting
    #    it would hold back the restart that beacons the real APs for as long as the
    #    station stays. (STA_LAST_SSID lags an association by up to one tick.)
    if [ -r "$STA_CARRIER" ]; then
        _known=1
        if sta_carrier_up; then
            [ "$STA_LAST_SSID" = "$IDLE_SSID" ] && return 1
            return 0
        fi
    fi
    # 2. Any other station on any AP-side netdev (wlan2 and wlan2_1..N)
    if [ -x "$IW" ]; then
        for _d in "$NETDEV_DIR/$AP_IF" "$NETDEV_DIR/$AP_IF"_*; do
            [ -d "$_d" ] || continue
            _sd=$("$IW" dev "${_d##*/}" station dump 2>/dev/null) || continue
            _known=1
            [ -n "$_sd" ] && return 0
        done
    fi
    [ "$_known" = 1 ] && return 1
    # 3. Neither is usable => fall to the safe side (a station is present). Log once.
    if [ "${NODETECT_LOGGED:-0}" != 1 ]; then
        NODETECT_LOGGED=1
        log "stations_present: cannot detect a station (neither $STA_CARRIER nor $IW is usable) -- returning \"station present\" on the safe side; no aps-driven hostapd restart"
    fi
    return 0
}

# sta_is_up -- is DomA's station interface up, i.e. is the Settings Wi-Fi toggle on?
#
# WHY ONLY $REQ WAITS ON IT. Turning Wi-Fi off in the DomA Settings must also stop DomD
# being asked to associate, and a PSK request is the only thing that asks while the
# station is down (mirror_station already does nothing without carrier). aps
# publications keep syncing $APS and hostapd.conf: no station can be dropped, and the
# list is current the moment the toggle comes back on.
#
# FLAGS, NOT CARRIER. With the toggle off the framework takes wlan0 down -- measured on
# RPi4 2026-09-24, flags 0x1003 -> 0x1002 within 1 s -- and carrier then reads -EINVAL
# (net/core/net-sysfs.c: carrier_show() needs netif_running()). flags is printed "%#x"
# and IFF_UP is bit 0, so the last hex digit is odd exactly when the interface is up;
# `case`, because a test operand cannot be hex in mksh. Unreadable (wlan0 not created
# yet) counts as up.
sta_is_up() {
    # The builtin `read`, not $(cat ...): see sta_carrier_up.
    _fl=""
    { IFS= read -r _fl < "$STA_FLAGS"; } 2>/dev/null || [ -n "$_fl" ] || return 0
    case "$_fl" in
        0x*[13579bdfBDF]) return 0;;
        0x*)              return 1;;
        *)                return 0;;
    esac
}

# confirm_hostapd_running -- check that running IS SUSTAINED.
#
# WHY IT IS NEEDED (from primary sources):
#   init's `NotifyStateChange("running")` is fired IN THE PARENT, RIGHT AFTER
#   THE FORK (system/core/init/service.cpp:817, just after waiting for `setsid`
#   to complete and before the `... started service` log). It IS UNRELATED to
#   whether the child then `exit 1`s in config parsing after exec. When the
#   child dies, the SIGCHLD reaping at :322 clears SVC_RUNNING and :428 fires
#   `"restarting"`.
#   => A `getprop init.svc.*` taken immediately after `setprop ctl.restart`
#   returns IS ALWAYS running, even with an INVALID hostapd.conf. Taken as
#   success, it would log "hostapd restarted via init (N SSID(s))" and reset
#   `RESTART_PENDING` to 0 while hostapd crash-loops every 5 s and the shadow AP
#   -- DomA's only way in -- is gone. That covers EVERY CASE THAT MAKES THE CONF
#   INVALID, including a wrong owner or mode (the measured "12 times, 5.0 s
#   apart" in write_hostapd_conf).
#
# init's `restart_period` defaults to 5 s, so sampling a 3 s window every 0.5 s
# (6 samples) is guaranteed to catch a non-running state at least once during a
# crash loop. The values can be overridden from the environment.
# The hostapd init service, vendor.doma_shadow_hostapd in init.xenvm-hwsim.rc.
#   `setprop ctl.restart` exits non-zero when init has no service of that name:
#   init's control-message handler replies PROP_ERROR_HANDLE_CONTROL_MESSAGE,
#   and bionic's __system_property_set() and toolbox's setprop turn that into a
#   failed exit (system/core/init/init.cpp,
#   bionic/libc/bionic/system_property_set.cpp,
#   system/core/toolbox/setprop.cpp). init replies only to a vendor above API
#   level Q (SelinuxGetVendorAndroidVersion() in property_service.cpp); this
#   board's vendor has ro.vendor.build.version.sdk=37.
HOSTAPD_SVC=${HOSTAPD_SVC:-vendor.doma_shadow_hostapd}

kick_hostapd() {
    setprop ctl.restart "$HOSTAPD_SVC"
}

# svc_is_running -- is the hostapd service running?
#
# init.svc.$HOSTAPD_SVC is readable from this domain (vendor_default_prop for a
#   `vendor.` service; see the service's comment in init.xenvm-hwsim.rc). Not pidof:
#   from this domain the other domains' /proc entries are not readable under
#   enforcing, and pidof cannot tell this hostapd from the platform's SoftAp one.
svc_is_running() {
    [ "$(getprop "init.svc.$HOSTAPD_SVC" 2>/dev/null)" = running ]
}

CONFIRM_SAMPLES=${CONFIRM_SAMPLES:-6}
CONFIRM_SLEEP=${CONFIRM_SLEEP:-0.5}
confirm_hostapd_running() {
    _n=0
    while [ "$_n" -lt "$CONFIRM_SAMPLES" ]; do
        sleep "$CONFIRM_SLEEP"
        svc_is_running || return 1
        _n=$((_n+1))
    done
    return 0
}

# restart_hostapd -- make hostapd read the new $CONF.
#
# GO THROUGH init. HOSTAPD IN THIS IMAGE IS AN INIT SERVICE ($HOSTAPD_SVC),
#   started in the foreground by its init.xenvm-hwsim.rc service (with neither
#   -B nor -P), so no pid file exists to kill it by, and a second hostapd -B
#   started here fails because wlan2 is in use: the new SSIDs would go into
#   hostapd.conf and never make it into a beacon. This follows step 5 of
#   doma-shadow-ap.sh (setprop ctl.* plus a wait on init.svc.<name>).
restart_hostapd() {
    # LOOK AT `init.svc.$HOSTAPD_SVC` ONLY (svc_is_running).
    #   `setprop ctl.*` DOES NOT RETURN UNTIL INIT HAS FINISHED HANDLING IT
    #   (SendControlMessage() in property_service.cpp Releases the client's socket fd
    #   and hands it to init, and init replies AFTER running
    #   HandleControlMessage()). So by the time setprop returns, the old instance has
    #   already been SIGKILLed and the state has been updated.
    kick_hostapd || {
        log "WARNING: ctl.restart $HOSTAPD_SVC failed (the rc has no such service)"
        RESTART_PENDING=1
        return 1
    }
    # THIS WAIT STALLS THE MAIN LOOP FOR UP TO 10 s (the caller polls every 2 s). If
    #   the hvc receive buffer overflows, one DomD publication can be lost. In practice
    #   the apex's hostapd reaches running in under a second, so this normally exits in
    #   less than 1 s.
    #   Shortening it would mean restructuring to "fire, return, and look at init.svc on
    #   the next tick", which moves where the success log comes from, so it is left as
    #   is for now.
    _i=0
    while [ $_i -lt 100 ]; do        # up to 10 s; the apex's hostapd comes up in under a second
        if svc_is_running; then
            # Do not call this a success yet (see the confirm_hostapd_running comment).
            if confirm_hostapd_running; then
                RESTART_PENDING=0; BOUNCE_WAIT=0; RESTART_FOR_LIST=0
                # what is beaconed now (see LIVE)
                cp "$CONF" "$LIVE.new" 2>/dev/null && chmod 0600 "$LIVE.new" 2>/dev/null \
                    && mv -f "$LIVE.new" "$LIVE" 2>/dev/null \
                    || log "WARNING: cannot update $LIVE"
                log "hostapd restarted via init ($(grep -c '^ssid=' "$CONF") SSID(s))"
                return 0
            fi
            RESTART_PENDING=1
            log "WARNING: hostapd dies right after starting (init.svc does not sustain running). Check $CONF (is it owned wifi:wifi 0660? is wpa_passphrase 8..63 bytes?)"
            return 1
        fi
        _i=$((_i+1)); sleep 0.1
    done
    # ON FAILURE, SET RESTART_PENDING, so flush_pending_restart retries on a
    #   later tick. The hostapd service is neither critical nor updatable, so
    #   repeated failures cannot reboot the device.
    RESTART_PENDING=1
    log "WARNING: hostapd restart failed (svc=$HOSTAPD_SVC init.svc=$(getprop "init.svc.$HOSTAPD_SVC")); see $CONF"
    return 1
}

# --- handlers ------------------------------------------------------------------------

# byte_len <s> -- sets _bl to the BYTE count of <s> without a fork. mksh's ${#s}
# counts characters only in its UTF-8 mode (set -U) and bytes otherwise, so the
# mode is turned off for the count and back on if it was on. A fork per row
# (printf | wc) cost DomA about 1 s of CPU per scan publication, enough to stall
# video playback (RPi4 2026-10-26).
byte_len() {
    case $- in *U*) set +U; _bl=${#1}; set -U;; *) _bl=${#1};; esac
}

# ssid_hostapd_safe <ssid> -- false for a name hostapd.conf cannot carry.
#
# ONE bad SSID makes hostapd reject the WHOLE config, and with it the shadow AP
# and all of DomA's Wi-Fi: measured 2026-09-17, an AP beaconing 20 NUL bytes
# left the shadow AP restarting every 5 s. hostapd takes `ssid=` byte for byte
# (hostapd/config_file.c copies it with os_memcpy) and refuses more than 32
# bytes; that SSID's escaped form, \x00 twenty times, is 80. A backslash means
# the name is still escaped -- DomD's JSON escapes a quote or a backslash in an
# SSID, and the sed in handle_aps does not undo that -- so it is refused as
# well. Count BYTES: mksh's ${#s} counts characters under UTF-8.
# doma-shadow-ap.sh carries the same function.
ssid_hostapd_safe() {
    case "$1" in ''|*\\*) return 1;; esac
    # Printable ASCII: one byte per character, so ${#1} is the byte count without
    #   running wc (an SSID is checked on every publication).
    case "$1" in *[!\ -~]*) ;; *) [ "${#1}" -le 32 ]; return;; esac
    byte_len "$1"; [ "$_bl" -le 32 ]
}

# psk_is_hex <psk> -- a raw PSK: exactly 64 hex digits. hostapd.conf carries it
# as wpa_psk=, and DomD's agent sends it to wpa_supplicant unquoted.
psk_is_hex() {
    case "$1" in ''|*[!0-9A-Fa-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}

# psk_valid <psk> -- is this a PSK both hostapd and DomD's wpa_supplicant
# accept?
#
# Two forms exist. A passphrase is 8..63 BYTES (count bytes, as above). A raw
# PSK is 64 hex digits (psk_is_hex): AAOS's Wi-Fi dialog LEGITIMATELY ACCEPTS
# ONE and stores it unquoted
# (packages/apps/Car/Settings/.../WifiUtil.java:285-288 puts it into
# preSharedKey without quotes when `password.matches("[0-9A-Fa-f]{64}")`), and
# hostapd takes it as wpa_psk=
# (external/wpa_supplicant_8/hostapd/config_file.c:2923-2934), which is how both
# generators write it.
#
# Anything else is refused BEFORE it reaches $APS or DomD.
# config_file.c:2910-2916 rejects a wpa_passphrase outside 8..63, and one error
# makes hostapd throw the WHOLE config away and exit 1; in $APS (on /data) that
# would happen at every boot and take the shadow AP -- DomA's way in -- with it.
# DomD's wpa_supplicant, for its part, prints a passphrase it refuses into its
# log. $REQ is wifi:system 0770 and is writable by more than just the app, so A
# GUARD IN THE APP ALONE IS NOT THE LAST LINE OF DEFENCE.
psk_valid() {
    psk_is_hex "$1" && return 0
    byte_len "$1"; _n=$_bl
    [ "$_n" -ge 8 ] && [ "$_n" -le 63 ]
}

# iw_ssid <SSID as iw prints it> -- the SSID's real bytes; returns 1 for one
# that has a control byte.
#
# `iw dev wlan0 link` prints the SSID through print_ssid_escaped()
# (external/iw/util.c): each byte that is not printable ASCII, each backslash,
# and a space at either end come out as \x and two lower-case hex digits, and
# nothing else is escaped. $APS holds the real bytes -- DomD's agent publishes
# SSIDs as UTF-8 text -- so iw's form of a name such as a Japanese one matches
# no row. Undecoded, psk_of would miss it and the mirror would send DomD's
# agent the escaped text with an empty PSK, which the agent would join as an
# open network in place of the real one. Every backslash iw prints starts such an
# escape, so each is rewritten as the octal \0NNN that printf's %b decodes, in
# toybox's printf (the one mksh runs on the device) as in bash's, dash's and
# busybox's. A control byte is refused rather than decoded: DomD's agent
# publishes no SSID that has one, and a NUL or a newline would not survive
# $(...).
iw_ssid() {
    _in=$1; _out=""
    while :; do
        case "$_in" in *\\x*) ;; *) break;; esac
        _out=$_out${_in%%\\x*}
        _in=${_in#*\\x}
        case "$_in" in [0-9a-f][0-9a-f]*) ;; *) return 1;; esac
        _c=$((0x${_in%"${_in#??}"}))
        [ "$_c" -ge 32 ] && [ "$_c" -ne 127 ] || return 1
        _in=${_in#??}
        _out=$_out\\0$((_c / 64))$((_c / 8 % 8))$((_c % 8))
    done
    printf '%b' "$_out$_in"
}

# sta_link_ssid -- the SSID DomA's own station is associated with, decoded by
# iw_ssid(); iw's own form if iw_ssid() refuses it (that matches no row of
# $APS); empty when the station is not associated.
sta_link_ssid() {
    _raw=$("$IW" dev "$STA_IF" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1)
    [ -n "$_raw" ] || return 0
    iw_ssid "$_raw" || printf '%s' "$_raw"
}

# in_ssid_list <ssid> <newline-separated list>
# A `case` on the newline-framed list, not `while read ... <<EOF`: mksh backs every
# here-document with a temporary file in $TMPDIR (/data/local), which this domain may
# not create -- one avc denial per call, several per publication. The quoted parts of
# the pattern match literally, so an SSID with * or ? in it is not a pattern.
in_ssid_list() {
    case "$NL$2$NL" in *"$NL$1$NL"*) return 0;; esac
    return 1
}

# aps_ssids <json-line> -- set _ssids to the newline-separated "ssid" values of a
# publication: what `printf | tr ',' '\n' | sed -n 's/.*"ssid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'`
# printed, without its three execs. As there, a value is the text up to the next
# double quote, blanks may surround the colon, and a value with a comma is dropped
# (the tr split it). _opens gets the subset whose "sec" is "open". At most APS_MAX
# values are taken, so a hostile or broken line cannot make this run for minutes.
aps_ssids() {
    _ssids=""; _opens=""; _r=$1; _na=0
    while [ "$_na" -lt "$APS_MAX" ]; do
        case "$_r" in *'"ssid"'*) ;; *) break;; esac
        # This object's text before its "ssid" key: after the last { in front of it.
        #   The previous object's ssid value has been consumed already, so a brace in
        #   some SSID cannot shift this.
        _b=${_r%%'"ssid"'*}; _b=${_b##*'{'}
        _r=${_r#*'"ssid"'}
        _x=$_r
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in :*) _x=${_x#:};; *) continue;; esac
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in \"*) _x=${_x#\"};; *) continue;; esac
        case "$_x" in *\"*) ;; *) break;; esac
        _v=${_x%%\"*}
        _r=${_x#*\"}
        case "$_v" in *,*) continue;; esac
        _ssids=$_ssids$_v$NL
        _na=$((_na+1))
        # Its "sec": a "sec" key in the SAME object -- before the "ssid" key ($_b) or
        #   after its value, up to the first }. A quote inside a JSON string is always
        #   escaped, so "sec" in quotes cannot come from a value, and no value of this
        #   protocol other than an SSID holds a brace. Only "open" matters to the caller.
        _x=$_b${_r%%'}'*}
        case "$_x" in *'"sec"'*) ;; *) continue;; esac
        _x=${_x#*'"sec"'}
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in :*) _x=${_x#:};; *) continue;; esac
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in '"open"'*) _opens=$_opens$_v$NL;; esac
    done
    _ssids=${_ssids%"$NL"}
    _opens=${_opens%"$NL"}
}

# msg_type <json-line> -- set _t to the message type: the value of the last "t" key
# whose value is [a-z]* in double quotes, which is what the greedy
# `sed -n 's/.*"t"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p'` printed. Empty if none.
msg_type() {
    _t=""; _r=$1
    while :; do
        case "$_r" in *'"t"'*) ;; *) break;; esac
        _r=${_r#*'"t"'}
        _x=$_r
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in :*) _x=${_x#:};; *) continue;; esac
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in \"*) _x=${_x#\"};; *) continue;; esac
        case "$_x" in *\"*) ;; *) continue;; esac
        _v=${_x%%\"*}
        case "$_v" in *[!a-z]*) continue;; esac
        _t=$_v
    done
}

# json_str <key> <json-line> -- set _js to the string value of "<key>", as msg_type
# reads "t": blanks may surround the colon, and a "<key>" that is not followed by a
# colon (a value that happens to be the same word, such as "t": "state") is passed
# over. Returns 1 when there is none, or when the value holds a backslash: an escaped
# SSID never gets a row (ssid_hostapd_safe), so there is nothing it could match.
json_str() {
    _js=""; _r=$2
    while :; do
        case "$_r" in *"\"$1\""*) ;; *) return 1;; esac
        _r=${_r#*"\"$1\""}
        _x=$_r
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in :*) _x=${_x#:};; *) continue;; esac
        while :; do case "$_x" in " "*|"$TAB"*) _x=${_x#?};; *) break;; esac; done
        case "$_x" in \"*) _x=${_x#\"};; *) continue;; esac
        case "$_x" in *\"*) ;; *) return 1;; esac
        _v=${_x%%\"*}
        case "$_v" in *\\*) return 1;; esac
        _js=$_v
        return 0
    done
}

# seed_real_psk_of <ssid> -- the seed's PSK for it unless that is empty or the
# placeholder (a build may seed an SSID with either; see the seed's header).
seed_real_psk_of() {
    _sr=$(seed_psk_of "$1") || return 1
    case "$_sr" in ''|"$PLACEHOLDER_PSK") return 1;; esac
    print -nr -- "$_sr"
}

# secured_psk_of <ssid> -- the PSK a secured SSID's row gets: a passphrase the user
# typed for it ($LEARNED), else the seed's, else the placeholder. Sets _src to which.
secured_psk_of() {
    if _sp=$(learned_psk_of "$1"); then _src=learned
    elif _sp=$(seed_real_psk_of "$1"); then _src=seed
    else _sp=$PLACEHOLDER_PSK; _src=placeholder
    fi
}

# handle_aps <json-line> -- make $APS mirror the SSIDs DomD can currently hear.
#
# Each publication REPLACES the list, so the picker shows what is actually in
# range, and a row that stops being published does not stay in hostapd.conf.
#
# Two kinds of row survive a publication that does not mention them:
#   * the SSID DomA's own station is associated with -- dropping it would delete
#     the shadow AP DomA is connected to, taking down the link this session runs
#     over;
#   * seeded rows (/vendor/etc/doma-shadow-aps.conf), which must be joinable
#     even before the first scan arrives.
# Existing rows keep their order and their PSK, so the primary BSS does not move.
# A row that does go takes its PSK to $LEARNED if it has a real one, and the SSID
# gets it back when it is published again.
#
# AT MOST APS_MAX ROWS. The hysteresis keeps rows a publication did not name, so
# without a cap a rotating top 20 grew the list to 40 and 60. When there are more,
# rows are kept in this order, and the rest dropped: the ones this publication
# names, then the station's, then seeded ones, then those missing from one
# publication, then from two. The order inside $APS does not change. A station
# whose SSID loses out is still protected: stations_present() defers the restart
# until it has left.
#
# SECURITY FOLLOWS THE PUBLICATION ("sec"), for new rows and for rows it names:
#   open    a new row gets an empty PSK (an open shadow BSS), unless the seed holds a
#           real PSK for it. A row holding the placeholder becomes open. A row
#           holding a real PSK -- typed by the user, or the seed's -- KEEPS IT: the
#           shadow BSS stays WPA2, which the station still joins with the saved PSK,
#           and DomD's agent joins the real AP without one because ITS scan says open.
#   secured a new row gets secured_psk_of (learned, seed, placeholder). An open row
#           gets the same, since an open shadow BSS for a secured AP is the dead end
#           described at PLACEHOLDER_PSK.
# A ROW'S SECURITY CHANGES ON THE THIRD PUBLICATION IN A ROW that says so (APS_FLIP1/2;
# at once with APS_HYST=0): one SSID can have an open and a secured BSS, DomD
# publishes the strongest, and without this the row, the conf and hostapd flipped
# with the signal every 20 s.
#
# A PUBLICATION WITH AN EMPTY LIST ("v": []) counts as naming no SSID, so rows age out
# under the hysteresis when DomD hears nothing at all; with no row left,
# write_hostapd_conf beacons only the hidden idle BSS. A line without any "ssid" that
# is not such a list is ignored, as before.
handle_aps() {
    # Extract every "ssid":"..." value. In the shell, not a JSON parser: toybox has
    # none and the producer is one known program. An SSID with a quote or a backslash
    # arrives escaped, and ssid_hostapd_safe refuses it below.
    # The new list is built in $_rows/$_out and compared with $APS in the shell: for a
    #   publication that changes nothing -- every one but the first, in practice --
    #   this function runs no external command (the main loop runs one getprop per aps
    #   message). Each one costs 30-60 ms of CPU on this guest, and the earlier
    #   pipeline-and-temp-file version ran ~42 per publication (9% of a vCPU while idle).
    aps_ssids "$1"
    if [ -z "$_ssids" ]; then
        case "$1" in *'"v": []'*|*'"v":[]'*) ;; *) return 0;; esac
    fi
    holds_seen
    _added=0
    _dropped=0
    # The station's SSID: mirror_station's cache, so normally without a fork.
    if [ -n "$STA_LAST_SSID" ]; then
        _sta=$STA_LAST_SSID
    elif [ ! -x "$IW" ] || { [ -r "$STA_CARRIER" ] && ! sta_carrier_up; }; then
        _sta=""
    else
        _sta=$(sta_link_ssid)
    fi
    _tmp=$APS.sync.$$
    _rows=""            # the kept rows, "<class>TAB<ssid>TAB<psk>" each, in $APS order
    _keys=$NL           # their SSIDs, newline-framed, for the duplicate check in step 2
    _cur=""             # $APS as it is, to tell whether anything changed
    _nonl=0             # 1 if its last line has no newline (rewrite it, see psk_of)
    _nN=0; _nS=0; _nP=0; _n1=0; _n2=0

    # 1. existing rows, in order, if still in range (N), or protected (S station, P
    #    seed), or -- with APS_HYST=1 -- missing from fewer than three publications in
    #    a row (1, 2)
    _m1=""; _m2=""      # the miss lists after this publication
    _f1=""; _f2=""      # and the security-change lists
    while IFS="$TAB" read -r _k _v || { [ -n "${_k:-}" ] && _nonl=1; }; do
        case "$_k" in ''|'#'*) _cur=$_cur$_k${_v:+$TAB$_v}$NL; continue;; esac
        _cur=$_cur$_k$TAB${_v:-}$NL
        if in_ssid_list "$_k" "$_ssids"; then
            # Named: in range. Does the published security disagree with the row's?
            _want=""
            if in_ssid_list "$_k" "$_opens"; then
                [ "${_v:-}" = "$PLACEHOLDER_PSK" ] && _want=open
            else
                [ -z "${_v:-}" ] && _want=secured
            fi
            if [ -n "$_want" ] && [ "$APS_HYST" = 1 ] \
               && case "$APS_FLIP2" in *"$NL$_k$NL"*) false;; *) true;; esac; then
                # disagreeing once or twice so far: keep the security, count it
                case "$APS_FLIP1" in *"$NL$_k$NL"*) _f2=$_f2$_k$NL;; *) _f1=$_f1$_k$NL;; esac
            elif [ "$_want" = open ]; then
                _v=""
                log "aps: $_k is open now; its row is open too"
            elif [ "$_want" = secured ]; then
                secured_psk_of "$_k"; _v=$_sp
                log "aps: $_k is secured now; its open row gets a PSK ($_src)"
            fi
            _c=N; _nN=$((_nN+1))
        elif [ -n "$_sta" ] && [ "$_k" = "$_sta" ]; then
            _c=S; _nS=$((_nS+1))
        elif seed_psk_of "$_k" >/dev/null 2>&1; then
            _c=P; _nP=$((_nP+1))
        elif [ "$APS_HYST" = 1 ] && case "$APS_MISS2" in *"$NL$_k$NL"*) false;; *) true;; esac; then
            # missing once or twice so far: keep the row, count the miss
            if case "$APS_MISS1" in *"$NL$_k$NL"*) true;; *) false;; esac; then
                _m2=$_m2$_k$NL; _c=2; _n2=$((_n2+1))
            else
                _m1=$_m1$_k$NL; _c=1; _n1=$((_n1+1))
            fi
        else
            _dropped=$((_dropped+1))
            # not a passphrase DomD has not accepted yet (see PENDING)
            pending_has "$_k" || learned_put "$_k" "${_v:-}"
            continue
        fi
        _rows=$_rows$_c$TAB$_k$TAB${_v:-}$NL
        _keys=$_keys$_k$NL
    done < "$APS"
    APS_MISS1=$NL$_m1
    APS_MISS2=$NL$_m2
    APS_FLIP1=$NL$_f1
    APS_FLIP2=$NL$_f2

    # 2. SSIDs in this publication that are not in the list yet
    # DO NOT WRITE `for _new in $_ssids` with the default IFS: AN SSID CONTAINING A
    #   SPACE WOULD BE SPLIT into two rows, neither of them the real name. Split on
    #   newlines only, with globbing off, into this function's own positional
    #   parameters (a here-document would cost a temporary file, see in_ssid_list).
    #   AN SSID CONTAINING A COMMA has already been dropped by aps_ssids.
    _oifs=$IFS; IFS=$NL; set -f
    set -- $_ssids
    IFS=$_oifs; set +f
    for _new in "$@"; do
        [ -n "$_new" ] || continue
        # Already in the new list (an existing row, or a duplicate in this
        #   publication): nothing to add. Checked before ssid_hostapd_safe, so a
        #   kept row is not re-validated; the outcome is the same, since an unsafe
        #   name was skipped either way.
        case "$_keys" in *"$NL$_new$NL"*) continue;; esac
        # Held after DomD failed to join it (see FAIL_HOLDS).
        hold_active "$_new" && continue
        if ! ssid_hostapd_safe "$_new"; then
            log "aps: skip SSID hostapd would reject (whole config would fail): $_new"
            continue
        fi
        # The seed's real PSK, if it has one, for an open AP too (see the top of this
        #   function); then an open AP gets an open row, and a secured one
        #   secured_psk_of -- see the seed_psk_of() comment for why the seed counts.
        if _sp=$(seed_real_psk_of "$_new"); then
            log "aps: registered $_new with the seed's PSK (not a placeholder)"
        elif in_ssid_list "$_new" "$_opens"; then
            _sp=""
            log "aps: registered $_new as open"
        else
            secured_psk_of "$_new"
            [ "$_src" = learned ] && log "aps: registered $_new with the passphrase typed for it earlier"
        fi
        _rows=$_rows"N$TAB$_new$TAB$_sp$NL"
        _keys=$_keys$_new$NL
        _nN=$((_nN+1))
        _added=$((_added+1))
    done

    # 3. the cap: how many of each class fit, in the order N S P 1 2
    _room=$APS_MAX
    for _c in N S P 1 2; do
        eval "_n=\$_n$_c"
        [ "$_n" -gt "$_room" ] && _n=$_room
        eval "_a$_c=\$_n"
        _room=$((_room-_n))
    done
    _out=""
    _oifs=$IFS; IFS=$NL; set -f
    set -- $_rows
    IFS=$_oifs; set +f
    for _ln in "$@"; do
        _c=${_ln%%"$TAB"*}; _ln=${_ln#*"$TAB"}
        _k=${_ln%%"$TAB"*}; _v=${_ln#*"$TAB"}
        eval "_n=\$_a$_c"
        if [ "$_n" -gt 0 ]; then
            eval "_a$_c=\$((_n-1))"
            _out=$_out$_k$TAB$_v$NL
        else
            _dropped=$((_dropped+1))
            pending_has "$_k" || learned_put "$_k" "$_v"
            log "aps: $_k dropped: more than $APS_MAX rows"
        fi
    done

    # 4. nothing to do unless the list (or its last newline) actually changed
    [ "$_out" = "$_cur" ] && [ "$_nonl" = 0 ] && return 0
    # In a subshell: mksh ends the function on a failed redirection onto a special
    #   builtin before `||` runs (see doma-shadow-ap.sh's seed merge); `print` is
    #   not one, but the subshell keeps this independent of that.
    if ! ( print -nr -- "$_out" > "$_tmp" ) 2>/dev/null; then
        log "WARNING: aps: cannot write $_tmp"
        rm -f "$_tmp"
        return 0
    fi
    # By rename, as handle_psk does: this daemon runs on every boot, so init's
    # SIGKILL at shutdown can land mid-write, and a truncated $APS loses every
    # PSK in it. The temporary file is in the same directory, so it has the same label.
    chmod 0660 "$_tmp" 2>/dev/null
    if ! mv -f "$_tmp" "$APS"; then
        log "WARNING: aps: could not update $APS"
        rm -f "$_tmp"
        return 0
    fi
    log "aps: synced to the current scan (+$_added -$_dropped, now $(grep -c . "$APS") row(s))"
    # Read per message, so a setprop takes effect without restarting the relay.
    #   The environment variable BOUNCE_ON_APS takes precedence if set.
    _bounce=${BOUNCE_ON_APS:-$(getprop persist.vendor.doma.wifi_relay_bounce_on_aps 2>/dev/null)}
    if [ "$_bounce" = false ]; then
        # The idle-only exception (see BOUNCE_ON_APS): nothing to disrupt.
        if conf_is_idle "$LIVE"; then
            log "aps: hostapd beacons only the hidden idle BSS -- applying the list despite ...wifi_relay_bounce_on_aps=false"
            write_hostapd_conf && restart_hostapd
            return 0
        fi
        # The rate-limited form (see BOUNCE_MIN_S).
        _min=${BOUNCE_MIN_S:-$(getprop persist.vendor.doma.wifi_relay_bounce_min_s 2>/dev/null)}
        case "$_min" in ''|*[!0-9]*) _min=0;; esac
        if [ "$_min" -gt 0 ]; then
            write_hostapd_conf || return 0
            if cmp -s "$CONF" "$LIVE" 2>/dev/null; then
                RESTART_PENDING=0; BOUNCE_WAIT=0; RESTART_FOR_LIST=0
                return 0
            fi
            if stations_present; then
                RESTART_PENDING=1; BOUNCE_WAIT=$_min; RESTART_FOR_LIST=1
                log "aps: a station is associated -- deferring the hostapd restart (rate-limited to one per $_min s)"
            elif [ -n "$LAST_BOUNCE" ] && [ $((SECONDS-LAST_BOUNCE)) -lt "$_min" ]; then
                RESTART_PENDING=1; BOUNCE_WAIT=$_min; RESTART_FOR_LIST=1
                log "aps: hostapd restarted $((SECONDS-LAST_BOUNCE)) s ago -- deferring this list until $_min s have passed"
            else
                # A failed restart is retried by flush_pending_restart as a list one.
                RESTART_FOR_LIST=1
                restart_hostapd && LAST_BOUNCE=$SECONDS
            fi
            return 0
        fi
        # hostapd is not restarted, so a hostapd.conf written now would not be read before
        #   the next boot (doma-shadow-ap regenerates it from $APS then) or a PSK repair
        #   (handle_psk writes it itself). Skipping it saves ~0.4 s of CPU per publication
        #   that changes the list (2026-10-11, measured on RPi4 DomA). A restart an
        #   earlier publication deferred would apply a conf older than $APS: drop it.
        if [ "$RESTART_PENDING" = 1 ]; then
            RESTART_PENDING=0; RESTART_FOR_LIST=0
            log "aps: dropping the deferred hostapd restart (...wifi_relay_bounce_on_aps=false; its conf is out of date)"
        fi
        log "aps: $APS updated only (...wifi_relay_bounce_on_aps=false); hostapd.conf follows at the next boot or on a PSK repair"
        return 0
    fi
    write_hostapd_conf || return 0
    # Back to what hostapd beacons (a security or presence flip undone, or a
    #   rewrite that only added the last newline): no restart, and none pending.
    if cmp -s "$CONF" "$LIVE" 2>/dev/null; then
        [ "$RESTART_PENDING" = 1 ] && log "aps: hostapd.conf is back to what hostapd beacons -- the deferred restart is not needed"
        RESTART_PENDING=0; RESTART_FOR_LIST=0
        return 0
    fi
    if [ "$_bounce" != true ] && stations_present; then
        RESTART_PENDING=1; RESTART_FOR_LIST=1
        log "aps: a station is associated -- deferring the hostapd restart (the conf is already updated; it will be applied once the station leaves)"
    else
        restart_hostapd
    fi
}

# flush_pending_restart -- apply a deferred conf once the last station has gone.
#
# WITHOUT THIS A DEFERRAL CAN LAST FOREVER. A publication that arrives while the
# user is connected defers the restart, and the next one finds nothing new:
# handle_aps returns as soon as it finds $APS unchanged, before reaching any
# restart, and handle_psk cannot fire for an SSID the user cannot see. Checked
# from the main loop instead, so the pending conf is applied within one tick (<=
# 2 s) of the station disconnecting.
flush_pending_restart() {
    [ "$RESTART_PENDING" = 1 ] || return 0
    # First the builtin check: while the station stays, which can be hours, this
    # then costs no exec per tick.
    stations_present && return 0
    # A restart deferred by BOUNCE_MIN_S waits for its interval as well.
    [ "$BOUNCE_WAIT" -gt 0 ] && [ -n "$LAST_BOUNCE" ] \
        && [ $((SECONDS-LAST_BOUNCE)) -lt "$BOUNCE_WAIT" ] && return 0
    # NOT WHILE doma_shadow_ap IS ITSELF BRINGING hostapd UP. Both run at
    # sys.boot_completed, and on the board a deferred restart that landed
    # between the oneshot's `ctl.start` and its confirmation left the log saying
    # "hostapd died right after start", the bridge up late and a second restart
    # needed. The oneshot reports `stopped` once it has exited; defer one tick
    # until then.
    [ "$(getprop init.svc.vendor.doma_shadow_ap 2>/dev/null)" = running ] && return 0
    log "applying deferred hostapd conf (no station associated)"
    # Counted as a list restart only when a list change deferred it (not a retry of
    #   a restart for a passphrase or for DomD's state that failed).
    _fl=$RESTART_FOR_LIST
    restart_hostapd && [ "$_fl" = 1 ] && LAST_BOUNCE=$SECONDS
}

# set_row_psk <ssid> <psk> -- give the SSID's row in $APS this PSK (appending the row
# if it has none), with awk, because the PSK may contain characters that would
# confuse sed's replacement.
#
# VALUES COME THROUGH ENVIRON, NOT -v. awk processes escape sequences in
# a -v assignment, so `-v p='a\\b'` reaches the program as `a\b`: a
# passphrase containing a backslash would be corrupted, and since the
# corrupted value would land in BOTH aps.conf and hostapd.conf, the
# local handshake would succeed while the real AP rejected it
# (reproduced on the PC). ENVIRON does no such processing.
set_row_psk() {
    RELAY_SSID=$1 RELAY_PSK=$2 awk -F'\t' 'BEGIN{OFS="\t"; s=ENVIRON["RELAY_SSID"]; p=ENVIRON["RELAY_PSK"]}
        /^#/ || NF==0 { print; next }
        $1==s { print s, p; seen=1; next }
        { print }
        END { if (!seen) print s, p }' "$APS" > "$APS.new" && mv "$APS.new" "$APS"
    chmod 0660 "$APS" 2>/dev/null
}

# drop_row <ssid> <why> -- take the SSID's row out of $APS and restart hostapd, so
# DomA's station on it is let go even while it is associated and whatever the
# bounce flag says: there is no link left behind it to keep. The mirror mark goes
# too, so a later association with the SSID is forwarded again.
drop_row() {
    RELAY_SSID=$1 awk -F'\t' 'BEGIN { s=ENVIRON["RELAY_SSID"] } /^#/ || NF==0 || $1 != s' \
        "$APS" > "$APS.new" && mv "$APS.new" "$APS"
    chmod 0660 "$APS" 2>/dev/null
    rm -f "$MIRROR_MARK"
    log "state: $1 removed from the shadow AP -- $2"
    state_restart
}

# state_restart -- hostapd restarts for handle_state's change of $APS now, although
#   a station is associated; but not while doma_shadow_ap is itself bringing hostapd
#   up (as flush_pending_restart waits), then on the first pass after (STATE_RESTART).
state_restart() {
    if [ "$(getprop init.svc.vendor.doma_shadow_ap 2>/dev/null)" = running ]; then
        STATE_RESTART=1
        log "state: doma_shadow_ap is still bringing the shadow AP up -- restarting hostapd after it"
        return 0
    fi
    STATE_RESTART=0
    write_hostapd_conf && restart_hostapd
}

# pending_add <ssid> <psk> <kind> -- a connect is about to be sent: sets _pid to its
#   id, and pending_commit then enters it (only once the write has succeeded).
# pending_has <ssid> -- an entry for the SSID; pending_take <id> -- remove the entry
#   with that id and every older one, setting _pp_s, _pp_k and _pp to its SSID, kind
#   and PSK; 1 if there is none. Both first drop the entries older than PENDING_TTL_S.
pending_add() {
    PENDING_SEQ=$((PENDING_SEQ+1))
    _pid=$$-$PENDING_SEQ
    _pnew=$_pid$TAB$1$TAB$SECONDS$TAB$3$TAB$2$NL
}
pending_commit() {
    PENDING=$PENDING$_pnew
}
pending_expire() {
    _pk2=$NL; _pr=${PENDING#"$NL"}
    while [ -n "$_pr" ]; do
        _pl=${_pr%%"$NL"*}; _pr=${_pr#*"$NL"}
        _pt=${_pl#*"$TAB"}; _pt=${_pt#*"$TAB"}; _pt=${_pt%%"$TAB"*}
        [ $((SECONDS-_pt)) -lt "$PENDING_TTL_S" ] && _pk2=$_pk2$_pl$NL
    done
    PENDING=$_pk2
}
pending_has() {
    pending_expire
    _pr=${PENDING#"$NL"}
    while [ -n "$_pr" ]; do
        _pl=${_pr%%"$NL"*}; _pr=${_pr#*"$NL"}
        _ps=${_pl#*"$TAB"}; _ps=${_ps%%"$TAB"*}
        [ "$_ps" = "$1" ] && return 0
    done
    return 1
}
pending_take() {
    _pp_s=""; _pp_k=""; _pp=""
    pending_expire
    case "$PENDING" in *"$NL$1$TAB"*) ;; *) return 1;; esac
    _pr=${PENDING#*"$NL$1$TAB"}
    _pl=${_pr%%"$NL"*}
    PENDING=$NL${_pr#*"$NL"}
    _pp_s=${_pl%%"$TAB"*}; _pl=${_pl#*"$TAB"}
    _pl=${_pl#*"$TAB"}
    _pp_k=${_pl%%"$TAB"*}
    _pp=${_pl#*"$TAB"}
    return 0
}

# hold_add <ssid> / hold_del <ssid> / hold_active <ssid> -- FAIL_HOLDS; an entry older
# than FAIL_HOLD_S is removed when looked at. hold_del returns 1 if there was none.
hold_add() {
    case "$FAIL_HOLDS_GONE" in *"$NL$1$NL"*) _hr=${FAIL_HOLDS_GONE#*"$NL$1$NL"}
        FAIL_HOLDS_GONE=${FAIL_HOLDS_GONE%%"$NL$1$NL"*}$NL$_hr;; esac
    hold_active "$1"
    case "$FAIL_HOLDS" in *"$NL$1$TAB"*) _hr=${FAIL_HOLDS#*"$NL$1$TAB"}
        FAIL_HOLDS=${FAIL_HOLDS%%"$NL$1$TAB"*}$NL${_hr#*"$NL"};; esac
    FAIL_HOLDS=$FAIL_HOLDS$1$TAB$SECONDS$NL
}
hold_del() {
    case "$FAIL_HOLDS" in *"$NL$1$TAB"*) ;; *) return 1;; esac
    _hr=${FAIL_HOLDS#*"$NL$1$TAB"}
    FAIL_HOLDS=${FAIL_HOLDS%%"$NL$1$TAB"*}$NL${_hr#*"$NL"}
    return 0
}
# holds_seen -- after aps_ssids: lift the hold of a held SSID that the last publication
#   left out and this one names (see FAIL_HOLDS_GONE), and note the held ones it leaves
#   out. No fork.
holds_seen() {
    _hl=${FAIL_HOLDS#"$NL"}; _gone=$NL
    while [ -n "$_hl" ]; do
        _he=${_hl%%"$NL"*}; _hl=${_hl#*"$NL"}
        _hn=${_he%%"$TAB"*}
        if in_ssid_list "$_hn" "$_ssids"; then
            case "$FAIL_HOLDS_GONE" in *"$NL$_hn$NL"*)
                hold_del "$_hn"
                log "aps: $_hn is back in DomD's scan after leaving it -- listed again";;
            esac
        else
            _gone=$_gone$_hn$NL
        fi
    done
    FAIL_HOLDS_GONE=$_gone
}
# state_publish online|offline <ssid> | up -- one line in $STATE_FILE for
#   DomaWifiRelay, which watches the file. <seq> is new on every write, so the app acts
#   once per line.
#   online: DomD has joined <ssid> (COMPLETED or BACK). If DomA's station checked the
#     network for internet access before DomD had a link, AAOS disabled it as
#     NO_INTERNET_PERMANENT (a network that has never had internet: not joined again
#     on its own); while DomD has it, the app enables it again.
#   offline: DomD lost <ssid> or could not join it (LOST, FAILED); DomD's
#     wpa_supplicant holds one network, so it then has none.
#   up: this script has started, so the app sweeps (it reads only the init.svc state of
#     this service, and may have swept before the start).
state_publish() {
    STATE_SEQ=$((STATE_SEQ+1))
    if printf '%s\t%s\t%s\n' "$1" "$$-$STATE_SEQ" "${2-}" > "$STATE_FILE.new" 2>/dev/null \
        && chmod 0640 "$STATE_FILE.new" 2>/dev/null \
        && chgrp system "$STATE_FILE.new" 2>/dev/null \
        && mv -f "$STATE_FILE.new" "$STATE_FILE" 2>/dev/null; then
        :
    else
        log "WARNING: cannot write $STATE_FILE ($1 ${2-})"
    fi
}
STATE_SEQ=0
hold_active() {
    case "$FAIL_HOLDS" in *"$NL$1$TAB"*) ;; *) return 1;; esac
    _hr=${FAIL_HOLDS#*"$NL$1$TAB"}
    _ht=${_hr%%"$NL"*}
    [ $((SECONDS-_ht)) -lt "$FAIL_HOLD_S" ] && return 0
    FAIL_HOLDS=${FAIL_HOLDS%%"$NL$1$TAB"*}$NL${_hr#*"$NL"}
    return 1
}

# state_sta -- set _sta to the SSID DomA's station is on: mirror_station's cache, else
#   iw (the relay's first pass after a restart handles a message before the mirror
#   has looked), as handle_aps does.
state_sta() {
    if [ -n "$STA_LAST_SSID" ]; then
        _sta=$STA_LAST_SSID
    elif [ ! -x "$IW" ] || { [ -r "$STA_CARRIER" ] && ! sta_carrier_up; }; then
        _sta=""
    else
        _sta=$(sta_link_ssid)
    fi
}

# handle_state <json-line> -- DomD's report on the network it joined for DomA:
#   COMPLETED or FAILED answers a connect (its "id", see PENDING), LOST comes unasked
#   once the joined network has stopped being COMPLETED (domd_wifi_agent.py,
#   link_lost). Without acting on them, DomA's station stays on a shadow BSS DomD has
#   no link behind, and the screen shows "Connected" for it.
#   COMPLETED for a typed passphrase's connect in PENDING: it works -- into $LEARNED.
#   FAILED for a connect in PENDING: with WRONG_KEY, its passphrase is remembered as
#     rejected (REJECT_*), and forgotten from $LEARNED if that is the one kept there
#     (the AP's key changed). An answer that matches no connect (from before a restart
#     of this daemon, or after its entry expired) changes neither. Then, while a later
#     connect for the SSID is still pending, nothing else is done: DomD's answer for
#     that one is still to come. Otherwise, with WRONG_KEY, if the row holds a PSK
#     other than the one it would get (learned, else seed, else placeholder; the
#     placeholder when the answer's connect had that very one) -- a passphrase DomD has not
#     accepted -- the row goes back to it and hostapd restarts, so the station is let
#     go (the screen shows the network as saved, not connected). Otherwise, while
#     DomA's station is on the SSID, the row goes and stays away for FAIL_HOLD_S (see
#     FAIL_HOLDS): a network DomD cannot join for a reason other than the key would
#     otherwise be joined again with the same passphrase, round after round.
#   LOST while DomA's station is on the SSID: the row goes (drop_row) and is held as
#     above, until BACK.
#   BACK (DomD rejoined the SSID on its own): its hold goes, so the next publication
#     lists it again.
#   Each of COMPLETED, BACK, LOST and FAILED is also written to $STATE_FILE
#   (state_publish).
#   Anything else is only logged. Each restart waits for doma_shadow_ap
#   (state_restart).
handle_state() {
    json_str ssid "$1" || return 0
    _hs=$_js
    json_str state "$1" || return 0
    _hst=$_js
    _her=""
    json_str error "$1" && _her=$_js
    _tk=0
    case "$_hst" in COMPLETED|FAILED)
        json_str id "$1" && pending_take "$_js" && [ "$_pp_s" = "$_hs" ] && _tk=1;;
    esac
    case "$_hst" in
        COMPLETED)
            # A typed passphrase only: the row's own PSK (a mirror connect) is already
            #   what the row gets, and an open row has none.
            if [ "$_tk" = 1 ] && [ "$_pp_k" = u ]; then
                learned_put "$_hs" "$_pp"
                log "psk: DomD joined $_hs; its passphrase is kept"
            fi
            [ "$_hs" = "$REJECT_SSID" ] && { REJECT_SSID=""; REJECT_PSK=""; }
            state_publish online "$_hs";;
        FAILED)
            state_publish offline "$_hs"
            case "$_her" in *WRONG_KEY*) _wk=1;; *) _wk=0;; esac
            if [ "$_wk" = 1 ] && [ "$_tk" = 1 ]; then
                REJECT_SSID=$_hs; REJECT_PSK=$_pp; REJECT_T=$SECONDS
                _lp=$(learned_psk_of "$_hs") && [ "$_lp" = "$_pp" ] && learned_del "$_hs"
            fi
            if pending_has "$_hs"; then
                log "state: DomD did not join $_hs with an earlier passphrase -- waiting for its answer to the later one"
                return 0
            fi
            # Only a row that is there: an SSID out of the list stays out. An open
            #   row (empty PSK) has no passphrase to undo.
            if [ "$_wk" = 1 ] && _rp=$(psk_of "$_hs" 2>/dev/null) && [ -n "$_rp" ]; then
                secured_psk_of "$_hs"
                # A seed PSK that WRONG_KEY names goes too (an answer that matches no
                #   connect names none).
                [ "$_tk" = 1 ] && [ "$_pp" = "$_sp" ] && { _sp=$PLACEHOLDER_PSK; _src=placeholder; }
                if [ "$_rp" != "$_sp" ]; then
                    set_row_psk "$_hs" "$_sp"
                    log "state: DomD did not accept the passphrase for $_hs -- its row is back to the $_src PSK"
                    state_restart
                    return 0
                fi
            fi
            state_sta
            if [ -n "$_sta" ] && [ "$_hs" = "$_sta" ]; then
                hold_add "$_hs"
                drop_row "$_hs" "DomD could not join it; not listed again for $FAIL_HOLD_S s"
            fi;;
        LOST)
            state_publish offline "$_hs"
            state_sta
            if [ -n "$_sta" ] && [ "$_hs" = "$_sta" ]; then
                hold_add "$_hs"
                drop_row "$_hs" "DomD lost it; not listed again until DomD has it back (at most $FAIL_HOLD_S s)"
            fi;;
        BACK)
            hold_del "$_hs" && log "state: DomD has $_hs back; it is listed again from the next publication"
            state_publish online "$_hs";;
    esac
}

# handle_psk <ssid> <psk> -- the user typed a passphrase; make it work.
#
# Order matters: hostapd must know the PSK BEFORE the app re-triggers the
# connect, or the retry fails the same way. DomD is told in parallel so the real
# association is under way while the local one completes.
handle_psk() {
    _s=$1; _p=$2
    # A PSK psk_valid refuses goes nowhere, neither into $APS nor to DomD, and
    #   the log names neither the value nor its length. NOR DOES AN EMPTY ONE: it
    #   would make the row open, a secured SSID's open shadow BSS is the dead end
    #   described at PLACEHOLDER_PSK, and DomaWifiRelay never sends one -- an open
    #   row comes only from DomD's "sec".
    if [ -z "${_p:-}" ] || ! psk_valid "$_p"; then
        log "WARNING: psk: PSK for $_s is empty, or not 8..63 bytes or 64 hex; dropped"
        return 0
    fi
    # The passphrase DomD has just rejected, asked for again (see REJECT_SSID).
    if [ "$_s" = "$REJECT_SSID" ] && [ "$_p" = "$REJECT_PSK" ] \
        && [ $((SECONDS-REJECT_T)) -lt "$FAIL_HOLD_S" ]; then
        log "psk: the passphrase DomD rejected for $_s came again -- dropped for $FAIL_HOLD_S s"
        return 0
    fi
    cur=$(psk_of "$_s" 2>/dev/null) || cur=""
    if [ "$cur" = "$_p" ]; then
        log "psk: $_s already current; only forwarding to DomD"
    else
        set_row_psk "$_s" "$_p"
        # If generating the conf failed, do not touch hostapd. `ctl.restart` is a
        #   SIGKILL, so dropping it while the old conf is still in place gains nothing
        #   and merely loses DomA's only way in.
        #   The connect forward below (handing the real PSK to DomD, the only route to
        #   the real AP) MUST still run even if this fails. Do not return here.
        if write_hostapd_conf; then
            restart_hostapd
        else
            log "WARNING: could not update hostapd.conf, so hostapd is not restarted (the connect is still forwarded)"
        fi
    fi
    # Do not write `A && log ... || log ...` (see log() at the top).
    # Into $LEARNED only once DomD reports COMPLETED for it (see handle_state).
    pending_add "$_s" "$_p" u
    if printf '{"t":"connect","id":"%s","ssid":"%s","psk":"%s"}\n' "$_pid" "$(json_esc "$_s")" "$(json_esc "$_p")" >&3; then
        pending_commit
        log "psk: forwarded connect($_s) to DomD"
        mirror_mark_write "$_s" "$_p"      # the mirror must not send this connect again
    else
        log "WARNING: could not write connect($_s) to $CHAN"
    fi
}

# --- boot-time mirror ------------------------------------------------------------------
# See the MIRROR_MARK block near the top for why this exists.
# mirror_mark_write <ssid> <psk> [<association>] -- the association, for an open row,
# goes into the first field as boot_id@association: an empty PSK field would vanish
# under IFS=TAB (tab is IFS whitespace, so `read` merges empty fields).
mirror_mark_write() {
    if printf '%s\t%s\t%s\n' "$BOOTID${3:+@$3}" "$1" "$2" > "$MIRROR_MARK.new" 2>/dev/null \
        && mv "$MIRROR_MARK.new" "$MIRROR_MARK" 2>/dev/null; then
        chmod 0600 "$MIRROR_MARK" 2>/dev/null
    else
        log "WARNING: cannot write $MIRROR_MARK (the mirror may forward again after a daemon restart)"
    fi
}

# mirror_marked <ssid> <psk> [<association>] -- was exactly this connect already
# forwarded this boot (or, given an association, for that association)?
mirror_marked() {
    [ -r "$MIRROR_MARK" ] || return 1
    _mb=""; _ms=""; _mp=""
    IFS="$TAB" read -r _mb _ms _mp < "$MIRROR_MARK" || return 1
    [ "$_mb" = "$BOOTID${3:+@$3}" ] && [ "$_ms" = "$1" ] && [ "$_mp" = "$2" ]
}

# The switch is re-read every MIRROR_PROP_TICKS passes of the main loop (15, about
# 30 s), not on every pass: getprop is an external command, 30-60 ms of CPU here.
MIRROR_PROP_TICKS=${MIRROR_PROP_TICKS:-15}
MIRROR_PROP_LEFT=0
MIRROR_PROP=""
mirror_station() {
    if [ "$MIRROR_PROP_LEFT" -le 0 ]; then
        MIRROR_PROP=$(getprop persist.vendor.doma.wifi_relay_mirror 2>/dev/null)
        MIRROR_PROP_LEFT=$MIRROR_PROP_TICKS
    fi
    MIRROR_PROP_LEFT=$((MIRROR_PROP_LEFT-1))
    [ "$MIRROR_PROP" != false ] || return 0
    [ -x "$IW" ] || return 0
    # Gate on the carrier bit before spawning iw: each iw is a fork and an nl80211
    # round trip, which is waste on every 2 s tick (with /system's iw it also logged
    # ~8 avc denials per exec and overran the audit rate limit on the board).
    # iw runs only while the station has carrier and the SSID is not yet known,
    # i.e. once per association.
    if [ -r "$STA_CARRIER" ] && ! sta_carrier_up; then
        STA_LAST_SSID=""
        return 0
    fi
    # ONE ASSOCIATION = ONE carrier_up_count. mac80211 raises carrier once per
    #   association (see stations_present) and the kernel counts every raise
    #   (carrier_up_count_show() in net/core/net-sysfs.c), so a change means a new
    #   association even when the 2 s tick missed the carrier drop in between (a quick
    #   switch to another shadow SSID, or a re-join of the same one). Builtin `read`, as
    #   in sta_carrier_up; unreadable reads empty, which behaves as before this count.
    _uc=""
    { IFS= read -r _uc < "$STA_UPCOUNT"; } 2>/dev/null
    [ -n "$STA_LAST_SSID" ] && [ "$_uc" = "$STA_LAST_UPC" ] && return 0
    _ss=$(sta_link_ssid)
    if [ -z "$_ss" ]; then
        # Not associated: re-arm so the NEXT association is a fresh event (roaming to
        # another shadow SSID, or the framework cycling Wi-Fi).
        STA_LAST_SSID=""
        return 0
    fi
    STA_LAST_SSID=$_ss
    STA_LAST_UPC=$_uc
    # The PSK of the BSS the station joined: from $LIVE, what hostapd beacons. $APS can
    # be ahead of it while a restart is deferred -- an open BSS still on the air while
    # its row already holds the placeholder, say -- and the station joined the beacon.
    # Without $LIVE (not written yet), $APS.
    # No BSS, no connect: there is no PSK to pair such a name with, and a connect with
    # an empty one would make DomD's agent replace its real network with an open one
    # of that name.
    if [ -r "$LIVE" ]; then
        _pk=$(live_psk_of "$_ss")
    else
        _pk=$(psk_of "$_ss" 2>/dev/null)
    fi || {
        log "mirror: station on $_ss, which hostapd does not beacon; not forwarding"
        return 0
    }
    if [ "$_pk" = "$PLACEHOLDER_PSK" ]; then
        log "mirror: station on $_ss but its BSS holds only the placeholder PSK; leaving it to the psk repair path"
        return 0
    fi
    # An empty $_pk is an open row of $APS: once per association (see MIRROR_MARK).
    #   The association is "c" and carrier_up_count, which survives a restart of this
    #   daemon; without that file, a count of this process's own detections, which
    #   does not -- a restart then forwards the current association once more.
    if [ -n "$_pk" ]; then
        _how=given; _as=""
    elif [ -n "$_uc" ]; then
        _how=none; _as=c$_uc
    else
        MIRROR_SEQ=$((MIRROR_SEQ+1))
        _how=none; _as=p$$-$MIRROR_SEQ
    fi
    if mirror_marked "$_ss" "$_pk" "$_as"; then
        if [ -n "$_as" ]; then
            log "mirror: station on $_ss; connect already forwarded for this association"
        else
            log "mirror: station on $_ss; this connect was the last one forwarded this boot"
        fi
        return 0
    fi
    # Do not fold this into `A && log ... || log ...` (see log() at the top).
    pending_add "$_ss" "$_pk" m
    if printf '{"t":"connect","id":"%s","ssid":"%s","psk":"%s"}\n' "$_pid" "$(json_esc "$_ss")" "$(json_esc "$_pk")" >&3; then
        pending_commit
        log "mirror: station associated with $_ss -> forwarded connect($_ss) to DomD (psk $_how)"
        mirror_mark_write "$_ss" "$_pk" "$_as"
    else
        log "WARNING: mirror: could not write connect($_ss) to $CHAN"
    fi
}

# --- main loop -----------------------------------------------------------------------
# 3<> so the same descriptor reads the agent's publications and writes the connect
# requests; virtio-serial is bidirectional on one node.
# DO NOT HANG `|| log FATAL` OFF `exec`. `exec` is a POSIX special builtin ("*=exec"
#   in mksh's external/mksh/src/funcs.c), and A FAILED REDIRECTION ONTO A SPECIAL
#   BUILTIN MAKES MKSH TERMINATE THE WHOLE SCRIPT (iosetup() failure in exec.c ->
#   errorfz() -> LERROR -> exit 1 for a non-interactive shell). In other words the
#   right-hand side of `||` never runs, and A MISCONFIGURED CHAN TURNS INTO THE
#   INSCRUTABLE SYMPTOM "restarting every 10 s without a single log line".
#   init then logs only `process with updatable components 'doma_wifi_relay'
#   exited 4 times in 4 minutes`. So TRY THE OPEN IN A SEPARATE PROCESS BEFORE
#   THE exec:
#   inside a subshell, even a special builtin's failure stays in the subshell.
if ! ( exec 3<> "$CHAN" ) 2>/dev/null; then
    log "FATAL: cannot open $CHAN read-write (check that it exists and whether it is an hvc or a vport node)"
    exit 1
fi
exec 3<> "$CHAN"

# RAW MODE. Without it BOTH directions break: DomD's publication and the connect
# requests this script sends. Established on the board 2026-09-22.
#
#   $CHAN is a virtconsole port, so Linux attaches a TTY to the hvc node, and a TTY
#   defaults to cooked with ECHO on:
#     (1) ECHO   the JSON DomD writes becomes input to the TTY and is echoed straight
#                back out to DomD. The agent then reads its own aps message, cut at
#                whatever TTY buffer boundary it hit, and says so every time:
#                  domd-wifi-agent: ignoring malformed line:
#                    b'{"t": "aps", "v": [{"ssid": "<SSID-WPA3>", ... "dbm": -43},'
#                The echo also occupies the line, so the agent's own writes back up:
#                  domd-wifi-agent: channel write failed (timed out); reconnecting
#                and OUR connect requests never reach it. The DomA side reports
#                  psk: forwarded connect(<SSID-B>) to DomD
#                while on the DomD side `wpa_cli list_networks` is empty and
#                wpa_state stays INACTIVE -- i.e. the AP list is right and the guest
#                still cannot get out.
#     (2) onlcr  LF on output becomes CRLF, which dirties the newline framing of the
#                newline-delimited JSON.
#     (3) icrnl  CR on input becomes LF. Together with (2) a line splits twice.
#     (4) icanon line editing is on, so ^C/^D/^U are interpreted as data. They do not
#                appear in the JSON, but they can appear in a PSK.
#
#   Applied to fd 3, NOT to the path. `stty -F "$CHAN"` works too, but that opens the
#   node a second time, and termios resets to the default on the last close -- which
#   produces the confusing state where typing stty by hand fixes it and the service
#   reopening the node breaks it again. Applied to fd 3 the setting lives as long as
#   the fd does.
#   NOT fatal. On a system without a working stty the JSON still flows (badly), and
#   exiting here would take DomA's Wi-Fi away entirely. Warn and carry on.
if stty raw -echo <&3 2>/dev/null; then
    log "chan: $CHAN set to raw/-echo"
else
    log "WARNING: chan: $CHAN could not be set raw; expect 'ignoring malformed line' and 'channel write failed' on the DomD side, and connect requests may not arrive"
fi

# END WHATEVER THE ECHO LEFT ON THE OTHER SIDE. Between the `exec 3<>` above and the
# stty, the TTY is still cooked with ECHO on, and the node has had no reader until
# this script opened it, so DomD's publications have queued up and part of them is
# echoed straight back. That fragment has no newline of its own: it waits in the
# agent's receive buffer and corrupts the next line that arrives. Measured on RPi4
# 2026-09-23 -- the session's one connect request reached DomD as
#     domd-wifi-agent: ignoring malformed line: b'{{"t":"connect",...}'
# DomD never associated, and DomA had Wi-Fi with no Internet. One newline ends
# the fragment as a line of its own, which the agent drops, so the first real
# request arrives clean. (The agent also recovers a message from behind such a
# fragment; this keeps the channel clean for an agent that does not.)
printf '\n' >&3 2>/dev/null || log "WARNING: chan: could not write the flushing newline to $CHAN"

log "started (chan=$CHAN aps=$APS req=$REQ)"
state_publish up

# Buffer that carries an incomplete line over. Details in the else branch below.
LINEBUF=""
# The last sta_is_up() answer, so the log line appears on a change only.
WIFI_UP_LAST=""
while :; do
    # 2 s so a request file dropped by the app is picked up promptly; the agent
    # publishes every 20 s so nothing is lost by not blocking on it.
    line=""
    if read -t 2 -r line <&3 2>/dev/null; then
        # Re-attach the incomplete part from the previous pass at the front
        line=$LINEBUF$line; LINEBUF=""
        # See LINE_MAX. The agent sends ~3 KiB at most, so this is a broken producer.
        if [ ${#line} -gt "$LINE_MAX" ]; then
            log "WARNING: dropping a ${#line}-character line from $CHAN (more than LINE_MAX)"
            line=""
        fi
        # DISPATCH ON THE PARSED VALUE, NOT A SUBSTRING. The producer is
        # json.dumps() (main() in domd_wifi_agent.py), whose default separators
        # are (', ', ': '), so the wire format is {"t": "aps", "v": [...]} --
        # with a space after every colon -- and a pattern such as *'"t":"aps"'*
        # never matches it. This sed and the ssid extraction in handle_aps both
        # allow [[:space:]]* around the colon.
        msg_type "$line"      # sets _t; in the shell, see msg_type
        case "$_t" in
            # NOT WHILE doma_shadow_ap IS STILL RUNNING. init starts this daemon right
            # after it, and the publications DomD queued while nothing read $CHAN arrive
            # at once: handle_aps would then write $APS and hostapd.conf under the
            # oneshot's seed merge, and its restart would race the oneshot's ctl.start
            # (the flush below defers for the same reason). The next publication
            # is at most 20 s away.
            aps)   if [ "$(getprop init.svc.vendor.doma_shadow_ap 2>/dev/null)" = running ]; then
                       log "aps: doma_shadow_ap is still bringing the shadow AP up -- skipping this publication"
                   else
                       handle_aps "$line"
                   fi;;
            # A line the agent cut part-way (a write that timed out, then sent again)
            #   arrives glued to the front of the next one: every message starts with
            #   {"t", so the state is read from the last.
            state) log "state: $line"
                   case "$line" in *'{"t"'*'{"t"'*) line='{"t"'${line##*'{"t"'};; esac
                   handle_state "$line";;
            '')    [ -z "$line" ] || log "ignoring: $(printf '%s' "$line" | cut -c1-120)";;
            *)     log "ignoring type $_t";;
        esac
    else
        # EVEN ON TIMEOUT, `read` LEAVES WHAT IT MANAGED TO READ IN THE VARIABLE (both
        #   bash and mksh do). Discarding it here would LOSE A WHOLE PUBLICATION, with
        #   the remainder surfacing on the next pass as `ignoring: <fragment>`. DomD on
        #   the device emits one line of up to ~3 KiB (20 SSIDs) every 20 s, so this
        #   can happen any time a line straddles the 2 s window.
        #   Reproduced on the PC under mksh (not under bash): a publication cut
        #   by the timeout surfaced as `ignoring: <fragment>` and lost its
        #   SSIDs. => Carry it over and concatenate with the next read.
        if [ -n "${line:-}" ]; then
            LINEBUF=$LINEBUF$line
            # Do not grow without bound for a broken producer that emits no newline
            if [ ${#LINEBUF} -gt "$LINE_MAX" ]; then
                log "WARNING: the incomplete line exceeded LINE_MAX, discarding it (the producer is not emitting newlines)"
                LINEBUF=""
            fi
        fi
    fi

    if sta_is_up; then _up=1; else _up=0; fi
    if [ "$_up" != "$WIFI_UP_LAST" ]; then
        if [ "$_up" = 1 ]; then
            log "wifi: $STA_IF is up (Settings toggle on) -- relaying to DomD"
        else
            log "wifi: $STA_IF is down (Settings toggle off) -- holding PSK requests; the AP list keeps syncing"
        fi
        WIFI_UP_LAST=$_up
    fi

    # A request stays in place while the toggle is off, and one left from the previous
    # boot waits for doma_shadow_ap to finish, as the publications above do: until then
    # wlan0 may not exist, so sta_is_up cannot tell, and handle_psk's restart would race
    # the oneshot's.
    if [ "$_up" = 1 ] && [ -s "$REQ" ] && [ "$(getprop init.svc.vendor.doma_shadow_ap 2>/dev/null)" != running ]; then
        # Move before reading so a request cannot be handled twice if hostapd's
        # restart takes longer than the poll interval.
        mv "$REQ" "$REQ.busy" 2>/dev/null || continue
        while IFS="$TAB" read -r verb a b; do
            case "$verb" in
                psk) [ -n "${a:-}" ] && handle_psk "$a" "${b:-}";;
                '')  ;;
                *)   log "unknown request verb: $verb";;
            esac
        done < "$REQ.busy"
        rm -f "$REQ.busy"
    fi

    mirror_station
    flush_pending_restart
    [ "$STATE_RESTART" = 1 ] && state_restart
done
