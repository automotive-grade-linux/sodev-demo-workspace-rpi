#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the RPi5 DomD memory map for BOTH board SKUs, without building anything.

The map exists in two places that must agree:

  * bcm2712-raspberrypi5-xen.dtso  -- /chosen/domD `memory` + `xen,static-mem`.
    These are the 16 GB values and the build default.
  * boot.cmd.xen.{zephyr,linux}-dom0.in -- the `if test "${board_ram}" = "8g"`
    block that overrides both properties at run time for the 8 GB board.

Because the 8 GB map only exists as two `fdt set` lines inside a U-Boot script, a
typo there is invisible until the board fails to boot. This script re-derives both
configurations from the real files and checks:

  1. the static-mem banks of each SKU do not overlap each other;
  2. `memory = <hi lo>` (in KiB) equals the sum of that SKU's banks;
  3. no fatload destination in either boot script lands inside a static-mem bank;
  4. the 8 GB map is a strict subset of the 16 GB map (only shrinks, never moves) --
     this is what keeps the verified low-bank placement intact;
  5. every bank lies inside real DRAM for that SKU;
  6. Dom0's bank[0] placement under Xen's allocate_memory_11() still equals the
     address Zephyr's sram0 is relinked to in patch 0008, and both boot scripts ask
     for the dom0_mem this prediction assumes;
  7. the domain budget vs usable DRAM, reported per SKU. With dom0_mem=512M both SKUs
     fit; if a future change pushes a SKU over, it is reported as an explicit
     OVER-COMMIT line rather than silently passing.

Exit status is non-zero only for 1-6 (mechanical inconsistencies). 7 is informational
by design, because the 8 GB usable figure is extrapolated rather than measured; use
--strict-budget to make an over-commit fail too.

Placement and scope: this lives at the workspace root next to build.sh and
rpi5-sodev.yaml because it reads across BOTH of them and two different layers
(meta-xt-rpi5's boot scripts and Xen overlay, meta-xt-common's Zephyr patch). It is
deliberately NOT under meta-rpi-sodev/scripts/, which holds helpers scoped to a single
layer. No recipe references it and nothing installs it into an image: it is a
developer-time check, run by hand or from CI, and must not be mistaken for an orphaned
file and deleted.

Usage:
    tools/check-memory-map.py                 # both SKUs
    tools/check-memory-map.py --ram 8g        # one SKU
    tools/check-memory-map.py --strict-budget
"""

import argparse
import os
import re
import sys

MiB = 1024 * 1024
GiB = 1024 * MiB

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DTSO = os.path.join(
    ROOT, "meta-rpi-sodev", "meta-xt-rpi5", "recipes-kernel", "linux", "files",
    "bcm2712-raspberrypi5-xen.dtso")
BOOTCMD_DIR = os.path.join(
    ROOT, "meta-rpi-sodev", "meta-xt-rpi5", "recipes-bsp", "xt-rpi-u-boot-scr", "files")
BOOTCMDS = {
    "zephyr": os.path.join(BOOTCMD_DIR, "boot.cmd.xen.zephyr-dom0.in"),
    "linux": os.path.join(BOOTCMD_DIR, "boot.cmd.xen.linux-dom0.in"),
}

# Real BCM2712 DRAM as the firmware reports it, so a bank cannot be proposed in a
# range with no memory behind it.
#
# GROUND TRUTH: the 16 GB board is the one this project has measured. Its firmware
# reports total_memory=16372 MiB (recorded in the xen.dtso comment). The 8 GB figure
# is EXTRAPOLATED from it (16384 - 12 -> 8192 - 12) and is marked as such: no 8 GB
# RPi5 has been measured here. Treat DRAM_TOP_8G as an upper bound, not a fact.
# The 16 GB board's banks, exactly as the firmware reported them in the Xen boot log
# ("RAM: <start> - <end>" lines, printed before any domain is built):
#   RAM: 0x0         - 0x3f3fffff     1012 MiB  (the 12 MiB up to 0x40000000 is the
#                                                firmware carve-out -- this is where
#                                                16384 - 12 = 16372 comes from)
#   RAM: 0x40000000  - 0xffffffff     3072 MiB
#   RAM: 0x100000000 - 0x3ffffffff   12288 MiB
# The 8 GB rows below are EXTRAPOLATED by shortening only the high bank (4 GiB instead
# of 12 GiB), which reproduces 8192 - 12 = 8180. No 8 GB Pi 5 has been measured here,
# so treat them as an upper bound rather than a fact.
DRAM_BANKS = {
    "16g": [(0x00000000, 0x3F400000), (0x40000000, 0x100000000),
            (0x100000000, 0x400000000)],
    "8g": [(0x00000000, 0x3F400000), (0x40000000, 0x100000000),
           (0x100000000, 0x200000000)],
}
USABLE_MiB = {"16g": 16372, "8g": 8180}
USABLE_MEASURED = {"16g": True, "8g": False}

# Only the low (<4 GiB) part matters for Dom0 bank[0], and it is identical on both SKUs.
LOW_RAM = [b for b in DRAM_BANKS["16g"] if b[0] < 4 * GiB]

# Non-module reservations that are already in place when allocate_memory_11() runs.
# The BOOT MODULES are deliberately NOT listed here: they are derived per flavour from
# the fatload lines in the boot scripts (see low_free_ranges), because hardcoding them
# is exactly how this table went stale once -- it omitted the linux flavour's Dom0
# initramfs at 0xa0000000, which only the linux script loads.
LOW_RESERVED = [
    (0x02000000, 0x0207B000),  # grant table ("Grant table range:" in the Xen log)
    (0x08000000, 0x08400000),  # optee_shm   (xen.dtso reserved-memory)
    (0x1D000000, 0x1F000000),  # optee_os    (xen.dtso reserved-memory)
]

# How much a fatload'ed module is assumed to occupy. The load ADDRESS is parsed from
# the script; the size is not knowable without the artifacts, so a flat slot is
# assumed. This is deliberately coarse: over-reserving removes candidate blocks, which
# can only move the prediction DOWN or make it report "no block free" -- it cannot
# invent a higher one. The largest real module is the ~27 MiB DomD Image.
MODULE_SLOT_BYTES = 32 * MiB

# Domain budget (MiB). Dom0 is heap-allocated via dom0_mem; DomU/DomA are
# heap-allocated by `xl create` from domu.cfg / doma.cfg; DomD is static-mem.
# XEN_OVERHEAD_MiB is an ESTIMATE of Xen's own footprint (image + frametable + heap
# metadata + grant tables), not a measurement.
XEN_OVERHEAD_MiB = 64
DOM0_MEM_MiB = 512
BUDGET = {
    "16g": {"Dom0": DOM0_MEM_MiB, "DomD": 4096, "DomU": 1024, "DomA": 4096},
    "8g": {"Dom0": DOM0_MEM_MiB, "DomD": 3072, "DomU": 1024, "DomA": 3072},
}

# DomD sizes that are known to be too small, so a future edit that reaches for one
# again gets told. Two independent measurements land on 2048:
#   * the Xen host overlay records `xl devd` OOM-killed at 2 GB with both guests' qemu
#     device-models plus weston and the VHAL backend running concurrently, which is why
#     DomD is 4096 on the 16 GB SKU;
#   * hardware, 2026-08-03: an earlier 8g map used DomD 2048 with DomA 4096 and AAOS
#     crash-looped in binder without ever setting sys.boot_completed -- with 1.3 GiB
#     still free in DomD and no OOM kill, so the limit is what the device model can map
#     of a 4 GiB guest rather than DomD's own RAM.
# The 8g map therefore splits the reduction: DomD 3072 + DomA 3072, verified to boot
# all four domains.
#
# "Four domains" throughout means Dom0/DomD/DomU/DomA. DomZ (16 MiB, heap-allocated by
# the toolstack, no static-mem bank) is deliberately not in this arithmetic; the totals
# here are 16 MiB below the with-DomZ totals in docs/DESIGN.md.
DOMD_KNOWN_OOM_MiB = 2048

# Where Zephyr's sram0 is relinked to, in
# meta-xt-dom0-zephyr/0008-rpi5-board-domd-owns-sd.patch. Xen cannot pin a direct-map
# Dom0 to a DT address, so dom0_mem DECIDES this, and Zephyr -- absolute-linked from
# CONFIG_SRAM_BASE_ADDRESS -- must agree or it executes garbage before console init.
# doma.cfg carries a substituted `memory` line and the recipe below maps BOARD_RAM to
# the value. BUDGET must agree with that mapping or the two drift apart silently.
DOMA_CFG = os.path.join(
    ROOT, "meta-rpi-sodev", "meta-xt-common", "meta-xt-doma",
    "recipes-extended", "xt-xen-cfg-doma", "files", "doma.cfg")
# doma.cfg's `memory` is substituted from BOARD_RAM, so every builder that installs
# xt-xen-cfg-doma has to be given BOARD_RAM. Two do: domd (zephyr flavour toolstack)
# and dom0 (linux flavour toolstack). Missing one is silent -- the recipe falls back
# to its 16g default -- so check the yaml rather than trust it.
SODEV_YAML = os.path.join(ROOT, "rpi5-sodev.yaml")

DOMA_RECIPE = os.path.join(
    ROOT, "meta-rpi-sodev", "meta-xt-common", "meta-xt-doma",
    "recipes-extended", "xt-xen-cfg-doma", "xt-xen-cfg-doma_1.0.bb")

ZEPHYR_SRAM_PATCH = os.path.join(
    ROOT, "meta-rpi-sodev", "meta-xt-common", "meta-xt-dom0-zephyr",
    "0008-rpi5-board-domd-owns-sd.patch")

errors = []
warnings = []


def err(msg):
    errors.append(msg)
    print("  FAIL  " + msg)


def warn(msg):
    warnings.append(msg)
    print("  WARN  " + msg)


def ok(msg):
    print("  ok    " + msg)


def _cells_to_banks(cells):
    """Turn a flat <hi lo hi lo ...> cell list into [(base, size), ...]."""
    if len(cells) % 4:
        raise ValueError("cell count %d is not a multiple of 4 (addr2 + size2)" % len(cells))
    banks = []
    for i in range(0, len(cells), 4):
        base = (cells[i] << 32) | cells[i + 1]
        size = (cells[i + 2] << 32) | cells[i + 3]
        banks.append((base, size))
    return banks


def _parse_cells(text):
    return [int(t, 0) for t in re.findall(r"0x[0-9a-fA-F]+|\b\d+\b", text)]


def parse_dtso():
    """Return (banks, memory_kib) for the 16 GB map from the Xen host overlay."""
    src = open(DTSO).read()
    # Strip comments so a hex value inside a /* */ block cannot be mistaken for data.
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    m = re.search(r"xen,static-mem\s*=\s*<([^>]*)>", src)
    if not m:
        raise SystemExit("ERROR: xen,static-mem not found in %s" % DTSO)
    banks = _cells_to_banks(_parse_cells(m.group(1)))
    m = re.search(r"\bmemory\s*=\s*<([^>]*)>", src)
    if not m:
        raise SystemExit("ERROR: /chosen/domD memory not found in %s" % DTSO)
    c = _parse_cells(m.group(1))
    if len(c) != 2:
        raise SystemExit("ERROR: memory = <%s> is not 2 cells" % m.group(1))
    return banks, (c[0] << 32) | c[1]


def parse_bootcmd_8g(path):
    """Return (banks, memory_kib) from the board_ram=8g override block, or None."""
    src = open(path).read()
    # Only look inside the `if test "${board_ram}" = "8g" ; then ... fi` block, so a
    # commented example elsewhere in the script cannot be picked up.
    m = re.search(
        r'if\s+test\s+"\$\{board_ram\}"\s*=\s*"8g"\s*;\s*then(.*?)^fi\s*$',
        src, flags=re.S | re.M)
    if not m:
        return None
    block = m.group(1)
    # Drop shell comments: a `#` line inside the block is documentation, not data.
    block = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
    sm = re.search(r"fdt set /chosen/domD xen,static-mem\s*<([^>]*)>", block)
    mm = re.search(r"fdt set /chosen/domD memory\s*<([^>]*)>", block)
    if not sm or not mm:
        return None
    banks = _cells_to_banks(_parse_cells(sm.group(1)))
    c = _parse_cells(mm.group(1))
    if len(c) != 2:
        raise SystemExit("ERROR: 8g memory = <%s> is not 2 cells in %s" % (mm.group(1), path))
    return banks, (c[0] << 32) | c[1]


def parse_fatloads(path):
    """Return [(addr, filename), ...] for every fatload in a boot script.

    re.search, NOT re.match: the DomD kernel load is written as the condition of an
    `if` -- `if fatload mmc 0 0xc000000 Image ; then` -- so anchoring at the start of
    the line silently drops it, and with it both the 0xc000000 reservation and the
    static-mem collision check for the largest module in the script.
    """
    out = []
    for line in open(path):
        line = line.strip()
        if line.startswith("#"):
            continue
        for m in re.finditer(r"fatload\s+mmc\s+\S+\s+(0x[0-9a-fA-F]+)\s+(\S+)", line):
            out.append((int(m.group(1), 0), m.group(2)))
    return out


def check_no_overlap(banks, label):
    s = sorted(banks)
    clean = True
    for (b0, s0), (b1, s1) in zip(s, s[1:]):
        if b0 + s0 > b1:
            err("%s: banks overlap: 0x%x+0x%x and 0x%x+0x%x" % (label, b0, s0, b1, s1))
            clean = False
    if clean:
        ok("%s: %d banks, no overlap" % (label, len(banks)))


def check_sum(banks, memory_kib, label):
    total = sum(sz for _, sz in banks)
    want = memory_kib * 1024
    if total != want:
        err("%s: bank sum %d B (%d MiB) != memory %#x KiB (%d MiB)"
            % (label, total, total // MiB, memory_kib, want // MiB))
    else:
        ok("%s: bank sum == memory == %d MiB (%#x KiB)" % (label, total // MiB, memory_kib))


def check_in_dram(banks, ram, label):
    dram = DRAM_BANKS[ram]
    clean = True
    for b, sz in banks:
        if not any(d0 <= b and b + sz <= d1 for d0, d1 in dram):
            err("%s: bank 0x%x+0x%x is outside %s DRAM (top 0x%x)"
                % (label, b, sz, ram, dram[-1][1]))
            clean = False
    if clean:
        top = max(b + sz for b, sz in banks)
        ok("%s: all banks inside %s DRAM (highest address 0x%x = %d MiB)"
           % (label, ram, top, top // MiB))


def check_loads_clear(banks, label):
    clean = True
    for flavour, path in BOOTCMDS.items():
        for addr, name in parse_fatloads(path):
            for b, sz in banks:
                if b <= addr < b + sz:
                    err("%s: %s fatload %s at 0x%x lands inside static-mem bank 0x%x+0x%x"
                        % (label, flavour, name, addr, b, sz))
                    clean = False
    if clean:
        ok("%s: no fatload destination lands inside a static-mem bank" % label)


def check_shrink_only(banks16, banks8):
    """Every 8g bank must be a prefix-range of a 16g bank at the same base."""
    m16 = dict(banks16)
    clean = True
    for b, sz in banks8:
        if b not in m16:
            err("8g: bank base 0x%x does not exist in the 16g map (bases must not move)" % b)
            clean = False
        elif sz > m16[b]:
            err("8g: bank 0x%x grew from 0x%x to 0x%x (8g must only shrink)" % (b, m16[b], sz))
            clean = False
    if clean:
        kept = [b for b, _ in banks8]
        dropped = [b for b, _ in banks16 if b not in kept]
        shrunk = [b for b, sz in banks8 if sz < m16[b]]
        ok("8g is a shrink-only subset of 16g (dropped: %s; shrunk: %s)"
           % (", ".join("0x%x" % b for b in dropped) or "none",
              ", ".join("0x%x" % b for b in shrunk) or "none"))


def low_free_ranges(banks, flavour):
    """The low-memory holes left when allocate_memory_11() runs, for one flavour.

    The boot modules are taken from the flavour's own fatload lines rather than a
    hardcoded table: the two scripts do NOT load the same set (only the linux one
    loads a Dom0 initramfs, at 0xa0000000), so a single table is wrong for one of them.
    """
    taken = list(LOW_RESERVED)
    taken += [(b, b + sz) for b, sz in banks if b < 4 * GiB]
    for addr, _name in parse_fatloads(BOOTCMDS[flavour]):
        if addr < 4 * GiB:
            taken.append((addr, min(addr + MODULE_SLOT_BYTES, 4 * GiB)))
    out = []
    for s0, e0 in LOW_RAM:
        cur = [(s0, e0)]
        for rs, re_ in taken:
            nxt = []
            for a, b in cur:
                if re_ <= a or rs >= b:
                    nxt.append((a, b))
                    continue
                if a < rs:
                    nxt.append((a, rs))
                if re_ < b:
                    nxt.append((re_, b))
            cur = nxt
        out += cur
    return sorted(out)


# Dom0 bank[0], as MEASURED on hardware. Keyed by (flavour, dom0_mem MiB).
#
# WHICH candidate wins inside one MEMF_bits tier is NOT predictable by this model, and
# two measurements now prove it is neither the lowest nor the highest:
#
#   zephyr, 512M : candidates 0xa0000000 / 0xc0000000 / 0xe0000000 -> 0xa0000000 (LOWEST)
#   linux,  512M : candidates 0xc0000000 / 0xe0000000              -> 0xe0000000 (HIGHEST)
#
# The history is worth keeping because both wrong answers looked justified at the time.
# The first model returned max(), reasoning that alloc_heap_pages() takes the head of the
# order-N free list and that with bootscrub=off those lists come out in descending
# address order. The zephyr board falsified that, so it was changed to min() -- on the
# strength of that ONE data point. The linux board then falsified min() too. The
# selection depends on the buddy free-list state, which differs between the flavours
# because they reserve different low regions, and this script does not model it.
#
# So: use the measured value where there is one, and where there is not, report the
# candidate set and say plainly that the pick is unproven. Do NOT re-derive a rule from
# a single new board.
DOM0_BANK0_MEASURED = {
    # BANK[0] 0xa0000000-0xc0000000; "Loading zImage ... to 00000000a0000000"
    ("zephyr", 512): 0xa0000000,
    # BANK[0] 0xe0000000-0x100000000; same log line, at 0xe0000000
    ("linux", 512): 0xe0000000,
    # earlier hardware log; single candidate in its tier
    ("zephyr", 1024): 0xc0000000,
}


def predict_dom0_bank0(banks, size_bytes, flavour):
    """Reproduce allocate_memory_11()'s bank[0] placement.

    Xen cannot pin a direct-map Dom0 to a DT address (allocate_memory_11() in
    xen/arch/arm/domain_build.c ignores xen,static-mem -- that property is parsed only
    on the dom0less path, xen/common/device-tree/dom0less-bindings.c) and it loads the
    arm64 Image at bank[0].start + text_offset (kernel_zimage_place() in
    xen/arch/arm/kernel.c), so dom0_mem decides where the bank lands.
    Re-checked against Xen 4.22: allocate_memory_11() still makes no reference to
    static memory, and the text_offset placement is unchanged. Cited by function
    rather than line number, because the previous citation named a line that did not
    hold the code even on 4.21.

    The loop in allocate_memory_11 is `for (bits = order; bits <= lowmem_bitsize;
    bits++) alloc_domheap_pages(d, order, MEMF_bits(bits))`: it raises the address
    ceiling one bit at a time and takes the FIRST ceiling that fits. lowmem_bitsize is
    min(32, arch_get_dma_bitsize()), i.e. 32 on this platform. Starting the sweep below
    `order` is harmless -- a smaller ceiling cannot fit the block.

    Returns (winner, bits, candidates, measured). `winner` is the MEASURED address when
    DOM0_BANK0_MEASURED has one for this (flavour, dom0_mem) -- see the note there for
    why nothing else is trustworthy -- and otherwise the lowest candidate merely as
    something to print, with `measured` False so the caller warns instead of asserting.
    `candidates` is the whole set in the winning tier, always reported.
    """
    holes = low_free_ranges(banks, flavour)
    for bits in range(12, 33):
        ceiling = 1 << bits
        cands = []
        for a, b in holes:
            base = (a + size_bytes - 1) // size_bytes * size_bytes
            while base + size_bytes <= min(b, ceiling):
                cands.append(base)
                base += size_bytes
        if cands:
            key = (flavour, size_bytes // MiB)
            m = DOM0_BANK0_MEASURED.get(key)
            if m is not None:
                # Sanity: the measured address must at least BE a candidate. If it is
                # not, the hole model itself is wrong and silently trusting the table
                # would hide that.
                return m, bits, sorted(cands), (m in cands)
            return min(cands), bits, sorted(cands), False
    return None, None, [], False


def parse_zephyr_sram_base():
    """Read the sram0 base that patch 0008 relinks Zephyr to."""
    if not os.path.exists(ZEPHYR_SRAM_PATCH):
        return None
    for line in open(ZEPHYR_SRAM_PATCH):
        m = re.match(r"\+\s*reg = <0x00 (0x[0-9a-fA-F]+) DT_SIZE_M\((\d+)\)>;", line)
        if m:
            return int(m.group(1), 0), int(m.group(2))
    return None


def check_dom0_bank0(banks, ram, label):
    """Dom0 bank[0] placement, per flavour, plus the Zephyr relink coupling."""
    sram = parse_zephyr_sram_base()
    if sram is None:
        err("%s: could not read the sram0 relink base from %s"
            % (label, os.path.basename(ZEPHYR_SRAM_PATCH)))
        return
    sram_base, sram_mib = sram

    per_flavour = {}
    for flavour in sorted(BOOTCMDS):
        got, bits, cands, measured = predict_dom0_bank0(
            banks, DOM0_MEM_MiB * MiB, flavour)
        per_flavour[flavour] = got
        if got is None:
            err("%s/%s: no %d MiB low block free for Dom0 bank[0]"
                % (label, flavour, DOM0_MEM_MiB))
            continue
        if measured:
            ok("%s/%s: Dom0 bank[0] 0x%x for dom0_mem=%dM (MEMF_bits=%d) -- MEASURED "
               "on hardware, and it is one of the %d candidates this model derives"
               % (label, flavour, got, DOM0_MEM_MiB, bits, len(cands)))
        elif (flavour, DOM0_MEM_MiB) in DOM0_BANK0_MEASURED:
            err("%s/%s: the measured bank[0] 0x%x is NOT among the candidates this "
                "model derives (%s) -- the free-hole model is wrong, not just the "
                "within-tier pick"
                % (label, flavour, got, ", ".join("0x%x" % c for c in cands)))
        else:
            warn("%s/%s: no measured bank[0] for dom0_mem=%dM; %d candidate(s) in the "
                 "winning tier (%s) and WHICH ONE WINS IS UNPROVEN -- neither lowest "
                 "nor highest holds (see DOM0_BANK0_MEASURED). Read BANK[0] from the "
                 "Xen log and add it to the table"
                 % (label, flavour, DOM0_MEM_MiB, len(cands),
                    ", ".join("0x%x" % c for c in cands)))
        if len(cands) > 1 and measured:
            ok("%s/%s: candidates in that tier: %s"
               % (label, flavour, ", ".join("0x%x" % c for c in cands)))
        # A boot module inside the predicted bank would be copied over / rejected.
        for addr, name in parse_fatloads(BOOTCMDS[flavour]):
            if got <= addr < got + DOM0_MEM_MiB * MiB:
                err("%s/%s: fatload %s at 0x%x lands inside the predicted Dom0 bank "
                    "0x%x+0x%x" % (label, flavour, name, addr, got,
                                   DOM0_MEM_MiB * MiB))

    # The sram0 relink constrains the ZEPHYR flavour only. A Linux Dom0 is a
    # relocatable arm64 Image: Xen loads it at bank[0].start + text_offset and it runs
    # there wherever that is. The two flavours legitimately land in different places --
    # MEASURED 0xa0000000 (zephyr) vs 0xe0000000 (linux) -- partly because the linux
    # script additionally fatloads its Dom0 initramfs at 0xa0000000, which takes that
    # candidate out of play, and partly because the within-tier pick differs (zephyr took
    # the lowest of its three, linux the highest of its two). An earlier version of this
    # check treated the divergence as a failure; that was an artefact of the first
    # (highest-wins) model, under which both flavours happened to agree.
    if per_flavour.get("linux") and per_flavour.get("zephyr") \
            and per_flavour["linux"] != per_flavour["zephyr"]:
        ok("%s: flavours place Dom0 differently (zephyr=0x%x, linux=0x%x) -- expected "
           "and measured. Only the zephyr flavour is constrained by the sram0 relink; "
           "a Linux Dom0 is a relocatable arm64 Image."
           % (label, per_flavour["zephyr"], per_flavour["linux"]))
    got = per_flavour.get("zephyr")
    if got is not None:
        if sram_base != got:
            err("%s: Zephyr sram0 is relinked to 0x%x but bank[0] lands at 0x%x -- "
                "Zephyr would execute garbage and go silent before console init"
                % (label, sram_base, got))
        else:
            ok("%s: Zephyr sram0 relink 0x%x matches the zephyr flavour's bank[0]"
               % (label, sram_base))
        if sram_mib > DOM0_MEM_MiB:
            err("%s: Zephyr declares %d MiB of SRAM but the Dom0 bank is only %d MiB"
                % (label, sram_mib, DOM0_MEM_MiB))
        else:
            ok("%s: Zephyr SRAM %d MiB fits the %d MiB Dom0 bank (%d MiB "
               "assigned-unused)" % (label, sram_mib, DOM0_MEM_MiB,
                                     DOM0_MEM_MiB - sram_mib))


def check_domd_size(banks, ram):
    """Flag a DomD size that is at or below a size measured to OOM-kill xl devd."""
    total = sum(sz for _, sz in banks) // MiB
    if total <= DOMD_KNOWN_OOM_MiB:
        warn("%s: DomD is %d MiB. The Xen host overlay records that at %d MiB "
             "`xl devd` was OOM-killed with the DomU+DomA qemu device-models, weston "
             "and the VHAL backend running together -- expect that risk whenever both "
             "guests run on this SKU" % (ram, total, DOMD_KNOWN_OOM_MiB))
    else:
        ok("%s: DomD %d MiB is above the %d MiB size known to OOM-kill xl devd"
           % (ram, total, DOMD_KNOWN_OOM_MiB))


def check_dom0_mem_in_bootcmds():
    """Both boot scripts must ask for the same dom0_mem as the model assumes."""
    for flavour, path in BOOTCMDS.items():
        src = open(path).read()
        m = re.search(r"xen,xen-bootargs\s+\"[^\"]*dom0_mem=(\d+)M", src)
        if not m:
            err("%s: dom0_mem not found in the xen,xen-bootargs line" % flavour)
            continue
        val = int(m.group(1))
        if val != DOM0_MEM_MiB:
            err("%s: bootargs say dom0_mem=%dM but this script assumes %dM -- the "
                "Zephyr relink target is derived from it" % (flavour, val, DOM0_MEM_MiB))
        else:
            ok("%s: bootargs dom0_mem=%dM" % (flavour, val))


def check_doma_mem():
    """doma.cfg must be a placeholder, and the recipe's BOARD_RAM map must equal BUDGET.

    DomA became board-dependent when the 8g map stopped shrinking DomD alone, which
    put its size in two places: BUDGET here and a `case "${BOARD_RAM}"` in the recipe.
    Nothing else ties them together, so check it rather than trust it.
    """
    print("== doma.cfg / xt-xen-cfg-doma ==")
    for p in (DOMA_CFG, DOMA_RECIPE):
        if not os.path.exists(p):
            err("missing %s" % p)
            return

    cfg = open(DOMA_CFG).read()
    if re.search(r"^memory = DOMA_MEM_PLACEHOLDER$", cfg, re.M):
        ok("doma.cfg carries the DOMA_MEM_PLACEHOLDER line")
    else:
        got = re.search(r"^memory\s*=\s*(\S+)", cfg, re.M)
        err("doma.cfg does not carry `memory = DOMA_MEM_PLACEHOLDER` (found %s); "
            "the recipe bbfatals on this, so the build would stop"
            % (got.group(1) if got else "no memory line"))

    rec = open(DOMA_RECIPE).read()
    # `16g) doma_mem=4096 ;;`
    found = dict((m.group(1), int(m.group(2)))
                 for m in re.finditer(r"^\s*(8g|16g)\)\s*doma_mem=(\d+)\s*;;",
                                      rec, re.M))
    for ram in sorted(BUDGET):
        want = BUDGET[ram]["DomA"]
        if ram not in found:
            err("the recipe has no doma_mem case for %s" % ram)
        elif found[ram] != want:
            err("%s: recipe sets DomA to %d MiB but BUDGET says %d MiB"
                % (ram, found[ram], want))
        else:
            ok("%s: recipe DomA %d MiB matches BUDGET" % (ram, want))

    if "do_install[vardeps] += \"BOARD_RAM\"" in rec:
        ok("do_install[vardeps] includes BOARD_RAM (no stale doma.cfg from sstate)")
    else:
        err("do_install[vardeps] does not include BOARD_RAM: switching SKUs could "
            "reuse a doma.cfg carrying the other board's memory value")

    # Both toolstack-carrying builders must inject BOARD_RAM. In the zephyr flavour
    # DomD runs xl and reads its own /etc/xen/doma.cfg; in the linux flavour Dom0
    # does, from the dom0-thin rootfs. meta-xt-doma installs xt-xen-cfg-doma into
    # both images, so a builder without BOARD_RAM silently ships the 16g value.
    if not os.path.exists(SODEV_YAML):
        err("missing %s" % SODEV_YAML)
        return
    y = open(SODEV_YAML).read()
    n = len(re.findall(r'^\s*-\s*\[BOARD_RAM,\s*"%\{BOARD_RAM\}"\]\s*$', y, re.M))
    if n >= 2:
        ok("rpi5-sodev.yaml injects BOARD_RAM into %d builder confs "
           "(domd + dom0, both install xt-xen-cfg-doma)" % n)
    else:
        err("rpi5-sodev.yaml injects BOARD_RAM into only %d builder conf(s); both the "
            "domd and the dom0 component need it, because each flavour's toolstack "
            "reads its OWN /etc/xen/doma.cfg and the 8g value would silently fall "
            "back to the 16g default in the one that is missing it" % n)


def report_budget(ram, strict):
    b = BUDGET[ram]
    total = sum(b.values())
    usable = USABLE_MiB[ram]
    detail = " + ".join("%s %d" % (k, v) for k, v in b.items())
    src = "measured" if USABLE_MEASURED[ram] else "EXTRAPOLATED, not measured"
    print("  ----  %s budget: %s = %d MiB (+ Xen ~%d) vs %d MiB usable (%s)"
          % (ram, detail, total, XEN_OVERHEAD_MiB, usable, src))
    if total + XEN_OVERHEAD_MiB > usable:
        short = total + XEN_OVERHEAD_MiB - usable
        msg = ("%s: OVER-COMMIT by %d MiB with all four domains (DomZ's 16 MiB not counted) -- "
               "`xl create doma.cfg` is expected to fail to allocate at run time"
               % (ram, short))
        if strict:
            err(msg)
        else:
            warn(msg)
        without_doma = total - b["DomA"] + XEN_OVERHEAD_MiB
        print("  ----  %s without DomA: %d MiB of %d MiB usable -- fits"
              % (ram, without_doma, usable))
    else:
        ok("%s: all four domains fit (%d MiB headroom; DomZ's 16 MiB heap allocation not counted)"
           % (ram, usable - total - XEN_OVERHEAD_MiB))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ram", choices=["16g", "8g"], action="append",
                    help="check only this SKU (repeatable; default: both)")
    ap.add_argument("--strict-budget", action="store_true",
                    help="treat an over-committed budget as a failure")
    args = ap.parse_args()
    skus = args.ram or ["16g", "8g"]

    for p in [DTSO] + list(BOOTCMDS.values()):
        if not os.path.exists(p):
            raise SystemExit("ERROR: missing %s" % p)

    banks16, mem16 = parse_dtso()

    # The 8g override must be present, identical, in BOTH boot scripts. A single-sided
    # edit would silently leave one Dom0 flavour on the 16 GB map.
    eight = {}
    for flavour, path in BOOTCMDS.items():
        eight[flavour] = parse_bootcmd_8g(path)

    print("== boot script 8g override ==")
    missing = [f for f, v in eight.items() if v is None]
    if missing:
        err("no board_ram=8g override block found in: %s" % ", ".join(sorted(missing)))
        banks8 = mem8 = None
    elif eight["zephyr"] != eight["linux"]:
        err("the 8g override differs between the zephyr and linux boot scripts")
        banks8, mem8 = eight["zephyr"]
    else:
        banks8, mem8 = eight["zephyr"]
        ok("both boot scripts carry an identical board_ram=8g override")

    check_dom0_mem_in_bootcmds()

    for flavour, path in BOOTCMDS.items():
        src = open(path).read()
        if "setenv board_ram BOARD_RAM_PLACEHOLDER" not in src:
            err("%s: `setenv board_ram BOARD_RAM_PLACEHOLDER` line is missing "
                "(the bbappend substitutes it and bbfatals if absent)" % flavour)
        else:
            ok("%s: BOARD_RAM_PLACEHOLDER line present" % flavour)

    check_doma_mem()

    maps = {"16g": (banks16, mem16), "8g": (banks8, mem8)}
    for ram in skus:
        banks, mem = maps[ram]
        print("== %s ==" % ram)
        if banks is None:
            err("%s: map could not be parsed; skipping its checks" % ram)
            continue
        check_no_overlap(banks, ram)
        check_sum(banks, mem, ram)
        check_in_dram(banks, ram, ram)
        check_loads_clear(banks, ram)
        check_dom0_bank0(banks, ram, ram)
        check_domd_size(banks, ram)
        report_budget(ram, args.strict_budget)

    if banks8 is not None and set(skus) == {"16g", "8g"}:
        print("== 16g vs 8g ==")
        check_shrink_only(banks16, banks8)

    print()
    print("%d failure(s), %d warning(s)" % (len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
