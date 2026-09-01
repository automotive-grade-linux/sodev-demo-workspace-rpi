# ============================================================================
# LOCAL INTERIM RECIPE — Xen 4.22.0 hypervisor
# ============================================================================
# meta-virtualization master at 526c9725 carries xen_4.19/4.20/4.21 only; there
# is no xen_4.22.bb. Both product configurations pin
# PREFERRED_VERSION_xen = "4.22.0+stable", so the version recipe has to exist
# somewhere -- hence this local copy.
#
# INTERIM. To be submitted to meta-virtualization@lists.yoctoproject.org and
# DELETED from this layer once accepted upstream. Submission date: (pending).
#
# WHY meta-xt-domx AND NOT A BOARD LAYER. A version recipe is not board-specific,
# and meta-xt-rpi5 and meta-xt-rpi4 are never loaded together (see the NAMING note
# at the top of rpi4-sodev.yaml). Putting it in either board layer would make it
# invisible to the other board's build, which then has no 4.22 recipe to resolve
# PREFERRED_VERSION against. meta-xt-domx is in common_yocto_layers for both
# products, so it is loaded by every component of every board -- the only place a
# single copy is visible everywhere xen or xen-tools is built. Its sibling
# xen-tools_4.22.bb lives here for the same reason, and keeping the pair together
# makes the eventual deletion one directory removal.
#
# Difference from the recipe that will be submitted upstream: only the two
# `require` lines and the FILESEXTRAPATHS block below. Upstream's copy sits next to
# xen.inc / xen-hypervisor.inc and writes the bare `require xen.inc`; this copy
# lives in another layer, so the bare form cannot resolve (bitbake searches the
# *including* file's own directory plus BBPATH -- see include_single_file() in
# bitbake's ConfHandler.py: `bbpath = dirname(parentfn) + ":" + BBPATH` -- and this
# directory has no xen.inc). The layer-root relative form below resolves because
# meta-virtualization's layer.conf does `BBPATH .= ":${LAYERDIR}"`. Its own
# `require xen-arch.inc` then resolves off its own directory, unchanged.
# When submitting upstream, restore the bare form and drop FILESEXTRAPATHS.
#
# Resolution is unambiguous only as long as meta-virtualization is the sole layer
# in these builds providing recipes-extended/xen/xen.inc -- checked against every
# layer listed in rpi5-sodev.yaml and rpi4-sodev.yaml. If another layer ever ships
# that path, bitbake takes the first BBPATH hit, so re-check when a layer is added.
#
# --- pre-patch audit against stable-4.22 @ d45d5687f1 ----------------------
# 0001-menuconfig-mconf-cfg-...        clean  -> kept
# 0001-libxl_nocpuid-fix-build-error   clean  -> kept
# 0001-ARM-Drop-ThumbEE-support        DROPPED: taken upstream as 5bbe1fe413
#   ("ARM: Drop ThumbEE support"), which is in RELEASE-4.21.0..RELEASE-4.22.0.
#   Leaving it in SRC_URI fails do_patch (double application).
#   NB: the xen_4.22.bbappend in this layer used to carry a "NOTE on ThumbEE"
#   explaining that the stock recipe supplied it; that note is now obsolete.
# ---------------------------------------------------------------------------

# The upstream xen recipe directory has to be on FILESPATH.
# FILE_DIRNAME is *this* layer, so FILESPATH covers only ./files -- but the .inc
# chain this recipe requires lives in meta-virtualization and adds its own
# file:// entries from its own files/ dir (xen-tools.inc: 10-ether.network,
# 10-xenbr0.netdev, 10-xenbr0.network), plus this recipe's own stock pre-patches.
# Without this line do_fetch dies with
#   Unable to get checksum for xen-tools SRC_URI entry 10-ether.network
# -- i.e. a recipe copied out of its home layer silently loses the file:// entries
# its own .inc chain contributes.
#
# Pointing at the upstream dir rather than copying the files here keeps a single
# source of truth: no duplicated upstream content to drift, and nothing to
# re-license. The path is derived from META_VIRT_CONFIG_PATH, which
# meta-virtualization's own layer.conf defines as
# ${LAYERDIR}/conf/distro/include/meta-virt-default-versions.inc -- so four
# dirname steps give its LAYERDIR wherever moulin checked it out.
# This whole block disappears when the recipe is submitted upstream (there it
# sits next to files/ already).
FILESEXTRAPATHS:prepend := "${@os.path.normpath(os.path.join(os.path.dirname(d.getVar('META_VIRT_CONFIG_PATH') or '/nonexistent/x/y/z'), '../../..', 'recipes-extended/xen/files'))}:"

SRCREV ?= "d45d5687f1441495f4ee20d5e9940066c5fa5beb"

XEN_REL ?= "4.22.0"
XEN_BRANCH ?= "stable-4.22"

SRC_URI = " \
    git://xenbits.xen.org/git-http/xen.git;protocol=https;branch=${XEN_BRANCH} \
    file://0001-menuconfig-mconf-cfg-Allow-specification-of-ncurses-location.patch \
    file://0001-libxl_nocpuid-fix-build-error.patch \
    "

# Unchanged from 4.21 on purpose: `git show stable-4.22:COPYING | md5sum` is
# d1a1e216f80b6d8da95fec897d0dbec9, identical to RELEASE-4.21.0. The value is
# carried over having been verified against stable-4.22, not assumed.
LIC_FILES_CHKSUM ?= "file://COPYING;md5=d1a1e216f80b6d8da95fec897d0dbec9"

PV = "${XEN_REL}+stable"

DEFAULT_PREFERENCE ??= "-1"

require recipes-extended/xen/xen.inc
require recipes-extended/xen/xen-hypervisor.inc
