# Troubleshooting

> **Documentation map** — [`README.md`](../README.md) build and run |
> [`docs/BUILD.md`](BUILD.md) build details |
> [`docs/DESIGN.md`](DESIGN.md) why the tree looks like this |
> [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when it does not work

Symptoms seen on real hardware, what caused them, and what to do. Each entry keeps
the log lines it was diagnosed from, so a recurrence can be recognised rather than
re-diagnosed.

If a panel is dark, start with *Late EDID on HDMI-A-2*: the guest cannot detect that
failure and will report a healthy display while nothing reaches the screen.

---

## Late EDID on HDMI-A-2

Measured on hardware, 2026-08-03. weston enumerated HDMI-A-2 with `EDID make 'unknown'`
and enabled the output from the pre-EDID mode list — correctly, at the pinned
`1920x720@93.240`. The panel's EDID then arrived **3.7 s later**, the kernel rebuilt that
connector's mode list (5 modes -> 17), and weston logged

```
DRM: head 'HDMI-A-2' updated, ... EDID make 'PNP(RTD)', model '12.3FHD'
Detected a monitor change on head 'HDMI-A-2', not bothering to do anything about it.
```

after which **every** atomic commit failed — still failing 14 minutes later:

```
atomic: couldn't commit new state: Invalid argument
repaint-flush failed: No such file or directory
```

The panel is dark and **the guest cannot tell**: its virtio-gpu display has no present
fences (`PresentFences=false`, `RUNNING_WITHOUT_SYNC_FRAMEWORK=1`), so AAOS keeps
composing into a framebuffer nobody scans out. Every guest-side check passes —
`sys.boot_completed=1`, the launcher resumed, `adb exec-out screencap -p` returns the
real UI, `am start` changes it — while nothing reaches HDMI. If you are debugging a dark
panel, check `journalctl _COMM=weston` for the commit failures before suspecting the
guest.

Pinning the modeline in `weston.ini` does **not** cover this. Pinning fixes mode
*selection* when the EDID is missing; what breaks here is the mode list changing under an
output that is already enabled. The fix is an `ExecStartPre` that polls the connectors'
`modes` until they stop changing (3 identical samples, 25 s ceiling, always exits 0 so it
can only delay weston). Reading `modes` also forces a connector detect, so it pulls the
EDID in rather than waiting for it. It settles in ~5 s in practice. Waiting for a
*non-empty EDID* would be wrong — HDMI-A-1 has none at all and would burn the full
timeout every boot.

This is intermittent: if the EDID happens to land before weston enumerates, nothing goes
wrong, which is why it was not caught earlier.

## DomD panics in `brcmstb_l2_intc` during boot

Measured on a Raspberry Pi 4, 2026-09-02, after swapping the HDMI display. DomD died
0.53 s into its own boot, before init:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000008
pc : brcmstb_l2_intc_irq_handle+0x40/0x1a0
Call trace:
  brcmstb_l2_intc_irq_handle
  ...
  _raw_spin_unlock_irqrestore                (P)
  irq_set_chained_handler_and_data+0x98/0xe0
  brcmstb_l2_intc_probe.isra.0+0x150/0x298
  platform_irqchip_probe
Kernel panic - not syncing: Oops: Fatal exception in interrupt
```

This is an upstream race, not a configuration problem, and **it is already fixed in this
workspace** by `0013-irqchip-brcmstb-l2-set-up-the-generic-chip-before-ch.patch`
(`meta-xt-common/meta-xt-driver-domain/recipes-kernel/linux/files/`). If the panic shows
up, the DomD kernel in the image predates that patch — rebuild it.

Why it happens: `brcmstb_l2_intc_probe()` installs the chained parent handler before
assigning `data->gc`, and `irq_set_chained_handler_and_data()` unmasks the parent line and
re-sends anything pending on it. A parent that is already asserted therefore runs the
handler from inside that call, where `data->gc` is still NULL. On BCM2711 the display L2
controller (`aon_intr`, `interrupt-controller@7ef00100`, GIC SPI 96) is the SoC's only
edge-triggered GIC line, so its parent latches pending state from the HDMI work the
firmware does before Linux starts — which is why a display swap can surface it while the
software is unchanged. BCM2712 has the same window on `disp_intr` (SPI 97) and `aon_intr`
(SPI 239), so the patch is applied to both boards.

The interrupt type matters too, and it was wrong here until 2026-09-02. The DomD partial
device tree declared `interrupts = <0x0 96 0x1>` (EDGE_RISING) for `aon_intr`, copied from
the `bcm2711-rpi-4-b.dtb` that `raspberrypi/firmware` distributes. **That prebuilt is
stale**: EDGE_RISING is what raspberrypi/linux carried up to `rpi-5.15.y`, while mainline
(since at least v5.19) and every rpi tree from `rpi-6.1.y` onwards — including the 6.18
pinned here — say `IRQ_TYPE_LEVEL_HIGH`. It is now `<0x0 96 0x4>`.

Why the type decides whether the race above is reachable: brcmstb-l2 masks all 32 child
sources and clears their status at the top of its probe, so the controller's output line is
already low when it chains the parent. With a **level** type there is no pending parent and
the probe finishes quietly. With an **edge** type, a rising edge latched earlier — during
the firmware's HDMI/EDID work, before Linux runs — stays pending regardless of the line and
is re-sent the instant the parent is started, which is exactly what walked into the window.
Measured on hardware: switching the partial DT to LEVEL_HIGH stops the panic.

⚠ Open item: the `bcm2711-rpi-4-b.dtb` shipped on p1 is still the firmware prebuilt, so the
**host** DT Xen reads and the **guest** partial DT now disagree for SPI 96. The partial DT
governs what DomD's own probe sees, which is why fixing it was sufficient. Making the host
DT agree means shipping the kernel-built dtb instead of the prebuilt, which has not been
done. See `meta-xt-rpi4/BCM2711-DT-TRUTH.md` §4.

🚨 `0013` must be **deleted** once upstream carries the fix — see the note at the end of
the patch itself and the comment above its `SRC_URI` line in
`linux-raspberrypi_6.18.bbappend`. Check it on every kernel SRCREV bump.

## DomD-side toolstack units are masked in the thin-Linux flavour

`domd-toolstack-prep.service`, `xl-create-domu.service` and `xl-create-doma.service` ship
in the DomD rootfs regardless of flavour, but in the thin-Linux flavour Dom0 owns the
toolstack: it runs `xenstored`, attaches the guest disks (`xl-attach-disks.service`, SD
p2 → `xvda` / p3 → `xvdb` / p4 → `xvdc`) and creates DomU/DomA itself. The DomD copies
are therefore masked to `/dev/null` by `rpi5-image-xt-domd-vc4.bb` when
`DOM0_OS != zephyr`.

Masked rather than stubbed, deliberately. Measured on hardware 2026-08-03 before the
mask existed: `domd-toolstack-prep` tried to seed a Zephyr xenstore that does not exist
in this flavour, failed, was restarted five times and gave up, filling the Xen console
with `(XEN) DOM1: [FAILED] Failed to start DomD toolstack preparation for the Zephyr-Dom0
topology` and `[DEPEND] Dependency failed for Launch DomU/DomA`. Those DEPEND failures
were the *only* thing keeping DomD's own `xl-create-*` from running — merely satisfying
the requirement with a no-op stub (which is what `meta-xt-dom0-linux` ships into the
**Dom0** rootfs, for a different reason) would let DomD race Dom0 to create the same
domains. A masked unit neither fails nor runs. After the mask, DomD reports **0 failed
units** on both SKUs.

> **Verification status.** All four `DOM0_OS` x `BOARD_RAM` combinations were brought up
> end-to-end on a real RPi5 (16 GB board) on 2026-08-03 — two-screen cockpit, four
> domains, `sys.boot_completed=1` in DomA, DomU and DomD reachable, zero failed systemd
> units in DomD:
>
> | | `--ram=16g` | `--ram=8g` |
> |---|---|---|
> | `--dom0=zephyr` | PASS | PASS |
> | `--dom0=linux` | PASS | PASS |
>
> In the **thin Linux Dom0** flavour Dom0 runs the xl toolstack and creates the guests,
> and block-attaches the guest partitions to the dom0less DomD
> (`xl-attach-disks.service` in `meta-xt-dom0-linux`: p2->`xvda` = DomD's own rootfs,
> p3->`xvdb`, p4->`xvdc`), against which DomD's `xl devd` spawns the guest device-models.
> Verified on hardware: DomD's `/` is `/dev/xvda` ext4 with no initramfs, all three vbd
> frontends reach state 4, and Dom0 at `dom0_mem=512M` has ~312 MiB available with no OOM.
>
> The 8 GB SKU is verified only in the sense that the 8 GB *map* boots on a 16 GB board;
> an 8 GB board's usable ceiling is still extrapolated. See *Board RAM size* (`docs/DESIGN.md`).

## Serial console — the single debug UART is Xen-multiplexed (Ctrl-A x3)

The RPi5 has one debug UART; Xen multiplexes it across the consoles that use the
hypervisor's serial path. Press `Ctrl-A` **three times** to cycle the input focus —
Xen announces each switch with `*** Serial input to <name>`. The cycle covers
**Xen → Dom0 → DomD (`DOM1`)**: Dom0 (the Zephyr shell, or the Linux login) and the
dom0less **DomD** (a **vpl011** domain) are the guests on this UART. Cycle input to
`DOM1` and you land on `raspberrypi5-domd login:`. DomD is reachable *only* this way on
the serial line — `xl console 1` / `xu console 1` cannot attach it (its vpl011 console
is backed by the hypervisor ring, not a PV console ring, so there is no pty to attach);
read its log non-interactively with `xl dmesg | grep DOM1`. Output from Xen/Dom0/DomD is
interleaved on the line (DomD prefixed `(XEN) DOM1:`); switching input only changes which
console receives your keystrokes.

**DomU and DomA are *not* on this UART.** Both are `xl`-created (not dom0less) and have no
vpl011, so each gets a Xen **PV console** (`hvc0`) instead — reach DomU with
`xl console 3` and DomA with `xl console 2`, both from the toolstack domain.
(Console access verified on hardware, both Dom0 flavours: `Ctrl-A ×3 → DOM1` → DomD root
login; `xl console 3` → `domu login:`; `xl console 2` → `console:/ $`.)

`xenconsole` calls `tcsetattr()` on stdin, so **`xl console` needs a tty**. Running it over
a plain `ssh root@192.168.10.10 'xl console 2'` hangs with no output; use `ssh -tt`. An
earlier revision of this README recorded DomA as having no PV console on the strength of
such a run — that was the missing tty, not a missing console.

> **The `virtconsole` sockets in `doma.cfg` do not work, by design conflict.** The V4H
> layout this configuration mirrors intended guest `hvc0` to be the first
> `virtconsole` (`/run/android_vm_virtconsole1`) and `hvc2` to carry logcat
> (`/run/android_vm_virtconsole4`). Under Xen that cannot happen: `xl` gives DomA a PV
> console ring whose frontend registers at **0.000425 s**, long before the PCI bus is
> walked, so `hvc0` is already taken when `virtio_console` probes. The six ports then
> appear as generic virtio-serial ports (`/sys/class/virtio-ports/vport2p0..p5`) and
> nothing in the guest opens them. The sockets go `st=01` LISTENING → `st=03` on connect
> and qemu holds them, but `socat` reads **0 bytes** — the transport is fine, there is
> simply no writer. Use `xl console 2` for the shell and `adb logcat` for logcat (the
> `seriallogging` service is `stopped` in this AAOS image, so `/dev/hvc2` is idle too).
> The devices are kept for V4H parity; deleting them changes DomA's virtio device count
> and PCI `addr` layout, which are proven values.

Quick sanity: all four domains in `xl list`, both panels lit, touch works on
the IVI panel, `kmscube`-class GL content renders via virtio-gpu-gl.

## `ninja failed with: signal: killed` during a `--aaos=source` build

**Symptom.** The AOSP step dies part-way (often 40-60 %) with
`ninja failed with: signal: killed`, then `#### failed to build some targets ####`,
then `FAILED: android/out/target/product/<device>/boot.img …`. Older `build.sh`
revisions reported it as a possible transient fetch/repo-sync abort and burned all
five retries on it; it now stops on the first one with the remedy below.

**Cause.** The build container was OOM-killed. Confirm on the host:

```sh
dmesg -T | grep -iE 'oom-kill|Memory cgroup out of memory'
# oom-kill:constraint=CONSTRAINT_MEMCG … task=ninja
```

`CONSTRAINT_MEMCG` means the *container's* limit was hit, not the host's — the host
can still have tens of GiB free. AOSP's `soong_ui` sizes `ninja -j` from
`runtime.NumCPU()+2` and never consults the cgroup limit, so a many-core host
overruns any `--memory` you set.

**Fix.** Cap the CPUs the container can see. This is what lowers `-j`; docker
`--cpus` does not, because it leaves `nproc` unchanged:

```sh
XT_DOCKER_RUN_OPTS="--cpuset-cpus=0-15" ./build.sh --aaos=source … --memory=44g
```

Re-run — the AOSP build resumes incrementally, so nothing is lost. For scale: on a
32-core host with a 44 GiB cap, a cold AOSP build was killed at `nproc`=32 and peaked
at ~19 GiB at `nproc`=16. Neither a warm `--aaos-src` tree (its `m` finishes in
minutes) nor a resumed build reaches that peak, so verify the fix on a cold one. See
*Bounding a cold AOSP build* (`docs/BUILD.md`).

## A mistyped `--sstate` / `--dl` / `--west-cache` path

**Symptom.** `build.sh` stops in a second or two with:

```
ERROR: --sstate: no such directory: /mnt/disk3/yocto/sstat
       This is almost always a typo -- a mistyped cache silently rebuilds
       everything. If a fresh sstate cache really was intended, create it first:
         mkdir -p '/mnt/disk3/yocto/sstat'
```

**Cause.** The path does not exist. It used to be created for you, which meant a
mistyped cache produced a *working* build that reused nothing: every task rebuilt from
source, the log looked entirely ordinary, and the only symptom was a 20-minute build
taking hours. The check exists so that failure is loud and immediate instead.

**Fix.** Correct the path. If you really did mean to start a fresh cache in a new
location, create the directory first — an existing but empty cache is accepted and only
noted:

```
>> NOTE: --sstate: '/data/sstate' is empty -- cold sstate cache, expect a long first build.
```

Nothing is auto-created any more, for any of the three cache flags. `--aaos-ref` and
`--aaos-kernel-ref` are checked more strictly still: the directory must exist *and*
hold at least one bare `*.git`, because an empty one would make `repo` fall back to
full network fetches — the very thing those flags exist to avoid.

## A Zephyr build cannot find Python 3.12

```
CMake Error at .../FindPackageHandleStandardArgs.cmake:230 (message):
  Could NOT find Python3: Found unsuitable version "3.10.12", but required is
  at least "3.12" (found /usr/bin/python3 ...)
Call Stack ... zephyr/cmake/modules/python.cmake:41 (find_package)
```

**Cause.** An image built from a `Dockerfile.builder` older than the Zephyr 4.4 move --
in practice an image `XT_DOCKER` points at, such as a pre-rename `sodev-builder`. Zephyr 4.4 sets
`PYTHON_MINIMUM_REQUIRED 3.12`; the distro python3 in the image is 3.10 and stays 3.10
on purpose (Yocto and the AOSP host tools are validated against it). What the current
`docker/Dockerfile.builder` does is install python3.12 alongside, put Zephyr's
`requirements-base.txt` in `/opt/zephyr-venv`, and point `/usr/local/bin/west` at that
interpreter -- `west build` then hands cmake the 3.12 it is running under. An old image
has `west` on 3.10 instead, and cmake stops as above.

**Fix.** `./build.sh --rebuild-images ...` once. To confirm which image you have:
`docker run --rm sodev-builder-rpi head -1 /usr/local/bin/west` should print
`#!/opt/zephyr-venv/bin/python3.12`. Note that `tools/check-domz.sh` uses the same
`XT_DOCKER` default, so a stale image makes its DomZ build step fail the same way.

## DomZ does not start

DomZ (the Zephyr RTOS domain, `-z`) has one interface: its Xen PV
console. Everything below is read there, with `xl console DomZ` from the toolstack
domain (`ssh -tt root@192.168.10.10 'xl console DomZ'` over ssh, since `xenconsole`
needs a tty). Exit with `Ctrl-]`.

| Symptom | Cause | What to do |
|---|---|---|
| `xl create` fails, `rc=-19` in `xl dmesg` | The guest asked for a vGICv3. BCM2712 is a GIC-400 and Xen reports *"vGICv3 is not supported on this platform"* | `gic_version="v2"` in `/etc/xen/domz.cfg` (it is the shipped value) and a DomZ image built for the plain `xenvm` board, not `xenvm_gicv3` |
| `xl create` hangs waiting for a device model | Something added a `virtio`/`disk`/`vif` entry to `domz.cfg`, so libxl spawns qemu for a guest that has no need of one | Keep all three lists empty — DomZ uses only the PV console |
| `xl create` prints `Parsing config from …` and then hangs forever | **xenstore is not reachable.** libxl blocks on its first xenstore write, before it ever touches the guest image, so this looks like an image problem and is not one. Reproduced deliberately under QEMU: with `xenstored` failing, `xl create` hung exactly here and `xl list` showed no domains at all — not even Dom0 | Check the toolstack domain: `xl list` must show Dom0/DomD. In the zephyr flavour xenstore is served by Zephyr Dom0 (`domd-toolstack-prep` seeds the connection); in the linux flavour it is `xenstored.service`. `systemctl status xenstored` and `journalctl -u xenstored` name the cause — on a Linux Dom0 the usual one is a kernel without `CONFIG_XEN_GNTDEV`, which makes xenstored exit with *"Failed to open connection to gnttab"* |
| Console silent, no `DomZ up:` line | The image is not what `kernel=` points at, or p1 was not mounted | `ls -l /mnt/zephyr-domz.bin` in the toolstack domain; `xl-create-domz.service` mounts `/dev/mmcblk0p1` at `/mnt` in its `ExecStartPre` |

## Health checks (xenstore / teardown regression sanity)
Run from the toolstack domain after boot:

| Check | PASS criterion |
|---|---|
| `xl list` | responds immediately and shows all 4 domains |
| xenstore burst: `for i in 1 2 3 4 5; do xenstore-write /local/domain/1/data/p$i v$i && xenstore-read /local/domain/1/data/p$i && xenstore-rm /local/domain/1/data/p$i; done` | completes without stalling (bursts like this used to wedge the xenstore server) |
| `dmesg \| grep -E 'error -5\|while (read\|writ)ing message'` in DomD | no output (no xenstore ring corruption) |
| `xl destroy DomU` then `xl create /etc/xen/domu.cfg` | destroy returns promptly and the re-created guest comes up (never destroy DomA — see Known issues) |

## Known issues
- **`dumpstate_grpc_server` does not run.** The prebuilt binary is linked against
  `libxml2.so.2` while wrynose ships `libxml2.so.16`, so it exits immediately. Its
  unit is therefore deliberately left out of `SYSTEMD_SERVICE` (it is installed but
  not enabled), and `SKIP_FILEDEPS` is set so the unprovidable `libxml2.so.2`
  requirement does not fail `do_rootfs`. The fix is to rebuild it against the
  wrynose libxml2; nothing in the demo depends on it in the meantime.
- **DomA re-create**: the DomD vhost-Xen patch tracks a single guest domid, so
  `xl destroy` + `xl create` of DomA breaks vhost-vsock/-net mappings
  (`vhost_xen_map_desc: Failed to map pages`). Reboot the board to restart DomA
  (this is also why DomA is created before DomU). A per-device domid fix is
  future work.
- **AAOS guest niceties** (guest-image side): Bluetooth-without-HCI log noise —
  suppress at runtime with `settings put global bluetooth_on 0` (NOT
  `pm disable com.android.bluetooth`, which crashes system_server); a benign
  boot-window dropbox race.
- Occasional qemu cleanup timeouts leave a zombie domain on `xl destroy`; a
  board reboot recovers.
- **DomA's AAOS home screen intermittently fails to appear, and the real cause is a
  `vhost_xen` domid race — not `/data`.** Measured across five consecutive boots of
  a byte-identical image with a pristine `userdata`: two succeeded, three left the
  AAOS panel black. The chain, established from a full `logcat` plus DomD's kernel
  log, runs the opposite way round from what the symptoms suggest:

  ```
  vhost_xen binds its single global guest_domid to the WRONG guest
    -> DomA's vhost-vsock and both vhost-net queues map DomU's memory
    -> the guest VHAL never reaches vehicle_hal_grpc_server on the host
    -> TimeHalService.init() cannot set EPOCH_TIME (property 290457094 =
       0x11500606) and gets NOT_AVAILABLE (code 3)
    -> that throws inside VehicleHal.priorityInit(), so CarService fails to
       construct at all -- 53 retries over 32 s, then it gives up
    -> com.android.car crash-loops (~2.1 s period, ~116 PIDs/s), so the
       car_service binder is never published
    -> FallbackHome can never hand over to CarLauncher
    -> HDMI-A-2 shows nothing
  ```

  `vhost_xen` keeps **one** global `guest_domid` for the whole driver domain, so a
  DomD that backs two guests can only ever map one of them. On this board only DomA
  uses vhost (`vhost-vsock-pci` for the VHAL, two `vhost=on` netdevs); DomU's netdev
  is `vhost=off` and it has no vsock device. Kernel patch `xen_patchset/0013`
  originally re-bound the parameter to the **highest** running domid, which is DomU
  — a guest with no vhost device at all. A userspace daemon
  (`domd-vhost-xen-domid`) corrected it back to the lowest domid, but only on a 10 s
  poll, so the exposure window was `next_tick - DomU_creation_time`, uniformly
  distributed over 0–10 s. That is the intermittency.

  Diagnosis, from DomD:
  ```
  cat /sys/module/vhost_xen/parameters/guest_domid   # must be DomA's domid (2)
  dmesg | grep 'Set new domid'                      # a 2 -> 3 flip is the failure
  journalctl -u dnsmasq | grep -c 'cb:ce\|cb:cf'    # DomA MACs: zero DHCP = vhost dead
  ```
  and from DomA (`adb`, or `xl console 2` on the DomD toolstack):
  ```
  getprop sys.boot_completed         # broken: empty; healthy: 1
  service check car_service          # broken: "not found"; healthy: "found"
  logcat | grep 290457094            # broken: "failed to set value for property"
  ```

  **Fixed** by making `0013` select the lowest domid that is both `running` and still
  has a live `/local/domain/<domid>` tree. That is the same value the daemon computed,
  it matches upstream EPAM semantics (with a single device-model the original code
  latched that guest and never re-bound, so the first-created vhost guest kept the
  binding), and it removes the window entirely. The liveness check also solves what
  `0013` was really written for: the toolstack leaves stale
  `/local/domain/<DomD>/device-model/<domid>` nodes behind — `libxl__destroy_device_model()`
  only cleans the Dom0 path — and those can keep a last recorded state of `running`,
  so no ordering of domids can distinguish them. The `domd-vhost-xen-domid` daemon is
  retained for now as a belt-and-braces and can be dropped once the kernel-side fix
  has been confirmed over several boots.

  The V4H reference has the identical single-global-`guest_domid` limitation and no
  workaround at all; it avoids the symptom purely by creating DomA first
  (`backend-ready@block` before `backend-ready@bridge`, reinforced upstream by a
  `sleep 5` in every other guest's unit), so the guest that needs vhost wins the
  latch. The upstream authors note the real fix in their own comments: pass the guest
  domid from qemu through a VHOST ioctl and keep it per device rather than in one
  global.

  Unrelated to the above, and still open: **DomA has no graceful-shutdown path.**
  `xl shutdown` writes `control/shutdown=poweroff` and the guest kernel calls
  `orderly_poweroff()`, but Android ships no `/sbin/poweroff`, so the request is a
  no-op (and `doma.cfg` deliberately sets `on_crash`/`on_reboot = preserve` for lab
  post-mortems). Every board power-off therefore stops Android with `/data` mounted
  read-write. That is a durability risk worth fixing, but note that it was **not** the
  cause of the black screen above: on the failing boots `vold` was `running`, `/data`
  (`vda12`) was mounted, and restoring a pristine `userdata` did not help — the
  restored image was byte-identical (`md5 7436d9a5…`, 7 GiB) to one that had already
  failed.
- **DomA's virtio-pci devices share four level-triggered INTx lines.** libxl emits
  no `msi-parent` for the virtio-pci host bridge (Xen builds with
  `CONFIG_HAS_ITS=n`, and upstream vITS is hardware-domain only), so the guest
  falls back to legacy INTx: `interrupt-map-mask` reduces the device number modulo
  4, giving SPI 44-47 for all seven devices. Measured in the guest:
  `irq 14 = SPI 45 (virtio-blk + virtio-tablet)`, `irq 15 = SPI 46 (vhost-vsock +
  virtio-net#2)`, `irq 16 = SPI 47 (virtio-serial + virtio-gpu)`,
  `irq 17 = SPI 44 (virtio-net#1)`. Sharing is inherent (seven devices, four
  lines) and `alloc_virtio_pci_host()` keys host-bridge allocation on the backend
  domid, so a single DomD device model always lands on one bridge. A few spurious
  interrupts do occur on the busiest line (`/proc/irq/16/spurious` showed
  `unhandled 4` against `count 64320`); Linux disables a line only after 99,900
  consecutive unhandled interrupts, which has not been observed here. Moving these
  devices to virtio-mmio (SPI 33-43, one dedicated line per device) would remove
  the sharing entirely and is the upstream-supported transport.

  **This is inherited from the V4H reference, not introduced here**, and the delta
  is worth stating because it runs the other way. The AGL V4H workspace
  (`meta-rcar-demo`, DomA on `xen-troops/xen` branch `xen-4.19-xt0.2`) declares the
  same seven virtio-pci devices at the same `addr=1..7`, and its libxl carries the
  same `VIRTIO_PCI_HOST_NUM_SPIS = 4`, the same `(pin + slot) % 4` swizzle, the same
  `PCI_DEVFN(3, 0) << 8` interrupt-map mask, the same `GUEST_VIRTIO_PCI_SPI_FIRST/
  LAST = 44/76`, no `msi-parent`, and the same `backend_domid`-keyed host-bridge
  allocation — so V4H shares the identical four lines with the identical pairing
  (virtio-serial together with virtio-gpu on the top line). Three fixes in this
  workspace are *ahead* of that base:
  - `4.22-0004-vgic-pci-irq-level-race-fix.patch` — the level-emulation array
    `d->arch.vgic.pci_irq_level[]` is written in `vgic_inject_irq()` while
    `gic_update_one_lr()` reads the same slot under the target vCPU's `vgic.lock`.
    The base writes it unlocked; the race loses a level update (missed interrupt)
    or leaves a stale `true` behind (spurious re-injection).
  - the same series' bounds tightening — the base tests
    `virq <= GUEST_VIRTIO_PCI_SPI_LAST` against a `pci_irq_level[NR_PCI_IRQS]`
    (32 entries), so SPI 76 indexes one past the end; here the writer and the
    reader both use `<` *and* the array is sized `NR_PCI_IRQS + 1`.
  - `0110-xen-ioreq-isr-range-fix.patch` — the base ships only the BTN_TOUCH qemu
    patch, so a virtio-pci ISR page missing from the IOREQ rangeset still faults
    the guest in `vp_interrupt`.

  One option exists here that does not on V4H: `CONFIG_NEW_VGIC` keeps a real
  `line_level` for level interrupts, but it is `select GICV2` and `xen/arch/arm/vgic/`
  has no v3 emulation, so it is only applicable to a GICv2 host — BCM2712 is
  `arm,gic-400`, while V4H is `arm,gic-v3`. It is untried here: upstream marks it
  `default n`, not security supported, and mutually exclusive with `HAS_ITS`.

