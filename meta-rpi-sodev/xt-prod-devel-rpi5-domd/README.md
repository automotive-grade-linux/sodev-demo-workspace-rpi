# xt-prod-devel-rpi5-domd — vendored DomD production layer for the Raspberry Pi 5

The V4H production base carried in this workspace for the Raspberry Pi 5 DomD build
(`rpi5-sodev.yaml` lists it; `rpi4-sodev.yaml` does not, and says why). Its
`trusted-firmware-a_git.bbappend` is load-bearing: it points the TF-A recipe at the
xen-troops fork, whose Raspberry Pi 5 platform carries the OP-TEE support.

## Licenses in this layer

`LICENSE` is Apache-2.0 and every file here is under it; none carries an SPDX tag.
