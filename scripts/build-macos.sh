#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

metal_profile="${ANGLE_METAL_PROFILE:-gles30}"
[[ "$metal_profile" == gles30 || "$metal_profile" == gles31 ]] || \
  fail "ANGLE_METAL_PROFILE must be gles30 or gles31"
ensure_angle_checkout

targets=(
  "natives-macos|osx|x86_64|release-osx-x64.gn|libEGL libGLESv2"
  "natives-macos-arm64|osx|arm64|release-osx-arm64.gn|libEGL libGLESv2"
)

selected_classifier="${BUILD_CLASSIFIER:-}"

pushd "$ANGLE_DIR" >/dev/null
for target in "${targets[@]}"; do
  IFS='|' read -r classifier runtime_os_dir arch_dir args_file ninja_targets <<<"$target"
  if [[ -n "$selected_classifier" && "$classifier" != "$selected_classifier" ]]; then
    continue
  fi
  apply_patches
  out_name="$(basename "$args_file" .gn)"
  profile_artifacts="$ARTIFACTS_DIR"
  if [[ "$metal_profile" == gles31 ]]; then
    out_name+="-gles31"
    profile_artifacts+="/gles31"
  fi
  out_dir="out/$out_name"
  stage_dir="$profile_artifacts/$classifier/native/angle/$runtime_os_dir/$arch_dir"

  mkdir -p "$out_dir"
  cp "$ROOT_DIR/$args_file" "$out_dir/args.gn"
  if [[ "$metal_profile" == gles31 ]]; then
    printf '\nangle_metal_enable_gles31 = true\n' >> "$out_dir/args.gn"
  fi
  gn gen "$out_dir"
  build_command=(autoninja -C "$out_dir")
  if [[ -n "${BUILD_JOBS:-}" ]]; then
    [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_JOBS must be a positive integer"
    build_command+=(-j "$BUILD_JOBS")
  fi
  "${build_command[@]}" $ninja_targets
  for library in libEGL.dylib libGLESv2.dylib; do
    lipo "$out_dir/$library" -verify_arch "$arch_dir"
  done

  mkdir -p "$stage_dir"
  build_info_file "$stage_dir"
  printf 'ANGLE_METAL_PROFILE=%s\n' "$metal_profile" >> "$stage_dir/ANGLE_BUILD_INFO.txt"
  cp -f LICENSE "$stage_dir/LICENSE.ANGLE" || true
  cp -f "$out_dir/libEGL.dylib" "$out_dir/libGLESv2.dylib" "$stage_dir/"
  require_staged_file "$stage_dir" libEGL.dylib
  require_staged_file "$stage_dir" libGLESv2.dylib
  python3 "$ROOT_DIR/scripts/write-build-manifest.py" --angle-dir "$ANGLE_DIR" \
    --out-dir "$ANGLE_DIR/$out_dir" --stage-dir "$stage_dir" --build-launcher autoninja \
    --metal-profile "$metal_profile"
done
popd >/dev/null
