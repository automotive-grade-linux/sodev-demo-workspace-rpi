# SPDX-License-Identifier: Apache-2.0
SUMMARY = "Tiny SDL2 + OpenGL ES2 demo for DomU VirtIO-GPU validation"
DESCRIPTION = "Renders a rotating RGB triangle on a Wayland surface using SDL2."
LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = " \
    file://sdl2-demo.c \
    file://sdl2-demo.service \
"

S = "${UNPACKDIR}"

DEPENDS = "libsdl2 virtual/libgles2 virtual/egl"
RDEPENDS:${PN} = "libsdl2 mesa-megadriver"

inherit systemd

SYSTEMD_SERVICE:${PN} = "sdl2-demo.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o sdl2-demo ${UNPACKDIR}/sdl2-demo.c \
        -lSDL2 -lGLESv2 -lm
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 sdl2-demo ${D}${bindir}/sdl2-demo

    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/sdl2-demo.service ${D}${systemd_unitdir}/system/sdl2-demo.service
}

FILES:${PN} = " \
    ${bindir}/sdl2-demo \
    ${systemd_unitdir}/system/sdl2-demo.service \
"
