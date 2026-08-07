# Derive the two DomA boot artifacts from the AAOS build outputs instead of taking
# them as hand-staged blobs.
#
# Why this exists
# ---------------
# DomA boots as a kernel+ramdisk pair (doma.cfg / `xl create`), so both have to be on
# SD p1. They used to be .gitignore'd files a developer copied in before the first
# build, which meant a clean clone could not build DomA at all: `--aaos=source`
# produces the p4 images but has no way to produce these two, so the build stopped at
# the boundary check.
#
# Both are mechanically derivable from what this workspace already builds:
#   kernel  = the doma_kernel component's bazel output (GKI 6.1.118 + xen-virtual-device)
#   ramdisk = the doma component's vendor_boot.img, repacked with its bootconfig
#
# ⚠ Only vendor_boot's ramdisk is used. docs/BUILD.md used to say to "concatenate the
# init_boot ramdisk with the vendor ramdisk", but that does not match the artifact the
# board actually boots: vendor_ramdisk00 already carries /init (a symlink to
# /system/bin/init) and first_stage_ramdisk/fstab.trout{,_xenvm}. Merging init_boot on
# top replaces that symlink with init_boot's generic first-stage init binary, and the
# guest then reaches /init and immediately issues `reboot bootloader` (measured on
# hardware: DomA entered shutdown 0.2 s after "Run /init as init process"). Compared
# against the known-good ramdisk, vendor_ramdisk00 alone is a superset of all 537 of
# its files -- nothing from init_boot is missing.
#
# What is still required at build time (the V4H SoDeV gets this from an Android-aware
# U-Boot at runtime; RPi5 hands Xen a kernel+ramdisk pair directly):
#   1. unpack vendor_boot.img -> vendor_ramdisk00 + bootconfig
#   2. decompress the ramdisk to cpio
#   3. drop the AVB entries from fstab.trout / fstab.trout_xenvm (vbmeta/dm-verity are
#      not used for this guest; leaving them makes first-stage init fail to mount)
#   4. repack as cpio newc with uid/gid 0 and compress with lz4 **legacy** framing --
#      ONE stream
#   5. append zero padding, then the bootconfig section and its trailer
#      ([params][size 4B LE][csum 4B LE]["#BOOTCONFIG\n"]) so the TOTAL size is a
#      multiple of 4096. libxl rounds initrd up to 4096 and Linux only looks for the
#      magic at initrd_end-12, so a non-aligned total hides the trailer and no
#      androidboot.* ever reaches the guest. (Verified on hardware: the guest logs
#      "Load bootconfig: 1187 bytes 63 nodes".)
#
# unpack_bootimg comes from the AOSP checkout (system/tools/mkbootimg); cpio's
# --owner 0:0 stands in for AOSP's mkbootfs, so no AOSP host binary is required.

# Where the two upstream components put their outputs. Defaults follow the moulin
# layout (<workspace>/android, <workspace>/android_kernel) resolved from TOPDIR, which
# is <workspace>/yocto/build-domd. Override for an out-of-tree AOSP checkout.
AAOS_SRC_TREE ??= "${TOPDIR}/../../android"
AAOS_KERNEL_TREE ??= "${TOPDIR}/../../android_kernel"

# PRODUCT_DEVICE of the AAOS product being built. A board that adds its own AOSP
# product variant (see meta-xt-doma/aosp-device/) has a different one and the product
# yaml passes it in; the default is the upstream xenvm-trout arm64 device.
AAOS_DEVICE ??= "xenvm_trout_arm64"
AAOS_PRODUCT_OUT ??= "${AAOS_SRC_TREE}/out/target/product/${AAOS_DEVICE}"
AAOS_KERNEL_IMAGE ??= "${AAOS_KERNEL_TREE}/out/deploy/common-modules/xen-virtual-device/xen_virtual_device_aarch64/Image"
AAOS_UNPACK_BOOTIMG ??= "${AAOS_SRC_TREE}/system/tools/mkbootimg/unpack_bootimg.py"

# --aaos=prebuilt escape hatch. Deriving needs the AOSP checkout (unpack_bootimg.py) and
# the bazel guest kernel, and prebuilt mode deliberately has neither -- it stages a
# bundle's six p4 images and skips the AOSP build entirely. So in that mode build.sh
# stages the bundle's two boot artifacts here and the derivation is skipped. Present =>
# use verbatim; absent => derive. Deliberately NOT in SRC_URI: a file:// entry must
# exist at do_fetch, which would make every source-mode build require them again.
AAOS_STAGED_KERNEL ??= "${THISDIR}/files/aaos-android-kernel-xenbuilt-6.1.118"
AAOS_STAGED_RAMDISK ??= "${THISDIR}/files/aaos-vendor-boot-ramdisk-xenbuilt-padded"

DEPENDS += "lz4-native cpio-native"

# unpack_bootimg.py is run as `python3`. DEPENDS on python3-native alone does NOT put a
# plain `python3` on PATH -- python3-native stages it as
# recipe-sysroot-native/usr/bin/python3-native/python3, a directory that only the
# python3native class prepends -- so the bare name would resolve to HOSTTOOLS' python3,
# i.e. whatever the host has. Inheriting the class is what makes the declared dependency
# the one that actually runs. (lz4 and cpio do land on PATH from their -native recipes:
# usr/bin/lz4 and bin/cpio.)
inherit python3native

# Reads files produced outside bitbake, so it must not be shared through sstate: a
# restored package would carry whatever the AAOS build looked like on the machine that
# populated the cache.
#
# do_deploy must be nostamp too. nostamp makes do_compile re-run, but it does NOT
# invalidate the stamps of the tasks after it, so a second build would re-derive the
# artifacts and then deploy the FIRST build's copies -- silently shipping a stale
# kernel/ramdisk, which is exactly the ABI-mismatch failure this recipe exists to avoid.
do_compile[nostamp] = "1"
do_deploy[nostamp] = "1"

python do_compile() {
    import os, re, struct, shutil, subprocess

    b = d.getVar('B')
    bb.utils.mkdirhier(b)

    # --aaos=prebuilt: use the bundle's artifacts as-is (see the AAOS_STAGED_* note above).
    sk = d.getVar('AAOS_STAGED_KERNEL')
    sr = d.getVar('AAOS_STAGED_RAMDISK')
    if os.path.exists(sk) and os.path.exists(sr):
        shutil.copyfile(sk, os.path.join(b, 'aaos-android-kernel'))
        shutil.copyfile(sr, os.path.join(b, 'aaos-vendor-boot-ramdisk'))
        bb.note("aaos-guest-binaries: using the staged prebuilt kernel (%d B) and "
                "ramdisk (%d B); derivation skipped"
                % (os.path.getsize(sk), os.path.getsize(sr)))
        return

    def need(p, what):
        if not os.path.exists(p):
            bb.fatal("%s not found at %s\n"
                     "  DomA needs the AAOS build outputs. Build them first\n"
                     "  (./build.sh -u --aaos=source, or --aaos-src=<AOSP checkout>),\n"
                     "  or point AAOS_SRC_TREE / AAOS_KERNEL_TREE at them.\n"
                     "  Running `ninja image-full` directly does NOT order the AOSP\n"
                     "  components before this build -- run `ninja doma_kernel doma`\n"
                     "  first, or use build.sh, which does it for you." % (what, p))
        return p

    out = d.getVar('AAOS_PRODUCT_OUT')
    unp = need(d.getVar('AAOS_UNPACK_BOOTIMG'), 'unpack_bootimg.py')
    kern = need(d.getVar('AAOS_KERNEL_IMAGE'), 'AAOS guest kernel (bazel Image)')
    vb = need(os.path.join(out, 'vendor_boot.img'), 'vendor_boot.img')

    work = os.path.join(d.getVar('B'), 'aaos-derive')
    bb.utils.remove(work, True)
    bb.utils.mkdirhier(work)

    def run(cmd, cwd=None, **kw):
        return subprocess.run(cmd, cwd=cwd or work, check=True, **kw)

    # 1. unpack vendor_boot (init_boot is deliberately NOT used -- see header)
    run(['python3', unp, '--boot_img', vb, '--out', 'vb'])

    # 2. decompress the vendor ramdisk to cpio
    try:
        run(['lz4', '-d', '-q', '-f', 'vb/vendor_ramdisk00', 'vendor.cpio'])
    except subprocess.CalledProcessError:
        with open(os.path.join(work, 'vendor.cpio'), 'wb') as o:
            subprocess.run(['gzip', '-dc', os.path.join(work, 'vb/vendor_ramdisk00')],
                           stdout=o, check=True)

    root = os.path.join(work, 'root')
    bb.utils.mkdirhier(root)
    with open(os.path.join(work, 'vendor.cpio'), 'rb') as i:
        # Non-root extraction cannot create device nodes; the tree is repacked with
        # explicit uid/gid 0 below and this guest's first-stage init creates what it
        # needs under /dev itself.
        subprocess.run(['cpio', '-idmu', '--quiet'], cwd=root, stdin=i, check=False)

    # /init must stay the symlink to /system/bin/init that vendor_ramdisk00 ships.
    init = os.path.join(root, 'init')
    if not os.path.islink(init):
        bb.fatal("/init in the derived ramdisk is not a symlink -- the guest will "
                 "`reboot bootloader` instead of booting (see header)")

    # 3. strip AVB from the trout fstabs only (fstab.cf.* are cuttlefish leftovers)
    for name in ('fstab.trout', 'fstab.trout_xenvm'):
        f = os.path.join(root, 'first_stage_ramdisk', name)
        if not os.path.exists(f):
            bb.warn("aaos-guest-binaries: %s absent from the vendor ramdisk" % name)
            continue
        txt = open(f).read()
        txt = re.sub(r',avb(_keys)?(=[^,\s]*)?', '', txt)
        txt = re.sub(r'(^|[\s,])avb(_keys)?(=[^,\s]*)?,?', r'\1', txt, flags=re.M)
        open(f, 'w').write(txt)

    # 4. repack (cpio newc, uid/gid 0) and compress with lz4 legacy framing
    #
    # Make the archive byte-reproducible. Without this the same inputs give a different
    # ramdisk every run (measured: three derivations of one vendor_boot.img produced
    # three md5s), because newc records per-entry dev/inode numbers and `find` walks in
    # readdir order, and cpio does not restore symlink mtimes on extraction. None of
    # that reaches the guest -- the kernel's initramfs unpacker ignores dev/ino -- but a
    # ramdisk whose bytes churn for no reason cannot be diffed against a known-good one
    # or pinned with AAOS_RAMDISK_MD5, which is the only handle a reviewer has.
    #   - sort the names: deterministic order, and lexicographic order also puts every
    #     directory ahead of its contents (a prefix sorts before its extensions)
    #   - --reproducible: zero the device numbers; --renumber-inodes: assign inodes
    #     sequentially from the (now fixed) order, preserving hardlink grouping
    #   - stamp every entry with SOURCE_DATE_EPOCH, symlinks included
    #     (follow_symlinks=False), which is what Yocto uses everywhere else
    sde = int(d.getVar('SOURCE_DATE_EPOCH') or 0)
    names = run(['find', '.', '-mindepth', '1', '-printf', '%P\\n'],
                cwd=root, capture_output=True, text=True).stdout.split('\n')
    names = sorted(n for n in names if n)
    for n in names:
        os.utime(os.path.join(root, n), (sde, sde), follow_symlinks=False)
    with open(os.path.join(work, 'merged.cpio'), 'wb') as o:
        subprocess.run(['cpio', '-o', '-H', 'newc', '--owner', '0:0',
                        '--reproducible', '--renumber-inodes', '--quiet'],
                       cwd=root, input=('\n'.join(names) + '\n').encode(),
                       stdout=o, check=True)
    run(['lz4', '-l', '-q', '-f', '-9', 'merged.cpio', 'payload.lz4'])

    # 5. bootconfig + trailer, total aligned to 4096
    pl = open(os.path.join(work, 'payload.lz4'), 'rb').read()
    bc = open(os.path.join(work, 'vb', 'bootconfig'), 'rb').read()
    tr = struct.pack('<II', len(bc), sum(bc) & 0xffffffff) + b'#BOOTCONFIG\n'
    pad = (-(len(pl) + len(bc) + len(tr))) % 4096
    blob = pl + b'\x00' * pad + bc + tr
    if len(blob) % 4096:
        bb.fatal("derived ramdisk is not 4096-aligned (%d)" % len(blob))

    open(os.path.join(b, 'aaos-vendor-boot-ramdisk'), 'wb').write(blob)
    shutil.copyfile(kern, os.path.join(b, 'aaos-android-kernel'))
    bb.note("aaos-guest-binaries: derived kernel %d B, ramdisk %d B (pad %d)"
            % (os.path.getsize(kern), len(blob), pad))
}
