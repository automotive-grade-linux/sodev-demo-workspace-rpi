COMPATIBLE_MACHINE = "raspberrypi5"
OPTEEMACHINE:raspberrypi5 ?= "rpi5"

# This is what selects 4.2.0: meta-xt-security carries 4.1.0 and 4.2.0, its
# optee.inc defaults COMPATIBLE_MACHINE to "invalid", and only the 4.2.0 bbappends
# in this directory require this file, so 4.1.0 is skipped for this MACHINE. A
# PREFERRED_VERSION written in a recipe would not do it -- bitbake reads that from
# the configuration datastore (providers.py findPreferredProvider), so a pin
# belongs in the yaml's conf, not here.
