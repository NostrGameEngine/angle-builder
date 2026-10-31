# Metal GLES 3.1 implementation

The first delivery targets macOS Metal. The iOS feature port follows review of
the macOS result. Repository synchronization and the iOS compatibility audit
are preparatory work; they do not enable new iOS capabilities.

## Baseline

Use the Chromium ANGLE repository as upstream and pin a full commit SHA.
The GitHub mirror can lag behind Chromium. Preserve the previous dependency
checkout and its local HDR changes while preparing `/store/DEV/angle`.
Rebase compatibility patches onto the selected revision, removing a patch
only when the corresponding behavior is present upstream. Keep compatibility
changes separate from experimental compute and indirect changes.

## Implementation order

1. Update the pinned source and HDR patches. Build macOS arm64, run HDR/SDR
   regressions, and record the source, patch and toolchain identities.
2. Audit the complete GLES 3.1 surface, including separable programs and
   multisample textures. Keep the production Metal version at GLES 3.0 until
   the requirements and tests of the newer profile are satisfied.
3. Extend the existing MSL translator and Metal program executable for compute
   kernels, workgroup builtins, local sizes and pipeline caching. Assign Metal
   resource slots explicitly, accounting for ANGLE's reserved bindings.
4. Implement SSBO layouts and range-aware reflection, shared memory, atomics,
   images and synchronization. Track writes and lifetime against the underlying
   Metal allocation, including aliases and storage replacements.
5. Encode direct/indirect dispatch and draw commands using GPU argument
   buffers. Adapt unsupported index/primitive representations on the GPU.
   Never read indirect arguments on the CPU to substitute direct commands.
6. Add multi-draw indirect as a separately validated extension. A CPU loop
   encoding native indirect draws is acceptable; it is not a performance claim
   or a claim of one hardware command.
7. Exercise compute-to-compute, compute-to-draw and render-to-compute transitions
   and resource reuse. Compare final pixels/bytes with independent expected
   results. Readback belongs only at the final test boundary.

## Ownership

The compute translator first maps the five invocation/grid builtins to native
Metal kernel parameters. `gl_WorkGroupSize` remains the GLSL compile-time
constant. `gl_NumWorkGroups` uses `threadgroups_per_grid`, including indirect
dispatch, without a CPU read of its argument buffer. Compute driver uniforms
use a dedicated struct rather than the graphics depth/viewport fields.

The first translator integration tests compile GLSL ES 3.10 into MSL and execute
that output on Metal with deterministic byte/pixel checks. Native MSL-only
encoder tests remain separate. Shared declarations are collected into a native
`threadgroup` struct, passed by `threadgroup` reference through helpers. They have
no host-visible layout and must not pass through uniform ABI conversion or be
copied into per-thread storage. GLSL `barrier()` maps to a whole-workgroup barrier
with `mem_threadgroup`; memory-only fences require separate handling. Resource
layouts and public GL program/dispatch wiring are validated independently before
profile exposure.

- `compiler/translator/msl`: kernel entry points, language builtins, storage
  layout, shared memory and language barriers.
- `ProgramMtl` / `ProgramExecutableMtl`: linking, reflection, resource maps,
  serialization and compute pipelines.
- `ContextMtl`: GL state, dispatch, indirect draw and command dependencies.
- `BufferMtl` / `TextureMtl`: storage identity, offsets, access invalidation and
  resource lifetime; reuse existing command-buffer resource tracking.
- `mtl_command_buffer`: native encoding and resource dependencies.
- `DisplayMtl`: device-derived limits and truthful public capability gates.
- `angle-builder`: reproducible patches, builds, package manifests and tests.

## Validation and acceptance

Run the existing checkout/patch tests before building. Use upstream ANGLE tests
for shader translation, compute, storage, images, barriers and indirect draws,
plus targeted regressions for newly introduced risks. Record the actual GPU,
OS, backend, GL version, limits, toolchain and SDK. Validate with Metal API
validation. Keep build-only results separate from executed GPU tests.

A compute demo does not establish GLES 3.1 conformance. The final macOS
acceptance requires GPU-generated commands, correct cross-frame dependencies,
the existing GLES 3.0 regressions, and the relevant GLES 3.1 tests. Package and
iOS validation are separate acceptance stages.

## Storage and compute program integration

Compute storage uses byte-addressed Metal `device` buffers. GLSL std140/std430
member offsets, array and matrix strides determine addresses; native Metal
struct layout is never used to reinterpret application storage. Layout shared
and packed use the backend's deterministic std430 layout. Slots 0..7 are
reserved for storage; 19/17 remain default/driver uniforms and 24 the uniform
buffer argument buffer. The link step maps block names to actual slots, so a GL
binding point is not mistaken for a fixed shader resource slot.

Storage instance pointers are gathered into a thread-local parameter struct
for helpers, while the pointed-to data stays in device memory. The first storage
stage covers scalar/vector accesses, fixed/runtime arrays and scalar accesses
to nested structures and matrices. Aggregate gather/scatter and block arrays
must be handled explicitly before advertising complete storage support.
Runtime-array length uses the GL-visible range size, passed as compute driver
metadata, rather than the size of the underlying Metal allocation.

The next program stage extends the existing Metal link/library/cache path to
compute stages, then uses the same reflection to bind buffers and uniforms.
Public profile exposure remains gated on the full resource and synchronization
contract; the native translated-shader tests stay available during integration.

Upstream `program_serialize_data_version.py` hashes the compiler and backend
sources listed in `angle_program_serialize_data_version.gni`. Metal files listed
in `metal_backend.gni`, including the shared command-conversion header, therefore
invalidate cached program blobs when their contents change. Keep using that
source fingerprint; the native MCP header additionally rejects incompatible
resource/packet layouts.

## Internal GLES dispatch integration

The macOS-only test flag `angle_metal_enable_compute_tests` permits public GLES
API integration before full profile completion. It requires a test build and is
rejected by release manifest generation using GN's resolved value. Production
continues to expose GLES 3.0.

Compute uses the existing frontend `MarkShaderStorageUsage` invalidation and native
allocation dependency tracking. Default uniforms upload before encoder acquisition;
SSBOs bind their GL range offsets and available sizes. Compute UBOs use the same
readonly byte-addressed layout lowering, avoiding graphics' CPU conversion path.
Their twelve slots are 8..16, 18, 20 and 21; 17/19 remain driver/default uniforms.
Sampler and image preparation completes before obtaining the compute encoder.
Image names are matched using the compiler's emitted names; image binding points
follow GLES layout qualifiers. Shader memory-only fences use Metal 3.2
`atomic_thread_fence`, with their requirement retained in reflection, caches and
program binaries. They never substitute an execution barrier in divergent code.

Native-topology array and indexed indirect draws consume GPU command buffers.
Byte indices, primitive restart, fans, loops and provoking conventions use GPU
conversion. Procedural array packets avoid allocations proportional to an
unknown argument count. Multi-draw loops encode native indirect commands; the
frontend checks the complete command interval before encoding. Production
GLES 3.1/MDI exposure remains a separate acceptance gate.

## Aggregate byte-layout accessors

Whole fixed storage values are gathered into native thread values and scattered
back using explicit scalar offsets. Struct/native alignment is never reused as a
GL byte layout. Generated helpers are emitted before their first consuming
function, after the value types have been declared; this accommodates synthetic
struct equality functions interleaved by the existing struct sorter. Arrays use
bounded loops and nested native array types. Matrix columns use their actual GL
component stride. Scoped `out`/`inout` copies preserve the same contract.

Vector swizzle helpers load/store only the selected components. They must not
load or rewrite a whole vector when another invocation owns different components
of that vector. Prefix/postfix storage mutations are lowered before generic
thread-reference rewriting, preserving device addresses and signed wraparound.

## Indirect UInt8 index conversion

The indirect path must promote an entire byte index allocation on the GPU before
encoding its native UInt16 draw. Index ordinals and signed baseVertex remain in
the GPU-owned command; the command itself needs no rewriting or CPU readback.
The existing index-conversion cache can be reused if shader writes invalidate it.
Conversion must explicitly bypass the direct-draw CPU fallback, even on devices
where ending a render pass is expensive. Preserve the render target across the
compute conversion and restore raster state before encoding the indirect draw.

Validation must include GPU-generated indices and arguments, nonzero firstIndex,
negative baseVertex, tight/padded MDI strides, cross-frame cache invalidation and
a render pass active immediately before conversion. Primitive restart and
provoking-vertex/topology rewrites require separate GPU algorithms.

## Graphics uniform conversion on the GPU

Graphics stages retain their existing native UBO ABI. When GLSL and Metal layouts
differ, build an immutable byte-copy map from linked reflection metadata, then
convert the original allocation with a compute kernel. Map entries distinguish
ordinary bytes, four-byte GLSL booleans normalized to native boolean bytes, and
zero padding. Matrix entries encode both orientations and array strides. The CPU
never maps source contents. Reuse the existing per-buffer conversion cache and
shader-write invalidation; program binaries rebuild maps from their layout data.

Prepare converted buffers before render encoder acquisition. Ending a previous
render pass must preserve its attachments, and resource tracking must retain both
source and converted storage until execution completes. Validate compute-written
row-major matrices, booleans, arrays, remapped ranges, binary reload and cross-frame
cache invalidation using final pixels and unchanged source/guard bytes. This is a
correctness and GPU residency change; performance requires separate measurement.

## Indexed indirect primitive conversion

For indexed commands that need topology, restart or flat-shading conversion,
preprocess the original index allocation and the GPU-owned command together.
Produce an ordered UInt32 point/line/triangle list plus native indexed indirect
arguments. Source allocation size bounds the output allocation; command counts,
firstIndex, signed baseVertex and instance counts remain GPU inputs. Preserve
primitive order and triangle winding when selecting the provoking vertex. Restart
resets strip/fan/loop state and discards incomplete list primitives. Byte indices
retain their original restart sentinel before promotion.

A sequential per-command kernel is an initial correctness path, with conservative
allocation bounds and no performance claim. Compare every primitive mode against
direct GLES draws, including first/last provoking conventions, all index widths,
restart boundaries, zero commands, multi-draw strides, negative baseVertex,
blending, culling and attachment/source guards. Array conversion uses the bounded
procedural packet described below because a procedural vertex shader has no
CPU-known index allocation that can bound generated storage.

GLES 3.1 section 12.1.2 permits only DrawArrays and DrawArraysInstanced while
transform feedback is active and unpaused. Indirect draws must retain the standard
frontend error in that state; paused feedback needs a normal rendering regression.

## Null image bindings

Allow unbound image units to reach Metal as nil textures and clear every active
image slot on each dispatch. Image size helpers must call is_null_texture before
querying dimensions; zero extents then make existing load/store bounds checks
return zero and discard stores. A native MSL 2.1 probe validates both bound and
nil textures with API and Shader Validation, without a dummy texture or a new
resource layout. Regressions cover all four image families, stale bindings,
program binaries and deletion while prior commands remain queued. Invalidate
program binaries containing the previous unguarded image helpers.

The direct flat-shading defects found by the indirect oracle need an independent
regression and correction. Direct calls have CPU-known counts, so their emulated
primitives can reuse the GPU converter with small uploaded command packets. Raw
client indices can be uploaded; GPU-owned EBO contents must not be read back.
Unaligned EBO offsets require byte loads. Array calls can use procedural identity
indices with a count bound supplied by the API; indirect procedural arrays still
need a separate solution because no CPU-known allocation bounds their GPU count.


## Aliased 3D image slices and native limits

Represent compute image2D values as a pair of native planar/volume handles with a
slice index. Emit a native resource record for the entry point and initialize a
local image record, leaving GLSL image expressions and helper arguments intact.
Unroll descriptor initialization from declared dimensions; the four-image limit
bounds it. Bind alternate texture slots 20..23 and four indices at buffer 23.
Select a mip view of the original volume, preserving aliasing across all bindings.
Do not materialize an independent 2D copy. Clear both handles on every dispatch
and invalidate binary records with the older image ABI.

Allocate immutable writable image storage with pixel-format-view usage so GLES
compatible access formats can use native views. Read the workgroup dimensions
from MTLDevice and retain per-kernel link validation. Validate 64 KB UBOs in the
Apple GPU integration profile before changing production limits, including all
words, GL range offsets, guard regions, binary reload and both graphics stages.

Upstream tests must execute against the Metal integration profile explicitly;
ANGLE's default ES31 instantiation macro omits Metal. Record optional skips and
fail unexpected skips. Correct invalid test inputs separately from backend
behavior: the upstream draw/compute/image regression had four vertices but issued
a six-vertex triangle draw; use the intended four-vertex triangle strip and unmap
its readback buffer before the final draw. Keep Metal Shader Validation enabled.


## Graphics program-pipeline ownership

Graphics pipelines must use the frontend aggregate only for pipeline-level
validation and GL interface/state queries. Native functions and mutable uniforms,
sampler maps, UBO bindings and converted ranges belong to each installed program
executable. Reuse `ProgramExecutable::getPPOProgramExecutables()` so deletion and
relinking follow the frontend's retained component lifetimes. Do not copy mutable
uniform data into a second linked executable.

At draw setup, select the vertex and fragment owners' native variants, combine
their functions in the render PSO and commit only each installed stage's resources.
Prepare UBO conversions before acquiring the render encoder. When one program
provides both stages, prepare and bind its UBO ranges once; when owners differ,
filter blocks by the installed stage. Keep each component's dirty bits, remapping,
program binary data and upload pools. The vertex owner supplies flat-shading and
transform-feedback metadata. Validate actual stage replacement, independent
uniform/sampler updates, binary loading, deletion/relink and transform feedback
against upstream program-pipeline tests before calling this feature complete.


## Array indirect topology conversion

Use CPU-visible vertex-binding metadata only to choose an allocation bound; never
read the command values. With a finite per-vertex attribute bound, reuse the GPU
primitive-list converter with procedural source indices and native array-command
layout. Ignore primitive restart for array calls. Clamp only beyond the accessible
attribute storage; preserve every valid in-bounds command.

Procedural shaders, instance-only attributes and zero-stride attributes have no
finite vertex-count bound. Use a fixed 64-byte GPU packet containing one native
array command and mapping metadata. Two consecutive native instances represent
one GL instance, with each processing half its primitive list. This keeps the
expanded vertex count within uint32 for valid GLsizei commands, without reordering
instances across multiple draws. Map vertex/instance IDs and double instance
attribute divisors; clip the single padded primitive when the count is odd.
Preserve the final command word as the native base instance for EXT_base_instance,
and subtract that base when mapping native instance IDs. Slot 25 holds metadata only
in that specialization.
Keep the ordinary native shader variant, and include the specialization in both
monolithic and separable pipeline cache keys. Verify independent complete-image
oracles for VBO, procedural, instanced and zero-stride inputs, minimal command
allocations, MDI strides, zero/incomplete commands and attachment preservation.

## Texture gather translation

GLES 3.1 requires gather and constant single-offset gather for 2D, array and cube
samplers, including signed/unsigned data and depth comparison variants. Map these
to Metal's native `gather` and `gather_compare`, preserving the documented
(-,+), (+,+), (+,-), (-,-) component order. Select color channels through native
constant component enumerators, and clamp rounded array layers to the valid range.
Cube gathers have no offset overload. Keep the optional GPU-shader5 four-offset
and dynamic-offset operations separate from the GLES 3.1 contract.

Expose the native constant offset range, validate emitted code with a compiler
regression covering all core sampler families, then run the actual dEQP gather
cases for pixels, base levels, wrap/filter behavior and components. Native mapping
alone is not sufficient evidence for these sampling semantics.
