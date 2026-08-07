# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
require recipes-bsp/trusted-firmware-a/trusted-firmware-a.inc

# Current master branch
SRCREV_tfa = "09a1cc2a0bd066702daa269bf35de9c5743ccc93"
SRCBRANCH = "master"

LIC_FILES_CHKSUM += "file://docs/license.rst;md5=b5fbfdeb6855162dded31fadcd5d4dc5"

# =============================================================================
# Raspberry Pi 4 / BCM2711
# =============================================================================
# TF-A provides EL3 on this board: PSCI — which Xen needs to bring up the
# secondary A72 cores — plus the GICv2 init. Facts driving the settings below,
# from docs/plat/rpi4.rst and plat/rpi/rpi4/:
#
#   * the PLAT name is `rpi4` and the only build target is `bl31`
#     (plat/rpi/rpi4/platform.mk: `all: bl31`). TF-A has NO "armstub8-gic.bin"
#     target — that name belongs to raspberrypi/tools/armstubs, a completely
#     different and much thinner EL3 stub. The RPi5 recipe's armstub8-2712
#     target does not exist here either, and neither does its dd of tee-raw.bin.
#   * bl31.bin IS itself a valid armstub: plat/rpi/rpi4/include/plat.ld.S
#     reserves the first 4 KiB for plat/rpi/common/aarch64/armstub8_header.S
#     (magic 0x5afe570b at +0xf0) and BL31 proper starts at 0x1000. The GPU
#     firmware loads whatever `armstub=` names to DRAM 0, enters it at EL3, and
#     fills in dtb_ptr32 / kernel_entry32 in that header — which is how
#     rpi4_get_dtb_address() and plat_get_ns_image_entrypoint() find the DTB and
#     U-Boot with no PRELOADED_* build-time constants.
#   * BL31 occupies 0x1000-0x80000 and rpi4_setup.c registers the whole
#     0x0-0x80000 range as the `atf@0` no-map reserved-memory entry. That is one
#     more reason boot.cmd must never rewrite /reserved-memory (see the
#     #size-cells warning there).
# =============================================================================

COMPATIBLE_MACHINE:raspberrypi4-64 = "raspberrypi4-64"

TFA_PLATFORM:raspberrypi4-64 = "rpi4"
TFA_BUILD_TARGET:raspberrypi4-64 = "bl31"
TFA_INSTALL_TARGET:raspberrypi4-64 = "bl31"

# OP-TEE IS DELIBERATELY OFF for the RPi4 bring-up, and this is the whole of the
# mechanism. meta-xt-rpi5 sets TFA_SPD = "opteed", DEPENDS += "optee-os" and an
# armstub8-2712 install target that dd's tee-raw.bin in after BL31; none of that is
# here. TF-A/rpi4 has no SPD integration comparable to the RPi5 OP-TEE patch, so:
#   * TFA_SPD stays empty (trusted-firmware-a.inc's own default is "", and saying it
#     explicitly is the statement that it is a choice);
#   * no optee-os DEPENDS, and this layer carries no recipes-security/optee at all;
#   * the DomD node in bcm2711-raspberrypi4-64-xen.dtso carries no xen,tee = "optee";
#   * xen-hyp-config.cfg has no CONFIG_TEE / CONFIG_OPTEE.
# Turning it on later means all four of those, plus writing the plat/rpi4 equivalent
# of the RPi5 OP-TEE patch, plus re-adding the secure carve-out to /reserved-memory
# with #address-cells = <2> / #size-cells = <1> — which is what the BCM2711 root
# declares, and writing 2/2 there makes Linux discard the whole /reserved-memory node
# including TF-A's own atf@0 entry.
TFA_SPD:raspberrypi4-64 = ""

# mbed TLS is only needed for the trusted-boot chain, which rpi4 does not use.
# trusted-firmware-a.inc defaults TFA_MBEDTLS to "0", so this is a statement rather
# than a change, and it is why SRC_URI_MBEDTLS / SRCREV_mbedtls /
# LIC_FILES_CHKSUM_MBEDTLS are not declared here: at TFA_MBEDTLS=0 the .inc reads
# none of them.
TFA_MBEDTLS:raspberrypi4-64 = "0"

# do_install in the .inc names the artefacts bl31-rpi4.bin plus a bl31.bin
# symlink; do_deploy copies both into DEPLOY_DIR_IMAGE. The boot partition file
# list in rpi4-sodev.yaml picks up bl31.bin, and rpi-config_git.bbappend writes
# the matching `armstub=bl31.bin` line into config.txt. Those three names must
# stay in agreement.
