#!/vendor/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Give AAOS a Wi-Fi station that can see and join REAL access points, by simulating the
# radios locally and beaconing the SSIDs DomD actually sees.
#
# WHY THIS EXISTS
# virt_wifi, the Wi-Fi the upstream product sets up, is an L2 shim over an
# ethernet link that synthesises exactly one fake network called "VirtWifi". It
# has no radio and cannot scan, so the Settings Wi-Fi screen can never list real
# APs with it. The board's real radio is not passed to this guest either: DomA's
# devices are qemu device models, so DomD drives the radio and this guest
# simulates its own.
#
# What is left is to simulate: mac80211_hwsim gives this kernel several radios on one
# in-kernel "perfect channel medium". wlan0 becomes the station AAOS uses; a further
# radio runs hostapd beaconing SSIDs copied from DomD's real scan. The user picks a
# genuine SSID on screen, and traffic leaves through DomD's real Wi-Fi.
#
# WHICH INTERFACE FOR WHAT, AND WHY IT MATTERS
#   wlan0  station. Fixed by the property wifi.interface=wlan0.
#   wlan1  LEFT ALONE. Android's SoftAp claims this name: the board sets
#          WIFI_HAL_INTERFACE_COMBINATIONS={{{STA},1},{{AP},1},{{P2P},1}}, so STA+AP
#          concurrency is allowed and wifi_chip.cpp's startIdxOfApIface() returns 1. No
#          ro.vendor.wifi.sap.interface is set anywhere to move it.
#   wlan2+ our shadow APs. Invisible to the vendor HAL, which does not enumerate wiphys
#          at all -- device/generic/goldfish/wifi/wifi_hal/info.cpp stats a hardcoded
#          {"wlan0","wlan1"} against /sys/class/net. wificond is name-driven too.
#
# STARTED AUTOMATICALLY AT BOOT. init.xenvm-hwsim.rc carries
#     on property:sys.boot_completed=1
#         start vendor.doma_shadow_ap
# and the service line says `disabled`, which only means init will not start it
# with its class -- that property trigger is what starts it.
#
# Manual control still works and is the right tool when debugging:
#     stop vendor.doma_shadow_ap ; start vendor.doma_shadow_ap
# and `setprop persist.vendor.doma.shadow_ap false` hands wlan0 back to virt_wifi (see
# the check further down). Taking wlan0 away from virt_wifi remains a one-way step for
# an already-running system, which is why that escape hatch exists.
#
# THE AP LIST IS AN INPUT, NOT A CONSTANT
# /data/vendor/wifi/shadow/aps.conf holds one AP per line:
#     <SSID>TAB<PSK>        PSK empty -> the shadow AP is open
# doma-wifi-relay keeps it in sync with DomD's scan; this script only merges the
# shipped seed's rows into it (the committed seed has none) and, while it has no
# usable row, beacons one hidden idle BSS instead (step 3).
set -u
# /vendor's tools only. init's default PATH puts /system/bin first, and this runs in a
# vendor domain, which may not execute /system's programs (a neverallow), so a bare
# `ls` or `brctl` would resolve to one it cannot run. DOMA_PATH is for the PC tests.
PATH=${DOMA_PATH:-/vendor/bin:/vendor/xbin}
export PATH

TAG=doma-shadow-ap
# Android's logger binary is also called `log`, so it must be called by absolute path:
# a bare `log` inside a function named log() recurses until the shell dies.
# THE TRAILING `:` IS MANDATORY. Without it, LOG()'S EXIT STATUS IS THAT OF
#   /vendor/bin/log, which turns the `A && log ... || die ...` idiom into "A
#   succeeded, yet die fired" (log normally succeeds, but if it fails you get a bogus
#   FATAL).
log() { echo "$TAG: $*"; /vendor/bin/log -t "$TAG" "$*" 2>/dev/null; :; }

RADIOS=${RADIOS:-3}                       # wlan0 station + wlan1 (SoftAp) + wlan2 shadow
MAC_PREFIX=${MAC_PREFIX:-$(getprop ro.boot.wifi_mac_prefix)}
[ -n "$MAC_PREFIX" ] || MAC_PREFIX=5554   # BoardConfig.mk sets this; default matches it
AP_IF=${AP_IF:-wlan2}
UPLINK_IF=${UPLINK_IF:-eth1}              # the vif bridged to DomD's xenbr0
BR=${BR:-br-shadow}
CONF_DIR=/data/vendor/wifi/shadow
APS=$CONF_DIR/aps.conf
# Shipped seed for $APS. The committed one carries no row, only its header; a
# build may list APs in it that must be beaconed before DomD's first scan
# arrives. With no row at all, step 3 beacons one hidden idle BSS.
SEED=${SEED:-/vendor/etc/doma-shadow-aps.conf}
# The same two values as in doma-wifi-relay.sh, whose comments say what they are
# for: the hidden idle BSS step 3 writes when $APS has no usable row is WPA2 with
# the relay's placeholder passphrase.
PLACEHOLDER_PSK=${PLACEHOLDER_PSK:-doma-relay-unprovisioned-0000}
IDLE_SSID=${IDLE_SSID:-doma-shadow-idle}
HOSTAPD=/apex/com.google.cf.wpa_supplicant/bin/hw/hostapd
CREATE_RADIOS=/apex/com.google.cf.wifi/bin/mac80211_create_radios
# Every tool comes from /vendor (toybox_vendor's brctl and ifconfig) or from
# cuttlefish's apexes (com.google.cf.wifi has rename_netiface): this runs in a vendor domain, which may
# not execute /system's ip, iw or toybox (a neverallow), and as uid wifi with only
# NET_ADMIN and NET_RAW (init.xenvm-hwsim.rc).
RENAME=/apex/com.google.cf.wifi/bin/rename_netiface

die() { log "FATAL: $*"; exit 1; }

# byte_len <s> -- sets _bl to the BYTE count of <s> without a fork. mksh's ${#s}
# counts characters only in its UTF-8 mode (set -U) and bytes otherwise, so the
# mode is turned off for the count and back on if it was on. A fork per row
# (printf | wc) cost DomA about 1 s of CPU per scan publication, enough to stall
# video playback (RPi4 2026-10-26).
byte_len() {
    case $- in *U*) set +U; _bl=${#1}; set -U;; *) _bl=${#1};; esac
}

# ssid_hostapd_safe / psk_is_hex / psk_valid -- the same functions as in
# doma-wifi-relay.sh, which writes hostapd.conf at runtime by the same rules;
# the comments there say why each rule exists.
ssid_hostapd_safe() {
    case "$1" in ''|*\\*) return 1;; esac
    byte_len "$1"; [ "$_bl" -le 32 ]
}
psk_is_hex() {
    case "$1" in ''|*[!0-9A-Fa-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}
psk_valid() {
    psk_is_hex "$1" && return 0
    byte_len "$1"; _n=$_bl
    [ "$_n" -ge 8 ] && [ "$_n" -le 63 ]
}

# --- 0. which implementation owns wlan0 this boot ------------------------------------
# ONE OWNER PER BOOT, CHOSEN BY A PROPERTY.
#
# virt_wifi and the shadow AP must never both own wlan0, so the owner is chosen
# here, before anything is touched.
#
# WHY A PROPERTY AND NOT AN IN-SCRIPT FALLBACK. The failure that matters most is
# one no error handler in here can see: this script exits 0, hostapd is up, and
# the FRAMEWORK still cannot scan or connect. Worse, a handler could not recover
# even from the failures it can see: wlan0 is deleted in step 1 and the hwsim
# radios take the name immediately after, and mac80211_create_radios has no
# destroy mode, so setup_wifi could not create its virt_wifi wlan0 afterwards.
# Selecting the owner BEFORE anything is touched, and recovering by reboot, is
# the only shape that covers both.
#
# RECOVERY ON HARDWARE, with no SD rewrite:
#     setprop persist.vendor.doma.shadow_ap false && reboot
# which hands wlan0 back to virt_wifi.
#
# getprop's second argument is the default, so the property does not have to exist in
# build.prop for this to read `true`.
if [ "$(getprop persist.vendor.doma.shadow_ap true)" != "true" ]; then
    log "persist.vendor.doma.shadow_ap is not true -- handing wlan0 to virt_wifi"
    # exec, not a background start: this service is `oneshot`, so init waits for it, and
    # setup_wifi is itself a oneshot that exits. It runs in setup_wifi's domain (the
    # transition is in sepolicy/doma_shadow_ap.te) as this service's uid wifi with
    # NET_ADMIN and NET_RAW, where cuttlefish's own setup_wifi service runs as root:
    # it renames a link and creates virt_wifi, and needs no module loaded (first-stage
    # init loads virt_wifi). Not yet run this way on a board.
    #
    # TIMING: setup_wifi renames eth1 with SIOCSIFNAME, which needs the
    # interface administratively down. This runs at sys.boot_completed, and
    # EthernetService was measured claiming eth0 at about 200 s (see
    # init.xenvm-buried-eth0.rc), well after that.
    exec /apex/com.google.cf.wifi/bin/setup_wifi --interface="$UPLINK_IF"
fi

# --- preconditions -----------------------------------------------------------------
# The modules are in vendor_ramdisk/lib/modules/modules.load, so first-stage init has
# already loaded them.
[ -d /sys/module/mac80211_hwsim ] || die "mac80211_hwsim is not loaded (is it in _VIRT_COMMON_MODULES?)"
[ -x "$CREATE_RADIOS" ] || die "$CREATE_RADIOS missing (com.google.cf.wifi apex?)"
[ -x "$HOSTAPD" ]       || die "$HOSTAPD missing (com.google.cf.wpa_supplicant apex?)"
[ -x "$RENAME" ]        || die "$RENAME missing (is the com.google.cf.wifi apex mounted?)"

# rename_back -- buried_$UPLINK_IF -> $UPLINK_IF (SIOCSIFNAME needs the link down).
rename_back() {
    ifconfig "buried_$UPLINK_IF" down 2>/dev/null
    "$RENAME" "buried_$UPLINK_IF" "$UPLINK_IF" \
        || { log "WARNING: could not rename buried_$UPLINK_IF; the bridge will have no uplink"; return 1; }
    ifconfig "$UPLINK_IF" up 2>/dev/null
}

# --- 1. wlan0 must not be virt_wifi's -----------------------------------------------
# setup_wifi (the fallback above) creates a virt_wifi wlan0 on top of a buried
# ethernet link. Both providers want the name, and whoever created it first holds it.
# Nothing in /vendor can delete a link, so a boot where the fallback ran first (the
# property switched back to true without a reboot) stops here; a reboot hands wlan0 to
# the shadow AP.
if [ -e /sys/class/net/wlan0 ] && [ -e /sys/class/net/wlan0/lower_buried_eth1 ]; then
    die "virt_wifi owns wlan0 this boot (setup_wifi ran); reboot to give it to the shadow AP"
fi
# AND RENAME THE LOWER INTERFACE BACK if a setup_wifi that ran first renamed eth1 to
# buried_eth1 and then made no wlan0 on it (with a wlan0, the check above has stopped
# the script). Step 4 would otherwise find no $UPLINK_IF, log "WARNING: eth1 absent;
# not enslaving", and bring br-shadow up with NO UPLINK -- the station associates to
# the shadow AP and never gets a DHCP lease, with nothing in the log pointing at the
# cause. A normal boot never needs this: nothing runs setup_wifi before this script.
if [ ! -e "/sys/class/net/$UPLINK_IF" ] && [ -e "/sys/class/net/buried_$UPLINK_IF" ]; then
    log "renaming buried_$UPLINK_IF back to $UPLINK_IF"
    rename_back
fi

# --- 2. simulated radios ------------------------------------------------------------
# The module is loaded with radios=0 (BOARD_KERNEL_CMDLINE carries
# mac80211_hwsim.radios=0) precisely so the count can be chosen here.
# The last radio's netdev, not a count of /sys/class/ieee80211/phy*: that directory is
# plain sysfs, which this domain may not list, so a count would always be 0 and a
# restart of this service would add radios (hwsim radios cannot be removed here).
if [ ! -e "/sys/class/net/$AP_IF" ]; then
    log "creating $RADIOS radios (mac prefix $MAC_PREFIX)"
    "$CREATE_RADIOS" --enable-pmsr "$RADIOS" "$MAC_PREFIX" || die "mac80211_create_radios failed"
else
    log "$AP_IF present; not creating more radios"
fi
for i in 0 1 2 3 4 5 6 7 8 9; do
    [ -e "/sys/class/net/$AP_IF" ] && break
    sleep 1
done
[ -e "/sys/class/net/$AP_IF" ] || die "$AP_IF never appeared after creating $RADIOS radios"

# --- 3. hostapd config from the AP list ---------------------------------------------
mkdir -p "$CONF_DIR" "$CONF_DIR/sockets" 2>/dev/null
# CONF_DIR must be 0771. The sys.boot_completed block of init.xenvm-hwsim.rc
#   sets 0771 on /data/vendor/wifi{,/shadow} right before
#   `start vendor.doma_shadow_ap`, so that DomaWifiRelay (uid system) can reach its
#   request drop-box, and a 0770 here would undo that on every boot (confirmed
#   on hardware).
#   o+x only; neither r nor w is granted. sockets/ stays 0770.
chmod 0771 "$CONF_DIR" 2>/dev/null
chmod 0770 "$CONF_DIR/sockets" 2>/dev/null
# A temporary file a run as root (before these services ran as uid wifi) left behind,
#   root 0600, would make every later write of that name fail: this uid cannot
#   truncate it, but the directory lets it remove it. The relay starts after this.
rm -f "$CONF_DIR"/*.new 2>/dev/null
# Seed $APS on first run, then MERGE the seed on every later run: add only the
# seed SSIDs $APS does not have and leave every existing row alone, so a PSK the
# user typed on screen is never reverted to the seed's value. $APS is where
# credentials live, not a cache: the merge brings a seed row back if $APS is
# lost, and doma-wifi-relay's seed_psk_of() keeps a publication from writing a
# placeholder over a seeded SSID. The merge skips `#` lines, so $APS carries
# data rows only (psk_of() and the two hostapd.conf generators ignore `#` lines
# anyway). If $APS cannot be written and is still empty, _seeded stays 0 and
# step 3 writes the hidden idle BSS.
if [ -s "$SEED" ]; then
    _seeded=0
    # DO NOT PRE-CREATE $APS. `:` is a POSIX special builtin in mksh
    #   ("*=:" in external/mksh/src/funcs.c), and A FAILED REDIRECTION ONTO A
    #   SPECIAL BUILTIN MAKES MKSH TERMINATE THE WHOLE SCRIPT (iosetup() failure in
    #   exec.c -> errorfz() -> LERROR -> exit 1 for a non-interactive shell). On top
    #   of that, `2>/dev/null` swallows the diagnostic too, so a missing $CONF_DIR
    #   alone would make us DIE SILENTLY HERE AT BOOT, never reaching hostapd.conf
    #   generation, br-shadow creation or the hostapd start.
    #   The existence-check loop below uses `done < "$APS"` (a redirection onto a
    #   compound command), so a missing $APS is not fatal there, and the appending
    #   `>>` creates the file when it is needed.
    # KEEP THE `|| [ -n "$_line" ]`. The seed is a hand-edited file, and IF THE LAST
    #   LINE HAS NO NEWLINE, read DROPS THAT LAST LINE, and that line could be
    #   the seed's only data row.
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|'#'*) continue;; esac
        _ss=${_line%%	*}
        [ -n "$_ss" ] || continue
        # If it is already there, leave it alone.
        #
        # DO NOT USE grep. With `grep -q "^$_ss<TAB>"` THE SSID IS INTERPRETED AS A
        #   BRE, so an SSID containing `.`, `[` or `*` matches the wrong row (for
        #   example a seed `A.B` matching an existing `AXB`, so the seed row
        #   never gets added). Use the same "read line by line and compare
        #   as strings" approach as psk_of(). A partial match (a shorter
        #   `<SSID-PREFIX>` masking `<SSID-A>`) is then also ruled out naturally by
        #   the field boundary.
        _have=0
        # GUARD IT WITH `[ -s "$APS" ]`. On a first boot ($APS absent),
        #   `done < "$APS"` prints `cannot open` on stderr ONCE PER SEED ROW. The
        #   script does not die, because while is not a special builtin in mksh (and
        #   the behaviour is still correct, since `>>` creates the file), but there is
        #   no reason to pollute the log with a harmless diagnostic on every boot. The
        #   decision "absent => _have=0" is correct as is: just append.
        if [ -s "$APS" ]; then
            while IFS="$(printf '\t')" read -r _k _rest; do
                [ "$_k" = "$_ss" ] && { _have=1; break; }
            done < "$APS"
        fi
        if [ "$_have" = 0 ]; then
            printf '%s\n' "$_line" >> "$APS" && _seeded=$((_seeded+1))
        fi
    done < "$SEED"
    chmod 0660 "$APS" 2>/dev/null
    # '^[^#]' and not a BRE alternation: toybox grep is what runs here and
    # GNU's \| is not portable to it. An empty line has no character to
    # match [^#], so blanks are excluded for free.
    # DO NOT WRITE `A && log ... || log ...`. log() ends with `:` today, but
    #   without that its exit status would be /vendor/bin/log's, and if the
    #   logger failed BOTH branches would print. Do not add an instance of the
    #   trap.
    if [ "$_seeded" -gt 0 ]; then
        log "merged $_seeded AP(s) from $SEED into $APS (now $(grep -c '^[^#]' "$APS") AP(s))"
    elif [ -s "$APS" ]; then
        log "$APS already carries every seed AP ($(grep -c '^[^#]' "$APS") AP(s))"
    fi
fi
# AN EMPTY LIST IS NOT FATAL. The committed seed has no row, so on a first boot $APS
#   is empty until doma-wifi-relay syncs DomD's first scan (~20 s), and the generator
#   below then writes the hidden idle BSS instead. Create the file anyway: the relay's
#   PSK repair rewrites $APS with awk, which writes nothing when the file is missing.
#   In a subshell, because `:` is a special builtin (see the merge above).
if [ ! -e "$APS" ]; then
    ( : > "$APS" ) 2>/dev/null || log "WARNING: cannot create $APS"
    chmod 0660 "$APS" 2>/dev/null
fi
[ -s "$APS" ] || log "$APS has no AP yet -- only the hidden idle BSS until doma-wifi-relay syncs DomD's scan"

CONF=$CONF_DIR/hostapd.conf
{
    echo "interface=$AP_IF"
    echo "bridge=$BR"
    echo "driver=nl80211"
    echo "ctrl_interface=$CONF_DIR/sockets"
    echo "hw_mode=g"
    echo "channel=6"
    echo "ieee80211n=1"
    # First line of aps.conf is the primary BSS; any further lines become bss= stanzas.
    #
    # EMIT `bridge=` IN EVERY BSS STANZA.
    #   hostapd's hostapd_config_bss() does not copy the preceding BSS's `bridge`, so
    #   writing it once at the top means EVERY BSS AFTER THE FIRST COMES UP WITH NO
    #   BRIDGE.
    #   PRIMARY SOURCES (the apex is not a prebuilt, it is built from this tree:
    #   device/google/cuttlefish/apex/com.google.cf.wpa_supplicant/Android.bp:28-29):
    #     external/wpa_supplicant_8/hostapd/config_file.c:2240-2241
    #         os_strlcpy(bss->bridge, ...) -- so bridge IS A PER-BSS FIELD
    #     same file :871-906, hostapd_config_bss() only does os_zalloc +
    #         defaults_bss + copying iface/vlan, AND DOES NOT COPY bridge
    #     src/ap/hostapd.c:1510 passes conf->bridge[0] ? conf->bridge : NULL, and
    #     the `bridge &&` at src/drivers/driver_nl80211.c:9706 is the gate
    #   THE MECHANISM (source) AND THE DAMAGE (measurement below) ARE SEPARATE PIECES
    #   OF EVIDENCE; read them as such.
    #   Damage (measured): when the order in aps.conf changed and the seed SSID
    #   (<SSID-A>) ended up sixth, DomA's own station got as far as association
    #   (COMPLETED / RSSI -30) but GOT NO IP (DHCP never completes, because nothing
    #   reaches DomD's dnsmasq via br-shadow -> eth1). Moving it back to the front
    #   gave wlan0 192.168.10.134/24.
    #   => Emit bridge explicitly in each BSS so nothing depends on the ordering.
    first=1
    idx=0
    # `|| [ -n "$ssid" ]`: a hand-edited last line without a newline still counts
    #   (doma-wifi-relay.sh reads it the same way).
    while IFS="$(printf '\t')" read -r ssid psk || [ -n "${ssid:-}" ]; do
        case "$ssid" in ''|'#'*) continue;; esac
        # Skip what hostapd would reject, by the same rules doma-wifi-relay.sh
        # applies when it writes this file at runtime: ONE bad row makes hostapd
        # refuse the entire file. log() writes to stdout, which is $CONF here,
        # so send it to stderr.
        if ! ssid_hostapd_safe "$ssid"; then
            log "skip SSID hostapd would reject: $ssid" >&2
            continue
        fi
        if [ -n "${psk:-}" ] && ! psk_valid "$psk"; then
            log "skip $ssid: PSK neither 8..63 bytes nor 64 hex" >&2
            continue
        fi
        if [ "$first" = 1 ]; then
            first=0
        else
            idx=$((idx+1))
            echo "bss=${AP_IF}_$idx"
            echo "bridge=$BR"
        fi
        echo "ssid=$ssid"
        if [ -n "${psk:-}" ]; then
            echo "wpa=2"
            echo "wpa_key_mgmt=WPA-PSK"
            echo "rsn_pairwise=CCMP"
            if psk_is_hex "$psk"; then
                echo "wpa_psk=$psk"
            else
                echo "wpa_passphrase=$psk"
            fi
        else
            echo "wpa=0"
        fi
    done < "$APS"
    # No usable row: the hidden idle BSS, as in doma-wifi-relay.sh (see IDLE_SSID
    # there).
    if [ "$first" = 1 ]; then
        log "no usable row in $APS; only the hidden idle BSS" >&2
        echo "ssid=$IDLE_SSID"
        echo "ignore_broadcast_ssid=1"
        echo "wpa=2"
        echo "wpa_key_mgmt=WPA-PSK"
        echo "rsn_pairwise=CCMP"
        echo "wpa_passphrase=$PLACEHOLDER_PSK"
    fi
} > "$CONF"
log "wrote $CONF ($(grep -c '^ssid=' "$CONF") SSID(s))"

# hostapd reads it as uid wifi, the uid this script runs as; $CONF holds a
# wpa_passphrase, so it must not be left readable more widely.
chmod 0660 "$CONF" 2>/dev/null || log "WARNING: chmod $CONF failed"

# --- 4. uplink bridge ----------------------------------------------------------------
# The AP side has to reach DomD. eth1 is this guest's second vif and is already on DomD's
# xenbr0, so bridging the two puts the station on the same L2 as DomD's dnsmasq: wlan0
# gets a lease and leaves through DomD's NAT. eth1 stops being an Android "Ethernet"
# network when it becomes a bridge port -- that is intended, the whole point is that
# connectivity now arrives over Wi-Fi.
if [ ! -e "/sys/class/net/$BR" ]; then
    brctl addbr "$BR" || die "cannot create $BR"
fi
ifconfig "$BR" up
# WAIT FOR THE UPLINK. This oneshot runs at sys.boot_completed and normally
# finds eth1 registered long before (init's `wait for /sys/class/net/eth1` fires
# at ~27 s), but br-shadow has come up on the board with eth1 NOT a port, and
# only `stop vendor.doma_shadow_ap; start vendor.doma_shadow_ap` repaired it.
# A vif that shows up late, or one still called buried_eth1 (see step 1), must not end
# as a one-line "WARNING: eth1 absent; not enslaving": that state has no DHCP for the
# station and nothing in the UI says why. Poll up to UPLINK_WAIT_S, then say so loudly.
UPLINK_WAIT_S=${UPLINK_WAIT_S:-20}
_w=0
while [ ! -e "/sys/class/net/$UPLINK_IF" ] && [ "$_w" -lt "$UPLINK_WAIT_S" ]; do
    if [ -e "/sys/class/net/buried_$UPLINK_IF" ]; then
        log "renaming buried_$UPLINK_IF back to $UPLINK_IF (late)"
        rename_back
        break
    fi
    [ "$_w" = 0 ] && log "$UPLINK_IF not present yet; waiting up to ${UPLINK_WAIT_S}s"
    sleep 1
    _w=$((_w+1))
done
[ -e "/sys/class/net/$UPLINK_IF" ] \
    || log "ERROR: $UPLINK_IF did not appear within ${UPLINK_WAIT_S}s -- $BR will have NO UPLINK (the station gets no DHCP lease). Recover: stop vendor.doma_shadow_ap; start vendor.doma_shadow_ap"
for p in "$AP_IF" "$UPLINK_IF"; do
    [ -e "/sys/class/net/$p" ] || { log "WARNING: $p absent; not enslaving"; continue; }
    [ -e "/sys/class/net/$p/master" ] && continue
    ifconfig "$p" down 2>/dev/null
    brctl addif "$BR" "$p" && log "$p -> $BR"
    ifconfig "$p" up
done
# Say plainly whether the uplink made it; this is the line to look for in
# `logcat -s doma-shadow-ap` when wlan0 associates but never gets an address.
if [ -e "/sys/class/net/$UPLINK_IF/master" ]; then
    log "$BR uplink OK ($UPLINK_IF is a port)"
else
    log "ERROR: $UPLINK_IF is NOT a port of $BR after step 4 -- the station will get no DHCP lease"
fi

# --- 5. hostapd ----------------------------------------------------------------------
# A distinct process name on purpose: the service name `hostapd` and the AIDL name
# android.hardware.wifi.hostapd.IHostapd/default belong to the apex's own SoftAp service
# (com.google.cf.wpa_supplicant.rc), which the framework starts on demand. This one is
# ours and must not collide with it.
# START IT AS AN INIT SERVICE. DO NOT EXEC IT WITH -B FROM HERE.
#
# This service is `oneshot`, so the moment this script exits init SIGKILLs the
# whole process group, as the board's dmesg shows:
#     init: Service 'doma_shadow_ap' (pid 1567) exited with status 0 oneshot ...
#     init: Sending SIGKILL to service 'doma_shadow_ap' (pid 1567) process group...
# A -B daemon stays in that group and dies with it. Handing it to init instead
# means it survives, and init restarts it if it crashes.
#
# vendor.doma_shadow_hostapd is defined in init.xenvm-hwsim.rc and is NOT oneshot.
HOSTAPD_SVC=${HOSTAPD_SVC:-vendor.doma_shadow_hostapd}
# init.svc.$HOSTAPD_SVC, not pidof: under enforcing this domain cannot read the other
# domains' /proc entries, and pidof would not tell this hostapd from the platform's
# SoftAp one either.
setprop ctl.stop "$HOSTAPD_SVC" 2>/dev/null || true
setprop ctl.start "$HOSTAPD_SVC" \
    || log "WARNING: ctl.start $HOSTAPD_SVC failed (the rc has no such service)"

i=0
while [ $i -lt 20 ]; do
    [ "$(getprop "init.svc.$HOSTAPD_SVC" 2>/dev/null)" = running ] && break
    sleep 0.5
    i=$((i+1))
done
# DO NOT WRITE `A && log ... || die ...` (see the note on log() at the top).
#   log() ends with `:` so its exit status is 0, but the idiom invites the next
#   editor to reintroduce the trap.
if [ "$(getprop "init.svc.$HOSTAPD_SVC" 2>/dev/null)" = running ]; then
    log "hostapd up on $AP_IF (bridge $BR) as init service $HOSTAPD_SVC"
    # What hostapd now beacons, for doma-wifi-relay (LIVE there): its mirror reads
    # the BSS the station joined from this copy, not from a $CONF that may be ahead.
    cp "$CONF" "$CONF.live.new" 2>/dev/null && chmod 0600 "$CONF.live.new" 2>/dev/null \
        && mv -f "$CONF.live.new" "$CONF.live" 2>/dev/null \
        || log "WARNING: cannot write $CONF.live"
else
    die "hostapd did not come up; check that the apex path in the service line exists and see logcat -s doma-shadow-ap, $CONF"
fi

# --- 6. make the Wi-Fi HAL re-enumerate the radios -----------------------------------
# The goldfish HAL lists wlan0/wlan1 once, when the framework starts it
# (device/generic/goldfish/wifi/wifi_hal/info.cpp:23-37), and those radios exist only
# from step 1 of this script. With Wi-Fi saved ON the framework starts the HAL at
# system-services-ready, always before this script, and then holds a stale radio list.
#
# Moving this service to an earlier trigger is not the fix: the fallback path execs
# setup_wifi, which has to run after the virtio NIC exists (see the trigger note in
# init.xenvm-hwsim.rc). So do not bet on ordering -- cycle Wi-Fi once, after the
# radios and hostapd are up.
#
# ONLY WHILE WI-FI IS SAVED ON. A fresh /data starts with Wi-Fi off
# (def_wifi_on=false, and nothing enables it at boot), and with it off the
# framework never starts the HAL, so the user's first ON -- after the radios exist --
# enumerates them. Cycling regardless would save Wi-Fi ON at every boot and override the
# Settings toggle. wifi_on is 1 when saved ON and 2 when ON in airplane mode
# (WifiSettingsStore.java:50-58).
#
# DomaWifiRelay does the cycle: `settings` and `cmd` are /system programs this vendor
# domain may not run, and the app has NETWORK_SETTINGS. It looks for this file in the
# request drop-box, cycles Wi-Fi if it is saved ON, and removes the file.
if printf '%s\n' "$(date +%s)" > "$CONF_DIR/req/wifi-cycle.new" 2>/dev/null \
    && mv -f "$CONF_DIR/req/wifi-cycle.new" "$CONF_DIR/req/wifi-cycle" 2>/dev/null; then
    log "asked DomaWifiRelay to cycle Wi-Fi so the HAL re-enumerates the hwsim radios"
else
    log "WARNING: cannot write $CONF_DIR/req/wifi-cycle; Wi-Fi not cycled -- the HAL may hold a stale radio list"
fi

log "done"
