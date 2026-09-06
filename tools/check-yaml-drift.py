#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Catch unintended divergence between the per-board product yamls.

WHY THIS EXISTS
---------------
There is one product yaml per board and moulin has NO cross-file include, so the two
files carry roughly 750 lines of identical text. Nothing makes an edit to a shared block
land in both, and the failure is silent: the board whose copy was not updated simply
keeps the older behaviour.

That is not hypothetical. rpi4-sodev.yaml was created from an older revision of
rpi5-sodev.yaml and arrived carrying an older `- [INHERIT:remove, "create-spdx"]` entry
while the shared text had already moved on, i.e. SBOM generation was off for that board while
being on for the other. It was found by noticing that the two boards' `bitbake -n` task
counts differed by ~1,400, not by any check. (Both lines are gone now -- the SBOM is
unconditional -- but the failure mode is not.) This is that check.

HOW IT WORKS
------------
1. Board-specific tokens are normalised to their Raspberry Pi 5 spelling
   (raspberrypi4-64 -> raspberrypi5, bcm2711 -> bcm2712, ...), so text that differs only
   because it names a different board compares equal.
2. The normalised files are diffed. Comment-only differences are counted and reported
   but do not fail: prose is expected to diverge.
3. FUNCTIONAL differences -- anything that is not a comment or blank -- are compared
   against a recorded baseline of the differences that are there by design (the memory
   map, the layer list, the SKU parameter, the absent SCMI wiring, ...). Anything not in
   the baseline fails.

The SKUs are deliberately NOT normalised. 16g/8g and 8g/4g overlap on "8g", so mapping
them would make genuinely different budgets compare equal -- exactly the class of bug
this is meant to catch. The BOARD_RAM blocks therefore sit in the baseline instead.

USAGE
    tools/check-yaml-drift.py             # check; non-zero exit on new drift
    tools/check-yaml-drift.py --update    # re-record the baseline after an intended change
"""
import argparse
import difflib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
YAML_A = os.path.join(ROOT, "rpi5-sodev.yaml")   # reference spelling
YAML_B = os.path.join(ROOT, "rpi4-sodev.yaml")
BASELINE = os.path.join(ROOT, "tools", "yaml-drift-baseline.txt")

# Applied in order, longest/most specific first: raspberrypi4-64 has to be rewritten
# before a bare raspberrypi4 would match part of it.
NORMALISE = [
    # Both boards now name their own AOSP product: rpi4 needs one for its CPU
    # variant, rpi5 for the vendor init.rc that minradio's data call depends on. So
    # the product NAME normalises rpi4 -> rpi5 like any other board token.
    #
    # The DEVICE deliberately does NOT normalise. rpi5's product keeps the upstream
    # xenvm_trout_arm64 device while rpi4 needs a device of its own, and that is a
    # real asymmetry rather than a board-token spelling: rewriting it here would hide
    # it, so it is left to show up as drift and is recorded in the baseline instead.
    ("aosp_xenvm_trout_rpi4_arm64", "aosp_xenvm_trout_rpi5_arm64"),
    # No rule for the staged device DIRECTORY name: the Pi 4's device is a repo
    # project now (device/sodev/xenvm-cf, from the AOSP manifest), so only the Pi 5
    # still names a directory in this tree and there is nothing to pair it with.
    ("raspberrypi4-64", "raspberrypi5"),
    ("raspberrypi4", "raspberrypi5"),
    ("meta-xt-rpi4", "meta-xt-rpi5"),
    ("rpi4-sodev", "rpi5-sodev"),
    ("bcm2711", "bcm2712"),
    ("rpi_4b", "rpi_5"),
    ("Raspberry Pi 4", "Raspberry Pi 5"),
    ("Cortex-A72", "Cortex-A76"),
    ("cortexa72", "cortexa76"),
    ("cortex-a72", "cortex-a76"),
    ("RPi4", "RPi5"),
    ("rpi4", "rpi5"),
    ("A72", "A76"),
]


def normalise(text):
    for a, b in NORMALISE:
        text = text.replace(a, b)
    return text


def is_functional(line):
    """True for a line that affects the build rather than only documenting it."""
    body = line.strip()
    if not body:
        return False
    return not body.startswith("#")


def diff_lines(a_text, b_text):
    a = normalise(a_text).split("\n")
    b = normalise(b_text).split("\n")
    # n=0: only the differing lines, so unrelated edits nearby do not churn the baseline.
    out = []
    for line in difflib.unified_diff(a, b, lineterm="", n=0):
        if line.startswith(("---", "+++", "@@")):
            continue
        if line[:1] in "+-":
            out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true",
                    help="re-record the baseline from the current files")
    args = ap.parse_args()

    for p in (YAML_A, YAML_B):
        if not os.path.exists(p):
            print("ERROR: missing %s" % p, file=sys.stderr)
            return 2

    a_text = open(YAML_A, encoding="utf-8").read()
    b_text = open(YAML_B, encoding="utf-8").read()

    d = diff_lines(a_text, b_text)
    functional = sorted(set(l for l in d if is_functional(l[1:])))
    comment_only = len(d) - len([l for l in d if is_functional(l[1:])])

    if args.update:
        hdr = ("# Recorded functional differences between the per-board product yamls,\n"
               "# after tools/check-yaml-drift.py normalises the board-specific tokens.\n"
               "# '-' is present only in %s, '+' only in %s.\n"
               "# Regenerate with: tools/check-yaml-drift.py --update\n"
               % (os.path.basename(YAML_A), os.path.basename(YAML_B)))
        tmp = BASELINE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(hdr)
            fh.write("\n".join(functional) + "\n")
        os.replace(tmp, BASELINE)
        print("recorded %d functional difference(s) in %s"
              % (len(functional), os.path.relpath(BASELINE, ROOT)))
        return 0

    if not os.path.exists(BASELINE):
        print("ERROR: %s is missing; create it with --update"
              % os.path.relpath(BASELINE, ROOT), file=sys.stderr)
        return 2

    recorded = set()
    for line in open(BASELINE, encoding="utf-8").read().split("\n"):
        if line.startswith("#") or not line.strip():
            continue
        recorded.add(line)

    current = set(functional)
    new = sorted(current - recorded)
    gone = sorted(recorded - current)

    print("== %s vs %s (board tokens normalised) ==" % (os.path.basename(YAML_A), os.path.basename(YAML_B)))
    print("  functional differences : %d (baseline %d)" % (len(current), len(recorded)))
    print("  comment-only differences: %d (reported, not gated)" % comment_only)

    rc = 0
    if new:
        rc = 1
        print("\nFAIL: %d functional difference(s) not in the baseline." % len(new))
        print("      Either the shared block was edited in only one file -- fix the other --")
        print("      or the difference is intended: re-record with --update.")
        for l in new:
            print("        %s" % l[:160])
    if gone:
        print("\nWARNING: %d baseline entr(y|ies) no longer present (stale baseline)." % len(gone))
        for l in gone[:20]:
            print("        %s" % l[:160])
        if len(gone) > 20:
            print("        ... and %d more" % (len(gone) - 20))

    if rc == 0 and not gone:
        print("\nOK: no unrecorded drift.")
    return rc


if __name__ == "__main__":
    sys.exit(main())
