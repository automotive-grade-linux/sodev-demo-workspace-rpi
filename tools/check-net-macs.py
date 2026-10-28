#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check that the guest MACs DomD's dnsmasq knows are the ones the guests have.

The guests' NICs are defined in their xl cfgs (doma.cfg, domu.cfg: the `mac=` of
each virtio-net-pci device), and sodev-net.inc repeats the MACs for dnsmasq's
dhcp-host lines. Nothing ties the two, and a difference fails quietly: a DomA NIC
whose MAC moved is still answered (its DHCP client is Android's), but from the
range instead of its fixed .13/.14, so the address adb and the management path
use changes; DomU, whose AGL image takes its address over DHCP (connman), gets
no answer at all, since dnsmasq ignores a client that is neither on a dhcp-host
line nor an Android one (dnsmasq_2.%.bbappend).

The pairs, by the NIC's id in the cfg:
    doma.cfg nic0 (DomA eth0)  XT_DOMA_ETH0_MAC
    doma.cfg nic1 (DomA eth1)  XT_DOMA_MAC
    domu.cfg nic0 (DomU eth0)  XT_DOMU_MAC
The values are not printed, only which pair differs.

USAGE
    tools/check-net-macs.py     # non-zero exit on a difference
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMON = os.path.join(ROOT, "meta-rpi-sodev", "meta-xt-common")
INC = os.path.join(COMMON, "meta-xt-driver-domain", "recipes-connectivity", "sodev-net.inc")
CFGS = {
    "doma.cfg": os.path.join(COMMON, "meta-xt-doma", "recipes-extended", "xt-xen-cfg-doma",
                             "files", "doma.cfg"),
    "domu.cfg": os.path.join(COMMON, "meta-xt-domu", "recipes-extended", "xt-xen-cfg-domu",
                             "files", "domu.cfg"),
}
PAIRS = [("doma.cfg", "nic0", "XT_DOMA_ETH0_MAC"),
         ("doma.cfg", "nic1", "XT_DOMA_MAC"),
         ("domu.cfg", "nic0", "XT_DOMU_MAC")]
MAC = r"[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}"


def inc_macs():
    out = {}
    for line in open(INC):
        m = re.match(r"\s*(XT_\w+_MAC)\s*\?\?=\s*\"(%s)\"" % MAC, line)
        if m:
            out[m.group(1)] = m.group(2).lower()
    return out


def cfg_macs(path):
    """{nic id: mac, or None without one} from the virtio-net-pci devices on lines
    that are not comments."""
    out = {}
    for line in open(path):
        if line.lstrip().startswith("#") or "virtio-net-pci" not in line:
            continue
        i = re.search(r"\bid=(\w+)", line)
        m = re.search(r"\bmac=(%s)" % MAC, line)
        if i:
            out[i.group(1)] = m.group(1).lower() if m else None
    return out


def main():
    inc = inc_macs()
    cfgs = {name: cfg_macs(path) for name, path in CFGS.items()}
    failed = 0
    for cfg, nic, var in PAIRS:
        a, b = cfgs[cfg].get(nic), inc.get(var)
        if a is None or b is None:
            print("FAIL: %s %s or %s not found" % (cfg, nic, var))
            failed += 1
        elif a != b:
            print("FAIL: %s %s and sodev-net.inc %s differ" % (cfg, nic, var))
            failed += 1
        else:
            print("ok    %s %s = %s" % (cfg, nic, var))
    extra = sorted("%s %s" % (c, n) for c, nics in cfgs.items() for n in nics
                   if (c, n) not in {(p[0], p[1]) for p in PAIRS})
    for e in extra:
        print("FAIL: %s has no sodev-net.inc counterpart in this check" % e)
        failed += 1
    print("\n%d failure(s)" % failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
