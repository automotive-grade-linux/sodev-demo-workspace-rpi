#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# dump-cma.sh: CMA reproducer step 1.
# Dump the CMA region for inspection. The region is discovered at run time from
# /proc/iomem (or /sys/kernel/debug/cma when debugfs is mounted) rather than
# hardcoded: base and size depend on the cma= kernel argument and on where the
# allocator lands, both of which differ between builds and boots.
#
# Usage:
#   dump-cma.sh [output-file]
# Default: /tmp/cma-dump.bin
#
# CMA reservation check:
#   ./dump-cma.sh                       # → /tmp/cma-dump.bin
#   analyze-vram.py /tmp/cma-dump.bin   # → /tmp/vram-png/region_*.png
#

set -e

OUT="${1:-/tmp/cma-dump.bin}"

# Discover the region. CMA_BASE / CMA_SIZE_MB may be set in the environment to
# override the probe.
if [ -z "${CMA_BASE:-}" ]; then
    line=$(grep -i "cma" /proc/iomem 2>/dev/null | head -n1)
    if [ -n "$line" ]; then
        CMA_BASE="0x${line%%-*}"
        end="0x$(echo "${line#*-}" | cut -d" " -f1)"
        CMA_SIZE_MB=$(( (end - CMA_BASE) / 1024 / 1024 ))
    fi
fi
if [ -z "${CMA_BASE:-}" ]; then
    echo "[dump-cma] could not find a CMA region in /proc/iomem;" >&2
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

echo "[dump-cma] Done: ${SIZE} bytes in ${ELAPSED}s (${SPEED_MB} MiB/s)"
echo "[dump-cma] Next step: analyze-vram.py $OUT"
