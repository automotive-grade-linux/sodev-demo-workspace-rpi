require ${@bb.utils.contains('DISTRO_FEATURES', 'vmsep', '${BPN}-package-split.inc', '', d)}

QEMU_TARGETS = "aarch64"
# ...and its system emulator alone. get_qemu_target_list() gives every arch a
# linux-user target as well, but nothing installs qemu-aarch64 (the DomD images take
# qemu-system-aarch64; the thin Dom0 excludes both), so the user-mode binary was a
# 40 MB build for nothing. configure keeps the last --target-list it is given, and
# this append comes after the one in the recipes' body.
EXTRA_OECONF:append:class-target = " --target-list=${@get_qemu_system_target_list(d)}"
