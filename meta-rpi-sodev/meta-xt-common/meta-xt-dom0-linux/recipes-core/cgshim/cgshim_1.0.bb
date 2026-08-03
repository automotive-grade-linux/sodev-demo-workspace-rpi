DESCRIPTION = "clock_gettime LD_PRELOAD shim for the DomD qemu device-model. \
On RPi5 dom0less direct-map DomD the aarch64 vDSO clock_gettime spins forever on \
a stuck seqcount (userspace busy-loop: /proc state=R, syscall=running, wchan=0), \
hanging qemu in cpu_enable_ticks so it never reaches state=running and libxl \
SIGKILLs it (rc=137). This shim overrides clock_gettime to issue the raw syscall \
(svc #0), bypassing the broken vDSO. Freestanding (no libc dependency) so it loads \
under any glibc. Wired into qemu via LD_PRELOAD in the DomD qemu wrapper."

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/Apache-2.0;md5=89aea4e17d99a7cacdbeed46a0096b10"

SRC_URI = "file://cgshim.c"
S = "${UNPACKDIR}"

# Freestanding aarch64 shared object: raw svc syscall, no libc/glibc dependency.
do_compile() {
    ${CC} -shared -fPIC -nostdlib -O2 -o cgshim.so ${S}/cgshim.c
}

do_install() {
    install -d ${D}${libdir}
    install -m 0755 cgshim.so ${D}${libdir}/cgshim.so
}

FILES:${PN} = "${libdir}/cgshim.so"

# Unversioned freestanding .so shipped in the runtime package (LD_PRELOAD target),
# built without standard libs: silence the corresponding QA checks.
INSANE_SKIP:${PN} = "dev-so ldflags textrel"
