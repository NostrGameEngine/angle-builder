# angle-builder

Builds native Google ANGLE binaries for Linux, Windows, and macOS and packages them in classifier jars for use in Java projects.

On macOS, choose the default GLES 3.0 build or the experimental Metal GLES 3.1 build with `ANGLE_METAL_PROFILE=gles30|gles31`. See [Metal GLES profiles and direct EGL context creation](docs/selecting-metal-gles-profile.md).

For iOS Simulator builds, capability checks and offscreen EGL validation, see [iOS Simulator Metal tests](docs/ios-simulator-metal-tests.md).

For builds and GPU tests on a paired physical iPhone, see [iOS device Metal tests](docs/ios-device-metal-tests.md).
