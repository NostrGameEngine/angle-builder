# Native ray queries

The extension targets the current pinned ANGLE revision and the existing Metal
GLES 3.1 patch series. It exposes native acceleration structures and inline ray
queries through GLES/GLSL ES, using Vulkan and Metal backend implementations.
Multi-context scheduling, multiple queues and temporal presentation are outside
this change. GPU resource dependencies and deferred destruction are required.

## API and ownership

Use the draft's private `GL_NGE_ray_query` namespace and eight GLES commands:
generate/delete/test acceleration-structure names, build triangle or AABB BLAS, configure
instances, build TLAS and bind TLAS. GLES names and binding points remain backend
independent. A BLAS contains triangle or AABB geometry; a TLAS contains transformed BLAS
instances. Rebuilding creates a new native generation, while queued uses retain
the generations they reference. Validate input ranges, alignment, transforms,
flags, object kinds, bindings and backend limits before native commands.

`accelerationStructureEXT` is an opaque uniform resource with its own binding
range. `rayQueryEXT` is invocation-local traversal state. Implement initialize,
proceed, confirm, terminate and hit getters with consistent candidate/committed
semantics. Sharing, copying or constructing traversal state is invalid. Use the
real GLSL parser and translator; generated files come from ANGLE's generators.

## Backend mapping

Vulkan uses `VK_KHR_acceleration_structure`, `VK_KHR_ray_query`, buffer device
addresses and their effective-device-version dependencies. Shader output uses
native SPIR-V ray-query operations and acceleration-structure descriptors in
ANGLE's resource bindings. Extend existing resource hazards and retirement.

Metal uses native primitive/instance acceleration structures, build encoders and
MSL intersection queries. Extend existing binding allocation, encoder transitions
and command-buffer retention. Check `supportsRaytracing` and
`supportsRaytracingFromRender` independently of GLES 3.1 and dedicated RT hardware.

Both backends must order geometry writes, BLAS/TLAS builds, traversal reads and
subsequent consumers. This ordering uses one queue and must not introduce routine
CPU/GPU-wide waits. Advertise only implemented, validated shader stages. Target
compute, fragment and vertex with one common language/API.

## Validation and delivery

1. Check native capabilities and freeze the extension specification.
2. Add resource ownership, validation, registry entries and generated entrypoints.
3. Add GLSL types, reflection/linking and compiler acceptance/rejection tests.
4. Implement SPIR-V/Vulkan and MSL/Metal lowering and resource execution.
5. Test hit/miss, distance, barycentrics, IDs, transforms, masks, flags, all three
   shader stages, object deletion and rebuilds while previous work is queued.
6. Use validation layers and real output checks. A software Vulkan implementation
   exposing the needed features can provide functional CI, without hardware RT
   performance claims. Unsupported devices and WebGL must reject exposure.
7. Generate patches after the existing series, verify a clean checkout and repeat
   application, build through the builder and record source/binary provenance.

The preserved fork at `45ed36a7f865d7ac2a603dc9671e440c53ee225a` contains a
historical plan and standalone probe, but no ray-query implementation patch.
Its original ANGLE baseline differs from this repository's current baseline.
