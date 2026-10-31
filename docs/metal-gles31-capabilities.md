# Metal GLES 3.1 capability audit

Source baseline: `b4a1ba9ec8896ce2b93d100f1d4224c56c14ebec` from Chromium ANGLE.
This inventory separates implementation, executed tests and production exposure;
it is not a conformance certification.

The current selectable profile is documented in [Selecting a Metal GLES
profile](selecting-metal-gles-profile.md). The default remains GLES 3.0; the
explicit `gles31` build exposes GLES 3.1 and MDI on eligible devices without the
internal compute-test flag. Public EGL, compute, synchronization and GPU-generated
MDI probes also pass on an A14 iPhone 12 with iOS 27.0.1 and Metal validation;
see [physical-device tests](ios-device-metal-tests.md). The full mustpass results
below concern the macOS internal profile and do not establish iOS conformance.

| Area | Source evidence | Limits and validation scope |
| --- | --- | --- |
| Context profile | `DisplayMtl::getMaxSupportedESVersion` selects GLES 3.0 or the explicitly enabled GLES 3.1 profile under device gates | The maximum conformant version remains GLES 3.0 |
| Compute translation | Kernels, five native invocation/grid inputs and constant workgroup size execute through native and public GLES tests | Broad validation on Apple M2/macOS 27.2; focused public EGL probes also pass on A14/iOS 27.0.1 |
| Compute programs | Public GLES compute programs link, dispatch and reload binaries in the isolated internal profile; default uniforms, direct byte-layout UBOs and sampler/image resource maps | Resource limits and program binaries verified in the internal profile |
| SSBOs | Byte-addressed std140/std430, range-based `.length()`, GL binding remapping, shared allocations, descriptor arrays, helper out/inout and native integer atomics pass GPU tests | Robust access remains unexposed; graphics-stage SSBO counts are zero |
| Direct/indirect dispatch | Standard GLES direct dispatch and GPU-generated indirect dispatch execute through `ProgramExecutableMtl::setupDispatch` | GPU-produced arguments and complete AOSP GLES 3.1 mustpass coverage on M2 |
| Images and atomics | Public GLES image arrays, 16 samplers plus four images, nested descriptor aliases and all eight signed/unsigned shared/device atomic functions pass targeted GPU tests | Graphics images/image atomics and robustness extensions remain unexposed |
| Shared memory | Threadgroup references, shared integer atomics, execution barriers and divergent memory-only fences pass GPU tests | Device/pipeline workgroup limits; no robustness extension claim |
| Command memory barriers | Internal ES 3.1 profile closes encoders conservatively, preserves attachments and tracks allocation dependencies without a CPU wait; by-region uses the same stronger path | Conservative encoder boundaries; optional graphics storage writes unexposed |
| Draw indirect | Public GLES native topologies and UInt8/UInt16/UInt32 indexed commands are encoded without CPU argument reads; GPU-generated indexed test covers negative baseVertex | Topology/index conversions covered; no robust-access extension claim |
| Multi-draw indirect | GPU-resident commands, full command-range validation, stride-domain checks and overlapping commands and five upstream MDI regressions | CPU loop of native indirect draws; microbenchmark is not app performance |
| Separable programs | Compute and graphics pipelines use installed component executables; GPU-converted UBOs, explicit varying locations and binary reload pass targeted and upstream tests | Optional graphics storage, geometry and tessellation remain unexposed |
| Attachmentless framebuffers | Device-derived sample limit and default raster sample propagation pass all 72 dEQP cases | Complete profile and device-family validation |
| Texture gather | Core float/int/uint/shadow samplers, channels, offsets and array layer selection translate to native Metal gather operations | Optional GPU-shader5 gather forms remain unexposed; complete profile validation |
| Multisample textures | `TextureMtl::setStorageMultisample` and `textureMultisampleANGLE` exist | 2D MSAA and interpolation covered; multisample arrays/sample shading optional |
| Limits and queries | Internal caps include 48 texture units, 48 UBO bindings, 44 combined uniform blocks, device-derived workgroup dimensions and 64 KB UBOs on Apple GPUs | Complete mustpass queries on M2; focused profile and device-limit checks on A14 |
| Packaging | Desktop and iOS manifests verify patched sources, selected profiles, platforms and runtime libraries; libJGLIOS imports the pinned shared series plus iOS overlays | Java/JNI compute-to-array/indexed MDI and the gears sample pass on A14/iOS 27.0.1 under Metal validation; this is distinct from standalone EGL acceptance |

The native indirect patch adds no public feature gate or context-version
override. Its white-box tests deliberately use a GLES 3.0 context and native
MSL kernels. Passing them cannot authorize GLES 3.1 or MDI exposure.

The translator patch is also internal development work. Tests compile GLSL ES
3.10 through ShaderLang and execute the resulting MSL through ANGLE's native
Metal encoder. They do not link a public GL compute program or call
`glDispatchCompute`. They validate all invocation builtins in a three-dimensional
direct/indirect grid, a GPU-produced indirect dispatch, and shared-memory exchange
between 128 threads across SIMD groups. The storage extension checks std430 input
and std140 output in two ranges of the same allocation, both matrix orientations,
vec3/scalar packing, bool representation, helper out/inout and compound vector
updates. Source, padding and guard bytes are verified as well as outputs.
The indirect producer now writes dispatch arguments directly through an SSBO
into private Metal storage, consumed by the next dispatch without image copying.
Production context and extension gates remain conservative; an explicit macOS test-only GN flag is described below.

Kernel tests additionally exercise Metal linked-stage selection, the executable's
compute pipeline cache and serialization/reload before dispatch. A separate
public GLES 3.0 test draws with vertex/fragment uniforms, saves/reloads a program
binary and draws again. The Metal binary header rejects the previous native
format rather than reading its resource maps using the new layout.

Memory-only GLSL fences use native memory fences, never an execution rendezvous.
Apple's [Metal Shading Language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf),
section 6.16.3, specifies `atomic_thread_fence` for Apple silicon with Metal 3.2
and later. Shaders that use those fences carry a requirement through compiler reflection,
library cache keys and program binaries. On Apple silicon with macOS 15/iOS 18 or
newer, they compile as MSL 3.2, using conservative sequentially consistent fences.
Other translated native tests retain their MSL 2.1 validation. Existing fragment
pixel-local-storage barrier handling is unchanged.

The complete profile and extension must be checked against the
[GLES 3.1 specification](https://registry.khronos.org/OpenGL/specs/es/3.1/es_spec_3.1.pdf)
and the separate
[EXT_multi_draw_indirect contract](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_multi_draw_indirect.txt).

## Internal GLES API profile

`angle_metal_enable_compute_tests = true` is accepted only for macOS test builds.
It exposes an experimental ES 3.1 integration context. The complete AOSP mustpass
result on Apple M2 is recorded below; other devices and iOS are not covered. The
normal build still exposes ES 3.0. Release manifest generation asks GN for the resolved flag
value and refuses to package an internal profile, including imported GN arguments.
The MDI tests explicitly enable ANGLE's existing emulated-multidraw test feature;
the implementation encodes one native indirect draw per command on the CPU.

The public API suite covers SSBO range aliases, default uniforms and binary
reload, GPU-generated 3D dispatch, shared/device atomics and returned old values,
compare-swap success/failure, GPU-written std140 UBOs, block arrays, image-to-sampler transitions,
GPU-generated array/indexed indirect and MDI, cross-frame reuse, zero commands and
frontend validation. Memory-only fence tests use divergent control flow before a
common workgroup barrier. The internal caps and these targeted tests do not
establish full GLES 3.1 support or conformance.

## Descriptor arrays and atomic counters

Compute SSBO/UBO block arrays select independent buffer ranges through arrays of
native device pointers. Each element is flattened to its own kernel parameter;
GL block reflection includes the block array element when assigning actual slots.
Runtime SSBO lengths select the corresponding range-size metadata. UBO arrays
use the twelve reserved compute slots, including the gaps at 17/19.

Atomic counters reuse ANGLE's common counter-to-storage lowering, restricted to
one compute counter-buffer binding. Its byte-addressed device buffer uses slot
22 and the exact GL range offset; driver offset corrections remain zero. Default
uniform layout excludes atomic counters. The common shader-write invalidation
also notifies buffers written exclusively through atomic counter bindings, so
cached vertex/index/uniform conversions cannot retain old data.

## Aggregate storage values

Fixed arrays (including nested arrays), structs, whole matrices and strided matrix
columns use generated layout accessors. Values live in ordinary thread storage;
loads/stores transfer individual scalar components at GL offsets/strides and
preserve padding. `out`/`inout` use scoped copies. Selected vector components have
separate gather/scatter helpers, so writing `.xy` does not read or write `.z`.
Signed storage increments retain wraparound and pre/post return semantics.
The native Metal nested-array spelling uses nested `metal::array` types.

## Compute image descriptors

Compute texture slots are distinct from sampler slots. The native encoder accepts
16 sampled textures together with four image descriptors; unused sampler/image
resource-map entries use out-of-range sentinels. Image arrays occupy consecutive
texture slots. Nested arrays use both the flattened parent index and the inner
array length when resolving linked uniforms, including after program binary reload.
The Metal binary header changes when this mapping changes.

Tests use non-identity GL unit assignments, independently read each written texture
through a sampler, and preserve SSBO guard regions. They exercise implicit-LOD
compute sampling, imageSize, write-only rgba32ui arrays and read/write r32ui arrays.
Layered 3D, 2D-array and cube images use native mip views. Non-layered volume
slices, null descriptors and compatible format views are covered below. Optional
graphics-stage image access remains unexposed.

## Byte indices in indirect draws

Unsigned-byte indices are promoted to UInt16 using ANGLE's GPU conversion cache.
The full source allocation is converted, so GPU-owned firstIndex and signed
baseVertex keep their original meanings. Indirect draws explicitly disable the
direct-draw CPU conversion fallback. Shader writes invalidate the cached result.
A regression disables cheap render passes, starts rasterization immediately before
conversion, and checks attachment preservation and six frames of GPU-written
indices/arguments with direct, tightly packed and padded multi-draw commands.

## Layered image views and integer builtins

Images retain the original Metal allocation across layered mip views and
non-layered cube/array views. imageSize reflects the selected view. Image loads
check every coordinate, returning zero outside the view, and out-of-range stores
are discarded. GPU tests compare 3D, signed array and cube writes with independent
framebuffer reads, preserve lower mip levels, and modify one cube face through a
2D alias. Two-dimensional targets ignore the layered/layer arguments.

The translator implements bitfield extract/insert/reverse, population count,
least/most significant bit queries, carry/borrow and signed/unsigned extended
multiplication. Signed overflow is avoided with unsigned arithmetic and native
high-product operations. The tests cover zero/full-width bitfields, negative
signed values, scalar/vector calls, storage out arguments and partial swizzles.
CPU references use bit loops and 64-bit arithmetic; source and padding are checked.

Internal GL binding capacities account for all three stages. The production
profile retains its original 32 texture units and UBO bindings; an independent
package probe checks those limits as well as the ES 3.0 gate.

Runtime-sized arrays support indexed access and length queries. Whole-array
assignment and function arguments are prohibited by GLSL ES 3.10 section 4.1.9;
they are not missing backend features.

## Link-time compute pipeline validation

Public compute links and binary loads create the native function and pipeline
before reporting success. Native workgroup-thread and static shared-memory limits
are checked there, including layout padding absent from frontend accounting.
Native compiler rejection becomes a failed GL link with an info log. The same
result path applies to parallel and sequential library compilation, including
library-cache hits. Context pipeline caches are updated on the context thread.

Regressions compile a padded shared record that exceeds the physical Metal limit,
require failed linking without a GL error, and exercise successful cached binary
loads in both compilation modes. The successful case uploads 4816-byte default
uniform arrays twice, uses distinct SSBO ranges, then deletes both programs before
readback. It checks upload independence, resource lifetime and untouched guards.

## Separable compute programs

Compute-only program pipelines use the component program executable for dispatch,
including its workgroup size, uniforms, resource maps and binding state. The
frontend keeps executable references alive across stage changes and program
deletion. glUniform targets the active shader program while execution uses the
installed compute component; glProgramUniform updates that component directly.
Tests switch to a binary-loaded component, keep a different active uniform target,
change SSBO ranges and uniforms without changing stages, and exercise indirect
dispatch in both compilation modes. Graphics separable pipelines use installed
stage owners and GPU uniform conversion, as described below.

## Indirect line loops

Indexed line loops use a GPU-generated ordered line list, including the closing
edge of each restart segment. Array loops use the procedural array packet path.
Both preserve the order of primitives within each logical instance; splitting
all strips from their closing edges reordered blended instanced draws. Counts
below two and zero instances produce no line. No command count or index value is
read on the CPU.

Regressions compare complete images with independently assembled line loops for
arrays and all three index widths. They check single and multi-draw commands,
tightly packed and padded strides, minimal argument allocations, zero commands,
source guards, restart/provoking conventions and attachment preservation across
compute. The final paths encode one native draw per GL command; array conversion
uses two native chunks per logical instance within that draw. This is a
correctness result, not a performance claim.

## GPU conversion for graphics uniforms

Graphics UBOs retain the existing Metal ABI, with a cached compute conversion when
GL and native layouts differ. The copy map is built from reflection alone. The
GPU transposes row-major matrices, repacks arrays and normalizes four-byte GL
booleans to native boolean bytes. Padding and missing trailing source bytes become
zero. Conversion covers all complete or partial blocks after the cached source
offset, and uses the existing shader-write invalidation and allocation tracking.

Preparation happens before render encoder acquisition; source contents are never
mapped by this conversion. Binary loading reconstructs conversion metadata without
changing the program binary ABI. The kernel remains compatible with MSL 2.1;
64-bit source offsets are passed as pairs of 32-bit fields. Full range-aware
robustness across consumers remains a separate requirement.

## Indexed primitive conversion

GPU-generated indexed commands can expand points, independent lines/triangles,
strips, fans and loops into ordered UInt32 primitive lists. The kernel handles
restart boundaries, incomplete primitives, signed baseVertex, instancing and
first/last provoking conventions. Valid all-ones byte/short indices remain
vertices when restart is disabled; UInt16 strips avoid Metal's fixed restart.
A private scratch allocation is reused between ordered compute/render encoders,
including fast loop closing packets. Its size does not multiply with MDI command
count, and memory trimming releases the context's reference.

The strict suite passes 38 Metal tests with API and Shader Validation enabled,
plus 94 compiler/range tests on Apple M2. The indexed regression compares 420
combinations, and a separate array-loop case checks 64 GPU-generated commands in
distinct cells. Reference readbacks precede the GPU producer. No readback occurs
between producing and consuming the actual indirect commands.

The direct indexed fan oracle exposed an existing flat-shading defect: the first
convention uses the pivot, whereas
[ANGLE_provoking_vertex table 2.12](https://raw.githubusercontent.com/google/angle/main/extensions/ANGLE_provoking_vertex.txt)
requires vertex i+1. Direct conversion of incomplete primitives can also attempt
an empty allocation. Fan/loop references therefore assemble independent primitive
lists from the specification, and empty references issue no draw. Direct and
indirect conversions implement that assembly; the oracle does not reproduce the
old defects. The bounded procedural packet handles array commands without a
CPU-known argument count.

## Image aliases and larger native limits

Compute image2D values carry a planar handle, an alternate 3D handle and a slice
number. The native entry point initializes that local representation, including
nested image arrays and helper arguments. Slots 20..23 hold alternate volume
handles and buffer 23 supplies four slice indices. Both native handles are rebound
on every dispatch. Selected mip views retain the original allocation, so writes
through a slice are visible through overlapping image3D/image2D bindings in the
same shader after its image memory fence. No temporary slice copy is involved.
The current binary ABI is MCP11; older native resource/array-packet records are rejected.

Immutable writable textures permit Metal pixel-format views at creation, including
RGBA8 storage accessed as R32UI. Null bindings return zero sizes/loads and discard
stores. Tests cover aliases, slice changes, same-slice writes, mixed 2D/3D/null
bindings, out-of-bounds stores, binary reload and deletion with queued commands.
Full image format compatibility still needs systematic coverage.

The internal profile uses device workgroup dimensions and validates each native
pipeline at link. Apple GPUs additionally expose 64 KB uniform blocks, with
combined component limits computed from the actual per-stage block limits.
A GPU producer fills every word of a 64 KB block. A binary-loaded compute program
copies it; vertex and fragment programs consume the same range. Final comparisons
include both complete buffers and their guards. The production profile keeps
its existing limits.

On Apple M2/macOS 27.2, tree `321b973b5cd6356a3ef03136aa5a518578ab571d`
passes 41 strict Metal integration tests and 94 compiler/range tests with Metal
API and GPU Shader Validation. The upstream compute suite executes 91 tests,
with no failures, and records eight explicit skips for its resource-limit or
optional graphics-image, texture-buffer, buffer-storage and packed-vertex cases.
The preserved results are in `build/metal-volume-test-verified`. This remains a
partial integration profile, not a GLES 3.1 conformance result.

## Boolean storage and direct primitives

Boolean SSBO scalar/vector copies use typed gather/store helpers, preserving the
four-byte GL component layout and normalizing every nonzero word to one. Targeted
GPU coverage includes noncanonical input words, assignment return values, helper
inout, swizzles, binary reload and complete source/output/guard comparisons.
The upstream storage suite executes 54 tests with no failures, and records four
explicit skips for graphics SSBO capabilities that are declared as zero.

Direct fan/loop, restart and last-provoking conversions reuse the ordered GPU
primitive-list converter. Direct calls upload their CPU-known command fields;
client indices are uploaded and buffer-owned index contents remain on the GPU.
Arrays use procedural identity indices with the API's count as the allocation
bound. Byte loads handle client uploads and GL-valid nonzero source offsets.
Incomplete calls return before allocating an empty converted list. Active
transform feedback retains its existing dedicated array path.

A GLES 3.0 regression compares 4,704 combinations against independently assembled
primitive lists: seven modes, array/EBO/client sources, all three index widths,
restart, both conventions, six counts and instancing, with procedural or buffered
vertices. It checks complete blended images with culling and Metal Shader
Validation. The direct command upload pool uses 64 KB blocks so ordinary draws
append packets rather than allocating one tiny native buffer for each command.

Tree `0c52b13528ffdf6541b500442bbc3daabd57274d` passes 43 strict Metal tests,
94 compiler/range tests, 91 upstream compute tests and 54 upstream storage tests.
Both normal/internal profiles pass all 66 upstream UBO cases. The normal profile
also passes nine Metal tests and 67 compiler cases. Its immutable candidate is
`build/metal-direct-verified/native/angle/osx/arm64`, a GLES 3.0 test configuration
with assertions enabled. Loading/profile and HDR/SDR probes pass; physical display
headroom is one. This is not a release/performance or physical HDR-panel result.

## Graphics pipelines and array indirect conversion

Graphics pipeline stages retain their owning program executables. Shader variants,
uniform conversion pools, resource mappings and binary state follow the installed
vertex or fragment component. Explicit varying locations match between differently
named matrix/array interfaces. The upstream pipeline checkpoint executes 40 cases
with seven explicit optional-feature skips, plus two custom ownership/binary cases.

Array indirect calls now convert triangle fans, line loops and provoking-vertex
representations on the GPU. Finite per-vertex storage bounds determine scratch
allocation without reading commands. Procedural, constant and instance-only input
uses a fixed packet and specialized vertex/instance ID mapping. A line loop uses
one complete segment list, preserving blending order across instances.

The targeted array regression compares 2,240 complete images against an independent
primitive-list reference. It includes seven topologies, eight input layouts
(procedural, float VBO, instance-only, zero stride, interleaved relative offsets,
fixed-point conversion, divisor three and a divisor above GLsizei range), both
provoking conventions, array restart toggles, minimal 16-byte commands, two MDI
strides, nonzero base instances, program binaries and incomplete/zero commands. Full current-source regression results are recorded separately from
these targeted results.

The procedural packet kernel is also executed for 2,160 boundary combinations
using the production conversion source. A 64-bit host oracle checks expanded
counts, zero/odd primitives, GLsizei limits, high first vertices, base instances,
source contents and surrounding guard bytes. This test reads packets after the
GPU finishes; the rendering path does not read indirect arguments on the CPU.

## Vertex binding state and optional resource rejection

Binding changes and GPU content notifications fan out to every attribute attached
to that binding. Observer masks retain shared bindings while any enabled attribute
uses them. A dedicated compute-to-vertex case checks two fixed-point converted
views, a disabled sharing attribute, GPU rewrites and buffer storage replacement.

Active graphics atomic counters are rejected cleanly because their declared stage
limits are zero. Inactive atomic-counter barriers reuse ANGLE's common removal
pass. The upstream negative shader and inactive-barrier cases execute without
translator assertions. Tests requiring nonzero graphics counters/storage query
the applicable stage limits before running.

The wider upstream ES 3.1 runner executes 121 cases with 51 explicit optional
skips. Stable-geometry culling independently verifies three complete rendered
views, GPU-written commands and atomic visibility counts. Full dEQP coverage,
performance/capture measurements and the production feature gate remain separate
acceptance requirements.

## Current macOS validation checkpoint

Tree `f6dd4d04bf3da4dc855fb147f2793a7f7ce1c7bc` passes the following on Apple
M2/macOS 27.2 with Metal API Validation and abort-on-fault Shader Validation:

| Suite | Executed | Explicit optional skips |
| --- | ---: | ---: |
| Strict Metal integration | 52 | 0 |
| Compiler and command ranges | 99 | 0 |
| Upstream compute | 91 | 8 |
| Upstream storage | 54 | 4 |
| Upstream graphics pipelines | 40 | 7 |
| Upstream wider ES 3.1, including MDI | 126 | 51 |
| Internal UBO regressions | 66 | 0 |
| Normal-profile Metal integration | 10 | 0 |
| Normal-profile compiler | 72 | 0 |
| Normal-profile UBO regressions | 66 | 0 |

The complete, unfiltered 37,802-case AOSP GLES 3.1 mustpass list finishes with
13,870 Pass and 23,932 NotSupported results. There are no failures, exceptions,
crashes, skips or quality warnings. NotSupported results identify unexposed
extensions, later language versions or resources outside declared limits; they
are not counted as passes. CTS fixture corrections and their separate source
identity are documented in `macos-metal-tests.md`. This is a test result on one
hardware/OS configuration, not certified conformance or iOS/Intel validation.

Stable-geometry culling verifies three byte-exact images, with 96, 35 and 12
visible objects, GPU-produced commands, counters and allocation guards. GN header
dependency checks, LF/CRLF patch application and the patch/manifest/CTS helpers
pass. All proof suites identify the same patched ANGLE source.

The preserved checkpoint is `build/metal-compute-indirect-verified`. Its native
libraries under `native/angle/osx/arm64` use the actual production arguments
(`angle_assert_always_on = false`, internal compute flag false). Runtime checks
against those staged libraries confirm GLES 3.0, 32 bindings and 16 KB uniform
blocks, plus five HDR/SDR phases. Both Metal validation layers are enabled for
these runtime checks. Display headroom is 1, so this does not demonstrate HDR
panel brightness. The experimental GLES 3.1 tests use separate binaries/arguments;
their passing results do not change the production exposure gate.

The checkpoint's `validation` directory contains logs, JSON, QPA, hardware data,
images and a one-frame `.gputrace`. Capture uses API Validation with Shader
Validation disabled in a separate run because combining the tools stalls on the
tested host. Strict correctness runs keep both layers enabled. `source-inputs`
preserves the patch series, CTS corrections, build arguments, scripts and tests;
`SHA256SUMS` covers the snapshot.

A separate, quiet-GPU microbenchmark interleaves the three draw paths for 96
visible objects, discards one warmup cycle and records eight samples per method.
Every sample matches the reference image. Metal instrumentation is disabled;
ANGLE test assertions remain enabled. Medians are in microseconds:

| Method | CPU encoding | GPU elapsed | Draw API calls |
| --- | ---: | ---: | ---: |
| Direct | 32.479 | 22.541 | 96 |
| Indirect loop | 25.312 | 22.811 | 96 |
| MDI | 22.104 | 22.811 | 1 |

MDI still encodes 96 native indirect draws on the CPU. These measurements describe
this small workload on M2; they are not representative engine performance and do
not establish a hardware indirect-command-buffer path.

## Additional dEQP findings

The wider conformance run exposed two mandatory cases beyond the targeted compute
suite. Attachmentless framebuffer samples now use the device-derived maximum;
render pass defaults select a supported native sample count and forward it to
Metal. All 72 cases in `functional.fbo.no_attachments` pass with validation enabled.

Default-block uniform array layout lookup now removes only the innermost array
suffix, preserving outer array indices, matching the Vulkan backend's handling.
The uniform/uniform-block reflection subgroup completes 1,692 cases: 1,240 passes,
452 NotSupported results for declared capabilities, and no failures or exceptions.
These changes follow the preserved 46ddad8 candidate; their broader validation is
recorded in separate dEQP result directories.

Nested vector array constructors no longer enter scalar/vector coercion: array
dimensions must survive the explicit-cast pass. The compiler regression and the
original fragment/vertex dEQP reproductions pass.

Core `textureGather` and `textureGatherOffset` use native Metal gather operations,
including component selection, shadow comparisons and rounded/clamped array
layers. Gather offsets report the native -8..7 range. The complete dEQP texture
group executes 473 cases successfully and records 2,096 NotSupported results for
unexposed optional extensions, with no failures. A public compute regression
independently checks six gathered vectors, guard bytes and program binary reload.
The production profile remains GLES 3.0 pending the complete acceptance matrix.

Fragment `gl_HelperInvocation` now uses Metal's per-invocation
`simd_is_helper_thread()` query, including calls from user helper functions.
All 60 supported dEQP helper-invocation cases pass; 20 cases requesting samples
beyond the device limit are NotSupported. Flattened struct varying leaves retain
their interpolation qualifiers without replacing an explicit member qualifier.
All 129 supported multisample-interpolation cases pass, with 40 NotSupported
sample configurations.

Two-argument `atan` uses Metal's precise `atan2` rather than its fast math variant,
which selected the wrong quadrant for some zero-x inputs. The four low-precision
dEQP cases now report Pass without quality warnings. A storage-fed compute test
checks positive/negative zero, both y signs, quadrants and binary reload.

MDI validation now checks the final command interval before any native encoding.
The original frontend checked only the first command, accepting out-of-buffer
tails and huge command counts. Checked arithmetic validates the complete byte interval, including overlapping
positive strides, and rejects overflow. Negative strides are rejected as
`GL_INVALID_VALUE`, respecting the nonnegative `sizei` domain. A direct
validator regression reproduced the bug without submitting invalid commands to
Metal; the corrected public API cases and all five upstream MDI tests pass.

The cached native render-pass descriptor now updates its default raster sample
count on every conversion, including passes with attachments. Reusing the old
attachmentless count could produce a 1-sample encoder with a 4-sample pipeline.
A public regression alternates six attachmentless/MSAA/resolve transitions and
checks the complete output image. The 152-case mixed attachmentless/helper
sequence completes with 132 Pass and 20 NotSupported results under validation.
