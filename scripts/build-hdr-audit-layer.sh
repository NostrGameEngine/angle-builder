#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Provide test output directory}"
mkdir -p "$output"; output="$(realpath "$output")"
include_args=()
headers="${VULKAN_HEADERS_DIR:-${ANGLE_DIR:-$ROOT_DIR/build/angle}/third_party/vulkan-headers/src/include}"
if [[ -f "$headers/vulkan/vk_layer.h" ]]; then include_args=(-I "$headers"); fi
"${CXX:-c++}" "${include_args[@]}" -std=c++17 -O2 -Wall -Wextra -shared -fPIC -fvisibility=hidden -pthread \
    "$ROOT_DIR/tests/vulkan-hdr-audit-layer.cpp" -o "$output/libVkLayer_NGE_hdr_audit.so"
python3 - "$output" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
manifest={"file_format_version":"1.2.0", "layer":{
    "name":"VK_LAYER_NGE_hdr_audit", "type":"GLOBAL",
    "library_path":str(p/"libVkLayer_NGE_hdr_audit.so"), "api_version":"1.3.0",
    "implementation_version":"1", "description":"NGE HDR observation-only swapchain audit"}}
(p/"VkLayer_NGE_hdr_audit.json").write_text(json.dumps(manifest,indent=2)+"\n")
PY
