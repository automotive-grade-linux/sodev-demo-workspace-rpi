# SPDX-License-Identifier: Apache-2.0
#
# Raspberry Pi 4 variant of aosp_xenvm_trout_arm64.
#
# Everything about the guest is inherited from the upstream product; only the identity
# is different, so that this variant gets its own PRODUCT_DEVICE (and therefore its own
# BoardConfig.mk and its own out/target/product/ tree). The board-specific part is in
# xenvm_trout_rpi4_arm64/BoardConfig.mk.
#
# The inherit has to come first: the upstream makefile ends with its own PRODUCT_NAME /
# PRODUCT_DEVICE / PRODUCT_MODEL assignments, so ours have to be written after it to win.
$(call inherit-product, device/epam/aosp-xenvm-trout/aosp_xenvm_trout_arm64.mk)

PRODUCT_NAME := aosp_xenvm_trout_rpi4_arm64
PRODUCT_DEVICE := xenvm_trout_rpi4_arm64
PRODUCT_MODEL := xenvm arm64 trout (Raspberry Pi 4)
