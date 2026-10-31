#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"
[[ "$(host_os)" == macos && "$(host_arch)" == arm64 ]] || fail "Requires an Apple Silicon Mac"
profile="${ANGLE_METAL_PROFILE:-gles30}"
[[ "$profile" == gles30 || "$profile" == gles31 ]] || fail "ANGLE_METAL_PROFILE must be gles30 or gles31"
jobs="${BUILD_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_JOBS must be a positive integer"
ensure_angle_checkout
apply_patches
out="$ANGLE_DIR/out/release-ios-device-arm64-$profile"
mkdir -p "$out"
cp "$ROOT_DIR/release-ios-device-arm64.gn" "$out/args.gn"
if [[ "$profile" == gles31 ]]; then
  printf '\nangle_metal_enable_gles31 = true\n' >> "$out/args.gn"
fi
metal_dir="$(dirname "$(xcrun --find metal)")"
[[ -x "$metal_dir/metallib" ]] || fail "Install the Xcode Metal toolchain first"
printf '\nangle_metal_toolchain_dir = "%s"\n' "$metal_dir" >> "$out/args.gn"
(cd "$ANGLE_DIR" && gn gen "$out" && autoninja -C "$out" -j "$jobs" libEGL libGLESv2)
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out" "$profile" <<'MANIFEST'
import importlib.util, json, re, subprocess, sys
from pathlib import Path
root, angle, out = map(Path, sys.argv[1:4])
profile = sys.argv[4]
spec = importlib.util.spec_from_file_location('manifest', root / 'scripts/write-build-manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
manifest.verify_production_profile(angle, out, profile)
record = {'source': manifest.source_identity(root, angle), 'profile': profile,
          'target': 'iOS device arm64', 'internal_compute_test_profile': False,
          'gn_args': (out / 'args.gn').read_text(),
          'xcode': manifest.capture('xcodebuild', '-version'),
          'sdk': manifest.capture('xcrun', '--sdk', 'iphoneos', '--show-sdk-version'),
          'binaries': {}}
for name in ('libEGL', 'libGLESv2'):
    binary = out / (name + '.framework') / name
    subprocess.run(['lipo', str(binary), '-verify_arch', 'arm64'], check=True)
    platform = manifest.capture('xcrun', 'vtool', '-show-build', str(binary))
    if not re.search(r'platform\s+IOS\s*$', platform, re.MULTILINE):
        raise SystemExit('Expected an iOS device framework: ' + platform)
    record['binaries'][name] = {'sha256': manifest.sha256(binary), 'platform': platform}
air = out / 'gen/angle/mtl_internal_shaders_autogen.air'
targets = sorted(set(value.decode() for value in re.findall(
    rb'air64(?:_v\d+)?-apple-ios[0-9.]+(?:-simulator)?', air.read_bytes())))
if not targets or any(target.endswith('-simulator') for target in targets):
    raise SystemExit('Internal Metal library is not compiled for an iOS device: ' + str(targets))
record['internal_metal_library'] = {
    'air_targets': targets,
    'sha256': manifest.sha256(out / 'gen/angle/mtl_internal_shaders_autogen.metallib')}
(out / 'ANGLE_DEVICE_MANIFEST.json').write_text(json.dumps(record, indent=2) + '\n')
print('IOS_DEVICE_BUILD_PASS profile=' + profile)
MANIFEST
