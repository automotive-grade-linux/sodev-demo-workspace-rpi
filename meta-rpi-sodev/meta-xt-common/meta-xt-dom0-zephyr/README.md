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
every symbol the SoDeV guests reference. Applying 0001 alone, or 0004 without
0002/0003, will not build.

> **Verification basis.** The series applies cleanly to clean checkouts of the
> pinned revisions of all four repositories and builds; that is the claim made
> below. No build-artifact checksums are quoted, because they are not reproducible
> from this tree alone (they depend on the toolchain and on the west workspace
> state at the time of the build).

| # | Target repo (west) | Pinned rev | File(s) | What |
|---|---|---|---|---|
| 0001 | `xen-troops/zephyr` (fork) | `f12d445f79` | `include/zephyr/xen/public/domctl.h` | Add the `altp2m` field (`struct { uint16_t opts; uint16_t nr; }`) to `xen_domctl_createdomain` to match the **Xen 4.21 (interface 0x17) ABI**. Load-bearing — see below. |
| 0002 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `Kconfig`, `boards/rpi_5.conf` | Add the `DOM_CFG_SODEV` symbol (gates the SoDeV guests) and the `DOM_CFG_AAOS_DOMAIN` symbol (the upstream single-AAOS example). Neither exists at the pinned rev. Also flips `CONFIG_DOM_STORAGE_FATFS_DIR` to `""` in `rpi_5.conf` (p1 FAT-root guest image lookup; see §Guest image staging). |
| 0003 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/dom0.{c,h}`, `src/storage.c` | Add the xenlib **optional-initrd** storage callbacks (`storage_image_initrd_read`/`_get_size`), the `image_initrd_path` field on `dom0_domain_cfg`, and the `dom0.c` wiring that points `initrd_info` at the config when a path is set. `rpi_5_sodev_doma` depends on these. |
| 0004 | `xen-troops/zephyr-dom0-xt` | `rpi5-v0.4.0` (`03b9614`) | `src/dom_cfg/rpi_5.c` | Add `rpi_5_sodev_domu` (1 GiB AGL cluster) and `rpi_5_sodev_doma` (4 GiB AAOS) dom_cfg + `domain_cfgs[]` registration, gated on `CONFIG_DOM_CFG_SODEV`. Also carries the `domu_cfg_4` AAOS example (gated `CONFIG_DOM_CFG_AAOS_DOMAIN`, off by default). |
| 0005 | `xen-troops/zephyr-xenlib` | `4957058` | `xen-dom-mgmt/include/domain.h`, `.../include/xen-dom-fdt.h`, `.../src/xen-dom-fdt.c`, `.../src/xen-dom-mgmt.c` | Optional-initrd loading in xenlib: the `initrd_info` field + `load_initrd_bytes`/`get_initrd_size` callbacks on `struct xen_domain_cfg`, the `linux,initrd-start/end` chosen-FDT props, and the physmap initrd load. `rpi_5_sodev_doma`'s Android layered ramdisk needs these. **Without 0005 the build fails: `struct xen_domain_cfg has no member named initrd_info`.** |
| 0006 | `xen-troops/zephyr-xenlib` | `4957058` | `Kconfig`, `xenstore-srv/include/xenstore_srv.h`, `xenstore-srv/src/xenstore_srv.c` | `CONFIG_XENSTORE_TOOLSTACK_DOMID` + `xss_set_toolstack_domid`: grant the dom0less DomD Dom0-equivalent xenstore privilege so it can serve the guests' virtio backends. Concretely, this is what lets DomD seed the `device-model/<domid>` xenstore nodes the qemu backends and `xl devd` read; without it those writes are refused as unprivileged. Not needed to compile, but required for the DomD device-model data plane at runtime. |
| 0007 | `xen-troops/zephyr-xenlib` | `4957058` | `xenstore-srv/src/xenstore_srv.c`, `xen-dom-mgmt/src/xen-dom-mgmt.c` | DomD-as-toolstack xenstore: `XS_INTRODUCE`/`XS_RELEASE` handlers + `@introduceDomain`/`@releaseDomain` watches, so an external privileged domain (dom0less DomD) can create/destroy guests via `xl` against the thin Zephyr Dom0 xenstore server. |
| 0008 | `xen-troops/zephyr-dom0-xt` | `03b9614` | `boards/.../rpi_5.overlay`, `src/dom0.h` | RPi5 board: HW-verified Dom0 bring-up + DomD-owns-SD (SoC SDHCI passed through to DomD; the Zephyr FATFS/xu-create path is unused and `dom0less_init` runs normally). |
| 0009 | `xen-troops/zephyr-xrun` | `5b6ecf2` | `src/storage.c` | Compile without `CONFIG_SDHC` (the SD is passed through to DomD, so xrun's SDHC path is dead on this board). |
| 0010 | `xen-troops/zephyr` (fork) | `f12d445f79` | `arch/arm64/core/xen/...` | Bump the sysctl interface version to `0x16` to match the Xen 4.21 ABI used by the Zephyr Dom0 domain manager. |
| 0011 | `xen-troops/zephyr-dom0-xt` | `03b9614` | `Kconfig`, `src/dom_cfg/...` | DomA built-in ramdisk slot (AAOS vendor_boot ramdisk). |
| 0012 | `xen-troops/zephyr-xenlib` | `4957058` | `xen-dom-mgmt/src/xen-dom-mgmt.c` | `xs-introduce` no-clobber: `XS_INTRODUCE` must not overwrite an externally-created domain's existing xenstore node/state. |
| 0013 | `xen-troops/zephyr` (fork) | `f12d445f79` | `drivers/xen/regions.c` | Null-initialize the region pointer to avoid using an uninitialized value. |
| 0014 | `xen-troops/zephyr-xenlib` | `4957058` | `xenstore-srv/src/xenstore_srv.c` | xenstore-server reply-path hardening against ring-wedge conditions (+ "ring corrupt" diagnostics). |
| 0015 | `xen-troops/zephyr-xenlib` | `4957058` | `xen-dom-mgmt/src/...` | Toolstack-domain teardown + `xu xsring` diagnostics (HW debug; see note below). |
| 0016 | `xen-troops/zephyr-xenlib` | `4957058` | `xen-dom-mgmt/include+src` | Guard the domain-destroy paths by toolstack ownership (`f_toolstack`). |
| 0017 | `xen-troops/zephyr-xenlib` | `4957058` | `xen-console-srv/src` | Guard `xu console` against toolstack-introduced domains whose console ring Dom0 never mapped (was crashing Dom0). |
| 0018 | `xen-troops/zephyr` (fork) | `f12d445f79` | `drivers/xen/dom0/domctl.c` | Zero the `createdomain` hypercall argument, so Xen does not read the `arm_sci_type` byte this tree's shorter `xen_arch_domainconfig` leaves uninitialised. |

**Gating is self-enabling.** `rpi5-sodev.yaml`'s zephyr `dom0` builder passes
`CONFIG_DOM_CFG_SODEV=y` (alongside `CONFIG_XEN_DOMCTL_INTERFACE_VERSION=0x17`),
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


## Why 0001 is load-bearing (rc=-3 root cause)

The vendored `zephyr` header predates Xen 4.20's `altp2m` addition to
`xen_domctl_createdomain`. Without those 4 bytes the following `arch` sub-struct
shifts 4 bytes early, so `arch.gic_version` (GIC_V3 = 2) is read by Xen 4.21 as
`cpupool_id`. `cpupool_find_by_id(2)` returns NULL → `sched_init_domain` fails
with `-ESRCH`, surfacing as `xu create ... rc=-3`. Adding the field makes
`cpupool_id` read 0 again. **Verified**: instrumented Xen 4.21 in QEMU shows
`>sched cpupool_id=0` → `domain:1 created` after the fix (was rc=-3).

## Apply

```sh
# ZEPHYR_WS = the west workspace root (contains zephyr/, zephyr-dom0-xt/, .west/)
./apply-zephyr-patches.sh /path/to/zephyr-workspace
```

Each patch is a `git diff` against its repo's pinned rev, so it applies cleanly
to a fresh `west update` checkout (`git apply`). The script is idempotent by
construction: each run first resets every target repo's working tree
(`git checkout -- .`) back to the pinned rev and then re-applies the whole
series, and it prints the failing hunks with a fix hint if the checkout has
drifted from the pinned rev.

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
storage path (SD p1) at `DISK_BIN_PATH` = `/1:/` + `CONFIG_DOM_STORAGE_FATFS_DIR`:

| dom_cfg | `image_kernel_path` | `image_initrd_path` |
|---|---|---|
| `rpi_5_sodev_domu` | `linux-domu` | — (initramfs-bundled) |
| `rpi_5_sodev_doma` | `aaos-android-kernel` | `aaos-vendor-boot-ramdisk` |

The existing image wires those files to the **p1 FAT root** (`linux-domu` via
the `ENABLE_DOMU=yes` variant; `aaos-android-kernel` / `aaos-vendor-boot-ramdisk`
in the base boot items). The board default `CONFIG_DOM_STORAGE_FATFS_DIR="dom0/"`
would make `xu` look in `/1:/dom0/` and miss them, so patch 0002 sets
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
nested GPT). Verified end-to-end from a clean checkout for **both** `--dom0=zephyr`
and `--dom0=linux` . `linux-domu` comes from the separate `build-domu`.

## Verification status (hardware + build)

- **Real build (docker sodev-builder, board `rpi_5`)**: a fresh `west update` +
  `apply-zephyr-patches.sh` + `west build` produces **zephyr.bin (2.8 MiB)** with
  `rpi_5_sodev_domu` + `rpi_5_sodev_doma` linked into the ELF, and `.config`
  showing `CONFIG_DOM_CFG_SODEV=y`, `CONFIG_DOM_CFG_AAOS_DOMAIN` unset
  (decoupled), `CONFIG_DOM_STORAGE_FATFS_DIR=""`,
  `CONFIG_XEN_DOMCTL_INTERFACE_VERSION=0x17`. VERIFIED. **This is the end-to-end
  proof that the vendored set (0001-0006) compiles the hybrid Dom0 from a clean
  checkout.**
- Patch set applies cleanly to a fresh checkout (`git apply --check` PASS for
  0002-0006; 0001 vs the zephyr fork rev), and every symbol the SoDeV `dom_cfg`
  references resolves. VERIFIED.
- 0001: rc=-3 → `domain:1 created` on real Xen 4.21 (QEMU). VERIFIED.
- 0004: clean compile on the `rpi_5` board; 1 GiB DomU
  `xu create` reaches `domain:1 created` (an earlier configuration halted in the
  1 GiB region map; that does
  not reproduce). VERIFIED. (build tree had `CONFIG_DOM_CFG_AAOS_DOMAIN=y`; with the
  self-enabling `CONFIG_DOM_CFG_SODEV=y` var the SoDeV guests are now compiled in
  regardless of the AAOS flag.)
- **Confirmed on RPi5 hardware:** DomD-as-device-model (`xl devd`
  ioreq) creates both guests; **full guest boot verified** — AGL cluster on
  HDMI-A-1 + AAOS on HDMI-A-2, both live and touch-capable; guest kernel/ramdisk
  p1 staging and DomA layered-ramdisk/bootconfig placement all validated on HW.
  The complete 4-domain `full.img` also builds from a clean checkout for both
  Dom0 flavours .

## 0010-0012: HW-proven fixes from the real-HW bring-up 
- **0010 (zephyr)** — widen `CONFIG_XEN_SYSCTL_INTERFACE_VERSION` Kconfig range
  to 0x15-0x16. Xen 4.21 requires 0x16; at 0x15 every sysctl fails the version
  check, so `xu list` / `xstat physinfo` silently print nothing.
- **0011 (zephyr-dom0-xt)** — DomA (AAOS) builtin-ramdisk incbin slot
  (`CONFIG_DOM_CFG_DOMA_RAMDISK_BIN_FILE`). The stock builtin mechanism embeds
  only kernel+DTB; AAOS boots kernel + a layered ramdisk. Inert when unset.
- **0012 (zephyr-xenlib)** — do not call `xs_initialize_xenstore()` from
  `xs_introduce_domain()`: for a toolstack-created guest libxl has already
  built the per-domain xenstore tree and the Zephyr defaults clobber it
  (HW-observed as shadow names "DomU-2"/"DomU-3" and broken device wiring).
  `dom0less_init_domain` keeps calling it (no pre-built tree in that path).

### ABI settings applied by the patch series (no manual `west build` flags)

The stock `rpi_5.conf` board file targets the xen-troops **4.19 fork ABI**; on our
Xen 4.21 four Kconfig values must differ. **These are now carried by the patches —
no manual `west build -D...` overrides are required** (they were, before 0008/0010
baked them in):

| Kconfig | value on Xen 4.21 | applied by |
|---|---|---|
| `CONFIG_XEN_DOMCTL_INTERFACE_VERSION` | `0x17` | 0008 (`boards/rpi_5.conf`) |
| `CONFIG_XEN_SYSCTL_INTERFACE_VERSION` | `0x16` | 0010 (Kconfig default + range 0x15-0x16) |
| `CONFIG_XEN_DOMCTL_XENTROOPS_ARCH_SCI_TYPE` | `n` | 0008 (`boards/rpi_5.conf`) |
| `CONFIG_XEN_DOMCTL_XENTROOPS_ARCH_VGSX_OSID` | `n` | 0008 (`boards/rpi_5.conf`) |

The two XENTROOPS options (the stock `rpi_5.conf` shipped them =y; **0008 now sets
them =n**) insert fork-specific fields into the middle of
`struct xen_arch_domainconfig`: a u16 `arm_sci_type` between `tee_type` and
`nr_spis`, and a u8 `vgsx_osid` between `nr_spis` and `clock_frequency`. That
takes the vendored struct from 12 to 20 bytes and `xen_domctl_getdomaininfo`
from 120 to 128.

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
Applying the full series (0001-0018) to clean checkouts of the pinned revisions
reproduces the pinned working trees for all four repositories (zephyr,
zephyr-dom0-xt, zephyr-xenlib, zephyr-xrun) and builds.

## 0013-0015: xenstore-server wedge fixes + reply-guarantee hardening 
Root-caused on real HW: the DomD→Zephyr xenstore connection wedged after guest
creation (manifesting as "DomD network intermittent", "xl list hangs", "destroy
hangs" — all one bug). The Linux guest xenbus serializes requests, so any request
that gets no reply / a wrong-req_id reply, or any code that blocks the per-domain
worker under a global mutex, wedges the whole connection. These patches fix that
class end-to-end.

- **0013 (zephyr)** — `regions.c xen_region_get_pages`: initialize `ptr = NULL`.
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
Series 0001-0018 build-reproduces the pinned working trees (all four repos; the
md5 is provenance of the verified build, not a literal target of the current
comment text — see the reproducibility note at the top). **Verified on real
hardware:** the xenstore-server wedge fix holds — `xl create` runs
both guests to completion, `xl list` stays responsive, and both HDMI screens render
live under sustained load (`dmesg | grep -c 'xenbus: error'` = 0, no OOM). `xl
destroy` + re-create of DomA carries the documented vhost-domid caveat (board
restart required; see the top-level README Known issues). 0013-0017 are final.

## 0016: toolstack destroy-ownership guards 
Found while reviewing the xen-dom-mgmt.c toolstack
lifecycle path (introduce/release/destroy). Four defects, two root causes:
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
One CMake warning is expected and benign:

```
CMake Warning at .../zephyr/CMakeLists.txt:864 (message):
  No SOURCES given to Zephyr library: drivers__disk
  Excluding target from build.
```

It follows from `CONFIG_DISK_DRIVER_SDMMC=n` in 0008. The stock `rpi_5.conf`
enables FATFS, `FAT_FILESYSTEM_ELM` does `select DISK_ACCESS`, and `DISK_ACCESS`
does `select DISK_DRIVERS`, so `drivers/disk` is still configured in — but with
the SD-card driver off and no other disk backend enabled it has no sources, and
CMake drops the empty library. Nothing is lost: DomD owns the SD controller and
`CONFIG_DOM_STORAGE_FATFS_DIR=""` already disables the storage path.

Setting `CONFIG_DISK_ACCESS=n` does **not** silence it — Kconfig `select` is
unconditional, so FATFS forces it back on and the assignment is dropped with a
Kconfig warning of its own. Silencing it properly means turning FATFS off in this
board's config, which would need `zephyr-dom0-xt`'s storage code to compile
without the fs API. Not worth a patch for a message with no effect on the image.

Series is 0001-0018; clean checkouts + patches == working trees (4 repos).
