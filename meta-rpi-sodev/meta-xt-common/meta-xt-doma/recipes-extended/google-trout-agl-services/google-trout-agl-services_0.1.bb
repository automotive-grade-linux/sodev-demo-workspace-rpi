SUMMARY = "DomD-side gRPC backends for the Android Automotive guest"
DESCRIPTION = "\
    vehicle_hal_grpc_server and dumpstate_grpc_server: the driver-domain half of \
    the AAOS guest's VHAL and dumpstate. The guest reaches them over vsock (see \
    xt-aaos-host-services for the unit files and their vsock CIDs/ports). \
    garage_mode_helper is built alongside because the VHAL server calls it. \
    "

# clang: the trout sources are written against Android's toolchain and do not build
# clean with gcc (the -Wno-error list below is clang diagnostic names). meta-clang
# is added to this build's layers by rpi5-sodev.yaml.
TOOLCHAIN = "clang"

# Each of these corresponds to a diagnostic that a newer clang promoted to an error
# in code that predates it. Kept identical to the upstream layer so behaviour matches
# the binaries the V4H reference image ships.
TARGET_CFLAGS:append   = " -Wno-error=vla-cxx-extension"
TARGET_CXXFLAGS:append = " -Wno-error=vla-cxx-extension"
TARGET_CFLAGS:append   = " -Wno-error=array-parameter"
TARGET_CXXFLAGS:append = " -Wno-error=array-parameter"
TARGET_CFLAGS:append   = " -Wno-error=unused-but-set-variable"
TARGET_CXXFLAGS:append = " -Wno-error=deprecated-declarations"
# Added for wrynose's clang (the upstream layer's list was written against an older
# one). BoringSSL at the pinned Android-12-era revision returns `const void *` from a
# `void *` function in crypto/fipsmodule/internal.h:777, and the trout CMake files build
# with -Werror. The sources are third-party and pinned, so relaxing the diagnostic is
# preferable to patching them.
TARGET_CFLAGS:append   = " -Wno-error=incompatible-pointer-types-discards-qualifiers"
TARGET_CXXFLAGS:append = " -Wno-error=incompatible-pointer-types-discards-qualifiers"

SRCREV_FORMAT = "default"

DEPENDS += "\
    google-trout-grpc-utils-native \
    systemd \
    libxml2 \
"

TROUT_target_install = "\
    vehicle_hal_grpc_server \
    dumpstate_grpc_server \
    garage_mode_helper \
"

# The trout CMake files pass their own optimisation flags.
COMMON_OPTIMIZATION = ""

inherit perlnative python3native

require trout-common.inc

FILES:${PN} = "${bindir}/vehicle_hal_grpc_server ${bindir}/dumpstate_grpc_server ${bindir}/garage_mode_helper"
