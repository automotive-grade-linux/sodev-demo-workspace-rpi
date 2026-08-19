# SPDX-License-Identifier: Apache-2.0
#
# DomZ - the Zephyr guest (DomU) of the RPi5 SoDeV cockpit.
#
# Built by the moulin `domz` component (rpi5-sodev.yaml) as
#   west build -b xenvm -d build-domz-rpi5 ../domz/app
# from the zephyr-domz/ west workspace, so this application lives OUTSIDE the
# workspace on purpose: it is versioned with the rest of this repository while
# the Zephyr tree itself stays a pristine west checkout.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(domz)

target_sources(app PRIVATE src/main.c)
