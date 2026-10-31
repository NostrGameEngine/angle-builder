#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
out_dir="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/metal-compute-api-tests-$(host_arch)}"
[[ -f "$out_dir/args.gn" ]] || fail "Prepare a Metal test build first"
rg -q '^angle_metal_enable_compute_tests = true$' "$out_dir/args.gn" || \
  fail "Upstream compute tests require the isolated integration profile"
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/metal-upstream-compute}"
mkdir -p "$results"

# Rebuild before recording source and executable identity. The existing GN args
# select either the normal GLES 3.0 profile or the isolated integration profile.
pushd "$ANGLE_DIR" >/dev/null
"$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" angle_white_box_tests
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$results" <<'PROVENANCE'
import importlib.util, json, os, sys
from pathlib import Path
root, angle, out, results = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = {"source": manifest.source_identity(root, angle),
          "gn_args": (out / "args.gn").read_text(),
          "metal_api_validation": True,
          "shader_validation_environment": {name: os.environ.get(name, "") for name in (
              "MTL_SHADER_VALIDATION", "MTL_SHADER_VALIDATION_DEFAULT_STATE",
              "MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING",
              "MTL_SHADER_VALIDATION_REPORT_TO_STDERR", "MTL_SHADER_VALIDATION_ABORT_ON_FAULT")},
          "executable_sha256": manifest.sha256(out / "angle_white_box_tests")}
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
PROVENANCE
system_profiler SPDisplaysDataType -json > "$results/gpu.json"
sw_vers > "$results/os.txt"
MTL_DEBUG_LAYER=1 "$out_dir/angle_white_box_tests" \
  '--gtest_filter=ComputeShaderTest.*/*Metal*:ComputeShaderTestES3.*/*Metal*:StorageImageRenderProgramTest.*/*Metal*' \
  "--gtest_output=json:$results/results.json"
python3 - "$results/results.json" <<'VERIFY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("failures", 0) or result.get("errors", 0):
    raise SystemExit("Upstream Metal compute regressions failed")
executed, skipped = [], []
for suite in result.get("testsuites", []):
    for test in suite.get("testsuite", []):
        name = suite["name"] + "." + test["name"]
        if test.get("status") != "RUN" or test.get("result") == "SKIPPED":
            skipped.append(name)
        else:
            executed.append(name)
allowed_skips = {
    "ComputeShaderTest.ExceedCombinedShaderOutputResourcesInCS",
    "ComputeShaderTest.DispatchConvertVertexDispatch",
    "ComputeShaderTest.AdvancedSyncVertexArray",
    "ComputeShaderTest.WriteToPersistentBuffer",
    "ComputeShaderTest.ImageBufferMapWrite",
    "ComputeShaderTest.ImageBufferMapWriteAndBufferSubData",
    "ComputeShaderTest.FSReadImageThenCSSample",
    "StorageImageRenderProgramTest.StorageImageInVertexShader",
}
for name in skipped:
    if name.split("/")[0] not in allowed_skips:
        raise SystemExit("Unexpected upstream compute skip: " + name)
if result.get("tests", 0) < 99 or len(executed) < 91:
    raise SystemExit("Insufficient upstream Metal compute coverage: " + str(len(executed)))
print(f"Upstream Metal compute tests executed: {len(executed)}; skipped: {len(skipped)}")
for name in skipped:
    print("Upstream skip: " + name)
VERIFY
popd >/dev/null
