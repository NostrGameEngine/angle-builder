# Metal profiles on iOS Simulator

The simulator build uses the same ordered ANGLE patches as macOS. The experimental
GLES 3.1 build can be selected for native macOS or iOS Simulator. A separate
[physical-device runner](ios-device-metal-tests.md) builds and tests the same
profile on a paired iPhone. The [libJGLIOS application build](https://github.com/NostrGameEngine/libJGLIOS/tree/GLES31#angle-gles-31-profile) imports the same pinned patches and adds its iOS compatibility overlays; it checks simulator capabilities separately.

## Build

On an Apple Silicon Mac with Xcode, the Metal toolchain and an installed simulator
runtime:

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 BUILD_JOBS=2 \
    bash scripts/build-ios-simulator.sh
```

Frameworks are written to `out/release-ios-simulator-arm64-gles31` in the ANGLE
checkout. The minimum target is iOS 18. `ANGLE_SIMULATOR_MANIFEST.json` verifies the
source, patch series, resolved GN profile, framework hashes, Mach-O simulator
platform and simulator target of the precompiled internal Metal library.

## Runtime capabilities

Selecting a build does not override the Metal device's capabilities. The tested
iOS 27 simulator exposes `Apple iOS simulator GPU` with these limits:

| Capability | Reported by the simulator | Required by this GLES 3.1 profile |
| --- | --- | --- |
| Apple GPU family 7 | No | Yes |
| Argument buffers | Tier 1 | Tier 2 |
| Read/write textures | None | Tier 2 |

Consequently, its GLES 3.1 context request is rejected with `EGL_BAD_MATCH`, and
the build retains its GLES 3.0 limit. This is not evidence of compute or MDI
execution on iOS. Physical iPhone capabilities must be tested independently.

## Direct EGL tests

The runner executes native iOS Simulator binaries through `simctl spawn`, using
the same EGL pbuffer probes as macOS. It stages executables and frameworks in a
physical temporary directory: CoreSimulator cannot reliably execute files from
the virtual workspace used in this environment. Results are copied back to the
requested results directory.

To require GLES 3.1 and run compute, shared memory, fences, GPU-generated indirect
dispatch and compute-to-MDI image checks when it is available:

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 \
    bash scripts/test-ios-simulator-metal.sh
```

That command fails on the limited virtual GPU described above. To verify its
expected rejection and GLES 3.0 fallback explicitly:

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 \
ANGLE_EXPECT_GLES31_UNAVAILABLE=1 \
    bash scripts/test-ios-simulator-metal.sh
```

This negative test verifies GLES 3.1 rejection, an exact GLES 3.0 context, GPU
pbuffer clear/readback, baseline resource limits, absence of compute/MDI exposure
and GLES 3.2 rejection. Its result is `gles31_unavailable`; compute and MDI are
recorded as `not_run`. It cannot pass if the device unexpectedly accepts GLES 3.1.

Both Metal API and Shader Validation are enabled. Results include GPU capability
JSON, context logs, native build provenance and test input/output hashes. If GLES
3.1 is available, culling also checks three reference images and command/counter
guards without reading generated arguments on the host before drawing.

Set `ANGLE_SIMULATOR_UDID` to use an existing simulator, which is preserved. By
default the runner creates and cleans up an iPhone 16 Pro with the installed iOS
18.5 runtime. `ANGLE_SIMULATOR_RUNTIME` and `ANGLE_SIMULATOR_DEVICE_TYPE` select a
different compatible pair. `ANGLE_SIMULATOR_BOOT_TIMEOUT` controls initial boot
waiting (default 600 seconds). `ANGLE_TEST_RESULTS_DIR` selects the results path.

These are offscreen EGL tests, not UIKit, libJGLIOS application acceptance,
physical-device performance measurements or a GLES certification claim.
