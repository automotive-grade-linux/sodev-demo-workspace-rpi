# RPi4: make domd-flatbridge-up's first wait look for ANY guest tap, not DomA's.
#
# THE BUG
# domd-flatbridge-up opens with a "wait for the first guest tap" loop whose guard
# admits either guest but whose test is hard-coded to DomA's tap name:
#
#     if [ -f /etc/xen/doma.cfg ] || [ -f /etc/xen/domu.cfg ]; then
#         i=0
#         while [ $i -lt 90 ]; do
#             [ -e /sys/class/net/vif-emu ] && break        # <-- DomA's tap only
#             i=$((i+1)); sleep 2
#         done
#     fi
#
# In a DomU-only build /sys/class/net/vif-emu never appears (DomU's tap is
# vif-emu2), so the loop always runs its full 90 x 2 s. The SAME script's later
# enslave loop already derives what to wait for from the xl configs present
# (doma.cfg -> "vif-emu vif-emu1", domu.cfg -> "vif-emu2"); only this first loop
# was left behind. The script's own comment says "Wait for the first guest tap to
# appear", so the glob below is what the code was meant to do.
#
# MEASURED ON HARDWARE (2026-08-04, 4 GiB SKU, DomU-only)
#     16:21:17 Starting DomD flat L2 bridge ...
#     16:24:18 domd-flatbridge-up: eth0 -> xenbr0            <-- 181 s later
#     16:24:18 domd-flatbridge-up: vif-emu2 -> xenbr0
#     16:24:18 Finished DomD flat L2 bridge ...
#
# Nothing is broken by it, but for three minutes the board looks broken, and that
# cost real debugging time:
#   * DomD has no 192.168.10.10 yet -- it is still on 192.168.10.11 (eth0). A
#     session polled .10 for two minutes after a reboot and concluded "DomD is
#     dead". It was not; the address had not moved yet.
#   * DomU has no network for those three minutes.
#   * multi-user.target Wants this unit, so DomD's reported boot time is +180 s.
#
# WHY THIS IS A BBAPPEND AND NOT AN EDIT
# domd-flatbridge-up ships from meta-xt-common (xen-network.bb), which RPi5 builds
# from the same file, and this port keeps meta-xt-common byte-identical. This layer
# (meta-xt-rpi4) is referenced only from rpi4-sodev.yaml, so RPi5 is untouched on
# both counts: the shared file is not modified, and this bbappend is not in RPi5's
# layer set. If the DomA guest is ever brought up here (G4), this change stays
# correct -- the glob matches vif-emu as well.
#
# The 90 x 2 s ceiling itself is deliberately NOT touched: the upstream comment
# states it has no measured basis and exists only so a guest-less build still
# reaches the rest of the script. With the glob fixed the loop exits on the first
# tap, so the size of the bound stops mattering.

# postfuncs, not do_install:append: xen-network.bb's own do_install:append
# substitutes XENBR0_ADDR/UPLINK_GW into this same file and verifies both with
# bbfatal. A postfunc is guaranteed to run after do_install and every append to
# it, so this patch applies to the final file and cannot fight those seds.
do_install[postfuncs] += "rpi4_flatbridge_wait_any_tap"
do_install[vardeps] += "RPI4_FLATBRIDGE_WAIT_OLD RPI4_FLATBRIDGE_WAIT_NEW"

# Exact lines, matched and verified with `grep -qxF` so no regex escaping can go
# wrong silently. Indentation is part of the match.
#
# SINGLE-quoted on purpose. BitBake takes a variable value literally between its
# outer quotes and does NOT process backslash escapes, so writing the inner
# "$_t" as \" inside a double-quoted value would store a literal backslash and
# ship a broken script. Single quotes also stop nothing here: neither value
# contains a single quote, so both survive being re-quoted with '' in the shell
# below, and $_t is never expanded (BitBake only expands ${...}).
RPI4_FLATBRIDGE_WAIT_OLD ?= '        [ -e /sys/class/net/vif-emu ] && break'
RPI4_FLATBRIDGE_WAIT_NEW ?= '        for _t in /sys/class/net/vif-emu*; do [ -e "$_t" ] && break 2; done'

rpi4_flatbridge_wait_any_tap() {
    f="${D}${bindir}/domd-flatbridge-up"
    if [ ! -f "$f" ]; then
        bbfatal "xen-network.bbappend (rpi4): $f not installed -- xen-network.bb's \
do_install must have run before this postfunc"
    fi

    # Refuse to guess. Silently doing nothing here puts back a 180 s window in
    # which the board looks dead, which is exactly what this exists to remove.
    if ! grep -qxF '${RPI4_FLATBRIDGE_WAIT_OLD}' "$f"; then
        if grep -qxF '${RPI4_FLATBRIDGE_WAIT_NEW}' "$f"; then
            bbnote "xen-network.bbappend (rpi4): flatbridge tap wait already globbed"
            return
        fi
        bbfatal "xen-network.bbappend (rpi4): the expected tap-wait line is not in \
$f. Upstream rewrote the wait loop; re-read domd-flatbridge-up and re-derive the patch."
    fi

    # awk with an exact string compare, not sed: the replacement contains [, ], *
    # and & -- all special to sed in either the pattern or the replacement -- and a
    # mis-escaped & would splice the whole match back in and produce a script that
    # still parses. Exact compare has nothing to escape. The temp file lives in
    # WORKDIR, not ${D}, so a failed mv cannot leave a stray file to be packaged.
    tmp="${WORKDIR}/domd-flatbridge-up.rpi4patched"
    awk -v old='${RPI4_FLATBRIDGE_WAIT_OLD}' -v new='${RPI4_FLATBRIDGE_WAIT_NEW}' \
        '$0 == old { print new; next } { print }' "$f" > "$tmp"
    install -m 0755 "$tmp" "$f"

    if ! grep -qxF '${RPI4_FLATBRIDGE_WAIT_NEW}' "$f"; then
        bbfatal "xen-network.bbappend (rpi4): replacement line not present in $f after awk"
    fi
    if grep -qxF '${RPI4_FLATBRIDGE_WAIT_OLD}' "$f"; then
        bbfatal "xen-network.bbappend (rpi4): original line still present in $f after awk"
    fi
    # The whole point of the replacement is a `break 2` nested one level deeper.
    # Parse the result rather than trusting the edit.
    if ! sh -n "$f"; then
        bbfatal "xen-network.bbappend (rpi4): $f no longer parses as a shell script"
    fi
    # xen-network.bb's own substitutions must have survived this rewrite.
    if ! grep -q '^XENBR0_ADDR=' "$f" || ! grep -q '^UPLINK_GW=' "$f"; then
        bbfatal "xen-network.bbappend (rpi4): XENBR0_ADDR/UPLINK_GW lost from $f"
    fi
    bbnote "xen-network.bbappend (rpi4): flatbridge now waits for any vif-emu* tap"
}

# -----------------------------------------------------------------------------
# Name the GENET NIC eth0 (see files/00-genet-eth0.link for why this is needed)
# -----------------------------------------------------------------------------
# The shared recipe ships 00-rp1-eth0.link, which matches Driver=macb — RP1's NIC.
# BCM2711 has no RP1, so nothing pins the interface name without this. The rp1 file
# stays installed and simply never matches on this board.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:raspberrypi4-64 = " file://00-genet-eth0.link"

# No do_install override is needed: the shared recipe has S = "${UNPACKDIR}" and
# installs ${S}/*.link wholesale, so adding the file to SRC_URI is enough to get it
# into ${D}. Only the packaging has to be declared.
#
# ${PN}-flatbridge, not ${PN}: that is the package the shared recipe puts
# 00-rp1-eth0.link in, and the naming rule is only wanted where the bridge is. Without
# this the file would trip the installed-vs-shipped QA check.
FILES:${PN}-flatbridge:append:raspberrypi4-64 = " ${sysconfdir}/systemd/network/00-genet-eth0.link"
