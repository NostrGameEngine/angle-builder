#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"
[[ "$(host_os)" == macos && "$(host_arch)" == arm64 ]] || fail "Requires an Apple Silicon Mac"
profile="${ANGLE_METAL_PROFILE:-gles31}"
unavailable="${ANGLE_EXPECT_GLES31_UNAVAILABLE:-0}"
boot_timeout="${ANGLE_SIMULATOR_BOOT_TIMEOUT:-600}"
[[ "$profile" == gles30 || "$profile" == gles31 ]] || fail "ANGLE_METAL_PROFILE must be gles30 or gles31"
[[ "$unavailable" == 0 || "$unavailable" == 1 ]] || fail "ANGLE_EXPECT_GLES31_UNAVAILABLE must be 0 or 1"
[[ "$unavailable" == 0 || "$profile" == gles31 ]] || fail "Unavailable expectation requires the GLES 3.1 build"
[[ "$boot_timeout" =~ ^[1-9][0-9]*$ ]] || fail "ANGLE_SIMULATOR_BOOT_TIMEOUT must be positive"
out="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/release-ios-simulator-arm64-$profile}"
suffix=""
[[ "$unavailable" == 0 ]] || suffix=-unavailable
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/ios-simulator-metal-$profile$suffix}"
[[ -f "$out/ANGLE_SIMULATOR_MANIFEST.json" ]] || fail "Build the iOS Simulator profile first"
mkdir -p "$results"
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out" "$profile" <<'VERIFY'
import importlib.util, json, sys
from pathlib import Path
root, angle, out = map(Path, sys.argv[1:4])
spec = importlib.util.spec_from_file_location('manifest', root / 'scripts/write-build-manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = json.loads((out / 'ANGLE_SIMULATOR_MANIFEST.json').read_text())
if (record['source'] != manifest.source_identity(root, angle) or record['profile'] != sys.argv[4] or
        record['gn_args'] != (out / 'args.gn').read_text()):
    raise SystemExit('Simulator build source or profile differs')
for name in ('libEGL', 'libGLESv2'):
    if manifest.sha256(out / (name + '.framework') / name) != record['binaries'][name]['sha256']:
        raise SystemExit('Simulator framework differs: ' + name)
VERIFY
# CoreSimulator must execute local files, including on workspaces backed by a virtual filesystem.
work="$(mktemp -d /private/tmp/angle-ios-metal.XXXXXX)"
device="${ANGLE_SIMULATOR_UDID:-}"
owned=0
cleanup() {
  python3 - "$device" "$owned" > "$results/cleanup.log" 2>&1 <<'CLEANUP'
import subprocess, sys
if sys.argv[2] == '1':
    for operation in ('shutdown', 'delete'):
        try:
            subprocess.run(['xcrun', 'simctl', operation, sys.argv[1]], timeout=20, check=False)
        except subprocess.TimeoutExpired:
            print('Simulator cleanup timed out: ' + operation)
CLEANUP
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/Frameworks"
for name in libEGL libGLESv2; do
  rsync -a "$out/$name.framework" "$work/Frameworks/"
done
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
compiler=(xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios18.0-simulator
  -isysroot "$sdk" -std=c++17 -fobjc-arc -I "$ANGLE_DIR/include" -F "$out"
  -Wl,-rpath,@executable_path/Frameworks)
"${compiler[@]}" "$ROOT_DIR/tests/metal-device-info.mm" -framework Foundation -framework Metal -o "$work/device-info"
"${compiler[@]}" "$ROOT_DIR/tests/metal-profile-probe.mm" -framework libEGL -framework libGLESv2 -framework Foundation -o "$work/profile-probe"
"${compiler[@]}" "$ROOT_DIR/tests/metal-culling-probe.mm" -framework libEGL -framework libGLESv2 -framework Foundation -framework Metal -o "$work/culling-probe"
: > "$results/probe-platforms.txt"
for name in device-info profile-probe culling-probe; do
  cp "$work/$name" "$results/$name"
  xcrun vtool -show-build "$work/$name" >> "$results/probe-platforms.txt"
done
cp "$out/ANGLE_SIMULATOR_MANIFEST.json" "$results/native-build-manifest.json"
if [[ -z "$device" ]]; then
  device="$(xcrun simctl create 'ANGLE Metal Test' \
    "${ANGLE_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro}" \
    "${ANGLE_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-18-5}")"
  owned=1
fi
printf '%s\n' "$device" > "$results/device.txt"
xcrun simctl list devices -j > "$results/devices.json"
xcrun simctl boot "$device" 2>/dev/null || true
python3 - "$device" "$results" "$boot_timeout" <<'BOOT'
import subprocess, sys
from pathlib import Path
with (Path(sys.argv[2]) / 'boot.log').open('w') as log:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', sys.argv[1], '-b'],
                   stdout=log, stderr=subprocess.STDOUT, timeout=int(sys.argv[3]), check=True)
BOOT
run_probe() {
  SIMCTL_CHILD_MTL_DEBUG_LAYER=1 SIMCTL_CHILD_MTL_SHADER_VALIDATION=1 \
  SIMCTL_CHILD_MTL_SHADER_VALIDATION_DEFAULT_STATE=all \
  SIMCTL_CHILD_MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING=1 \
  SIMCTL_CHILD_MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 \
  SIMCTL_CHILD_MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1 \
  SIMCTL_CHILD_ANGLE_FEATURE_OVERRIDES_ENABLED= SIMCTL_CHILD_ANGLE_FEATURE_OVERRIDES_DISABLED= \
  python3 -c 'import subprocess,sys; subprocess.run(sys.argv[1:], timeout=180, check=True)' \
    xcrun simctl spawn "$device" "$@"
}
run_probe "$work/device-info" > "$results/device.json" 2> "$results/device-runtime.log"
expected="$profile"
[[ "$unavailable" == 0 ]] || expected=gles31-unavailable
run_probe "$work/profile-probe" "$expected" 2>&1 | tee "$results/profile.log"
if [[ "$profile" == gles31 && "$unavailable" == 0 ]]; then
  run_probe "$work/culling-probe" "$work/culling.ppm" 2>&1 | tee "$results/culling.log"
  cp "$work/culling.ppm" "$results/culling.ppm"
  sips -s format png "$results/culling.ppm" --out "$results/culling.png" >/dev/null
fi
python3 - "$ROOT_DIR" "$results" "$expected" <<'RESULT'
import hashlib, json, sys
from pathlib import Path
root, results, expected = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
profile_log = (results / 'profile.log').read_text()
if f'METAL_PROFILE_PASS selected={expected}' not in profile_log or 'GLES30_PBUFFER_RENDER_PASS' not in profile_log:
    raise SystemExit('Simulator context or pbuffer verification failed')
if 'Metal API Validation Enabled' not in profile_log or 'Metal GPU Validation Enabled' not in profile_log:
    raise SystemExit('Simulator Metal validation did not activate')
if expected == 'gles31':
    log = (results / 'culling.log').read_text()
    frames = [line for line in log.splitlines() if line.startswith('FRAME ')]
    if ('COMPUTE_SYNCHRONIZATION_PASS' not in profile_log or len(frames) != 3 or
            'METAL_GPU_CULLING_PASS' not in log or
            any('image_match=1' not in line or 'command_guards=1' not in line or
                'counter_guards=1' not in line for line in frames)):
        raise SystemExit('Simulator compute or MDI output differs')
record = {'status': 'gles31_unavailable' if expected == 'gles31-unavailable' else 'pass',
          'expected_context_profile': expected, 'gles31_available': expected == 'gles31',
          'compute_and_mdi': 'pass' if expected == 'gles31' else 'not_run',
          'gles30_pbuffer_render': 'pass', 'feature_overrides': [],
          'metal_api_validation': True, 'metal_shader_validation': True,
          'device': json.loads((results / 'device.json').read_text()),
          'native_build': json.loads((results / 'native-build-manifest.json').read_text()),
          'input_sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in (
              'tests/metal-device-info.mm', 'tests/metal-profile-probe.mm',
              'tests/metal-culling-probe.mm', 'scripts/test-ios-simulator-metal.sh')},
          'result_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sorted(results.iterdir())
                            if path.is_file() and path.name != 'provenance.json'}}
(results / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
print('IOS_SIMULATOR_RESULT ' + record['status'])
RESULT
