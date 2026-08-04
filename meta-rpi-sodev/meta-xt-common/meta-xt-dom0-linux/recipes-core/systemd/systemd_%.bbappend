# Enable the systemd-coredump PACKAGECONFIG.
#
# Without coredumpctl / systemd-coredump in the image, no core is written to
# /var/lib/systemd/coredump/ when weston hits a SEGV, so no backtrace can be
# analyzed.
#
# Enabling the `coredump` PACKAGECONFIG bundles
# `/usr/lib/systemd/systemd-coredump` and `/usr/bin/coredumpctl` into the
# systemd package, and systemd's sysctl routes kernel.core_pattern through a
# pipe to systemd-coredump, so a SEGV produces a dump with a backtrace.
#
# To inspect a dump:
#   coredumpctl list                    # list
#   coredumpctl info weston             # show backtrace
#   coredumpctl dump weston > weston.core   # extract core file
PACKAGECONFIG:append = " coredump"
