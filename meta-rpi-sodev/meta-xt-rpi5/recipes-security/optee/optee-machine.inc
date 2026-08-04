COMPATIBLE_MACHINE = "raspberrypi5"
OPTEEMACHINE:raspberrypi5 ?= "rpi5"

# Pin the OP-TEE version explicitly. Both 4.1.0 and 4.2.0 recipes exist in
# meta-xt-security (kept there to stay close to its upstream), and with no
# PREFERRED_VERSION bitbake would simply take the higher one -- 4.2.0 is what this
# board wants, but by accident rather than by statement. Say it, so a later 4.3.0
# landing upstream does not silently change what this board builds.
PREFERRED_VERSION_optee-os = "4.2.0"
PREFERRED_VERSION_optee-os-tadevkit = "4.2.0"
PREFERRED_VERSION_optee-client = "4.2.0"
PREFERRED_VERSION_optee-test = "4.2.0"
