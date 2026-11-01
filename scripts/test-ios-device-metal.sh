#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"
[[ "$(host_os)" == macos ]] || fail "Requires Xcode on macOS"
device="${ANGLE_IOS_DEVICE_UDID:?Set ANGLE_IOS_DEVICE_UDID to the paired physical iPhone}"
team="${ANGLE_IOS_TEAM:?Set ANGLE_IOS_TEAM to your Apple development team}"
profile="${ANGLE_METAL_PROFILE:-gles31}"
capabilities="${ANGLE_DEVICE_CAPABILITIES_ONLY:-0}"
[[ "$capabilities" == 0 || "$capabilities" == 1 ]] || fail "ANGLE_DEVICE_CAPABILITIES_ONLY must be 0 or 1"
[[ "$profile" == gles30 || "$profile" == gles31 ]] || fail "ANGLE_METAL_PROFILE must be gles30 or gles31"
[[ "$capabilities" == 0 ]] || profile=capabilities
out="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/release-ios-device-arm64-$profile}"
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/ios-device-metal-$profile}"
bundle="org.ngengine.angle.deviceprobe"
mkdir -p "$results"
results="$(cd "$results" && pwd)"
arguments=(--output "$results/project" --team "$team" --bundle-id "$bundle")
if [[ "$capabilities" == 0 ]]; then
  python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out" "$profile" <<'VERIFY'
import importlib.util, json, sys
from pathlib import Path
root, angle, out = map(Path, sys.argv[1:4])
spec = importlib.util.spec_from_file_location('manifest', root / 'scripts/write-build-manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = json.loads((out / 'ANGLE_DEVICE_MANIFEST.json').read_text())
if (record['source'] != manifest.source_identity(root, angle) or record['profile'] != sys.argv[4] or
        record['gn_args'] != (out / 'args.gn').read_text() or record['target'] != 'iOS device arm64'):
    raise SystemExit('Device build source or profile differs')
for name in ('libEGL', 'libGLESv2'):
    if manifest.sha256(out / (name + '.framework') / name) != record['binaries'][name]['sha256']:
        raise SystemExit('Device framework differs: ' + name)
VERIFY
  cp "$out/ANGLE_DEVICE_MANIFEST.json" "$results/native-build-manifest.json"
  arguments+=(--angle-dir "$ANGLE_DIR" --angle-out "$out")
fi
python3 "$ROOT_DIR/scripts/prepare-ios-device-probe.py" "${arguments[@]}"
# Keep Xcode products on the local filesystem for signing and device installation.
work="$(mktemp -d /private/tmp/angle-device-probe.XXXXXX)"
trap 'rm -rf "$work"' EXIT
xcodebuild -project "$results/project/AngleDeviceProbe.xcodeproj" -target AngleDeviceProbe \
  -configuration Release -sdk iphoneos -jobs 2 -allowProvisioningUpdates \
  SYMROOT="$work/products" build > "$results/build.log" 2>&1
app="$work/products/Release-iphoneos/AngleDeviceProbe.app"
codesign --verify --deep --strict "$app"
ditto "$app" "$results/AngleDeviceProbe.app"
xcrun devicectl device info details --device "$device" --timeout 30 \
  --json-output "$results/device-details.json" > "$results/device-details.log"
python3 - "$results/device-details.json" <<'DEVICE'
import json,sys
record = json.load(open(sys.argv[1]))['result']
if record['hardwareProperties']['reality'] != 'physical':
    raise SystemExit('Expected a physical iPhone')
DEVICE
xcrun devicectl device install app --device "$device" --timeout 120 "$app" \
  --json-output "$results/install.json" > "$results/install.log" 2>&1
validation='{"MTL_DEBUG_LAYER":"1","MTL_SHADER_VALIDATION":"1","MTL_SHADER_VALIDATION_DEFAULT_STATE":"all","MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING":"1","MTL_SHADER_VALIDATION_REPORT_TO_STDERR":"1","MTL_SHADER_VALIDATION_ABORT_ON_FAULT":"1","ANGLE_FEATURE_OVERRIDES_ENABLED":"","ANGLE_FEATURE_OVERRIDES_DISABLED":""}'
xcrun devicectl device process launch --device "$device" --timeout 240 --terminate-existing \
  --console --environment-variables "$validation" "$bundle" "$profile" \
  > "$results/runtime.log" 2>&1
xcrun devicectl device copy from --device "$device" --timeout 60 \
  --domain-type appDataContainer --domain-identifier "$bundle" --source Documents \
  --destination "$results/documents" > "$results/copy.log" 2>&1
python3 - "$ROOT_DIR" "$results" "$profile" <<'RESULT'
import hashlib,json,re,sys
from pathlib import Path
root, results, profile = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
log = (results / 'runtime.log').read_text()
if f'IOS_DEVICE_METAL_PASS profile={profile}' not in log:
    raise SystemExit('Physical iPhone probe did not pass; inspect runtime.log')
match = re.search(r'METAL_DEVICE_INFO_BEGIN.*?(\{.*?\})\s*METAL_DEVICE_INFO_END',log,re.S)
if not match:
    raise SystemExit('Physical Metal device capabilities are missing')
device = json.loads(match.group(1))
(results / 'device.json').write_text(json.dumps(device,indent=2)+'\n')
if profile != 'capabilities':
    if (f'METAL_PROFILE_PASS selected={profile}' not in log or 'GLES30_PBUFFER_RENDER_PASS' not in log or
            'GLES30_XFB_PASS' not in log):
        raise SystemExit('Physical EGL context or baseline rendering did not pass')
    if 'Metal API Validation Enabled' not in log or 'Metal GPU Validation Enabled' not in log:
        raise SystemExit('Metal API or Shader Validation did not activate')
if profile == 'gles31':
    frames = [line for line in log.splitlines() if line.startswith('FRAME ')]
    if ('COMPUTE_SYNCHRONIZATION_PASS' not in log or 'GRAPHICS_SSBO_PASS' not in log or
            'GRAPHICS_IMAGE_PASS vertex=load_store fragment=load_store binary=1' not in log or
            'IMAGE_ALIAS_PASS vertex=1 graphics=1 compute=1 mixed_shape=1 mixed_format=1 four=1 binary=1 exchange=1' not in log or
            'GRAPHICS_SSBO_ARRAY_PASS' not in log or 'GRAPHICS_SSBO_INVALIDATION_PASS' not in log or
            'GRAPHICS_SSBO_STAGE_LIMIT_PASS' not in log or 'GRAPHICS_SSBO_PIPELINE_PASS' not in log or
            'GRAPHICS_ATOMIC_COUNTER_PASS' not in log or
            'GRAPHICS_ATOMIC_COUNTER_STAGE_LIMIT_PASS' not in log or
            'GRAPHICS_SSBO_XFB_PASS' not in log or 'GRAPHICS_SSBO_XFB_RASTER_PASS' not in log or
            'GRAPHICS_SSBO_XFB_INSTANCE_PASS' not in log or 'GRAPHICS_SSBO_XFB_PIPELINE_PASS' not in log or
            'METAL_GPU_CULLING_PASS' not in log or
            len(frames) != 3 or any('image_match=1' not in line or 'command_guards=1' not in line or
                                   'counter_guards=1' not in line for line in frames)):
        raise SystemExit('Compute, graphics images, synchronization or MDI output differs')
inputs = ['tests/ios-metal-probe-app.mm','tests/metal-device-info.mm',
          'scripts/prepare-ios-device-probe.py','scripts/test-ios-device-metal.sh']
if profile != 'capabilities':
    inputs += ['tests/metal-profile-probe.mm','tests/metal-culling-probe.mm']
record = {'status':'pass','profile':profile,'device':device,
          'compute_and_mdi':'pass' if profile == 'gles31' else 'not_run',
          'feature_overrides':[],
          'native_build':json.loads((results / 'native-build-manifest.json').read_text())
                         if profile != 'capabilities' else None,
          'input_sha256':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in inputs},
          'result_sha256':{str(p.relative_to(results)):hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted(results.rglob('*')) if p.is_file() and
                           p.name != 'provenance.json'}}
(results/'provenance.json').write_text(json.dumps(record,indent=2)+'\n')
print('IOS_DEVICE_RESULT pass profile='+profile)
RESULT
