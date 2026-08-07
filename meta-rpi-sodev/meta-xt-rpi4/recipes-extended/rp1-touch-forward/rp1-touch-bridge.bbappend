# SPDX-License-Identifier: MIT
# Assisted-by: Claude Code:claude-opus-4-8
# Route the touch panel to HDMI-A-1 on this board, not HDMI-A-2.
#
# WHY
# 72-rp1-touch-output.rules tags every touchscreen interface WL_OUTPUT=HDMI-A-2 because
# on the reference board AAOS/DomA lives on that output. On THIS RPi4 only HDMI-A-1 has a
# panel attached -- /sys/class/drm reads
#     card0-HDMI-A-1: connected 1920x720
#     card0-HDMI-A-2: disconnected
# -- so DomA was moved to HDMI-A-1 in weston.ini (see the note in that file). The touch
# routing has to follow, and it is NOT enough to leave it pointing at a dead output:
# weston does not fall back to the primary output when WL_OUTPUT names one that does not
# exist. weston-15.0.0 libweston/libinput-seat.c:128-138
#
#     output_name = libinput_device_get_output_name(libinput_device);
#     if (output_name) {
#         device->output_name = strdup(output_name);
#         output = output_find_by_head_name(c, output_name);   /* NULL if disconnected */
#         evdev_device_set_output(device, output);
#     } else if (!wl_list_empty(&c->output_list)) {
#         /* default assignment to an arbitrary output */      /* <- only when UNSET */
#
# takes the "arbitrary output" branch ONLY when the property is unset, and
# libweston/libinput-device.c:460 then drops every event:
#
#     if (!device->output)
#             return;
#
# So WL_OUTPUT=HDMI-A-2 on a board where HDMI-A-2 is disconnected means touch is discarded
# inside weston -- the guest sees nothing, no matter which output its surface is on. That
# is the observed symptom (display works, touch does not).
#
# WHY A BBAPPEND
# meta-xt-common is kept byte-identical to upstream in this port, so the board-specific
# output map lives here. The LIBINPUT_IGNORE_DEVICE rules for the panel's second
# REL/mouse interface and the USB force-enumerate rules are board-independent and are
# left untouched.
#
# FILE NAME: rp1-touch-bridge.bbappend, NOT rp1-touch-bridge_%.bbappend. The recipe is
# rp1-touch-bridge.bb with no version in the filename, and `_%` requires an underscore to
# match -- with the wrong name bitbake does not ignore it, it FAILS the whole parse:
#     ERROR: No recipes in default available for: .../rp1-touch-bridge_%.bbappend
#
# IF THE CABLE MOVES to the second micro-HDMI port, drop this bbappend and revert
# weston.ini together -- the two must always name the same output.

RPI4_TOUCH_OUTPUT_FROM ?= "HDMI-A-2"
RPI4_TOUCH_OUTPUT_TO ?= "HDMI-A-1"

do_install[postfuncs] += "rpi4_touch_output_retarget"
do_install[vardeps] += "RPI4_TOUCH_OUTPUT_FROM RPI4_TOUCH_OUTPUT_TO"

rpi4_touch_output_retarget:raspberrypi4-64() {
    rules="${D}${sysconfdir}/udev/rules.d/72-rp1-touch-output.rules"
    if [ ! -f "$rules" ]; then
        bbfatal "rp1-touch-bridge.bbappend (rpi4): $rules not installed"
    fi

    # Only the ENV{WL_OUTPUT}="..." assignments are rewritten; the comments above them
    # keep documenting the reference layout, and this file explains the deviation.
    from='ENV{WL_OUTPUT}="${RPI4_TOUCH_OUTPUT_FROM}"'
    to='ENV{WL_OUTPUT}="${RPI4_TOUCH_OUTPUT_TO}"'

    n_from=$(grep -cF "$from" "$rules" || true)
    n_to=$(grep -cF "$to" "$rules" || true)

    if [ "$n_from" = "0" ]; then
        if [ "$n_to" != "0" ]; then
            bbnote "rp1-touch-bridge.bbappend (rpi4): touch already routed to \
${RPI4_TOUCH_OUTPUT_TO} ($n_to rule(s))"
            return
        fi
        bbfatal "rp1-touch-bridge.bbappend (rpi4): no 'ENV{WL_OUTPUT}=' assignment for \
${RPI4_TOUCH_OUTPUT_FROM} in $rules. Upstream changed the touch routing -- re-derive the \
output map from /sys/class/drm on the board (which connector is actually attached) and \
from weston.ini (which output carries DomA) before touching this."
    fi

    sed -i "s|$from|$to|g" "$rules"

    # The routing rule that actually matters is the name-independent
    # ID_INPUT_TOUCHSCREEN one; verify it specifically rather than trusting the count.
    if ! grep -qF 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{WL_OUTPUT}="${RPI4_TOUCH_OUTPUT_TO}"' "$rules"; then
        bbfatal "rpi4_touch_output_retarget: the ID_INPUT_TOUCHSCREEN rule is not routed \
to ${RPI4_TOUCH_OUTPUT_TO} after the sed in $rules"
    fi
    if grep -qF "$from" "$rules"; then
        bbfatal "rpi4_touch_output_retarget: '${RPI4_TOUCH_OUTPUT_FROM}' still assigned \
in $rules"
    fi
    n_after=$(grep -cF "$to" "$rules")
    if [ "$n_after" != "$n_from" ]; then
        bbfatal "rpi4_touch_output_retarget: rewrote $n_from assignment(s) but found \
$n_after afterwards in $rules"
    fi
    bbnote "rp1-touch-bridge.bbappend (rpi4): touch routed to ${RPI4_TOUCH_OUTPUT_TO} \
($n_after rule(s))"
}

# Default is a no-op: this board-specific rewrite only runs on raspberrypi4-64.
rpi4_touch_output_retarget() {
    :
}

# Machine gating: rewriting WL_OUTPUT encodes a fact about THIS board -- only HDMI-A-1 has
# a panel attached. On RPi5 the upstream assignment (HDMI-A-2, the AAOS output) is correct.
# This must always name the same board and the same output as the assignment in
# weston-init.bbappend: changing only one of the two is silent, because weston discards
# every event from a device whose output does not exist, so the picture appears and touch
# does nothing.
