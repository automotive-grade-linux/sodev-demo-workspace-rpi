# Version-agnostic xen-tools overlay.
#
# The build resolves xen-tools to xen-tools_4.22.bb (PV "4.22+stable", SRCREV
# d45d5687f1, branch stable-4.22), selected via
# PREFERRED_VERSION_xen-tools = "4.22+stable" in rpi5-sodev.yaml. [4.22] That
# recipe is an INTERIM LOCAL copy in this layer, not the stock
# meta-virtualization one -- master (526c9725) stops at xen-tools_4.21.bb. The
# toolstack patch series is carried by the sibling xen-tools_4.22.bbappend here
# (no xen-troops _git fork recipe is used). This `_%` bbappend is intentionally
# version-agnostic so the RDEPENDS:remove below applies to whichever xen-tools
# version is selected (the local _4.22 recipe today, the stock _4.21 one before,
# or a _git fork if the pin were changed) -- which is why it needs no rename.
# Two base RDEPENDS break the dom0-thin THIN
# control domain, which deliberately EXCLUDES qemu and python3 from its rootfs:
#
#   - xen-tools.inc RDEPENDS:${PN} += QEMU_SYSTEM_RDEPENDS (qemu-system-*)
#     -> handled via rpi5-sodev.yaml linux_domain_conf
#        (QEMU_SYSTEM_RDEPENDS:pn-xen-tools = ""), so it is reproducible from the yaml.
#   - xen-tools.inc RDEPENDS:${PN} pulls python3 -> python3-core, but dom0-thin
#     excludes python3/python3-core/python3-modules -> dnf
#     "xen-tools requires python3-core ... filtered out by exclude filtering".
#
# Mirror the scarthgap xen-troops fix (meta-xt-rpi5 xen-tools_git.bbappend:
# `RDEPENDS:${PN}:remove:class-target = " ${PYTHON_PN}-core"`) so it also applies
# to the 4.22 recipe. The python tooling (pygrub etc.) is not used by the
# dom0-thin control domain (xl + xenstore are the active bits; guests are
# dom0less / DomD-hosted). DomD installs qemu explicitly and pulls only the
# xen-tools-* sub-packages it needs, so this :remove on the meta-package is safe.
RDEPENDS:${PN}:remove:class-target = " python3-core python3"
