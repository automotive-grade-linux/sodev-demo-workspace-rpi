# BCM2711 / Raspberry Pi 4 B — measured device tree (the port's primary data)

Source: **`boot/bcm2711-rpi-4-b.dtb`** from the Raspberry Pi firmware repository
(`https://github.com/raspberrypi/firmware/raw/master/boot/bcm2711-rpi-4-b.dtb`),
disassembled with `dtc -I dtb -O dts` and read off. Every address, size and interrupt
number in this layer comes from here rather than from a datasheet or from the RPi5
values — that is the point of the file.

These values are the sole justification for the board DTS, the boot scripts, the
`xen,reg` ranges and `domd.cfg`'s `iomem` list.

---

## 0. The structural differences that matter most (versus BCM2712)

| item | BCM2711 / RPi4 | BCM2712 / RPi5 |
|---|---|---|
| **root cells** | **`#address-cells=<2>` / `#size-cells=<1>`** | 2 / 2 |
| bus wrappers | `/soc`(1/1), `/scb`(2/2), `/emmc2bus`(2/1), `/v3dbus`(**1/2**) | `/soc@107c000000`, `/axi` |
| physical address width | 35 bit (all peripherals within 32 bit: `0xfe......`) | 40 bit (`0x10_7c......`) |
| GIC | `/soc/interrupt-controller@40041000` `arm,gic-400`<br>GICD `0xff841000` / GICC `0xff842000` | `0x10_7fff8000` range |
| IOMMU | **none** | `/axi/iommu@5200` + `iommuc@5b00` |
| MSI | **inside the PCIe root complex** (`msi-parent` points at itself, GIC SPI 148) | separate MIP0 chip (SPI 128-191) |
| GPU aggregate node | **`/gpu` at the root**, `compatible="brcm,bcm2711-vc5"` | `/axi/gpu`, `brcm,bcm2712-vc6` |
| L2 interrupt controllers | only one, for HDMI (`@7ef00100`, SPI 96 **EDGE**) | disp_intr / aon_intr / bsc_irq |
| display clocks | **`<&firmware_clocks N>`** via the mailbox | same, though on RPi5 the probe fails and a fixed-clock stands in |

> **`#size-cells=<1>` is a trap.** `/reserved-memory` is 2/1 as well. An overlay that
> writes 2/2 there makes Linux's `__reserved_mem_check_root` reject the cell counts and
> ignore the WHOLE `/reserved-memory` node — including TF-A's own `atf@0` entry. This is
> the same trap the RPi5 boot script hit on 2026-06-24.

## 1. Bus wrappers (measured `ranges` / `dma-ranges`)

```
/                #address-cells=<2>  #size-cells=<1>

/soc             simple-bus  1/1
  ranges     = <0x7e000000 0x0 0xfe000000 0x1800000>,
               <0x7c000000 0x0 0xfc000000 0x2000000>,
               <0x40000000 0x0 0xff800000 0x0800000>
  dma-ranges = <0xc0000000 0x0 0x00000000 0x40000000>,   <- VPU/legacy DMA: low 1 GB only
               <0x7c000000 0x0 0xfc000000 0x3800000>

/emmc2bus        simple-bus  2/1
  ranges     = <0x0 0x7e000000 0x0 0xfe000000 0x1800000>
  dma-ranges = <0x0 0xc0000000 0x0 0x00000000 0x40000000> <- SD (emmc2) also low 1 GB only

/scb             simple-bus  2/2
  ranges     = <0x0 0x7c000000 0x0 0xfc000000 0x0 0x3800000>,
               <0x0 0x40000000 0x0 0xff800000 0x0 0x0800000>,
               <0x6 0x00000000 0x6 0x00000000 0x0 0x40000000>,
               <0x0 0x00000000 0x0 0x00000000 0x0 0xfc000000>
  dma-ranges = <0x4 0x7c000000 0x0 0xfc000000 0x0 0x3800000>,
               <0x0 0x00000000 0x0 0x00000000 0x4 0x00000000> <- GENET reaches 16 GB

/v3dbus          simple-bus  **1/2**
  ranges     = <0x7c500000 0x0 0xfc500000 0x0 0x3300000>,
               <0x40000000 0x0 0xff800000 0x0 0x0800000>
  dma-ranges = <0x0 0x0 0x0 0x4 0x0>                      <- V3D reaches 16 GB (own MMU)
```

**What the DMA constraints imply.** Only the **VideoCore mailbox, the HVS (display) and
emmc2 (SD)** are restricted to the low 1 GB. GENET, V3D and PCIe (3 GB) are not. So the
**mailbox, the CMA pool and the SD card have to end up in the same domain (DomD)**.

## 2. Measured device table (`/soc` offset -> physical address / GIC SPI)

Within `/soc`: `0x7e......` -> `0xfe......`, `0x7c......` -> `0xfc......`, and
`0x40000000` -> `0xff800000`.

| label | DT path | reg (bus) | **physical base** | size | GIC SPI / L2 sub-IRQ |
|---|---|---|---|---|---|
| `mailbox` | `/soc/mailbox@7e00b880` | `0x7e00b880` | **`0xfe00b880`** | 0x40 | **33** |
| `firmware` | `/soc/firmware` | (no reg) | — | — | — |
| `gpio` | `/soc/gpio@7e200000` | `0x7e200000` | **`0xfe200000`** | 0xb4 | 113, 114 |
| `uart0` (pl011) | `/soc/serial@7e201000` | `0x7e201000` | **`0xfe201000`** | 0x200 | **121** |
| `hvs` | `/soc/hvs@7e400000` | `0x7e400000` | **`0xfe400000`** | 0x8000 | **97** (straight to the GIC) |
| `pixelvalve0` | `/soc/pixelvalve@7e206000` | `0x7e206000` | **`0xfe206000`** | 0x100 | 109 |
| `pixelvalve1` | `/soc/pixelvalve@7e207000` | `0x7e207000` | **`0xfe207000`** | 0x100 | 110 |
| `pixelvalve2` | `/soc/pixelvalve@7e20a000` | `0x7e20a000` | `0xfe20a000` | 0x100 | 101 |
| `pixelvalve3` | `/soc/pixelvalve@7ec12000` | `0x7ec12000` | `0xfec12000` | 0x100 | 106 |
| `pixelvalve4` | `/soc/pixelvalve@7e216000` | `0x7e216000` | `0xfe216000` | 0x100 | 110 |
| `dvp` | `/soc/clock@7ef00000` | `0x7ef00000` | **`0xfef00000`** | 0x10 | — |
| hdmi L2 intc | `/soc/interrupt-controller@7ef00100` | `0x7ef00100` | **`0xfef00100`** | 0x30 | **96 (EDGE=0x1)** |
| `hdmi0` | `/soc/hdmi@7ef00700` | 10 blocks, below | **`0xfef00700`** | — | L2 sub 0..5 |
| `hdmi1` | `/soc/hdmi@7ef05700` | 10 blocks, below | **`0xfef05700`** | — | L2 sub 8,7,6,9,10,11 |
| `ddc0` | `/soc/i2c@7ef04500` | `0x7ef04500`,`0x7ef00b00` | `0xfef04500`,`0xfef00b00` | 0x100, 0x300 | — |
| `ddc1` | `/soc/i2c@7ef09500` | `0x7ef09500`,`0x7ef05b00` | `0xfef09500`,`0xfef05b00` | 0x100, 0x300 | — |
| `pm` (watchdog) | `/soc/watchdog@7e100000` | `0x7e100000`,`0x7e00a000`,`0x7ec11000` | `0xfe100000`,`0xfe00a000`,`0xfec11000` | 0x114,0x24,0x20 | — |
| `avs_monitor` | `/soc/avs-monitor@7d5d2000` | `0x7d5d2000` | **`0xfd5d2000`** | 0xf00 | — |
| `usb` (dwc2) | `/soc/usb@7e980000` | `0x7e980000`,`0x7e00b200` | **`0xfe980000`**,`0xfe00b200` | 0x10000, 0x200 | **73** (usb), 40 (soft) |
| `txp` | `/soc/txp@7e004000` | `0x7e004000` | `0xfe004000` | 0x20 | 75 |
| `firmwarekms` | `/soc/firmwarekms@7e600000` | `0x7e600000` | `0xfe600000` | 0x100 | 112 |
| `cprman` | `/soc/cprman@7e101000` | `0x7e101000` | `0xfe101000` | 0x2000 | — |
| `dma` | `/soc/dma-controller@7e007000` | `0x7e007000` | `0xfe007000` | 0xb00 | 80..88 |
| GIC-400 | `/soc/interrupt-controller@40041000` | `0x40041000`.. | **GICD `0xff841000` / GICC `0xff842000`** | 0x1000 / 0x2000 | — |
| `emmc2` | `/emmc2bus/mmc@7e340000` | `0x0 0x7e340000` | **`0xfe340000`** | 0x100 | **126** |
| `pcie0` (VL805 RC) | `/scb/pcie@7d500000` | `0x0 0x7d500000` | **`0xfd500000`** | 0x9310 | **147** (pcie), **148** (msi), INTA-D **143..146** |
| `genet` | `/scb/ethernet@7d580000` | `0x0 0x7d580000` | **`0xfd580000`** | 0x10000 | **157, 158** |
| `xhci` (fixed BAR) | `/scb/xhci@7e9c0000` | `0x0 0x7e9c0000` | `0xfe9c0000` | 0x100000 | 176 |
| `dma40` | `/scb/dma@7e007b00` | `0x0 0x7e007b00` | `0xfe007b00` | 0x400 | 89..92 |
| `hevc_dec` | `/scb/codec@7eb10000` | `0x7eb00000`,`0x7eb10000` | `0xfeb00000`,`0xfeb10000` | 0x10000, 0x1000 | 98 |
| `v3d` | `/v3dbus/v3d@7ec04000` | hub `0x7ec00000`, core0 `0x7ec04000` | **`0xfec00000`, `0xfec04000`** | 0x4000 x2 | **74** |
| `vc4` | **`/gpu`** | (no reg) | — | — | `brcm,bcm2711-vc5` |

### HDMI0's 10 reg blocks (bus -> physical)
| name | bus | physical | size |
|---|---|---|---|
| hdmi | `0x7ef00700` | `0xfef00700` | 0x300 |
| dvp | `0x7ef00300` | `0xfef00300` | 0x200 |
| phy | `0x7ef00f00` | `0xfef00f00` | 0x80 |
| rm | `0x7ef00f80` | `0xfef00f80` | 0x80 |
| packet | `0x7ef01b00` | `0xfef01b00` | 0x200 |
| metadata | `0x7ef01f00` | `0xfef01f00` | 0x400 |
| csc | `0x7ef00200` | `0xfef00200` | 0x80 |
| cec | `0x7ef04300` | `0xfef04300` | 0x100 |
| hd | `0x7ef20000` | `0xfef20000` | 0x100 |
| **intr2** | `0x7ef00100` | `0xfef00100` | 0x30 |

### HDMI1's 10 reg blocks
| name | bus | physical | size |
|---|---|---|---|
| hdmi | `0x7ef05700` | `0xfef05700` | 0x300 |
| dvp | `0x7ef05300` | `0xfef05300` | 0x200 |
| phy | `0x7ef05f00` | `0xfef05f00` | 0x80 |
| rm | `0x7ef05f80` | `0xfef05f80` | 0x80 |
| packet | `0x7ef06b00` | `0xfef06b00` | 0x200 |
| metadata | `0x7ef06f00` | `0xfef06f00` | 0x400 |
| csc | `0x7ef00280` | `0xfef00280` | 0x80 |
| cec | `0x7ef09300` | `0xfef09300` | 0x100 |
| hd | `0x7ef20000` | `0xfef20000` | 0x100 (shared with hdmi0) |
| **intr2** | `0x7ef00100` | `0xfef00100` | 0x30 (shared with hdmi0) |

**Folded into 4 KiB pages — this is what `xen,reg` actually has to cover**

| page | contents |
|---|---|
| `0xfef00000` | dvp(0x…000) / csc0(0x…200) / intr2(0x…100) / dvp0(0x…300) / hdmi0(0x…700) / ddc0-auto(0x…b00) / phy0(0x…f00) / rm0(0x…f80) / csc1(0x…280) |
| `0xfef01000` | packet0(0x…b00 +0x200) / metadata0(0x…f00 **+0x400**) |
| `0xfef02000` | **the rest of metadata0** — `0x…1f00 + 0x400 = 0x…2300` crosses the page |
| `0xfef04000` | cec0(0x…300) / ddc0-bsc(0x…500) |
| `0xfef05000` | dvp1(0x…300) / hdmi1(0x…700) / ddc1-auto(0x…b00) / phy1(0x…f00) / rm1(0x…f80) |
| `0xfef06000` | packet1(0x…b00 +0x200) / metadata1(0x…f00 **+0x400**) |
| `0xfef07000` | **the rest of metadata1** — crosses the page for the same reason |
| `0xfef09000` | cec1(0x…300) / ddc1-bsc(0x…500) |
| `0xfef20000` | hd (shared) |

So the HDMI complex is **9 pages**:
`0xfef00000` / `0xfef01000` / `0xfef02000` / `0xfef04000` / `0xfef05000` /
`0xfef06000` / `0xfef07000` / `0xfef09000` / `0xfef20000`.

**Correction (adversarial review, 2026-07-26).** This table used to say "6 pages plus
`0xfef20000` = 7 pages". That was wrong: `metadata`'s `reg` is `+0x1f00` size `0x400`,
i.e. `0x…1f00-0x…22ff`, so it **always crosses into the next page**. Recomputed from the
real DTB:

```
$ dtc -I dtb -O dts bcm2711-rpi-4-b.dtb   # reg/reg-names of hdmi@7ef00700
  metadata     0x7ef01f00+0x0400  pages 0x7ef01000..0x7ef02000  <-- CROSSES A PAGE
  # hdmi@7ef05700
  metadata     0x7ef06f00+0x0400  pages 0x7ef06000..0x7ef07000  <-- CROSSES A PAGE
```

`bcm2711-raspberrypi4-64-domd-vc4.dts` was already correct — it passes `xen,reg` as
`0x2000` (two pages). The error was in this table alone. It surfaced from a check that
every part of a host `reg` is covered by the corresponding `xen,reg`; if you change any
`xen,reg` here, redo that comparison by hand against the DTB.

`aon_intr` / `bsc_irq` / `mop` / `moplet`, all needed on BCM2712, do not exist on BCM2711.

## 3. firmware_clocks indices (measured)

For `clocks = <&firmware_clocks N>`:

| consumer | N | what for |
|---|---|---|
| `hvs` | 4 | core |
| `v3d` | 5 | v3d |
| `hdmi0/1` | 13 | hdmi |
| `hdmi0/1` | 14 | bvb |
| `pm` (watchdog) | 5 | v3d, for the power domain |

`hdmi`'s remaining two clocks are `<&dvp 0|1>` (audio) and `<&clk_27MHz>` (cec).
`dvp`'s parent is `<&clk_108MHz>` (root `/clk-108M`, 108 MHz); `clk_27MHz` is `/clk-27M`.

## 4. Interrupt types to watch on this board

* The HDMI L2 intc (`@7ef00100`) has GIC `interrupts = <0x0 96 0x1>`, i.e.
  **EDGE_RISING** — not BCM2712's LEVEL_HIGH. The type has to be preserved when the
  line is handed to Xen's vGIC.
* `hvs` is wired **straight to the GIC as SPI 97**, unlike BCM2712 where it goes through
  an L2 controller.
* `pixelvalve1` and `pixelvalve4` **share SPI 110**. That is what the real DT says.

## 5. Reproducing this table

```sh
curl -sL -o bcm2711-rpi-4-b.dtb \
  https://github.com/raspberrypi/firmware/raw/master/boot/bcm2711-rpi-4-b.dtb
dtc -I dtb -O dts -o bcm2711-rpi-4-b.dts bcm2711-rpi-4-b.dtb
```

On a running board use `dtc -I fs -O dts /proc/device-tree` (or the on-disk
`/boot/firmware/bcm2711-rpi-4-b.dtb`). **The firmware copy and the running copy differ
only in `/memory` and the gpu_mem carve-out**; every MMIO address and SPI is identical.
