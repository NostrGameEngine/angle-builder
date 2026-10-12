# Linux HDR: Wayland / Vulkan

This change targets the ANGLE revision pinned in `ANGLE_COMMIT`. It does not add
an HDR flag for a particular GPU vendor. It fixes EGL configuration generation,
WSI capability discovery, and shared Wayland-client linkage for standalone EGL
applications such as SDL3 and GLFW.

## What changes

The Wayland Vulkan backend preserves its existing BGRA8 configurations and adds
RGB10_A2 and RGBA16F candidates when the underlying Vulkan format supports the
required rendering operations. A configuration gets `EGL_WINDOW_BIT` only when
that Vulkan format is presentable. Pbuffer storage is not proof of HDR output.

HDR colorspaces are discovered from a temporary **real Wayland Vulkan surface**,
including on ICDs without `VK_GOOGLE_surfaceless_query`. The probe uses a private
Wayland event queue and never dispatches a toolkit's default queue. The requested
format/colorspace pair is queried again for every application surface. Discovery
failures must not manufacture HDR capabilities or retain a stale surface cache.

The legacy Vulkan enumeration path now preserves `colorSpace` as well as
`format`. Both enumeration paths handle query failure, list shrink, empty lists,
and bounded `VK_INCOMPLETE` retries.

`angle_use_system_wayland = true` is enabled in both Linux GN profiles. The
standalone libraries must share the caller's libwayland-client implementation:
passing an opaque `wl_display` from the system library into a different,
statically linked private Wayland implementation is not ABI-safe. All ANGLE
Wayland consumers, including GPU-info utilities, use the common GN dependency.
Only the stable `wl_egl_window` backend header is taken from the bundled sources;
the private Wayland-client implementation is not linked.

XCB/X11 HDR is deliberately not advertised by this patch. Visual compatibility
and colorspace signaling require a separate implementation. The existing Mac
Metal patch remains unchanged.

## Build

Use the normal builder scripts, which apply every patch in `patches/` before
running GN. For the standard Linux build:

```sh
./scripts/build-linux.sh
```

The Linux build environment must provide pkg-config and Wayland client/EGL
headers and libraries (`wayland-client >= 1.18`). Cross builds must resolve those
libraries from the **target** sysroot, not from the host. The x86_64 validation
performed in the Devbox uses a recorded, reduced local build profile; see the
[validation results and build profile](linux-hdr-validation.md). The full
Steam Runtime / ARM64 CI matrix was not rebuilt in that validation run.

## Tests on a real KDE Wayland session

Build first. Run tests as the logged-in desktop user, not under sudo. The probe
loads the selected ANGLE `libEGL.so` and `libGLESv2.so`, prints their hashes, and
checks the GLES renderer name to reject accidental use of the system EGL stack.

```sh
python3 tests/test-linux-hdr-logic.py
./scripts/test-linux-hdr.sh --require-scrgb
HDR_AUDIT=1 ./scripts/test-linux-hdr.sh --require-hdr
```

The first command compiles the actual enumeration helper into a **mocked Vulkan
unit-test harness**. It verifies enumeration/error logic only. It is not an HDR
rendering test.

The second command requires the FP16 scRGB path used by the current NGE SDL
backend. The third checks actual downstream Vulkan swapchain formats and
presentation calls through an observation-only layer. Neither the layer nor the
tests fabricate Vulkan formats, colorspaces, or monitor capabilities.

Useful overrides:

```sh
ANGLE_DIR=/absolute/path/to/angle \
ANGLE_NATIVE_DIR=/absolute/path/to/angle/out/release-linux-x64 \
HDR_AUDIT=1 HDR_AUDIT_LOG=/tmp/angle-hdr-audit.log \
./scripts/test-linux-hdr.sh --require-scrgb
```

`WAYLAND_PROTOCOLS_DIR` selects a wayland-protocols installation when pkg-config
cannot find it. `VULKAN_HEADERS_DIR` selects Vulkan headers for the optional
audit layer. `TEST_TIMEOUT_SECONDS` defaults to 90. `WAYLAND_DEBUG=client` records
actual compositor color-management requests for manual inspection.

## What the runtime probe checks

- Real Wayland window, ES3 EGL context, selected EGL colorspace and color format.
- SDR rendering and encoded-sRGB output.
- FP16 native-window readback preserves a value of 2.0 rather than clipping at 1.
- HDR10/PQ native-window rendering agrees with a CPU ST.2084 reference.
- Four successful swaps per phase, plus downstream Vulkan evidence when audited.
- HDR to SDR transitions on the same native window and invalid-colorspace refusal.
- Explicit HDR unavailability; an unsupported format is never counted as HDR PASS.

Exit codes: **0** = requested tests passed; **1** = runtime/assertion failure;
**2** = setup/usage error; **77** = explicitly required HDR path unavailable;
**124** = timeout. Without a require flag, SDR-only success can return 0, but the
summary explicitly reports `hdr_pass=0` and `HDR_SKIP` entries.

The audit verifier checks real `vkCreateSwapchainKHR` and `vkQueuePresentKHR`
records. It requires FP16 + extended-linear-sRGB for scRGB, and packed 10-bit
UNORM + HDR10_ST2084 for PQ. Successful EGL creation alone is insufficient.

## Limits

A headless color-managed compositor is useful for testing **real HDR input and
software presentation** but has no physical HDR screen. Even a successful
swapchain does not establish output luminance, EDID interpretation, KWin policy,
NVIDIA-specific behavior, or the monitor's actual HDR mode. Those must be checked
on the target machine. `physical_hdr=NOT_TESTED` is intentional in every summary.

For NGE integration, select ANGLE and **native Wayland**. An X11 preference or
a launch mode that forces native OpenGL exercises a separate path, not the
HDR support added by this Wayland patch. This repository change does not update NGE's
Maven dependency or implement its PQ output-selection policy.
