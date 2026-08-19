# Zephyr Dom0 hybrid migration — vendored patches

These patches carry the Dom0 Linux→Zephyr **hybrid** migration changes for the
Zephyr Dom0 component (`dom0:` in `rpi5-sodev.yaml` under `--DOM0_OS zephyr` (the default)).

Hybrid architecture: **DomD stays a dom0less domain** (created by Xen from the
U-Boot boot modules, keeping its proven GPU/HDMI/RP1 direct-map + static-mem
passthrough unchanged). The **Zephyr Dom0 runs only the xenstore server**; the
two virtio guests (DomU = AGL cluster, DomA = AAOS) are created by **DomD's xl
toolstack** (`xl create`, via the DomD `xl-create-*.service` chain — patches
0006/0007 grant the dom0less DomD the xenstore privilege to do so). This
sidesteps the fact that the current `zephyr-xenlib` has no direct-map/static-mem
allocation path (so Zephyr cannot create the GPU driver domain itself).

moulin's git/west fetchers do **not** support `apply_patch`, and the Zephyr
sources are pulled fresh by `west update` at the pinned revs. Apply these
patches to the west workspace **after `west update`** and **before** building
the `dom0` component (see `apply-zephyr-patches.sh`).

## Patches

The set is **self-contained**: on a clean checkout of the pinned revs it adds
every symbol the SoDeV guests reference. It is also **not** a menu of independent
fixes — 0004 without 0002/0003 will not build, 0021 has to come first (and be
followed by a second `west update`) because it is what moves the pins, and the
`Depends on` lines in the individual patch headers are load-bearing.

**0001, 0010 and 0013 are vacant numbers.** They were dropped in the move to
Zephyr 4.4.1, for the reasons in their rows below. The numbers are deliberately
not reused: commit messages, evidence records and the sections further down this
file refer to patches by number.

> **Verification basis.** `apply-zephyr-patches.sh` runs end to end against a fresh
> `west init`/`west update` and the result builds; that is the claim made below, and
> "Verification status" says exactly how far it was taken on which pins. The script
> does more than apply patches - see "Series completeness verification". No
> build-artifact checksums are quoted here because they depend on the toolchain and
> on the west workspace state at build time.

| # | Target repo (west) | Pinned rev | File(s) | What |
|---|---|---|---|---|
| ~~0001~~ | — | — | — | **Gone.** It added the `altp2m` field to Zephyr's vendored `xen_domctl_createdomain`. 0024 removes that vendored copy altogether, and zephyr-xenlib's headers (a byte-for-byte copy of Xen 4.21.0's) already carry the field. Applying 0001 alone was also never enough on 4.4.1: it brought `sizeof(struct xen_domctl_createdomain)` to 72 where Xen 4.21 expects 76, because `arch.arm_sci_type` was still missing. |
| 0002 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `Kconfig`, `boards/rpi_5.conf` | Add the `DOM_CFG_SODEV` symbol (gates the SoDeV guests) and the `DOM_CFG_AAOS_DOMAIN` symbol (the upstream single-AAOS example). Neither exists at the pinned rev. Also flips `CONFIG_DOM_STORAGE_FATFS_DIR` to `""` in `rpi_5.conf` (p1 FAT-root guest image lookup; see §Guest image staging). |
| 0003 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/dom0.{c,h}`, `src/storage.c` | Add the xenlib **optional-initrd** storage callbacks (`storage_image_initrd_read`/`_get_size`), the `image_initrd_path` field on `dom0_domain_cfg`, and the `dom0.c` wiring that points `initrd_info` at the config when a path is set. `rpi_5_sodev_doma` depends on these. |
| 0004 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/dom_cfg/rpi_5.c` | Add `rpi_5_sodev_domu` (1 GiB AGL cluster) and `rpi_5_sodev_doma` (4 GiB AAOS) dom_cfg + `domain_cfgs[]` registration, gated on `CONFIG_DOM_CFG_SODEV`. Also carries the `domu_cfg_4` AAOS example (gated `CONFIG_DOM_CFG_AAOS_DOMAIN`, off by default). |
| 0005 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-dom-mgmt/include/domain.h`, `.../include/xen-dom-fdt.h`, `.../src/xen-dom-fdt.c`, `.../src/xen-dom-mgmt.c` | Optional-initrd loading in xenlib: the `initrd_info` field + `load_initrd_bytes`/`get_initrd_size` callbacks on `struct xen_domain_cfg`, the `linux,initrd-start/end` chosen-FDT props, and the physmap initrd load. `rpi_5_sodev_doma`'s Android layered ramdisk needs these. **Without 0005 the build fails: `struct xen_domain_cfg has no member named initrd_info`.** |
| 0006 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `Kconfig`, `xenstore-srv/include/xenstore_srv.h`, `xenstore-srv/src/xenstore_srv.c` | `CONFIG_XENSTORE_TOOLSTACK_DOMID` + `xss_set_toolstack_domid`: grant the dom0less DomD Dom0-equivalent xenstore privilege so it can serve the guests' virtio backends. Concretely, this is what lets DomD seed the `device-model/<domid>` xenstore nodes the qemu backends and `xl devd` read; without it those writes are refused as unprivileged. Not needed to compile, but required for the DomD device-model data plane at runtime. Regenerated against xenlib `main`. |
| 0007 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xenstore-srv/src/xenstore_srv.c`, `xen-dom-mgmt/{include/xen_dom_mgmt.h,src/xen-dom-mgmt.c}` | DomD-as-toolstack xenstore: `XS_INTRODUCE`/`XS_RELEASE` handlers + `@introduceDomain`/`@releaseDomain` watches, so an external privileged domain (dom0less DomD) can create/destroy guests via `xl` against the thin Zephyr Dom0 xenstore server. Regenerated against xenlib `main`. |
| 0008 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `boards/rpi_5.{conf,overlay}`, `src/dom0.h` | RPi5 board: HW-verified Dom0 bring-up + DomD-owns-SD. Rebased for 4.4.1: the `&sdio1` disable, `CONFIG_DISK_DRIVER_SDMMC=n` and the `CONFIG_XEN_DOMCTL_XENTROOPS_ARCH_*` assignments are dropped — none of those exist upstream, and on Zephyr 4.x an assignment to an undefined symbol is a build error (an unresolved DTC label likewise). |
| 0009 | `xen-troops/zephyr-xrun` | `5b6ecf2` | `src/storage.c` | Compile without `CONFIG_SDHC` (the SD is passed through to DomD, so xrun's SDHC path is dead on this board). |
| ~~0010~~ | — | — | — | **Gone.** Replaced by 0022, the upstream backport of the same `XEN_SYSCTL_INTERFACE_VERSION` range widening. The value itself is now set in `boards/rpi_5.conf` (0028) instead of by changing the Kconfig default, which keeps this tree closer to upstream. |
| 0011 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `Kconfig`, `src/domain_bins.S` | DomA built-in ramdisk slot (AAOS vendor_boot ramdisk). |
| 0012 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-dom-mgmt/src/xen-dom-mgmt.c` | `xs-introduce` no-clobber: `XS_INTRODUCE` must not overwrite an externally-created domain's existing xenstore node/state. |
| ~~0013~~ | — | — | — | **Gone.** It null-initialized `ptr` in `drivers/xen/regions.c`. The upstream version of that driver, backported here as 0023, already has `void *ptr = NULL`. |
| 0014 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xenstore-srv/src/xenstore_srv.c` | xenstore-server reply-path hardening against ring-wedge conditions (+ "ring corrupt" diagnostics). Rewritten against xenlib `main`; see the 0014 note below. |
| 0015 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-dom-mgmt/src/...`, `xen-shell-cmd/src/xen_cmds.c` | Toolstack-domain teardown + `xu xsring` diagnostics (HW debug; see note below). |
| 0016 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-dom-mgmt/include+src` | Guard the domain-destroy paths by toolstack ownership (`f_toolstack`). |
| 0017 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-console-srv/src` | Guard `xu console` against toolstack-introduced domains whose console ring Dom0 never mapped (was crashing Dom0). |
| 0018 | `xen-troops/zephyr` (fork) | `1f6485eca2` | `drivers/xen/dom0/domctl.c` | Zero the `createdomain` hypercall argument. It is the only `xen_domctl_t` in that file without an initialiser, and the one that matters: Xen reads its own idea of the struct, so any trailing field Zephyr does not write would come from uninitialised stack. Since 0024 the layouts match, and this makes `arch.arm_sci_type` a defined 0 (`XEN_DOMCTL_CONFIG_ARM_SCI_NONE`). Also fixes the comma operators in the assignments below it. |
| 0019 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `boards/rpi_4b.{conf,overlay}` | **Raspberry Pi 4 Model B (BCM2711) Zephyr Dom0 board.** From upstream; rebased here for 4.4.1. Three of its Kconfig assignments were hard errors on 4.x: `FS_MULTI_PARTITION` is spelled `FS_FATFS_MULTI_PARTITION` upstream, and `XEN_DOMCTL_XENTROOPS_ARCH_{VGSX_OSID,SCI_TYPE}` existed only in the xen-troops fork. `HW_STACK_PROTECTION=y` is replaced by `STACK_SENTINEL=y` for the same reason as rpi_5 (only `CPU_AARCH64_CORTEX_R` selects `ARCH_HAS_STACK_PROTECTION`). The overlay gains the inert `ramdisk0` (4.4.1 derives `FF_VOLUMES` from status-okay disk nodes and rpi_4b had none, which breaks `ff.c` and the `BUILD_ASSERT(FF_VOLUMES == 1)` in the shared `src/storage.c`), deletes the dangling `chosen zephyr,entropy` and the `leds`/`led0` pair, and disables `gpio1`. Adds `XEN_SYSCTL_INTERFACE_VERSION=0x16`, `XEN_REGIONS=y`, `XENSTORE_TREE_TRAVERSE_DEPTH=16` to match rpi_5. `sram0` stays at upstream's measured `0x20000000` (`dom0_mem=128M`). |
| 0020 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/dom_cfg/rpi_4b.c` | **RPi4 guest domain configs** (`rpi_4b_sodev_domu` / `rpi_4b_sodev_doma`, GIC_V2 — BCM2711 is a GIC-400 like BCM2712). From upstream, unchanged: its `<zephyr/xen/public/domctl.h>` include is rewritten by 0027 rather than here, so this patch stays as close to upstream as possible. That is why `apply-zephyr-patches.sh` no longer keeps 0019/0020 at the end of the series — they must precede 0027. |
| 0021 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `west.yml` | **Zephyr 4.4.1 + the zephyrproject-rtos xenlib.** Moves `zephyr` to `1f6485ec` (`zephyr-v4.4.1-xt`), repoints `zephyr-xenlib` at `zephyrproject-rtos` `7f08845` (`main`), and moves `fatfs` to `f4ead3bf`. Applied first, followed by a second `west update` — moulin's west source can only pin the manifest repo's url/rev, so this file is the only way to change the project pins. |
| — | `zephyrproject-rtos/fatfs` | `f4ead3bf` | — | Not patched, but pinned by 0021 and part of the workspace: Zephyr 4.4.1's `modules/fatfs/zephyr_fatfs_config.h` asserts `FFCONF_DEF == 80386`, and the previous pin `427159bf` is 80286. |
| 0022 | `xen-troops/zephyr` (fork) | `1f6485eca2` | `arch/arm64/core/xen/Kconfig` | Backport of upstream `31d2bd60ff29`: widen the `XEN_SYSCTL_INTERFACE_VERSION` range so `0x16` (what Xen 4.21's `sysctl.h` declares) is accepted. Replaces 0010. |
| 0023 | `xen-troops/zephyr` (fork) | `1f6485eca2` | `drivers/xen/{regions.c,Kconfig,CMakeLists.txt}`, `include/zephyr/xen/regions.h` | Backport of upstream `26d1dce50e01`: the Xen extended-regions driver. Dom0 maps guest kernels/dtbs through it while building a domain. Without it xenlib falls back to carving the window out of Dom0's own 2 MiB heap, which a 24 MiB guest kernel does not fit. |
| 0024 | `xen-troops/zephyr` (fork) | `1f6485eca2` | `include/zephyr/xen/public/` (removed), 20 files' includes, `arch/arm64/core/xen/Kconfig` | Backport of upstream `d58fbb8cfc58`: drop Zephyr's vendored Xen public headers and take them from zephyr-xenlib instead, plus `select GNU_C_EXTENSIONS`. Both trees used the *same* include guards for *different* struct layouts, so whichever one a translation unit reached first won: `sizeof(struct xen_arch_domainconfig)` was 12 in Zephyr's copy and 16 in xenlib's, an ODR violation the linker cannot see. The 14 header deletions are done by `apply-zephyr-patches.sh` (a `git apply` deletion does not survive the script's reset). |
| 0025 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `prj.conf` | `CONFIG_MP_NUM_CPUS` → `CONFIG_MP_MAX_NUM_CPUS`. Removed in Zephyr 4.0; already a no-op alias in 3.6, so the value does not change. |
| 0026 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `Kconfig`, `boards/rpi_5.conf`, `src/storage.c` | Track the Zephyr 4.x FATFS renames: `FS_MULTI_PARTITION` (a fork-only symbol) → `FS_FATFS_MULTI_PARTITION`, and `SDMMC_VOLUME_NAME` (removed in 4.0, now a devicetree `disk-name`) → the literal `"SD"` its default produced. |
| 0027 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/domu_cfg.c`, `src/dom_cfg/rpi_5{,_domd}.c`, `src/dom_cfg/rpi_4b.c` | `<zephyr/xen/public/domctl.h>` → `<xen/public/domctl.h>`, i.e. take the Xen ABI from zephyr-xenlib. Required once 0024 removes the vendored copy. |
| 0028 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `boards/rpi_5.{conf,overlay}`, `src/storage.c` | Keep 4.4.1's newly-enabled devices out of Dom0. The overlay disables **eight** nodes - `pcie1`, `pcie2`, the three RP1 GPIO banks `gpio0_0`/`gpio0_1`/`gpio0_2`, `gio_aon` (and the `leds` node plus the `led0` alias that reference it), `rng` and `uart10` - because none of that hardware is Dom0's here and only the GIC is statically mapped, so each driver's `SYS_INIT` would fault on its first register access; the same failure 0008 documents for the 3.6 SDHCI node. Disabling is not always enough, so the overlay also **deletes** the `chosen zephyr,pcie-controller` and `zephyr,entropy` properties and the `.conf` sets **`CONFIG_PCIE=n`**: `gen_defines` resolves a chosen phandle regardless of `status`, so `drivers/pcie/host/pcie.c` still expanded `DEVICE_DT_GET(DT_CHOSEN(zephyr_pcie_controller))` to a `__device_dts_ord_N` that was never emitted. It adds the inert `ramdisk0` FatFs volume (4.4.1 derives `FF_VOLUMES` from status-okay devicetree disk nodes, and with none the generated `ff.c` does not compile) and fixes `src/storage.c`'s `VolToPart[0]` from `{3, 2}` to `{0, 2}` - `pd` indexes `zfs_diskio.c`'s `pdrv_str[]`, which now has one entry, so 3 was an out-of-bounds read. Sets `CONFIG_XEN_REGIONS=y`, `CONFIG_XEN_SYSCTL_INTERFACE_VERSION=0x16` and `CONFIG_XENSTORE_TREE_TRAVERSE_DEPTH=16` (see 0031). |
| 0029 | `xen-troops/zephyr-xrun` | `5b6ecf2` | `src/xrun.c` | Same change as 0027, for the one `#include <zephyr/xen/public/domctl.h>` in xrun. Required once 0024 removes Zephyr's vendored copy, otherwise the build stops with "fatal error: zephyr/xen/public/domctl.h: No such file or directory". |
| 0030 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xen-dom-mgmt/src/xen-dom-mgmt.c` | The three `arch_dcache_flush_and_invd_range()` call sites in the kernel/dtb/initrd load paths passed `nr_pages` where `include/zephyr/arch/cache.h` wants a **byte count**, so they flushed 1/4096 of the mapping and left the rest of the guest image in Dom0's dirty D-cache. Found while regenerating 0005 against xenlib `main` (see 0005's `Local-Modifications:`); worth submitting upstream on its own. |
| 0031 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `xenstore-srv/src/xenstore_srv.c`, `Kconfig` | Input validation and resource bounds, from adversarial review of this series. NUL-terminate the request payload at the boundary (every path handler treated it as a C string, so `header.len == 0` or a payload without a NUL read off the end of the allocation - and construct_path() copied what it found into a key the guest can read back); refuse to free the static root node (`xs rm /` wrote through a NULL dlist pointer and k_free()d a .bss address); arm the xss_do_write() rollback before the perms allocation (a failure on the first new node left a node with an empty perms list, which check_perms() dereferences); scope key_to_watcher() by domain and compare tokens exactly; require watch prefixes to end on a path boundary; coalesce and cap pending watch events per domain (the list was unbounded and grew K*K per write); bound the work done per pass under the global tree lock; stop emitting a req_id-0 XS_ERROR for an oversized watch event; bound tree depth at creation (`CONFIG_XENSTORE_TREE_TRAVERSE_DEPTH`, set to the Kconfig maximum 16 by 0028) so the recursive free cannot overflow the xenstore worker stack, which this patch also raises from 4 to 8 KiB to match. All of these predate this series. A second review round then found defects in this patch itself - a missing `path\0token` separator check in watch/unwatch, an unterminated stored token that `fire_watcher()` leaked past, and a pending-event cap that combined with the `running_transaction` drain gate to *drop* events - and they are fixed here too; see its `Second-round review follow-ups:`. |
| 0032 | `zephyrproject-rtos/zephyr-xenlib` | `7f08845` | `CMakeLists.txt`, `include/xen/public/xen-compat.h`, `vch/include/vch.h`, `vch/include/xen/public/io/libxenvchan.h` (removed), `xstat/include/xstat.h` | Finish the single-header-tree move. vch/ held a second copy of `xen/public/io/libxenvchan.h` at the same relative path, and vch.h reached it with a quoted include - so the authoritative copy was never compiled. And `__XEN_TOOLS__` was defined in xen-compat.h, which domctl.h/sysctl.h test with `#error` *before* including xen.h, so a TU whose first include was `<xen/public/domctl.h>` failed; it is now a build definition, as in upstream Xen's tools - and unconditional under `CONFIG_XEN` rather than gated on `CONFIG_XEN_DOM0`, because `XSTAT`/`XEN_DOMAIN_MANAGEMENT`/`XEN_SHELL` have no `depends on XEN_DOM0` and so a `XEN=y`/`XEN_DOM0=n` build compiles `xstat.c`, which includes `domctl.h`. Also retargets the one stale comment in `xstat/include/xstat.h` that still named `include/zephyr/xen/public/domctl.h`. |
| 0033 | `xen-troops/zephyr` (fork) | `1f6485eca2` | `arch/arm64/core/xen/Kconfig` | **[Xen 4.22]** Widen `CONFIG_XEN_DOMCTL_INTERFACE_VERSION` to `range 0x15 0x18` and move the default there. Xen bumped `XEN_DOMCTL_INTERFACE_VERSION` to 0x18 for 4.22; out of range, kconfiglib *discards* a user value with only a warning and falls back to the default, so the `=0x18` set by 0008 (`rpi_5.conf`) and 0019 (`rpi_4b.conf`) would silently stay 0x17 - green build, every domctl rejected by 4.22, and the only symptom a Dom0 whose `xu list` prints nothing. Domctl-side counterpart of 0022 (sysctl): same file, non-overlapping hunk, so it applies at offset 0 right after it. The sysctl version is unchanged on 4.22 (still 0x16), so 0022 needs no follow-up. |

**Gating is self-enabling.** `rpi5-sodev.yaml`'s zephyr `dom0` builder passes
`CONFIG_DOM_CFG_SODEV=y` (alongside `CONFIG_XEN_DOMCTL_INTERFACE_VERSION=0x18`),
so the SoDeV guests are compiled in and registered in `domain_cfgs[]` on a plain
`./build.sh`. **`CONFIG_DOM_CFG_SODEV` is deliberately independent of
`DOM_CFG_AAOS_DOMAIN`** — the AGL cluster (`rpi_5_sodev_domu`) is not an Android
guest and must not be coupled to the AAOS example flag.

### Options this series adds but does not enable

Two additions are inert in the configuration this workspace builds, and are kept
deliberately rather than by oversight:

- **`CONFIG_DOM_CFG_AAOS_DOMAIN`** (0002, with `domu_cfg_4` in 0004). The shipping
  DomA is created by the DomD toolstack from `doma.cfg`, not by Dom0, so this
  built-in Android domain config is not selected. It is kept because it is the
  upstream `zephyr-dom0-xt` example's own shape: dropping it would make the patch
  diverge from the file it modifies, and it is the entry point for anyone bringing
  DomA up from Dom0 directly (a PC harness, or a board with no toolstack domain).
- **`CONFIG_DOM_CFG_DOMA_RAMDISK_*`** (0011). Lets a guest ramdisk be linked into
  the Dom0 binary via `.incbin`. Not used here because the AAOS ramdisk is staged
  on SD p1, but it is the only way to start a guest on a Dom0 that owns no storage
  — which is the direction this topology moves in, since DomD owns the SD.

Neither is referenced by `rpi5-sodev.yaml`, so a plain `./build.sh` compiles
neither. Verified in the build tree's `.config`.


## The createdomain ABI (rc=-3 root cause), and where the fix lives now

Zephyr used to vendor its own trimmed copy of the Xen public headers, and that
copy predated Xen 4.20's `altp2m` addition to `xen_domctl_createdomain`. Without
those 4 bytes the following `arch` sub-struct sits 4 bytes early, so
`arch.gic_version` is read by Xen 4.21 as `cpupool_id`; `cpupool_find_by_id()`
returns NULL, `sched_init_domain` fails with `-ESRCH`, and it surfaces as
`xu create ... rc=-3`. **Verified** on instrumented Xen 4.21 in QEMU:
`>sched cpupool_id=0` → `domain:1 created` after the field was added.

That is what 0001 patched. It is no longer the right fix, for two reasons:

- **It was not sufficient on 4.4.1.** Adding `altp2m` brings
  `sizeof(struct xen_domctl_createdomain)` from 68 to 72; Xen 4.21 expects 76.
  The remaining 4 bytes are `arch.arm_sci_type`, which the vendored copy also
  lacked.
- **The vendored copy is gone.** Upstream deleted it in favour of zephyr-xenlib's
  headers (backported here as 0024), and xenlib's `include/xen/public/` tracks Xen
  4.21.0 — `altp2m`, `arm_sci_type` and all. "Byte-for-byte" holds for the headers
  that carry the ABI this series depends on (see the 9 diffed below), not for the
  whole 75-header tree. `xen-compat.h` is the one header of the nine that is not a
  literal copy, but not in the way an earlier revision of this file claimed: its
  `__XEN_LATEST_INTERFACE_VERSION__` is `0x00041300` (Xen 4.19), and so is **Xen
  4.21.0's own** - verified against the SRCREV this workspace builds (`1c72306b`) and
  the `RELEASE-4.21.0` tag, both `0x00041300`. The ceiling is upstream Xen's, not
  xenlib's: asking for `CONFIG_XEN_INTERFACE_VERSION=0x00041500` trips
  `#error "These header files do not support the requested interface version."`
  against genuine Xen headers too. What xenlib actually changes in that file is how
  `__XEN_INTERFACE_VERSION__` is supplied - from `CONFIG_XEN_INTERFACE_VERSION`
  rather than from the `__XEN__`/`__XEN_TOOLS__` test - plus a `stdbool.h`/`stdint.h`
  include under `CONFIG_XEN` and a copyright line.
- **A third interface version exists and is *not* set by this series.**
  `CONFIG_XEN_INTERFACE_VERSION` stays at Zephyr's upstream default `0x00040e00`
  (Xen 4.14) from `arch/arm64/core/xen/Kconfig`; only `XEN_DOMCTL_INTERFACE_VERSION`
  (0x18 for Xen 4.22, patch 0008; range widened by 0033) and `XEN_SYSCTL_INTERFACE_VERSION` (0x16, patches 0022+0028)
  were moved to 4.21. It gates 20-odd `#if __XEN_INTERFACE_VERSION__` blocks in
  `xen.h`/`grant_table.h`/`memory.h`/`errno.h` and the `XENPV_FLEX_ARRAY_DIM` choice
  in `io/ring.h`. Checked: `0x00040e00` satisfies every lower bound those guards use
  (the highest is `0x00040d00`), and the ring size arithmetic is `offsetof`-based so
  it does not depend on the flex-array dimension. Left alone rather than raised: 4.19
  is the ceiling `xen-compat.h` enforces, and that ceiling is Xen 4.21.0's own.

So on this tree the ABI is correct because 0024 + 0027 make everything read one
set of headers, and 0018 zeroes the hypercall argument so any field Xen reads and
Zephyr never writes is 0. The expected layout, which 0024 is what delivers:

| expression | Xen 4.21 | Zephyr's old vendored copy | + 0001 |
|---|---|---|---|
| `sizeof(struct xen_arch_domainconfig)` | 16 | 12 | 12 |
| `offsetof(struct xen_domctl_createdomain, arch)` | 60 | 56 | 60 |
| `sizeof(struct xen_domctl_createdomain)` | 76 | 68 | 72 |

`sizeof(xen_domctl_t)` is 144 either way — `u.pad[128]` dominates the union — so
the container size proves nothing. Check `createdomain` and `arch`.


## Zephyr 4.4.1 upgrade: behaviour deltas that are NOT from these patches

Measured by diffing the built `.config` against the 3.6.0 build
(a 230-line diff; 44 `CONFIG_` lines only in 3.6.0, 103 only in 4.4.1, the rest changed values). Everything else in that diff is either one of
the renames these patches make, the SD-related devicetree nodes that 4.4.1's board
does not have, or upstream Kconfig churn with no effect here. These two are
upstream default changes that do change runtime behaviour, left at the upstream
value deliberately - deviating without evidence would add risk of its own - but
worth knowing about when reading a hardware log:

| Kconfig | 3.6.0 | 4.4.1 | why it matters |
|---|---|---|---|
| `TIMESLICE_SIZE` | `0` (off) | `20` ms | Preemptive time slicing between equal-priority preemptible threads is on now. Dom0 is single-CPU (`MP_MAX_NUM_CPUS=1`), so this only reorders the shell thread against the xenstore worker threads; it does not change stack usage, so it is unrelated to the `xu create` stack overflow 0008 fixes. |
| `LOG_RATELIMIT` | absent | `y`, 5000 ms | Repeated identical log lines can now be suppressed. 0008 sets `LOG_MODE_IMMEDIATE=y` specifically so a failure line prints atomically and readably on the shared Xen UART; if a repeating error looks like it stopped, check whether it was rate-limited rather than assuming it cleared. |

Also worth noting, though not a behaviour change: `NUM_IRQS` went 512 -> 280
(devicetree/SoC-derived in 4.4), `SCHED_DUMB`/`WAITQ_DUMB` became
`SCHED_SIMPLE`/`WAITQ_SIMPLE`, newlib gave way to picolibc as the default libc, and
`CONFIG_KERNEL_DIRECT_MAP=y` is now pulled in because upstream's `XEN_REGIONS`
selects it.

## Apply

```sh
# ZEPHYR_WS = the west workspace root (contains zephyr/, zephyr-dom0-xt/, .west/)
./apply-zephyr-patches.sh /path/to/zephyr-workspace

# DomZ's workspace shares this manifest repository but builds none of the Dom0
# sources, so it takes the pins and nothing else:
./apply-zephyr-patches.sh --manifest-only /path/to/zephyr-domz
```

Each patch is a `git diff` against its repo's pinned rev, so it applies cleanly
to a fresh `west update` checkout (`git apply`). The script is idempotent by
construction: each run first resets every target repo - `git reset --hard` to
west's `manifest-rev` branch where it exists, plus `git clean -fd` - and then
re-applies the whole series, and it prints the failing hunks with a fix hint if the
checkout has drifted from the pinned rev. Naming a revision is deliberate:
`git checkout -- .` restores from the index, so a *staged* partial application
survives it, and a bare `git reset --hard` with no revision does not undo a
*committed* one either.

## Guest image staging (historical)

> **Historical, superseded on real hardware by patch 0008.** This section documents
> the earlier design where **Zephyr's `xu`** loaded the guest kernels/ramdisks from
> the SD p1 FATFS itself (hence `CONFIG_DOM_STORAGE_FATFS_DIR=""` via patch 0002). In
> the shipping design, **DomD owns the SD** (SoC SDHCI passed through to DomD;
> see patch 0008) and **DomD's `xl create` toolstack** creates and loads the guests
> (matching this README's opening summary and patches 0006/0007) — the Zephyr
> FATFS/`xu`-create path is **unused/dead** on this board (patch 0009 even compiles
> out `CONFIG_SDHC`). The `CONFIG_DOM_STORAGE_FATFS_DIR=""` change from 0002 is
> therefore inert at runtime here; it is kept only for the non-passthrough/PC-harness
> path. Read the rest of this section as the historical mechanism, not the live one.

The `domain_cfgs[]` entries load each guest kernel/ramdisk from the FATFS
storage path (SD p1) at `DISK_BIN_PATH` = `/0:/` + `CONFIG_DOM_STORAGE_FATFS_DIR`:

| dom_cfg | `image_kernel_path` | `image_initrd_path` |
|---|---|---|
| `rpi_5_sodev_domu` | `linux-domu` | — (initramfs-bundled) |
| `rpi_5_sodev_doma` | `aaos-android-kernel` | `aaos-vendor-boot-ramdisk` |

The existing image wires those files to the **p1 FAT root** (`linux-domu` via
the `ENABLE_DOMU=yes` variant; `aaos-android-kernel` / `aaos-vendor-boot-ramdisk`
in the base boot items). The board default `CONFIG_DOM_STORAGE_FATFS_DIR="dom0/"`
would make `xu` look in `/0:/dom0/` and miss them, so patch 0002 sets
`CONFIG_DOM_STORAGE_FATFS_DIR=""` in `boards/rpi_5.conf`, aligning the lookup to
the root. (The override lives in the `.conf`, not as a `-D` in `rpi5-sodev.yaml`,
because moulin mishandles an empty-string `-D` argument.) Without a matching file
`xu create` fails at `xrun_get_file_size`.

**Build-graph resolution:** `aaos-android-kernel` / `aaos-vendor-boot-ramdisk`
are **md5-pinned prebuilts** staged into the AAOS layer before the build (see the
top-level README §"Staging the AAOS prebuilts") — they are deliberately not
produced inside the Zephyr Dom0 graph (the Zephyr west build has no
`tmp/deploy/images/…`). With them staged, `DOM0_OS=zephyr` produces the complete
4-domain `full.img` (p1 carries `zephyr.bin` + `xen` + the DomD `Image`/initramfs/DT
+ `aaos-android-kernel` / `aaos-vendor-boot-ramdisk` + `linux-domu`; p4 the AAOS
nested GPT). This was verified end-to-end from a clean checkout for **both**
`--dom0=zephyr` and `--dom0=linux` on the 3.6.0 pins, and both have been re-run on
the current 4.4.1 pins at the DomD-only scope (no `-u`/`-a`); see
"Verification status". `linux-domu` comes
from the separate `build-domu`.

## Verification status

> **Read the scope first.** Everything under "On Zephyr 3.6.0 + xenlib v3.2.0"
> below was measured on the *previous* pins. On the current pins
> (Zephyr 4.4.1 + zephyrproject-rtos xenlib) **only the build has been verified —
> there is no hardware run yet.**
>
> **Rebased onto upstream `main` (2026-08-17).** The series now sits on top of
> upstream's RPi4 work, and two things changed underneath it that invalidate part of
> what is recorded below: `sram0` moved from `0xc0000000` to the hardware-measured
> `0xa0000000` (upstream measured `BANK[0] 0xa0000000-0xc0000000` on 2026-08-03 after
> `dom0_mem` went 1024M -> 512M), and the series grew from 27 to 30 patches with the
> two rpi_4b ones. Every measured value in this section was re-taken after the
> rebase; anything that could not be re-taken is marked as such.

### On Zephyr 4.4.1 + zephyrproject-rtos xenlib (current pins)

- `apply-zephyr-patches.sh` runs end to end from a fresh `west init`/`west update`,
  including the mid-series `west update` that moves the pins. Re-running it is
  idempotent (verified 3 consecutive times). VERIFIED.
- `west build -b rpi_5` links `zephyr.elf`; 0 errors, 0 `undefined reference`,
  0 Kconfig warnings (Zephyr 4.x promotes those to errors). RAM 2916 KB / 128 MB.
  `CONFIG_SRAM_BASE_ADDRESS=0xa0000000`. The RAM figure is rpi_5's; rpi_4b is
  2920 KB (its ELF LOAD span is 4 KiB larger). VERIFIED.
- `west build -b rpi_4b` also links, with the same result: 0 errors, 0 Kconfig
  warnings, `CONFIG_SRAM_BASE_ADDRESS=0x20000000`. The build itself is the proof that
  `FF_VOLUMES == 1` on that board too, because the `BUILD_ASSERT` sits in the shared
  `src/storage.c`. VERIFIED.
- Reproducible: `zephyr.bin` md5 identical across repeated apply+build cycles. VERIFIED.
- Binary size, for the hardware step: `zephyr.bin` **230,160 B** on both boards
    (`zephyr.elf` 2,648,920 B; text 204,132 / data 20,694 / bss 2,757,837).

    **No md5 is quoted here on purpose.** Earlier revisions of this file quoted one,
    but the image is absolute-linked from `CONFIG_SRAM_BASE_ADDRESS` and its contents
    also move with `CONFIG_XEN_DOMCTL_INTERFACE_VERSION`, so a checksum taken before
    either changed identifies the wrong binary while still matching on size -- exactly
    the confusion it was meant to prevent (`sram0` moved `0xc0000000` -> `0xa0000000`,
    and the domctl version moved 0x17 -> 0x18 for Xen 4.22). Take the checksum from
    the build you are about to install:

        md5sum zephyr/build-dom0/zephyr/zephyr.bin

    and compare it on the board after the `scp`. That is the only reason a checksum is
    wanted here at all: the hardware procedure replaces `zephyr.bin` on p1 by `scp`
    rather than by re-writing the SD, so without one there is no way to tell
    afterwards which build a hardware run exercised.
- ABI locked by temporary `BUILD_ASSERT`s in the real aarch64 build:
  `sizeof(xen_arch_domainconfig)==16`, `sizeof(xen_domctl_createdomain)==76`,
  `offsetof(...,arch)==60`, `sizeof(xen_domctl_t)==144`, and the interface versions
  0x17/0x16 — matching Xen 4.21.0, the version that measurement was taken on; the
  shipping pair is 0x18/0x16 for Xen 4.22 (0008/0019 set it, 0033 widens the range). The asserts were removed afterwards. VERIFIED.
- 9 of the 75 headers in xenlib's `include/xen/public/` - the ones this series'
  ABI claims rest on - diffed byte-for-byte against the Xen tree the workspace
  built AT THE TIME (Xen 4.21: `meta-xt-rpi5`'s `xen_4.21.bbappend` pinned PV
  `4.21.0+stable`, SRCREV `1c72306b`): 0 differing lines. That bbappend is now
  `xen_4.22.bbappend` and pins SRCREV `d45d5687`, so re-running this comparison
  means diffing against 4.22, not against the revision named here. That commit's
  public headers are md5-identical to the `RELEASE-4.21.0` tag, so the two baselines
  coincide; `stable-4.21` has since changed `domctl.h` by 5 lines (4 insertions,
  1 deletion from `1c72306b` to `RELEASE-4.21.2`), one of which is a `path`->`Path`
  comment fix outside the guard while the rest are only
  inside `#ifdef __XEN__` (invisible to tools) and both interface versions are still
  0x17/0x16 as they were then (0x18/0x16 now). The other 66 headers were not diffed. VERIFIED.
- `.config` compared symbol-by-symbol against the 3.6.0 build; every difference is
  accounted for (see "behaviour deltas" above). VERIFIED.
- Dom0=Linux flavour: built end to end in the updated image. `ninja image-full`
  produced `full.img` (GPT: p1 boot 512 MiB + p2 domd 9216 MiB) with 0 `ERROR`,
  cross-checked against the in-container bitbake cooker logs rather than only the
  outer log. domd = 6071 tasks (sstate 97 %, 151 actually executed), dom0 = 4799
  tasks (98 %, 101 executed). The hypervisor in p1 is `Xen 4.21.1-pre`
  (PV `4.21.0+stable`, SRCREV `1c72306b`) — the Xen recipe is not shared with the
  Xen 4.22 workspace whose sstate was reused, so it was genuinely rebuilt here.
  No Zephyr artefact reaches this image: `build.ninja` references neither
  `apply-zephyr-patches.sh` nor `meta-xt-dom0-zephyr`, neither `bblayers.conf`
  includes the layer, and p1 contains no `zephyr.bin`. VERIFIED.
  ⚠ **Scope: DomU (AGL, p3) and DomA (AAOS, p4) were not built** - `-u`/`-a` were not
  passed, and rouge omits those partitions by design in that configuration.
- The builder image's own toolchain path was exercised separately, because a 97 %
  sstate hit means almost nothing was compiled: `python3-build-native` and
  `python3-installer-native` (pep517 natives) plus `python3-babel` (pep517 target)
  were rebuilt after `cleansstate` and all succeeded. `PIP_REQUIRE_VIRTUALENV=1`,
  which the image now sets, cannot affect Yocto: bitbake strips it (0 occurrences in
  `bitbake -e`), this poky's `python_pep517.bbclass` installs with `pypa/installer`
  rather than pip, and the only two recipes in the layer set that call `pip install`
  (`build-appliance-image`, `python3-djangorestframework`) are outside our tree. VERIFIED.
- Dom0=Zephyr `full.img`, **rebuilt after the rebase** (2026-08-17): built end to end
  through `./build.sh --board=rpi5 --dom0=zephyr --aaos=off` from a removed
  `ws/zephyr`, exit 0 with 0 `ERROR`, 0 `FAILED`, no ninja retry and no OOM kill.
  This exercises the whole moulin path rather than the standalone `west build`:
  `ninja fetch-dom0` -> `apply-zephyr-patches.sh` (all 30) -> `zephyr_build` ->
  DomD bitbake -> `rouge -fi full`. VERIFIED.
  - **The moulin-built `zephyr.bin` is byte-identical to the standalone one**
    (230,160 B, the same checksum), and so is the copy rouge
    puts in p1. That is the property that makes a single md5 usable as the
    hardware-side identity check: it does not depend on which of the two build entry
    points produced it.
  - The image is named `rpi5-16GB-Dom0Zephyr-<YYYYmmdd-HHMM>.img` and `full.img` is a
    symlink to it, so `dd if=full.img` still works. 10,218,373,120 B, GPT p1 boot
    512 MiB (FAT, 48.9 MB used / 486 MB free) + p2 domd 9 GiB (ext4) - two partitions
    only, because DomU (p3) and DomA (p4) were not built.
  - p1 carries `zephyr.bin`, `xen`, `u-boot`, the uncompressed DomD `Image` (27 MB),
    `bcm2712-rpi-5-b.dtb`, `bcm2712-raspberrypi5-xen.dtbo`,
    `bcm2712-raspberrypi5-domd-vc4.dtb`, `boot.scr` and the RPi bootfiles - and,
    correctly, **no** dom0 initramfs and no `aaos-*`/DomU item.
  - The `boot.scr` in p1 is the Zephyr-gated one: `fatload mmc 0 0x4000000
    zephyr.bin` for Dom0, `dom0_mem=512M`, and DomD still a dom0less module set
    (`xen,domain-id <1>` + `xen,privileged`). Its `dom0_mem` matches the `sram0`
    relink in 0008, which is the pairing `tools/check-memory-map.py` enforces.
  - DomD: 6071 tasks attempted, 5828 needed no rerun (243 executed). ⚠ Most of the
    build was still an sstate hit, so this proves the image assembly and the Zephyr
    side rather than a full DomD recompile.
  - ⚠ **Scope: DomU (AGL, p3) and DomA (AAOS, p4) were not built** - `--aaos=off` and
    no `-u`, matching the Dom0=Linux run. With those off moulin gates the `aaos-*` p1
    items out entirely, which is why no AAOS prebuilt bundle was needed.
  - Built with `XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-3"` to cap every stage at 4 jobs
    while another build had the host at load average 77. bitbake derives
    `BB_NUMBER_THREADS`/`PARALLEL_MAKE` from `oe.utils.cpu_count()`, which reads
    `sched_getaffinity`, and ninja does the same - so the cpuset is the one knob that
    bounds all of them. `docker --cpus` does not, because it leaves `nproc` alone.
- Dom0=Zephyr flavour, **pre-rebase**: built end to end through
  `build.sh --dom0=zephyr`, from a removed `ws/zephyr` (so `west init` ran clean),
  exit 0 with 0 `ERROR`, 0 `FAILED`, no ninja retry. This exercised the whole moulin
  path rather than the standalone `west build`: `ninja fetch-dom0` ->
  `apply-zephyr-patches.sh` (27 at the time) -> `zephyr_build` -> DomD bitbake ->
  `rouge -fi full`. VERIFIED (on that tree).
  - **The moulin-built `zephyr.bin` was byte-identical to the standalone one**
    (230,160 B, the checksum measured then), and
    so was the copy rouge put in p1. That is the property that makes a single md5
    usable as the hardware-side identity check: it does not depend on which of the two
    build entry points produced it. The property is what carries over; the value is
    not - it has moved twice since (the sram0 relink, then the 0x18 domctl bump), which is why no value is quoted in this file.
  - `full.img` 10,218,373,120 B, GPT p1 boot 512 MiB (FAT, 48.9 MB used / 486 MB
    free) + p2 domd 9 GiB (ext4). p1 carries `zephyr.bin`, `xen`, `u-boot`, the
    uncompressed DomD `Image` (27 MB), `bcm2712-rpi-5-b.dtb`,
    `bcm2712-raspberrypi5-xen.dtbo`, `bcm2712-raspberrypi5-domd-vc4.dtb`,
    `boot.scr` and the RPi bootfiles - and, correctly, **no** dom0 initramfs (the
    Linux flavour's p1 has `initramfs-xt-dom0-thin.cpio.gz`, 23 MB; this one has
    nothing in its place).
  - The `boot.scr` in p1 is the Zephyr-gated one: `fatload mmc 0 0x4000000
    zephyr.bin` for Dom0, with DomD still a dom0less module set
    (`xen,domain-id <1>` + `xen,privileged`). The Linux flavour's `boot.scr` names
    `zephyr.bin` only in comments.
  - DomD: 6071 tasks attempted, 6046 needed no rerun (25 executed) - a 99.6 % sstate
    hit, ⚠ so this run proves the image assembly and the Zephyr side, not a DomD
    recompile.
  - **Scope: DomU (AGL, p3) and DomA (AAOS, p4) were not built** - `-u`/`-a` were not
    passed, matching the Dom0=Linux run above, so the two flavours are compared at
    the same scope. With those off, moulin gates the `aaos-*` p1 items out entirely,
    which is why no AAOS prebuilt bundle was needed.
- Upstream's own checkers pass on the rebased tree: `tools/check-memory-map.py`
  reports 0 failures and 0 warnings for both SKUs, including
  "Zephyr sram0 relink 0xa0000000 matches the zephyr flavour's bank[0]", and
  `tools/check-yaml-drift.py` reports no unrecorded drift between `rpi5-sodev.yaml`
  and `rpi4-sodev.yaml` (70 functional differences, matching the baseline) after the
  FATFS drive-name and `additional_deps` edits were mirrored into both. VERIFIED.
- Second review round (adversarial, three independent passes) closed on patch
  provenance and internal consistency as well as code: all 30 patches now parse as
  git trailers (`git interpret-trailers` sees the `Signed-off-by:` in every one; 8
  did not before, because a multi-line `Local-Modifications:`/`Rebased onto`
  paragraph sat between the body and the trailer block), no two share a Subject,
  0022-0024 carry their upstream commit messages verbatim, and 0024 no longer adds
  the `<zephyr/xen/regions.h>` include that is not in `d58fbb8cfc58` (nor omits its
  migration-guide entry). VERIFIED.
- **Hardware: run on 2026-08-18** on a tree whose 30 patches are payload-identical
  to these: four patterns (RPi4/RPi5 x Zephyr-Dom0/thin-Linux-Dom0) all passed. The
  procedure followed there, and the notes in this file, are the reference.

### On Zephyr 3.6.0 + xenlib v3.2.0 (previous pins — provenance of the fixes)

- **Real build (docker sodev-builder, board `rpi_5`)**: a fresh `west update` +
  `apply-zephyr-patches.sh` + `west build` produced **zephyr.bin (2.8 MiB)** with
  `rpi_5_sodev_domu` + `rpi_5_sodev_doma` linked into the ELF, and `.config`
  showing `CONFIG_DOM_CFG_SODEV=y`, `CONFIG_DOM_CFG_AAOS_DOMAIN` unset
  (decoupled), `CONFIG_DOM_STORAGE_FATFS_DIR=""`,
  `CONFIG_XEN_DOMCTL_INTERFACE_VERSION=0x17`. VERIFIED. **This is the end-to-end proof
  the vendored set compiled the hybrid Dom0 from a clean checkout.** (On 4.4.1 the
  same build produces a 225 KiB `zephyr.bin` / 2.6 MB `zephyr.elf`; the 2.8 MiB
  figure is the 3.6.0 one.)
- Patch set applies cleanly to a fresh checkout (`git apply --check` PASS for
  the then-current 0002-0007), and every symbol the SoDeV `dom_cfg`
  references resolves. VERIFIED.
- The createdomain ABI fix: rc=-3 → `domain:1 created` on real Xen 4.21 (QEMU). VERIFIED.
  (Carried by 0001 at the time; on 4.4.1 the same ABI comes from 0024+0027+0018 —
  see "The createdomain ABI" above.)
- 0004: clean compile on the `rpi_5` board; 1 GiB DomU
  `xu create` reaches `domain:1 created` (an earlier configuration halted in the
  1 GiB region map; that does
  not reproduce). VERIFIED. (build tree had `CONFIG_DOM_CFG_AAOS_DOMAIN=y`; with the
  self-enabling `CONFIG_DOM_CFG_SODEV=y` var the SoDeV guests are now compiled in
  regardless of the AAOS flag.)
- **Confirmed on RPi5 hardware (3.6.0 pins only):** DomD-as-device-model (`xl devd`
  ioreq) creates both guests; **full guest boot verified** — AGL cluster on
  HDMI-A-1 + AAOS on HDMI-A-2, both live and touch-capable; guest kernel/ramdisk
  p1 staging and DomA layered-ramdisk/bootconfig placement all validated on HW.
  The complete 4-domain `full.img` also builds from a clean checkout for both
  Dom0 flavours .

## 0011-0012 (and the former 0010): HW-proven fixes from the real-HW bring-up
- **0010 (zephyr)** — widened the `CONFIG_XEN_SYSCTL_INTERFACE_VERSION` Kconfig
  range to 0x15-0x16. Xen 4.21 requires 0x16; at 0x15 every sysctl fails the
  version check, so `xu list` / `xstat physinfo` silently print nothing.
  **Superseded on 4.4.1** by 0022 (upstream backport of the same range change)
  plus 0028 (which sets the value in `boards/rpi_5.conf`).
- **0011 (zephyr-dom0-xt)** — DomA (AAOS) builtin-ramdisk incbin slot
  (`CONFIG_DOM_CFG_DOMA_RAMDISK_BIN_FILE`). The stock builtin mechanism embeds
  only kernel+DTB; AAOS boots kernel + a layered ramdisk. Inert when unset.
- **0012 (zephyr-xenlib)** — do not call `xs_initialize_xenstore()` from
  `xs_introduce_domain()`: for a toolstack-created guest libxl has already
  built the per-domain xenstore tree and the Zephyr defaults clobber it
  (HW-observed as shadow names "DomU-2"/"DomU-3" and broken device wiring).
  `dom0less_init_domain` keeps calling it (no pre-built tree in that path).

### ABI settings applied by the patch series (no manual `west build` flags)

The stock board files target the xen-troops **4.19 fork ABI**; on our Xen 4.22 four
Kconfig values must differ. **These are now carried by the patches — no manual
`west build -D...` overrides are required** (they were, before 0008/0019/0028 and
0022/0033 baked them in). Both boards need them:

| Kconfig | value on Xen 4.22 | applied by |
|---|---|---|
| `CONFIG_XEN_DOMCTL_INTERFACE_VERSION` | `0x18` | 0008 (`boards/rpi_5.conf`) + 0019 (`boards/rpi_4b.conf`); **0033 widens the Kconfig range so the value is accepted** |
| `CONFIG_XEN_SYSCTL_INTERFACE_VERSION` | `0x16` | 0028 (`boards/rpi_5.conf`), 0019 (`boards/rpi_4b.conf`); 0022 widens the Kconfig range so the value is accepted. Unchanged on 4.22 |
| `CONFIG_XEN_DOMCTL_XENTROOPS_ARCH_SCI_TYPE` | — | **n/a on 4.4.1.** Fork-only symbol; the field it gated now comes from zephyr-xenlib unconditionally and is zeroed by 0018 |
| `CONFIG_XEN_DOMCTL_XENTROOPS_ARCH_VGSX_OSID` | — | **n/a on 4.4.1.** Same |

> **Historical (3.6.0 fork).** The two XENTROOPS options inserted fork-specific
> fields into the middle of `struct xen_arch_domainconfig` - a u16 `arm_sci_type`
> between `tee_type` and `nr_spis`, and a u8 `vgsx_osid` between `nr_spis` and
> `clock_frequency` - taking the vendored struct from 12 to 20 bytes and
> `xen_domctl_getdomaininfo` from 120 to 128, which is why the stock `=y` had to be
> overridden. **None of this applies on 4.4.1:** the symbols do not exist, the
> vendored headers are gone (0024), and the ABI comes from zephyr-xenlib, whose
> `arm_sci_type` is a trailing u8 that matches Xen 4.21 exactly. 0008 removes the
> assignments rather than setting them to n - assigning to an undefined symbol is a
> Kconfig error in Zephyr 4.x. See "The createdomain ABI" above for the measured
> layout.

Xen 4.21 has neither field at those positions. It does have an `arm_sci_type`,
but as a `uint8_t` *after* `clock_frequency` (it comes from Xen's own generic
SCI subsystem), and it has no `vgsx_osid` anywhere. So at =y Xen reads `nr_spis`
and `clock_frequency` at offsets 8 and 16 where it expects 4 and 8, and the
getdomaininfolist array stride mismatches — entries 2+ come out as garbage in
`xu list`. Measured with gcc against Xen 4.21's public headers: Xen's
`xen_arch_domainconfig` is 16 bytes with `arm_sci_type` at offset 12, `nr_spis`
at 4; `xen_domctl_getdomaininfo` is 120 with `arch_config` at 104.

Setting them =n does not make the two structs identical: the vendored one is 12
bytes against Xen's 16, and the four bytes of difference are exactly Xen's
trailing `arm_sci_type` plus its padding. The *enclosing* `getdomaininfo` is 120
either way, because 104+12 rounds up to the same 8-byte boundary as 104+16, which
is why `xu list` reads correctly. For the outgoing direction, patch 0018 zeroes
the `createdomain` hypercall argument so Xen reads that byte as
`XEN_DOMCTL_CONFIG_ARM_SCI_NONE` instead of uninitialised stack. Verified on
hardware: with =n `xu list` shows all 4 domains correctly.

### Series completeness verification
Running `apply-zephyr-patches.sh` against a fresh `west init`/`west update` of
`zephyr-dom0-xt` at `rpi5-v0.4.0` reproduces the working trees recorded here for all
**five** projects - zephyr, zephyr-dom0-xt, zephyr-xenlib, zephyr-xrun, fatfs - and
builds.

Note that "clean checkouts + patches" is not the whole story, and the script is not
a plain `git apply` loop: it also (a) runs `west update` in the middle, because 0021
is what moves the pins - so 0018/0022-0024 only apply to the *second* checkout of
`zephyr`, not to the one `rpi5-v0.4.0` originally pinned - (b) removes
`include/zephyr/xen/public/` itself, and (c) rewrites the git remote of any project
whose manifest URL moved - that is how zephyr-xenlib ends up on zephyrproject-rtos.
`west update` moves an existing checkout to a new revision but never re-points its
remote, so without (c) the tree would build from the right commit while
`git remote -v` still said xen-troops. The remote is rewritten in place, not
deleted and re-cloned: an earlier version did `rm -rf` + reclone, which meant any
cosmetic change to west.yml's `url-base` could delete the ~1 GiB `zephyr` checkout.
The remote is renamed to the name west.yml's `remotes:` list gives it (so
`zephyr-xenlib` becomes `zephyrproject-rtos`), and only for the project that
actually moved - deriving the name from the URL's org segment instead, as an earlier
version did, renamed `xentroops` to `xen-troops` on projects whose upstream had not
changed at all.

## 0014-0015 (and the former 0013): xenstore-server wedge fixes + reply-guarantee hardening
Root-caused on real HW: the DomD→Zephyr xenstore connection wedged after guest
creation (manifesting as "DomD network intermittent", "xl list hangs", "destroy
hangs" — all one bug). The Linux guest xenbus serializes requests, so any request
that gets no reply / a wrong-req_id reply, or any code that blocks the per-domain
worker under a global mutex, wedges the whole connection. These patches fix that
class end-to-end.

- **0013 (zephyr)** — `regions.c xen_region_get_pages`: initialize `ptr = NULL`.
  **Superseded on 4.4.1**: the upstream driver backported as 0023 already has it.
  When every extended region is -ENOMEM the loop never assigned `ptr` and returned
  uninitialized stack garbage, which `xenmem_map_region` would then map a foreign
  guest page over (arbitrary-VA corruption).
- **0014 (zephyr-xenlib)** — `xenstore_srv.c` server hardening: handle_rm
  inverted-return (no reply on success); process_message unknown-op replied with
  req_id=0 and leaked the input buffer; invalidate_client self-thread guard (no
  k_thread_join on self); worker-loop out-buffer backpressure gate; handle_input
  oversized-payload → invalidate (was: no reply + ring desync); send_reply_sz made
  non-blocking (removed a k_msleep retry loop reachable under xsel+wel+pfl —
  XS_WATCH_EVENT defers, solicited replies invalidate on OOM); process_pending_watch_events
  takes xsel→wel→pfl and drops permanently-undeliverable events; fire_watcher
  propagates -ENOMEM to defer; get_stack_idx bounds check; XS_IS_DOMAIN_INTRODUCED
  implemented; @introduceDomain/@releaseDomain watch path fixed (handle_watch no
  longer classifies '@' names as relative); send_errno negative-errno normalization;
  handle_directory empty-dir returns an empty list instead of ENOMEM; ring diag logs.
- **0015 (zephyr-xenlib)** — lifecycle + diag: xs_release_domain / put_domain now
  unlink under dl_mutex then RELEASE it before stop_domain_stored() (whose
  k_thread_join must not run under dl_mutex); mem-mgmt.c err_out uses `*mapped_addr`
  (was passing the stack `void**` to region_space_remove → removed arbitrary Dom0
  pages from the physmap on the error path); xen_cmds.c `xu xsring <domid>` ring/
  server-state diag command + `unref_domain()` (drops a borrowed ref under dl_mutex,
  never a raw refcount--).

### Status
The series build-reproduces the pinned working trees (the four patched repos -
zephyr, zephyr-dom0-xt, zephyr-xenlib, zephyr-xrun; `fatfs` is the fifth workspace
project but carries no patch). **Verified on real
hardware:** the xenstore-server wedge fix holds — `xl create` runs
both guests to completion, `xl list` stays responsive, and both HDMI screens render
live under sustained load (`dmesg | grep -c 'xenbus: error'` = 0, no OOM). `xl
destroy` + re-create of DomA carries the documented vhost-domid caveat (board
restart required; see the top-level README Known issues). 0014-0017 are final.

## 0016: toolstack destroy-ownership guards
Found while reviewing the xen-dom-mgmt.c toolstack
lifecycle path (introduce/release/destroy). Two root causes:
- The only DomD/dom0less destroy guard was `__ASSERT(!f_dom0less)`, which is
  compiled out in the shipped build (`CONFIG_ASSERT=n`) — so `xu destroy 1`
  reached `xen_domctl_destroydomain()` and tore down the control domain
  (GPU/HDMI/SD owner); and a toolstack-introduced DomU had no marker
  distinguishing it from a Zephyr-created one, so `xu destroy <DomU>` (or a
  put_domain/xs_release_domain race) double-destroyed a domain DomD owns.

Fix (does NOT touch the automatic demo path — XS_INTRODUCE→xs_introduce_domain,
XS_RELEASE→xs_release_domain — only the manual `xu` shell/lifecycle paths):
- **domain.h**: add `f_toolstack:1` to `struct xen_domain`.
- **xs_introduce_domain**: set `f_toolstack = true` (DomD owns the hyp domain).
- **put_domain**: replace the compiled-out `__ASSERT(!f_dom0less)` with a
  runtime guard — for a dom0less OR toolstack domain, drop the borrow only
  (decrement under dl_mutex), never teardown/free/destroy. Only a Zephyr-created
  domain reaches the teardown+xen_domctl_destroydomain path.
- **domain_destroy** (`xu destroy`): refuse f_dom0less || f_toolstack domains
  (drop the get_domain borrow via unref_domain, return -EPERM) — closes the
  DomD-destroy footgun, the toolstack double-destroy, and the double-put vs
  xs_release_domain use-after-free race in one guard.

Residual (documented, low-priority, needs HW-validated refactor): a borrow drop
(`xu pause/console/xsring`) that races an XS_RELEASE whose teardown was deferred
can leave a toolstack domain linked at refcount 0 (a SAFE leak — no UAF, no wrong
destroy). A proper fix is a `f_dying` flag so the last borrow-dropper reaps; left
for a future HW-verified change.

## 0017: guard `xu console` against unmanaged (toolstack-introduced) domains
`xu console <domid>` on a toolstack-introduced guest (a DomU/DomA created by the
DomD `xl` toolstack) crashed the whole Zephyr Dom0 (NULL/unmapped-ring
dereference → CPU exception → "Halting system"). Such a guest is tracked in
`domain_list` via `xs_introduce()`, but its console ring is never mapped by this
Dom0: `xen_init_domain_console()` runs only in the Dom0-driven `domain_create()`
path, so `domain->console.intf` stays NULL (the domain struct is memset to 0).
`xen_attach_domain_console()` only checked `!domain` and `f_dom0less`, not the
console-init state, so it armed the shell bypass and the display thread then
dereferenced the unmapped ring.

Fix (`xen-console-srv/src/xen_console.c`): after taking `&domain->console`,
refuse the attach when `console->intf` is NULL (`shell_error` + return `-ENODEV`)
and point the operator at the owning toolstack (`xl console` on the driver
domain). A Dom0-created domain has `intf` mapped (non-NULL), so a valid attach is
unaffected. Also drop the `get_domain()` borrow (`put_domain`) on the
`f_dom0less` early return, which previously leaked it.

## 0018: zero the createdomain hypercall argument
`xen_domctl_createdomain()` in `zephyr/drivers/xen/dom0/domctl.c` was the only
one of the twenty `xen_domctl_t` locals in that file declared without an
initialiser, and it is the one where that matters: the struct ends in
`xen_arch_domainconfig`, which this tree vendors 4 bytes shorter than Xen 4.21's
(see the ABI section above), so Xen read the trailing `arm_sci_type` byte from
uninitialised stack. Harmless as this series is configured -- Xen's
`sci_domain_sanitise_config()` returns 0 while no SCI mediator is registered, and
none is unless `CONFIG_SCMI_SMC` is selected -- but a sporadic
`createdomain` failure as soon as one is. 0018 zeroes the argument and, while
there, replaces the three commas that terminated the following assignments with
semicolons.

## Expected build warnings

**None as of Zephyr 4.4.1.** The build is warning-clean.

> **Historical (3.6.0).** A benign `No SOURCES given to Zephyr library:
> drivers__disk` CMake warning used to be expected: `FAT_FILESYSTEM_ELM` selects
> `DISK_ACCESS` which selects `DISK_DRIVERS`, so `drivers/disk` was configured in
> while `CONFIG_DISK_DRIVER_SDMMC=n` left it without sources. On 4.4.1 that
> assignment is gone (0008) and 0028 adds the inert `ramdisk0` node, so
> `CONFIG_DISK_DRIVER_RAM=y` gives the library a source file and the warning does
> not occur.
