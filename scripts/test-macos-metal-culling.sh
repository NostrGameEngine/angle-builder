#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/scripts/common.sh"

[[ "$(host_os)" == macos ]] || fail "This test requires macOS with Metal"
out_dir="${ANGLE_TEST_OUT_DIR:-$ANGLE_DIR/out/metal-compute-api-tests-$(host_arch)}"
results="${ANGLE_TEST_RESULTS_DIR:-$ROOT_DIR/test-results/metal-culling}"
api_validation="${ANGLE_METAL_API_VALIDATION:-1}"
[[ "$api_validation" == 0 || "$api_validation" == 1 ]] || fail "ANGLE_METAL_API_VALIDATION must be 0 or 1"
[[ "$api_validation" == 1 || "${ANGLE_METAL_BENCHMARK:-0}" == 1 ]] || \
  fail "Disable API validation only for an explicit benchmark run"
if [[ -n "${ANGLE_METAL_CAPTURE_PATH:-}" ]]; then
  [[ -z "${MTL_SHADER_VALIDATION:-}" || "$MTL_SHADER_VALIDATION" == 0 ]] || \
    fail "Run GPU capture separately with MTL_SHADER_VALIDATION=0; keep strict validation as a separate run"
  export MTL_CAPTURE_ENABLED=1
fi
resolved="$(cd "$ANGLE_DIR" && "$ANGLE_DIR/buildtools/mac/gn" args "$out_dir" --list=angle_metal_enable_compute_tests --short)"
selected="$(cd "$ANGLE_DIR" && "$ANGLE_DIR/buildtools/mac/gn" args "$out_dir" --list=angle_metal_enable_gles31 --short)"
[[ "$resolved" == 'angle_metal_enable_compute_tests = true' || "$selected" == 'angle_metal_enable_gles31 = true' ]] || \
  fail "Culling requires the selectable GLES 3.1 profile or isolated integration build"
mkdir -p "$results"
if [[ -n "${ANGLE_NATIVE_MANIFEST:-}" ]]; then
  # Verify a prepared release build instead of mixing Ninja and Siso output.
  python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$ANGLE_NATIVE_MANIFEST" "$results" <<'PREBUILT'
import importlib.util, json, shutil, sys
from pathlib import Path
root, angle, out, manifest_path, results = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = json.loads(manifest_path.read_text())
if record["source"] != manifest.source_identity(root, angle):
    raise SystemExit("Prepared native build source differs from the current patch series")
if record["build"]["gn_args"] != (out / "args.gn").read_text():
    raise SystemExit("Prepared native build arguments differ")
for name in ("libEGL.dylib", "libGLESv2.dylib"):
    if record["binaries"][name]["sha256"] != manifest.sha256(out / name):
        raise SystemExit("Prepared native binary differs: " + name)
shutil.copy2(manifest_path, results / "native-build-manifest.json")
PREBUILT
else
  pushd "$ANGLE_DIR" >/dev/null
  "$ANGLE_DIR/third_party/ninja/ninja" -C "$out_dir" -j "${BUILD_JOBS:-2}" libEGL libGLESv2
  popd >/dev/null
fi
xcrun clang++ -std=c++17 -fobjc-arc -I "$ANGLE_DIR/include" \
  "$ROOT_DIR/tests/metal-culling-probe.mm" -L "$out_dir" -lEGL -lGLESv2 \
  -Wl,-rpath,"$out_dir" -framework Foundation -framework Metal -o "$results/metal-culling-probe"
python3 - "$ROOT_DIR" "$ANGLE_DIR" "$out_dir" "$results" "$api_validation" <<'PROVENANCE'
import importlib.util, json, os, sys
from pathlib import Path
root, angle, out, results = map(Path, sys.argv[1:5])
spec = importlib.util.spec_from_file_location("manifest", root / "scripts/write-build-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)
record = {"source": manifest.source_identity(root, angle),
          "profile": ("Metal ES 3.1 culling microbenchmark; not representative application performance"
                      if os.environ.get("ANGLE_METAL_BENCHMARK") == "1" else
                      "Metal ES 3.1 culling integration; not conformance or performance evidence"),
          "gn_args": (out / "args.gn").read_text(),
          "metal_api_validation": sys.argv[5] == "1",
          "feature_overrides": [],
          "gpu_capture_path": os.environ.get("ANGLE_METAL_CAPTURE_PATH"),
          "benchmark_requested": os.environ.get("ANGLE_METAL_BENCHMARK") == "1",
          "shader_validation_environment": {name: os.environ.get(name, "") for name in (
              "MTL_SHADER_VALIDATION", "MTL_SHADER_VALIDATION_DEFAULT_STATE",
              "MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING",
              "MTL_SHADER_VALIDATION_REPORT_TO_STDERR", "MTL_SHADER_VALIDATION_ABORT_ON_FAULT")},
          "sha256": {name: manifest.sha256(path) for name, path in {
              "probe_source": root / "tests/metal-culling-probe.mm",
              "probe": results / "metal-culling-probe",
              "libEGL": out / "libEGL.dylib", "libGLESv2": out / "libGLESv2.dylib"}.items()}}
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
PROVENANCE
system_profiler SPDisplaysDataType -json > "$results/gpu.json"
sw_vers > "$results/os.txt"
(cd "$out_dir" && MTL_DEBUG_LAYER="$api_validation" "$results/metal-culling-probe" "$results/culling.ppm") \
  2>&1 | tee "$results/runtime.log"
sips -s format png "$results/culling.ppm" --out "$results/culling.png" >/dev/null
python3 - "$results" <<'VERIFY'
import hashlib, json, sys
from pathlib import Path
results = Path(sys.argv[1])
log = (results / "runtime.log").read_text()
frames = [line for line in log.splitlines() if line.startswith("FRAME ")]
if ("METAL_GPU_CULLING_PASS" not in log or len(frames) != 3 or
        any("image_match=1" not in line for line in frames)):
    raise SystemExit("GPU culling did not verify every frame")
record = json.loads((results / "provenance.json").read_text())
record["frame_results"] = frames
record["benchmark_results"] = [line for line in log.splitlines() if line.startswith("BENCH_")]
if record["benchmark_requested"] and (log.count("BENCH_SAMPLE ") != 24 or
                                       log.count("BENCH_MEDIAN ") != 3):
    raise SystemExit("Incomplete direct/indirect/MDI timing comparison")
if record["gpu_capture_path"]:
    capture = Path(record["gpu_capture_path"])
    if not capture.is_dir() or "GPU_CAPTURE " + str(capture) not in log:
        raise SystemExit("GPU capture was not produced")
    record["gpu_capture_files"] = {
        str(path.relative_to(capture)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(capture.rglob("*")) if path.is_file()}
    if not record["gpu_capture_files"]:
        raise SystemExit("GPU capture is empty")
record["sha256"].update({name: hashlib.sha256((results / name).read_bytes()).hexdigest()
                         for name in ["culling.ppm", "culling.png", "runtime.log"]})
(results / "provenance.json").write_text(json.dumps(record, indent=2) + "\n")
VERIFY
