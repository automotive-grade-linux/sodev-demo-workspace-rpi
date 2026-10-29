# Pair the frontend snapshot with the SDK's Dart runtime.
do_install:append:class-native() {
    sdk="${D}${datadir}/flutter/sdk"
    snapshot="$sdk/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot"
    if [ "${BUILD_ARCH}" = aarch64 ] && [ -f "$snapshot" ]; then
        install -Dm0644 "$snapshot" \
            "$sdk/bin/cache/artifacts/engine/linux-arm64/frontend_server_aot.dart.snapshot"
    fi
}
