FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

# weston.sh sets XDG_RUNTIME_DIR for a login shell in a virtio guest, where
# weston runs as a non-root user whose uid is allocated at image build time.
# It is gated on the enable_virtio DISTRO_FEATURE. `SRC_URI:append:enable_virtio`
# would NOT work: enable_virtio is a DISTRO_FEATURE, not an OVERRIDE, so the
# append never fires and the file is never fetched.
SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' file://weston.sh', '', d)}"
FILES:${PN} += "${@bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', ' ${sysconfdir}/profile.d/weston.sh', '', d)}"

do_install:append() {
    # Disable weston's idle timeout. The guests are watched rather than touched
    # for minutes at a time, and the default 300 s idle would DPMS-off the output.
    # This is the only weston-init append in the tree that does it, so no
    # idempotency guard is needed.
    sed -i -e "/^\[core\]/a idle-time=0" ${D}${sysconfdir}/xdg/weston/weston.ini

    if [ -e ${UNPACKDIR}/weston.sh ]; then
        install -d ${D}/${sysconfdir}/profile.d
        install -m 0755 ${UNPACKDIR}/weston.sh ${D}/${sysconfdir}/profile.d/weston.sh
    fi
}
