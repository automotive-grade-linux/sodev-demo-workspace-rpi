# networkd and resolved are required by the DomD network design: systemd-networkd
# creates and owns xenbr0 from /etc/systemd/network/xenbr0.netdev, and resolved
# provides the stub resolver DomD offers the guests.
PACKAGECONFIG:append = " networkd"
PACKAGECONFIG:append = " resolved"

# Demote OE's dynamic uid/gid consistency check to a warning. systemd creates
# several system users (systemd-network, systemd-resolve, ...) without pinned
# ids, and this build does not pin them either; a hard error would only be
# correct for an image that guarantees stable ids across rebuilds.
USERADD_ERROR_DYNAMIC = "warn"
