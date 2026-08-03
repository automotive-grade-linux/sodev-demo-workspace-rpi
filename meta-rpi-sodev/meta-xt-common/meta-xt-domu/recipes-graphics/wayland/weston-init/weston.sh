#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

export XDG_RUNTIME_DIR=/run/user/`id -u weston`
export WAYLAND_DISPLAY=wayland-1
