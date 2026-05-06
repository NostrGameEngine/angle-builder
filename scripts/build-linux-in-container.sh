#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

ensure_angle_checkout

rm -rf "$ARTIFACTS_DIR/natives-linux" "$ARTIFACTS_DIR/natives-linux-arm64"

targets=(
  "natives-linux|linux|x86_64|release-linux-x64.gn|libEGL libGLESv2"
  "natives-linux-arm64|linux|arm64|release-linux-arm64.gn|libEGL libGLESv2"
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
  if [[ "$arch_dir" == "arm64" ]]; then
    python3 build/linux/sysroot_scripts/install-sysroot.py --arch=arm64
  fi
  gn gen "$out_dir"
  autoninja -C "$out_dir" $ninja_targets

  mkdir -p "$stage_dir"
  build_info_file "$stage_dir"
  cp -f LICENSE "$stage_dir/LICENSE.ANGLE" || true
  cp -f "$out_dir"/libEGL.* "$stage_dir/"
  cp -f "$out_dir"/libGLESv2.* "$stage_dir/"
  rm -f "$stage_dir"/*.TOC || true
  require_staged_file "$stage_dir" libEGL.so
  require_staged_file "$stage_dir" libGLESv2.so

done
popd >/dev/null
