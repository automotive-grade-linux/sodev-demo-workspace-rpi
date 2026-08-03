# Design notes

> **Documentation map** — [`README.md`](../README.md) build and run |
> [`docs/BUILD.md`](BUILD.md) build details |
> [`docs/DESIGN.md`](DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when it does not work

Why the tree is arranged the way it is: which domain owns what, how the memory map
is derived, how the display and console paths are wired, and where this port departs
from the R-Car V4H AGL SoDeV reference it came from.

> **The in-tree comments are authoritative, not this file.** Every measurement
> summarised here is also recorded next to the code it constrains -- the boot scripts,
> `tools/check-memory-map.py`, the Zephyr board patch, `doma.cfg`, the weston recipe.
> When the two disagree, the comment beside the code is the one that was verified
> against hardware; fix this file to match it.

---

## Domain / CPU map
| Domain | vCPUs | pCPU pin | Role |
|---|---|---|---|
| Dom0 | 1 | 0 | zephyr: xenstore server only / linux: xl toolstack + SD block backend |
| DomD | 2 | 0–1 | dom0less, direct-mapped; GPU + RP1 (+ SDHCI with zephyr Dom0); qemu virtio backends; toolstack (zephyr flavour) |
| DomU | 1 | 1 | AGL cluster guest (virtio-pci, grant DMA) |
| DomA | 2 | 2–3 | AAOS guest (virtio-pci/-gpu/-blk, vhost-net/-vsock) |

BCM2712 has **no IOMMU**, so DomD is direct-mapped (`xen,static-mem` + libxl
direct-map). DomU virtio uses grant-based DMA; DomA virtio uses foreign mapping
(`grant_usage=0` in `doma.cfg`).

## Board RAM size

Raspberry Pi 5 ships as an 8 GB and a 16 GB SKU. `--ram=16g|8g` (moulin
`--BOARD_RAM`) selects which one the SD image is built for; **16g is the default**.

| Domain | `16g` (default) | `8g` | allocation |
|---|---|---|---|
| Dom0 | 512 MiB | 512 MiB | heap, `dom0_mem=512M` |
| DomD | 4096 MiB | **3072 MiB** | `xen,static-mem` |
| DomU | 1024 MiB | 1024 MiB | heap, `domu.cfg` |
| DomA | 4096 MiB | **3072 MiB** | heap, `doma.cfg` (substituted from `BOARD_RAM`) |
| total | 9728 MiB | 7680 MiB | + Xen ~64 MiB |

**`8g` splits the reduction between DomD and DomA.** DomD's static-mem banks reach
`0x1c0000000` (7 GiB), so on an 8 GB board every address in the map still exists —
what does not fit is the total. The 8 GB map drops bank4 (`0x180000000` +1 GiB) and
leaves the rest alone, giving DomD 3072 MiB: `0x50000000` is bank[0], where Xen's
`place_modules()` puts the DomD kernel and DTB, and `0x20000000`/`0x80000000` are
inside the VPU's 32-bit DMA window that carries vc4's CMA. The highest static-mem
address drops to `0x180000000` (6 GiB). DomA gives back the other 1024 MiB, which
`xt-xen-cfg-doma` substitutes into `doma.cfg` from `BOARD_RAM`. Note that
`meta-xt-doma` installs that recipe into **both** rootfs images, and the flavours
differ in which copy `xl create` actually reads: DomD's in the zephyr flavour, Dom0's
in the linux flavour (where Dom0 runs the toolstack). `rpi5-sodev.yaml` therefore has
to pass `BOARD_RAM` to the **domd and the dom0** components, not just to domd --
`tools/check-memory-map.py` fails the check if either is missing, because the recipe
would otherwise fall back to its 16g default and an 8 GB build would silently ask for
DomA 4096.

An earlier revision of this map shrank **DomD alone**, to 2048 MiB, and left DomA at
4096. That does not work, and the reason is measured — see the warning further down.

**Dom0 is 512 MiB on both SKUs**, and the value is not board-dependent. It is
`dom0_mem` that decides *where* bank[0] lands, though — Xen cannot pin a direct-map
Dom0 to a DT address (`allocate_memory_11()` ignores `xen,static-mem`; that is
dom0less-domU only) and it loads the arm64 Image at `bank[0].start + text_offset`.
**The address differs per flavour**, and both values are measured:

| flavour | `dom0_mem` | bank[0] | evidence |
|---|---|---|---|
| **zephyr** | **512M** | **`0xa0000000`** | `BANK[0] 0xa0000000-0xc0000000`, `Loading zImage ... to 00000000a0000000` |
| **linux** | **512M** | **`0xe0000000`** | `BANK[0] 0xe0000000-0x100000000`, same line at `0xe0000000` |
| zephyr | 1024M | `0xc0000000` | earlier UART log; single candidate in its tier |
| — | 128M | `0x10000000` | Zephyr's pre-relink link address |

Only the **zephyr** flavour is constrained by this: Zephyr is absolute-linked from
`CONFIG_SRAM_BASE_ADDRESS` and is relinked to `0xa0000000` in
`meta-xt-dom0-zephyr/0008-rpi5-board-domd-owns-sd.patch`, so **those two must be changed
together** and `tools/check-memory-map.py` enforces the pair. A Linux Dom0 is a
relocatable arm64 Image and runs wherever Xen puts it, which is why the flavours can
diverge at all.

⚠ **Which candidate wins inside one `MEMF_bits` tier is NOT predictable, and two
measurements prove it is neither the lowest nor the highest.** `allocate_memory_11()`
raises the ceiling one bit at a time and takes the first tier that fits; the pick inside
that tier depends on buddy free-list state this script does not model, and the flavours
differ because they reserve different low regions.

- zephyr, 512M: candidates `0xa0000000` / `0xc0000000` / `0xe0000000` → **lowest**
- linux, 512M: candidates `0xc0000000` / `0xe0000000` → **highest**
  (`0xa0000000` is out of play: the linux script fatloads its Dom0 initramfs there)

Both wrong answers looked justified when they were written. The first model returned the
highest, reasoning that `alloc_heap_pages()` takes the head of an order-N free list and
that with `bootscrub=off` those lists come out in descending address order. The zephyr
board falsified that, and it was changed to lowest — on the strength of that **one** data
point. The linux board then falsified lowest too. `check-memory-map.py` now keeps a table
of measured addresses (`DOM0_BANK0_MEASURED`), **warns** where a `(flavour, dom0_mem)`
combination has no measurement instead of asserting a rule, and **fails** if a measured
address is not even among the candidates it derives — that would mean the free-hole model
itself is wrong, not just the pick. Do not re-derive a rule from a single new board.

Zephyr declares only 128 MiB of SRAM (`CONFIG_SRAM_SIZE=131072` KiB) and the image is
~3 MiB with a 2 MiB heap, so 512 MiB is four times what it can address; 384 MiB of the
bank is assigned but unused. At the previous 1024M it was 896 MiB unused.

If a future `dom0_mem` change puts the bank somewhere else, Xen prints
`BANK[0] <start>-<end>` **before** Dom0 runs, so the log gives the right value even when
Zephyr is silent: fix patch 0008, rebuild `zephyr.bin` only and scp it to p1 — no SD
re-image. That is exactly how the `0xe0000000` → `0xa0000000` correction was made. Note
that Zephyr keeps `.config` across incremental builds, so delete `zephyr/build-dom0` and
build pristine, then check the `zephyr.bin` md5 actually changed.

⚠ **DomD 2048 MiB does not work with all four domains, and that is why the 8g map
splits the reduction.** Two independent measurements say so.
`bcm2712-raspberrypi5-xen.dtso` records `xl devd` OOM-killed at 2 GB with the DomU and
DomA qemu device-models plus weston and the VHAL backend running concurrently — exactly
the 4-domain case, and the reason DomD is 4096 on 16g. An earlier 8g map reintroduced
2048 anyway (DomD being the one domain that can give space back) and reproduced the
failure on hardware, 2026-08-03: AAOS got as far as DHCP and then crash-looped in binder
(`cannot find target node`, `undelivered transaction, process died` — 16 occurrences) and
never set `sys.boot_completed`. The panel stayed dark.

The interesting part is what was *not* wrong: DomD still had 1.3 GiB free, nothing was
OOM-killed, `xendriverdomain` was alive, and DomD's `swiotlb`/CMA state was byte-identical
to the working 16g boot. So the binding limit is not DomD's RAM but what its device model
can map of a 4 GiB guest. Giving DomA the other 1024 MiB fixes it: **DomD 3072 + DomA
3072** keeps the same 7680 MiB total and boots all four domains cleanly — 0 binder
errors, `sys.boot_completed=1`, both panels lit (verified on hardware).

The mechanism behind the mapping limit is not pinned down. `DomD 2048 + DomA 4096` fails
and `DomD 3072 + DomA 3072` works; which of the two changes carries the fix has not been
isolated.

**All four domains fit an 8 GB board** by the arithmetic, but not by much: 7680 + Xen ~64 = 7744 MiB
against roughly 8180 MiB usable (extrapolated from the 16 GB board's
`total_memory=16372` = 16384 − 12), i.e. ~436 MiB of headroom. That margin exists
*only* because Dom0 is 512M — at 1024M the same four domains came to 8256 MiB and
over-committed the board. `build.sh` prints the arithmetic when `--ram=8g` is combined
with `-a/--android`, because the 8180 figure is extrapolated rather than measured.

**The thin Linux Dom0 at 512M is hardware-verified** (2026-08-03: `available` ~312 MiB of
512, no OOM, four domains up). The older recorded failures
(512M → 18 MB free → systemd OOM-killed; 2048M exhausted because `xl` grew past 1 GB)
were all measured when **Dom0 itself ran weston**. It no longer does —
`rpi5-image-xt-dom0-thin.bb` `PACKAGE_EXCLUDE`s weston/mesa/wayland/qemu/python3, and
its rootfs is the initramfs at 23 MB gzip / 65 MiB unpacked into tmpfs. At 1024M the
Dom0 kernel reported `Memory: 946696K/1085952K available (… 127816K reserved …)`, so
fixed overhead is ~141 MiB and 512M should leave roughly 300 MiB free. The unresolved
item is the "`xl` past 1 GB" claim: in the linux flavour Dom0 still runs `xl` and
`xenstored`. Check with `free -m` in Dom0 after each guest is created; if `xl create`
fails, this is the first value to revisit (and reverting means restoring 1024M **and**
the `sram0` relink together).

**Mechanism.** Both boot scripts carry `setenv board_ram BOARD_RAM_PLACEHOLDER`,
which the `xt-rpi-u-boot-scr` bbappend substitutes from `${BOARD_RAM}` (and
`bbfatal`s if the line is missing, so an un-substituted script cannot ship). The
scripts then branch at run time with
`fdt set /chosen/domD memory|xen,static-mem`, so the whole delta is two lines per
script rather than a second overlay. `xen.dtso` keeps the 16 GB values as the
source-level default. `BOARD_RAM` is in `do_compile[vardeps]`, so switching SKUs
cannot reuse a stale `boot.scr` from sstate. Because `board_ram` is a plain U-Boot
env var, a one-off test needs no rebuild:

```
setenv board_ram 8g ; source ${scriptaddr}
```

**Validation without building:** `tools/check-memory-map.py` re-derives both maps
from `xen.dtso` and the two boot scripts and checks bank overlap, the `memory` ⇔
bank-sum identity, that no `fatload` lands inside a bank, that `8g` is a shrink-only
subset of `16g`, that both boot scripts carry an identical override and the same
`dom0_mem`, that the predicted Dom0 bank[0] equals the `sram0` base in patch 0008, and
that Zephyr's declared SRAM fits the Dom0 bank. The 8 GB usable figure it compares
against is **extrapolated, not measured** — no 8 GB Pi 5 has been tested here, and the
script labels it as such.

## Patch trailers

Every `.patch` authored or modified here carries a human `Signed-off-by:` — the
DCO sign-off is never machine-generated. Where a change was produced with AI
assistance, an `Assisted-by:` trailer sits immediately above that sign-off, so
the assistance is declared without being confused for authorship.

The agent name in that trailer is spelled **`ClaudeCode`** in the Linux-kernel
patches and **`Claude Code`** everywhere else. The reason is mechanical: the
kernel's `scripts/checkpatch.pl` validates the trailer as
`AGENT_NAME:MODEL_VERSION` and treats whitespace inside `AGENT_NAME` as
malformed, so a kernel patch with the spaced form draws a `BAD_SIGN_OFF`
warning. All five kernel patches pass `checkpatch.pl --strict` clean; the Xen,
Zephyr, QEMU and U-Boot patches are not checked by that script and keep the
readable spelling.

## Zephyr Dom0 (DOM0_OS=zephyr, the default)

The default Dom0 is **Zephyr acting as a xenstore server only** (no toolstack,
no device drivers) — the disaggregated control plane described in *Boot
process*. It is built from:

- **Source**: [`xen-troops/zephyr-dom0-xt`](https://github.com/xen-troops/zephyr-dom0-xt)
  @ `rpi5-v0.4.0`, fetched by moulin as a `west` source; zephyr builder,
  board `rpi_5`.
- **Patch series**: `meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/`
  (0001-0018 + its own README with the per-patch rationale and required
  `west build` flags). Highlights:
  0001 aligns the domctl ABI with Xen 4.21 (load-bearing — guest creation
  fails with rc=-3 without it), 0004 adds the SoDeV DomU/DomA `dom_cfg`
  entries, 0006/0007 move the toolstack role to DomD, 0012/0014-0016 harden the
  xenstore server against ring wedges (0013 is a regions null-init-ptr fix), and
  0017 guards `xu console` against toolstack-introduced domains whose console
  ring Dom0 never mapped (was crashing Dom0).
- **Applying the patches**: moulin has no patch hook for west sources, so run
  `meta-rpi-sodev/meta-xt-common/meta-xt-dom0-zephyr/apply-zephyr-patches.sh "$PWD/zephyr"`
  once **after** the first `west update` (i.e. after the first moulin/ninja
  fetch) and rebuild. The script is idempotent; its only argument is the west
  workspace root (`<build-root>/zephyr`, or set `$XT_ZEPHYR_SRC`).
- **Console**: the Zephyr shell is on the muxed debug UART (`Ctrl-A` x3 —
  see *Testing*); `xu list` / `xu console <id>` are available for
  diagnostics, while normal guest lifecycle runs from DomD's `xl`.

## Boot process

> Two boot-time failures that used to be documented here are in
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) instead, because they are symptoms
> rather than design: *Late EDID on HDMI-A-2* (the IVI panel stays dark and the
> guest cannot tell) and *DomD-side toolstack units are masked in the thin-Linux
> flavour* (why DomD reports no failed units).
1. RPi5 EEPROM loads u-boot; `boot.scr` loads Xen, the Dom0 image, the DomD
   kernel and the device trees, and marks the passthrough nodes. DomD carries no
   ramdisk: it mounts its rootfs from p2.
2. Xen starts **dom0less**: Dom0 and DomD come up in parallel; DomD is
   direct-mapped (`xen,static-mem`) and owns GPU/RP1 (and SDHCI in the zephyr
   flavour). The xenstore ring page of the dom0less DomD is reserved from its
   static-mem bank (in-tree Xen patch; it is also an upstream candidate, tracked
   outside this repository).
3. `DOM0_OS=zephyr`: Zephyr Dom0 provides xenstore; **DomD's** xl service chain
   creates DomA first, then DomU (ordering is intentional — see Known issues).
   `DOM0_OS=linux`: Dom0's `xl-create-*.service` chain does the same,
   xenstore-gated on DomD weston.
4. DomD weston (kiosk-shell) routes the qemu windows by app-id:
   DomU -> HDMI-A-1, DomA -> HDMI-A-2. weston's start is gated on the DRM mode lists
   having settled (`96-wait-drm-modes.conf` -> `weston-wait-drm-modes`); see below.

## Differences vs the V4H AGL SoDeV (`sodev-demo-workspace`)

For readers coming from the upstream V4H (R-Car) AGL SoDeV — what is kept
identical and what this port changes:

| Area | V4H AGL SoDeV (upstream) | This RPi5 port |
|---|---|---|
| DomU/DomA sources | `sodev-demo-workspace` | **identical** — consumed via the same repo as a pinned submodule (`external/sodev-demo-workspace`); guest virtio contract (virtio-pci BDF addr1-7, virtio-gpu-gl) unchanged, so V4H-built guest images boot unmodified |
| Build flow | `build.sh` + moulin + docker | **mirrored** — this repo's `build.sh`/`docker/` reproduce the same flow on the RPi5 yaml |
| Board / BSP | R-Car V4H (Spider/Sparrow Hawk) | Raspberry Pi 5 (BCM2712 + RP1), via `xen-troops/meta-xt-prod-devel-rpi5` + `meta-rpi-sodev/meta-xt-rpi5` |
| Xen | xen-troops fork | **stock meta-virtualization Xen 4.21** + bbappend patch series (a bbappend patch series over the stock recipes; no forked Xen repo) |
| IOMMU | IPMMU present | **none on BCM2712** → DomD is direct-mapped (`xen,static-mem`); DomU virtio = grant DMA, DomA virtio = foreign mapping (`grant_usage=0`) |
| Dom0 | Linux Dom0 | selectable: **Zephyr xenstore-only Dom0 (default)** or thin Linux Dom0 (`DOM0_OS`) |
| Boot | Dom0 creates domains | **dom0less**: Xen brings up Dom0 + DomD from the DTB; the toolstack domain then creates DomU/DomA |
| Display routing | V4H DU/compositor setup | DomD weston **kiosk-shell app-id routing** to two HDMI heads |
| Yocto release | scarthgap-era layers | **Wrynose 6.0 LTS port** (vendored `LAYERSERIES_COMPAT`/`UNPACKDIR` fixes under `meta-rpi-sodev/`) |

### Design highlights (all documented in-tree)
- **Xen/xen-tools are the stock meta-virtualization recipes** plus an ordered
  patch series in bbappends. No forked xen repo is used by the build:
  `rpi5-sodev.yaml` fetches meta-virtualization at a pinned revision and the
  whole RPi5/virtio delta is reconstructed as `file://` patch series on top of
  the pristine xenbits `stable-4.21` tree (see the headers of
  `meta-xt-rpi5/recipes-extended/xen/xen_4.21.bbappend` and
  `meta-xt-dom0-linux/recipes-extended/xen-tools/xen-tools_4.21.bbappend`).
  Rebasing to a newer Xen means bumping the pin and re-applying the series —
  no fork history to carry.
- **No IOMMU** → direct-map DomD; DomU grant DMA / DomA foreign mapping (`grant_usage=0`). Guest disks per
  flavour: with the thin **Linux Dom0**, Dom0 owns the SD and attaches guest
  disks via `xl block-attach phy:` (kernel blkback; the legacy qdisk unit is
  masked); with the default **Zephyr Dom0* (`docs/DESIGN.md`)*, the SD (SoC SDHCI) is passed
  through to DomD, whose own xl attaches the guest disks locally.
- **Disaggregated control plane (zephyr flavour)**: Dom0 is reduced to a
  xenstore server; the toolstack lives in the driver domain. This follows the
  Xen dom0less capabilities / Hyperlaunch model (control cap on a non-domid-0
  domain).
- **Networking**: flat L2 bridge in DomD (`xenbr0` 192.168.10.10; DomU .10.12,
  DomA .10.13 via dnsmasq static leases) + a Dom0<->DomD p2p vif for routed
  Dom0 SSH (192.168.0.1, linux flavour). All reachable from the bench PC
  through one NIC.
- **Display routing**: DomD weston kiosk-shell routes qemu windows by app-id
  (WMCLASS). The window size propagates to the guest via virtio-gpu
  ui_info/EDID, so the panel mode defines the guest mode.

### Wrynose 6.0 port notes
- Yocto 6.0 ships component repos (no `poky` combo); the yaml reconstructs a
  `poky/` dir from `openembedded-core` + `bitbake` + `meta-yocto` for moulin.
- The upstream `meta-xt-*` layers have no wrynose branch (scarthgap-only); their
  wrynose port (`LAYERSERIES_COMPAT`, `WORKDIR`→`UNPACKDIR`) is vendored under
  `meta-rpi-sodev/` — the only yaml-reproducible way to carry non-appendable
  `layer.conf` changes. The `external/` submodule stays pristine.
- The self-built Mesa 24.2.7 / libdrm / wayland-protocols pins were dropped
  (not disabled): stock wrynose Mesa 26.0.5 already covers the BCM2712-D0 V3D
  support they were pinned for, so only a `mesa.bbappend` (glvnd) is carried. A
  V3D-D0 regression fallback would mean re-vendoring the 24.2.7 recipes.

## DomD compositor startup and rootfs (V4H-aligned)

Two earlier deviations from the upstream / V4H pattern have been removed: DomD no
longer starts weston from a hand-written PID 1, and it no longer runs out of a RAM
initramfs. Both now follow the V4H SoDeV reference implementation.

### weston is started by the stock systemd `weston.service`

DomD used to boot with `rdinit=/init-vc4.sh`, a script that brought the GPU up,
launched `weston` itself and then `exec`ed systemd, with poky's `weston.service`
and `weston.socket` masked at runtime. That had three consequences worth recording,
because each one had to be undone deliberately:

- the three `weston.service.d/` drop-ins were attached to a masked unit and so had
  no effect at all;
- the `weston.ini` that actually took effect was the one the script generated at
  runtime, not the one the recipe installed. The recipe copy still said
  `renderer=pixman` and `mode=preferred`, so simply unmasking the unit would have
  silently moved the compositor onto the CPU rasteriser and dropped both outputs to
  the DRM fallback mode;
- `weston.socket` could not start (its service was masked), `graphical.target`
  therefore never completed, and anything anchored on that target never ran.

What ships now matches V4H: the stock poky `weston.service` (`Type=notify` with
`--modules=systemd-notify.so`, `User=weston`, `PAMName=weston-autologin`, and
`weston.socket` enabled alongside it). The project-specific parts are only the
`weston.ini` — kiosk-shell app-id routing plus the two RPi5-specific output modes —
and three small drop-ins: `95-v3d-env.conf` (`V3D_DEBUG=db`, previously exported by
the PID-1 script), `97-restart-on-failure.conf` and `98-no-watchdog.conf`.

`98-no-watchdog.conf` keeps `WatchdogSec=0` but sets a finite
`TimeoutStartSec=120`. It must not be `0`: with `Type=notify` and `weston.socket`
gating `graphical.target`, "no timeout" would let a compositor that never reaches
ready block that target for ever instead of failing and being retried.
`97-restart-on-failure.conf` widens `StartLimitIntervalSec` to 600 s, because a
60 s window is shorter than the 120 s start timeout above and the rate limiter
would never be reachable.

A fourth drop-in, `99-modifier-workaround.conf`, was **removed** rather than carried
over. It set `MESA_EXTENSION_OVERRIDE=-EGL_EXT_image_dma_buf_import_modifiers` to work
around dmabuf-modifier negotiation, and the reason to drop it is that it was never in
force: it was a drop-in for `weston.service`, and `weston.service` was masked to
`/dev/null` for the whole period the PID-1 launch was shipping. So every observation
of this platform rendering correctly — including the two-screen demo — was made with
gl-renderer running *without* the override. Enabling the drop-in along with the unit
would have introduced an untested change, not preserved a working one. If modifier
negotiation ever does regress, this is the first thing to reintroduce, and the commit
that removed it holds the exact contents.

The GPU bring-up that genuinely cannot be expressed declaratively stays in a
oneshot unit, `domd-gpu-init.service`
(`meta-rpi-sodev/meta-xt-common/meta-xt-driver-domain/recipes-extended/xt-domd-vc4-init/`),
ordered `After=systemd-udevd.service` and `Before=weston.service`. It modprobes
`i2c-brcmstb`, then `vc4`, then `v3d` in that order — `vc4`'s `component_bind_all()`
needs the DDC i2c adapter bound first, and `modules-load.d` gives no ordering
guarantee, which is also why `CONFIG_I2C_BRCMSTB` is pinned to `=m` — and pins V3D
runtime-active as a guard for the 6.18 runtime-PM hang under Xen.

**Difference from V4H, deliberately.** V4H points its device-models at
`/run/user/1000` with `WAYLAND_DISPLAY=wayland-1` through a drop-in that upstream
itself labels a temporary hack, because it assumes the `weston` user's uid. poky
already publishes a global socket at `${runtimedir}/wayland-0` = `/run/wayland-0`
via `weston.socket`, so this port sets `XDG_RUNTIME_DIR=/run` and
`WAYLAND_DISPLAY=wayland-0` instead, which resolves to that socket without assuming
any uid. The old non-standard `/wlrt` runtime directory is gone.

**Known issue kept from V4H.** `weston-notification.service` publishes
`drivers/weston-up/status = ready` to xenstore and writes `dead` from
`ExecStopPost`, and the `xl-create-doma/domu` units poll that node. Combined with
`Restart=on-failure`, a weston restart therefore flips the guest-creation gate to
`dead` and back. This is the V4H mechanism verbatim; on V4H the waiter lives in
Dom0, so the xenstore round trip is unavoidable there.

### The DomD rootfs is SD p2, not a RAM initramfs

DomD used to run entirely out of `initramfs-domd-vc4.cpio.gz` (104 MiB on p1,
unpacking to roughly 495 MiB), while the 9 GiB ext4 on p2 was built but never
mounted. It now boots p2 directly, which is what the V4H DomD does: V4H sets
`root=/dev/STORAGE_PART2 rw rootwait` and its `domd-set-root` strips the `ramdisk=`
line entirely when booting from mmc. The initramfs V4H does carry exists only to
load `pcie-rcar-gen4` before a PCIe-attached rootfs appears, and `switch_root`s
away immediately.

The two flavours reach p2 differently, because SD ownership differs:

| | `DOM0_OS=zephyr` | `DOM0_OS=linux` |
|---|---|---|
| SoC SDHCI owner | DomD (`xen,passthrough`) | Dom0 (hardware domain) |
| DomD `root=` | `/dev/mmcblk0p2` | `/dev/xvda` over PV-block |
| how it is provided | DomD's own mmc controller | `xl-attach-disks.service` in Dom0 block-attaches `phy:/dev/mmcblk0p2` as `xvda` |

In the linux flavour DomD's partial device tree omits the SD/GPIO block (stripped by
`domd-vc4.bb`) precisely so the dom0less DomD does not re-request mmc IRQ SPI273 and
fail with `route_irq_to_guest -EBUSY`. `xen-blkfront` is built in, the kernel blocks
on `rootwait`, and Dom0 attaches p2 before anything else — a missing p2 is a hard
failure in that unit rather than a skip, since DomD can never boot without it. There
is no circular dependency: `/libxl/1/type`, which the attach waits for, is created by
Dom0's `init-dom0less`, not by DomD.

Gains: persistent logs and state, roughly 0.5 GiB of DomD RAM back, and the `/run`
re-mount problem (and with it the non-standard `XDG_RUNTIME_DIR`) disappears.

**Measured boot timing** (DomD monotonic, from the kernel's own log): p2 ext4 mounted
at t+0.65 s, `Run /sbin/init` at t+0.65 s, `basic.target` t+3.2 s,
`domd-gpu-init.service` finished t+3.8 s, **weston `READY=1` at t+7.6 s**, DomA
created t+11 s, DomU t+12 s, DomD SSH reachable and DomU holding a DHCP lease by
t+19 s. So the compositor costs only about a second more than the old PID-1 launch
(~7 s) even with a 9 GiB ext4 mount in front of it.

The first measurement also showed `multi-user.target` at t+102 s — 90 s of which was
pure dead time from three fixed timers that had nothing left to wait for, all since
removed: the flat-bridge unit ran its tap-enslaving loop to completion instead of
breaking out once all three taps were in the bridge (they were, by t+12 s), and
`getty.target` waited out `DefaultTimeoutStartSec` twice for `/dev/hvc0` and
`/dev/ttyAMA10`, neither of which exists in DomD.

**Always shut the board down cleanly, or at least `sync` on DomD, before pulling the
SD.** A writable ext4 root is exposed to damage a RAM initramfs was immune to, and
this is measured rather than theoretical: after one power-cut removal of the card,
`e2fsck -fn` reported errors on **both** ext4 partitions (p2: `Free inodes count
wrong`, `Feature orphan_present is set but orphan file is clean`, `Filesystem still
has errors`; p3, DomU's rootfs: errors as well) and `fsck.fat -n` found the FAT dirty
bit set on p1. Rewriting the affected partitions from the built image clears it.

Note that a writable rootfs alone does **not** give persistent logs: poky ships
`/var/log` as a symlink to `volatile/log` (`VOLATILE_LOG_DIR`), so journald keeps
using only its runtime journal under `/run`. The image recipe therefore replaces that
symlink with a real directory and creates `/var/log/journal`; the journal is capped
(`SystemMaxUse=128M`) because it now survives every boot. SSH host keys likewise
survive reboots now instead of being regenerated each time.

The RAM-initramfs image recipe is not part of this PR. Reviving that boot path would
need more than restoring p1 from an older build: the PID-1 script it chained through
(`rdinit=/init-vc4.sh`) is gone, and so are the DomD `module@2` node and the cpio.gz
fatload in the boot scripts. The last working revision of all of it is in the git
history.

