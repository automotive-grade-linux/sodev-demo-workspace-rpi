SUMMARY = "Native protoc / grpc_cpp_plugin for the trout AGL services build"
DESCRIPTION = "\
    Host-side protobuf compiler and gRPC C++ plugin, built from the same pinned \
    grpc-grpc/protobuf sources as the target binaries so the generated stubs match. \
    Installed under the Android-style names the trout CMake files expect \
    (aprotoc, protoc-gen-grpc-cpp-plugin). \
    "

DEPENDS += "go-native"

SRCREV_FORMAT = "default"

TROUT_target_install = "\
    protoc:aprotoc \
    grpc_cpp_plugin:protoc-gen-grpc-cpp-plugin \
"

require trout-common.inc

inherit native
