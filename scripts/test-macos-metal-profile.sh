#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"
[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
arch="$(host_arch)"
profile="${ANGLE_METAL_PROFILE:-gles30}"
[[ "$profile" == gles30 || "$profile" == gles31 ]] || fail "ANGLE_METAL_PROFILE must be gles30 or gles31"
native_dir="${ANGLE_NATIVE_DIR:-$ANGLE_DIR/out/release-osx-$arch}"
if [[ -z "${ANGLE_NATIVE_DIR:-}" && "$profile" == gles31 ]]; then
  native_dir="$ANGLE_DIR/out/release-osx-$arch-gles31"
fi
[[ -f "$native_dir/libEGL.dylib" && -f "$native_dir/libGLESv2.dylib" ]] || fail "Build native libraries first"
test_dir="$ROOT_DIR/build/metal-profile-test-$arch"
mkdir -p "$test_dir"
xcrun clang++ -std=c++17 -fobjc-arc -I "$ANGLE_DIR/include" \
  "$ROOT_DIR/tests/metal-profile-probe.mm" -L "$native_dir" -lEGL -lGLESv2 \
  -Wl,-rpath,"$native_dir" -framework Foundation \
  -o "$test_dir/metal-profile-probe"
(cd "$native_dir" && MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
  "$test_dir/metal-profile-probe" "$profile")
if [[ "$profile" == gles31 ]]; then
  MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 python3 "$ROOT_DIR/tests/metal-graphics-image-probe.py" \
    --native-dir "$native_dir"
  MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 python3 "$ROOT_DIR/tests/metal-image-alias-probe.py" \
    --native-dir "$native_dir"
fi
