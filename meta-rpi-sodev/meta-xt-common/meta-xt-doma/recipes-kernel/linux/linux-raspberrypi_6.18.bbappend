FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# vhost_xen module + vsock.cfg (driver-domain virtio backend support for AAOS).
# The DomA (AAOS) virtio rings carry grant/foreign addresses, so the DomD-side
# vhost must map guest pages via Xen grant/foreign mappings; stock 6.18 vhost
# cannot, so vsock over virtio fails and the VHAL never reaches the guest.
# Gated on enable_virtio. Stacked as a SEPARATE bbappend on top of the base
# DomD linux-raspberrypi_6.18.bbappend (which carries the vc4/V4H-Xen patchset);
# the base layer is not modified.
#
# Upstream attribution (Signed-off-by preserved verbatim inside each .patch):
#   0004-0008 = Oleksandr Tyshchenko / Dmytro Firsov (EPAM), Acked-by V. Babchuk
#   0011      = Yuya Hamamachi (Renesas)
#   0012/0013 = Yuichi Kusakabe (RPi5-specific EXPORT_SYMBOL_GPL + domid-rebind fix)
# inline-python in SRC_URI breaks wrynose's
# fetcher_hashes_dummyfunc[vardepvalue] (raw ${@...} survives unexpanded ->
# NoMethodError). Moved out of SRC_URI into anonymous python. Effective SRC_URI
# (when enable_virtio is in DISTRO_FEATURES) is unchanged.
python __anonymous() {
    if bb.utils.contains('DISTRO_FEATURES', 'enable_virtio', True, False, d):
        d.appendVar('SRC_URI', ' \
            file://vsock.cfg \
            file://xen_patchset/0004-vhost_xen-Implement-Xen-grant-mappings-module-for-vh.patch \
            file://xen_patchset/0005-vhost_xen-Get-the-guest-domid-from-Xenstore.patch \
            file://xen_patchset/0006-vhost_xen-Implement-Xen-foreign-mappings-along-with-.patch \
            file://xen_patchset/0007-vhost_xen-Adapt-net-for-Xen-specific-mappings.patch \
            file://xen_patchset/0008-vhost_xen-Change-a-logic-to-get-the-guest-domid.patch \
            file://xen_patchset/0011-vhost_xen-Fix-build-error.patch \
            file://xen_patchset/0012-vhost_xen-EXPORT_SYMBOL_GPL-for-module-use.patch \
            file://xen_patchset/0013-vhost_xen-Rebind-guest-domid-on-every-device-model-c.patch \
            file://xen_patchset/0014-vhost_xen-adversarial-hardening.patch')
}
