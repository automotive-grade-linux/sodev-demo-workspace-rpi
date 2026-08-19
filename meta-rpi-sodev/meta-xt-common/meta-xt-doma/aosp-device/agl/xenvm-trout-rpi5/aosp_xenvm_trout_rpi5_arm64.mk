# SPDX-License-Identifier: Apache-2.0
#
# Raspberry Pi 5 DomA product: the upstream xenvm-trout product plus the one file
# minradio needs, and nothing else.
#
# WHY THIS EXISTS AT ALL
# The interface-rename fix (init.xenvm-buried-eth0.rc) has to reach the vendor
# partition, and the only mechanism for that is PRODUCT_COPY_FILES in a product
# makefile. device/epam/aosp-xenvm-trout is repo-managed, so adding the line there
# would be reverted by the next `repo sync`; the rpi4 board already solves the same
# problem with a staged product of its own. Without the file, AAOS never finishes a
# data call and retries setupDataCall at 7-13 Hz -- measured at 186 % of a physical
# core for 1 h 42 m on rpi4, and this product ships the same minradio APEX, the same
# cuttlefish rename_eth0 service and the same trout property that disables it
# (verified in this tree's own rpi5 build output: vendor/apex carries
# com.android.hardware.radio.minradio.virtual.apex, vendor/etc/init/init.cutf_cvm.rc
# carries the service, and vendor/build.prop has
# ro.vendor.disable_rename_eth0=true).
#
# PRODUCT_DEVICE IS DELIBERATELY UNCHANGED
# Unlike the rpi4 variant -- which needs its own PRODUCT_DEVICE because its
# BoardConfig names a different CPU variant (cortex-a72) -- this product changes no
# board property. Keeping PRODUCT_DEVICE at xenvm_trout_arm64 means:
#   * it reuses the upstream BoardConfig, so there is no second BoardConfig.mk for
#     one device name (which AOSP's board_config.mk rejects), and
#   * out/target/product/xenvm_trout_arm64 stays the same tree, so switching to this
#     product is an incremental build rather than a fresh 200k-action one, and the
#     yaml's ANDROID_DEVICE (which names that directory for rouge) does not move.
# What does change is PRODUCT_NAME, and with it ro.product.name /
# ro.build.fingerprint. Nothing in this workspace keys off either.
#
# The inherit has to come first: the upstream makefile ends with its own
# PRODUCT_NAME / PRODUCT_DEVICE / PRODUCT_MODEL assignments, so ours have to be
# written after it to win.
$(call inherit-product, device/epam/aosp-xenvm-trout/aosp_xenvm_trout_arm64.mk)

PRODUCT_NAME := aosp_xenvm_trout_rpi5_arm64
PRODUCT_DEVICE := xenvm_trout_arm64
PRODUCT_MODEL := xenvm arm64 trout (Raspberry Pi 5)

# Start the interface rename that minradio's data call depends on. cuttlefish already
# ships the service and a trigger for it, but trout sets ro.vendor.disable_rename_eth0
# so that trigger never fires; overriding that is deliberate and argued in the .rc.
# The file is shared with the rpi4 product (device/agl/common) because the fix is a
# property of minradio and trout, not of either board.
PRODUCT_COPY_FILES += \
    device/agl/common/init.xenvm-buried-eth0.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.xenvm-buried-eth0.rc

# Settings.Global defaults for a fresh userdata: Bluetooth off (no transport in this
# guest, and com.android.bluetooth crash-loops without one) and window/transition
# animations off (the device model, not the GPU, pays for them). The overlay file
# carries the measurements and the runtime equivalents for an existing /data.
DEVICE_PACKAGE_OVERLAYS += device/agl/common/overlay
