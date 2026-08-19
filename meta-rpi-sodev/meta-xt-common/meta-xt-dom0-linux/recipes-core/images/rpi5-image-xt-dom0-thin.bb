SUMMARY = "Thin Dom0 image (control plane only)"
DESCRIPTION = "\
    Thin Dom0 carrying only the control plane: \
    - control plane (xl, xenstored, xenconsoled) \
    - boot-time vCPU pinning (xt-rpi5-domain) \
    - guest creation via the xl-create-*.service units (xt-xen-cfg-*) \
    - GPU stack (mesa, weston) excluded = handled by DomD \
    - qemu virtio backend excluded = handled by DomD \
    - Python/rpm/opkg excluded for a production-sized image"

LICENSE = "Apache-2.0"

IMAGE_FSTYPES = "cpio.gz"

# xen-tools-flask is deliberately NOT in IMAGE_INSTALL: the XSM policy is not
# module-loaded during this demo's boot (the hypervisor's own
# xenpolicy-raspberrypi5 is deployed separately to the boot partition), so it is
# not needed in the Dom0 rootfs.
#
# [4.22] The *other* reason the 4.21 revision of this comment gave -- "xenpolicy
# is claimed by no package, so xen-tools-flask is empty and dnf fails with
# 'No match for argument: xen-tools-flask'" -- NO LONGER HOLDS, and the comment
# has been corrected rather than version-bumped. Measured on 4.22 in build-dom0
# (the build that assembles this image, where PACKAGECONFIG includes xsm):
#   FILES:xen-tools-flask = "/boot/xenpolicy-*"      <- claimed, and version-agnostic
#   package/boot/xenpolicy-4.22.0                    <- produced
#   packages-split/xen-tools-flask                   <- 20K, NOT empty
# So adding it back would build today. It stays out on the "not needed" ground
# above only. If XSM enforcing is ever wanted in the Dom0 rootfs, just add
# xen-tools-flask to IMAGE_INSTALL -- no packaging fix is required any more.
# (In build-domd xsm is not in PACKAGECONFIG, so no policy is built there at all.)
IMAGE_INSTALL = " \
    packagegroup-core-boot \
    base-files \
    busybox \
    udev \
    kmod \
    bash \
    iproute2 \
    iputils \
    openssh-sshd \
    openssh-sftp-server \
    openssh-ssh \
    openssh-scp \
    openssh-sftp \
    xen \
    xen-tools \
    xen-tools-xl \
    xen-tools-xencommons \
    xen-tools-xenstore \
    xen-tools-xenstored \
    xen-tools-xentrace \
    xen-tools-scripts-block \
    xen-tools-scripts-network \
    xen-network \
    xt-rpi5-domain \
    xt-linux-dom0-guests \
    dom0-domd-vif \
    kernel-module-bridge \
    ${CORE_IMAGE_EXTRA_INSTALL} \
    "

# bridge.ko is required by the vif-bridge script that libxl runs when a vif is
# attached; without it the backend setup fails with "Unknown device type".
# No netfilter modules are installed: this image ships no iptables/nft userspace,
# so they could not be configured, and PC<->Dom0 traffic is routed (not NAT'd)
# through DomD -- see dom0-domd-vif-up.

# Exclude GPU stack + qemu + dev tools (those run in DomD)
PACKAGE_EXCLUDE = " \
    mesa mesa-megadriver \
    libgles2-mesa libegl-mesa libgles2 libegl \
    weston weston-init weston-examples \
    wayland wayland-protocols \
    qemu qemu-system-aarch64 qemu-system-arm \
    qemu-aarch64 qemu-edid qemu-img qemu-io qemu-nbd \
    qemu-pr-helper qemu-storage-daemon \
    virglrenderer libsdl2 \
    python3 python3-core python3-modules \
    rpm dnf opkg \
    "

INITRAMFS_MAXSIZE = "262144"
IMAGE_ROOTFS_SIZE = "8192"

BAD_RECOMMENDATIONS += "busybox-syslog mesa weston"
NO_RECOMMENDATIONS = "1"

IMAGE_LINGUAS = ""

inherit core-image

# Allow root login on the serial console. Dom0 boots with console=hvc0 and the
# Xen physical-console "DOM0" mux lands on hvc0; without an empty/known root
# password the default image locks root (root:*:) and the getty login fails.
# (DomD image uses the same posture via the same IMAGE_FEATURES.)
IMAGE_FEATURES:append = " empty-root-password allow-empty-password allow-root-login"


ROOTFS_POSTPROCESS_COMMAND += "flatten_dom0_network; enable_hvc0_getty; mask_legacy_qdisk_backend; fix_dom0_hostname; linux_dom0_guest_disks; "

# [DOM0_OS=linux] The shared guest cfgs (domu.cfg/doma.cfg, from xt-xen-cfg-domu/
# -doma) point qemu's -drive at /dev/mmcblk0p3 / p4 — correct for the zephyr
# flavour where DomD owns the SD via SDHCI passthrough. In the linux flavour Dom0
# owns the SD and xl-attach-disks.service (xt-linux-dom0-guests) block-attaches
# p3->xvdb / p4->xvdc into the dom0less DomD, so the DomD-side qemu must open the
# xvd* nodes. Rewrite the Dom0-thin copies only (the DomD-rootfs copies, used by
# the zephyr flavour, are built from a different image and are untouched). Guarded
# on file presence so a guest-less / DomU-only build is a no-op.
linux_dom0_guest_disks() {
    if [ -f ${IMAGE_ROOTFS}${sysconfdir}/xen/domu.cfg ]; then
        sed -i 's#file=/dev/mmcblk0p3#file=/dev/xvdb#' ${IMAGE_ROOTFS}${sysconfdir}/xen/domu.cfg
    fi
    if [ -f ${IMAGE_ROOTFS}${sysconfdir}/xen/doma.cfg ]; then
        sed -i 's#file=/dev/mmcblk0p4#file=/dev/xvdc#' ${IMAGE_ROOTFS}${sysconfdir}/xen/doma.cfg
    fi
}

# base-files.bbappend (meta-xt-domx) appends "-${XT_DOM_NAME}" to the hostname,
# but this image is built from the DomD builder (single consolidated build dir,
# XT_DOM_NAME = "domd"), so Dom0 would ship the DomD hostname. Pin it here.
fix_dom0_hostname() {
    echo "${MACHINE}-dom0" > ${IMAGE_ROOTFS}${sysconfdir}/hostname
}

# xen-qemu-dom0-disk-backend.service (from the meta-virtualization xen-tools
# packaging) exec's /usr/bin/qemu-system-i386, which this thin Dom0 does not
# ship. It is a leftover from the qdisk approach: the demo attaches the guest
# disks with `xl block-attach ... phy:` (kernel blkback), so no Dom0 qemu disk
# backend is needed. On hardware (log audit) the unit failed every
# boot with 203/EXEC. Mask it instead of shipping a qemu just to satisfy it.
mask_legacy_qdisk_backend() {
    ln -sf /dev/null         ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/xen-qemu-dom0-disk-backend.service
}

# Dom0 console is hvc0 (bootargs: console=hvc0), but the machine's SERIAL_CONSOLES
# only stages a getty for ttyAMA10, so the Xen physical-console "DOM0" mux has no
# login prompt and Dom0 is unreachable from the UART. Enable serial-getty@hvc0
# explicitly so Dom0 gets a login prompt on hvc0 (login: root, empty password).
# (Mirrors the DomD RAM-initramfs recipe, which enables the same getty. That image
# is no longer in the boot flow but is still in the tree as a recovery starting
# point -- see its header. The
# shipping DomD p2 rootfs deliberately does NOT: nothing attaches a PV console to a
# dom0less DomD, and the getty cost 45 s of DefaultTimeoutStartSec every boot.)
enable_hvc0_getty() {
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants
    ln -sf /lib/systemd/system/serial-getty@.service \
        ${IMAGE_ROOTFS}/etc/systemd/system/getty.target.wants/serial-getty@hvc0.service
}

# Flat L2 management bridge (DomD owns the single xenbr0 = 192.168.10.10). The
# thin Dom0 has no physical NIC (RP1 ethernet was passed through to DomD); its
# only link is the Dom0<->DomD point-to-point vif1.0, which dom0-domd-vif-up
# brings up at 192.168.0.1 (DomD netfront end = 192.168.0.11, routed — NOT
# bridged into xenbr0; the flat 192.168.10.0/24 segment lives inside DomD). So
# Dom0 must NOT run its own bridge/NAT and must NOT claim a physical-NIC IP:
#  - a static address on a physical NIC would collide with DomD's xenbr0 .10;
#  - a Dom0-side xenbr0 is worse than dead: `[Match] Type=ether` matches vif1.0,
#    so networkd enslaves the Dom0<->DomD vif into the bridge and
#    dom0-domd-vif-up can no longer address vif1.0 directly.
#
# Two packages install such configuration and BOTH have to be undone:
#   xen-network (this project)        -> xenbr0.netdev, 50-xenbr0.network
#   xen-tools-net-conf (xen-tools,    -> 10-xenbr0.netdev, 10-xenbr0.network,
#     pulled in transitively by the      10-ether.network
#     xen-tools meta-package)
# The 10-* set is the one that actually shipped: verified by listing
# /etc/systemd/network/ in the built rootfs, which contained exactly those three
# files. Missing them left Dom0 creating xenbr0 and bridging every ether link --
# precisely the failure described above. Any change here must be re-verified by
# listing that directory in the built image; it is expected to be empty.
flatten_dom0_network() {
    rm -f ${IMAGE_ROOTFS}/etc/systemd/network/xenbr0.netdev
    rm -f ${IMAGE_ROOTFS}/etc/systemd/network/50-xenbr0.network
    rm -f ${IMAGE_ROOTFS}/etc/systemd/network/10-xenbr0.netdev
    rm -f ${IMAGE_ROOTFS}/etc/systemd/network/10-xenbr0.network
    rm -f ${IMAGE_ROOTFS}/etc/systemd/network/10-ether.network
    rm -f ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd.service.d/xenbr0-systemd-networkd.conf
    # Fail loudly rather than shipping a Dom0 that bridges its own vif: any file
    # left here is a network config this function does not know about.
    if [ -n "$(ls -A ${IMAGE_ROOTFS}/etc/systemd/network 2>/dev/null)" ]; then
        bbfatal "thin Dom0: unexpected files left in /etc/systemd/network:" \
                "$(ls -A ${IMAGE_ROOTFS}/etc/systemd/network | tr '\n' ' ')"
    fi
    install -d ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service.d
    cat > ${IMAGE_ROOTFS}/etc/systemd/system/systemd-networkd-wait-online.service.d/systemd-networkd-wait-online.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
EOF
}

