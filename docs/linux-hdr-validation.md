# Linux HDR validation results

Validation date: 12 October 2026.

ANGLE revision: `36f593228fa928dffcf5881fb40038c2ec9d166c` (the unchanged
`ANGLE_COMMIT` pin). Builder base: `49adae36cad6b337108b017dd219a13b224992cb`.

## Environment and scope

The native libraries were built and tested on Ubuntu 24.04 x86_64 with Mesa
25.2.8 lavapipe/llvmpipe, LLVM 20.1.2, and a headless Weston 16.0.0 compositor
with its GL renderer and LittleCMS color management enabled. A separate
non-color-managed Weston 13.0.0 instance exercised the SDR-only case.

This environment has no NVIDIA GPU or physical HDR display. Successful HDR
input and Vulkan presentation into a real compositor are **not a measurement
or certification of physical HDR output**. Fedora/KWin, RTX 3070, full NGE
integration, ARM64, and the complete Steam Runtime release matrix were not
validated in this run.

The host does not expose `VK_GOOGLE_surfaceless_query`, so the new native
Wayland surface discovery path was exercised rather than bypassed.

## Results

| Check | Result |
| --- | --- |
| Linux x86_64 `libEGL.so` and `libGLESv2.so` compilation | PASS |
| Clean application to the pinned ANGLE revision with the existing Metal patch | PASS |
| Compiled enumeration-helper tests with mocked Vulkan calls | 14/14 PASS; logic tests only |
| Real scRGB FP16 window, native-buffer readback, and four presentations | PASS; 2.0000000 written and read back |
| Real RGB10A2 HDR10/PQ window, shader/readback, and four presentations | PASS; 0.7517107 observed versus 0.7518271 expected for a neutral 1000-nit input |
| HDR to SDR transitions on the same native window | PASS after each HDR path |
| Invalid colorspace rejection followed by SDR rendering | PASS |
| Encoded sRGB rendering | PASS |
| Observation-only downstream Vulkan audit | Seven phases and 28 successful presentations |
| Explicit HDR requirement on an SDR-only compositor | Exit 77; HDR skipped, not falsely reported as passed |
| Shell/Python syntax and patch whitespace checks | PASS |

The observer recorded these actual swapchain pairs:

```text
scRGB:
  VK_FORMAT_R16G16B16A16_SFLOAT
  VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT
HDR10/PQ:
  VK_FORMAT_A2B10G10R10_UNORM_PACK32
  VK_COLOR_SPACE_HDR10_ST2084_EXT
```

The Wayland trace also recorded transfer-function and primaries selection,
image-description `ready` responses, and application of image descriptions to
surfaces. Neither the tests nor the audit layer fabricated advertised formats,
colorspaces, or compositor capabilities.

The regular run, without rendering-feature overrides, completed with:

```text
LINUX_HDR_SUMMARY hdr_pass=2 hdr_skip=0 sdr=PASS physical_hdr=NOT_TESTED
AUDIT_SUMMARY phases=7 hdr_phases=2 physical_hdr=NOT_TESTED
```

## Validation-layer qualification

The installed Khronos validation layer is 1.3.275. With the default rendering
path it reported 22 unknown-structure errors for newer dynamic-rendering-local-read
structures (types 1000232000 and 1000232001). Although the functional probes
completed, that run is **not counted as clean validation**. The audit verifier
rejects logs containing validation errors.

A separate run with
`ANGLE_FEATURE_OVERRIDES_DISABLED=supportsDynamicRenderingLocalRead` passed the
same HDR and SDR tests with zero validation errors. This compatibility override
changes neither HDR capabilities nor swapchain formats. It is not in the
production build profiles and was not required by the successful regular HDR
run. Validation of the default rendering path with a matching modern validator
remains outstanding.

## Build profile

This is a recorded local validation profile, not the full release build. It
uses the patched production Vulkan/Wayland implementation but omits unrelated
backends and bundled tools, and builds against the local host rather than the
production sysroot. Cross builds must use target-architecture Wayland libraries.

```gn
is_component_build = false
target_cpu = "x64"
is_debug = false
angle_assert_always_on = false
clang_use_chrome_plugins = false
angle_use_x11 = true
angle_use_wayland = true
ozone_platform_x11 = true
ozone_platform_wayland = true
angle_use_vulkan_display = false
angle_enable_vulkan = true
angle_enable_gl = false
angle_enable_null = false
angle_shared_libvulkan = false

symbol_level = 0
angle_build_all = false
use_sysroot = false
enable_rust = false
use_glib = false
angle_enable_swiftshader = false
angle_enable_vulkan_validation_layers = false
angle_enable_wgpu = false

angle_use_system_wayland = true
```

SHA-256 of the tested native libraries:

```text
libEGL.so
99486a0ab9d87e95ece7772a31b3932e00ddc150cdd5dbebc3bcb8df85b1d314
libGLESv2.so
c69f6ef5ed6a8e995454b5c43e3b60439cac63992350b3a4f5e1b593b86a156b
```

## Reproduction

After building the patched libraries, run as the logged-in Wayland desktop user:

```sh
python3 tests/test-linux-hdr-logic.py
HDR_AUDIT=1 ./scripts/test-linux-hdr.sh --require-hdr --require-scrgb
```

The scRGB requirement exercises the encoding used by the current NGE SDL
backend. See [Linux HDR setup and test instructions](linux-hdr.md) for dependency,
path, diagnostic, and exit-code details. Raw machine logs and native binaries
are intentionally not committed to the source repository.
