SUMMARY = "AAOS (DomA) guest kernel + vendor_boot ramdisk for SD p1"
DESCRIPTION = "\
    Places the DomA (AAOS) boot binaries into DEPLOY_DIR_IMAGE. \
    rouge (ninja image-full) grafts them onto SD p1 (FAT) as \
    aaos-android-kernel / aaos-vendor-boot-ramdisk, and Dom0's \
    xl-create-doma.service runs xl create with doma.cfg \
    (kernel=/mnt/aaos-android-kernel, ramdisk=/mnt/aaos-vendor-boot-ramdisk) \
    after mounting /mnt. \
\
    Binary provenance: \
    - kernel  = self-built GKI 6.1.118 (CONFIG_XEN=y/XEN_VIRTIO=y, from the \
      xen-troops android_kernel_manifest). CONFIG_XEN=y is required to avoid \
      the virtio-pci vp_interrupt spurious data-abort panic. \
    - ramdisk = vendor_boot ramdisk with AVB removed, all virtio modules \
      replaced, and a zero pad inserted before the bootconfig trailer so the \
      total size is a multiple of 4096 (bootconfig trailer alignment). \
\
    A layer-local copy is used (an absolute file:// path outside the workspace is \
    not buildable because the docker builder only mounts the workspace). \
    An optional md5 assertion (AAOS_KERNEL_MD5 / AAOS_RAMDISK_MD5, empty by default) \
    can pin a specific validated build via local.conf/env; see README."

# What the two staged artefacts are, for the record:
#   - the guest kernel is a GKI 6.1.118 build, i.e. the Linux kernel, so it is
#     GPL-2.0-only material. Corresponding source: the xen-troops
#     android_kernel_manifest (see README, "Building the prebuilts from source").
#   - the vendor_boot ramdisk is AOSP userspace, repacked with AVB removed and the
#     virtio modules replaced. Measured on the staged artefact (lz4 -dc | cpio -i;
#     52 MiB unpacked, 334 files / 224 symlinks / 46 dirs):
#       * lib/modules/ : 96 kernel modules. modinfo -F license gives GPL x66,
#         "GPL v2" x15, "Dual BSD/GPL" x14, "GPL and additional rights" x1 --
#         all GPL-family, as expected for Linux kernel modules.
#       * system/bin/ : 229 entries = 188 symlinks to toybox (0BSD), 17 other
#         symlinks (mkfs.ext{2,3,4} -> mke2fs, resize/defrag/dump.f2fs ->
#         fsck.f2fs, getevent/getprop/modprobe/setprop -> toolbox,
#         linker_{asan,hwasan}64 -> linker64), 23 real ELF binaries and one
#         directory (hw/). GPL-2.0-family among those 23:
#         mke2fs + e2fsdroid (e2fsprogs), fsck.f2fs + make_f2fs + sload_f2fs
#         (f2fs-tools), mkfs.erofs + fsck.erofs + dump.erofs (erofs-utils).
#         mkfs.ext{2,3,4} symlink to mke2fs; resize/defrag/dump.f2fs to fsck.f2fs.
#         The remainder is AOSP native (Apache-2.0): init, adbd, linker64,
#         toolbox, servicemanager, recovery, fastbootd, minadbd, ueventd, ...
#         Note gzip is a symlink to toybox, not GNU gzip, so no GPL-3.0 is present.
#       * system/lib64/ : 65 ELF (bionic and AOSP native).
#       * apex/, etc/, sepolicy, *_file_contexts : AOSP data.
#     Licenses above are attributed by upstream project, not by reading headers in
#     the stripped binaries, and this is one AOSP build's output -- a different
#     build can differ.
#
# So these artefacts aggregate material under at least GPL-2.0-family, Apache-2.0
# and 0BSD terms. OpenEmbedded's LICENSE field cannot be
# left unset -- bitbake defaults it to "INVALID" and base.bbclass makes that a fatal
# error -- so a value has to be chosen. "CLOSED" is the one that asserts nothing
# about which licenses apply to the aggregate or how they combine; naming a license,
# or an expression joining several, would be a statement this recipe is not in a
# position to make about binaries it does not build. Its practical effect, measured
# against a normal recipe in the same build: insane.bbclass skips LIC_FILES_CHKSUM
# validation, and license.bbclass collects no license text under
# ${LICENSE_DIRECTORY}/${PN}/ -- only a recipeinfo reading "LICENSE: CLOSED", where
# openssh in the same build gets its LICENCE plus one generic_* file per license.
# Note that the package is still listed in the image license.manifest, as
# "LICENSE: CLOSED"; that manifest is written from every installed package's LICENSE
# without filtering.
#
# Note that this repository ships neither artefact: both are .gitignore'd and staged
# by the builder (README, "Staging the AAOS prebuilts"), so nothing is redistributed
# by the repository itself. Anyone redistributing a built image is the party for whom
# the licensing of these binaries has to be determined, and the provenance recorded
# above is the input to that.
#
# For contrast, the equivalent guest-binary recipes in the AGL reference workspace
# (meta-rcar-demo domz.bb / install-files-doma.bb) declare MIT, but the binaries they
# stage are Zephyr guest images rather than a Linux kernel Image; their MIT covers
# their own glue, which is what our MIT-licensed xt-xen-cfg-* / xen-network glue
# recipes match.
LICENSE = "CLOSED"

SRC_URI = " \
    file://aaos-android-kernel-xenbuilt-6.1.118 \
    file://aaos-vendor-boot-ramdisk-xenbuilt-padded \
    "

# Optional prebuilt-integrity check (OFF by default). The DomA guest binaries are
# external, .gitignore'd, and rebuilt per AOSP/kernel tree, so their md5 is a property
# of the builder's environment, NOT of this source tree -- hardcoding a specific hash
# here would break the build for anyone staging a different (legitimate) AAOS. Left
# empty, do_deploy accepts whatever is staged (the --aaos-prebuilt bundle's MANIFEST.md5
# already covers bundle integrity). To assert a specific validated build, set these via
# local.conf / the environment; the reference values for this project's HW-verified
# coherent bundle (guest kernel + super.img vendor_dlkm both module_layout CRC
# 0xea759d7f) are documented in README, "Staging the AAOS prebuilts":
#   AAOS_KERNEL_MD5  = "c1700f50019c7a07baefa428abb3c41e"
#   AAOS_RAMDISK_MD5 = "e201569f233c3cfa20cb1fc3cdc402bf"
# (NB: the guest kernel and the super.img vendor_dlkm modules must share ONE ABI; a
# stale-kernel / fresh-super mismatch makes ~97 guest modules fail "disagrees about
# version of symbol module_layout" so AAOS never reaches SurfaceFlinger -- keep the
# whole bundle from one coherent build.)
AAOS_KERNEL_MD5 ?= ""
AAOS_RAMDISK_MD5 ?= ""

S = "${UNPACKDIR}"

inherit deploy nopackages

INHIBIT_DEFAULT_DEPS = "1"
PACKAGE_ARCH = "${MACHINE_ARCH}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install[noexec] = "1"

# Note: shell variables are referenced as $VAR (no braces) so they do not
#       collide with bitbake variable expansion (${D} etc.), and arithmetic
#       uses expr because bitbake pysh does not support $((...)).
do_deploy() {
    KSRC="${UNPACKDIR}/aaos-android-kernel-xenbuilt-6.1.118"
    RSRC="${UNPACKDIR}/aaos-vendor-boot-ramdisk-xenbuilt-padded"

    # Optional prebuilt-integrity check: only when AAOS_*_MD5 is set (default empty =
    # skip, so any staged AAOS builds). Set via local.conf/env to pin a validated build.
    if [ -n "${AAOS_KERNEL_MD5}" ]; then
        echo "${AAOS_KERNEL_MD5}  $KSRC" | md5sum -c - || \
            bbfatal "aaos kernel md5 mismatch (staged binary != AAOS_KERNEL_MD5=${AAOS_KERNEL_MD5}); unset to skip"
    fi
    if [ -n "${AAOS_RAMDISK_MD5}" ]; then
        echo "${AAOS_RAMDISK_MD5}  $RSRC" | md5sum -c - || \
            bbfatal "aaos ramdisk md5 mismatch (staged binary != AAOS_RAMDISK_MD5=${AAOS_RAMDISK_MD5}); unset to skip"
    fi

    install -m 0644 "$KSRC" "${DEPLOYDIR}/aaos-android-kernel"
    install -m 0644 "$RSRC" "${DEPLOYDIR}/aaos-vendor-boot-ramdisk"

    # Assert: the ramdisk total size must be a multiple of 4096.
    # libxl xg_dom_arm.c rounds initrd up to 4096 and advertises initrd_end,
    # but Linux only looks at the "#BOOTCONFIG\n" magic at initrd_end-12, so a
    # non-4096-multiple size hides the bootconfig trailer and androidboot.* is
    # never supplied.
    DST="${DEPLOYDIR}/aaos-vendor-boot-ramdisk"
    SZ=$(stat -c %s "$DST")
    REM=$(expr $SZ % 4096 || true)
    if [ "$REM" != "0" ]; then
        PAD=$(expr 4096 - $REM)
        if [ "$(tail -c 12 "$DST" | head -c 11)" = "#BOOTCONFIG" ]; then
            # The bootconfig trailer must be exactly at end of file, so pad is
            # inserted BEFORE the trailer (a plain tail append would shift the
            # trailer off the magic position and break it again).
            # trailer = [payload][size 4B LE][csum 4B LE]["#BOOTCONFIG\n" 12B]
            BCSZ=$(od -A n -t u4 -j $(expr $SZ - 20) -N 4 "$DST" | tr -d ' \n')
            SEC=$(expr $BCSZ + 20)
            head -c $(expr $SZ - $SEC) "$DST" > "$DST.pad"
            dd if=/dev/zero bs=$PAD count=1 >> "$DST.pad" 2>/dev/null
            tail -c $SEC "$DST" >> "$DST.pad"
            mv "$DST.pad" "$DST"
        else
            # A ramdisk without bootconfig can simply be zero-padded at the end
            dd if=/dev/zero bs=$PAD count=1 >> "$DST" 2>/dev/null
        fi
        bbwarn "aaos ramdisk auto-padded +$PAD bytes to 4096 multiple"
    fi
    SZ=$(stat -c %s "$DST")
    REM=$(expr $SZ % 4096 || true)
    [ "$REM" = "0" ] || bbfatal "aaos ramdisk size $SZ not 4096-aligned"
}
addtask deploy after do_install before do_build
