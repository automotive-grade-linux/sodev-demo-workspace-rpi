# SPDX-License-Identifier: Apache-2.0
#
# Product entry point for the Raspberry Pi 5 DomA product (see
# aosp_xenvm_trout_rpi5_arm64.mk for why it exists). Same shape as the rpi4
# variant's AndroidProducts.mk; AOSP finds this file by scanning device/*/*.
#
PRODUCT_MAKEFILES := \
	aosp_xenvm_trout_rpi5_arm64:$(LOCAL_DIR)/aosp_xenvm_trout_rpi5_arm64.mk \

COMMON_LUNCH_CHOICES := \
	aosp_xenvm_trout_rpi5_arm64-trunk_staging-eng \
	aosp_xenvm_trout_rpi5_arm64-trunk_staging-userdebug \
