# Selecting a Metal GLES profile

The macOS build defaults to `ANGLE_METAL_PROFILE=gles30`. Select the experimental GLES 3.1 profile explicitly:

```sh
ANGLE_DIR=/store/DEV/angle \
ANGLE_METAL_PROFILE=gles31 \
BUILD_CLASSIFIER=natives-macos-arm64 \
BUILD_JOBS=2 \
bash scripts/build-macos.sh
```

Set `ANGLE_DIR` to your ANGLE checkout. The build synchronizes dependencies and applies this repository's patches. The GLES 3.1 profile uses `out/release-osx-arm64-gles31` and stages libraries under `angle-artifacts/gles31/natives-macos-arm64/native/angle/osx/arm64`. `ARTIFACTS_DIR` changes the staging root. The default GLES 3.0 profile keeps `out/release-osx-arm64` and `angle-artifacts/natives-macos-arm64/native/angle/osx/arm64`.

Load both `libEGL.dylib` and `libGLESv2.dylib` from the selected profile. Requesting a GLES 3.1 context cannot enable GLES 3.1 in a binary built with the default profile. The build manifest records `metal_profile`, the resolved GN arguments, source identity and binary hashes. The selectable build uses `angle_metal_enable_gles31=true`; it does not enable the internal `angle_metal_enable_compute_tests` option.

For Java packaging, select that subtree explicitly and use a distinct artifact name or version:

```sh
PACKAGE_INPUT_DIR=angle-artifacts/gles31 \
PACKAGE_OUTPUT_DIR=dist/gles31 \
ARTIFACT_ID=angle-natives-gles31 \
bash scripts/package.sh local-gles31
```

Default packaging excludes the `gles31` container, so the two profiles cannot be combined accidentally by that command.

## Direct EGL

Include `EGL/egl.h`, `EGL/eglext.h` and `GLES3/gl31.h`. Select the Metal display and initialize EGL:

```cpp
auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
    eglGetProcAddress("eglGetPlatformDisplayEXT"));
// Check that getPlatformDisplay is non-null before calling it.
const EGLint displayAttributes[] = {
    EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
    EGL_NONE
};
EGLDisplay display = getPlatformDisplay(
    EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttributes);
// Check display != EGL_NO_DISPLAY and every EGLBoolean result.
eglInitialize(display, nullptr, nullptr);
eglBindAPI(EGL_OPENGL_ES_API);
```

Choose your window or pbuffer configuration with `EGL_RENDERABLE_TYPE = EGL_OPENGL_ES3_BIT_KHR`. Once you have `display` and `config`, request the minor version explicitly:

```cpp
const EGLint contextAttributes[] = {
    EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
    EGL_CONTEXT_MINOR_VERSION_KHR, 1,  // Use 0 to request GLES 3.0.
    EGL_NONE
};
EGLContext context = eglCreateContext(
    display, config, EGL_NO_CONTEXT, contextAttributes);
if (context == EGL_NO_CONTEXT) {
    const EGLint error = eglGetError();
    // Report the error, or deliberately retry with minor version 0.
}
```

Using only `EGL_CONTEXT_CLIENT_VERSION = 3` does not explicitly request GLES 3.1: the minor version defaults to zero. See the [EGL_KHR_create_context specification](https://registry.khronos.org/EGL/extensions/KHR/EGL_KHR_create_context.txt).

After creating the surface and successfully calling `eglMakeCurrent`, verify the actual API version:

```cpp
GLint major = 0, minor = 0;
glGetIntegerv(GL_MAJOR_VERSION, &major);
glGetIntegerv(GL_MINOR_VERSION, &minor);
// Require major > 3 || (major == 3 && minor >= 1) before using GLES 3.1.
```

GLES 3.1 provides compute shaders, SSBOs, memory barriers and individual indirect draws. Multi-draw indirect is an additional extension: check `GL_EXT_multi_draw_indirect` by enumerating `glGetStringi(GL_EXTENSIONS, i)` and resolve its entry points with `eglGetProcAddress`. This profile enables that extension for GLES 3.1 contexts without private feature overrides. The backend currently encodes multiple Metal indirect draws in a CPU loop; it does not use Metal indirect command buffers.

The experimental Metal profile supports `imageLoad` and `imageStore` in vertex,
fragment and compute shaders. Query `GL_MAX_VERTEX_IMAGE_UNIFORMS`,
`GL_MAX_FRAGMENT_IMAGE_UNIFORMS` and `GL_MAX_COMPUTE_IMAGE_UNIFORMS` after
creating the context. The eligible profile currently reports four per stage;
these are ANGLE's resource-slot limits. Writable graphics-image aliases have
an additional [documented restriction](metal-gles31-capabilities.md#image-descriptors).

In this ANGLE build, requesting minor version 0 still creates a GLES 3.0 context even when using the GLES 3.1 libraries. That context rejects compute shaders and does not expose GLES 3.1 MDI. The default profile rejects a GLES 3.1 context request. Both profiles reject GLES 3.2.

## Availability and validation

The selectable GLES 3.1 profile is experimental. The macOS runtime gate requires macOS 15 or newer, Apple GPU family 7 or newer, tier 2 argument buffers and read/write textures, at least 128 threads per threadgroup, 16 KiB of threadgroup memory and 128 MiB maximum buffer length. Unsupported devices retain the baseline API limit. Runtime validation has been performed on an Apple M2; the feature predicate does not establish validation on every eligible device. The maximum conformant version remains GLES 3.0: this profile is not a GLES 3.1 certification claim.

Apple family 7 includes the M1 and A14 GPUs; newer Apple GPU families can pass
the same predicate when their reported properties meet its requirements. The
profile does not currently enable GLES 3.1 on Intel Macs: its shader memory
fences use a Metal feature documented for Apple silicon. See Apple's
[GPU families](https://developer.apple.com/documentation/metal/mtlgpufamily)
and [Metal Shading Language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf).

The same profile can be built for a [physical iPhone](ios-device-metal-tests.md)
with an iOS 18 minimum target. Its direct EGL, compute, graphics-stage SSBO,
2D image load/store, atomic-counter, transform-feedback, synchronization and MDI
probes have passed
on an iPhone 12 with an A14 GPU and iOS 27.0.1, with Metal API and Shader
Validation enabled. The [simulator runner](ios-simulator-metal-tests.md)
tests a separate platform with a virtual GPU; its capabilities do not establish
the capabilities of the corresponding physical iPhone.

To check the profile through public EGL calls:

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 \
    bash scripts/test-macos-metal-profile.sh
```

This checks explicit 3.0 and 3.1 context creation, compute output, vertex/fragment images, storage buffers and atomic counters, their range rebinding and cross-stage synchronization, extension visibility and 3.2 rejection. Use `ANGLE_NATIVE_DIR` to test staged libraries. `ANGLE_METAL_PROFILE=gles30` checks baseline context rejection and limits. The culling probe additionally verifies compute-generated multi-draw indirect commands against reference images; its runner accepts a verified release manifest through `ANGLE_NATIVE_MANIFEST`.

An isolated [iOS Simulator build and test runner](ios-simulator-metal-tests.md) is also available. It uses the same profile argument with an iOS 18 minimum. For the Java/Graal iOS application, [libJGLIOS](https://github.com/NostrGameEngine/libJGLIOS/tree/GLES31#angle-gles-31-profile) imports this repository's pinned patch series and adds its iOS compatibility patches. Select `-PangleIosMetalProfile=gles31` in that build and request context version 3.1 before graphics initialization. The macOS build command does not produce iOS frameworks.
