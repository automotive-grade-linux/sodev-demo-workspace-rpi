# SPDX-License-Identifier: Apache-2.0
#
# Board configuration for the Raspberry Pi 4 variant of the xenvm-trout AAOS guest.
#
# The upstream board config is included wholesale and only the ISA baseline is changed
# after it, so this file stays a delta rather than a fork: partition sizes, bootconfig,
# sepolicy dirs, kernel cmdline and the mesa3d/virgl selection all keep coming from
# device/epam/aosp-xenvm-trout.
include device/epam/aosp-xenvm-trout/xenvm_trout_arm64/BoardConfig.mk

# --- Raspberry Pi 4 (BCM2711) ISA baseline ---------------------------------------
# The included config resolves, via device/google/trout/trout_arm64/BoardConfig.mk, to
#     TARGET_CPU_VARIANT := cortex-a53
# and LLVM's cortex-a53 feature set implies the ARMv8 crypto extensions. That holds for
# the CPU Arm specifies, and for every host this guest has been built for so far --
# including the Cortex-A76 of a Raspberry Pi 5.
#
# The Cortex-A72 of a Raspberry Pi 4 does NOT implement them:
#     # cat /proc/cpuinfo
#     Features : fp asimd evtstrm crc32 cpuid
# BoringSSL folds its capability check at compile time when the compiler says the
# extensions are present, so /init reaches sha256su0 and dies with SIGILL before
# first-stage mount. The guest never boots, and nothing in the build warns.
#
# Naming cortex-a72 fixes it: the cortex-a72 entry in
# build/soong/cc/config/arm64_device.go carries `-mcpu=cortex-a72+nocrypto`, so the
# folded path is never emitted and BoringSSL keeps its run-time HWCAP check.
# TARGET_ARCH_VARIANT stays armv8-a; it is the CPU variant that leaks the extensions.
#
# This is the AAOS-guest counterpart of the Yocto side, where the DomD host services are
# built with meta-raspberrypi's own DEFAULTTUNE = "cortexa72-nocrypto" for
# raspberrypi4-64 and are therefore already safe.
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_VARIANT := cortex-a72
