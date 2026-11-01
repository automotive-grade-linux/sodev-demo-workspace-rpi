# SPDX-License-Identifier: Apache-2.0
#
# Board configuration for the Raspberry Pi 5 variant of the xenvm-trout AAOS guest.
#
# The upstream board config is included wholesale and the lines after it
# override or extend individual variables, so this file stays a delta rather
# than a fork: what it does not name -- partition sizes, bootconfig, kernel
# cmdline and the rest -- keeps coming from device/epam/aosp-xenvm-trout.
include device/epam/aosp-xenvm-trout/xenvm_trout_arm64/BoardConfig.mk

# --- Raspberry Pi 5 (BCM2712) ISA baseline ---------------------------------------
# The included config resolves, via device/google/trout/trout_arm64/BoardConfig.mk, to
#     TARGET_CPU_VARIANT := cortex-a53
# and this file names cortex-a76 instead. READ THE RPi4 COUNTERPART BEFORE CHANGING
# THIS: that board's BoardConfig.mk (device/sodev/xenvm-cf, a manifest project rather
# than a staged directory) records, with a measurement, that the CPU variant is NOT
# what keeps the guest off the ARMv8 crypto extensions. AOSP 17's clang defines
# none of __ARM_FEATURE_{AES,SHA2,CRYPTO} for -mcpu=cortex-a53/a72/a76, so
# BoringSSL takes its OPENSSL_STATIC_ARMCAP-undefined path and dispatches
# through OPENSSL_armcap_P at run time. That is board-independent, and it is the
# real reason no SIGILL happens.
#
# So this line is NOT here to avoid illegal instructions. On this board it could not
# be: BCM2712's Cortex-A76 HAS the crypto extensions. (Yocto agrees and is explicit
# about it -- meta-raspberrypi's raspberrypi5.conf requires
# tune-cortexa76.inc, whose TUNE_FEATURES:tune-cortexa76 is
# "aarch64 crypto cortexa76", against raspberrypi4-64.conf's
# DEFAULTTUNE = "cortexa72-nocrypto". There is no AOSP equivalent of that split.)
#
# It is here for the two reasons the RPi4 file gives, both of which apply
# unchanged:
#
#   1. It gives this board its own PRODUCT_DEVICE, so the two boards'
#      out/target/product/ trees stay apart and objects built for the other CPU cannot
#      be reused silently. Each board syncs its own AOSP checkout anyway
#      (rpi4-sodev.yaml sets DOMA_DIR = "android-rpi4", rpi5-sodev.yaml "android"),
#      so this is a guard rather than the thing that makes the arrangement work.
#
#      What it does carry is the other direction: a PRODUCT_DEVICE of its own is the
#      only way this product can ship the BoardConfig.mk it needs at all, because
#      AOSP's board_config.mk rejects two configs for one device name.
#
#   2. Whether the CPU variant matters for some library other than libcrypto has not
#      been established. Only BoringSSL's SHA256 path was examined.
#
# TARGET_ARCH_VARIANT stays armv8-a; it is the CPU variant that names the extensions.
#
# Measured: build/soong/cc/config/arm64_device.go:83 lists cortex-a76 as a recognised
# variant and :143 maps it to ${config.Arm64CortexA55Cflags}, so this is a supported
# value and not a silent fall-through to the default.
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_VARIANT := cortex-a76

# The Wi-Fi path's sepolicy: the shadow AP and the relay (doma_shadow_ap.te), and
# DomaWifiRelay's drop-box (system_app.te), written so that the path works enforcing
# although this product boots permissive. Same content as the RPi4 board's.
BOARD_VENDOR_SEPOLICY_DIRS += device/agl/xenvm-trout-rpi5/sepolicy

# ---------------------------------------------------------------------------
# Build the Venus ICD.
#
# The included board config sets BOARD_MESA3D_USES_MESON_BUILD and
# GALLIUM_DRIVERS := virgl and names no Vulkan driver, so Mesa was configured
# with -Dvulkan-drivers= and nothing after it and the install tree carries no
# libvulkan_*.so. Naming it here is what puts -Dvulkan-drivers=virtio on the
# meson line and what makes Mesa's Android.mk emit the vulkan.virtio module
# into /vendor/lib64/hw/.
#
# Build-system trap: the MESON_MESA3D .build.timestamp rule rebuilds the whole
# meson project with rm -rf / cp -r / meson setup / ninja, and this variable is
# not among its prerequisites, so make semantics alone do not retrigger it.
# mesa3d_cross.mk also touches an empty .so when the real one is missing and
# Android.mk turns LOCAL_CHECK_ELF_FILES off, so a stale tree ships a 0-byte ICD
# and the build still passes. Remove obj/MESON_MESA3D* before trusting a
# rebuild.
BOARD_MESA3D_VULKAN_DRIVERS := virtio
