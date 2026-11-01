# SPDX-License-Identifier: MIT
FILESEXTRAPATHS:prepend := "${THISDIR}/weston:"

# kiosk-shell dereferences a NULL output after an output is destroyed and
# recreated, and weston (the compositor both guests' device models draw into)
# dies with SIGSEGV. Measured on the RPi4 board 2026-09-23: the Onlap1102I panel
# drops HPD for ~0.6 s about 7 s after weston sets 1280x720 on HDMI-A-1 (every
# 1280x720 boot, never at 1920x1080 or 1920x720), weston destroys and recreates
# the output, kiosk-shell leaves DomA's window with shsurf->output == NULL while
# appid_output_assigned stays true, and the next touch runs
# kiosk_shell_surface_activate() -> kiosk_shell_output_raise_surface_subtree(NULL).
# Three core dumps, the same backtrace each time; qemu then aborted and DomA's
# panel stayed black. Upstream fixed exactly this on main (daef679), which is in
# neither 15.0.0 nor 16.0.0, so both versions carry it.
SRC_URI += "file://0001-kiosk-shell-guard-against-NULL-output-during-hotplug.patch"

# For a video decoder's SAND128 buffer that a client hands to weston to show directly on an overlay plane:
# 0002: gl-renderer aborted (SIGABRT) when v3d optimised the YUV uniform away for
#       NV12 SAND imported as Y + UV -- weston, the qemu display and AAOS went down.
# 0003: drm_fb_compatible_with_plane matched modifiers exactly, so SAND128 with its
#       column-height parameter never went onto the plane (GL composition instead).
# The 15.0.0 and 16.0.0 sources differ around both spots, hence one pair per major version.
WESTON_SAND_PATCHES = "${@ \
    'file://0002-gl-renderer-do-not-abort-when-the-YUV-uniform-is-optimised-away.patch ' \
    'file://0003-backend-drm-match-Broadcom-SAND-modifiers-without-the-column-height.patch' \
    if d.getVar('PV').startswith('15.') else \
    'file://0002-gl-renderer-do-not-abort-when-the-YUV-uniform-is-optimised-away-w16.patch ' \
    'file://0003-backend-drm-match-Broadcom-SAND-modifiers-without-the-column-height-w16.patch'}"
SRC_URI += "${WESTON_SAND_PATCHES}"

# 16.0.0 only: a head whose EDID cannot be parsed (none read while HDMI hot-plug flaps)
# supported no color format, and the next repaint aborted in kms-color.c on the
# output's default AUTO color format (seen on the Raspberry Pi 4 board). 15.0.0 has no
# color-format handling.
SRC_URI += "${@'' if d.getVar('PV').startswith('15.') else 'file://0004-backend-drm-allow-the-AUTO-color-format-without-an-EDID-w16.patch'}"
