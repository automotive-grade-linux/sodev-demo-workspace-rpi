#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
CMA VRAM dump scanner + framebuffer PNG renderer.

Usage:
    analyze-vram.py <cma-dump.bin> [out-dir]

Defaults out-dir = /tmp/vram-png

Reproduction:
  1. capture /tmp/cma-dump.bin with dump-cma.sh
  2. analyze-vram.py /tmp/cma-dump.bin
  3. framebuffer contents are written as PNG to /tmp/vram-png/region_*.png
  4. inspect the weston main fb for vertical stripes
"""
import os, sys, struct
from PIL import Image

# Framebuffer geometry to look for. These are search parameters, not a claim about
# the panel: override with FB_W / FB_H in the environment to match your output.
CMA_BASE = int(os.environ.get("CMA_BASE", "0x34000000"), 0)
FB_W = int(os.environ.get("FB_W", "1920"))
FB_H = int(os.environ.get("FB_H", "720"))
PITCH = FB_W * 4   # XRGB8888
HEIGHT = FB_H
FB_SIZE = PITCH * HEIGHT

def fast_xrgb_decode(buf, w=FB_W, h=FB_H):
    """XRGB8888 little-endian raw -> PIL RGB image."""
    out = bytearray(w * h * 3)
    n = w * h
    for i in range(n):
        out[3*i]   = buf[4*i+2]  # R
        out[3*i+1] = buf[4*i+1]  # G
        out[3*i+2] = buf[4*i]    # B
    return Image.frombytes("RGB", (w, h), bytes(out))

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <cma-dump.bin> [out-dir]")
        sys.exit(1)
    dump_path = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/vram-png"
    os.makedirs(out_dir, exist_ok=True)

    with open(dump_path, "rb") as f:
        data = f.read()
    print(f"CMA dump: {dump_path} ({len(data)/1024/1024:.1f} MiB)")

    # Scan for non-empty 64 KiB chunks
    scan_step = 64 * 1024
    in_region = False
    regions = []
    rs = None
    for off in range(0, len(data), scan_step):
        chunk = data[off:off+scan_step]
        nonzero = sum(1 for b in chunk if b != 0)
        pct = nonzero / len(chunk) if chunk else 0
        if pct > 0.3:
            if not in_region:
                rs, in_region = off, True
        else:
            if in_region:
                regions.append((rs, off)); in_region = False
    if in_region:
        regions.append((rs, len(data)))

    print(f"Found {len(regions)} non-empty regions:")
    for rs, re in regions:
        size = re - rs
        print(f"  offset 0x{rs:08x} - 0x{re:08x}  ({size/1024/1024:.2f} MiB)  "
              f"CPU PA 0x{CMA_BASE+rs:08x}")

    big_regions = [(rs, re) for (rs, re) in regions if re - rs >= FB_SIZE]
    print(f"\nRegions >= {FB_SIZE/1024/1024:.1f} MiB (probable {FB_W}x{FB_H} fb):"
          f" {len(big_regions)}")

    for i, (rs, _re) in enumerate(big_regions[:6]):
        print(f"\nRegion #{i} at offset 0x{rs:08x} (CPU PA 0x{CMA_BASE+rs:08x}):")
        fb_buf = data[rs:rs+FB_SIZE]
        p0 = struct.unpack('<I', fb_buf[0:4])[0]
        mid_row, last_row = FB_H // 2, FB_H - 1
        p_mid = struct.unpack('<I', fb_buf[mid_row*PITCH:mid_row*PITCH+4])[0]
        p_last = struct.unpack('<I', fb_buf[last_row*PITCH:last_row*PITCH+4])[0]
        print(f"  first pixel: 0x{p0:08x}")
        print(f"  middle pixel: 0x{p_mid:08x}")
        print(f"  last pixel: 0x{p_last:08x}")
        try:
            img = fast_xrgb_decode(fb_buf, FB_W, FB_H)
            out_path = os.path.join(out_dir, f"region_{i}_off_{rs:08x}.png")
            img.save(out_path, "PNG")
            thumb = img.copy(); thumb.thumbnail((800, 500))
            thumb.save(os.path.join(out_dir, f"region_{i}_off_{rs:08x}_thumb.png"))
            print(f"  saved: {out_path}")
        except Exception as e:
            print(f"  ERROR rendering: {e}")
    print("\nDone.")

if __name__ == "__main__":
    main()
