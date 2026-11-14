#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# dump-cma.sh: CMA reproducer step 1.
# Dump the CMA region for inspection. The region is discovered at run time from
# the kernel's boot log rather than hardcoded: base and size depend on the cma=
# kernel argument and on where the allocator lands, both of which differ between
# builds and boots. The base is written beside the dump (<output-file>.base) so
# analyze-vram.py can print CPU physical addresses for what it finds.
#
# Usage:
#   dump-cma.sh [output-file]
# Default: /tmp/cma-dump.bin
#
# CMA reservation check:
#   ./dump-cma.sh                       # → /tmp/cma-dump.bin + /tmp/cma-dump.bin.base
#   analyze-vram.py /tmp/cma-dump.bin   # → /tmp/vram-png/region_*.png
#

set -e

OUT="${1:-/tmp/cma-dump.bin}"

# Discover the region from the kernel's boot log. The CMA area has no name of
# its own in /proc/iomem (arm64 lists it as "reserved"), and neither board puts
# its base in the device tree: the RPi5 cma node carries only size + alloc-ranges,
# and the RPi4 DomD gets its pool from the cma= kernel argument. The kernel
# prints the base on both paths:
#   cma: Reserved 256 MiB at 0x000000002c000000                  (mm/cma.c, cma=)
#   Reserved memory: created CMA memory pool at 0x0000000030000000, size 256 MiB
#                                 (kernel/dma/contiguous.c, reserved-memory node)
# CMA_BASE / CMA_SIZE_MB in the environment override the probe, for a ring
# buffer that has already wrapped past the line.
if [ -z "${CMA_BASE:-}" ]; then
    # `|| true`: under set -e a grep with no match would end the script here,
    # before the message below says what to do.
    line=$(dmesg 2>/dev/null | grep -m1 -E 'cma: Reserved [0-9]+ MiB at 0x|created CMA memory pool at 0x' || true)
    if [ -n "$line" ]; then
        CMA_BASE=$(echo "$line" | grep -oE 'at 0x[0-9a-fA-F]+' | head -n1 | cut -d" " -f2)
        CMA_SIZE_MB=$(echo "$line" | grep -oE '[0-9]+ MiB' | head -n1 | cut -d" " -f1)
    fi
fi
if [ -z "${CMA_BASE:-}" ]; then
    echo "[dump-cma] could not find the CMA base in the kernel log (dmesg);" >&2
    echo "[dump-cma] set CMA_BASE=0x... and CMA_SIZE_MB=... to override" >&2
    exit 1
fi
CMA_BASE_HEX="$CMA_BASE"
CMA_SIZE_MB="${CMA_SIZE_MB:-64}"

# Convert CMA base to dd skip count (1 MiB blocks)
CMA_BASE_MB=$((CMA_BASE_HEX / 1024 / 1024))

printf "[dump-cma] CMA region: %#x + %s MiB\n" "$CMA_BASE_HEX" "$CMA_SIZE_MB"
echo "[dump-cma] dd skip=${CMA_BASE_MB} count=${CMA_SIZE_MB} (1 MiB blocks)"
echo "[dump-cma] Output: $OUT"

START="$(date +%s.%N)"
dd if=/dev/mem of="$OUT" bs=1M count=${CMA_SIZE_MB} skip=${CMA_BASE_MB} \
   status=progress 2>&1
END="$(date +%s.%N)"

ELAPSED="$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.3f", e-s }')"
SIZE="$(stat -c %s "$OUT")"
SPEED_MB="$(awk -v s="$SIZE" -v t="$ELAPSED" 'BEGIN { printf "%.1f", (s/1048576)/t }')"

# analyze-vram.py reads this to turn dump offsets into CPU physical addresses.
printf '%#x\n' "$CMA_BASE_HEX" > "$OUT.base"

echo "[dump-cma] Done: ${SIZE} bytes in ${ELAPSED}s (${SPEED_MB} MiB/s)"
echo "[dump-cma] Base written to $OUT.base"
echo "[dump-cma] Next step: analyze-vram.py $OUT"
