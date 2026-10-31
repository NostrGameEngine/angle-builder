#include <EGL/egl.h>
#include <EGL/eglext.h>
#import <Foundation/Foundation.h>
#include <GLES3/gl31.h>
#include <array>
#include <cstdio>
#include <cstring>
#include <stdexcept>

static void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

static bool extension(const char *name) {
  GLint count = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &count);
  for (GLint i = 0; i < count; ++i) {
    if (!std::strcmp(
            reinterpret_cast<const char *>(glGetStringi(GL_EXTENSIONS, i)),
            name)) {
      return true;
    }
  }
  return false;
}

static void verifyVersion(GLint requestedMinor) {
  GLint major = 0, minor = 0;
  glGetIntegerv(GL_MAJOR_VERSION, &major);
  glGetIntegerv(GL_MINOR_VERSION, &minor);
  require(major == 3 && minor == requestedMinor,
          "Unexpected GLES context version");
  std::printf("CONTEXT requested=3.%d actual=%d.%d\n", requestedMinor, major,
              minor);
  std::printf("GL_VERSION %s\nGL_RENDERER %s\n", glGetString(GL_VERSION),
              glGetString(GL_RENDERER));
}

static void verifyGLES30Rendering() {
  glClearColor(1, 0, 1, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  std::array<GLubyte, 4> pixel = {};
  glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
  require(glGetError() == GL_NO_ERROR &&
              pixel == std::array<GLubyte, 4>{255, 0, 255, 255},
          "GLES 3.0 pbuffer output differs");
  std::puts("GLES30_PBUFFER_RENDER_PASS rgba=255,0,255,255");
}

static GLuint computeProgram(const char *source) {
  GLuint shader = glCreateShader(GL_COMPUTE_SHADER);
  require(shader != 0,
          "Cannot create a compute shader in the selected GLES 3.1 context");
  const char *text = source;
  glShaderSource(shader, 1, &text, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    std::fprintf(stderr, "COMPUTE_SHADER_LOG %s\n", log);
  }
  require(ok, "Compute compilation failed");
  GLuint program = glCreateProgram();
  glAttachShader(program, shader);
  glLinkProgram(program);
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "COMPUTE_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Compute linking failed");
  glDeleteShader(shader);
  return program;
}

static void verifyCompute() {
  constexpr char source[] = R"(#version 310 es
        layout(local_size_x=1) in;
        layout(std430,binding=0) buffer Result { uint words[4]; } outputData;
        void main() { outputData.words[1]=0x12345678u; }
    )";
  const GLuint program = computeProgram(source);
  GLuint buffer;
  glGenBuffers(1, &buffer);
  const std::array<GLuint, 4> initial = {0xcdcdcdcdu, 0xcdcdcdcdu, 0xcdcdcdcdu,
                                         0xcdcdcdcdu};
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffer);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(initial), initial.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffer);
  glUseProgram(program);
  glDispatchCompute(1, 1, 1);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  const auto *actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(initial), GL_MAP_READ_BIT));
  require(actual && actual[0] == initial[0] && actual[1] == 0x12345678u &&
              actual[2] == initial[2] && actual[3] == initial[3],
          "Compute output or guard bytes differ");
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
          "Cannot unmap compute output");
  glDeleteBuffers(1, &buffer);
  glDeleteProgram(program);
  require(glGetError() == GL_NO_ERROR, "Unexpected compute GL error");
  std::puts("COMPUTE_DISPATCH_PASS guards=1");
}

static void verifyComputeSynchronization() {
  constexpr char producerSource[] = R"(#version 310 es
        layout(local_size_x=4) in;
        shared uint tile[4];
        layout(std430,binding=0) buffer Result { uint words[8]; } outputData;
        layout(std430,binding=1) buffer Indirect { uint words[4]; } indirectData;
        void main() {
            uint lane=gl_LocalInvocationIndex;
            tile[lane]=lane+1u;
            memoryBarrierShared();
            barrier();
            if (lane==0u) {
                outputData.words[1]=tile[0]+tile[1]+tile[2]+tile[3];
                indirectData.words[1]=1u;
                indirectData.words[2]=1u;
                indirectData.words[3]=1u;
                memoryBarrier();
            }
        }
    )";
  constexpr char consumerSource[] = R"(#version 310 es
        layout(local_size_x=1) in;
        layout(std430,binding=0) buffer Result { uint words[8]; } outputData;
        void main() {
            outputData.words[2]=outputData.words[1]+gl_NumWorkGroups.x;
            memoryBarrierBuffer();
        }
    )";
  const GLuint producer = computeProgram(producerSource);
  const GLuint consumer = computeProgram(consumerSource);
  constexpr GLuint guard = 0xcdcdcdcdu;
  const std::array<GLuint, 8> initial = {guard, guard, guard, guard,
                                         guard, guard, guard, guard};
  const std::array<GLuint, 4> command = {guard, 0, 0, 0};
  std::array<GLuint, 2> buffers;
  glGenBuffers(buffers.size(), buffers.data());
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(initial), initial.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[1]);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(command), command.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[1]);
  glUseProgram(producer);
  glDispatchCompute(1, 1, 1);
  glMemoryBarrier(GL_COMMAND_BARRIER_BIT | GL_SHADER_STORAGE_BARRIER_BIT);
  glBindBuffer(GL_DISPATCH_INDIRECT_BUFFER, buffers[1]);
  glUseProgram(consumer);
  glDispatchComputeIndirect(sizeof(GLuint));
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  // Read only after the GPU has consumed the generated dispatch arguments.
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
  const auto *actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(initial), GL_MAP_READ_BIT));
  require(actual != nullptr, "Cannot map synchronized compute output");
  for (size_t i = 0; i < initial.size(); ++i) {
    require(actual[i] == (i == 1   ? 10u
                          : i == 2 ? 11u
                                   : guard),
            "Shared memory, indirect dispatch output or guards differ");
  }
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
          "Cannot unmap synchronized output");
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[1]);
  actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(command), GL_MAP_READ_BIT));
  require(actual && actual[0] == guard && actual[1] == 1 && actual[2] == 1 &&
              actual[3] == 1,
          "GPU dispatch arguments or guard differ");
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
          "Cannot unmap indirect arguments");
  glDeleteBuffers(buffers.size(), buffers.data());
  glDeleteProgram(producer);
  glDeleteProgram(consumer);
  require(glGetError() == GL_NO_ERROR, "Unexpected synchronization GL error");
  std::puts("COMPUTE_SYNCHRONIZATION_PASS shared=1 fences=1 "
            "gpu_indirect_dispatch=1 guards=1");
}

int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      require(argc <= 2,
              "Usage: metal-profile-probe [gles30|gles31|gles31-unavailable]");
      const bool selected31 = argc == 2 && !std::strcmp(argv[1], "gles31");
      const bool unavailable31 =
          argc == 2 && !std::strcmp(argv[1], "gles31-unavailable");
      require(argc == 1 || selected31 || unavailable31 ||
                  !std::strcmp(argv[1], "gles30"),
              "Invalid profile");
      auto getDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
          eglGetProcAddress("eglGetPlatformDisplayEXT"));
      require(getDisplay != nullptr,
              "Missing ANGLE platform display entry point");
      // No private ANGLE feature overrides: this is the application's public
      // path.
      const EGLint displayAttributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                                          EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
                                          EGL_NONE};
      EGLDisplay display =
          getDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes);
      require(eglInitialize(display, nullptr, nullptr),
              "Cannot initialize ANGLE Metal");
      require(eglBindAPI(EGL_OPENGL_ES_API), "Cannot select GLES API");
      const EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                         EGL_RENDERABLE_TYPE,
                                         EGL_OPENGL_ES3_BIT_KHR, EGL_NONE};
      EGLConfig config = nullptr;
      EGLint count = 0;
      require(eglChooseConfig(display, configAttributes, &config, 1, &count) &&
                  count > 0,
              "Missing GLES 3 pbuffer configuration");
      const EGLint computeAttributes[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                                          EGL_CONTEXT_MINOR_VERSION_KHR, 1,
                                          EGL_NONE};
      EGLContext compute =
          eglCreateContext(display, config, EGL_NO_CONTEXT, computeAttributes);
      if (selected31) {
        require(compute != EGL_NO_CONTEXT,
                "GLES 3.1 unavailable: check selected libraries, macOS and "
                "Metal device");
      } else {
        require(compute == EGL_NO_CONTEXT,
                "Package or device unexpectedly exposes GLES 3.1");
        require(eglGetError() == EGL_BAD_MATCH,
                "Unexpected GLES 3.1 context rejection");
        std::puts("CONTEXT requested=3.1 rejected=EGL_BAD_MATCH");
        if (unavailable31) {
          std::puts("GLES31_UNAVAILABLE_CONFIRMED");
        }
      }
      const EGLint contextAttributes[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                                          EGL_CONTEXT_MINOR_VERSION_KHR, 0,
                                          EGL_NONE};
      EGLContext context =
          eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
      require(context != EGL_NO_CONTEXT, "Cannot create GLES 3.0 context");
      const EGLint surfaceAttributes[] = {EGL_WIDTH, 8, EGL_HEIGHT, 8,
                                          EGL_NONE};
      EGLSurface surface =
          eglCreatePbufferSurface(display, config, surfaceAttributes);
      require(surface != EGL_NO_SURFACE &&
                  eglMakeCurrent(display, surface, surface, context),
              "Cannot activate GLES 3.0 pbuffer");
      verifyVersion(0);
      verifyGLES30Rendering();
      GLint textureUnits = 0, uniformBindings = 0, uniformBlocks = 0,
            uniformBlockSize = 0;
      glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &textureUnits);
      glGetIntegerv(GL_MAX_UNIFORM_BUFFER_BINDINGS, &uniformBindings);
      glGetIntegerv(GL_MAX_COMBINED_UNIFORM_BLOCKS, &uniformBlocks);
      glGetIntegerv(GL_MAX_UNIFORM_BLOCK_SIZE, &uniformBlockSize);
      if (!selected31) {
        require(textureUnits == 32 && uniformBindings == 32 &&
                    uniformBlocks == 32,
                "GLES 3.1 binding limits leaked into the baseline profile");
        require(uniformBlockSize == 16384,
                "Large UBO limit leaked into the baseline profile");
      }
      std::printf("GL_UNIFORM_BLOCK_SIZE %d\n", uniformBlockSize);
      std::printf(
          "GL_BINDINGS textureUnits=%d uniformBindings=%d uniformBlocks=%d\n",
          textureUnits, uniformBindings, uniformBlocks);
      require(!extension("GL_EXT_multi_draw_indirect"),
              "GLES 3.0 context exposes GLES 3.1 MDI");
      require(glCreateShader(GL_COMPUTE_SHADER) == 0 &&
                  glGetError() == GL_INVALID_ENUM,
              "GLES 3.0 context accepted a compute shader");
      if (selected31) {
        require(eglMakeCurrent(display, surface, surface, compute),
                "Cannot activate GLES 3.1");
        verifyVersion(1);
        require(extension("GL_EXT_multi_draw_indirect"),
                "Selected GLES 3.1 context lacks MDI");
        verifyCompute();
        verifyComputeSynchronization();
        std::puts("MDI_EXTENSION_PASS private_feature_overrides=0");
      }
      const EGLint futureAttributes[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                                         EGL_CONTEXT_MINOR_VERSION_KHR, 2,
                                         EGL_NONE};
      require(eglCreateContext(display, config, EGL_NO_CONTEXT,
                               futureAttributes) == EGL_NO_CONTEXT &&
                  eglGetError() == EGL_BAD_MATCH,
              "Profile unexpectedly exposes GLES 3.2");
      require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                             EGL_NO_CONTEXT) &&
                  eglDestroyContext(display, context) &&
                  eglDestroySurface(display, surface),
              "Cannot release profile resources");
      if (compute != EGL_NO_CONTEXT) {
        require(eglDestroyContext(display, compute),
                "Cannot release compute context");
      }
      require(eglTerminate(display), "Cannot terminate profile display");
      std::printf("METAL_PROFILE_PASS selected=%s\n", selected31 ? "gles31"
                                                      : unavailable31
                                                          ? "gles31-unavailable"
                                                          : "gles30");
    } catch (const std::exception &error) {
      std::fprintf(stderr, "METAL_PROFILE_FAIL %s\n", error.what());
      return 1;
    }
  }
  return 0;
}
