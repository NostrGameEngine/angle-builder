# Metal profiles on a physical iPhone

The experimental GLES 3.1 profile can be built for an arm64 iOS device. It uses
the same ordered patch series as macOS and iOS Simulator. The device gate still
requires iOS 18 or newer, Apple GPU family 7, tier 2 argument buffers and read/write
textures, 128 threads per threadgroup, 16 KiB threadgroup memory and a 128 MiB
maximum buffer length. These requirements describe this implementation's
supported profile, not universal GLES 3.1 requirements.

The direct EGL, compute, synchronization and compute-to-MDI probes have passed
on an iPhone 12 with an Apple A14 GPU and iOS 27.0.1, with Metal API and Shader
Validation enabled. That device reports Apple GPU family 7, tier 2 argument
buffers, tier 2 read/write textures, 1024 threads per threadgroup, 32 KiB
threadgroup memory and a 2 GiB maximum buffer length. The simulator's smaller
feature set does not describe this physical GPU.

## Build

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 BUILD_JOBS=2 \
    bash scripts/build-ios-device.sh
```

Frameworks and their source, profile, platform and binary manifest are written to
`out/release-ios-device-arm64-gles31`. The AIR library and frameworks are checked
for the physical iOS platform; simulator binaries cannot be substituted.

## Run on a paired device

Use `xcrun devicectl list devices` to find the physical device identifier. The
iPhone must have Developer Mode enabled, be paired with Xcode and be unlocked
while Xcode prepares it. A network connection configured through Xcode is
supported. Xcode needs an Apple development team and access to its signing key.

```sh
ANGLE_DIR=/store/DEV/angle ANGLE_METAL_PROFILE=gles31 \
ANGLE_IOS_DEVICE_UDID=YOUR_PAIRED_DEVICE_IDENTIFIER \
ANGLE_IOS_TEAM=YOUR_DEVELOPMENT_TEAM \
    bash scripts/test-ios-device-metal.sh
```

The runner uses automatic development signing and installs the dedicated
`org.ngengine.angle.deviceprobe` app. It does not replace the libJGLIOS application.
The test app exits after writing its result. Its installation is retained so the
test can be repeated; `xcrun devicectl device uninstall app --device DEVICE
org.ngengine.angle.deviceprobe` removes this test app and its data.

The app first measures Metal capabilities, then runs the shared direct EGL probes
for context selection, compute, shared memory, fences, GPU-generated indirect
dispatch and compute-to-MDI rendering. It checks three reference images plus
command and counter guards. Metal API and Shader Validation are requested and
their activation must appear in the runtime log. Private ANGLE feature overrides
remain empty.

To measure only the physical GPU's capabilities without first building ANGLE:

```sh
ANGLE_DEVICE_CAPABILITIES_ONLY=1 \
ANGLE_IOS_DEVICE_UDID=YOUR_PAIRED_DEVICE_IDENTIFIER \
ANGLE_IOS_TEAM=YOUR_DEVELOPMENT_TEAM \
    bash scripts/test-ios-device-metal.sh
```

Results default to `test-results/ios-device-metal-PROFILE`. They include the device
capabilities, signed test app, console output, copied app documents and provenance.
`ANGLE_TEST_RESULTS_DIR` selects a different results directory. A capabilities-only
result records compute and MDI as `not_run`. Successful focused probes do not
establish complete GLES 3.1 conformance, performance or libJGLIOS integration.
