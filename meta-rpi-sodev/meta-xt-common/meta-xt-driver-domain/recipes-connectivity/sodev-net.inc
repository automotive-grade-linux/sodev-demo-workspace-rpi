# sodev-net.inc — single source of truth for the RPi5 Xen cockpit DomD network
# topology (IP addresses, MACs, DHCP range).
#
# Consumers `require` this file and derive their shipped config from these vars,
# so each address/MAC lives in exactly one place:
#   - xen-network        : DomD eth0 (.network), Dom0<->DomD vif (.network),
#                          domd-flatbridge-up (xenbr0 address + uplink gateway)
#   - dnsmasq (bbappend) : DHCP range + static guest leases
#   - dom0-domd-vif      : Dom0 end of the point-to-point vif (bring-up script)
#
# One consumer is deliberately outside that set: meta-rpi-sodev-devel's
# domu-network runs in a different bitbake instance, which does not include
# meta-xt-driver-domain and therefore cannot `require` this file. Its
# 20-eth0.network repeats the DomU address and the DomD gateway literally and has
# to be kept in step by hand -- see the note in domu-network_0.1.bb. Changing a
# value here means checking that file too.
#
# These are HW-proven values. Do NOT change them casually: a wrong value
# silently breaks the 2-screen demo (SSH / guests / HDMI). In particular the
# xenbr0 bridge MUST stay addressless in the .network files — .10.10 is assigned
# LATE by the flatbridge script, never via a .network Address=.
#
# Two segments:
#   - Flat L2 management subnet 192.168.10.0/24 (DomD xenbr0 .10, guests, PC).
#   - Dom0<->DomD point-to-point vif 192.168.0.0/24 (Dom0 .1, DomD netfront .11).
#
# NOTE: bitbake has no inline comments — a trailing `# ...` on an assignment line
# is a parse error ("unparsed line"), so every annotation below is on its own line.

# --- flat L2 management subnet (192.168.10.0/24) ---
# DomD xenbr0 (assigned LATE by flatbridge; also DomD eth0 gateway)
XT_DOMD_XENBR0_IP   ??= "192.168.10.10"
# DomD RP1 eth0 (boot-time, NOT bridged)
XT_DOMD_ETH0_IP     ??= "192.168.10.11"
# Uplink gateway DomD points its default route at once xenbr0 is up. In the demo
# setup this is the PC on the flat segment; it is what gives DomD (and, through
# it, the guests) a route off the RPi5.
XT_PC_UPLINK_GW_IP  ??= "192.168.10.1"
# DomU static lease
XT_DOMU_IP          ??= "192.168.10.12"
# DomA eth1 (adb) static lease.
# Never answered while the shadow AP runs: that service enslaves eth1 into
# br-shadow at sys.boot_completed, a bridge port holds no L3 address, and DomA
# therefore never completes DHCP on eth1 -- dnsmasq logs DHCPOFFER 192.168.10.13
# with no ACK. It stays correct for a build without the shadow AP. DomA's wlan0
# reservation is XT_DOMA_WLAN0_IP below.
XT_DOMA_IP          ??= "192.168.10.13"
# DomA eth0 static lease. Never answered either: eth0 is renamed to buried_eth0
# for minradio, so nothing asks for this MAC.
XT_DOMA_ETH0_IP     ??= "192.168.10.14"
# DomA wlan0 (hwsim station joined to the in-guest shadow AP). Outside the DHCP
# range on purpose, so a range change cannot move it: measured on the PC (netns,
# real dnsmasq 2.90), an unreserved station lands on a range address that MOVES
# when the range moves (.175 for .100-.200, .112 for .100-.150, .135 for
# .120-.200). DomA gets this address only when the MAC its station uses is on
# the dhcp-host line, i.e. when XT_DOMA_WLAN0_MAC below is set; by default it
# takes a range address.
XT_DOMA_WLAN0_IP    ??= "192.168.10.15"
XT_DHCP_RANGE_START ??= "192.168.10.100"
XT_DHCP_RANGE_END   ??= "192.168.10.200"

# --- Dom0<->DomD point-to-point vif subnet (192.168.0.0/24) ---
# Dom0 end of the vif
XT_DOM0_VIF_IP    ??= "192.168.0.1"
# DomD xen-netfront end of the vif
XT_DOMD_VIF_IP    ??= "192.168.0.11"

# --- guest MAC addresses (also fixed in /etc/xen/domX.cfg, shipped by
# xt-xen-cfg-*; those cfgs remain the authoritative NIC definition — these
# mirror them for the dnsmasq static leases) ---
XT_DOMU_MAC      ??= "08:00:27:ff:cb:c2"
# DomA eth1 (management / adb)
XT_DOMA_MAC      ??= "08:00:27:ff:cb:cf"
# DomA eth0
XT_DOMA_ETH0_MAC ??= "08:00:27:ff:cb:ce"
# DomA wlan0. TWO addresses map to XT_DOMA_WLAN0_IP because the framework decides at
# connect time which one the station uses, and dnsmasq accepts several MACs on one
# dhcp-host line (verified: both resolve to .15, an unrelated MAC still gets a range
# address).
#
# 1. The persistent randomized MAC. CuttlefishWifiOverlay (pulled in through
#    cuttlefish/shared/device.mk -> trout -> epam -> this product) sets
#    config_wifi_connected_mac_randomization_supported=true, overriding the Wi-Fi
#    module default of false, and a UI-saved network defaults to RANDOMIZATION_AUTO
#    which resolves to persistent here (the non-persistent allowlist is empty and this
#    product ships no GMS to push one). The value is HMAC-SHA256 over the network key
#    (SSID + security type) with a Keystore secret, so it is stable per SSID and
#    survives reboot -- measured unchanged across at least four boots and an SD
#    rewrite that kept the userdata partition, and with it the Keystore secret.
#    It is SSID-specific: the DomD agent publishes eight SSIDs, and joining a
#    different one produces a different MAC that this reservation will not
#    match. Making the address SSID-independent needs an RRO that turns
#    randomization off (device/epam/aosp-xenvm-trout/rro_overlay/wifi/,
#    overriding CuttlefishWifiOverlay) -- not done here.
#
#    EMPTY BY DESIGN, AND NOT A PLACEHOLDER TO FILL IN BLIND. Because the value
#    is HMAC-SHA256 over the network key, it identifies the access point the
#    board was associated with, so a literal here would publish site information
#    in a source tree. It is also worthless to anyone else: their board,
#    keystore and SSID produce a different address.
#    Leave it empty and DomA takes an address from the DHCP range, which is
#    enough for everything except a fixed adb endpoint. To pin adb to
#    XT_DOMA_WLAN0_IP on one bench, read the address off the board WHILE IT IS
#    ASSOCIATED (`adb shell ip link show wlan0`; reading it while disconnected
#    returns a fresh random address that looks like it rotates) and set
#      XT_DOMA_WLAN0_MAC = "aa:bb:cc:dd:ee:ff"
#    for that build only, in no committed file. build.sh regenerates DomD's
#    conf/ on every run, so a line added to its local.conf lasts until the next
#    build.sh; a conf entry for the domd component in an uncommitted copy of the
#    product yaml lasts. The dnsmasq bbappend drops the address from the
#    dhcp-host line when this is empty, so an unset value cannot produce a
#    config dnsmasq refuses to parse.
XT_DOMA_WLAN0_MAC      ??= ""
# 2. The hwsim radio-0 perm_addr, used when randomization is off (or before the first
#    association). mac80211_create_radios builds it as 02:<prefix hi>:<prefix lo>:00:<idx>:00
#    from ro.boot.wifi_mac_prefix=5554 (0x15B2), so radio 0 is 02:15:b2:00:00:00.
#    Listing it here means the reservation keeps working if the RRO above is ever added.
XT_DOMA_WLAN0_PERM_MAC ??= "02:15:b2:00:00:00"
