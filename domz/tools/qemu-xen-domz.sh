#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Boot Xen + a minimal Linux Dom0 under QEMU aarch64, so DomZ can be created with xl
# on a PC. This is how the one thing that no build can check was checked: that
# `xl create` accepts the Zephyr image and that the guest reaches its PV console.
#
# Result when this was last run (Zephyr 3.6, Xen 4.21.1-pre, GICv2) -- see RECORDED
# OUTPUT at the end of this file, which is updated from the actual console.
#
# The share disk is built here rather than being a manual step: it is how the guest
# binaries and their xl configs reach Dom0 (which has no network), and a harness whose
# first step is undocumented is not a harness. Point DOMZ_BIN at another build if you
# want, or pass --refresh-share to rebuild it after a Zephyr change.
#
# No u-boot and no ImageBuilder: Xen finds Dom0 through /chosen/module@N in the
# device tree, exactly like the dom0less DomD on the real board does. So we dump
# QEMU's own DT, add those nodes, and let QEMU place the files in memory with
# -device loader. That is the whole trick.
#
# Layout in guest-physical memory (QEMU virt RAM starts at 0x40000000):
#   0x40000000  Xen            (-kernel, arm64 Image header)
#   0x44000000  Dom0 kernel    (-device loader)
#   0x50000000  Dom0 initramfs (-device loader; clear of 0x48000000, where QEMU
#               parks the DTB)
set -euo pipefail

# Default to the workspace this script lives in (tools/ is two levels down from
# the repository root), not to whatever path it happened to be written on: an
# absolute home directory from another machine makes the first run fail on a
# missing DEPLOY path instead of just working. Override with WS= for a
# workspace built elsewhere.
WS="${WS:-$(cd "$(dirname "$0")/../.." && pwd)}"
DEPLOY="$WS/yocto/build-qemu/tmp/deploy/images/qemuarm64"
OUT="${OUT:-$(dirname "$0")/qemu-xen}"
mkdir -p "$OUT"

REFRESH_SHARE=0
args=()
for a in "$@"; do
  case "$a" in
    --refresh-share) REFRESH_SHARE=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

XEN_BIN="$DEPLOY/xen-qemuarm64"
DOM0_KERNEL="$DEPLOY/Image"
DOM0_INITRD="$DEPLOY/core-image-minimal-qemuarm64.rootfs.cpio.gz"

for f in "$XEN_BIN" "$DOM0_KERNEL" "$DOM0_INITRD"; do
  [ -f "$f" ] || { echo "missing artifact: $f"; exit 1; }
done

# ---------------------------------------------------------------- share disk
# Dom0 has no network, so the guest images and their xl configs travel on a small FAT
# disk (virtio-blk). Dom0 mounts it at /mnt/host; the xl configs below refer to that
# path, which is why they are generated here rather than committed.
SHARE="$OUT/share.img"
DOMZ_BIN="${DOMZ_BIN:-$WS/zephyr-domz/build-domz-rpi5/zephyr/zephyr.bin}"

if [ ! -f "$SHARE" ] || [ "$REFRESH_SHARE" = 1 ]; then
  if [ ! -f "$DOMZ_BIN" ]; then
    cat >&2 <<EOF
missing DomZ image: $DOMZ_BIN

Build it first (from the west workspace the domz component creates):
  cd $WS/zephyr-domz && source zephyr/zephyr-env.sh
  west build -p always -b xenvm -d build-domz-rpi5 ../domz/app
Or point DOMZ_BIN at a build you already have.
EOF
    exit 1
  fi

  tmpcfg="$(mktemp -d)"
  trap 'rm -rf "$tmpcfg"' EXIT
  # gic_version="v2" for the same reason as on the board: this host has no usable
  # vGICv3 (QEMU is started with gic-version=2 above, so a v3 guest would fail to
  # create with rc=-19).
  cat > "$tmpcfg/domz.cfg" <<EOF
name = "DomZ"
kernel = "/mnt/host/domz.bin"
memory = 16
vcpus = 1
gic_version = "v2"
on_crash = 'preserve'
on_reboot = 'restart'
on_poweroff = 'destroy'
virtio = []
disk = []
vif = []
EOF

  rm -f "$SHARE"
  truncate -s 8M "$SHARE"
  mkfs.vfat -n DOMZSHARE "$SHARE" >/dev/null
  mcopy -i "$SHARE" "$DOMZ_BIN" ::domz.bin
  mcopy -i "$SHARE" "$tmpcfg/domz.cfg" ::
  echo ">> share.img built:$(mdir -i "$SHARE" :: | grep -E "^ +[0-9]+ files")"
fi

DOM0_ADDR=0x44000000
INITRD_ADDR=0x50000000   # clear of 0x48000000, where QEMU parks the DTB
k_size=$(stat -Lc %s "$DOM0_KERNEL")   # -L: deploy/ entries are symlinks
i_size=$(stat -Lc %s "$DOM0_INITRD")

# 1. QEMU's own device tree
qemu-system-aarch64 -machine virt,gic-version=2,virtualization=true \
  -cpu cortex-a57 -smp 4 -m 4096 -nographic \
  -machine dumpdtb="$OUT/virt.dtb" >/dev/null 2>&1 || true
[ -s "$OUT/virt.dtb" ] || { echo "dumpdtb produced nothing"; exit 1; }

# 2. add Xen's boot protocol nodes to /chosen
dtc -I dtb -O dts -o "$OUT/virt.dts" "$OUT/virt.dtb" 2>/dev/null
python3 - "$OUT/virt.dts" "$DOM0_ADDR" "$k_size" "$INITRD_ADDR" "$i_size" <<'PY'
import re, sys
path, kaddr, ksize, iaddr, isize = sys.argv[1], *map(lambda x: int(x, 0), sys.argv[2:])
src = open(path).read()
chosen = """	chosen {
		#address-cells = <0x2>;
		#size-cells = <0x2>;
		xen,xen-bootargs = "console=dtuart dtuart=/pl011@9000000 dom0_mem=2560M dom0_max_vcpus=1 loglvl=all guest_loglvl=all sync_console";
		xen,dom0-bootargs = "console=hvc0 earlycon=xen earlyprintk=xen root=/dev/ram0 rdinit=/sbin/init";
		module@0 {
			compatible = "multiboot,kernel", "multiboot,module";
			reg = <0x0 %#x 0x0 %#x>;
			bootargs = "console=hvc0 earlycon=xen earlyprintk=xen root=/dev/ram0 rdinit=/sbin/init";
		};
		module@1 {
			compatible = "multiboot,ramdisk", "multiboot,module";
			reg = <0x0 %#x 0x0 %#x>;
		};
	};
""" % (kaddr, ksize, iaddr, isize)
# replace QEMU's chosen node (it only carries stdout-path / bootargs)
src, n = re.subn(r"\tchosen \{.*?\n\t\};\n", chosen, src, count=1, flags=re.S)
if n != 1:
    src = src.replace("};\n", chosen + "};\n", 1)   # no chosen node at all
open(path, "w").write(src)
print("chosen/module@0..1 written")
PY
dtc -I dts -O dtb -o "$OUT/virt-xen.dtb" "$OUT/virt.dts" 2>/dev/null

# 3. boot it
cat <<'EOF'
=== booting Xen + Dom0 under QEMU (Ctrl-A X to quit) ===
Once the Dom0 shell appears (it autologins as root), DomZ is two commands away:

  mkdir -p /mnt/host && mount /dev/vda /mnt/host
  xl create /mnt/host/domz.cfg && xl list
  xl console DomZ                                   # Ctrl-] to leave the console

EOF
exec qemu-system-aarch64 \
  -machine virt,gic-version=2,virtualization=true \
  -cpu cortex-a57 -smp 4 -m 4096 -nographic \
  -kernel "$XEN_BIN" \
  -dtb "$OUT/virt-xen.dtb" \
  -device "loader,file=$DOM0_KERNEL,addr=$DOM0_ADDR,force-raw=on" \
  -device "loader,file=$DOM0_INITRD,addr=$INITRD_ADDR,force-raw=on" \
  -drive "file=$OUT/share.img,format=raw,if=none,id=sh" \
  -device virtio-blk-device,drive=sh \
  "$@"

# ------------------------------------------------------------- RECORDED OUTPUT
# Actually observed, 2026-08-17, Zephyr 3.6.0 / Xen 4.21.1-pre / GICv2, after the
# multi-board rebase:
#
#   root@qemuarm64:~# mkdir -p /mnt/host && mount /dev/vda /mnt/host
#   root@qemuarm64:~# xl create /mnt/host/domz.cfg && xl list
#   Name                        ID   Mem VCPUs      State   Time(s)
#   Domain-0                     0  2560     1      r-----     26.0
#   DomZ                         3    16     1      -b----      0.0   <- blocked = idle
#   root@qemuarm64:~# xl console DomZ
#   *** Booting Zephyr OS build f12d445f792d ***
#   I: DomZ up: Zephyr 3.6.0 as Xen DomU (AGL SoDeV)
#   I: DomZ: board=xenvm soc=xenvm
#   I: DomZ alive, uptime 10 s
#
# A halted Zephyr keeps its vCPU: a crashed domain stays `r-----` with Time(s)
# climbing, which on the board is a pegged pCPU 0 -- so `xl destroy DomZ` it once the
# dump has been read.
