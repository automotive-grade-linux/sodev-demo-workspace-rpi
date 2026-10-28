#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Cross-check the Raspberry Pi 4 memory map against the files that define it.

The Pi 5 has tools/check-memory-map.py; this is the Pi 4's, and it exists because
the Pi 4's map is the tighter one and had no automated check behind it at all --
rpi4-sodev.yaml claimed the Pi 5 tool covered both SKUs, which it never did (its
--ram takes only 16g and 8g, and its DRAM tables are BCM2712's).

Derived from, never duplicated:
  * bcm2711-raspberrypi4-64-xen.dtso  -- the 8 GiB DomD banks and `memory`
  * boot.cmd.xen.{zephyr,linux}-dom0.in
      - the `board_ram=4g` override block (DomD 1056)
      - the `venus_lane=yes` sub-block inside it (DomD 1440; the Vulkan lane)
      - every fatload destination, including the indented `if fatload` ones
      - DomD's `cma=`/`swiotlb=` (the `domd_cma` variable, per SKU)
  * bcm2711-raspberrypi4-64-domd-vc4.dts       -- soc_bus's VideoCore window
  * meta-xt-rpi4/.../xt-xen-cfg-doma_%.bbappend  -- DomA's size per lane
  * boot.cmd.xen.{zephyr,linux}-dom0.in          -- Dom0's size, from the live
      xen,xen-bootargs (both files also mention other dom0_mem values in comments)
  * meta-xt-domu/.../files/domu.cfg              -- DomU's size
  * rpi4-sodev.yaml, rpi5-sodev.yaml             -- XT_DOMA_HWDEC per GPU lane
      and Dom0 flavour

What it checks, and why each one can actually go wrong:

  1. banks do not overlap each other -- a hand-edited static-mem cell list is easy
     to get wrong, and Xen's assign_static_memory_11() does not diagnose it;
  2. `memory = <hi lo>` (KiB) equals the sum of that lane's banks -- the two are
     edited together by hand and Xen believes `memory`;
  3. every bank lies inside real DRAM for the 4 GiB SKU -- a bank in a hole boots
     to a hang, not to an error;
  4. no fatload destination lands inside a static-mem bank -- Xen copies modules
     out before the domain runs, but a clobbered source is silent;
  5. the 4g block is byte-identical in the two Dom0 flavours -- they are separate
     files and the block's own comment requires it;
  6. the Venus override grows ONLY bank@0x40000000 -- the low bank is the only
     VideoCore-visible window and carries DomD's CMA and ZONE_DMA;
  7. the domain budget fits 3956 MiB for every (SKU, Dom0 flavour, lane) -- DomZ
     only on 8 GiB, build.sh refuses it on 4 GiB -- and the
     Venus transfer does not grow the total: DomA gives up at least what DomD gains;
  8. DomA's size in the bbappend agrees with what the boot script's echo claims;
  9. DomD's low bank lies inside soc_bus's dma-ranges in the DomD DT -- outside it
     the VideoCore cannot reach DomD's CMA;
 10. CMA + swiotlb + 64 MiB of ordinary ZONE_DMA fit in the low bank, per SKU --
     the decoder's buffers and the order-10 GFP_DMA fallback both live there;
 11. DomA is at most 2048 MiB in the 4 GiB Venus lane -- above that the guest gets
     a second, small memory zone and AOSP's extra_free_kbytes.sh miscomputes
     watermark_scale_factor (see the bbappend);
 12. in both board yamls XT_DOMA_HWDEC is false on the gl lane, and true on
     the vulkan lane with the zephyr Dom0 -- the guest's decoder needs the
     qemu 10.0.2 or 11.1.2 device model and, on 4 GiB, the venus lane's 1440 MiB
     DomD.

Usage: tools/check-rpi4-memory-map.py [--strict-budget]
Exit status is non-zero if any check fails. --strict-budget additionally fails the
one over-commitment that is intended: DomU and DomA together on the 4 GiB SKU.
"""

import os
import re
import sys

MiB = 1024 * 1024
GiB = 1024 * MiB

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPI4 = os.path.join(ROOT, "meta-rpi-sodev", "meta-xt-rpi4")
XEN_DTSO = os.path.join(RPI4, "recipes-kernel", "linux", "files",
                        "bcm2711-raspberrypi4-64-xen.dtso")
BOOTCMDS = {
    "zephyr": os.path.join(RPI4, "recipes-bsp", "xt-rpi-u-boot-scr", "files",
                           "raspberrypi4-64", "boot.cmd.xen.zephyr-dom0.in"),
    "linux": os.path.join(RPI4, "recipes-bsp", "xt-rpi-u-boot-scr", "files",
                          "raspberrypi4-64", "boot.cmd.xen.linux-dom0.in"),
}
DOMA_BBAPPEND = os.path.join(RPI4, "recipes-extended", "xt-xen-cfg-doma",
                             "xt-xen-cfg-doma_%.bbappend")

# What the firmware reports with gpu_mem=76, from the BOARD_RAM block of
# rpi4-sodev.yaml (which in turn recorded it from the board). The 4 GiB SKU has no
# range above 4 GiB at all, which is the whole reason the 4g map exists.
#
# CAREFUL: these are (lo, hi_exclusive) pairs, NOT the (base, size) pairs that
# `banks` uses everywhere else in this file. They are named DRAM_RANGES for that
# reason -- rewriting them as (base, size) without changing the containment test
# would make it pass for banks that are NOT in DRAM, which is the direction that
# hides a fault. The self-check below is what catches such an edit: the ranges must
# sum to USABLE_MiB, which they do not if read the other way.
DRAM_RANGES = {
    "4g": [(0x00000000, 0x3B400000), (0x40000000, 0xFC000000)],
    "8g": [(0x00000000, 0x3B400000), (0x40000000, 0xFC000000),
           (0x100000000, 0x200000000)],
}
USABLE_MiB = {"4g": 3956, "8g": 8052}
for _sku, _r in DRAM_RANGES.items():
    _sum = sum(hi - lo for lo, hi in _r) // MiB
    if _sum != USABLE_MiB[_sku]:
        raise SystemExit("ERROR: DRAM_RANGES[%r] sums to %d MiB but USABLE_MiB says "
                         "%d -- the pairs are (lo, hi_exclusive); if they were just "
                         "changed to (base, size) that is the bug"
                         % (_sku, _sum, USABLE_MiB[_sku]))

# Measured, not assumed: 3956 - assigned - `xl info` free_memory came to 78/79/80
# across three DomD sizes on the 4 GiB board, so use the worst.
#
# Those runs had DomU (1 vCPU, 1024 MiB) as the guest, so the 80 includes
# DomU's libxl paging pool, 4 KiB x (256 x vCPUs + MiB + 128) = 5.5 MiB.
# DomA's (2 vCPUs) is 12.5 MiB at 2560 and 10.5 MiB at 2048, 7 and 5 MiB more
# than this budget counts, so a DomA spare below that is not a margin it can
# promise. build.sh warns about the one combination that has one: the 4 GiB
# gl lane with a linux Dom0.
XEN_OVERHEAD_MiB = 80
# Dom0 differs by flavour, and both values are placement levers for
# allocate_memory_11() rather than requirements. DERIVED, not duplicated -- this
# file's whole premise is that it re-reads the sources, and hard-coding these
# two here would be the same drift the rest of it exists to prevent.
DOMU_CFG = os.path.join(ROOT, "meta-rpi-sodev", "meta-xt-common", "meta-xt-domu",
                        "recipes-extended", "xt-xen-cfg-domu", "files", "domu.cfg")

# DomZ is a 16 MiB Zephyr guest, and the size is NOT a tunable: Zephyr uses a static
# memory map, so the cfg's `memory` has to match the xenvm board's memory@40000000
# node. Parsed rather than hard-coded, for the same reason as the two above.
DOMZ_CFG = os.path.join(ROOT, "meta-rpi-sodev", "meta-xt-common", "meta-xt-domz",
                        "recipes-guests", "domz", "files", "domz.cfg")

# Both board yamls, for the one cross-check that is not about memory: the guest's
# hardware-decode build has to be gated on the SAME lane as the memory transfer.
BOARD_YAMLS = {b: os.path.join(ROOT, "%s-sodev.yaml" % b) for b in ("rpi4", "rpi5")}

# A module's load slot. The address is parsed; the size is not knowable here, so a
# flat slot is assumed. Over-reserving can only cause a false alarm, never hide a
# real overlap. The largest real module is the ~27 MiB DomD Image.
MODULE_SLOT_BYTES = 32 * MiB

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ok   %s" % msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print("  FAIL %s" % msg)


def hdr(msg):
    print("\n== %s ==" % msg)


def read(path):
    with open(path) as f:
        return f.read()


def cells_to_banks(text):
    """<0x0 0x40000000 0x0 0x28000000 ...> -> [(base, size), ...] (2 cells each)."""
    words = [int(w, 16) for w in re.findall(r"0x[0-9a-fA-F]+", text)]
    if len(words) % 4:
        raise SystemExit("ERROR: %d cells is not a whole number of banks" % len(words))
    banks = []
    for i in range(0, len(words), 4):
        base = (words[i] << 32) | words[i + 1]
        size = (words[i + 2] << 32) | words[i + 3]
        banks.append((base, size))
    return banks


def parse_dtso():
    """The 8 GiB DomD map: (banks, memory_kib) from the host overlay."""
    s = read(XEN_DTSO)
    m = re.search(r"memory\s*=\s*<([^>]*)>", s)
    sm = re.search(r"xen,static-mem\s*=\s*<([^>]*)>", s, re.S)
    if not m or not sm:
        raise SystemExit("ERROR: no memory/xen,static-mem in %s" % XEN_DTSO)
    c = [int(w, 16) for w in re.findall(r"0x[0-9a-fA-F]+", m.group(1))]
    if len(c) != 2:
        raise SystemExit("ERROR: dtso memory is not 2 cells")
    return cells_to_banks(sm.group(1)), (c[0] << 32) | c[1]


def extract_4g_block(path):
    """The whole `if test board_ram = 4g` block, comments included."""
    s = read(path)
    m = re.search(r'^if test "\$\{board_ram\}" = "4g" ; then\n(.*?)^fi$',
                  s, re.M | re.S)
    if not m:
        raise SystemExit("ERROR: no board_ram=4g block in %s" % path)
    return m.group(0)


def parse_lane(block, venus):
    """(banks, memory_kib) for the 4g base lane or its venus override."""
    # The venus override is the inner `if test venus_lane = yes` block; the base
    # lane is what precedes it.
    inner = re.search(r'^\s+if test "\$\{venus_lane\}" = "yes" ; then\n(.*?)^\s+fi$',
                      block, re.M | re.S)
    if not inner:
        raise SystemExit("ERROR: no venus_lane sub-block in the 4g block")
    text = inner.group(1) if venus else block[:inner.start()]
    mem = re.findall(r"fdt set /chosen/domD memory <([^>]*)>", text)
    sm = re.findall(r"fdt set /chosen/domD xen,static-mem <([^>]*)>", text)
    if len(mem) != 1 or len(sm) != 1:
        raise SystemExit("ERROR: expected one memory and one static-mem line, got "
                         "%d/%d (venus=%s)" % (len(mem), len(sm), venus))
    c = [int(w, 16) for w in re.findall(r"0x[0-9a-fA-F]+", mem[0])]
    return cells_to_banks(sm[0]), (c[0] << 32) | c[1]


def parse_fatloads(path):
    return [int(m, 16) for m in
            re.findall(r"^\s*(?:if\s+)?fatload\s+mmc\s+\d+\s+(0x[0-9a-fA-F]+)",
                       read(path), re.M)]


# Ordinary (non-CMA) ZONE_DMA left in DomD's low bank: the CMA failure mode measured
# on 2026-09-15 fell back to order-10 GFP_DMA allocations there, and 64 MiB is what
# the 8 GiB map has always left.
ZONE_DMA_RESERVE_MiB = 64
# Linux's default swiotlb when no `swiotlb=` is given (IO_TLB_DEFAULT_SIZE).
SWIOTLB_DEFAULT_MiB = 64
DOMD_DTS = os.path.join(RPI4, "recipes-guest", "domd-vc4", "files",
                        "bcm2711-raspberrypi4-64-domd-vc4.dts")


def parse_soc_window():
    """(phys, size) of soc_bus's dma-ranges in the DomD DT."""
    m = re.search(r"soc_bus: soc-bus \{.*?dma-ranges = <([^>]*)>;", read(DOMD_DTS), re.S)
    if not m:
        raise SystemExit("ERROR: no soc_bus dma-ranges in %s" % DOMD_DTS)
    c = [int(w, 16) for w in m.group(1).split()]
    if len(c) != 6:
        raise SystemExit("ERROR: soc_bus dma-ranges is not one <child parent size> "
                         "triple of 2-cell values: %s" % m.group(1))
    return (c[2] << 32) | c[3], (c[4] << 32) | c[5]


def parse_domd_cma(block):
    """{"8g": (cma MiB, swiotlb MiB), "4g": (...)} from the `domd_cma` variable:
    the default set just before the 4g block, and the override inside it."""
    def one(v):
        c = re.search(r"\bcma=(\d+)M\b", v)
        if not c:
            raise SystemExit("ERROR: domd_cma %r has no cma=<n>M" % v)
        t = re.search(r"\bswiotlb=(\d+)\b", v)
        return int(c.group(1)), (int(t.group(1)) * 2048 // MiB if t else SWIOTLB_DEFAULT_MiB)
    out = {}
    for f, p in BOOTCMDS.items():
        s = read(p)
        d = re.findall(r'^setenv domd_cma "?([^"\n]*)"?$', s, re.M)
        if len(d) != 1:
            raise SystemExit("ERROR: %s must set the domd_cma default exactly once at "
                             "top level, found %d" % (p, len(d)))
        # The default is outside the 4g block, so check 5 does not compare
        # it; the 8 GiB rows below take the first flavour's, and the other
        # has to match.
        v = one(d[0])
        if out.setdefault("8g", v) != v:
            bad("%s sets the domd_cma default to cma=%dM, swiotlb %d MiB; "
                "the other flavour to cma=%dM, swiotlb %d MiB"
                % ((f,) + v + out["8g"]))
    inner = re.findall(r'^\s+setenv domd_cma "?([^"\n]*)"?$', block, re.M)
    if len(inner) != 1:
        raise SystemExit("ERROR: the 4g block must override domd_cma exactly once, "
                         "found %d" % len(inner))
    out["4g"] = one(inner[0])
    return out


def parse_doma_mem():
    """{(sku, lane): MiB} from the bbappend's inline-python expression.

    Reading the two numbers out of a conditional expression is order-dependent, and
    a rewrite as `'2560' if not(...) else '2176'` would be read backwards -- which
    the "the transfer is neutral" check below could not catch, because -384/+384 sums
    to zero just as well as +384/-384. So pin the shape rather than just the digits:
    the expression must be `'<venus 4g value>' if <condition> else '<other>'`, the
    condition must name both the 4 GiB SKU and the VENUS_LANE gate (the same
    two-valued variable the sibling xt-rpi-u-boot-scr.bbappend uses), and the value
    the condition selects must be the SMALLER one -- the Venus lane gives memory
    away.
    """
    s = read(DOMA_BBAPPEND)
    m = re.search(r"DOMA_MEM_MiB:raspberrypi4-64\s*=\s*\"(.*)\"", s)
    if not m:
        raise SystemExit("ERROR: no DOMA_MEM_MiB in %s" % DOMA_BBAPPEND)
    expr = m.group(1)
    shape = re.match(r"^\$\{@'(\d+)' if (.+) else '(\d+)'\}$", expr.strip())
    if not shape:
        raise SystemExit("ERROR: DOMA_MEM_MiB is not of the form "
                         "\"${@'N' if <cond> else 'M'}\"; this checker reads it "
                         "positionally and would misread anything else:\n  %s" % expr)
    venus_4g, cond, other = int(shape.group(1)), shape.group(2), int(shape.group(3))
    for want in ("'4g'", "VENUS_LANE"):
        if want not in cond:
            raise SystemExit("ERROR: the DOMA_MEM_MiB condition does not mention %s, "
                             "so it is not the (4 GiB SKU and Venus lane) gate this "
                             "checker assumes:\n  %s" % (want, cond))
    if venus_4g > other:
        raise SystemExit("ERROR: the condition selects %d MiB, which is LARGER than "
                         "the %d MiB it falls back to -- the Venus lane is supposed "
                         "to give memory to DomD, so this reads inverted:\n  %s"
                         % (venus_4g, other, expr))
    return {("4g", "venus"): venus_4g, ("4g", "base"): other,
            ("8g", "venus"): other, ("8g", "base"): other}


def parse_dom0_mem():
    """{flavour: MiB} from each boot script's live dom0_mem, not from a comment.

    The Zephyr flavour writes the value into xen,xen-bootargs literally; the Linux
    one writes ${dom0mem} and sets it with `setenv dom0mem 256M`. Both files also
    MENTION other values in comments (1024M, 512M) while reasoning about
    allocate_memory_11(), so a naive grep for dom0_mem= picks the wrong one --
    hence the two shapes below and the "exactly one" requirement.
    """
    out = {}
    for flavour, path in BOOTCMDS.items():
        s = read(path)
        args = re.findall(r'fdt set /chosen xen,xen-bootargs "([^"]*)"', s)
        if len(args) != 1:
            raise SystemExit("ERROR: %s has %d xen,xen-bootargs lines, expected 1"
                             % (path, len(args)))
        m = re.search(r"dom0_mem=(\$\{(\w+)\}|(\d+)M)", args[0])
        if not m:
            raise SystemExit("ERROR: no dom0_mem in %s's xen,xen-bootargs" % path)
        if m.group(3):
            out[flavour] = int(m.group(3))
            continue
        var = m.group(2)
        sets = re.findall(r"^setenv\s+%s\s+(\d+)M\s*$" % re.escape(var), s, re.M)
        if len(sets) != 1:
            raise SystemExit("ERROR: %s sets ${%s} %d times, expected 1"
                             % (path, var, len(sets)))
        out[flavour] = int(sets[0])
    return out


def parse_domu_mem():
    """DomU's size in MiB from domu.cfg -- libxl's `memory` is already MiB."""
    s = read(DOMU_CFG)
    m = re.findall(r"^memory\s*=\s*(\d+)\s*$", s, re.M)
    if len(m) != 1:
        raise SystemExit("ERROR: %s has %d `memory =` lines, expected 1"
                         % (DOMU_CFG, len(m)))
    return int(m[0])


def parse_domz_mem():
    """DomZ's `memory =` from its xl config, in MiB."""
    m = re.search(r"^memory\s*=\s*(\d+)\s*$", read(DOMZ_CFG), re.M)
    if not m:
        raise SystemExit("could not read `memory =` from %s" % DOMZ_CFG)
    return int(m.group(1))


def parse_hwdec_gate(path):
    """XT_DOMA_HWDEC as the GPU parameter sets it, per lane.

    The value reaches the AOSP build through the doma builder's env, and the guest's
    hardware-decode additions are inside `ifeq ($(XT_DOMA_HWDEC),true)`. It must
    never be true off the venus lane: the decoder the guest talks to is a
    virtio-media device, which only the qemu 10.0.2 and 11.1.2 device models have.

    The vulkan branch names %{XT_DOMA_HWDEC_VULKAN}, which the top-level
    variables set and a Dom0 flavour can override, so the result is per
    (lane, flavour), and a reference is resolved the way moulin resolves it:
    the flavour's own variables first, then the top-level ones.
    """
    text = read(path)

    def var(block, name):
        m = re.search(r'^\s*%s:\s*"([^"]*)"' % name, block, re.M)
        return m.group(1) if m else None

    # The GPU branches are `    "gl":` / `    "vulkan":` at four spaces of
    # indent inside `  GPU:`, the flavours `    zephyr:` / `    linux:` inside
    # `  DOM0_OS:`; each branch runs up to the next one or the next key.
    top = re.search(r"^variables:\n(.*?)(?=^[a-z])", text, re.M | re.S)
    dom0 = re.search(r"^  DOM0_OS:\n(.*?)(?=^  \S)", text, re.M | re.S)
    gpu = re.search(r"^  GPU:\n(.*?)(?=^  \S)", text, re.M | re.S)
    if not (top and dom0 and gpu):
        raise SystemExit("no variables, DOM0_OS or GPU in %s" % path)
    out = {}
    for flavour in ("zephyr", "linux"):
        fl = re.search(r"^    %s:\n(.*?)(?=^    \S|\Z)" % flavour,
                       dom0.group(1), re.M | re.S)
        for lane in ("gl", "vulkan"):
            br = re.search(r'^    "%s":\n(.*?)(?=^    "|\Z)' % lane,
                           gpu.group(1), re.M | re.S)
            v = var(br.group(1), "XT_DOMA_HWDEC") if br else None
            ref = re.fullmatch(r"%\{(\w+)\}", v or "")
            if ref:
                v = (var(fl.group(1), ref.group(1)) if fl else None) \
                    or var(top.group(1), ref.group(1))
            out[(lane, flavour)] = v
    return out


def check_banks(banks, memory_kib, sku, label):
    s = sorted(banks)
    overlap = False
    for (b0, s0), (b1, s1) in zip(s, s[1:]):
        if b0 + s0 > b1:
            bad("%s: banks overlap: 0x%x+0x%x and 0x%x+0x%x" % (label, b0, s0, b1, s1))
            overlap = True
    if not overlap:
        ok("%s: %d banks, no overlap" % (label, len(banks)))

    total = sum(sz for _, sz in banks)
    if total != memory_kib * 1024:
        bad("%s: memory = %d KiB (%d MiB) but the banks sum to %d MiB"
            % (label, memory_kib, memory_kib // 1024, total // MiB))
    else:
        ok("%s: memory = %d MiB matches the banks" % (label, total // MiB))

    outside = [(b, sz) for b, sz in banks
               if not any(lo <= b and b + sz <= hi for lo, hi in DRAM_RANGES[sku])]
    if outside:
        for b, sz in outside:
            bad("%s: bank 0x%x+0x%x is not inside %s DRAM" % (label, b, sz, sku))
    else:
        ok("%s: every bank is inside real %s DRAM" % (label, sku))


def check_modules(banks, path, label):
    clashes = []
    for addr in parse_fatloads(path):
        for b, sz in banks:
            if b <= addr < b + sz or b <= addr + MODULE_SLOT_BYTES - 1 < b + sz:
                clashes.append((addr, b, sz))
    if clashes:
        for addr, b, sz in clashes:
            bad("%s: fatload to 0x%x lands in static-mem bank 0x%x+0x%x"
                % (label, addr, b, sz))
    else:
        ok("%s: no fatload destination lands in a static-mem bank" % label)


def main():
    strict = "--strict-budget" in sys.argv[1:]
    dom0_mem = parse_dom0_mem()
    domu_mem = parse_domu_mem()
    domz_mem = parse_domz_mem()
    print("Raspberry Pi 4 memory map cross-check")
    print("  overlay   : %s" % os.path.relpath(XEN_DTSO, ROOT))
    for f, p in BOOTCMDS.items():
        print("  boot.cmd  : %s (%s, dom0_mem=%d MiB)"
              % (os.path.relpath(p, ROOT), f, dom0_mem[f]))
    print("  domu.cfg  : %s (DomU %d MiB)"
          % (os.path.relpath(DOMU_CFG, ROOT), domu_mem))
    print("  domz.cfg  : %s (DomZ %d MiB)"
          % (os.path.relpath(DOMZ_CFG, ROOT), domz_mem))

    # --- the two boot scripts must agree on the 4g block --------------------
    hdr("the 4g block is the same in both Dom0 flavours")
    blocks = {f: extract_4g_block(p) for f, p in BOOTCMDS.items()}
    if blocks["zephyr"] == blocks["linux"]:
        ok("byte-identical (%d bytes)" % len(blocks["zephyr"]))
    else:
        bad("the zephyr and linux flavours' 4g blocks differ")

    block = blocks["zephyr"]
    domd = {
        ("8g", "base"): parse_dtso(),
        # The 8 GiB map is deliberately identical in both lanes: Venus's ~100 MiB is
        # noise against DomD's 1920 MiB there. Same input on purpose, so the bank
        # checks for ("8g", "venus") re-run the same assertions -- they are counted,
        # but they are not additional coverage. What IS checked for 8g is the budget
        # with DomA's own per-lane size, and the transfer-neutrality below.
        ("8g", "venus"): parse_dtso(),
        ("4g", "base"): parse_lane(block, venus=False),
        ("4g", "venus"): parse_lane(block, venus=True),
    }

    # --- banks, sums, DRAM containment, module clashes ----------------------
    for (sku, lane), (banks, mem_kib) in sorted(domd.items()):
        hdr("DomD banks: %s / %s lane" % (sku, lane))
        check_banks(banks, mem_kib, sku, "DomD %s/%s" % (sku, lane))
        for f, p in BOOTCMDS.items():
            check_modules(banks, p, "DomD %s/%s vs %s modules" % (sku, lane, f))

    # --- the Venus override must not touch the VideoCore window -------------
    hdr("the Venus override only grows the high bank")
    base = dict(domd[("4g", "base")][0])
    venus = dict(domd[("4g", "venus")][0])
    lows = {b for b in set(base) | set(venus) if b < GiB}
    LOW = min(lows) if lows else 0
    if len(lows) != 1 or base.get(LOW) is None or venus.get(LOW) is None:
        bad("no bank at 0x%x in one of the 4g lanes -- the VideoCore/ZONE_DMA "
            "window must exist in both" % LOW)
    elif base[LOW] != venus[LOW]:
        bad("the Venus lane changes bank@0x%x from %d to %d MiB; it carries vc4's "
            "CMA and DomD's ZONE_DMA and must not move"
            % (LOW, base[LOW] // MiB, venus[LOW] // MiB))
    else:
        ok("bank@0x%x is %d MiB in both lanes" % (LOW, base[LOW] // MiB))
    changed = {b for b in set(base) | set(venus) if base.get(b) != venus.get(b)}
    if changed == {0x40000000}:
        ok("only bank@0x40000000 differs: %d -> %d MiB"
           % (base[0x40000000] // MiB, venus[0x40000000] // MiB))
    else:
        bad("the Venus lane changes banks %s; only 0x40000000 should differ"
            % ", ".join("0x%x" % b for b in sorted(changed)))

    # --- the budget ---------------------------------------------------------
    doma = parse_doma_mem()
    for sku in ("8g", "4g"):
        for lane in ("base", "venus"):
            hdr("budget: %s / %s lane" % (sku, lane))
            domd_mib = domd[(sku, lane)][1] // 1024
            for flavour, dom0 in sorted(dom0_mem.items()):
                fixed = XEN_OVERHEAD_MiB + dom0 + domd_mib
                room = USABLE_MiB[sku] - fixed
                print("       %s dom0: Xen %d + Dom0 %d + DomD %d = %d MiB, "
                      "%d MiB left for guests"
                      % (flavour, XEN_OVERHEAD_MiB, dom0, domd_mib, fixed, room))
                # DomZ is a fixed 16 MiB when build.sh is given -z, and it is
                # additive: it runs alongside whichever guest is up, so every
                # combination below is also checked with it.
                for guest, size in (("DomU", domu_mem),
                                    ("DomA", doma[(sku, lane)]),
                                    ("DomA+DomZ", doma[(sku, lane)] + domz_mem),
                                    ("DomU+DomZ", domu_mem + domz_mem),
                                    ("both", domu_mem + doma[(sku, lane)])):
                    if sku == "4g" and "DomZ" in guest:
                        # build.sh refuses -z on the 4 GiB RPi4, so these are not
                        # images anyone can build.
                        print("       (not built) %s/%s/%s: %s -- build.sh refuses -z "
                              "on 4g" % (sku, lane, flavour, guest))
                        continue
                    fits = size <= room
                    if fits:
                        ok("%s/%s/%s: %s (%d MiB) fits, %d MiB spare"
                           % (sku, lane, flavour, guest, size, room - size))
                    elif sku == "4g" and guest == "both" and not strict:
                        # Documented and intended: the 4 GiB SKU runs one guest at a
                        # time. --strict-budget turns it into a failure for anyone who
                        # wants the stronger invariant.
                        print("       (expected) %s/%s/%s: both guests (%d MiB) do "
                              "NOT fit in %d MiB -- that needs the 8 GiB SKU"
                              % (sku, lane, flavour, size, room))
                    else:
                        bad("%s/%s/%s: %s (%d MiB) exceeds the %d MiB left"
                            % (sku, lane, flavour, guest, size, room))

    # --- the Venus transfer must be neutral --------------------------------
    hdr("the Venus transfer is a redistribution, not a new commitment")
    for sku in ("8g", "4g"):
        d_delta = domd[(sku, "venus")][1] // 1024 - domd[(sku, "base")][1] // 1024
        a_delta = doma[(sku, "venus")] - doma[(sku, "base")]
        if d_delta + a_delta <= 0:
            ok("%s: DomD %+d MiB, DomA %+d MiB, total %+d MiB"
               % (sku, d_delta, a_delta, d_delta + a_delta))
        else:
            bad("%s: DomD %+d MiB but DomA only %+d MiB -- the total grows by %+d MiB"
                % (sku, d_delta, a_delta, d_delta + a_delta))

    # --- DomA must keep one memory zone on the 4 GiB Venus lane -------------
    hdr("DomA fits in GUEST_RAM0 on the 4 GiB Venus lane")
    if doma[("4g", "venus")] <= 2048:
        ok("4g/venus: DomA %d MiB <= 2048 MiB, so the guest has ZONE_DMA32 only"
           % doma[("4g", "venus")])
    else:
        bad("4g/venus: DomA %d MiB puts %d MiB above 4 GiB as a separate small zone; "
            "AOSP's extra_free_kbytes.sh then writes a huge watermark_scale_factor"
            % (doma[("4g", "venus")], doma[("4g", "venus")] - 2048))

    # --- the low bank must be inside the VideoCore window -------------------
    hdr("DomD's low bank is inside soc_bus's VideoCore window")
    win = parse_soc_window()
    print("       soc_bus dma-ranges: phys 0x%x + %d MiB" % (win[0], win[1] // MiB))
    for (sku, lane), (banks, _) in sorted(domd.items()):
        low = [(b, sz) for b, sz in banks if b < GiB]
        if len(low) == 1 and win[0] <= low[0][0] and low[0][0] + low[0][1] <= win[0] + win[1]:
            ok("%s/%s: bank 0x%x+%d MiB is inside the window"
               % (sku, lane, low[0][0], low[0][1] // MiB))
        else:
            bad("%s/%s: low bank(s) %s are not exactly one bank inside the window"
                % (sku, lane, ["0x%x+%dM" % (b, sz // MiB) for b, sz in low]))

    # --- CMA + swiotlb + ZONE_DMA fit the low bank ---------------------------
    hdr("DomD's CMA, swiotlb and ZONE_DMA fit the low bank")
    cma = parse_domd_cma(block)
    for f, p in BOOTCMDS.items():
        if re.search(r'module@0 bootargs "[^"]*\$\{domd_cma\}', read(p)):
            ok("%s: DomD bootargs take ${domd_cma}" % f)
        else:
            bad("%s: DomD bootargs do not use ${domd_cma}, so the per-SKU value is "
                "not what DomD boots with" % f)
    for (sku, lane), (banks, _) in sorted(domd.items()):
        low = [sz for b, sz in banks if b < GiB]
        c_mib, t_mib = cma["4g" if sku == "4g" else "8g"]
        need = c_mib + t_mib + ZONE_DMA_RESERVE_MiB
        if low and need <= low[0] // MiB:
            ok("%s/%s: CMA %d + swiotlb %d + ZONE_DMA %d = %d MiB <= bank %d MiB"
               % (sku, lane, c_mib, t_mib, ZONE_DMA_RESERVE_MiB, need, low[0] // MiB))
        else:
            bad("%s/%s: CMA %d + swiotlb %d + ZONE_DMA %d = %d MiB does not fit the "
                "low bank (%s MiB)" % (sku, lane, c_mib, t_mib, ZONE_DMA_RESERVE_MiB,
                                       need, low[0] // MiB if low else "none"))

    # --- the boot script's own echo must not lie ---------------------------
    hdr("the boot script's messages match the values")
    for lane, venus in (("base", False), ("venus", True)):
        banks, mem_kib = domd[("4g", lane)]
        mib = mem_kib // 1024
        echoes = re.findall(r'echo "([^"]*)"', block)
        # \b so that 1024 does not match "10240" or "1024x768"; the echo says
        # "DomD 1440 MiB", so require the unit too.
        want = re.compile(r"\b%d MiB\b" % mib)
        hit = [e for e in echoes if want.search(e) and
               (("venus_lane=yes" in e) == venus)]
        if hit:
            ok("4g/%s: an echo mentions %d MiB (%r)" % (lane, mib, hit[0][:60]))
        else:
            bad("4g/%s: no echo mentions DomD %d MiB -- the message would mislead "
                "whoever reads the console" % (lane, mib))
    a = doma[("4g", "venus")]
    a_re = re.compile(r"\b%d\b" % a)
    if any(a_re.search(e) for e in re.findall(r'echo "([^"]*)"', block)):
        ok("4g/venus: an echo mentions DomA %d MiB, matching the bbappend" % a)
    else:
        bad("4g/venus: the bbappend says DomA %d MiB but no echo mentions it" % a)

    # --- the hardware-decode gate must ride the venus lane -----------------
    #
    # This is the one check here that is not about addresses. It belongs in this file
    # because of what it prevents: the 4 GiB DomD growth to 1440 MiB is gated on
    # venus_lane, and hardware decode is what NEEDS that expansion (a 1024 MiB DomD
    # thrashes its page cache during 1080p playback). If XT_DOMA_HWDEC were ever
    # switched on for the gl lane, the guest would ask for a decoder that lane has no
    # device model for, and with DomD at only 1056 MiB. Widening the memory
    # gate instead would be the wrong fix: it would give the gl lane a DT that its
    # device model does not match.
    #
    # A Dom0 flavour may leave the decoder out on the vulkan lane too (rpi5's
    # linux flavour does), which is safe in both directions; what must hold is
    # false on gl in every flavour and true on vulkan with the zephyr Dom0, the
    # default.
    hdr("the hardware-decode gate follows the venus lane")
    for board, path in sorted(BOARD_YAMLS.items()):
        gate = parse_hwdec_gate(path)
        linux = gate[("vulkan", "linux")]
        if gate[("gl", "zephyr")] == gate[("gl", "linux")] == "false" \
                and gate[("vulkan", "zephyr")] == "true" \
                and linux in ("true", "false"):
            ok("%s: XT_DOMA_HWDEC is false on gl and true on vulkan "
               "(linux Dom0: %s)" % (board, linux))
        else:
            bad("%s: XT_DOMA_HWDEC is %r -- it must be false on gl and true "
                "on vulkan with the zephyr Dom0, because the decoder is a "
                "virtio-media device and only qemu 10.0.2 and 11.1.2 provide "
                "one"
                % (board, gate))

    print("\n%d ok, %d failure(s)" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
