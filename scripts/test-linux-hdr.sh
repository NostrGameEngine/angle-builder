#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { echo 'This probe requires Linux/Wayland' >&2; exit 2; }
ANGLE_DIR="${ANGLE_DIR:-$ROOT_DIR/build/angle}"
arch="$(uname -m)"; [[ "$arch" == x86_64 ]] && arch=x64; [[ "$arch" == aarch64 ]] && arch=arm64
native_dir="${ANGLE_NATIVE_DIR:-$ANGLE_DIR/out/release-linux-$arch}"
native_dir="$(realpath "$native_dir")"
[[ -f "$native_dir/libEGL.so" && -f "$native_dir/libGLESv2.so" ]] || { echo "Build ANGLE first: $native_dir" >&2; exit 2; }
for tool in pkg-config wayland-scanner "${CXX:-c++}" "${CC:-cc}" timeout; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done
pkg-config --exists wayland-client wayland-egl || { echo 'Install Wayland client development files' >&2; exit 2; }
protocol_dir="${WAYLAND_PROTOCOLS_DIR:-$(pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)}"
xml="$protocol_dir/stable/xdg-shell/xdg-shell.xml"
if [[ ! -f "$xml" ]]; then xml="$ANGLE_DIR/third_party/wayland-protocols/src/stable/xdg-shell/xdg-shell.xml"; fi
[[ -f "$xml" ]] || { echo 'Install wayland-protocols or set WAYLAND_PROTOCOLS_DIR' >&2; exit 2; }
test_dir="$ROOT_DIR/build/linux-hdr-test-$arch"
mkdir -p "$test_dir"
wayland-scanner client-header "$xml" "$test_dir/xdg-shell-client-protocol.h"
wayland-scanner private-code "$xml" "$test_dir/xdg-shell-protocol.c"
read -r -a wl_cflags <<< "$(pkg-config --cflags wayland-client wayland-egl)"
read -r -a wl_libs <<< "$(pkg-config --libs wayland-client wayland-egl)"
"${CC:-cc}" -fPIC "${wl_cflags[@]}" -c "$test_dir/xdg-shell-protocol.c" -o "$test_dir/xdg-shell-protocol.o"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -DWL_EGL_PLATFORM -I "$ANGLE_DIR/include" -I "$test_dir" \
    "${wl_cflags[@]}" "$ROOT_DIR/tests/linux-hdr-probe.cpp" "$test_dir/xdg-shell-protocol.o" \
    -L "$native_dir" -Wl,-rpath,"$native_dir" -lEGL -lGLESv2 "${wl_libs[@]}" -o "$test_dir/linux-hdr-probe"
export LD_LIBRARY_PATH="$native_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
printf 'ANGLE_NATIVE_DIR=%s\nWAYLAND_DISPLAY=%s\n' "$native_dir" "${WAYLAND_DISPLAY:-not set}"
sha256sum "$native_dir/libEGL.so" "$native_dir/libGLESv2.so"
# For compositor-side evidence use WAYLAND_DEBUG=client and retain stderr. This
# never alters advertised HDR capabilities. Set HDR_AUDIT=1 for Vulkan audit layer.
if [[ "${HDR_AUDIT:-0}" == 1 ]]; then
    "$ROOT_DIR/scripts/build-hdr-audit-layer.sh" "$test_dir"
    export VK_LAYER_PATH="$test_dir:/usr/share/vulkan/explicit_layer.d:/etc/vulkan/explicit_layer.d${VK_LAYER_PATH:+:$VK_LAYER_PATH}"
    export VK_INSTANCE_LAYERS="VK_LAYER_NGE_hdr_audit${VK_INSTANCE_LAYERS:+:$VK_INSTANCE_LAYERS}"
    log="${HDR_AUDIT_LOG:-$test_dir/hdr-audit-$(date -u +%Y%m%d-%H%M%S)-$$.log}"
    set +e
    timeout "${TEST_TIMEOUT_SECONDS:-90}" "$test_dir/linux-hdr-probe" "$@" 2>&1 | tee "$log"
    probe_status=${PIPESTATUS[0]}
    python3 "$ROOT_DIR/scripts/verify-linux-hdr-audit.py" "$log"
    audit_status=$?
    set -e
    [[ "$probe_status" == 0 ]] || exit "$probe_status"
    exit "$audit_status"
fi
exec timeout "${TEST_TIMEOUT_SECONDS:-90}" "$test_dir/linux-hdr-probe" "$@"
