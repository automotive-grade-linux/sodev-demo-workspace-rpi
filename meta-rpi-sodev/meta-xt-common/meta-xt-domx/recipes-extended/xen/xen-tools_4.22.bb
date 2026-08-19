# ============================================================================
# LOCAL INTERIM RECIPE — Xen 4.22 toolstack (xen-tools)
# ============================================================================
# Sibling of xen_4.22.bb in this directory; see that file for why both live in
# meta-xt-domx rather than a board layer, and for the two differences from the
# copy being submitted upstream. In short: meta-virtualization master at 526c9725
# has xen-tools_4.19/4.20/4.21 but no xen-tools_4.22.bb, and both products pin
# PREFERRED_VERSION_xen-tools = "4.22+stable".
#
# INTERIM. To be submitted to meta-virtualization@lists.yoctoproject.org and
# DELETED from this layer once accepted upstream. Submission date: (pending).
#
# --- pre-patch audit against stable-4.22 @ d45d5687f1 ----------------------
# The two "kept verbatim" ones are NOT copied into this layer -- they are pulled
# straight from meta-virtualization's files/ via the FILESEXTRAPATHS below, so
# there is one copy of each and nothing to drift. Only the refreshed one lives
# here, and it carries a distinct file name so which copy wins never depends on
# FILESPATH ordering.
# 0001-python-pygrub-pass-DISTUTILS-xen-4.19   clean -> kept verbatim (upstream copy)
# 0001-libxl_nocpuid-fix-build-error           clean -> kept verbatim (upstream copy)
# 0001-tests-vpci-drop-explicit-g-use          context drift -> REFRESHED, and
#   carried here as 0001-tests-vpci-drop-explicit-g-use-refreshed-4.22.patch.
#   This one is `Upstream-Status: Inappropriate [oe specific]` and the explicit
#   -g is still present in 4.22, so it is still needed. It stopped applying only
#   because c6f5590c93 ("vPCI: introduce private header") added a private.h
#   prerequisite and `-include emul.h` to the $(TARGET) rule. Dropping it
#   instead of refreshing it would re-introduce the QA failure it exists to fix.
#   The refresh is recorded in the patch's own Local-Modifications: header.
# 0001-tools-libxl-Fix-build-with-NOCPUID-and-json-c   DROPPED: superseded
#   upstream by ca7906501e ("tools/libxl: Fix libxl_nocpuid.c build with
#   json-c"). 4.22's libxl_nocpuid.c already has the HAVE_LIBJSONC gen_jso stub
#   and the HAVE_LIBYAJL guard this patch was adding.
# 0001-ARM-Drop-ThumbEE-support                DROPPED: upstream 5bbe1fe413.
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

XEN_REL ?= "4.22"
XEN_BRANCH ?= "stable-4.22"

SRC_URI = " \
    git://xenbits.xen.org/xen.git;branch=${XEN_BRANCH} \
    file://0001-python-pygrub-pass-DISTUTILS-xen-4.19.patch \
    file://0001-libxl_nocpuid-fix-build-error.patch \
    file://0001-tests-vpci-drop-explicit-g-use-refreshed-4.22.patch \
    "

# Unchanged from 4.21 on purpose: `git show stable-4.22:COPYING | md5sum` is
# d1a1e216f80b6d8da95fec897d0dbec9, identical to RELEASE-4.21.0. Verified against
# stable-4.22, not assumed.
LIC_FILES_CHKSUM ?= "file://COPYING;md5=d1a1e216f80b6d8da95fec897d0dbec9"

PV = "${XEN_REL}+stable"

DEFAULT_PREFERENCE ??= "-1"

require recipes-extended/xen/xen.inc
require recipes-extended/xen/xen-tools.inc
