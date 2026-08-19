# DomZ — Zephyr as an unprivileged Xen guest (the RTOS domain)

DomZ is the fifth domain of this cockpit: **Zephyr running as an ordinary DomU**.
It is built for both boards.

```
Xen 4.22 on Raspberry Pi 5 or 4
|- Dom0 : Zephyr, xenstore only                        [1 vCPU @ pCPU 0]
|- DomD : dom0less driver domain + xl toolstack         [2 vCPU @ pCPU 0-1]
|- DomU : AGL instrument cluster            (-u)        [1 vCPU @ pCPU 1]
|         (pCPU 2 on rpi4 -- meta-xt-rpi4's xt-xen-cfg-domu bbappend moves it
|          off DomD's cores; see the CPU map note in domz.cfg)
|- DomA : Android Automotive OS             (-a)        [2 vCPU @ pCPU 2-3]
|- DomZ : Zephyr RTOS domain                (-z)        [1 vCPU @ pCPU 0]   <- this
```

The domain is **board-independent**: `xenvm` is Zephyr's generic ARMv8 Xen guest
board, so the same image is a valid guest under Xen on a Pi 4 (BCM2711, GIC-400) and
on a Pi 5. It has no rootfs, no device model, no display and no network — its only
interface is the Xen PV console.

Build it with `./build.sh -z`; add `--board=rpi4` for a Pi 4. Console:

```sh
ssh root@192.168.10.10          # the toolstack domain (DomD in the Zephyr-Dom0 flavour)
xl console DomZ                 # Zephyr's Xen PV console, Ctrl-] to leave
```

> **Not in this series:** passing a CAN controller (an mcp2515 HAT on SPI0) through to
> DomZ. That work exists but has never been exercised against a real CAN bus on either
> board, so it is held back for a follow-up series rather than shipped unverified.

## What is in here

| Path | What it is |
|---|---|
| `app/` | The Zephyr application. Board **`xenvm`** (Zephyr's Xen-guest board: GICv2, guest RAM at 0x40000000, Xen PV console). Built by the moulin `domz` component out of a separate west workspace (`zephyr-domz/`), which is why the application itself lives here rather than in that workspace. |
| `tools/qemu-xen-domz.sh` | Boots Xen + a minimal Linux Dom0 under QEMU aarch64 so `xl create` can be exercised on a PC. See *Verifying `xl create` on a PC* below. |
| `tools/meta-domz-qemu/` | The one Yocto layer that harness needs: the Xen dom0 kernel options poky's `features/xen` does not set (`CONFIG_XEN_GNTDEV` above all). |

The domain config and its systemd unit are on the Yocto side, in
`meta-rpi-sodev/meta-xt-common/meta-xt-domz/` (`domz.cfg`,
`xl-create-domz.service`), installed into the toolstack domain's rootfs — DomD in the
Zephyr-Dom0 flavour, the thin Dom0 in the linux one.

Everything that can be checked without a board is collected in
`tools/check-domz.sh` (`--quick` for the static half).

## Verifying `xl create` on a PC (QEMU)

The domain-creation path — does `xl create` accept the Zephyr image, does the guest
reach its PV console — needs a hypervisor, not a Raspberry Pi. `tools/qemu-xen-domz.sh`
boots Xen with a minimal Linux Dom0 under QEMU aarch64 and lets you create DomZ there.
**This has been run, and it works** (recorded with Zephyr 3.6.0 / Xen 4.21.1-pre /
GICv2, before the 4.4.1 move):

```
root@qemuarm64:~# mkdir -p /mnt/host && mount /dev/vda /mnt/host
root@qemuarm64:~# xl create /mnt/host/domz.cfg && xl list
DomZ        3    16     1     -b----       0.0     <- blocked = idle, i.e. healthy
root@qemuarm64:~# xl console DomZ
*** Booting Zephyr OS build f12d445f792d ***
I: DomZ up: Zephyr 3.6.0 as Xen DomU (AGL SoDeV)
I: DomZ: board=xenvm soc=xenvm
I: DomZ alive, uptime 10 s
```

The script builds the share disk (the guest binary plus a generated xl config, on a
FAT image Dom0 mounts at `/mnt/host`) and prints these commands before booting, so
there is no undocumented first step. `--refresh-share` rebuilds it after a Zephyr
change; `DOMZ_BIN` points it at another build.

To reproduce, build a Dom0 for `qemuarm64` in its own build directory:

```sh
cd yocto && source poky/oe-init-build-env build-qemu
bitbake-layers add-layer ../meta-yocto/meta-poky ../meta-openembedded/meta-oe     ../meta-openembedded/meta-python ../meta-openembedded/meta-networking     ../meta-openembedded/meta-filesystems ../meta-virtualization
cp -r ../../domz/tools/meta-domz-qemu ../meta-domz-qemu && bitbake-layers add-layer ../meta-domz-qemu
cat >> conf/local.conf <<'EOF'
MACHINE = "qemuarm64"
DISTRO_FEATURES:append = " xen virtualization"
INIT_MANAGER = "systemd"
IMAGE_FSTYPES:append = " cpio.gz"
IMAGE_INSTALL:append = " xen-tools kernel-modules"
EXTRA_IMAGE_FEATURES:append = " empty-root-password allow-empty-password allow-root-login serial-autologin-root"
EOF
bitbake core-image-minimal xen
cd ../.. && domz/tools/qemu-xen-domz.sh      # see the script header for the share.img step
```

Three things bit during bring-up and are worth knowing, because two of them would bite
on hardware too:

1. **`xl create` printing `Parsing config from …` and then hanging is a xenstore
   problem, not an image problem.** libxl blocks on its first xenstore write. Here
   `xenstored` had died with *"Failed to open connection to gnttab"* because the Dom0
   kernel lacked `CONFIG_XEN_GNTDEV` — hence the layer above. Same signature as
   upstream [issue #42](https://github.com/xen-troops/meta-xt-prod-devel-rpi5/issues/42).
2. Dom0 needs enough memory to unpack its own initramfs — 1 GB was not enough for a
   152 MB cpio.gz and Linux panicked with *"System is deadlocked on memory"*.
3. QEMU-only: `stat` without `-L` on a `deploy/` symlink returns the length of the link
   target string, so Xen believed the kernel was 72 bytes long.

## Hardware bring-up

DomZ has been verified on hardware in all four verification patterns (RPi4 and RPi5,
Zephyr-Dom0 and thin-Linux-Dom0):

```
xl list                      # DomZ present, 16 MiB, 1 vCPU
xl console DomZ              # Ctrl-] to leave
I: DomZ up: Zephyr 4.4.1 as Xen DomU (AGL SoDeV)
I: DomZ: board=xenvm soc=xenvm
I: DomZ alive, uptime 10 s   # every 10 s; the interval measured 10 s with no missed ticks
```

Two things to know when it does not come up:

* If `xl create` fails, check `gic_version="v2"` in `domz.cfg` first: these boards have
  no usable vGICv3, and a `v3` guest fails to create with `rc=-19`. That — not the
  image format — is the likely cause: the image *will* be accepted, because Zephyr's
  arm64 output carries a Linux arm64 Image header (`"ARM\x64"` at offset 0x38), which
  is what libxc's zimage64 loader probes for.
* The console is the Xen PV console, so it needs a pty: `xl console DomZ` from an
  interactive shell in the toolstack domain, or `ssh -tt <toolstack> 'xl console DomZ'`.
  In the Zephyr-Dom0 flavour the same lines are also written to
  `/var/log/xen/console/guest-DomZ.log`, because DomD starts `xenconsoled` with
  `--log=guest --log-dir=...` there. The thin-Linux Dom0 runs the stock unit, whose
  `XENCONSOLED_TRACE` defaults to `none`, so there is no log file on that flavour --
  attach to the console, or set `XENCONSOLED_TRACE=guest` in Dom0's
  `/etc/default/xencommons` first.

### Iterating without reflashing the SD card

Everything DomZ consists of lives in the toolstack domain's filesystem or on the FAT
boot partition it has mounted, and DomZ is created by `xl` at run time. So after the
**first** flash, a DomZ change needs neither a new `full.img` nor a reboot — only
`scp` and a domain restart:

```sh
# 1. Rebuild just DomZ on the build host (minutes, no Yocto work)
./build.sh -z --domains-only          # [--board=rpi4]

# 2. Replace the guest image on SD p1 (the toolstack domain has it at /mnt)
scp zephyr-domz/build-domz-rpi5/zephyr/zephyr.bin root@192.168.10.10:/mnt/zephyr-domz.bin
#   (build-domz-rpi4 on a Pi 4 -- the build dir carries the board, see rpi5-sodev.yaml)

# 3. Restart the domain and watch it come up
ssh -tt root@192.168.10.10 'xl destroy DomZ 2>/dev/null; xl create /etc/xen/domz.cfg && xl console DomZ'
```

The guest config is an ordinary file too, so poll intervals and the like can be changed
the same way. Reflashing is only necessary when something outside DomZ changes (Xen,
DomD, the boot script).

## Memory and CPU

16 MiB and one vCPU, pinned to pCPU 3 (idle in the default DomA-less build; shared
with the Android guest when `-a` is used). The 16 MiB is not a tunable: Zephyr's
`xenvm` board links against a 16 MiB RAM bank at `0x40000000`, so `memory = 16` in
`domz.cfg` has to match it — `tools/check-domz.sh` checks that pair. Nothing
static-mem changes, so the memory map checked by `tools/check-memory-map.py` is
untouched.
