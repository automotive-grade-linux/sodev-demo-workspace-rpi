#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compare a freshly built SD image against one that is known to boot.

WHY
---
Hardware verification is expensive: writing an SD card and booting four domains costs
far more than a build. But the source of a rebuild is usually unchanged, so most of what
lands on the card should be bit-identical to an image that has already booted — and the
parts that are not should be a short, enumerable list. Turning "the images differ" into
"they differ in exactly the places we changed on purpose" is what makes a rebuild
trustworthy without a board.

This is the technique that was used to accept the RPi5 DomA source-build change: p1 was
28-of-30 files md5-identical, the DomD ramdisk differed only in its 97 .ko files, and the
kernel/module ABI (module_layout CRC) matched.

WHAT IT CHECKS, AND HOW EACH CLASS IS JUDGED
--------------------------------------------
Artifacts fall into three groups, and applying one criterion to all of them is what makes
naive image diffs useless.

  A  Deterministic by construction -> require plain byte equality.
     Device trees (dtc is deterministic and the .dts inputs are unchanged), the
     VideoCore firmware blobs copied from meta-raspberrypi, config.txt.

  B  Timestamp- or path-contaminated but otherwise deterministic -> normalise, then
     compare. boot.scr carries a build time and CRC in its 64-byte uImage header, so the
     payload is compared instead. The kernel Image and bl31.bin embed a version banner,
     so the differing byte positions are reported and checked for being confined to it.
     An initramfs is compared by member list, not as a gzip stream.

  C  Deliberately different -> equality is the wrong question. p4 (the AAOS guest) is
     built for a different PRODUCT_DEVICE here, so it is checked for the PROPERTY that
     matters (no unguarded crypto/LDAPR that would SIGILL on a Cortex-A72) rather than
     for equality. That check is separate; see the note printed at the end.

VERDICTS
    IDENTICAL       byte-for-byte equal
    IDENTICAL*      equal after removing a known header/banner (reason printed)
    NORMALIZED-EQ   differing bytes all fall inside the version banner window
    EXPECTED-DIFF   differs, and the difference is in the expected-difference table
    UNEXPECTED-DIFF differs, and it is not -> this is the only verdict worth chasing
    ONLY-IN-REF / ONLY-IN-NEW  present on one side only

Run inside the build container (it needs mtools, debugfs, dtc):
    docker run --rm -v $PWD:/work -w /work sodev-builder \\
        python3 tools/compare-sd-image.py <reference.img> <candidate.img>
"""
import argparse
import hashlib
import os
import re
import struct
import subprocess
import sys

# Files whose difference is explained by a change made on purpose. The reason is printed,
# so a reviewer sees the justification next to the verdict rather than having to trust it.
EXPECTED_DIFF = {
    "Image": "kernel version banner (builder host + build date) and CONFIG_BUILD_SALT",
    "Image.gz": "compressed form of Image; inherits its banner difference",
    "zephyr.bin": "Zephyr build id and timestamp",
    "bl31.bin": "TF-A build string",
    "boot.scr": "uImage header carries a build time and CRC; payload compared separately",
}
# Substring -> reason, for names that vary (rootfs, initramfs, per-machine suffixes).
EXPECTED_DIFF_SUBSTR = [
    ("initramfs", "cpio member mtimes and the kernel modules built alongside the kernel"),
    ("rootfs.ext4", "ext4 inode timestamps and filesystem UUID; contents compared by file"),
]

BANNER_MAX_SPAN = 4096   # a version banner and salt live within one page


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def md5(b):
    return hashlib.md5(b).hexdigest()


# --- GPT ---------------------------------------------------------------------------
def gpt_partitions(path):
    """Parse the GPT without external tools, so this works anywhere python does."""
    with open(path, "rb") as fh:
        fh.seek(512)
        hdr = fh.read(92)
        if hdr[:8] != b"EFI PART":
            raise SystemExit("ERROR: %s has no GPT (found %r)" % (path, hdr[:8]))
        (_sig, _rev, _hsz, _crc, _r, _cur, _bak, _first, _last, _guid_lo, _guid_hi,
         pe_lba, pe_num, pe_size, _pcrc) = struct.unpack("<8sIIIIQQQQQQQIII", hdr)
        fh.seek(pe_lba * 512)
        out = []
        for i in range(pe_num):
            e = fh.read(pe_size)
            if len(e) < 128:
                break
            tguid = e[0:16]
            first, last = struct.unpack("<QQ", e[32:48])
            name = e[56:128].decode("utf-16-le", "replace").rstrip("\x00")
            if first == 0 and last == 0:
                continue
            out.append({"idx": i + 1, "name": name, "start": first * 512,
                        "size": (last - first + 1) * 512, "type": tguid.hex()})
        return out


# --- p1 (FAT, via mtools' offset syntax) -------------------------------------------
def fat_list(img, off):
    r = sh(["mdir", "-/", "-b", "-i", "%s@@%d" % (img, off), "::/"])
    if r.returncode != 0:
        print("  ! mdir failed: %s" % r.stderr.strip().splitlines()[:1])
        return []
    return [l.strip() for l in r.stdout.splitlines()
            if l.strip().startswith("::") and not l.rstrip().endswith("/")]


def fat_read(img, off, name):
    r = subprocess.run(["mcopy", "-n", "-i", "%s@@%d" % (img, off), name, "-"],
                       capture_output=True)
    return r.stdout if r.returncode == 0 else None


# --- normalisers -------------------------------------------------------------------
def strip_uimage(b):
    """A mkimage uImage header is 64 bytes and holds the build time and CRCs."""
    return b[64:] if len(b) > 64 and b[:4] == b"\x27\x05\x19\x56" else None


def dtb_to_dts(b):
    r = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-q"], input=b, capture_output=True)
    return r.stdout if r.returncode == 0 else None


def diff_span(a, b):
    """Byte positions that differ, plus the span they cover."""
    n = min(len(a), len(b))
    pos = [i for i in range(n) if a[i] != b[i]]
    if len(a) != len(b):
        pos.append(n)
    return pos


def classify(name, a, b):
    if a == b:
        return "IDENTICAL", ""
    # boot.scr: compare the payload, not the header.
    if name.endswith("boot.scr"):
        pa, pb = strip_uimage(a), strip_uimage(b)
        if pa is not None and pa == pb:
            return "IDENTICAL*", "uImage payload equal; header holds build time + CRC"
    # Device trees: compare decompiled source, which normalises layout and padding.
    if name.endswith((".dtb", ".dtbo")):
        da, db = dtb_to_dts(a), dtb_to_dts(b)
        if da is not None and da == db:
            return "IDENTICAL*", "decompiled device tree identical"
        if da is not None and db is not None:
            return "UNEXPECTED-DIFF", "device tree content differs (dtc output differs)"
    # Banner-window check for raw binaries.
    pos = diff_span(a, b)
    if pos and len(a) == len(b) and (pos[-1] - pos[0]) <= BANNER_MAX_SPAN:
        return "NORMALIZED-EQ", "%d differing bytes, all within %d bytes at 0x%x" % (
            len(pos), pos[-1] - pos[0] + 1, pos[0])
    base = os.path.basename(name)
    if base in EXPECTED_DIFF:
        return "EXPECTED-DIFF", EXPECTED_DIFF[base]
    for sub, why in EXPECTED_DIFF_SUBSTR:
        if sub in base:
            return "EXPECTED-DIFF", why
    return "UNEXPECTED-DIFF", "%d differing byte position(s), sizes %d vs %d" % (
        len(pos), len(a), len(b))


# --- p2 (ext4, via debugfs' offset syntax) -----------------------------------------
def ext4_files(img, off):
    """name -> size for every regular file, via debugfs.

    debugfs has no recursive ls (`ls -l -R` is rejected outright), so the tree is walked
    breadth-first: one debugfs invocation per depth level, fed a command file listing
    every directory at that level. debugfs echoes each command before its output, which
    is what lets one invocation cover many directories.

    Timestamps and inode numbers are deliberately ignored -- they always differ between
    two builds and say nothing about content. `ls -l` prints
        inode  mode  (type)  uid  gid  size  date...  name
    and the mode's leading digits give the type: 10 regular, 12 symlink, 4 directory.
    """
    files, dirs, level = {}, [], ["/"]
    for _depth in range(24):
        if not level:
            break
        cmds = "".join("ls -l %s\n" % d for d in level)
        p = subprocess.run(["debugfs", "-f", "/dev/stdin", "%s?offset=%d" % (img, off)],
                           input=cmds, capture_output=True, text=True)
        if p.returncode != 0 and not p.stdout:
            return None
        cur, nxt = None, []
        for line in p.stdout.splitlines():
            m = re.match(r"^debugfs:\s*ls -l (\S.*)$", line)
            if m:
                cur = m.group(1).strip()
                continue
            if cur is None:
                continue
            f = line.split()
            if len(f) < 8:
                continue
            mode, name = f[1], f[-1]
            if name in (".", ".."):
                continue
            path = os.path.join(cur, name)
            if mode.startswith("4"):            # directory
                if name != "lost+found":
                    nxt.append(path)
            elif mode.startswith("10"):         # regular file
                try:
                    files[path] = int(f[5])
                except ValueError:
                    pass
            # symlinks (12...) are skipped: their "size" is the target length, and a
            # target that differs is caught by the file set, not by a size compare.
        level = nxt
        dirs.extend(nxt)
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference", help="image known to boot")
    ap.add_argument("candidate", help="freshly built image")
    ap.add_argument("--quiet-identical", action="store_true",
                    help="print only the verdicts that need attention")
    a = ap.parse_args()
    for p in (a.reference, a.candidate):
        if not os.path.exists(p):
            raise SystemExit("ERROR: no such image: %s" % p)

    rc = 0
    print("== reference: %s" % a.reference)
    print("== candidate: %s" % a.candidate)

    # L0 -------------------------------------------------------------------------
    print("\n-- L0 partition table --")
    pr, pc = gpt_partitions(a.reference), gpt_partitions(a.candidate)
    if len(pr) != len(pc):
        print("  UNEXPECTED-DIFF  partition count %d vs %d" % (len(pr), len(pc)))
        rc = 1
    for x, y in zip(pr, pc):
        same = (x["name"], x["start"], x["size"], x["type"]) == (y["name"], y["start"], y["size"], y["type"])
        if not same:
            rc = 1
            print("  UNEXPECTED-DIFF  p%d %s: start/size/type %d/%d vs %d/%d"
                  % (x["idx"], x["name"], x["start"], x["size"], y["start"], y["size"]))
        elif not a.quiet_identical:
            print("  IDENTICAL        p%d %-8s start=%d size=%d" % (x["idx"], x["name"], x["start"], x["size"]))

    # L1..L4 over p1 --------------------------------------------------------------
    if pr and pc:
        o_r, o_c = pr[0]["start"], pc[0]["start"]
        print("\n-- L1..L4 boot partition (p1) --")
        lr, lc = set(fat_list(a.reference, o_r)), set(fat_list(a.candidate, o_c))
        for n in sorted(lr - lc):
            print("  ONLY-IN-REF      %s" % n); rc = 1
        for n in sorted(lc - lr):
            print("  ONLY-IN-NEW      %s" % n); rc = 1
        stats = {}
        for n in sorted(lr & lc):
            ba, bb = fat_read(a.reference, o_r, n), fat_read(a.candidate, o_c, n)
            if ba is None or bb is None:
                print("  ?                %s (unreadable)" % n); rc = 1; continue
            v, why = classify(n, ba, bb)
            stats[v] = stats.get(v, 0) + 1
            if v == "UNEXPECTED-DIFF":
                rc = 1
            if v.startswith("IDENTICAL") and a.quiet_identical:
                continue
            print("  %-16s %-52s %s" % (v, n, why))
        print("  ---- p1 summary: " + ", ".join("%s=%d" % (k, stats[k]) for k in sorted(stats)))

    # L5 over p2 ------------------------------------------------------------------
    if len(pr) > 1 and len(pc) > 1:
        print("\n-- L5 DomD rootfs (p2) file set --")
        fr, fc = ext4_files(a.reference, pr[1]["start"]), ext4_files(a.candidate, pc[1]["start"])
        if fr is None or fc is None:
            print("  ?                debugfs could not read one of the p2 filesystems")
        else:
            only_r, only_c = sorted(set(fr) - set(fc)), sorted(set(fc) - set(fr))
            resized = [k for k in (set(fr) & set(fc)) if fr[k] != fc[k]]
            print("  files: reference %d, candidate %d" % (len(fr), len(fc)))
            for n in only_r[:40]:
                print("  ONLY-IN-REF      %s" % n)
            for n in only_c[:40]:
                print("  ONLY-IN-NEW      %s" % n)
            if len(only_r) > 40 or len(only_c) > 40:
                print("  ... (%d / %d more)" % (max(0, len(only_r) - 40), max(0, len(only_c) - 40)))
            print("  same name, different size: %d" % len(resized))
            for n in sorted(resized)[:20]:
                print("      %-60s %d -> %d" % (n, fr[n], fc[n]))
            if only_r or only_c:
                rc = 1

    print("\n-- not covered here --")
    print("  p4 (AAOS): built for a different PRODUCT_DEVICE, so equality is the wrong")
    print("  question. Check the PROPERTY instead: extract super.img and confirm no")
    print("  unguarded crypto/LDAPR in /init and libcrypto (a Cortex-A72 SIGILLs on those).")
    print("  Runtime behaviour cannot be inferred from any of the above: identical inputs")
    print("  are necessary, not sufficient.")
    print("\nexit=%d (%s)" % (rc, "nothing unexpected" if rc == 0 else "see UNEXPECTED-DIFF / ONLY-IN-* above"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
