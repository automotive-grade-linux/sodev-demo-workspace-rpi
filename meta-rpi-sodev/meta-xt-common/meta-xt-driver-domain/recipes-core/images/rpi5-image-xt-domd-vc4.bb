SUMMARY = "DomD VC4 graphics driver domain image for RPi5 + Xen"
DESCRIPTION = "Linux DomD image for the disaggregated cockpit. DomD owns vc4-drm \
(V3D + HVS + HDMI + mailbox) and runs weston, started by the stock systemd \
weston.service as on the V4H reference implementation, as the sole graphics \
compositor with the gl-renderer / Mesa V3D path. Hosts the thin \
qemu-system-aarch64 device-model (spawned by xl devd) for DomU/DomA virtio-pci \
surface compositing onto HDMI. \
\
This ext4 image is the SHIPPING DomD rootfs: it is written to SD p2 and mounted \
directly by the dom0less DomD (root=/dev/mmcblk0p2 in the zephyr flavour, or \
root=/dev/xvda over PV-block in the linux flavour, where Dom0 owns the SD). The \
older RAM-initramfs boot path is available in the git history if a RAM-root \
the tree for recovery but is no longer part of the boot flow."

# Base: meta-xt-rpi5 minimal DomD image (= driver domain xen-tools subset)
require recipes-core/images/rpi5-image-minimal-domd.bb

#
# Graphics stack (weston + mesa + V3D / vc4-drm)
#
GFX_PACKAGES = " \
    mesa \
    libdrm \
    libdrm-tests \
    weston \
    weston-init \
    weston-examples \
    wayland \
    wayland-protocols \
    kmscube \
"

#
# DomU surface compositing.
#   - The full `qemu` meta-package is not installed: DomD only needs the thin
#     qemu-system-aarch64 (installed by rpi5-image-xt-domd-v4h.bb), which has
#     the virtio-gpu qdisk/block backend built in. The device-model is spawned
#     by xl devd (xendriverdomain).
#   - virglrenderer is required for virtio-gpu-gl rendering, so it is kept.
#   - The shipping compositor uses weston's kiosk-shell (app-id output routing,
#     see weston.ini); the ivi-shell stack (wayland-ivi-extension + DisplayManager)
#     was an earlier, never-completed prototype and is not installed.
#
DOMU_GFX_PACKAGES = " \
    virglrenderer \
"

#
# Kernel modules required for vc4-drm aggregate bind.
# CONFIG_DRM_VC4 is =m (so Dom0 can blacklist it), which means DomD must
# explicitly install kernel-module-vc4.
#
KMOD_PACKAGES = " \
    kernel-module-vc4 \
    kernel-module-v3d \
    kernel-module-drm-shmem-helper \
    kernel-module-gpu-sched \
    kernel-module-i2c-brcmstb \
"

#
# General debug tools.
# NOTE: the VRAM/stripe-noise diagnostics (xt-vram-tools + its python3 /
# python3-pillow runtime) were moved to the opt-in meta-rpi-sodev-devel layer.
#
DEBUG_PACKAGES = " \
    openssh \
    htop \
    strace \
    tcpdump \
"

#
# Driver-domain runtime that used to live only in the RAM initramfs image.
# Now that this ext4 image IS the DomD rootfs, everything the running driver
# domain needs has to be here:
#   - xen-network-flatbridge : the SSH-reachability design (flat L2 bridge,
#                              domd-sshd-fix, static eth0). xen-network alone
#                              only carries the base network units.
#   - domd-toolstack-prep    : seeds the Zephyr xenstore (cpupool name,
#                              xenconsoled domid), creates /var/lib/xen and
#                              /var/log/xen/console and runs the console seeder.
#                              xl-create-doma/domu.service have
#                              Requires=domd-toolstack-prep.service.
#   - dnsmasq / socat        : DomA DHCP lease and DomA console relay.
#   - haveged                : the A76 has no hwrng / FEAT_RNG, so early
#                              getrandom would block `ssh-keygen -A`; this
#                              jitter-entropy daemon seeds the CRNG quickly.
#   - bash                   : the qemu wrapper installed below is #!/bin/bash.
#   - libsdl2                : qemu -display sdl,gl=on.
#   - rp1-touch-bridge       : forwards the RP1 touch controller to the guests.
#   - kernel-module-bridge   : xenbr0 (CONFIG_BRIDGE=m).
#   - kernel-module-pwm-fan  : cooling-device of the cpu_thermal zone.
#   - openssh-sftp-server    : scp/sftp onto DomD.
#   - logrotate              : /var/log and /var/log/xen are persistent now (see
#                              install_persistent_var_log), so they need rotating.
#
DOMD_RUNTIME_PACKAGES = " \
    xt-domd-vc4-init \
    domd-toolstack-prep \
    xen-network-flatbridge \
    dnsmasq \
    socat \
    haveged \
    bash \
    iproute2 \
    iputils \
    openssh-sshd \
    openssh-sftp-server \
    logrotate \
    libsdl2 \
    rp1-touch-bridge \
    kernel-module-bridge \
    kernel-module-pwm-fan \
    mesa-megadriver \
    libegl-mesa \
    libglvnd \
"

# The DomU xl config is only installed when the DomU is actually built: the moulin
# domd conf sets XT_DOMU_CFG_INSTALL="xt-xen-cfg-domu" for ENABLE_DOMU=yes and ""
# otherwise, so a guest-less build does not pull an unbuildable provider.
XT_DOMU_CFG_INSTALL ??= ""

# Same gate for DomZ (the Zephyr RTOS domain): the moulin domd conf sets
# XT_DOMZ_CFG_INSTALL="xt-xen-cfg-domz" for ENABLE_DOMZ=yes and "" otherwise.
# xt-xen-cfg-domz carries an auto-enabled
# xl-create-domz.service, so a DomZ-less build must not ship it.
XT_DOMZ_CFG_INSTALL ??= ""

# Dev-convenience posture, matching the V4H SoDeV reference (see the security note
# in the top-level README before deploying outside a closed lab).
IMAGE_FEATURES:append = " empty-root-password allow-empty-password allow-root-login ssh-server-openssh"

IMAGE_INSTALL:append = " \
    ${GFX_PACKAGES} \
    ${DOMU_GFX_PACKAGES} \
    ${KMOD_PACKAGES} \
    ${DEBUG_PACKAGES} \
    ${DOMD_RUNTIME_PACKAGES} \
    ${XT_DOMU_CFG_INSTALL} \
    ${XT_DOMZ_CFG_INSTALL} \
"

BAD_RECOMMENDATIONS += "busybox-syslog"

# weston.service is enabled under graphical.target.wants, not
# multi-user.target.wants. Override SYSTEMD_DEFAULT_TARGET (poky default
# "multi-user.target") so the built-in set_systemd_default_target() rootfs
# postprocess wires /etc/systemd/system/default.target -> graphical.target and
# weston auto-starts on boot.
SYSTEMD_DEFAULT_TARGET = "graphical.target"

#
# systemd-coredump is enabled for weston SEGV analysis
# (via PACKAGECONFIG coredump in systemd_%.bbappend).
#

#
# rootfs size: weston + mesa + qemu + virglrenderer, plus the driver-domain
# runtime that moved here from the initramfs. 6 GiB, which still fits the 9216 MiB
# p2 slot that rouge writes with resize: false.
#
IMAGE_ROOTFS_SIZE = "6291456"

# Make /var/log a real directory on p2 BEFORE anything else populates it.
#
# A rw rootfs is not sufficient on its own: poky's base-files ships /var/log as a
# symlink to volatile/log (VOLATILE_LOG_DIR defaults to yes), so /var/log lands on
# the /var/volatile tmpfs and journald keeps using only its runtime journal under
# /run/log/journal. Verified on hardware: with Storage=persistent alone the boot
# journal still reported "Runtime Journal (/run/log/journal/...)" and no System
# Journal, i.e. logs were still lost on reboot.
#
# This must run FIRST among the postprocess steps. install_v4h_sodev_bits_ext4
# creates /var/log/xen; if the symlink were still in place at that point, that
# mkdir would land in ${IMAGE_ROOTFS}/var/volatile/log/xen -- shadowed by the
# /var/volatile tmpfs at runtime -- and replacing the symlink afterwards would then
# discard it, leaving no /var/log/xen in the shipped image at all.
#
# /var/volatile stays mounted for the other users that expect it.
ROOTFS_POSTPROCESS_COMMAND =+ "install_persistent_var_log;"
install_persistent_var_log() {
    if [ -L ${IMAGE_ROOTFS}/var/log ]; then
        rm -f ${IMAGE_ROOTFS}/var/log
    fi
    install -d -m 0755 ${IMAGE_ROOTFS}/var/log
    install -d -m 2755 ${IMAGE_ROOTFS}/var/log/journal

    # The journal now survives every boot, so cap it.
    install -d ${IMAGE_ROOTFS}/etc/systemd/journald.conf.d
    cat > ${IMAGE_ROOTFS}/etc/systemd/journald.conf.d/50-domd-size.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=128M
SystemMaxFileSize=16M
EOF

    # /var/log/xen is likewise persistent now, and nothing rotates it: `xl devd`
    # writes xl-<dom>.log and qdisk-N.log per guest, and domd-console-seeder.sh
    # restarts xenconsoled once per newly seen domain on every boot, so each boot
    # adds guest-console files carrying the full AAOS boot console. On the RAM
    # initramfs this could not accumulate. Cap it the same way.
    install -d ${IMAGE_ROOTFS}${sysconfdir}/logrotate.d
    # NB: the whole block is indented, including the closing brace. bitbake ends a
    # shell function at the first `}` in column 1, so an unindented brace inside a
    # heredoc truncates the function and the following EOF becomes a parse error
    # ("unparsed line: 'EOF'"). logrotate does not care about the indentation.
    cat > ${IMAGE_ROOTFS}${sysconfdir}/logrotate.d/xen <<'EOF'
  /var/log/xen/*.log /var/log/xen/console/*.log {
      rotate 3
      size 8M
      missingok
      notifempty
      copytruncate
      compress
  }
EOF
}

# native-style FAN control: ensure the pwm-fan cooling-device driver is loaded.
# The DomD DT cooling_fan(pwm-fan) is the cooling-device of the cpu_thermal
# thermal-zone (kernel-managed FAN). CONFIG_SENSORS_PWM_FAN=m; force it via
# systemd-modules-load (pwm-fan EPROBE_DEFERs until the RP1 PWM is up, then
# binds). bcm2711_thermal / THERMAL_OF are =y (auto-bound).
ROOTFS_POSTPROCESS_COMMAND += "install_pwm_fan_modload;"
install_pwm_fan_modload() {
    install -d ${IMAGE_ROOTFS}/etc/modules-load.d
    echo "pwm_fan" > ${IMAGE_ROOTFS}/etc/modules-load.d/pwm-fan.conf
}

# libxl__spawn_qdisk_backend() in libxl_dm.c execve's QEMU_XEN_PATH, which is
# hardcoded at xen-tools configure time; on aarch64 the real binary is
# /usr/bin/qemu-system-aarch64. Without the shim the qdisk backend spawn fails
# with execve ENOENT and libxl times out with "Qdisk backend not ready".
# Two paths must be covered because the configure default differs between our
# recipes:
#   - /usr/lib/xen/bin/qemu-system-i386 : fork xen-tools libexec default.
#   - /usr/bin/qemu-system-i386         : stock meta-virtualization xen-tools 4.21
#                                         (--with-system-qemu).
# This was confirmed on hardware: /var/log/xen/qdisk-N.log showed "libxl: cannot
# execute /usr/bin/qemu-system-i386: No such file or directory" and the DomA/DomU
# device-model spawn failed; adding the symlink live on the board made the DomA
# qemu spawn and AAOS boot. The shim is therefore required on ARM, despite the
# i386 name.
ROOTFS_POSTPROCESS_COMMAND += "install_qemu_xen_path_shim;"
install_qemu_xen_path_shim() {
    install -d ${IMAGE_ROOTFS}/usr/lib/xen/bin
    if [ ! -e ${IMAGE_ROOTFS}/usr/lib/xen/bin/qemu-system-i386 ]; then
        ln -sf /usr/bin/qemu-system-aarch64 \
            ${IMAGE_ROOTFS}/usr/lib/xen/bin/qemu-system-i386
    fi
    if [ ! -e ${IMAGE_ROOTFS}/usr/bin/qemu-system-i386 ]; then
        ln -sf /usr/bin/qemu-system-aarch64 \
            ${IMAGE_ROOTFS}/usr/bin/qemu-system-i386
    fi
}

# Additional V4H DomD compatibility packages
IMAGE_INSTALL:append = " kernel-module-tun xen-tools-devd xen-tools-xencommons xen-tools-xenstore xt-rpi5-domain cgshim"

#
# Driver-domain runtime postprocess. This is the single owner of the DomD
# systemd fixups now that the initramfs image is out of the boot path.
#
ROOTFS_POSTPROCESS_COMMAND += "install_v4h_sodev_bits_ext4; "

install_v4h_sodev_bits_ext4() {
    # 1. qemu wrapper.
    # Under DISTRO_FEATURES += vmsep, DomD cannot read another domain's
    # /local/domain/<id>/name due to xenstore VM separation. libxl starts the
    # device-model with `-name domain-<domid>` (not `-name DomU`). weston
    # kiosk-shell routes the output by app-id (SDL_VIDEO_WAYLAND_WMCLASS), so a
    # WMCLASS of domain-<id> mismatches the weston.ini app-ids (DomA/DomU) and
    # the guest screen is not routed to any output. The wrapper recovers the
    # guest identity from argv (DomA = Android guest: argv contains an
    # android_vm virtual console chardev; otherwise DomU). No machine
    # translation is needed (qemu TYPE_XEN_ARM "xenpv" matches libxl's -M xenpv).
    if [ -e ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64 ] && \
       [ ! -e ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64.bin ]; then
        mv ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64 \
           ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64.bin
        cat > ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64 <<'EOF'
#!/bin/bash
REAL_QEMU="/usr/bin/qemu-system-aarch64.bin"
name=""
prev=""
for i in "$@"; do
    if [ "$prev" = "-name" ]; then name="$i"; fi
    prev="$i"
done
wmclass="$name"
case "$name" in
    domain-*)
        if printf '%s\n' "$@" | grep -q 'android_vm'; then
            wmclass="DomA"
        else
            wmclass="DomU"
        fi
        ;;
esac
export SDL_VIDEO_WAYLAND_WMCLASS="$wmclass"
# Force clock_gettime through the raw syscall (cgshim.so), bypassing the
# aarch64 vDSO seqcount spin that hangs this device-model qemu in cpu_enable_ticks.
export LD_PRELOAD=/usr/lib/cgshim.so
exec "${REAL_QEMU}" "$@"
EOF
        chmod 0755 ${IMAGE_ROOTFS}/usr/bin/qemu-system-aarch64
    fi

    # 2. xendriverdomain.service drop-ins
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/xendriverdomain.service.d
    cat > ${IMAGE_ROOTFS}/etc/systemd/system/xendriverdomain.service.d/99-debug.conf <<'EOF'
[Service]
Type=simple
StandardOutput=journal+console
StandardError=journal+console
ExecStartPre=/bin/mkdir -p /var/log/xen /var/run/xen/device-model
ExecStart=
ExecStart=/usr/sbin/xl devd -F
EOF

    # 3. /var/log/xen + /var/run/xen/device-model pre-create
    install -d ${IMAGE_ROOTFS}/var/log/xen
    install -d ${IMAGE_ROOTFS}/var/run/xen/device-model

    # 4. Three notification services (block/bridge/weston-up status ready).
    # As on V4H DomD, they write drivers/<name>/status ready in xenstore; the
    # guest-creation units poll those nodes before calling xl create.
    install -d ${IMAGE_ROOTFS}/usr/lib/systemd/system
    cat > ${IMAGE_ROOTFS}/usr/lib/systemd/system/block-up-notification.service <<'EOF'
[Unit]
Description=Block device ready notification
Wants=-.mount xenstored.service
After=-.mount xenstored.service

[Service]
Type=simple
ExecStart=/usr/bin/xenstore-write drivers/block/status ready
RemainAfterExit=yes
ExecStopPost=/usr/bin/xenstore-write drivers/block/status dead
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    # bridge-up-notification.service is NOT generated here: it is packaged and
    # auto-enabled by the xen-network recipe (SYSTEMD_SERVICE:${PN}). Writing a
    # second copy under /usr/lib and symlinking it would orphan the packaged one.
    cat > ${IMAGE_ROOTFS}/usr/lib/systemd/system/weston-notification.service <<'EOF'
[Unit]
Description=Weston ready notification
# BindsTo (not just Wants/After): After= is satisfied when weston.service reaches
# ANY terminal state, failed included, and Wants= does not propagate failure. With
# only Wants/After this unit published "ready" even when the compositor had died,
# and xl-create-doma/domu -- which poll exactly this node -- then created guests
# whose device-models could not connect to /run/wayland-0. The retired PID-1
# launcher gated the same write on the wayland socket actually existing, so this
# was a fail-safe gate turned fail-open. BindsTo also stops this unit when weston
# stops, which is what makes the ExecStopPost below able to run.
BindsTo=weston.service
After=weston.service xenstored.service
Wants=xenstored.service

[Service]
Type=simple
# Only publish once the socket weston.socket advertises is really there.
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do [ -S /run/wayland-0 ] && exit 0; sleep 1; done; echo "/run/wayland-0 never appeared"; exit 1'
ExecStart=/usr/bin/xenstore-write drivers/weston-up/status ready
RemainAfterExit=yes
ExecStopPost=/usr/bin/xenstore-write drivers/weston-up/status dead
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # 5. Enable the two image-generated notification services via symlink
    #    (bridge-up-notification is enabled by its own package).
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/block-up-notification.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/block-up-notification.service
    ln -sf /usr/lib/systemd/system/weston-notification.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/multi-user.target.wants/weston-notification.service

    # 6. xendriverdomain.service.d/hack-xdg_runtime_dir.conf drop-in.
    # The qemu device-models that `xl devd` spawns render with -display sdl,gl=on
    # and must reach weston's socket. weston.socket publishes the global socket at
    # ${runtimedir}/wayland-0 = /run/wayland-0, so XDG_RUNTIME_DIR=/run plus
    # WAYLAND_DISPLAY=wayland-0 resolves to exactly that path. (The V4H reference
    # instead hardcodes /run/user/1000 + wayland-1, which upstream itself labels a
    # temporary hack because it assumes the weston uid; the global socket needs no
    # such assumption.)
    # V3D_DEBUG=db enables Mesa V3D TLB store double-buffering (overlap TLB store
    # of a tile with rasterization of the next on non-MSAA jobs; correctness-safe).
    # It is a per-process env, so it is set here so the device-models inherit it --
    # the dominant render load is the guest draw, not weston compositing. weston
    # itself gets it from its own 95-v3d-env.conf drop-in.
    cat > ${IMAGE_ROOTFS}/etc/systemd/system/xendriverdomain.service.d/hack-xdg_runtime_dir.conf <<'EOF'
[Service]
Environment="XDG_RUNTIME_DIR=/run"
Environment="WAYLAND_DISPLAY=wayland-0"
Environment="SDL_VIDEODRIVER=wayland"
Environment="V3D_DEBUG=db"
EOF

    # 7. Mask services that must not run on DomD.
    # xen-init-dom0.service      : skipped by its own control_d check (no mask needed)
    # xen-init-dom0less.service  : dom0less xenstore tree init = Dom0 only
    # xen-qemu-dom0-disk-backend : Dom0 qemu disk backend = Dom0 only
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/xen-init-dom0less.service
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/xen-qemu-dom0-disk-backend.service
    # The xenstore SERVER is Dom0 (Zephyr zephyr-xenlib xenstore_srv, or the thin
    # Linux Dom0's xenstored). DomD must be a xenstore CLIENT (xenbus via STORE_PFN)
    # and must never run its own daemon: its xenstored.service is gated on
    # `grep control_d /proc/xen/capabilities` and fails today on the non-control
    # DomD, but once the dom0less DomD is granted control caps it would START and
    # DOUBLE the xenstore -> corruption. xenconsoled is likewise a Dom0-role daemon
    # (Requires=xenstored). Mask both; the xenstore CLIENT CLI (xen-tools-xenstore)
    # and xendriverdomain (`xl devd`) stay enabled.
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/xenstored.service
    ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/xenconsoled.service
    # NB: getty@tty1 / getty@tty7 are deliberately NOT masked here. The stock
    # weston.service owns its VT properly (TTYPath=/dev/tty7 with TTYReset /
    # TTYVHangup / TTYVTDisallocate), so there is nothing to arbitrate: masking is
    # only needed by a compositor started outside systemd's TTY management, and
    # neither poky's own weston image nor the V4H reference masks them. Masking them
    # here would also break the build: `systemctl preset-all`, which
    # systemd_handle_machine_id runs at rootfs time, exits non-zero on a masked
    # TEMPLATE INSTANCE such as getty@tty1.service (the four plain xen units masked
    # above only produce a tolerated warning).

    # 8. Serial gettys: keep only the one whose port actually exists in DomD.
    #
    # DomD's console is the Xen vpl011, which the kernel registers as ttyAMA0 --
    # measured on hardware, the only line is `console [ttyAMA0] enabled`, and
    # serial-getty@ttyAMA0 comes up and serves. Two other gettys used to be wired in
    # and both cost 90 s of boot each, because getty.target waits on their .device
    # units and neither device can ever appear:
    #   - serial-getty@hvc0: /dev/hvc0 never appears. A dom0less DomD gets the
    #     vpl011, not the Xen PV console, so there is no hvc device to serve.
    #   - serial-getty@ttyAMA10: enabled by poky from SERIAL_CONSOLES, which names
    #     the RPi5 SoC's own debug UART. DomD does not own that UART -- it is Xen's,
    #     and DomD sees only the emulated vpl011.
    # Symptom in the journal: `Expecting device /dev/hvc0...` at t+2 s, then at
    # t+92 s `Timed out waiting for device` and `Dependency failed for Serial Getty
    # on hvc0` / `on ttyAMA10`, with multi-user.target held back until then.
    # Drop both enablement symlinks (the units stay installed, just not wanted).
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants/serial-getty@hvc0.service
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA10.service
    ln -sf /lib/systemd/system/serial-getty@.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

    # 9. sshd config + privsep directories. Host keys are NOT shipped (a community
    # repo must not contain private keys); `ssh-keygen -A` in domd-sshd-fix.service
    # (xen-network-flatbridge) generates them, and haveged seeds the CRNG so that
    # generation does not block on this hwrng-less A76. Unlike the initramfs, this
    # root is persistent, so the keys are generated once and then survive reboots.
    install -d -m 0755 ${IMAGE_ROOTFS}/etc/ssh
    install -d -m 0755 ${IMAGE_ROOTFS}/var/empty

}

# In the thin-Linux flavour the toolstack is DOM0's, not DomD's: Dom0 runs xenstored,
# attaches the guest disks (xl-attach-disks.service) and creates DomU/DomA itself. The
# three DomD-side units below therefore have no job, and leaving them enabled is not
# harmless in either direction:
#
#   * domd-toolstack-prep seeds a Zephyr xenstore that does not exist here. Measured on
#     hardware 2026-08-03: it failed, was restarted five times, then gave up
#     ("Start request repeated too quickly"), filling the Xen console with
#     `(XEN) DOM1: [FAILED] Failed to start DomD toolstack preparation for the
#     Zephyr-Dom0 topology` and `[DEPEND] Dependency failed for Launch DomU/DomA`.
#   * the DEPEND failures are what kept DomD's own xl-create-{domu,doma} from running,
#     which is the ONLY reason the boot came up correctly. Satisfying the requirement
#     instead -- e.g. with the no-op stub meta-xt-dom0-linux ships into the DOM0 rootfs
#     for exactly this reason -- would let DomD race Dom0 to create the same domains.
#
# So mask all three rather than stub them: masked units neither fail nor run. The units
# stay installed (the image content is flavour-independent); only the enablement changes,
# which is the same approach used for the serial-getty units above.
# Which Dom0 the image is being built alongside. The default MUST match the moulin
# default: without it an unset DOM0_OS expands to the empty string, which is not
# "zephyr", and the masks below would fire on a standalone `bitbake
# rpi5-image-xt-domd-vc4` -- silently shipping a DomD that never creates the guests
# in the flavour where it is supposed to. Same default as xt-rpi-u-boot-scr.bbappend.
DOM0_OS ??= "zephyr"

ROOTFS_POSTPROCESS_COMMAND += "mask_zephyr_toolstack_units; "
mask_zephyr_toolstack_units() {
    if [ "${DOM0_OS}" = "zephyr" ]; then
        return
    fi
    install -d ${IMAGE_ROOTFS}/etc/systemd/system
    for u in domd-toolstack-prep.service xl-create-domu.service xl-create-doma.service; do
        # A unit that is not installed in this configuration (e.g. xl-create-doma when
        # ENABLE_ANDROID=no) needs no mask, and masking it would leave a dangling
        # symlink that `systemctl` reports as a bogus masked unit.
        if [ -e ${IMAGE_ROOTFS}${systemd_system_unitdir}/$u ]; then
            ln -sf /dev/null ${IMAGE_ROOTFS}/etc/systemd/system/$u
            bbnote "masked $u (DOM0_OS=${DOM0_OS}: Dom0 owns the toolstack)"
        fi
    done
}

# The masks above are DOM0_OS-dependent, so a flavour switch must not reuse a rootfs
# built for the other one. Same reason DOM0_OS is in domd-vc4's do_compile[vardeps].
do_rootfs[vardeps] += "DOM0_OS"

#
# Note: the DomD is an xl-created guest, so boot files (start4.elf,
# fixup4.dat, bootcode.bin, u-boot, etc.) are not needed. However,
# rpi5-image-minimal-domd.bb requires trusted-firmware-a etc. via
# do_image[depends], which is inherited (build once and sstate caches it).
