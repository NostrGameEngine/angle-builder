#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

ensure_angle_checkout

rm -rf "$ARTIFACTS_DIR/natives-macos" "$ARTIFACTS_DIR/natives-macos-arm64"

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
  out_dir="out/$out_name"
  stage_dir="$ARTIFACTS_DIR/$classifier/native/angle/$runtime_os_dir/$arch_dir"

  mkdir -p "$out_dir"
  cp "$ROOT_DIR/$args_file" "$out_dir/args.gn"
  gn gen "$out_dir"
  autoninja -C "$out_dir" $ninja_targets

  mkdir -p "$stage_dir"
  build_info_file "$stage_dir"
  cp -f LICENSE "$stage_dir/LICENSE.ANGLE" || true
  cp -f "$out_dir"/libEGL.* "$stage_dir/"
  cp -f "$out_dir"/libGLESv2.* "$stage_dir/"
  rm -f "$stage_dir"/*.TOC || true
  require_staged_file "$stage_dir" libEGL.dylib
  require_staged_file "$stage_dir" libGLESv2.dylib
done
popd >/dev/null
