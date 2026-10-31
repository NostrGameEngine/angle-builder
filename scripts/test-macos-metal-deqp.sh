#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"
[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
out_dir="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/metal-compute-api-tests-$(host_arch)}"
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/metal-deqp-gles31}"
cases="${ANGLE_DEQP_CASE:-dEQP-GLES31.*}"
filter="${ANGLE_DEQP_GTEST_FILTER:-}"
filter_args=("--deqp-case=$cases")
if [[ -n "$filter" ]]; then
  # ANGLE rewrites both options into one GTest filter; supplying both would
  # overwrite the case expression rather than intersecting the two selections.
  filter_args=("--gtest_filter=$filter")
fi
resolved="$(cd "$ANGLE_DIR" && "$ANGLE_DIR/buildtools/mac/gn" args "$out_dir" --list=angle_metal_enable_compute_tests --short)"
[[ "$resolved" == 'angle_metal_enable_compute_tests = true' ]] || \
  fail "dEQP GLES 3.1 requires the isolated integration profile"
mkdir -p "$results"
python3 "$ROOT_DIR/scripts/prepare-cts-tests.py" --angle-dir "$ANGLE_DIR" --apply \
  --output "$results/cts-source.json"
pushd "$ANGLE_DIR" >/dev/null
"$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" angle_deqp_gles31_tests
popd >/dev/null
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$results" "$cases" "$filter" <<'PROVENANCE'
import importlib.util, json, os, sys
from pathlib import Path
root, angle, out, results = map(Path, sys.argv[1:5])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = {"source": manifest.source_identity(root, angle), "case_expression": sys.argv[5],
          "gtest_filter": sys.argv[6],
          "cts": json.loads((results / "cts-source.json").read_text()),
          "profile": "internal ES 3.1 dEQP integration; not a certified conformance result",
          "gn_args": (out / "args.gn").read_text(), "metal_api_validation": True,
          "shader_validation_environment": {name: os.environ.get(name, "") for name in (
              "MTL_SHADER_VALIDATION", "MTL_SHADER_VALIDATION_DEFAULT_STATE",
              "MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING",
              "MTL_SHADER_VALIDATION_REPORT_TO_STDERR", "MTL_SHADER_VALIDATION_ABORT_ON_FAULT")},
          "executable_sha256": manifest.sha256(out / "angle_deqp_gles31_tests"),
          "client_sha256": {name: manifest.sha256(out / name) for name in (
              "libEGL.dylib", "libGLESv2.dylib", "libangle_deqp_libgles31.dylib", "libangle_util.dylib")}}
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
PROVENANCE
system_profiler SPDisplaysDataType -json > "$results/gpu.json"
sw_vers > "$results/os.txt"
set +e
(cd "$out_dir" && MTL_DEBUG_LAYER=1 ./angle_deqp_gles31_tests --use-angle=metal \
  "${filter_args[@]}" "--gtest_output=json:$results/results.json") \
  > "$results/runtime.log" 2>&1
status=$?
set -e
[[ ! -f "$out_dir/TestResults.qpa" ]] || cp "$out_dir/TestResults.qpa" "$results/TestResults.qpa"
python3 - "$results" "$status" <<'VERIFY'
import collections, json, re, sys
from pathlib import Path
results = Path(sys.argv[1])
status = int(sys.argv[2])
log = (results / "runtime.log").read_text()
# GTest treats NotSupported as success. Keep the underlying dEQP counters and
# per-case QPA results separate so optional cases are never reported as passes.
summary = {name: int(value) for name, value in re.findall(
    r"^\*RESULT: (Total|Passed|Failed|Skipped|Not Supported|Exception|Crashed): (\d+)$", log, re.M)}
record = json.loads((results / "provenance.json").read_text())
qpa = results / "TestResults.qpa"
case_results = re.findall(
    r'<TestCaseResult CasePath="([^"]+)".*?<Result StatusCode="([^"]+)"',
    qpa.read_text() if qpa.exists() else "", re.S)
status_counts = dict(collections.Counter(code for _, code in case_results))
record.update({"process_exit_code": status, "summary": summary,
               "qpa_status_counts": status_counts})
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
print("Metal dEQP result:", summary, "process exit:", status)
print("dEQP individual statuses:", status_counts)
for name, code in case_results:
    if code not in ("Pass", "NotSupported"):
        print("dEQP status:", code, name)
if status or not summary.get("Total") or any(summary.get(name, 0) for name in (
        "Failed", "Skipped", "Exception", "Crashed")):
    raise SystemExit("Metal dEQP did not complete without failures/skips/exceptions")
if summary["Passed"] + summary["Not Supported"] != summary["Total"]:
    raise SystemExit("Incomplete dEQP accounting")
for name, code in case_results:
    if code == "NotSupported":
        print("dEQP NotSupported:", name)
VERIFY
