#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
ensure_angle_checkout
apply_patches

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
"$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" angle_white_box_tests libEGL libGLESv2
mkdir -p "$ROOT_DIR/test-results/metal-indirect"
system_profiler SPDisplaysDataType -json > "$ROOT_DIR/test-results/metal-indirect/gpu.json"
sw_vers > "$ROOT_DIR/test-results/metal-indirect/os.txt"
cp "$out_dir/args.gn" "$ROOT_DIR/test-results/metal-indirect/args.gn"
MTL_DEBUG_LAYER=1 "$out_dir/angle_white_box_tests" \
  '--gtest_filter=IndirectCommandTestMetal.*' \
  "--gtest_output=json:$ROOT_DIR/test-results/metal-indirect/results.json"
python3 - "$ROOT_DIR/test-results/metal-indirect/results.json" <<'PY'
import json, sys
with open(sys.argv[1]) as result_file:
    results = json.load(result_file)
if results.get("tests", 0) < 4 or results.get("disabled", 0) or results.get("failures", 0):
    raise SystemExit("Metal indirect tests did not all execute successfully")
for suite in results.get("testsuites", []):
    for test in suite.get("testsuite", []):
        if test.get("status") != "RUN" or test.get("result") == "SKIPPED":
            raise SystemExit("Metal indirect test was skipped: " + test["name"])
PY
popd >/dev/null
