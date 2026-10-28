SUMMARY = "Xen runtime cfg for the DomU guest (xl create)"
DESCRIPTION = "\
    /etc/xen/domu.cfg + xl-create-domu.service (disaggregated topology: runs inside DomD, the \
    toolstack domain). qemu reads the DomU rootfs directly from /dev/mmcblk0p3 \
    (DomD owns the SD via SDHCI passthrough); the old Dom0-blkback \
    xl-attach-disks chain is gone. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# xl-attach-disks.service is dropped from the package:
# the Dom0-blkback disk chain does not exist under the Zephyr Dom0; DomD
# owns the SD (SDHCI passthrough) and qemu reads /dev/mmcblk0pN directly.
SRC_URI = " \
    file://domu.cfg \
    file://xl-create-domu.service \
    "

S = "${UNPACKDIR}"

# [Venus] virtio-gpu-gl device-model options, from the moulin GPU parameter (see
# do_install). The RECIPE default is the pre-Venus content even though the product
# default is GPU=vulkan, and deliberately so: a standalone `bitbake xt-xen-cfg-domu`
# outside moulin has no way to know which device model is installed, and `venus=true`
# on a qemu that does not have the property is a config qemu REJECTS outright, while
# the empty string is a working config on either. moulin always sets the value
# explicitly, so the product default does not come from here. Same reason
# xt-xen-cfg-doma defaults BOARD_RAM.
XT_VENUS_GPU_OPTS ??= ""
# [qemu 10] The qemu version the guests' device model is built from. It comes from
# PREFERRED_VERSION_qemu, which the moulin conf sets per lane: in the default
# GPU=vulkan lane 11.1.2 on both boards (qemu_11.1.2.bb; docs/VULKAN-VENUS.md), or
# 10.0.2 where a board selects meta-xt-qemu/qemu_10.0.2.bb instead,
# 7.0.0 for --gpu=gl -- which is the yaml's base value, left standing.
#
# The '7.0.0' fallback below is deliberately the OLDER of the two, because the
# 7.0.0-only syntax is the conservative choice: every qemu in this tree parses
# the config it produces, whereas the 10.x form makes a 7.0.0 device model exit
# on an unknown property. It is not a safe default in general, though: a build
# that leaves PREFERRED_VERSION_qemu unset gets oe-core's qemu
# (10.2.0 at the time of writing) while this fallback still emits the 7.0.0-only
# syntax, and that device model exits on it. Such a build must set
# XT_DM_QEMU_VERSION itself. Inside moulin the variable is always set, so the
# fallback only ever applies to a bare `bitbake` in this tree's own conf.
XT_DM_QEMU_VERSION ??= "${@d.getVar('PREFERRED_VERSION_qemu') or '7.0.0'}"


inherit systemd

SYSTEMD_SERVICE:${PN} = " \
    xl-create-domu.service \
    "
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/domu.cfg ${D}${sysconfdir}/xen/domu.cfg

    # [Venus] Substitute the virtio-gpu-gl device-model options. XT_VENUS_GPU_OPTS
    # comes from the moulin GPU parameter through the domd component conf:
    # ",hostmem=256M,blob=true,venus=true" for the default Vulkan lane, "" for --gpu=gl
    # (docs/VULKAN-VENUS.md). With --gpu=gl the token is replaced with nothing,
    # so that lane's installed file carries none of the Venus options.
    #
    # Fail loudly rather than ship the placeholder: qemu exits on an unknown
    # -device property, so the guest's device model would never start -- and the
    # same applies if a future edit renames the token.
    if ! grep -q 'virtio-gpu-gl-pci.*XT_VENUS_GPU_OPTS_PLACEHOLDER' ${D}${sysconfdir}/xen/domu.cfg; then
        bbfatal "XT_VENUS_GPU_OPTS_PLACEHOLDER not found in domu.cfg"
    fi
    # The value contains ',' and '=' but no '/', so '/' stays usable as the sed
    # delimiter. Deleting the comment block that documents the token as well: it
    # explains a build-time mechanism and has no meaning in the installed file.
    sed -i -e '/^    # XT_VENUS_GPU_OPTS_PLACEHOLDER is SUBSTITUTED AT BUILD TIME/,/^    # See docs\/VULKAN-VENUS.md.$/d' \
           -e "s/XT_VENUS_GPU_OPTS_PLACEHOLDER/${XT_VENUS_GPU_OPTS}/" \
        ${D}${sysconfdir}/xen/domu.cfg

    # [qemu 10] Device-model argument fixups. Two of the options in domu.cfg are
    # 7.0.0-xt-only and qemu 10 EXITS on either one -- both measured on RPi5:
    #   virtio-snd-pci        -> "'virtio-snd-pci' is not a valid device model name"
    #                            (upstream calls it virtio-sound-pci, alias virtio-sound)
    #   virtio-blk-pci,scsi=  -> "Property 'virtio-blk-pci.scsi' not found"
    #                            (the property was removed upstream)
    # `-vga std` only warns there ("this machine type does not use that option";
    # the xenpvh machine creates no VGA device at all), and is dropped with them so
    # the emitted config has no dead options for that device model.
    #
    # Keyed on the device model's version, not on the GPU parameter: the incompatibility
    # belongs to qemu 10, so a later qemu bump outside the Venus lane is covered
    # too, and this step leaves the 7.0.0 (--gpu=gl) lane untouched (the case
    # does nothing there).
    case "${XT_DM_QEMU_VERSION}" in
    7.*)
        ;;
    *)
        sed -i -e "s/'virtio-snd-pci,/'virtio-sound-pci,/" \
               -e "s/'virtio-blk-pci,scsi=off,/'virtio-blk-pci,/" \
               -e "/^    '-vga', 'std',$/d" \
            ${D}${sysconfdir}/xen/domu.cfg
        # Fail loudly rather than ship a config the device model will reject.
        if grep -qE "virtio-snd-pci|virtio-blk-pci,scsi=|'-vga'" ${D}${sysconfdir}/xen/domu.cfg; then
            bbfatal "qemu ${XT_DM_QEMU_VERSION} device-model incompatibility left in domu.cfg"
        fi
        ;;
    esac

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-domu.service ${D}${systemd_system_unitdir}/xl-create-domu.service
}

# domu.cfg now depends on XT_VENUS_GPU_OPTS, so switching lanes must not reuse a
# domu.cfg from sstate that still carries the other lane's device-model options.
do_install[vardeps] += "XT_VENUS_GPU_OPTS"
# Same reason for the device-model version that selects the argument fixups.
do_install[vardeps] += "XT_DM_QEMU_VERSION"

FILES:${PN} = " \
    ${sysconfdir}/xen/domu.cfg \
    ${systemd_system_unitdir}/xl-create-domu.service \
    "
