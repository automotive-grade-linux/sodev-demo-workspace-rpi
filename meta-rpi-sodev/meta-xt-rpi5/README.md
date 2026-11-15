# meta-xt-rpi5 — Raspberry Pi 5 (BCM2712) board layer

Everything specific to BCM2712 for the SoDeV disaggregated cockpit: the DomD partial
device tree, the Xen host overlay and the SCMI host overlay, the U-Boot boot scripts
for both Dom0 flavours, the TF-A, U-Boot and OP-TEE configuration, and the kernel
fragments. `meta-xt-rpi4` is the Raspberry Pi 4 sibling and the two are mutually
exclusive in a build (`rpi5-sodev.yaml` lists this one); its `README.md` describes the
design the two share.

## Licenses in this layer

`LICENSE` is Apache-2.0, and that is the license of every file here that carries no
SPDX tag or is tagged `SPDX-License-Identifier: Apache-2.0` (the device trees and
overlays, the kernel and Xen `.cfg` fragments, the boot scripts, ...), with these
exceptions:

| files | license | why |
|---|---|---|
| `recipes-core/images/rpi5-image-xt-domd-v4h.bbappend`, `recipes-extended/xt-xen-cfg-doma/xt-xen-cfg-doma_%.bbappend`, `recipes-graphics/wayland/weston-init.bbappend`, `recipes-multimedia/rpidistro-ffmpeg/rpidistro-ffmpeg_%.bbappend` | MIT (`SPDX-License-Identifier: MIT`) | recipe metadata, tagged as the meta-xt-common recipes they extend are |
| `recipes-bsp/trusted-firmware-a/trusted-firmware-a.inc` | MIT, no SPDX tag | derived from meta-arm's `recipes-bsp/trusted-firmware-a/trusted-firmware-a.inc` (meta-arm is MIT, its `COPYING.MIT`) with local changes; the same file is in `meta-xt-rpi4` |
| `recipes-kernel/linux/files/bcm2712-raspberrypi5-scmi-host.dtso` | GPL-2.0 (`SPDX-License-Identifier: GPL-2.0`) | a host device-tree overlay built in the kernel tree next to the kernel's own |
| `recipes-extended/xen/files/*.patch`, `recipes-kernel/linux/files/*.patch`, `recipes-bsp/u-boot/files/*.patch`, `recipes-multimedia/rpidistro-ffmpeg/files/*.patch`, `recipes-security/optee/files/*.patch` | the license of the project each one modifies: Xen (GPL-2.0-only; `0025-*.patch` adds a file with that SPDX tag), the Raspberry Pi kernel (GPL-2.0), U-Boot (GPL-2.0+), FFmpeg's libavcodec (LGPL-2.1+), OP-TEE (BSD-2-Clause; the patch adds files with that tag) | a patch is a change to that project, not to this layer |
