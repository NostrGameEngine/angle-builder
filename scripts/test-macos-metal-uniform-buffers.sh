#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
out_dir="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/metal-indirect-tests-$(host_arch)}"
[[ -f "$out_dir/args.gn" ]] || fail "Prepare a Metal test build first"
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/metal-uniform-buffers}"
mkdir -p "$results"

# Rebuild before recording source and executable identity. The existing GN args
# select either the normal GLES 3.0 profile or the isolated integration profile.
pushd "$ANGLE_DIR" >/dev/null
"$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" angle_white_box_tests
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$results" <<'PROVENANCE'
import importlib.util, json, sys
from pathlib import Path
root, angle, out, results = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = {"source": manifest.source_identity(root, angle),
          "gn_args": (out / "args.gn").read_text(),
          "executable_sha256": manifest.sha256(out / "angle_white_box_tests")}
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
PROVENANCE
system_profiler SPDisplaysDataType -json > "$results/gpu.json"
sw_vers > "$results/os.txt"
MTL_DEBUG_LAYER=1 "$out_dir/angle_white_box_tests" \
  '--gtest_filter=UniformBufferTest.*/*Metal*:UniformBlockWithOneLargeArrayMemberTest.*/*Metal*:WebGL2UniformBufferTest.*/*Metal*' \
  "--gtest_output=json:$results/results.json"
python3 - "$results/results.json" <<'VERIFY'
import json, sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get("failures", 0) or result.get("errors", 0):
    raise SystemExit("Upstream Metal UBO regressions failed")
executed, skipped = [], []
for suite in result.get("testsuites", []):
    for test in suite.get("testsuite", []):
        name = suite["name"] + "." + test["name"]
        if test.get("status") != "RUN" or test.get("result") == "SKIPPED":
            skipped.append(name)
        else:
            executed.append(name)
if len(executed) < 40:
    raise SystemExit("Insufficient upstream Metal UBO coverage: " + str(len(executed)))
print(f"Upstream Metal UBO tests executed: {len(executed)}; skipped: {len(skipped)}")
for name in skipped:
    print("Upstream skip: " + name)
VERIFY
popd >/dev/null
