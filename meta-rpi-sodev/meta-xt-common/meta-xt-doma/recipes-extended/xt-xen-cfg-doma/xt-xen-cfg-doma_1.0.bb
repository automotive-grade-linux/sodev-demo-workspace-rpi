SUMMARY = "Xen runtime cfg for the DomA (AAOS) guest (xl create)"
DESCRIPTION = "\
    /etc/xen/doma.cfg + doma.dtb + xl-create-doma.service, plus the \
    DomA-augmented /etc/xen/domd.cfg (adds xvdc=p4 = the AAOS super.img to the \
    DomD config). DomA is created before DomU so the DomD vhost_xen module \
    latches the correct guest domid. Boot order is encoded in the unit files. \
    "

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://doma.cfg \
    file://domd.cfg \
    file://doma.dts \
    file://xl-create-doma.service \
    file://doma-devmodel-sweep.sh \
    "

S = "${UNPACKDIR}"

inherit systemd

DEPENDS = "dtc-native"

SYSTEMD_SERVICE:${PN} = "xl-create-doma.service"
SYSTEMD_AUTO_ENABLE = "enable"

# The unit's ExecStart/ExecStartPre chain needs `xl` and the xenstore CLI; the sweep
# script additionally uses awk and grep, which busybox provides.
RDEPENDS:${PN} = "xen-tools-xl xen-tools-xenstore"

# Which Raspberry Pi 5 SKU this image is for. Set from the moulin BOARD_RAM
# parameter through the domd builder's conf: meta-xt-doma is in that builder's
# layers, and doma.cfg ships in the DomD image because DomD runs the toolstack.
# The default matches moulin's own default so a standalone bitbake still works.
BOARD_RAM ??= "16g"

# Board layers whose SKUs are not the Pi 5's 16g/8g set this to DomA's size in MiB
# and the BOARD_RAM map in do_install is not consulted. Empty means "use the map".
DOMA_MEM_MiB ??= ""

do_compile() {
    dtc -I dts -O dtb -o ${WORKDIR}/doma.dtb ${UNPACKDIR}/doma.dts
}

do_install() {
    install -d ${D}${sysconfdir}/xen
    install -m 0644 ${UNPACKDIR}/doma.cfg ${D}${sysconfdir}/xen/doma.cfg
    install -m 0644 ${UNPACKDIR}/domd.cfg ${D}${sysconfdir}/xen/domd.cfg

    # DomA's size is board-dependent. On the 8 GB SKU the four domains have to fit
    # 7680 MiB, and DomD cannot absorb the whole reduction alone: DomD 2048 was
    # measured to leave the DomA device model unable to serve a 4 GiB guest (AAOS
    # crash-looped in binder while DomD itself still had 1.3 GiB free and was never
    # OOM-killed). 3072/3072 keeps the same total and boots all four domains. The
    # measurement and its history are in doma.cfg next to this value.
    # A board whose SKUs are not 16g/8g sets DOMA_MEM_MiB and bypasses the map
    # entirely. meta-xt-rpi4 does: the Raspberry Pi 4 SKUs are 8g and 4g, and its
    # 8 GiB budget puts DomA at a different size than the Pi 5's, so neither the
    # sizes nor the SKU names carry over. The map below stays literal because
    # tools/check-memory-map.py cross-checks these numbers against its own budget
    # table for the Pi 5.
    if [ -n "${DOMA_MEM_MiB}" ]; then
        doma_mem="${DOMA_MEM_MiB}"
    else
        case "${BOARD_RAM}" in
            16g) doma_mem=4096 ;;
            8g)  doma_mem=3072 ;;
            *)   bbfatal "BOARD_RAM must be 8g or 16g (got '${BOARD_RAM}'), or the board layer must set DOMA_MEM_MiB" ;;
        esac
    fi
    # Fail loudly rather than ship the placeholder: `xl create` rejects a
    # non-numeric `memory`, so DomA would simply never start -- and the same
    # applies if a future edit renames the token.
    if ! grep -q '^memory = DOMA_MEM_PLACEHOLDER$' ${D}${sysconfdir}/xen/doma.cfg; then
        bbfatal "DOMA_MEM_PLACEHOLDER not found in doma.cfg"
    fi
    # $doma_mem, not ${doma_mem}: inside a bitbake shell function ${...} is bitbake's
    # own expansion, and doma_mem is a shell local. It happens to survive today only
    # because bitbake leaves unknown names untouched -- a bitbake variable of that
    # name appearing later would silently substitute the wrong value.
    sed -i "s/^memory = DOMA_MEM_PLACEHOLDER\$/memory = $doma_mem/" \
        ${D}${sysconfdir}/xen/doma.cfg

    install -d ${D}/usr/lib/xen/boot
    install -m 0644 ${WORKDIR}/doma.dtb ${D}/usr/lib/xen/boot/doma.dtb

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/xl-create-doma.service ${D}${systemd_system_unitdir}/xl-create-doma.service

    # ExecStartPre of xl-create-doma.service. A script rather than an inline Exec
    # line because the awk field reference needs a backslash-escaped `$`, which
    # systemd rejects with "Ignoring unknown escape sequences".
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/doma-devmodel-sweep.sh ${D}${libexecdir}/doma-devmodel-sweep
}

# doma.cfg now depends on BOARD_RAM, so switching SKUs must not reuse a doma.cfg
# from sstate that still carries the other board's `memory` value. The same reason
# BOARD_RAM is in xt-rpi-u-boot-scr's do_compile[vardeps].
do_install[vardeps] += "BOARD_RAM"
# Same reason, for the board-layer override that bypasses the BOARD_RAM map.
do_install[vardeps] += "DOMA_MEM_MiB"

FILES:${PN} = " \
    ${sysconfdir}/xen/doma.cfg \
    ${sysconfdir}/xen/domd.cfg \
    /usr/lib/xen/boot/doma.dtb \
    ${systemd_system_unitdir}/xl-create-doma.service \
    ${libexecdir}/doma-devmodel-sweep \
    "
