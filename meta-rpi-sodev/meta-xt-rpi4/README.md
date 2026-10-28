# meta-xt-rpi4 — Raspberry Pi 4 (BCM2711) board layer

The Raspberry Pi 4 sibling of `meta-xt-rpi5`. It carries everything that is specific to
BCM2711 for the SoDeV disaggregated cockpit: the DomD partial device tree, the Xen host
overlay, the passthrough overlays, the U-Boot boot scripts for both Dom0 flavours, the
TF-A and U-Boot configuration, and the kernel fragment for the on-SoC devices that
replace RP1 on this board.

**The two board layers are mutually exclusive.** They provide the same recipe names
(`xt-rpi-u-boot-scr`, `domd-vc4`, the `rpi5-image-*` wrappers), so exactly one of them
belongs in a build: `rpi4-sodev.yaml` lists this layer where `rpi5-sodev.yaml` lists
`meta-xt-rpi5`. `./build.sh --board=rpi4` selects the yaml.

Every address, size and interrupt number here is measured from the shipped
`bcm2711-rpi-4-b.dtb` and recorded in **`BCM2711-DT-TRUTH.md`**. Read that file before
changing any of them; it is the only justification for the values in the DTS, the boot
scripts, `xen,reg` and `domd.cfg`'s `iomem`.

## What is verified, and where

| | status |
|---|---|
| Build, both Dom0 flavours | `--board=rpi4 --dom0=linux` and `--dom0=zephyr` complete and assemble a `full.img`. |
| Hardware, 4 GiB SKU | Booted in the environment this port came from (2026-08-07): Dom0 (Zephyr) + dom0less DomD + DomA. AAOS reaches `sys.boot_completed=1`, CarLauncher is on the panel, touch input reaches the guest, `adb` connects over tcp/5555, `xl console DomA` receives. Idle load 5.6 % CPU / 0 % GPU render; under continuous swiping DomD 67 % + DomA 78 % of one core and 40.7 % GPU render. 158 MiB of Xen free memory left. All of this with the map of the time: DomD 1024 MiB, DomA 2560 MiB. |
| Hardware, 4 GiB SKU, this map | Booted 2026-09-23 in the Venus lane with the Zephyr Dom0: DomD 1440 MiB, DomA 2048 MiB on 2 vCPUs (pcpu 2-3). `xl info` read 262 MiB of Xen free memory; DomD reserved its 336 MiB CMA at 0x0b000000, and 1080p60 with 13 CAPTURE buffers left CmaFree >= 196 MB. The gl lane's DomD 1056 / DomA 2560 has not been booted. |
| Hardware, 8 GiB SKU | Not measured. The 8 GiB domain map is the one the boot scripts default to, but the four-domain configuration has only been reasoned about, not booted. |

## Board SKUs

`--ram=8g` (default) or `--ram=4g`; the value reaches the boot script as
`setenv board_ram` and the script branches on it with `fdt set /chosen/domD
memory|xen,static-mem`, so the whole delta is two lines per script rather than a second
overlay.

* **8g** — Dom0 128 MiB (zephyr, the default) or 256 MiB (linux) of `dom0_mem`,
  with bank[0] measured at `0x20000000` on the 4 GiB board and the low map the
  same here + DomD 1920 MiB (three static-mem banks: 384 MiB + 1 GiB + 512 MiB) +
  DomU 1024 MiB + DomA 2560 MiB. **This is the
  default, and it is the one SKU that has not been booted** — the board available to this
  port is a 4 GiB one. The map is derived from the same rules as the 4g map and builds
  cleanly, but if you have an 8 GiB board, treat the first boot as unverified and capture
  `(XEN) RAM:` / `(XEN) BANK[0]` from the log: the 8 GiB usable total is currently
  extrapolated, not measured.
* **4g** — DomD 1056 MiB (bank2 dropped, bank0 down to 640 MiB, bank1 moved down to
  0x06000000 + 416 MiB so DomD's CMA can be 336 MiB). DomU and DomA each fit
  alone; **they cannot run at the same time**, so `build.sh` REFUSES `-u` together with
  `-a` on this SKU and names the three ways out (drop one guest, or `--ram=8g`). It
  also refuses `-z`: DomZ is not part of this SKU's configuration. A
  DomU-less DomA image is a first-class configuration: `ENABLE_DOMU_RESERVED` puts an
  empty 8 MiB partition where DomU's rootfs would be, so the DomA nested GPT still lands
  on p4, which is the partition `doma.cfg` opens.

  **The Vulkan lane redistributes this SKU**, because a host-visible blob window is
  device-model memory in DomD and none of it is reclaimable. With `--gpu=vulkan` (the
  default), 384 MiB moves from DomA to DomD: **DomD 1440 MiB (bank0 1024 MiB) and DomA
  2048 MiB**. DomA gives up 128 MiB more than DomD takes, so that its RAM stays in one
  memory zone -- at 2176 the 82 MB ZONE_NORMAL made AOSP's `extra_free_kbytes.sh` write a
  `watermark_scale_factor` of 615-1777 and kswapd saturated both domains (see
  `xt-xen-cfg-doma_%.bbappend`; the script's two defects are fixed since, in an
  AOSP source build, by `meta-xt-doma`'s `aosp-patches/system/core` 0001 and 0002).
  The direction follows from the asymmetry -- if DomD runs out, weston loses DRM master and
  both guests' device models die with it, whereas AAOS at 2048 is the size upstream
  gives it. Sized at three times the 128 MiB `hostmem` of the time (the hard ceiling on
  what the device model can pin) rather than to the ~76-106 MiB estimate: the estimate's
  biggest term is the one nobody has measured, and the board verification then showed the
  device model's own footprint under full-Vulkan AAOS needing the rest -- DomD's
  MemAvailable bottomed at ~460 MiB with 1408. `hostmem` is 256 MiB now; with a video
  playing in a WebView and 126 MiB of the window in use, DomD kept ~505 MiB available
  (2026-09-24). The 8 GiB SKU is untouched: DomD has 1920 MiB there and the delta is
  noise. Both halves read the lane through the same two-valued
  `VENUS_LANE` variable -- `xt-rpi-u-boot-scr.bbappend` substitutes it into the boot
  script, `xt-xen-cfg-doma`'s bbappend tests it in `DOMA_MEM_MiB` -- and
  `tools/check-rpi4-memory-map.py` re-derives both lanes from those two files so the
  numbers cannot drift apart (it fails if DomA gives up less than DomD gains or if the
  condition is ever inverted).

  `--gpu=vulkan` selects qemu 11.1.2, which version-gates off the six 7.0.0-only
  device-model patches. `0111` (virtio-tablet `BTN_TOUCH`) is among them, and Android
  classifies an ABS_X/ABS_Y device as a touchscreen only when it also reports `BTN_TOUCH`;
  that fix is carried for 11.1.2 as `meta-xt-qemu`'s `q11-017` (for the selectable
  10.0.2-xt as `0118`), so the Vulkan lane keeps the touch this SKU's hardware run
  verified. `0110` is carried too (`q11-019`; `0120` for 10.0.2), `0101`/`0103` are
  forward-ported as `q11-021` (`0201` for 10.0.2), and `0112` and `0113` do not apply
  -- the per-patch evidence against 10.0.2 is in `meta-xt-driver-domain`'s
  `qemu_%.bbappend`. `--gpu=gl` rebuilds the 7.0.0-xt device model with all six.
  See `docs/VULKAN-VENUS.md`.

## Where BCM2711 forced a different design

* **DMA reach decides domain layout.** `/soc` has `dma-ranges` limited to the low
  1 GB, so the VideoCore mailbox and the HVS must live in the same domain as the CMA
  pool — DomD. `/emmc2bus` looks limited in `bcm2711-rpi-4-b.dtb` but the firmware
  rewrites it to identity over the usable 3.94 GB, so the SD controller is NOT
  restricted (it stays in DomD because DomD owns the rootfs, not because of DMA).
  GENET, V3D and PCIe are not restricted either. See §1 of `BCM2711-DT-TRUTH.md`.
* **`#size-cells = <1>` at the root**, including `/reserved-memory`. Nothing here may
  rewrite that node with 2/2 cells: Linux's `__reserved_mem_check_root` would discard
  the entire node, TF-A's `atf@0` entry included.
* **One display L2 interrupt controller** (`@7ef00100`, GIC SPI 96), **LEVEL_HIGH** like
  every other peripheral SPI on this SoC. ⚠ The `bcm2711-rpi-4-b.dtb` that
  raspberrypi/firmware distributes still says EDGE_RISING for it; that value is stale
  (pre-`rpi-6.1.y`) and following it panicked DomD on hardware. See §4 of
  `BCM2711-DT-TRUTH.md`. Note that the libxl `irqs=[...]` path carries no type
  information at all, which is called out where it matters.
* **No RP1.** The devices RP1 provided on RPi5 are on-SoC here (GENET, dwc2, the VL805
  xHCI behind the PCIe root complex, gpio/spi/i2c), which is why this layer adds a
  `can-passthrough.dtso` and its own `00-genet-eth0.link` that `meta-xt-rpi5` has no
  counterpart for.
* **No SCMI, no MIP, no IOMMU.** Clocks and power come from the VideoCore firmware
  mailbox; PCIe MSI is inside the root complex. The SCMI overlays, the SCMI Kconfig
  fragment and the MIP MSI Xen patch are absent rather than remapped.
* **Xen's console is the mini UART** (`/soc/serial@7e215040`), because the pl011 goes
  to Bluetooth. `4.22-0014` (rpi4 only) makes Xen leave its divisor as the boot loader
  programmed it: the automatic baud read returned 0 on some boots, the 16550 fallback
  then wrote divisor 1 (~31 Mbaud on this UART) and the console was garbage from the
  first line.
* **`pixelvalve2` and `pixelvalve4` are the CRTCs** (HDMI0 and HDMI1), per
  `vc4_crtc.c`'s `bcm2711_pv2_data` / `bcm2711_pv4_data` — not pixelvalve0/1 as on
  BCM2712. `pixelvalve1` shares SPI 110 with pixelvalve4 and is deliberately left with
  the hardware domain.

## Upstream settings that only apply to this MACHINE, and are cancelled

Setting `MACHINE = "raspberrypi4-64"` pulls in meta-virtualization's
`dynamic-layers/raspberrypi/conf/distro/include/xen-raspberrypi4-64.inc`, a file that
does not exist for RPi5. `rpi4-sodev.yaml` overrides three of its settings with strong
assignments in both the dom0 and domd components:

| upstream | symptom | override |
|---|---|---|
| `PREFERRED_PROVIDER_virtual/kernel ?= "linux-yocto"` | the `?=` lands at parse time and beats meta-raspberrypi's weak `??= "linux-raspberrypi"` -> `ERROR: Nothing PROVIDES 'virtual/kernel'` | `= "linux-raspberrypi"` |
| `IMAGE_FSTYPES += rpi-sdimg` / `IMAGE_CLASSES += sdcard_image-rpi` | builds an unused SD image (`do_image_rpi_sdimg[recrdeps] = "do_build"`) | `:remove` on both |
| `PREFERRED_PROVIDER_u-boot-default-script ?= "xen-rpi-u-boot-scr"` | reached via `u-boot_%.bbappend`'s `DEPENDS:append:rpi`, so the upstream boot.scr wins | `= "xt-rpi-u-boot-scr"` |

A fourth RPi4-only override is handled in this layer rather than the yaml:
meta-raspberrypi's `linux-raspberrypi.inc` adds `SRC_URI:append:raspberrypi4 = "
file://rpi4-nvmem.cfg"` and ships that fragment in its own `files/raspberrypi4/`, but
`FILESPATH` is built from the RECIPE's directory and the recipe lives in
`meta-xt-driver-domain`. `recipes-kernel/linux/linux-raspberrypi_6.18.bbappend` puts
exactly that one subdirectory — not meta-raspberrypi's whole `files/` — on
`FILESEXTRAPATHS`; the reasoning for the narrow scope is in the file.

Two changes in the shared layers were also needed, both machine-gated so RPi5 behaviour
is unchanged: `meta-xt-driver-domain`'s `linux-raspberrypi_6.18.bbappend` scopes its
SCMI/WiFi `.dtso` entries to `:raspberrypi5` (they are templated from
`${RPI_SOC_FAMILY}-${MACHINE}` and would make `do_fetch` look for files that do not
exist on this board), and `xt-xen-cfg-doma` gained a `DOMA_MEM_MiB` override so a board
whose SKUs are not 16g/8g can state DomA's size directly.

## The AAOS guest is compiled for this board too

A virtio guest still executes on the host's cores, so DomA's userspace has to be built
for the host ISA — and this is the one place where "DomA is board-independent" is wrong.

`device/google/trout/trout_arm64/BoardConfig.mk` resolves to
`TARGET_CPU_VARIANT := cortex-a53`, and LLVM's cortex-a53 feature set implies the ARMv8
crypto extensions. A Cortex-A76 has them; the Cortex-A72 does not
(`Features : fp asimd evtstrm crc32 cpuid`). BoringSSL folds its capability check at
compile time when the compiler says the extensions are present, so on this board `/init`
reaches `sha256su0` and dies with SIGILL before first-stage mount — with nothing in the
build to warn about it.

The fix is an ADDED AOSP product variant, not a patch to the upstream device, and it
lives in a repository of its own rather than in this layer:

```
automotive-grade-linux/Android_device_sodev_xenvm-cf  ->  device/sodev/xenvm-cf
  AndroidProducts.mk                       aosp_xenvm_trout_rpi4_arm64
  aosp_xenvm_trout_rpi4_arm64.mk           inherits the upstream product, new identity
  xenvm_trout_rpi4_arm64/BoardConfig.mk    includes the upstream board config, then
                                           TARGET_CPU_VARIANT := cortex-a72
  init.xenvm-buried-eth0.rc                the minradio interface fix the product
  overlay/…/SettingsProvider/…/defaults.xml  installs
```

The AOSP manifest names it with `groups="notdefault,rpi4"`, so only a checkout that asks
for the group fetches it: `XT_DOMA_SOURCE_GROUP: "default,rpi4"` in `rpi4-sodev.yaml`
makes `repo init` do that (repo *replaces* the group set, so `default` has to be named
too). Measured on the pinned revision: 1087 projects with the group, 1086 without, the
device being the difference — a Pi 5 or a V4H checkout is unaffected.

The DomA features also have a device half, in that repository. Until the
manifest pins a revision of it that contains them, each rpi4 commit here that
changes the device carries the repository's matching commit as
`meta-xt-common/meta-xt-doma/aosp-patches/device/sodev/xenvm-cf/000N-*.patch`,
numbered in order, and `apply-aosp-patches.sh` applies the series after the AOSP
fetch; the Pi 5 checkout has no such project and skips it.

`meta-xt-common/meta-xt-doma/stage-aosp-device.sh` no longer copies anything for this
board; `build.sh` still runs it between `ninja fetch-doma` and `ninja doma`, where it
checks that the project, its board config, `init.xenvm-buried-eth0.rc`, the overlay's
`defaults.xml` and the dialer's `config.xml` are present, that every XML under the
overlay and the device's `media_codecs_c2.xml` and audio policy XML are well formed,
and that `DomaWifiRelay`, `DomaSettingsProviderRRO`, `DomaWifiOverlay` and
`DomaNoSafeAreaRRO` are each defined by exactly one `Android.bp` under `device/`. A forgotten group flag otherwise
surfaces as `lunch` reporting "Can't find a product spec", which points at neither the
manifest nor the flag. Nothing under `device/epam/aosp-xenvm-trout` is modified either
way, so `repo sync` has nothing to reset and the pinned manifest revision can move
without the change rotting.

Two consequences worth knowing:

* The variant has its own `PRODUCT_DEVICE`, so each board gets its own
  `out/target/product/` tree (`xenvm_trout_rpi4_arm64` vs `xenvm_trout_arm64`). With one
  shared device name, switching `--board` in an existing checkout would reuse object files
  compiled for the other CPU and say nothing. AOSP would also refuse two board configs
  claiming one device name ("Multiple board config files for TARGET_DEVICE").
* `aaos-guest-binaries` derives the DomA kernel and ramdisk from that tree, so
  `rpi4-sodev.yaml` passes `AAOS_DEVICE` into the DomD build conf. `build.sh` reads the
  same name out of the yaml rather than carrying a second copy of it.

The Yocto-built DomD host services need no equivalent: meta-raspberrypi's own
`DEFAULTTUNE = "cortexa72-nocrypto"` for raspberrypi4-64 already keeps them A72-safe.

## DomA's display path with the qemu 11.1.2 device model

The vulkan lane selects the qemu 11.1.2 device model (rpi4-sodev.yaml). These act only
with it:

* **`xt-qemu-display-toggles`**, installed in the DomD image on this board, is a
  tmpfiles.d entry that creates the `/run/qemu-*` switches at boot: the ISP direct
  scanout of the decoded video (`media-isp`, `isp-scanout`, `isp-skip-copy`,
  `media-sg-rw`, `fb-invalidate`, and `isp-scanout-depth` at 2 instead of the code's
  4), the SAND buffer on a weston overlay plane without the ISP (`sand-scanout`,
  `sand-skip-isp`), and the guest's planes on weston subsurfaces in the HMI case
  (`plane-handoff`). Only qemu 11.1.2 reads them (`q11-063`, `q11-066`); qemu 10.0.2
  does nothing with them. Removing a file turns its feature off (`isp-scanout-depth`:
  back to 4).
* **`RPI4_DOMA_HOST_SAND`** (`xt-xen-cfg-doma`'s bbappend; `1` by default with qemu
  11, `0` otherwise) adds
  `host-sand=N` to DomA's virtio-media decoder: `0` is the decoder's NV12 output,
  `1` SAND128 detiled by DomD's Mesa, `2` SAND sampled as one linear texture and
  detiled in the shader. `sand-scanout` and `sand-skip-isp` need a value other than
  `0`. Any value but `0`, `1` and `2`, or a value other than `0` with any other device
  model, stops the build, because qemu 10.0.2 has no such property and would not
  start DomA's device model.
* **`XT_DOMA_OVERLAY_PLANES`** `3` and **`XT_DOMA_PLANE_SCALING`** `1` with qemu 11
  (`xt-xen-cfg-doma`'s bbappend): three overlay planes for drm_hwcomposer and the
  scaled primary plane, as on this board's doma.cfg since its display path was
  measured.

## Known limitations and open items

* **emmc2 is NOT behind the low-1 GiB VideoCore alias — the firmware rewrites its
  `dma-ranges`, and a guest DT that carries the value from `bcm2711-rpi-4-b.dtb`
  corrupts every SD DMA transfer.** This cost two days of hardware debugging and is
  the reason `emmc2_bus` in the DomD partial DT is identity-mapped:

  ```
  bcm2711-rpi-4-b.dtb   /emmc2bus  dma-ranges = <0x0 0xc0000000 0x0 0x0 0x40000000>
  running DT (U-Boot)   /emmc2bus  dma-ranges = <0x0 0x0        0x0 0x0 0xfc000000>
  ```

  Read the running value with `fdt print /emmc2bus` at the U-Boot prompt. `/soc`
  (mailbox, HVS) really does keep the alias, which is what made the file's value look
  plausible for emmc2 too. With the alias in the guest DT, DomD adds 0xc0000000 to
  every SD DMA address, so the controller transfers to and from addresses that are not
  the buffers Linux prepared. Nothing reports a bus error; the data simply comes back
  wrong, and the symptom depends on the transfer mode:

  ```
  ADMA (default)                 SDMA (SDHCI_QUIRK_BROKEN_ADMA)      PIO (both masked)
  mmc0: ADMA error: 0x02000000   mmc0: invalid bus width             mounts normally
  mmc0: error -5 ... (forever)   mmc0: error -22 ... (forever)
  mmc0: unrecognised SCR
        structure version 4
  ```

  Both failures are the same corrupted 8-byte SCR read. Reproduced on two cards from
  different vendors (SanDisk 512 GiB `ST512` manfid 0x03, 2026-08-05/08-17; Kioxia
  32 GiB `SE032` manfid 0x02, 2026-08-18), which is what ruled out the media-specific
  reading and the PIO workaround that had been prepared for it. With the identity
  mapping the card comes up at full DDR50 under ADMA with zero errors.

  Two things made this expensive to find, both worth knowing for any similar bug:
  **(1)** DomD's bootargs carry `quiet loglevel=3`, so even `Waiting for root device`
  is invisible and the domain looks like it hung with no output at all — rebuild
  `boot.scr` with `ignore_loglevel` (a bare `loglevel=N` is overridden by the trailing
  `quiet loglevel=3`) and add `earlycon=pl011,0x22000000 keep_bootcon` (DomD's
  vpl011 while Xen's console is the mini UART; 0xfe201000 is the Bluetooth UART
  passed through to DomD), or nothing reaches the console before the pl011
  driver probes. **(2)** `sdhci` prints the
  register dump and the ADMA descriptor table with `SDHCI_DUMP`, which is `pr_debug`,
  and this kernel has `CONFIG_DYNAMIC_DEBUG` off — so `ADMA error: 0x%08x` is all you
  get. The `dma-ranges` mismatch was found by reading the live host DT instead.

  Still unexplained: `sdhci-iproc fe340000.mmc: incomplete constraints, dummy supplies
  not allowed (id=vqmmc2)` at probe. The mmc core asks for `vqmmc`, not `vqmmc2`, and
  the DT supplies both `vqmmc-supply` and `vmmc-supply`. It is harmless in that the
  controller works, but nobody has traced where the `2` comes from.
* **The Pi 4's Cortex-A72 has no ARMv8 Crypto Extensions.** `ID_AA64ISAR0_EL1` reads
  `0x10000` on BCM2711 — CRC32 only, AES/SHA1/SHA2 all zero (Xen prints it as
  `ISA Features: 0000000000010000`). DomA's fscrypt therefore falls back to
  `cts(cbc(ecb(aes-generic)))` and `blk-crypto-fallback`, which is correct, not a missing
  module. The consequence is that the first boot on a freshly written `userdata` is CPU
  bound: dex2oat plus software AES on encrypted `/data` saturates both DomA vCPUs for a
  long time, and it does not log to the kernel ring while it does so. Do not read a quiet
  console with high CPU as a hang. It is also why the AAOS userspace must rely on
  BoringSSL's `OPENSSL_armcap_P` runtime dispatch rather than compile-time crypto.
* **OP-TEE is off.** TF-A's `rpi4` platform has no SPD integration comparable to the
  RPi5 patch, so `TFA_SPD` is empty, there is no `recipes-security/optee` here, the DomD
  node carries no `xen,tee`, and `CONFIG_TEE`/`CONFIG_OPTEE` are out of the hypervisor
  fragment. Re-enabling it means all of those plus a `plat/rpi4` equivalent of the RPi5
  OP-TEE patch and a secure carve-out written with 2/1 cells; the full list is in
  `recipes-bsp/trusted-firmware-a/trusted-firmware-a_git.bb`.
* **VL805 passthrough works; its MSI path has only been exercised by USB HID.**
  BCM2711's MSI controller is inside the PCIe root complex, which is simpler than
  RPi5's MIP, but Xen/ARM has no vPCI, so the configuration depends on 1:1 direct-map
  + RC MMIO + SPI 148. This matters because every USB-A port on a Pi 4 Model B is
  behind VL805 — `/soc/usb@7e980000` (dwc2) serves the USB-C connector only — so VL805
  passthrough is effectively required for the touch panel. Measured on hardware
  2026-08-17: `lspci` in DomD lists `0000:00:00.0` and `0000:01:00.0`, and the panel's
  touch controller enumerates through it as
  `P: Phys=usb-0000:01:00.0-1.4/input0`, `N: Name="wch.cn TouchScreen"`, which weston
  then holds through seatd. A tap injected into that device's evdev node reaches DomA's
  virtio tablet with the coordinates scaled correctly and moves the AAOS foreground
  activity, so the whole path is live. What has *not* been exercised is anything that
  needs sustained bulk transfer or many vectors — this is one low-rate HID endpoint. The
  fallbacks, if a device does turn out to need more, remain a powered USB-C hub or a
  CM4 carrier.
* **`CONFIG_VHOST_XEN=y` is a bundled behaviour change that is NOT YET VERIFIED.**
  Turning `CONFIG_VHOST` on for DomA's vsock pulled it in; before that fragment existed
  the symbol was not set at all on this board, which means the `vhost_xen.nogrant=1` on
  DomD's cmdline was being silently ignored. The details are in
  `recipes-kernel/linux/files/bcm2711-domd-hw.cfg`.
* **A72 headroom for two screens is not measured.** BCM2711's V3D 4.2 is well below
  BCM2712's, and the RPi5 DVFS pair (960/500 MHz) does not apply — `v3d_freq=500` is
  this board's stock maximum. The load figures above are for one screen with DomU
  absent.
* **`domd.cfg` still carries BCM2712 `iomem`/`irqs`.** It is off the boot path (DomD is
  dom0less, `domd.service` is masked, and `xl create` cannot direct-map), and the file
  says so in its header. It has to be regenerated before anyone tries the libxl route on
  this board — which is also where the missing interrupt-type information in
  `irqs=[...]` would bite.
* **DomA's 1280x720 needs a panel whose EDID lists 1280x720@60.** weston
  drives HDMI-A-1 with CEA-861 VIC 4 (74.25 MHz), which the bench panel, an
  Onlap1102I, lists, and the panel scales it up. On a panel that does not
  accept that timing, weston's atomic commits fail and it never presents a
  frame: the failure `recipes-graphics/wayland/weston-init.bbappend` records
  for a computed timing on a fixed-timing panel. Only the Onlap1102I has run
  at this size; for another panel take the modeline from its EDID and give
  DomA the same size in `RPI4_DOMA_GPU_RES`.
* **This board has its own checker: `tools/check-rpi4-memory-map.py`.** The BCM2712
  tool (`tools/check-memory-map.py`) has no rpi4 rows, so the invariants the boot
  scripts and recipes here describe are enforced by the rpi4 tool instead: banks and
  their sum, containment in real DRAM, module load addresses, the two flavours
  agreeing, the Venus override touching only `bank@0x40000000`, and the domain budget
  for both SKUs. Neither tool models Xen's `allocate_memory_11()`, so Dom0's bank[0]
  address remains an observation read off the console.

## Layout

```
BCM2711-DT-TRUTH.md                     measured host DT — the source of every value
conf/layer.conf                         collection xt-rpi4, priority 10
recipes-bsp/bootfiles/                  config.txt: armstub, GIC, UART+BT pins, gpu_mem, v3d_freq
recipes-bsp/trusted-firmware-a/         PLAT=rpi4, target bl31 (bl31.bin is itself the armstub)
recipes-bsp/u-boot/                     CONFIG_BCM2711_64B, NR_DRAM_BANKS=8, >4 GiB mapping
recipes-bsp/xt-rpi-u-boot-scr/          static board-tuned boot.cmd per Dom0 flavour
recipes-connectivity/xen-network/       name the GENET NIC eth0 on DomD
recipes-core/images/                    rpi5-image-{minimal,xt}-domd wrappers (recipe names, not board names)
recipes-extended/rp1-touch-forward/     retarget the touch panel to the attached output
recipes-extended/xen/                   Xen 4.22 series + hypervisor Kconfig + BCM2711 passthrough quirks
recipes-extended/xt-aaos-host-services/ widen COMPATIBLE_MACHINE for the AAOS host services
recipes-extended/xt-qemu-display-toggles/ /run/qemu-* display-path switches for qemu 11.1.2
recipes-extended/xt-rpi5-domain/        per-domain CPU pinning (recipe name shared with meta-xt-common)
recipes-extended/xt-xen-cfg-{doma,domu}/ DomA memory and 1280x720 display, DomU vcpu pinning
recipes-graphics/wayland/               weston output map and the HDMI-A-1 modeline
recipes-guest/domd-vc4/                 DomD partial device tree (the file boot.cmd loads)
recipes-kernel/linux/                   DT set, passthrough overlays, BCM2711 driver fragment
```
