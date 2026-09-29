#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS and a logged-in graphical session"
arch="$(host_arch)"
[[ "$arch" == arm64 || "$arch" == x64 ]] || fail "Unsupported macOS architecture"
native_dir="${ANGLE_NATIVE_DIR:-$ANGLE_DIR/out/release-osx-$arch}"
[[ -f "$native_dir/libEGL.dylib" && -f "$native_dir/libGLESv2.dylib" ]] || fail "Build native libraries first"
test_dir="$ROOT_DIR/build/metal-hdr-test-$arch"
mkdir -p "$test_dir"
xcrun clang++ -std=c++17 -fobjc-arc -I "$ANGLE_DIR/include" \
  "$ROOT_DIR/tests/metal-hdr-probe.mm" -L "$native_dir" -lEGL -lGLESv2 \
  -Wl,-rpath,"$native_dir" -framework AppKit -framework Metal -framework QuartzCore \
  -o "$test_dir/metal-hdr-probe"
# ANGLE's dylib install names may be relative to the native library directory.
(cd "$native_dir" && "$test_dir/metal-hdr-probe")
