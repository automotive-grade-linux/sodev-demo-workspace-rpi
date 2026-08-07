# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# RPi4: let the AAOS host-side services build for raspberrypi4-64.
#
# THE BLOCKER
# xt-aaos-host-services.bb ends with
#     COMPATIBLE_MACHINE = "raspberrypi5"
# so on this board bitbake skipped it and the DomD image, which RDEPENDS on it,
# had no buildable provider at all:
#     xt-aaos-host-services was skipped: incompatible with machine raspberrypi4-64
#     ERROR: Nothing RPROVIDES 'xt-aaos-host-services' (but rpi5-image-xt-domd-v4h.bb
#            RDEPENDS on or otherwise requires it)
#     ERROR: Required build target 'rpi5-image-xt-domd-v4h' has no buildable providers.
# i.e. the whole DomD build fails the moment ENABLE_ANDROID=yes. Found on 2026-08-04,
# the first time the RPi4 port ever built with DomA enabled.
#
# WHY IT IS SAFE TO WIDEN
# Nothing in the recipe is BCM2712-specific. It installs our own glue -- gnss_replay.py,
# the dumpstate config, the GNSS csv and three systemd units -- and the two gRPC backends
# it RDEPENDS on come from google-trout-agl-services, which builds them from source for
# whatever machine is being built. The services talk over vsock and a UNIX socket:
#     /usr/bin/vehicle_hal_grpc_server   vsock cid2:9210   (DomA VehicleHAL)
#     /usr/bin/dumpstate_grpc_server     vsock cid2:9310
#     /usr/bin/gnss_replay.py            /run/gnss-uart    (qemu virtconsole)
# The only RPi5 references left in the file are prose (SUMMARY/DESCRIPTION) and this
# guard. RPi4's DomD userspace is the same wrynose aarch64 rootfs.
#
# A machine-specific override rather than editing the value: it follows the precedent
# already in this layer -- recipes-kernel/linux/linux-raspberrypi_6.18.bbappend does
#     COMPATIBLE_MACHINE:raspberrypi4-64 = "(raspberrypi4-64)"
# -- and it leaves the raspberrypi5 value untouched for every other machine, so
# meta-xt-common stays byte-identical and RPi5 is unaffected.
COMPATIBLE_MACHINE:raspberrypi4-64 = "(raspberrypi4-64)"

# NO BINARY SUBSTITUTION IS NEEDED ON THIS BOARD, and this is worth recording because an
# earlier revision of this layer carried a 12 MB replacement binary here.
#
# The RPi4 port originally shipped its own vehicle_hal_grpc_server, because the version
# the shared recipe installed was a prebuilt aarch64 blob compiled for Cortex-A76
# (ARMv8.2). On BCM2711 (Cortex-A72, ARMv8.0) it died with SIGILL the moment it started:
# a bare run exited rc=132 (signal 4), and under systemd the unit reached "restart
# counter is at 65". The causes were LDAPR (FEAT_LRCPC), inline LSE atomics, and
# BoringSSL's hardware-capability checks being short-circuited at compile time by
# __ARM_FEATURE_SHA2.
#
# That whole class of failure is gone: xt-aaos-host-services no longer carries prebuilt
# binaries at all. google-trout-agl-services builds both backends from source in this
# same Yocto build, and meta-raspberrypi's own machine definition sets
# DEFAULTTUNE = "cortexa72-nocrypto" for raspberrypi4-64 -- upstream's default, not
# something this layer sets -- so the compiler never emits ARMv8.2 or crypto
# instructions unguarded. The ISA mismatch was a property of the imported blob, not of
# the board.
#
# If a future change reintroduces a prebuilt here, check it with
#     objdump -d <binary> | grep -c ldapr        # expect 0
# and confirm any LSE / crypto instructions sit behind run-time HWCAP gates (the outline
# atomic helpers, BoringSSL's *_hw routines).
#
# RELATED, AND NEEDED TOGETHER: the recipe's DESCRIPTION asserts "The DomD kernel has
# VSOCK=y / VHOST_VSOCK=y / VHOST=y (no kernel change needed)". That is NOT true on this
# board -- the RPi4 DomD kernel builds them as MODULES
#     CONFIG_VSOCKETS=m  CONFIG_VHOST=m  CONFIG_VHOST_VSOCK=m
# and the DomD image installed only kernel-module-vhost{,-iotlb,-net}. Without
# vhost_vsock there is no /dev/vhost-vsock and DomA's
# `-device vhost-vsock-pci,guest-cid=3` cannot start. That half is fixed by building the
# vsock stack IN rather than as modules -- see the "vsock for DomA" block at the end of
# recipes-kernel/linux/files/bcm2711-domd-hw.cfg in this same layer, which also explains
# why the module route is not viable on this workspace.
