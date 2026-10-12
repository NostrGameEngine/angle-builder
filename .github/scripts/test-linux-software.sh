#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$ROOT_DIR/test-results/linux-software}"
WESTON_BINARY="${WESTON_BINARY:-weston}"
WESTON_SHELL="${WESTON_SHELL:-kiosk-shell.so}"
mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(realpath "$RESULTS_DIR")"
for tool in "$WESTON_BINARY" vulkaninfo python3 timeout; do
    command -v "$tool" >/dev/null || { echo "Missing test dependency: $tool" >&2; exit 2; }
done

# Select the CPU ICD explicitly. Never require /dev/dri or a physical HDR display.
icd=""
for candidate in /usr/share/vulkan/icd.d/lvp_icd.json \
                 "/usr/share/vulkan/icd.d/lvp_icd.$(uname -m).json"; do
    if [[ -f "$candidate" ]]; then icd="$candidate"; break; fi
done
[[ -n "$icd" ]] || { echo 'Mesa lavapipe ICD not installed' >&2; exit 2; }
export VK_DRIVER_FILES="$icd" VK_ICD_FILENAMES="$icd"
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=2
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
unset VK_INSTANCE_LAYERS VK_LAYER_PATH VK_ADD_LAYER_PATH VK_LOADER_LAYERS_ENABLE
unset ANGLE_FEATURE_OVERRIDES_ENABLED ANGLE_FEATURE_OVERRIDES_DISABLED

runtime="$(mktemp -d "${TMPDIR:-/tmp}/angle-software.XXXXXX")"
export XDG_RUNTIME_DIR="$runtime" XDG_CACHE_HOME="$runtime/cache"
mkdir -p "$XDG_CACHE_HOME"
weston_pid=""
stop_weston() {
    if [[ -n "$weston_pid" ]]; then
        kill "$weston_pid" 2>/dev/null || true
        for ((attempt=0; attempt<50; ++attempt)); do
            kill -0 "$weston_pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$weston_pid" 2>/dev/null; then kill -KILL "$weston_pid" 2>/dev/null || true; fi
        wait "$weston_pid" 2>/dev/null || true
        weston_pid=""
    fi
}
cleanup() {
    stop_weston
    rm -rf -- "$runtime"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
report() {
    printf '%s\n' "$*" | tee -a "$RESULTS_DIR/summary.txt"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}
start_weston() {
    local mode="$1" color_management="$2"
    export WAYLAND_DISPLAY="angle-$mode"
    cat > "$runtime/weston-$mode.ini" <<INI
[core]
color-management=$color_management
idle-time=0
[shell]
locking=false
panel-position=none
background-color=0xff202020
INI
    "$WESTON_BINARY" --backend=headless --renderer=gl --shell="$WESTON_SHELL" --width=640 --height=360 \
        --socket="$WAYLAND_DISPLAY" --config="$runtime/weston-$mode.ini" \
        --log="$RESULTS_DIR/weston-$mode.log" > "$RESULTS_DIR/weston-$mode.stderr" 2>&1 &
    weston_pid=$!
    for ((attempt=0; attempt<100; ++attempt)); do
        if ! kill -0 "$weston_pid" 2>/dev/null; then
            cat "$RESULTS_DIR/weston-$mode.log" "$RESULTS_DIR/weston-$mode.stderr" >&2
            return 1
        fi
        [[ ! -S "$runtime/$WAYLAND_DISPLAY" ]] || return 0
        sleep 0.1
    done
    echo 'Headless Weston did not become ready' >&2
    return 1
}
run_probe() {
    local mode="$1"
    shift
    HDR_AUDIT=1 HDR_AUDIT_LOG="$RESULTS_DIR/$mode-audit.log" \
        WAYLAND_DEBUG=client bash "$ROOT_DIR/scripts/test-linux-hdr.sh" "$@" \
        > "$RESULTS_DIR/$mode-probe.log" 2>&1
}

: > "$RESULTS_DIR/summary.txt"
"$WESTON_BINARY" --version | tee "$RESULTS_DIR/weston-version.txt"
report 'Physical HDR output: NOT TESTED (CPU rendering and headless compositor).'
start_weston sdr false
timeout 30 vulkaninfo --summary > "$RESULTS_DIR/vulkan-summary.txt" 2>&1
grep -q 'PHYSICAL_DEVICE_TYPE_CPU' "$RESULTS_DIR/vulkan-summary.txt" || {
    echo 'The test did not select a CPU Vulkan device' >&2; exit 1;
}

# Requiring HDR on a genuinely SDR-only compositor must report unavailable.
status=0
run_probe sdr --require-hdr || status=$?
if [[ "$status" != 77 ]]; then
    cat "$RESULTS_DIR/sdr-probe.log" >&2
    echo "Expected SDR-only exit 77, got $status" >&2
    exit 1
fi
grep -q 'LINUX_HDR_SUMMARY hdr_pass=0 hdr_skip=2 sdr=PASS' "$RESULTS_DIR/sdr-probe.log"
grep -q 'AUDIT_SUMMARY phases=3 hdr_phases=0' "$RESULTS_DIR/sdr-probe.log"
report 'PASS: SDR rendering, invalid colorspace rejection, and explicit HDR unavailability.'
stop_weston

# Older distribution compositors need not support the stable color protocol.
version="$(sed -nE 's/^weston ([0-9]+)\..*/\1/p' "$RESULTS_DIR/weston-version.txt")"
[[ "$version" =~ ^[0-9]+$ ]] || { echo 'Cannot determine Weston version' >&2; exit 1; }
if (( version < 15 )); then
    report 'SKIP: HDR presentation requires a Weston version with stable color management.'
    exit 0
fi
start_weston hdr true

# Determine expectations independently of ANGLE. An ANGLE regression must fail,
# not turn into a successful skip just because EGL stopped advertising HDR.
timeout 30 vulkaninfo > "$RESULTS_DIR/vulkan-wayland.txt" 2>&1
python3 - "$RESULTS_DIR/vulkan-wayland.txt" > "$RESULTS_DIR/hdr-requirements.txt" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(errors='replace')
surfaces = re.findall(r'Surface type = (\S+)', text)
if not surfaces or any(surface != 'VK_KHR_wayland_surface' for surface in surfaces):
    raise SystemExit('Expected an isolated Vulkan Wayland surface query')
pairs = set(re.findall(r'format = (\S+)\s+colorSpace = (\S+)', text))
requirements = []
if ('FORMAT_R16G16B16A16_SFLOAT', 'COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT') in pairs:
    requirements.append('--require-scrgb')
if any((fmt, 'COLOR_SPACE_HDR10_ST2084_EXT') in pairs for fmt in (
        'FORMAT_A2B10G10R10_UNORM_PACK32', 'FORMAT_A2R10G10B10_UNORM_PACK32')):
    requirements.append('--require-hdr10')
print(' '.join(requirements))
PY
read -r -a requirements < "$RESULTS_DIR/hdr-requirements.txt"
if (( ${#requirements[@]} == 0 )); then
    report 'SKIP: the software Vulkan/Wayland stack advertises no usable scRGB or HDR10 pair.'
    exit 0
fi
status=0
run_probe hdr "${requirements[@]}" || status=$?
if [[ "$status" != 0 ]]; then
    cat "$RESULTS_DIR/hdr-probe.log" >&2
    echo "Advertised software HDR presentation failed: exit $status" >&2
    exit 1
fi
grep -E '^(PHASE_PASS|LINUX_HDR_SUMMARY|AUDIT_SUMMARY)' "$RESULTS_DIR/hdr-probe.log"
report "PASS: advertised software HDR modes (${requirements[*]}), native-buffer readback, HDR-to-SDR transitions, and Vulkan presentation audit."
