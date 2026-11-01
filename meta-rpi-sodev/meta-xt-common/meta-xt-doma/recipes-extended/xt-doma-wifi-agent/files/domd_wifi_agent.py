#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""DomD side of the shadow-AP Wi-Fi bridge for DomA.

DomD owns the only real radio on the board. DomA does not get it: its devices
are qemu device models, and its wlan0 has to be one that WifiService manages. So
DomA simulates its radios with mac80211_hwsim and beacons the SSIDs this agent
reports, and this agent performs the real association on DomA's behalf.

TRANSPORT
A qemu virtio-serial chardev, not vsock and not TCP: doma.cfg's virts5, a UNIX
socket qemu listens on (server=on,wait=off). Chosen over the alternatives
because it needs no IP, no routing rules (DomA's policy routing sends unmarked
traffic to a different interface) and no kernel module. This side is the CLIENT.
It must be SOCK_STREAM -- SOCK_SEQPACKET fails to connect against a qemu
chardev, which gnss_replay.py records as well.

PROTOCOL -- one JSON object per line, both directions:
    ->  {"t":"aps","v":[{"ssid":..,"bssid":..,"sec":<see below>,
                         "freq":2462,"dbm":-59}, ..]}
    <-  {"t":"connect","id":"<id>","ssid":"<SSID-A>","psk":"..."}
    ->  {"t":"state","ssid":..,"state":"COMPLETED","ip":"<from the AP's DHCP>","id":..}
    ->  {"t":"state","ssid":..,"state":"FAILED","error":"<why>","id":..}
    ->  {"t":"state","ssid":..,"state":"LOST","error":"wpa_state <state>"}
    ->  {"t":"state","ssid":..,"state":"BACK","ip":"<address on the interface>"}

COMPLETED and FAILED answer a connect, one for each, in the order they came, and
carry its "id" back (when it had one), by which the relay tells which passphrase the
answer is for. LOST is sent unasked, once, when the network
last joined for DomA has stopped being COMPLETED (see link_lost()): without it
DomA's station stays on that SSID's shadow BSS, and the screen shows a network
DomD no longer has as connected. BACK is sent unasked, once, when a network LOST was
sent for is COMPLETED again: wpa_supplicant keeps trying the one network it has, so
it rejoins on its own when the AP returns, and the relay lists the SSID again then
(it keeps it off the list after a LOST, instead of letting the stale BSS that DomD's
scans still report for a while bring it back).

"sec" is one of
    "open"     no WPA, RSN or OSEN element and no [WEP] (the privacy bit)
    "wpa"      WPA (v1) with PSK
    "wpa2"     RSN with PSK, PSK-SHA256 or FT-PSK
    "sae"      RSN with SAE and no PSK: WPA3-Personal only
    "sae-psk"  RSN with SAE and PSK: the WPA3/WPA2 transition mode
The DomA relay beacons "open" as an open shadow BSS and every other value as a
WPA2 one; only this agent tells the WPA3 kinds apart. An empty psk in a connect
means an open network. Only infrastructure BSSes are published ([MESH] and [IBSS]
are not), and only the strongest BSS of each SSID.

WPA_SUPPLICANT
Spoken to directly over its control socket. wpa_cli is not in the DomD image and
python3 is, so there is nothing to add. The control interface is
AF_UNIX/SOCK_DGRAM and the client must bind its own path first, which is why a
plain connect() is not enough.

A second socket is ATTACHed for events (Monitor): a scan is read once
CTRL-EVENT-SCAN-RESULTS has arrived rather than after a fixed wait, and a join
that fails is reported with the reason wpa_supplicant gave.

connect_real_ap() picks key_mgmt from the latest scan of the requested SSID
(sec_of in main()), so that every kind it publishes can be joined -- measured with
wpa_supplicant 2.11 built from DomD's .config against hostapd on mac80211_hwsim:
    open, or an empty psk   NONE
    "wpa"                   WPA-PSK
    "wpa2", or not in scan  WPA-PSK WPA-PSK-SHA256 FT-PSK, ieee80211w 1
    "sae"                   SAE FT-SAE, ieee80211w 2 (PMF required)
    "sae-psk"               SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK, ieee80211w 1
wpa_supplicant's default key_mgmt (WPA-PSK IEEE8021X) with PMF off joins none of a
PSK-SHA256-only, an FT-only or a PMF-required AP, and for EAP+PSK it picks EAP and
stalls. ieee80211w 1 is "PMF if the AP offers it". FT is dropped by wpa_supplicant
itself on a driver that cannot do it. SAE takes the passphrase as its password
(sme.c falls back from sae_password to the network's passphrase), so a 64-hex raw
PSK cannot join a "sae" AP and is refused; for "sae-psk" it joins over PSK. main()
sets the global sae_pwe to 2 once, so both hash-to-element and hunting-and-pecking
work. It never carries a WEP key, so an AP that offers only EAP, OWE, DPP, FILS,
OSEN, SAE-EXT-KEY (which needs key_mgmt SAE-EXT-KEY, not SAE) or WEP cannot be
joined, and parse_scan_results() does not publish one.

A connect for the network wpa_supplicant is already COMPLETED on -- same SSID, same
key_mgmt and PSK as the last one applied -- does not re-join: the relay asks again
on every association of DomA's station to an open AP, and re-joining would cut
DomD's working link each time. It only takes a lease when wlan0 has no IPv4 address
(the first DHCP may have found no server). A join that does not reach COMPLETED is
forgotten, so the same connect re-joins. Any other connect re-joins, and takes a
new DHCP lease: the address left on wlan0 from the previous AP is flushed first, so
it is never reported for the new one.

SECURITY, STATED PLAINLY
A passphrase typed on the AAOS screen travels this channel in the clear, because
the shadow AP cannot learn a PSK from a 4-way handshake -- only a MIC crosses
the air. Lab use only; do not ship it to a vehicle.
"""

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time

LOG_PREFIX = "domd-wifi-agent:"


def log(*a):
    print(LOG_PREFIX, *a, flush=True)


class Supplicant:
    """Minimal wpa_supplicant control-interface client."""

    def __init__(self, path, timeout=5.0, suffix=""):
        self.path = path
        self.timeout = timeout
        self.base = "/tmp/domd_wifi_agent_%d%s" % (os.getpid(), suffix)
        self.local = self.base
        self.opened = 0
        self.sock = None

    def open(self):
        # The control interface is a datagram socket and it replies to the client's bound
        # address, so the client has to have one. Without the bind, sendto() works and
        # recv() then blocks forever.
        # A new path on every open after the first: a reply wpa_supplicant sends late
        # goes to the address the command came from, and must not reach a new socket.
        self.local = self.base if not self.opened else "%s.%d" % (self.base, self.opened)
        self.opened += 1
        if os.path.exists(self.local):
            os.unlink(self.local)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            self.sock.bind(self.local)
            self.sock.settimeout(self.timeout)
            self.sock.connect(self.path)
        except OSError:
            # Not left half open: every later command would fail on it, and the bound
            # path would stay behind in /tmp.
            self.close()
            raise

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None
        if os.path.exists(self.local):
            try:
                os.unlink(self.local)
            except OSError:
                pass

    def cmd(self, text):
        if self.sock is None:
            self.open()             # a reopen after a timeout failed (see below)
        self.sock.send(text.encode())
        # Unsolicited events are only delivered after ATTACH, which is sent on the
        # Monitor's socket only, so the next datagram here is the reply to this command.
        try:
            return self.sock.recv(65536).decode("utf-8", "replace")
        except socket.timeout:
            # The late reply would answer the NEXT command, and every one after it
            # would read the reply of the one before. A new socket on a new address
            # (see open) leaves the late reply behind. Raised on, as before.
            self.close()
            self.open()
            raise

    def status(self):
        return dict(kv.split("=", 1) for kv in self.cmd("STATUS").splitlines() if "=" in kv)


class Monitor(Supplicant):
    """A second control socket, ATTACHed: events arrive here, replies stay on the first.

    Not essential: when ATTACH fails (or events stop arriving), the agent falls back
    to fixed waits, as before this existed.
    """

    def __init__(self, path):
        super().__init__(path, timeout=1.0, suffix=".ev")
        self.ok = False
        self.reason = ""

    def attach(self):
        self.close()
        try:
            self.open()
            self.ok = self.cmd("ATTACH").strip() == "OK"
        except OSError:
            self.ok = False
        if not self.ok:
            self.close()
        return self.ok

    def _note(self, ev):
        # Why a join failed, as wpa_supplicant says it; these events carry the SSID
        # and codes only, never a key.
        for name, key in (("CTRL-EVENT-SSID-TEMP-DISABLED", "reason"),
                          ("CTRL-EVENT-ASSOC-REJECT", "status_code"),
                          ("CTRL-EVENT-AUTH-REJECT", "status_code"),
                          ("CTRL-EVENT-NETWORK-NOT-FOUND", None)):
            if name in ev:
                m = re.search(r"\b%s=(\S+)" % key, ev) if key else None
                self.reason = name + (" %s=%s" % (key, m.group(1)) if m else "")

    def drain(self):
        """Read what is queued, so wpa_supplicant never finds this socket full."""
        if not self.ok:
            return
        self.sock.setblocking(False)
        try:
            while True:
                self._note(self.sock.recv(65536).decode("utf-8", "replace"))
        except (BlockingIOError, InterruptedError):
            pass
        except OSError:
            self.ok = False
        finally:
            if self.sock:
                self.sock.settimeout(self.timeout)

    def wait(self, names, secs):
        """The first event naming one of names within secs, or None."""
        if not self.ok:
            time.sleep(secs)
            return None
        end = time.time() + secs
        while True:
            left = end - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                ev = self.sock.recv(65536).decode("utf-8", "replace")
            except socket.timeout:
                return None
            except OSError:
                self.ok = False
                return None
            self._note(ev)
            if any(n in ev for n in names):
                return ev


def unescape_ssid(s):
    """Undo wpa_supplicant's printf_encode() so the real bytes can be inspected."""
    BS = chr(92)
    out, i, n = bytearray(), 0, len(s)
    simple = {"n": 10, "r": 13, "t": 9, "e": 27, BS: 92, '"': 34}
    while i < n:
        c = s[i]
        if c != BS or i + 1 >= n:
            out += c.encode("utf-8", "replace")
            i += 1
            continue
        e = s[i + 1]
        if e == "x" and i + 3 < n:
            try:
                out.append(int(s[i + 2:i + 4], 16))
                i += 4
                continue
            except ValueError:
                pass
        if e in simple:
            out.append(simple[e])
        else:
            out += (BS + e).encode("utf-8", "replace")
        i += 2
    return bytes(out)


def ssid_is_usable(ssid):
    """True if this SSID can be carried through hostapd.conf on the DomA side.

    Rejects the empty SSID (hidden AP), anything containing NUL or other control bytes
    -- an AP in range beacons 20 NUL bytes and hostapd refuses its whole config over it,
    which takes out all of DomA's Wi-Fi -- and anything that is not valid UTF-8 or is
    longer than the 32-byte 802.11 limit.
    """
    raw = unescape_ssid(ssid)
    if not raw or len(raw) > 32:
        return False
    if any(b < 0x20 or b == 0x7F for b in raw):
        return False
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


# Key management names as wpa_supplicant prints them inside a [WPA-..]/[WPA2-..]/
# [RSN-..] flag of SCAN_RESULTS, "+"-joined and followed by "-<cipher>"
# (wpa_supplicant_ie_txt() in wpa_supplicant/ctrl_iface.c, 2.11). Longest first, so
# "SAE-EXT-KEY" is not read as "SAE" and a "-EXT-KEY" cipher.
_AKM_NAMES = sorted([
    "EAP", "PSK", "None", "SAE", "SAE-EXT-KEY", "FT/EAP", "FT/PSK", "FT/SAE",
    "FT/SAE-EXT-KEY", "EAP-SHA256", "PSK-SHA256", "EAP-SUITE-B", "EAP-SUITE-B-192",
    "FILS-SHA256", "FILS-SHA384", "FT-FILS-SHA256", "FT-FILS-SHA384", "OWE", "DPP",
    "OSEN", "EAP-SHA384"], key=len, reverse=True)
_PSK_AKMS = {"PSK", "PSK-SHA256", "FT/PSK"}
_SAE_AKMS = {"SAE", "FT/SAE"}


def _akms(text):
    """The key management names at the front of a flag's body, e.g. "PSK+SAE-CCMP"."""
    out, i = set(), 0
    while True:
        for name in _AKM_NAMES:
            j = i + len(name)
            if text.startswith(name, i) and text[j:j + 1] in ("+", "-", ""):
                out.add(name)
                i = j
                break
        else:
            return out          # an unknown name: stop, keep what was understood
        if text[i:i + 1] != "+":
            return out
        i += 1


def classify_flags(flags):
    """("open"|"wpa"|"wpa2"|"sae"|"sae-psk", None), or (None, why it is excluded)."""
    groups = re.findall(r"\[([^\]]*)\]", flags)
    if "MESH" in groups or "IBSS" in groups:
        # not an infrastructure AP: wpa_supplicant's station cannot join it as one
        return None, "mesh or IBSS"
    if any(g.startswith("OSEN-") for g in groups):
        # Hotspot 2.0 OSEN prints neither a WPA/RSN flag nor [WEP], so it would go
        # out as "open", and key_mgmt NONE cannot join it
        return None, "OSEN"
    protos, akms = set(), set()
    for f in groups:
        m = re.match(r"(WPA2|WPA|RSN)-(.*)$", f)
        if m:
            protos.add(m.group(1))
            akms |= _akms(m.group(2))
    if not protos:
        if "[WEP]" in flags:
            # A WEP AP carries no WPA or RSN flag, so it would go out as "open". The
            # DomA relay would then beacon it open and forward an empty passphrase, and
            # connect_real_ap() cannot join WEP (see WPA_SUPPLICANT above).
            return None, "WEP"
        return "open", None
    psk, sae = akms & _PSK_AKMS, akms & _SAE_AKMS
    if sae and psk:
        return "sae-psk", None
    if sae:
        return "sae", None
    if psk:
        return ("wpa2" if protos & {"WPA2", "RSN"} else "wpa"), None
    # EAP, OWE, DPP, FILS, SAE-EXT-KEY only: connect_real_ap() cannot join it (see
    # WPA_SUPPLICANT above), so DomA is not offered it.
    return None, "no PSK or SAE key management"


# "bssid / frequency / signal level / flags / ssid", tab separated, one header line.
def parse_scan_results(text):
    out = []
    for line in text.splitlines()[1:]:
        f = line.split("\t")
        if len(f) < 5:
            continue
        bssid, freq, sig, flags, ssid = f[0], f[1], f[2], f[3], f[4]
        if not ssid:
            continue          # hidden SSID: nothing to show on a picker
        if not ssid_is_usable(ssid):
            # Not cosmetic: DomA writes what this agent publishes into
            # hostapd.conf, and hostapd rejects the whole file over one bad
            # SSID, which kills the shadow AP and with it all of DomA's Wi-Fi.
            # Seen with an AP beaconing NUL bytes.
            log("skipping unusable SSID %r" % ssid)
            continue
        sec, why = classify_flags(flags)
        if sec is None:
            log("skipping %r: %s (%s)" % (ssid, why, flags))
            continue
        try:
            freq_i, sig_i = int(freq), int(sig)
        except ValueError:
            continue
        # Published as text, not as SCAN_RESULTS prints it: that is
        # printf-escaped (\xNN for every byte outside printable ASCII), and DomA
        # writes the value into hostapd.conf byte for byte, so the escaped form
        # would beacon another name. ssid_is_usable() has already checked that
        # it decodes.
        out.append({"ssid": unescape_ssid(ssid).decode("utf-8"), "bssid": bssid,
                    "sec": sec, "freq": freq_i, "dbm": sig_i})
    return out


def top_n(aps, n=None):
    """Strongest BSS per SSID, strongest SSIDs first; all of them when n is None.

    Deduplicated by SSID because an AP with several radios or several band-specific BSSes
    would otherwise fill the whole list with one network -- on the board under test a
    single scan returned 69 BSSes for far fewer distinct names.
    """
    best = {}
    for a in aps:
        cur = best.get(a["ssid"])
        if cur is None or a["dbm"] > cur["dbm"]:
            best[a["ssid"]] = a
    return sorted(best.values(), key=lambda a: -a["dbm"])[:n]


def psk_arg(psk):
    """Argument for SET_NETWORK psk, or None if wpa_supplicant would refuse it.

    64 hex digits are a raw PSK and go in unquoted; anything else is a
    passphrase, which wpa_supplicant takes quoted, at 8..63 bytes and without
    control characters. It prints a passphrase it refuses into its log, so such
    a value is not sent at all.
    """
    if len(psk) == 64 and all(c in "0123456789abcdefABCDEF" for c in psk):
        return psk
    raw = psk.encode("utf-8")
    if 8 <= len(raw) <= 63 and not any(b < 0x20 or b == 0x7F for b in raw):
        return '"%s"' % psk
    return None


# key_mgmt for a passphrase (see WPA_SUPPLICANT above)
_KM_PSK = "WPA-PSK WPA-PSK-SHA256 FT-PSK"
_KM_SAE = "SAE FT-SAE"


def network_for(sec, psk):
    """(key_mgmt, ieee80211w or None, psk argument or None), or (None, None, error)."""
    if not psk:
        return "NONE", None, None
    arg = psk_arg(psk)
    if arg is None:
        return None, None, "psk is neither 8..63 bytes nor 64 hex digits"
    hexpsk = not arg.startswith('"')
    if sec == "sae":
        if hexpsk:
            return None, None, "a SAE-only AP needs the passphrase, not a 64-hex PSK"
        return _KM_SAE, "2", arg
    if sec == "sae-psk":
        return (_KM_PSK if hexpsk else _KM_SAE + " " + _KM_PSK), "1", arg
    if sec == "wpa":
        return "WPA-PSK", None, arg
    return _KM_PSK, "1", arg            # "wpa2", or an SSID the latest scan lacks


# The network last applied by connect_real_ap(): (ssid, key_mgmt, ieee80211w, psk).
_applied = None


def forget_applied():
    """The last join did not complete: the next connect for it must re-join."""
    global _applied
    _applied = None


# How often main() looks at the link between connects, and how many looks in a row
# must find it down before DomA is told. Two looks (5-10 s) let a roam between BSSes
# of the same SSID, or a rekey, pass without a report.
LINK_CHECK_S = 5.0
LINK_LOST_CHECKS = 2
# Whether the network watched has been COMPLETED since it was applied, and how many
# looks in a row have found it down since. The network watched is _applied's, or,
# until a connect sets that, "ssid": the one in WATCH_FILE when this agent started
# (it restarts with Restart=always, also after wpa_supplicant restarted and forgot
# the network), else the one wpa_supplicant was COMPLETED on then.
# "lost": a LOST has been sent for it and no BACK since; "back": the SSID a BACK is
# due for (main() takes it).
_link = {"up": False, "miss": 0, "ssid": None, "lost": False, "back": None}
# The SSID last joined for DomA, kept across a restart of this agent; /run, so not
# across a boot of DomD (DomA's relay forwards the connect again then).
WATCH_FILE = "/run/domd-wifi-agent.watch"


def _watch_write(ssid):
    try:
        if ssid is None:
            os.unlink(WATCH_FILE)
        else:
            with open(WATCH_FILE + ".new", "w", encoding="utf-8") as f:
                f.write(ssid)
            os.replace(WATCH_FILE + ".new", WATCH_FILE)
    except OSError:
        pass


def link_set(up):
    """Called after a connect: up when it ended COMPLETED."""
    _link["up"] = up
    _link["miss"] = 0
    _link["ssid"] = None
    _link["lost"] = False
    _link["back"] = None
    _watch_write(_applied[0] if up and _applied is not None else None)


def link_adopt(sup):
    """At start: watch the network last joined for DomA (WATCH_FILE), as if it were up,
    so that a link wpa_supplicant lost while this agent was down is reported; but the
    network wpa_supplicant is COMPLETED on, if it is on one."""
    try:
        with open(WATCH_FILE, encoding="utf-8") as f:
            ssid = f.read().strip()
    except OSError:
        ssid = ""
    try:
        st = sup.status()
    except OSError:
        st = {}
    # COMPLETED on another network than the file names: the agent stopped during a
    #   join (the file is cleared before one, see connect_real_ap) or wpa_supplicant
    #   moved; that network is the one there is to watch.
    if st.get("wpa_state") == "COMPLETED" and st.get("ssid"):
        cur = unescape_ssid(st["ssid"]).decode("utf-8", "replace")
        if cur != ssid:
            _watch_write(cur)
        _link.update(up=True, miss=0, ssid=cur)
    elif ssid:
        _link.update(up=True, miss=0, ssid=ssid)


def link_lost(sup):
    """(ssid, wpa_state) to report once the network watched has been lost, else None.

    Lost: it was COMPLETED, and LINK_LOST_CHECKS looks in a row found wpa_supplicant
    not COMPLETED on its SSID. Only one network exists at a time (connect_real_ap), so
    wpa_supplicant keeps trying that one; when it comes back COMPLETED the watch is
    armed again."""
    ssid = _applied[0] if _applied is not None else _link["ssid"]
    if ssid is None:
        _link["up"] = False
        _link["miss"] = 0
        return None
    try:
        st = sup.status()
    except OSError:
        return None
    if (st.get("wpa_state") == "COMPLETED"
            and unescape_ssid(st.get("ssid", "")).decode("utf-8", "replace") == ssid):
        if not _link["up"]:
            _watch_write(ssid)          # back up (after a LOST, or a refused connect)
            if _link["lost"]:
                _link["lost"] = False
                _link["back"] = ssid
        _link["up"] = True
        _link["miss"] = 0
        return None
    if not _link["up"]:
        return None
    _link["miss"] += 1
    if _link["miss"] < LINK_LOST_CHECKS:
        return None
    _link["up"] = False
    _link["miss"] = 0
    _link["lost"] = True
    _watch_write(None)
    return ssid, st.get("wpa_state") or "unknown"


def connect_real_ap(sup, ssid, psk, sec=None, iface="wlan0"):
    """Select the network for a real AP. Returns (True, "joining" | "current"), or
    (False, error) without having touched wpa_supplicant.

    sec is the SSID's "sec" in the latest scan, or None if it was not in it; the
    key management follows it (see WPA_SUPPLICANT above).
    """
    global _applied
    if psk and sec == "open":
        # The DomA row still holds a PSK (the relay keeps a real one when an AP turns
        # open), but the AP takes none.
        log("%r is open in the latest scan; joining without the psk" % ssid)
        psk = ""
    km, pmf, arg = network_for(sec, psk)
    if km is None:
        return False, arg
    want = (ssid, km, pmf, arg)
    st = sup.status()
    if (want == _applied and st.get("wpa_state") == "COMPLETED"
            and unescape_ssid(st.get("ssid", "")).decode("utf-8", "replace") == ssid):
        return True, "current"
    # One network at a time: nothing else adds networks (the config file has
    # none), and without this every connect request would leave one more behind.
    sup.cmd("REMOVE_NETWORK all")
    _applied = None
    nid = sup.cmd("ADD_NETWORK").strip()
    if not nid.isdigit():
        return False, "ADD_NETWORK -> %r" % nid
    steps = ['SET_NETWORK %s ssid "%s"' % (nid, ssid), "SET_NETWORK %s key_mgmt %s" % (nid, km)]
    if pmf:
        steps.append("SET_NETWORK %s ieee80211w %s" % (nid, pmf))
    if arg:
        steps.append("SET_NETWORK %s psk %s" % (nid, arg))
    for s in steps:
        r = sup.cmd(s).strip()
        if r != "OK":
            return False, "%s %s -> %r" % (s.split()[0], s.split()[2], r)
    # The previous AP's lease must not outlive it (see WPA_SUPPLICANT above).
    drop_lease(iface)
    # Nothing is joined for DomA until this join completes (link_set): an agent that
    #   restarts in the middle must not watch the network before it (link_adopt).
    _watch_write(None)
    sup.cmd("SELECT_NETWORK %s" % nid)
    _applied = want
    return True, "joining"


JOIN_WAIT_S = 30
SCAN_WAIT_S = 15


def wait_state(sup, mon, want="COMPLETED", secs=JOIN_WAIT_S):
    """The wpa_state reached within secs: polls STATUS, and meanwhile listens on the
    Monitor for why a join fails (mon.reason)."""
    end = time.time() + secs
    last = ""
    mon.reason = ""
    while time.time() < end:
        last = sup.status().get("wpa_state", "")
        if last == want:
            return last
        mon.wait((), min(1.0, max(0.0, end - time.time())))
    return last


UDHCPC_PID = "/run/domd-wifi-agent.udhcpc.pid"


def _stop_udhcpc():
    try:
        with open(UDHCPC_PID) as f:
            os.kill(int(f.read().strip()), signal.SIGTERM)
    except (OSError, ValueError):
        pass


def drop_lease(iface):
    """Stop the previous association's udhcpc and flush wlan0's IPv4 addresses (with
    them its routes), so nothing of the previous AP's lease is used or reported."""
    _stop_udhcpc()
    try:
        subprocess.run(["ip", "-4", "addr", "flush", "dev", iface], timeout=10,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except Exception as e:                                    # noqa: BLE001
        log("ip addr flush on %s failed: %s" % (iface, e))


def iface_ip(iface):
    try:
        out = subprocess.run(["ip", "-o", "-4", "addr", "show", iface],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
        return m.group(1) if m else ""
    except Exception:                                         # noqa: BLE001
        return ""


def dhcp(iface):
    """Take a lease on iface with busybox's udhcpc, and keep it renewed.

    Without -q, udhcpc forks into the background once it holds the lease and
    renews it from there; -n makes it exit instead when no lease comes. The
    udhcpc of the previous association is stopped first, so only one runs.
    """
    _stop_udhcpc()
    try:
        subprocess.run(["udhcpc", "-i", iface, "-n", "-t", "6", "-T", "3",
                        "-p", UDHCPC_PID], timeout=60, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:                                    # noqa: BLE001
        log("dhcp on %s failed: %s" % (iface, e))
    return iface_ip(iface)


def parse_line(line):
    """One newline-delimited JSON message from DomA, or None.

    A line can arrive with a fragment glued to its front. The DomA relay opens its
    virtconsole node and only then switches it to raw mode, so for a moment the TTY
    is cooked with ECHO on and sends part of what this agent had already written
    straight back. That fragment has no newline of its own and prefixes the next
    real line. Measured on RPi4 2026-09-23: the one connect request of a session
    arrived as b'{{"t":"connect",...}' and was dropped, so DomD never associated and
    DomA had Wi-Fi with no Internet. Every message this protocol carries starts with
    {"t", so when the whole line does not parse, retry from the last one.
    """
    try:
        return json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        pass
    i = line.rfind(b'{"t"')
    if i > 0:
        try:
            req = json.loads(line[i:].decode("utf-8", "replace"))
        except ValueError:
            pass
        else:
            log("recovered a message after dropping %d leading byte(s): %r"
                % (i, _redact(line[:i])[:40]))
            return req
    log("ignoring malformed line: %r" % _redact(line)[:120])
    return None


def _redact(b):
    """A connect request may be in the line: keep its passphrase out of the log.

    The value is matched as a JSON string, escapes included: the relay escapes a
    quote or a backslash in a passphrase, and a pattern that stopped at the
    first quote would let the rest through.
    """
    return re.sub(rb'("psk"\s*:\s*")(?:\\.|[^"\\])*', rb'\1<redacted>', b)


def connect_channel(path, tries=0):
    """Connect to the qemu-created socket, retrying while it is absent."""
    n = 0
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            return s
        except OSError as e:
            n += 1
            if tries and n >= tries:
                raise
            if n == 1 or n % 30 == 0:
                log("channel %s not ready (%s); retrying" % (path, e))
            time.sleep(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--socket", default="/run/android_vm_virtconsole5",
                    help="qemu virtio-serial chardev socket (DomA side is /dev/hvc4)")
    ap.add_argument("-c", "--ctrl", default="/run/wpa_supplicant/wlan0")
    ap.add_argument("-i", "--iface", default="wlan0")
    ap.add_argument("-n", "--top", type=int, default=20,
                    help="how many SSIDs to publish (strongest first)")
    ap.add_argument("--interval", type=float, default=20.0,
                    help="seconds between scans")
    args = ap.parse_args()

    sup = Supplicant(args.ctrl)
    try:
        sup.open()
    except OSError as e:
        log("cannot open %s: %s -- is wpa_supplicant running on %s?"
            % (args.ctrl, e, args.iface))
        return 1
    log("wpa_supplicant ctrl %s: %s" % (args.ctrl, sup.cmd("PING").strip()))
    # Global, so once: both SAE PWE methods (hash-to-element and hunting-and-pecking),
    # whichever the AP asks for. Not fatal -- without it SAE still works against an AP
    # that offers hunting-and-pecking. Restart=always runs this again whenever the
    # agent comes back after wpa_supplicant restarted.
    log("SET sae_pwe 2: %s" % sup.cmd("SET sae_pwe 2").strip())
    mon = Monitor(args.ctrl)
    log("event socket: %s" % ("attached" if mon.attach() else "not attached; fixed waits"))
    link_adopt(sup)

    chan = connect_channel(args.socket)
    log("channel connected: %s" % args.socket)
    chan.settimeout(0.5)

    rx = b""
    next_scan = 0.0
    next_link = 0.0
    # Messages for the relay not written yet: a LOST or a BACK, or an answer whose
    #   write failed.
    #   Sent first on every pass, reconnecting the channel when a write fails. A write
    #   that timed out part-way leaves half a line in qemu's buffer, glued to the front
    #   of the next line; the relay reads a state message from its last {"t".
    outbox = []
    # "sec" of every SSID in the latest scan, not only the published ones: a connect
    # may name one that has dropped out of the top N.
    sec_of = {}
    while True:
        if outbox:
            try:
                while outbox:
                    chan.sendall((json.dumps(outbox[0], ensure_ascii=False) + "\n").encode())
                    outbox.pop(0)
            except OSError as e:
                log("channel write failed (%s); reconnecting" % e)
                chan.close()
                chan = connect_channel(args.socket)
                chan.settimeout(0.5)
                # Complete lines already read are still requests to answer; only a
                #   trailing partial line belongs to the channel that went.
                rx = rx[:rx.rfind(b"\n") + 1]
                continue
        now = time.time()
        if now >= next_scan:
            next_scan = now + args.interval
            if not mon.ok:
                mon.attach()        # wpa_supplicant restarted, or events stopped
            mon.drain()
            r = sup.cmd("SCAN").strip()
            # Read the BSS table once this scan (or the one already running, on
            # FAIL-BUSY) has finished, not after a guess: read early, it still holds
            # the previous scan's view, sec_of with it. Up to SCAN_WAIT_S; a scan of
            # every channel takes a few seconds.
            if r in ("OK", "FAIL-BUSY") and mon.ok:
                if mon.wait(("CTRL-EVENT-SCAN-RESULTS", "CTRL-EVENT-SCAN-FAILED"),
                            SCAN_WAIT_S) is None:
                    log("no scan-results event within %d s; reading the BSS table as it is"
                        % SCAN_WAIT_S)
                    mon.ok = False          # re-ATTACH before the next scan
            else:
                time.sleep(3)
            found = parse_scan_results(sup.cmd("SCAN_RESULTS"))
            sec_of = {a["ssid"]: a["sec"] for a in top_n(found)}
            aps = top_n(found, args.top)
            msg = json.dumps({"t": "aps", "v": aps}, ensure_ascii=False)
            try:
                chan.sendall((msg + "\n").encode())
            except OSError as e:
                log("channel write failed (%s); reconnecting" % e)
                chan.close()
                chan = connect_channel(args.socket)
                chan.settimeout(0.5)
                rx = rx[:rx.rfind(b"\n") + 1]     # as above: keep complete lines only
                continue
            log("published %d SSID(s): %s"
                % (len(aps), ", ".join(a["ssid"] for a in aps)))

        if now >= next_link:
            next_link = now + LINK_CHECK_S
            lost = link_lost(sup)
            if lost:
                lost_msg = {"t": "state", "ssid": lost[0], "state": "LOST",
                            "error": "wpa_state %s" % lost[1]}
                log("link lost: %s" % lost_msg)
                outbox.append(lost_msg)
                continue
            if _link["back"] is not None:
                back = _link["back"]
                _link["back"] = None
                # wpa_supplicant rejoined without this agent, so no lease was taken;
                #   the old address stays on the interface unless something dropped it.
                ip = iface_ip(args.iface)
                if not ip:
                    log("no IPv4 address on %s after the rejoin; taking a lease" % args.iface)
                    ip = dhcp(args.iface)
                back_msg = {"t": "state", "ssid": back, "state": "BACK", "ip": ip}
                log("link back: %s" % back_msg)
                outbox.append(back_msg)
                continue

        mon.drain()
        try:
            b = chan.recv(65536)
            if not b:
                raise OSError("channel closed by peer")
            rx += b
        except socket.timeout:
            # Lines left in rx (after an answer whose write failed) are still handled.
            if b"\n" not in rx:
                continue
        except OSError as e:
            log("channel read failed (%s); reconnecting" % e)
            chan.close()
            chan = connect_channel(args.socket)
            chan.settimeout(0.5)
            rx = rx[:rx.rfind(b"\n") + 1]         # as above: keep complete lines only
            continue

        while b"\n" in rx:
            line, rx = rx.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            req = parse_line(line)
            if req is None:
                continue
            if req.get("t") != "connect":
                continue
            ssid, psk = req.get("ssid", ""), req.get("psk", "")
            if not ssid:
                continue
            log("connect request for %r (psk %s, sec %s)"
                % (ssid, "given" if psk else "none", sec_of.get(ssid, "not in scan")))
            ok, info = connect_real_ap(sup, ssid, psk, sec_of.get(ssid), args.iface)
            if not ok:
                reply = {"t": "state", "ssid": ssid, "state": "FAILED",
                         "error": info}
            elif info == "current":
                log("already COMPLETED on %r with this key; not re-joining" % ssid)
                ip = iface_ip(args.iface)
                if not ip:
                    log("no IPv4 address on %s; taking a lease" % args.iface)
                    ip = dhcp(args.iface)
                reply = {"t": "state", "ssid": ssid, "state": "COMPLETED", "ip": ip}
            else:
                state = wait_state(sup, mon)
                if state == "COMPLETED":
                    # always a new lease: the old one belonged to the previous AP
                    reply = {"t": "state", "ssid": ssid, "state": state,
                             "ip": dhcp(args.iface)}
                else:
                    forget_applied()
                    reply = {"t": "state", "ssid": ssid, "state": "FAILED",
                             "error": "not associated within %d s (wpa_state %s%s)"
                             % (JOIN_WAIT_S, state or "unknown",
                                "; " + mon.reason if mon.reason else "")}
            if isinstance(req.get("id"), str):
                reply["id"] = req["id"]
            log("result: %s" % reply)
            link_set(reply["state"] == "COMPLETED")
            # ensure_ascii=False, as for "aps": the relay compares the SSID with the
            # station's, which it reads decoded, not as \u escapes. A write that fails
            # is sent again from the outbox once the channel is back.
            outbox.append(reply)
            try:
                chan.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode())
                outbox.pop()
            except OSError as e:
                log("channel write failed (%s); sending the answer again" % e)
                break
            # A fresh association changes what is worth reporting.
            if info != "current":
                next_scan = 0.0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
