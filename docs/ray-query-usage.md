# Experimental native ray queries

`GL_NGE_ray_query` adds native triangle and AABB acceleration structures and inline ray
queries to ANGLE. It is a private draft extension, separate from the GLES 3.1
profile. Its GLSL types, constants and functions use the `EXT` names from
[Khronos GLSL_EXT_ray_query](https://github.com/KhronosGroup/GLSL/blob/main/extensions/ext/GLSL_EXT_ray_query.txt);
the GLES commands for creating and binding acceleration structures are specific
to this draft. See [the extension specification](NGE_ray_query.txt) for its API,
ownership, validation and shader rules.

Enable the Metal prototype before creating an EGL display:

```sh
export ANGLE_METAL_ENABLE_NGE_RAY_QUERY=1
```

Always check `GL_NGE_ray_query` in `glGetStringi(GL_EXTENSIONS, ...)` after making
the context current. The Metal switch does not override device capabilities. Metal
requires native ray tracing, ray tracing from render stages and tier 2 argument
buffers. Vulkan selects version 1.2 automatically when available, with a 1.1
fallback. It registers ray queries only with an effective device version of at
least 1.2, acceleration structures, ray queries and buffer device addresses.
WebGL and protected contexts omit the extension.

For compute on macOS, build the experimental GLES 3.1 profile:

```sh
ANGLE_METAL_PROFILE=gles31 BUILD_CLASSIFIER=natives-macos-arm64 BUILD_JOBS=2 \
    bash scripts/build-macos.sh
```

Create a GLES 3.1 context through EGL:

```c
const EGLint attributes[] = {
    EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
    EGL_CONTEXT_MINOR_VERSION_KHR, 1,
    EGL_NONE
};
EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, attributes);
```

Resolve the eight `gl*AccelerationStructure*` commands with
`eglGetProcAddress`. Use the declarations in ANGLE's `GLES2/gl2ext_angle.h`.
Build a triangle BLAS from GLES buffers, configure its transformed instances in
a TLAS, build that TLAS and bind it to a query slot. Bindings are independent of
texture, image and shader-buffer bindings. For example, assuming `vertexBuffer`
contains three tightly packed `vec3` vertices:

```c
PFNGLGENACCELERATIONSTRUCTURESPROC gen =
    (PFNGLGENACCELERATIONSTRUCTURESPROC)eglGetProcAddress("glGenAccelerationStructures");
PFNGLBUILDTRIANGLEACCELERATIONSTRUCTUREPROC buildBlas =
    (PFNGLBUILDTRIANGLEACCELERATIONSTRUCTUREPROC)eglGetProcAddress("glBuildTriangleAccelerationStructure");
PFNGLSETACCELERATIONSTRUCTUREINSTANCEPROC setInstance =
    (PFNGLSETACCELERATIONSTRUCTUREINSTANCEPROC)eglGetProcAddress("glSetAccelerationStructureInstance");
PFNGLBUILDTOPLEVELACCELERATIONSTRUCTUREPROC buildTlas =
    (PFNGLBUILDTOPLEVELACCELERATIONSTRUCTUREPROC)eglGetProcAddress("glBuildTopLevelAccelerationStructure");
PFNGLBINDACCELERATIONSTRUCTUREPROC bind =
    (PFNGLBINDACCELERATIONSTRUCTUREPROC)eglGetProcAddress("glBindAccelerationStructure");
/* Check all function pointers before calling them. */
GLuint objects[2];
gen(2, objects); /* objects[0] is the BLAS, objects[1] is the TLAS. */
buildBlas(objects[0], vertexBuffer, 0, 3 * sizeof(GLfloat), 3,
          0, 0, GL_NONE, 0, GL_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
const GLfloat identity[12] = {1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0};
setInstance(objects[1], 0, objects[0], identity, 0, 0xff, 0);
buildTlas(objects[1], 1, GL_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT);
bind(0, objects[1]);
/* Check glGetError() after the operations and delete both objects when done. */
```

```glsl
#version 310 es
#extension GL_NGE_ray_query : require
precision highp float;
precision highp int;
layout(local_size_x = 1) in;
layout(binding = 0) uniform accelerationStructureEXT scene;
layout(std430, binding = 0) buffer Result { uint hit; };

void main() {
    rayQueryEXT query;
    rayQueryInitializeEXT(query, scene, gl_RayFlagsNoneEXT, 255u,
                         vec3(0), 0.0, vec3(0, 0, 1), 100.0);
    while (rayQueryProceedEXT(query)) {
        if (rayQueryGetIntersectionTypeEXT(query, false) ==
            gl_RayQueryCandidateIntersectionTriangleEXT)
            rayQueryConfirmIntersectionEXT(query);
    }
    hit = rayQueryGetIntersectionTypeEXT(query, true);
}
```

The same traversal functions work in vertex and fragment shaders with GLSL ES
3.00 or newer. A query belongs to its shader invocation and may be declared in
global or function scope, stored in arrays and passed to user functions. It
cannot be copied or initialized with a constructor. Its built-in operations
mutate traversal state. Array indices must be dynamically uniform, and a getter's
candidate/committed selector must be constant.

Rebuilding a BLAS does not change existing TLAS generations. Rebuild the TLAS to
use the new geometry. Builds consume preceding GPU geometry writes; subsequent
queries consume preceding builds through backend dependencies. These operations
do not require `glFinish`. Synchronize CPU readback and other shader resources
with the ordinary GLES rules.

Run the public EGL probe against the exact libraries being evaluated:

```sh
python3 tests/nge-ray-query-probe.py --native-dir /absolute/path/to/native/libraries \
    --backend metal --stage all --extended --validation --require-supported
```

Use `--backend vulkan` on Linux. `--expect-absent` checks a disabled or unsupported
configuration; `--webgl` checks that the extension is not exposed to WebGL.
The probe verifies library provenance, EGL exports, reflection, API errors,
traversal results and queued generation lifetimes. A software Vulkan driver can
provide correctness evidence; it does not measure hardware ray tracing speed.

This profile builds triangle or AABB BLAS and instanced TLAS. AABB candidates
must be tested against the actual procedural geometry before committing them.
Acceleration-structure arrays use consecutive binding points. The current GLES
instance API fixes the shader binding table record offset at zero. Mid-execution
frame capture/replay reconstruction has not been qualified. The libJGLIOS ray-query
port and iOS runtime qualification remain separate work.
