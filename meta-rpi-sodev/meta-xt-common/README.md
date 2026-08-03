# meta-xt-common #

Vendored from <https://github.com/xen-troops/meta-xt-common> (Apache-2.0) and
modified for the RPi5 SoDeV port. Changes against the upstream tree:

- `meta-xt-dom0` renamed to `meta-xt-dom0-linux`
- `meta-xt-control-domain` removed (unused on this board)
- `meta-xt-dom0-zephyr` added (Zephyr thin Dom0 patch series)
- `meta-xt-doma` added (Android Automotive guest layer)
- `recipes-extended/xen-common/` added: the Xen patch series shared by the
  hypervisor and toolstack recipes, which live in different layers

These layers are hardware- and product-independent; they provide common
facilities that may be used by any xt-based product.

`meta-xt-security/` comes from the same upstream tree, pinned at commit
`3f17cfe7a644`; its OP-TEE recipes originate at Arm (`meta-arm`, MIT) and reached
here via xen-troops. It is **not** byte-identical to that commit: 9 of its 21 files
carry the wrynose port and nothing else. Eight are mechanical OE 6.0 (wrynose) migrations --
`LAYERSERIES_COMPAT` `scarthgap` to `wrynose` plus a `LAYERDEPENDS` line in
`conf/layer.conf`, dropping the now-default `S = "${WORKDIR}/git"`, and
`${WORKDIR}` to `${UNPACKDIR}` for recipe-fetched files -- and the ninth adds an
`Origin:` block to `optee-os/0003-optee-enable-clang-support.patch`. Diff against
the pinned commit to see the whole delta.

Only the `_4.2.0` recipes are buildable on this board -- `optee.inc` sets
`COMPATIBLE_MACHINE ?= "invalid"` and the RPi5 override is supplied by
`meta-xt-rpi5/recipes-security/optee/*_4.2.0.bbappend`, so the 4.1.0 recipes are
never parsed for `MACHINE=raspberrypi5`. They are kept so the layer stays close to
upstream and can be rebased without conflicts.

Those layers *may* be added and used manually, but they were written
with [Moulin](https://moulin.readthedocs.io/en/latest/) build system,
as Moulin-based project files provide correct entries in local.conf

List of layers:

* meta-xt-dom0-linux - recipes for *"thin"* Dom0, which does not have
  access to HW and is booted from ramdisk. Main idea behind such thin
  Dom0 is to move all HW-dependend code into separate domain, that
  theoretically can be rebooted in runtime, without rebooting the
  whole platform.

* meta-xt-domu - recipes for generic user domain. This is
  unprivileged domain that generally have no access to real hardware.

* meta-xt-domx - shared recipes that can be used by any domain
  type.

* meta-xt-driver-domain - recipes for driver domain. This domain have
  access to real hardware and provides PV backends for other domain
  types, so they, say, can access network on display something on
  screen. Ideally, this layer can be applied either on top of Dom0, or
  on top of separate DomD.

* meta-xt-dom0-zephyr - recipes + patch series for a Zephyr-based thin
  control Dom0 (the SoDeV RPi5 hybrid; DOM0_OS=zephyr). The control
  domain creates the other domain types during boot.

* meta-xt-doma - recipes for an Android Automotive OS (AAOS) guest
  domain (DomA), gated by ENABLE_ANDROID.

* meta-xt-security - OP-TEE / secure-world recipes.

* meta-xt-qemu - recipes for any domain, which wants to install and run
  the recent version of QEMU.