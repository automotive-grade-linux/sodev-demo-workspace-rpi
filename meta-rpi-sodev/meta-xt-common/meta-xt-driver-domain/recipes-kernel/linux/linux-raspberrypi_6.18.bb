# Proper linux-raspberrypi 6.18 recipe for the shared Dom0/DomD kernel.
#
# Yocto release is wrynose (6.0 LTS); the kernel is bumped 6.12.25 -> 6.18.33
# (the version-pinned base bbappends are _6.12; this recipe provides _6.18).
# Body is meta-raspberrypi master's linux-raspberrypi_6.18.bb (machine branch
# rpi-6.18.y + kmeta branch yocto-6.18 are BOTH pinned to 6.18 so there is no
# source/kmeta version mismatch). The heavy recipe logic is reused from
# meta-raspberrypi's linux-raspberrypi.inc via the path-form `require` (resolved
# through BBPATH). meta-raspberrypi is pinned to master @6d81e22c in rpi5-sodev.yaml.
#
# Attachment: this is a real versioned recipe, so any version-pinned _6.12 base
# bbappend no longer attaches; the bodies we still need are re-hosted into the
# _6.18 bbappends of meta-xt-rpi5, meta-xt-driver-domain and meta-xt-doma.
# `bitbake-layers show-appends` + a SRC_URI audit verifies completeness.
#
# files/vc4graphics.cfg is a byte-identical copy of meta-raspberrypi's own copy
# and must NOT be deleted as a redundant duplicate: linux-raspberrypi.inc adds
# `file://vc4graphics.cfg` to SRC_URI whenever MACHINE_FEATURES contains
# vc4graphics (which rpi-base.inc sets), but FILESPATH is rooted at THIS
# recipe's directory, so meta-raspberrypi's files/ is never searched. Without
# the local copy the recipe fails to parse ("file could not be found").
#
# It is also NOT interchangeable with xen-config-a4b-frontend.cfg. vc4graphics.cfg
# is the stock RPi GPU baseline (I2C_BCM2835/I2C_BRCMSTB, DRM, DRM_FBDEV_EMULATION,
# DRM_VC4, SND/SND_SOC, all =y); xen-config-a4b-frontend.cfg is the Xen override
# that deliberately demotes two of those symbols to =m -- DRM_VC4 so that Dom0's
# modprobe.blacklist=vc4 is effective and DomD can bind the GPU at runtime, and
# I2C_BRCMSTB so that a kernel-module-i2c-brcmstb package exists for the DomD image
# -- and adds the unrelated unpopulated-alloc, 4K-page and THP groups. The override
# only holds because merge_config is last-wins and the Xen fragment is appended
# after vc4graphics.cfg, so the two must both be present and in that order.
LINUX_VERSION ?= "6.18.33"
LINUX_RPI_BRANCH ?= "rpi-6.18.y"
LINUX_RPI_KMETA_BRANCH ?= "yocto-6.18"

SRCREV_machine = "95b85bebbedcaedfa7ca79116ed38b7376fba412"
SRCREV_meta = "6d012fbc35201ba081efcc19c9519c1dc7b64c43"

KMETA = "kernel-meta"

SRC_URI = " \
    git://github.com/raspberrypi/linux.git;name=machine;branch=${LINUX_RPI_BRANCH};protocol=https \
    git://git.yoctoproject.org/yocto-kernel-cache;type=kmeta;name=meta;branch=${LINUX_RPI_KMETA_BRANCH};destsuffix=${KMETA};protocol=https \
    file://powersave.cfg \
    file://android-drivers.cfg \
    "

require recipes-kernel/linux/linux-raspberrypi.inc

KERNEL_DTC_FLAGS += "-@ -H epapr"

RDEPENDS:${KERNEL_PACKAGE_NAME}:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}"
RDEPENDS:${KERNEL_PACKAGE_NAME}-base:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-base"
RDEPENDS:${KERNEL_PACKAGE_NAME}-image:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-image"
RDEPENDS:${KERNEL_PACKAGE_NAME}-dev:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-dev"
RDEPENDS:${KERNEL_PACKAGE_NAME}-vmlinux:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-vmlinux"
RDEPENDS:${KERNEL_PACKAGE_NAME}-modules:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-modules"
RDEPENDS:${KERNEL_PACKAGE_NAME}-dbg:raspberrypi-armv7:append = " ${RASPBERRYPI_v7_KERNEL_PACKAGE_NAME}-dbg"

DEPLOYDEP = ""
DEPLOYDEP:raspberrypi-armv7 = "${RASPBERRYPI_v7_KERNEL}:do_deploy"
do_deploy[depends] += "${DEPLOYDEP}"

# The kconfiglib.py bundled with scarthgap's kern-tools-native cannot parse the new
# Kconfig syntax ('transitional') used by 6.18's arch/Kconfig, so do_kernel_configcheck
# fails with an exception (it is only the Yocto-side config-audit tool that has not caught
# up with the kernel version; the kernel's own Kconfig = do_configure succeeds). In this
# setup, where only the kernel is bumped to 6.18 without upgrading Yocto, disable the audit
# task and guarantee fragment application by inspecting .config directly.
do_kernel_configcheck[noexec] = "1"

# DT staging fix.
# On scarthgap, SRC_URI's `file://<dt>.dts;subdir=git/arch/${ARCH}/boot/dts/broadcom`
# was unpacked directly under WORKDIR/git (= the shared kernel-source). wrynose split
# WORKDIR → UNPACKDIR (${WORKDIR}/sources), so `subdir=git/...` now lands at
# ${UNPACKDIR}/git/arch/${ARCH}/boot/dts/broadcom/ and does NOT reach the real
# kernel-source (S=${STAGING_KERNEL_DIR}=work-shared/.../kernel-source) broadcom dir
# → RPI_KERNEL_DEVICETREE's domd.dtb etc. fail with "No rule to make target".
# Land every .dts/.dtso staged by both the meta-xt-rpi5 and meta-xt-driver-domain bbappends from the
# post-unpack UNPACKDIR into the real kernel-source broadcom dir (since the source is
# shared, overwrite-copy on every do_compile:prepend to reliably apply the patched version).
do_compile:prepend() {
    src_bcm="${UNPACKDIR}/git/arch/${ARCH}/boot/dts/broadcom"
    dst_bcm="${S}/arch/${ARCH}/boot/dts/broadcom"
    if [ -d "${src_bcm}" ]; then
        install -d "${dst_bcm}"
        for f in "${src_bcm}"/*.dts "${src_bcm}"/*.dtso; do
            [ -e "${f}" ] || continue
            cp -f "${f}" "${dst_bcm}/"
            bbnote "wrynose DT staging: $(basename ${f}) -> kernel-source broadcom"
        done
    fi
}
