#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
ensure_angle_checkout
apply_patches

# Share the native encoder suite's build directory and arguments.
out_dir="$ANGLE_DIR/out/metal-indirect-tests-$(host_arch)"
mkdir -p "$out_dir"
sed -e 's/^angle_build_all = false$/angle_build_all = true/' \
    -e 's/^angle_assert_always_on = false$/angle_assert_always_on = true/' \
    "$ROOT_DIR/release-osx-$(host_arch).gn" > "$out_dir/args.gn"
cat >> "$out_dir/args.gn" <<'EOF'
angle_build_tests = true
angle_has_histograms = false
EOF

pushd "$ANGLE_DIR" >/dev/null
"$ANGLE_DIR/buildtools/mac/gn" gen "$out_dir"
"$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" angle_unittests angle_white_box_tests libEGL libGLESv2
results="$ROOT_DIR/test-results/metal-compute"
mkdir -p "$results"
system_profiler SPDisplaysDataType -json > "$results/gpu.json"
sw_vers > "$results/os.txt"
cp "$out_dir/args.gn" "$results/args.gn"
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$results" <<'PROVENANCE'
import importlib.util, json, os, sys
from pathlib import Path
root, angle, out, results = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = {"source": manifest.source_identity(root, angle),
          "profile": "normal GLES 3.0 test configuration; assertions enabled",
          "metal_api_validation": True,
          "shader_validation_environment": {name: os.environ.get(name, "") for name in (
              "MTL_SHADER_VALIDATION", "MTL_SHADER_VALIDATION_DEFAULT_STATE",
              "MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING",
              "MTL_SHADER_VALIDATION_REPORT_TO_STDERR", "MTL_SHADER_VALIDATION_ABORT_ON_FAULT")},
          "gn": manifest.capture(str(angle / "buildtools/mac/gn"), "--version"),
          "ninja": manifest.capture(str(angle / "third_party/ninja/ninja"), "--version"),
          "executables": {name: manifest.sha256(out / name)
                          for name in ("angle_unittests", "angle_white_box_tests")}}
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
PROVENANCE
"$out_dir/angle_unittests" \
  '--gtest_filter=MSLComputeOutputTest.*:MSLOutputTest.*:MSLVertexOutputTest.*' \
  "--gtest_output=json:$results/compiler.json"
MTL_DEBUG_LAYER=1 "$out_dir/angle_white_box_tests" \
  '--gtest_filter=ComputeShaderTestMetal.*:IndirectCommandTestMetal.*' \
  "--gtest_output=json:$results/results.json"
python3 - "$results/compiler.json" "$results/results.json" <<'PYTHON'
import json, sys
required = (
    {"MSLComputeOutputTest": 8, "MSLOutputTest": 53, "MSLVertexOutputTest": 11},
    {"ComputeShaderTestMetal": 6, "IndirectCommandTestMetal": 4},
)
for path, suites in zip(sys.argv[1:], required):
    with open(path) as source:
        results = json.load(source)
    if (results.get("tests", 0) < sum(suites.values()) or results.get("disabled", 0)
            or results.get("failures", 0) or results.get("errors", 0)):
        raise SystemExit("Compute tests did not all execute successfully: " + path)
    actual_suites = {suite["name"]: suite for suite in results.get("testsuites", [])}
    for name, minimum in suites.items():
        if actual_suites.get(name, {}).get("tests", 0) < minimum:
            raise SystemExit("Required compute test suite missing: " + name)
    for suite in results.get("testsuites", []):
        for test in suite.get("testsuite", []):
            if test.get("status") != "RUN" or test.get("result") == "SKIPPED":
                raise SystemExit("Compute test was skipped: " + test["name"])
PYTHON
popd >/dev/null
