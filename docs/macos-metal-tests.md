# macOS Metal validation

Use a macOS host with Xcode, the Metal toolchain and a graphical login session.
ANGLE is pinned in `ANGLE_COMMIT`; the build and tests apply the files in
`patches/` in lexical order. A separate dependency checkout can be selected with
`ANGLE_DIR` to preserve an older patched checkout.

The suites below cover the individual internal implementation stages. For the
current selectable GLES 3.0/GLES 3.1 build and direct EGL context selection, see
[Selecting a Metal GLES profile](selecting-metal-gles-profile.md). The explicit
GLES 3.1 profile does not require the internal compute-test option; the default
build remains GLES 3.0.

```sh
ANGLE_DIR=/path/to/angle BUILD_CLASSIFIER=natives-macos-arm64 BUILD_JOBS=2 \
  bash scripts/build-macos.sh
ANGLE_DIR=/path/to/angle bash scripts/test-macos-hdr.sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 bash scripts/test-macos-metal-indirect.sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 bash scripts/test-macos-metal-compute.sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 bash scripts/test-macos-metal-compute-api.sh
```

Set `ANGLE_SKIP_SYNC=1` only after a successful dependency sync for the pinned
revision. The scripts verify the source revision before accepting that option.
The macOS runtime package contains `ANGLE_BUILD_MANIFEST.json` with upstream
and patched tree identities, patch SHA-256 checksums, GN arguments, toolchain,
SDK and library checksums. Source changes outside the patch series cause
manifest generation to fail.

The two native indirect tests use ANGLE's actual Metal command encoders and native MSL
kernels. A first kernel produces a three-dimensional indirect dispatch; the
second produces array and indexed drawing arguments, including nonzero offsets,
strides, `firstIndex` and negative `baseVertex`. Sixteen frames vary visibility
and reuse command storage. A second test drops argument-buffer references before
the deferred render stream is encoded. Only the final image readback waits for
GPU results. Tests run with Metal API validation and must execute successfully;
zero tests or skipped tests are not accepted.

These two tests verify native command encoding and resource dependencies. It does
not exercise GLSL compute compilation, GL SSBO layout/reflection, public GL
dispatch, GLES primitive/index emulation or `GL_EXT_multi_draw_indirect` entry
points. It does not establish GLES 3.1 support. The distributed Metal capability
remains GLES 3.0 by default; the separately selected GLES 3.1 profile has its own
public EGL probes.

The compute suite additionally compiles GLSL ES 3.10 through ShaderLang into MSL
2.1 and executes the translated kernels. It checks all invocation builtins over
288 invocations in a 3D direct grid and a GPU-generated indirect grid. A separate
case writes a private image in one kernel, reads it in another, and exchanges
shared values across 128 threads with three workgroup barriers and helper calls.
The test checks that the group spans more than one hardware SIMD group and
allocates native threadgroup memory. Only the final output is mapped to the CPU.

The compute runner also executes the MSL vertex/fragment/compiler regressions
and the native indirect suite, with Metal API validation enabled for GPU tests.
It records results and machine/build metadata in `test-results/metal-compute`.
This validates translation and backend primitives; public GL program linking,
SSBOs, full memory fences and MDI entry points remain separate requirements.

Storage cases cover std430 input and std140 output with the same underlying
allocation and distinct nonzero binding offsets. They verify array strides,
vec3/scalar packing, bool storage, nested records, both matrix orientations,
helper out/inout arguments and compound vector writes. Runtime-array length is
checked against supplied GL-visible ranges smaller than the allocation.
The test compares all bytes, including source, padding and guard regions.

Before executing, translated kernels also pass through Metal linked-stage
selection, executable pipeline caching, serialization and reload. A public GLES
3.0 regression checks raster uniforms and program binary reload. The indirect
producer writes its dispatch arguments directly to a private SSBO; the consumer
uses that same allocation as an indirect buffer. No intermediate argument
readback or image-to-buffer command copy is used.

Overlapping resource slots have compiler diagnostic tests. The native-only tests
do not establish public GL compute/SSBO support or full GLES 3.1 conformance.
The additional public API integration tests below use an isolated internal profile.

## GLES API integration suite

`test-macos-metal-compute-api.sh` uses a separate output directory and explicitly
enables `angle_metal_enable_compute_tests`. This partial profile is for integration
testing only and the release manifest writer rejects it. The complete suite needs
Apple silicon and macOS 15 or newer for Metal 3.2 memory-only shader fences.

The runner executes twenty-seven compute API tests, an indirect byte-index API test,
six link/cache/lifetime checks and the nine native/backend GPU regressions,
and 67 compiler plus 27 index-range tests. It rejects missing/skipped/failed tests and records source
and patch identities, executable hashes, GN arguments, versions and GPU metadata
under `test-results/metal-compute-api`. GL version, renderer and compute limits are
recorded in the first API test's JSON properties.

Public API checks include program-binary reload, SSBO range aliases and length,
default uniforms, shared/device atomics with returned old values and compare-swap,
GPU-generated indirect dispatch, GPU-written std140 UBOs with row-major matrices,
image-to-sampler use, and GPU-generated array/indexed indirect and multi-draw.
Draw commands have a nonzero buffer offset and non-tight stride; indexed commands
include nonzero firstIndex and negative baseVertex. Eight frames exercise command
reuse and zero instance counts. Shader fence tests execute divergent branches,
which must not introduce an implicit execution rendezvous. Images and memory-fence
requirements also survive program-binary reload.

These checks cover native topologies and UInt8/UInt16/UInt32 index types. Array triangle-fan/provoking conversion, range-aware robustness,
complete image format compatibility remain required
before enabling the public GLES 3.1 profile or MDI in production.

Descriptor-array coverage binds two SSBO elements to separate ranges of one
allocation and all twelve UBO elements to remapped GL binding points. It checks
runtime lengths, std140 element strides and untouched guard/source bytes after
program-binary reload. Atomic-counter coverage uses a four-byte range offset,
helper arguments, 256 concurrent increment/decrement tickets, unsigned wraparound,
a second dispatch's atomic reads and binary reload. A separate regression writes
a counter-only buffer after a GL_FIXED vertex conversion has been cached, then
checks the resulting draw without an intermediate readback.

Aggregate storage coverage copies whole matrices, structs and fixed arrays between
std430 row-major input and std140 row-/column-major output. It exercises nested
arrays, `out`/`inout`, pre/post increment, signed wraparound, vector swizzles and
noncontiguous matrix columns, comparing every word including source/guard/padding
bytes. Separate SIMD groups write different components of the same row-major
column; partial writes touch only the selected scalar locations.

Image descriptor coverage uses all sixteen compute samplers together with four
write-only images, remaps the GL texture units, and checks imageSize and implicit
LOD sampling. A second case exercises nested read/write r32ui image arrays with
non-identity image-unit assignments and binary reload, then samples each physical
texture independently. Final SSBO checks include untouched range guards.

The byte-index indirect test forces `HasCheapRenderPass` off. A marker draw starts
a raster pass immediately before GPU conversion; final pixels verify attachment
preservation, signed baseVertex, nonzero firstIndex and tight/padded MDI strides.
Compute rewrites the indices over six frames, alternating visible and degenerate
geometry to expose stale conversion caches. Source guard words remain unchanged.

Layered-image tests compare signed/unsigned 3D, array and cube mip views with
framebuffer reads. They preserve lower mip levels and check cube face aliases,
ignored 2D layer arguments, zero out-of-range loads and discarded stores. Binding
tests exercise texture units 32..47 and UBO points 36..47 after binary reload.

Integer builtins are checked word by word against independent CPU references:
128 scalar input lanes include boundary values and pseudorandom patterns, with
zero/full-width bitfields, carry/borrow, signed high products, vector widths 2..4
and scalar/swizzled storage out arguments. Input, padding and range guards remain
part of the comparison.

Compute link validation runs with parallel Metal compilation enabled and disabled.
An oversized native shared-memory layout must fail linking with an info log and
no GL API error. A successful binary-cache case uploads 4816-byte default uniform
arrays twice, deletes both programs before readback and compares distinct output
ranges and guards. Pipeline creation happens during linking; context cache
registration remains on the context thread.

Separable compute cases verify local size, uniforms and SSBO binding reflection
after program binary loading. They deliberately keep the first program active
for glUniform while installing another compute component, then update the
component with glProgramUniform and change buffer ranges without changing stages.
Both direct and indirect dispatch execute before program deletion and final
readback. Graphics separable pipelines are still unsupported.

Indirect line-loop coverage compares complete framebuffers against direct GLES
draws for arrays and UInt8/UInt16/UInt32 indices. GPU-generated commands include
nonzero firstIndex, negative baseVertex, two instances, single-vertex/zero-count
commands, zero instances and tight/padded multi-draw strides. Minimal 16-byte
array and 20-byte indexed argument allocations are tested separately. Source
indices/arguments and a previously drawn marker remain part of the comparison.

## Graphics UBO regressions

The compute-to-graphics case writes a std140 block containing rectangular
row-major matrices, matrix/vector arrays, vec3/scalar packing and noncanonical
boolean words. Vertex and fragment stages consume the same block after GL binding
remapping. Six frames update cached conversions, switch aligned ranges and reload
a graphics program binary. Both direct and GPU-generated indirect draws check
final pixels, preserved attachments and all source/padding/guard words.

The separate upstream UBO runner rebuilds the selected test output and records
its source and executable identities:

```sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 \
  bash scripts/test-macos-metal-uniform-buffers.sh
```

It defaults to the normal-profile Metal test output prepared by the compute
runner. Set `ANGLE_TEST_OUT_DIR` to an existing integration test output to exercise
that profile, and `ANGLE_TEST_RESULTS_DIR` to keep its results separate. It runs
upstream Metal UBO, large-array and WebGL2 UBO cases. Upstream skips are listed
explicitly and are separate from the strict integration suite, which accepts no
skips. These targeted tests do not establish GLES conformance.

Indexed topology coverage exercises all seven GLES primitive modes, three index
widths, first/last provoking conventions and restart on/off over 420 frames. It
checks blending, winding/culling, nonzero firstIndex, signed baseVertex, MDI
strides, incomplete/zero commands and untouched source/guard words. Fan/loop
oracles use specification-based CPU assembly to avoid defects in legacy direct
emulation. A 64-command array-loop grid stresses reuse of the private packet.
Reference readbacks happen before GPU production of the actual commands.

Enable GPU memory/texture instrumentation as well as the runner's API validation:

```sh
MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_DEFAULT_STATE=all \
MTL_SHADER_VALIDATION_ENABLE_ERROR_REPORTING=1 \
MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1 \
ANGLE_DIR=/path/to/angle ANGLE_SKIP_SYNC=1 BUILD_JOBS=2 \
  bash scripts/test-macos-metal-compute-api.sh
```

These environment settings are recorded in provenance. Abort-on-fault ensures
reported shader errors cannot be mistaken for a successful pixel comparison.
See Apple's [Shader Validation documentation](https://developer.apple.com/documentation/xcode/validating-your-apps-metal-shader-usage).


## Upstream compute integration

After preparing the isolated integration output, run the registered upstream
compute cases with the same Shader Validation environment shown above:

```sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 \
  bash scripts/test-macos-metal-upstream-compute.sh
```

The runner rebuilds, records source/executable/GN/GPU identities, requires at
least 91 executed tests from the pinned 99-case suite, and rejects failures or
unexpected skips. Its eight permitted skips remain visible in JSON and output;
they concern declared limits or optional capabilities. They are separate from
the strict suite, which permits no skips. Results are stored under
`test-results/metal-upstream-compute`.

The strict suite also covers null image bindings, native 3D slice aliases through
nested image2D arrays and helper arguments, binary reload and deletion. A separate
64 KB UBO case checks every GPU-written word and its guards, then consumes the
same range in compute, vertex and fragment stages. These checks extend targeted
coverage and do not authorize the production GLES 3.1 version gate.


The upstream storage runner is separate so graphics-only limits stay explicit:

```sh
ANGLE_DIR=/path/to/angle BUILD_JOBS=2 \
  bash scripts/test-macos-metal-upstream-storage.sh
```

It requires at least 54 executed cases from the pinned 58-case suite and permits
only the four named graphics-storage/combined-limit skips. The strict suite
accepts no skips. Boolean copies are checked with GPU-generated noncanonical
values, helper copy-out, swizzles and untouched guard/padding words.

The GLES 3.0 direct-primitive regression adds 4,704 complete-image comparisons
for procedural and VBO vertices, client and buffer indices, all primitive modes,
restart, provoking conventions, incomplete counts and instancing. Its oracle
assembles native primitive lists independently. The API integration and normal
GLES 3.0 runners both include this test; it is separate from the original two
native indirect command tests.


## Array commands and pipeline components

The strict API runner additionally checks 2,240 array-indirect images, including
relative vertex offsets, format conversion, zero-stride and instanced attributes,
nonzero base instances, both provoking conventions and command strides. A native
packet-only regression checks 2,160 combinations at the uint/GLsizei boundaries
without rasterizing enormous draws. It uses the actual backend MSL conversion
source and a separate 64-bit reference, and checks allocation guards.

Two graphics pipeline cases exercise independent and shared vertex/fragment
program ownership, GPU-converted uniform ranges, explicit matrix/array varying
locations, program binaries and indirect fans. The upstream pipeline runner is
`test-macos-metal-upstream-pipelines.sh`; it records its source and executable
identity and requires 40 executed cases with seven named optional-feature skips.

## Broader ES 3.1 regressions

After preparing the isolated profile, run
`scripts/test-macos-metal-upstream-es31.sh` with the Shader Validation environment
above. It rebuilds and records provenance, then runs the pinned Metal vertex
binding, atomic counter, program interface, multisample texture, framebuffer and
indirect tests, including the five upstream multi-draw indirect cases. The
current checkpoint executes 126 of 177 registered cases. The
51 permitted skips name optional extensions or resources beyond the declared
limits; unexpected skips and failures fail the runner. Two compute/program-pipeline
vertex-update cases now execute on Metal as well as Vulkan. These checks cover
additional mandatory behavior without establishing full GLES 3.1 conformance.

## Stable-geometry GPU culling

`scripts/test-macos-metal-culling.sh` requires the isolated integration profile.
Use the same Metal Shader Validation variables as the strict API runner. It
renders three camera views of 96 objects with one stable quad VBO, one stable
index buffer and one stable object allocation. Compute reads the objects, writes
padded indexed-indirect commands and increments an atomic visibility counter.
A command barrier precedes `glMultiDrawElementsIndirectEXT`; no host argument
read or geometry update occurs between dispatch and draw.

Each view is compared byte-for-byte against an independently selected direct-draw
reference rendered before GPU command production. Proof readbacks after rendering
verify every command, padding/guard word, atomic count and unchanged geometry.
The expected visible counts are 96, 35 and 12. This is functional integration
coverage with instrumentation enabled, not a performance measurement.

Results under `test-results/metal-culling` include the executable, three-view PNG,
raw PPM, runtime log, GPU/OS data and source/binary/image hashes. The experimental
libraries remain excluded from production packaging.

Set `ANGLE_METAL_BENCHMARK=1` for an optional comparison of 96 direct draw calls,
96 indirect draw calls and one MDI call encoding 96 native indirect draws. The
first view has all 96 objects visible. Methods run in interleaved forward/reverse
order with a discarded warmup cycle and eight measured samples per method.
Every sample must match the reference image. The log records CPU encoding time
and non-disjoint `GL_TIME_ELAPSED_EXT` GPU queries in nanoseconds, plus medians.
Readback/timer collection happens after each measured draw sequence. Use a quiet
GPU and a separate results directory for timing; instrumented functional runs
are not representative application performance evidence.
`ANGLE_METAL_API_VALIDATION=0` is accepted only with the explicit benchmark
option. Combine it with `MTL_SHADER_VALIDATION=0` for a separate timing run;
both validation settings are recorded in provenance. Correctness runs keep
both validation layers enabled.

For an Xcode frame capture, set `ANGLE_METAL_CAPTURE_PATH` to a new absolute
`.gputrace` path and use `MTL_SHADER_VALIDATION=0` in a separate run. The runner
enables `MTL_CAPTURE_ENABLED=1`, captures compute through the first MDI render,
and hashes the capture files. Metal API Validation stays enabled. On the tested
host, combining GPU capture and Shader Validation stalls during initialization;
the runner rejects that combination. Keep the strict Shader Validation run as
separate correctness evidence. Existing capture paths are preserved.


## dEQP GLES 3.1

`scripts/test-macos-metal-deqp.sh` builds and runs the pinned AOSP GLES 3.1 mustpass
list against the isolated Metal profile, with source/client/executable hashes and
the validation environment recorded. `ANGLE_DEQP_CASE` selects a case expression;
use `ANGLE_TEST_RESULTS_DIR` to preserve each subgroup separately. The default
expression runs the entire list. Use the same Shader Validation environment as
the strict API suite above.
For a state-transition reproduction across multiple groups,
`ANGLE_DEQP_GTEST_FILTER` overrides the case expression with a colon-separated
GTest filter. The effective filter is recorded; filtered runs do not replace the
complete default mustpass run.

The runner preserves `TestResults.qpa` and parses dEQP's own Pass/NotSupported/
Fail/Exception/Crashed counters. GTest alone treats NotSupported as success, so its
passed count is not used as a conformance result. A failed or interrupted run
retains its log and source record. No backend-specific skip expectations have
been added for the Metal implementation.
The provenance also records individual QPA status counts, so quality warnings
are visible separately from actual `Pass` results.

The initial compute subgroup completes 195 cases: 193 Pass and two NotSupported
cases requiring the unexposed optional `OES_shader_image_atomic` extension.
The attachmentless framebuffer subgroup passes all 72 cases. The complete
37,802-case list now finishes with 13,870 Pass and 23,932 NotSupported results,
zero failures/crashes/exceptions and no quality warnings on Apple M2/macOS 27.2.
The full QPA and source/client hashes are preserved in the current checkpoint;
this is not certified conformance or coverage of other devices.


### CTS test-input patches

Conformance-only corrections live under `patches-cts`, separately from the ANGLE
production series. `prepare-cts-tests.py` verifies the CTS gitlink in `ANGLE_COMMIT`,
applies the recorded series without replacing the real index or conflicting
edits, and emits the CTS commit/tree and patch hashes. The dEQP runner records
that identity alongside the ANGLE source/client hashes.

The sRGB-decode tests must require `EXT_texture_sRGB_decode` for every format.
The [R8](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_sRGB_R8.txt)
and [RG8](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_sRGB_RG8.txt)
format extensions do not depend on the optional
[decode-control extension](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_texture_sRGB_decode.txt).
Without it, `GL_TEXTURE_SRGB_DECODE_EXT` correctly produces `GL_INVALID_ENUM`.
The test-input patch checks that requirement consistently; it does not change
Metal capabilities or add backend-specific skip expectations.

The shader executor transports floating test payloads through flat integer
varyings, using `floatBitsToUint`/`uintBitsToFloat` and separate columns for
matrices. The tested operations and input bit patterns are unchanged. This avoids
Metal Shader Validation rejecting NaN/Inf interpolants in the test's passthrough
stages. Both vertex-output and fragment-input transport are covered; all 36
`functional.shaders.builtin_functions.precision.frexp` cases pass with validation
enabled. This is a CTS harness correction, not a relaxation of numerical checks.

The helper-invocation framebuffer fixture checks `GL_MAX_SAMPLES` before issuing
storage commands. Its former late check left `GL_INVALID_OPERATION` pending when
an 8-sample case exceeded the device limit, contaminating the next case in the
shared context. Unsupported sample counts now return NotSupported without
issuing the invalid GL operation; supported counts execute the original test.

`python3 tests/test-cts-patches.py` verifies gitlink pinning, repeatable application,
preservation of the ANGLE and CTS indexes, and rejection of conflicting edits or
an unpinned CTS checkout.
