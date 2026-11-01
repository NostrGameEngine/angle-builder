#include <EGL/egl.h>
#include <EGL/eglext.h>
#import <Foundation/Foundation.h>
#include <GLES3/gl31.h>
#include <algorithm>
#include <array>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>

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

static GLuint graphicsProgram(const char *vertexSource,
                              const char *fragmentSource) {
  const char *sources[] = {vertexSource, fragmentSource};
  const GLenum stages[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
  const GLuint program = glCreateProgram();
  for (size_t i = 0; i < 2; ++i) {
    GLuint shader = glCreateShader(stages[i]);
    glShaderSource(shader, 1, &sources[i], nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
      char log[8192] = {};
      glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
      std::fprintf(stderr, "GRAPHICS_SHADER_LOG %s\n", log);
    }
    require(ok, "Graphics shader compilation failed");
    glAttachShader(program, shader);
    glDeleteShader(shader);
  }
  glProgramParameteri(program, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
  glLinkProgram(program);
  GLint ok = GL_FALSE;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "GRAPHICS_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Graphics shader linking failed");
  return program;
}

static GLuint reloadGraphicsProgramBinary(GLuint original) {
  GLint formats = 0;
  glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &formats);
  if (!formats) {
    std::puts("GRAPHICS_PROGRAM_BINARY_SKIP no_formats");
    return original;
  }
  GLint size = 0;
  glGetProgramiv(original, GL_PROGRAM_BINARY_LENGTH, &size);
  require(size > 0, "Graphics program binary unavailable");
  std::vector<GLubyte> bytes(size);
  GLenum format = 0;
  GLsizei written = 0;
  glGetProgramBinary(original, size, &written, &format, bytes.data());
  require(written > 0, "Cannot save graphics program binary");
  GLuint restored = glCreateProgram();
  glProgramBinary(restored, format, bytes.data(), written);
  GLint ok = GL_FALSE;
  glGetProgramiv(restored, GL_LINK_STATUS, &ok);
  require(ok && glGetError() == GL_NO_ERROR,
          "Cannot reload graphics program binary");
  glDeleteProgram(original);
  std::puts("GRAPHICS_PROGRAM_BINARY_PASS");
  return restored;
}

static void verifyGraphicsStorage() {
  GLint vertexLimit = 0, fragmentLimit = 0, computeLimit = 0;
  GLint64 sizeLimit = 0;
  glGetIntegerv(GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS, &vertexLimit);
  glGetIntegerv(GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS, &fragmentLimit);
  glGetIntegerv(GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS, &computeLimit);
  glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &sizeLimit);
  std::printf("SSBO_LIMITS vertex=%d fragment=%d compute=%d size=%lld\n",
              vertexLimit, fragmentLimit, computeLimit,
              static_cast<long long>(sizeLimit));
  require(vertexLimit > 0 && fragmentLimit > 0 && computeLimit > 0,
          "Graphics or compute SSBO support missing");
  constexpr char computeSeed[] = R"(#version 310 es
    layout(local_size_x=1) in;
    layout(std430,binding=0) buffer Data { uint words[]; } data;
    void main() { data.words[0]=100u; }
  )";
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer Data { uint words[]; } data;
    void main() {
      uint id=uint(gl_VertexID);
      memoryBarrierBuffer();
      data.words[id+1u]=(data.words.length()==10 ? data.words[0]+id+1u : 0u);
      atomicAdd(data.words[6],1u);
      vec2 p=vec2(id==1u?3.0:-1.0,id==2u?3.0:-1.0);
      gl_Position=vec4(p,0,1);
    }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer Data { uint words[]; } data;
    layout(location=0) out vec4 color;
    void main() {
      uint x=uint(gl_FragCoord.x);
      memoryBarrierBuffer();
      data.words[x+4u]=(data.words.length()==10 ? data.words[0]+x+10u : 0u);
      atomicAdd(data.words[7],1u);
      color=vec4(1);
    }
  )";
  constexpr char computeVerify[] = R"(#version 310 es
    layout(local_size_x=1) in;
    layout(std430,binding=0) buffer Data { uint words[]; } data;
    void main() {
      bool ok=data.words[0]==100u && data.words[1]==101u && data.words[2]==102u &&
              data.words[3]==103u && data.words[4]==110u && data.words[5]==111u &&
              data.words[6]==3u && data.words[7]==2u;
      data.words[8]=ok ? 0x1234abcdU : 0u;
    }
  )";
  GLuint seed = computeProgram(computeSeed);
  GLuint graphics = graphicsProgram(vertex, fragment);
  GLuint verify = computeProgram(computeVerify);
  std::array<GLuint, 10> initial = {};
  GLuint buffer;
  glGenBuffers(1, &buffer);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffer);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(initial), initial.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffer);
  glUseProgram(seed);
  glDispatchCompute(1, 1, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glUseProgram(graphics);
  glViewport(0, 0, 2, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glUseProgram(verify);
  glDispatchCompute(1, 1, 1);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  const auto *actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(initial), GL_MAP_READ_BIT));
  if (actual && actual[8] != 0x1234abcdu) {
    std::fprintf(stderr, "SSBO_VALUES %u %u %u %u %u %u %u %u %u\n", actual[0],
                 actual[1], actual[2], actual[3], actual[4], actual[5],
                 actual[6], actual[7], actual[8]);
  }
  require(actual && actual[8] == 0x1234abcdu,
          "Compute/graphics SSBO synchronization failed");
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER) &&
              glGetError() == GL_NO_ERROR,
          "Graphics SSBO buffer mapping failed");
  glDeleteBuffers(1, &buffer);
  glDeleteProgram(seed);
  glDeleteProgram(graphics);
  glDeleteProgram(verify);
  std::puts("GRAPHICS_SSBO_PASS vertex_fragment_compute_sync=1 length=1 "
            "atomics=1 fences=1");
}

static void verifyGraphicsImages() {
  GLint vertexImages = 0, fragmentImages = 0;
  glGetIntegerv(GL_MAX_VERTEX_IMAGE_UNIFORMS, &vertexImages);
  glGetIntegerv(GL_MAX_FRAGMENT_IMAGE_UNIFORMS, &fragmentImages);
  require(vertexImages > 0 && fragmentImages > 0,
          "Graphics image uniforms are unavailable");
  GLint binaryFormats = 0;
  glGetIntegerv(GL_NUM_PROGRAM_BINARY_FORMATS, &binaryFormats);
  require(binaryFormats > 0, "Graphics image program binaries are unavailable");

  constexpr char vertexStore[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui,binding=0) writeonly uniform highp uimage2D vertexImage;
      void main() {
        imageStore(vertexImage, ivec2(gl_VertexID, 0), uvec4(uint(10 + gl_VertexID), 1, 2, 3));
        vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
        gl_Position = vec4(p, 0, 1);
      }
  )";
  constexpr char fragmentStore[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui,binding=1) writeonly uniform highp uimage2D fragmentImage;
      layout(location=0) out highp uvec4 color;
      void main() {
        int x = int(gl_FragCoord.x);
        imageStore(fragmentImage, ivec2(x, 0), uvec4(uint(20 + x), 4, 5, 6));
        color = uvec4(1);
      }
  )";
  constexpr char vertexLoad[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui,binding=0) readonly uniform highp uimage2D vertexImage;
      flat out highp uint value;
      void main() {
        value = imageLoad(vertexImage, ivec2(0)).x;
        vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
        gl_Position = vec4(p, 0, 1);
      }
  )";
  constexpr char fragmentLoad[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui,binding=1) readonly uniform highp uimage2D fragmentImage;
      flat in highp uint value;
      layout(location=0) out highp uvec4 color;
      void main() {
        color = uvec4(value, imageLoad(fragmentImage, ivec2(int(gl_FragCoord.x), 0)).x, 7, 8);
      }
  )";
  const GLuint writer = graphicsProgram(vertexStore, fragmentStore);
  const GLuint reader = reloadGraphicsProgramBinary(graphicsProgram(vertexLoad, fragmentLoad));
  std::array<GLuint, 3> textures = {};
  glGenTextures(textures.size(), textures.data());
  for (GLuint texture : textures) {
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32UI, 4, 1);
  }
  GLuint framebuffer = 0;
  glGenFramebuffers(1, &framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         textures[2], 0);
  require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
          "Graphics image framebuffer is incomplete");
  glViewport(0, 0, 2, 1);
  for (GLuint unit = 0; unit < 2; ++unit) {
    glBindImageTexture(unit, textures[unit], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA32UI);
  }
  glUseProgram(writer);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  for (GLuint unit = 0; unit < 2; ++unit) {
    glBindImageTexture(unit, textures[unit], 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA32UI);
  }
  glUseProgram(reader);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  std::array<GLuint, 8> actual = {};
  glReadPixels(0, 0, 2, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT, actual.data());
  require(glGetError() == GL_NO_ERROR &&
              actual == std::array<GLuint, 8>{10, 20, 7, 8, 10, 21, 7, 8},
          "Graphics image load/store output differs");
  glUseProgram(0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(textures.size(), textures.data());
  glDeleteProgram(writer);
  glDeleteProgram(reader);
  std::puts("GRAPHICS_IMAGE_PASS vertex=load_store fragment=load_store binary=1");
}

static void verifyImageAliases() {
  constexpr char vertex[] = R"(#version 310 es
      void main() {
        vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0,
                      gl_VertexID == 2 ? 3.0 : -1.0);
        gl_Position = vec4(p, 0, 1);
      }
  )";
  constexpr char fragment[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D dst;
      layout(rgba32ui, binding=1) coherent readonly uniform highp uimage2D src;
      layout(location=0) out highp uvec4 color;
      void main() {
        ivec2 p = ivec2(int(gl_FragCoord.x), 0);
        imageStore(dst, p, uvec4(uint(31 + p.x), 4, 5, 6));
        memoryBarrierImage();
        color = imageLoad(src, p);
      }
  )";
  constexpr char vertexAlias[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D dst;
      layout(rgba32ui, binding=1) coherent readonly uniform highp uimage2D src;
      flat out highp uvec4 value;
      void main() {
        ivec2 p = ivec2(gl_VertexID, 0);
        imageStore(dst, p, uvec4(71, 4, 5, 6));
        memoryBarrierImage();
        value = imageLoad(src, p);
        vec2 xy = vec2(gl_VertexID == 1 ? 3.0 : -1.0,
                       gl_VertexID == 2 ? 3.0 : -1.0);
        gl_Position = vec4(xy, 0, 1);
      }
  )";
  constexpr char vertexAliasFragment[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      flat in highp uvec4 value;
      layout(location=0) out highp uvec4 color;
      void main() { color = value; }
  )";
  constexpr char fourImages[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(r32ui, binding=0) coherent uniform highp uimage2D images[4];
      layout(location=0) out highp uvec4 color;
      void main() {
        ivec2 p = ivec2(int(gl_FragCoord.x), 0);
        uvec4 v = uvec4(uint(90 + p.x), 1, 2, 3);
        imageStore(images[0], p, v); imageStore(images[1], p, v);
        imageStore(images[2], p, v); imageStore(images[3], p, v);
        memoryBarrierImage();
        color = imageLoad(images[0], p) + imageLoad(images[1], p) +
                imageLoad(images[2], p) + imageLoad(images[3], p);
      }
  )";
  constexpr char compute[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(local_size_x=2) in;
      layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D dst;
      layout(rgba32ui, binding=1) coherent readonly uniform highp uimage3D src;
      layout(std430, binding=0) buffer Result { uvec4 words[2]; } result;
      void main() {
        int x = int(gl_GlobalInvocationID.x);
        imageStore(dst, ivec2(x,0), uvec4(uint(50+x), 4, 5, 6));
        memoryBarrierImage();
        barrier();
        result.words[x] = imageLoad(src, ivec3(1-x,0,1));
      }
  )";
  constexpr char snorm[] = R"(#version 310 es
      precision highp float;
      precision highp int;
      layout(local_size_x=2) in;
      layout(rgba8_snorm, binding=0) coherent writeonly uniform highp image2D dst;
      layout(r32ui, binding=1) coherent readonly uniform highp uimage2D src;
      layout(std430, binding=0) buffer Result { uvec4 words[2]; } result;
      void main() {
        int x = int(gl_GlobalInvocationID.x);
        imageStore(dst, ivec2(x,0), vec4(-1.0, -64.0/127.0, 32.0/127.0, 1.0));
        memoryBarrierImage();
        result.words[x] = uvec4(imageLoad(src, ivec2(x,0)).x, 4, 5, 6);
      }
  )";
  std::array<GLuint, 5> textures = {};
  glGenTextures(textures.size(), textures.data());
  for (size_t i = 0; i < 3; ++i) {
    glBindTexture(GL_TEXTURE_2D, textures[i]);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32UI, 4, 1);
  }
  const std::array<GLuint, 8> seed = {17, 4, 5, 6, 18, 4, 5, 6};
  glBindTexture(GL_TEXTURE_2D, textures[1]);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 2, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT,
                  seed.data());
  glBindTexture(GL_TEXTURE_3D, textures[3]);
  glTexStorage3D(GL_TEXTURE_3D, 1, GL_RGBA32UI, 4, 1, 3);
  glBindTexture(GL_TEXTURE_2D, textures[4]);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8_SNORM, 4, 1);
  GLuint framebuffer = 0;
  glGenFramebuffers(1, &framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         textures[2], 0);
  require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
          "Image alias framebuffer is incomplete");
  glViewport(0, 0, 2, 1);
  auto drawAndCheck = [](const std::array<GLuint, 8> &wanted) {
    glDrawArrays(GL_TRIANGLES, 0, 3);
    std::array<GLuint, 8> actual = {};
    glReadPixels(0, 0, 2, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT, actual.data());
    require(glGetError() == GL_NO_ERROR && actual == wanted,
            "Graphics image alias output differs");
  };
  GLuint program = graphicsProgram(vertex, fragment);
  glBindImageTexture(0, textures[0], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA32UI);
  glBindImageTexture(1, textures[0], 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA32UI);
  glUseProgram(program);
  drawAndCheck({31, 4, 5, 6, 32, 4, 5, 6});
  program = reloadGraphicsProgramBinary(program);
  glUseProgram(program);
  glBindImageTexture(1, textures[1], 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA32UI);
  drawAndCheck(seed);
  glBindImageTexture(1, textures[0], 0, GL_FALSE, 0, GL_READ_ONLY, GL_RGBA32UI);
  drawAndCheck({31, 4, 5, 6, 32, 4, 5, 6});
  glDeleteProgram(program);

  program = graphicsProgram(vertexAlias, vertexAliasFragment);
  glUseProgram(program);
  drawAndCheck({71, 4, 5, 6, 71, 4, 5, 6});
  glDeleteProgram(program);

  program = graphicsProgram(vertex, fourImages);
  glUseProgram(program);
  for (GLuint unit = 0; unit < 4; ++unit)
    glBindImageTexture(unit, textures[4], 0, GL_FALSE, 0, GL_READ_WRITE, GL_R32UI);
  drawAndCheck({360, 0, 0, 4, 364, 0, 0, 4});
  glDeleteProgram(program);

  GLuint resultBuffer = 0;
  glGenBuffers(1, &resultBuffer);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, resultBuffer);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(seed), nullptr, GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, resultBuffer);
  auto dispatchAndCheck = [&](GLuint computeProgramId, const std::array<GLuint, 8> &wanted) {
    glUseProgram(computeProgramId);
    glDispatchCompute(1, 1, 1);
    glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    const auto *data = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(seed), GL_MAP_READ_BIT));
    require(data && std::equal(wanted.begin(), wanted.end(), data),
            "Compute image alias output differs");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER) && glGetError() == GL_NO_ERROR,
            "Cannot read compute image alias output");
  };
  program = computeProgram(compute);
  glBindImageTexture(0, textures[3], 0, GL_FALSE, 1, GL_WRITE_ONLY, GL_RGBA32UI);
  glBindImageTexture(1, textures[3], 0, GL_TRUE, 0, GL_READ_ONLY, GL_RGBA32UI);
  dispatchAndCheck(program, {51, 4, 5, 6, 50, 4, 5, 6});
  glDeleteProgram(program);
  program = computeProgram(snorm);
  glBindImageTexture(0, textures[4], 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8_SNORM);
  glBindImageTexture(1, textures[4], 0, GL_FALSE, 0, GL_READ_ONLY, GL_R32UI);
  dispatchAndCheck(program, {0x7f20c081, 4, 5, 6, 0x7f20c081, 4, 5, 6});
  glDeleteProgram(program);
  glUseProgram(0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteBuffers(1, &resultBuffer);
  glDeleteTextures(textures.size(), textures.data());
  std::puts("IMAGE_ALIAS_PASS vertex=1 graphics=1 compute=1 mixed_shape=1 mixed_format=1 four=1 binary=1 exchange=1");
}

static void verifyGraphicsStorageArrays() {
  GLint alignment = 0;
  glGetIntegerv(GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT, &alignment);
  require(alignment > 0, "Invalid SSBO offset alignment");
  const size_t stride = std::max<size_t>(static_cast<size_t>(alignment), 64);
  require(stride % sizeof(GLuint) == 0, "Unsupported SSBO alignment");
  std::vector<GLuint> initial(stride * 3 / sizeof(GLuint), 0);
  const size_t first = stride / sizeof(GLuint), second = first * 2;
  initial[first + 1] = 101;
  initial[second + 1] = 201;
  const std::array<GLuint, 8> empty = {};
  std::array<GLuint, 2> buffers = {};
  glGenBuffers(buffers.size(), buffers.data());
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
  glBufferData(GL_SHADER_STORAGE_BUFFER, initial.size() * sizeof(GLuint),
               initial.data(), GL_DYNAMIC_DRAW);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[1]);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(empty), empty.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, buffers[1]);
  constexpr char vertexRead[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) readonly buffer Data { uint values[]; } d[2];
    uniform int selected;
    flat out uvec4 value;
    void main() {
      uint id=uint(gl_VertexID);
      value=uvec4(d[0].values[selected], d[1].values[selected], uint(d[0].values.length()), uint(d[1].values.length()));
      gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);
    }
  )";
  constexpr char fragmentWrite[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=2) buffer Result { uvec4 values[]; } outputData;
    flat in uvec4 value;
    layout(location=0) out vec4 color;
    void main() { if (gl_FragCoord.x<1.0) outputData.values[0]=value; color=vec4(1); }
  )";
  constexpr char vertexPlain[] = R"(#version 310 es
    void main() { uint id=uint(gl_VertexID); gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1); }
  )";
  constexpr char fragmentRead[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) readonly buffer Data { uint values[]; } d[2];
    uniform int selected;
    layout(std430,binding=2) buffer Result { uvec4 values[]; } outputData;
    layout(location=0) out vec4 color;
    void main() {
      if (gl_FragCoord.x<1.0) outputData.values[1]=uvec4(
          d[0].values[selected], d[1].values[selected], uint(d[0].values.length()), uint(d[1].values.length()));
      color=vec4(1);
    }
  )";
  GLuint vertexProgram =
      reloadGraphicsProgramBinary(graphicsProgram(vertexRead, fragmentWrite));
  GLuint fragmentProgram =
      reloadGraphicsProgramBinary(graphicsProgram(vertexPlain, fragmentRead));
  glViewport(0, 0, 2, 1);
  glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 0, buffers[0], stride,
                    4 * sizeof(GLuint));
  glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 1, buffers[0], 2 * stride,
                    6 * sizeof(GLuint));
  glUseProgram(vertexProgram);
  const GLint vertexSelected = glGetUniformLocation(vertexProgram, "selected");
  require(vertexSelected >= 0, "Missing vertex storage index");
  glUniform1i(vertexSelected, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 0, buffers[0], 2 * stride,
                    6 * sizeof(GLuint));
  glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 1, buffers[0], stride,
                    4 * sizeof(GLuint));
  const GLuint firstBlock = glGetProgramResourceIndex(fragmentProgram, GL_SHADER_STORAGE_BLOCK, "Data[0]");
  const GLuint secondBlock = glGetProgramResourceIndex(fragmentProgram, GL_SHADER_STORAGE_BLOCK, "Data[1]");
  require(firstBlock != GL_INVALID_INDEX && secondBlock != GL_INVALID_INDEX,
          "Missing shader storage block array reflection");
  glUseProgram(fragmentProgram);
  const GLint fragmentSelected = glGetUniformLocation(fragmentProgram, "selected");
  require(fragmentSelected >= 0, "Missing fragment storage index");
  glUniform1i(fragmentSelected, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[1]);
  const auto *actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(empty), GL_MAP_READ_BIT));
  const std::array<GLuint, 8> expected = {101, 201, 4, 6, 201, 101, 6, 4};
  require(actual && std::equal(expected.begin(), expected.end(), actual),
          "Graphics SSBO arrays or rebound range lengths differ");
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER) &&
              glGetError() == GL_NO_ERROR,
          "Graphics SSBO array buffer mapping failed");
  glDeleteBuffers(buffers.size(), buffers.data());
  glDeleteProgram(vertexProgram);
  glDeleteProgram(fragmentProgram);
  std::puts("GRAPHICS_SSBO_ARRAY_PASS vertex_fragment=1 range_rebind=1 reflection=1");
}

static void verifyGraphicsStorageInvalidation() {
  constexpr char vertexRead[] = R"(#version 310 es
    layout(location=0) in vec2 position;
    void main() { gl_Position=vec4(position,0,1); }
  )";
  constexpr char vertexWrite[] = R"(#version 310 es
    precision highp int;
    layout(std430,binding=0) buffer Data { int values[]; } data;
    uniform bool makeVisible;
    void main() {
      uint id=uint(gl_VertexID);
      int x=id==1u?3:-1, y=id==2u?3:-1;
      data.values[2u*id]=(makeVisible?x:4)*65536;
      data.values[2u*id+1u]=(makeVisible?y:4)*65536;
      gl_Position=vec4(float(x),float(y),0,1);
    }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float;
    layout(location=0) out vec4 color;
    void main() { color=vec4(1,0,0,1); }
  )";
  GLuint reader = graphicsProgram(vertexRead, fragment),
         writer = graphicsProgram(vertexWrite, fragment);
  const std::array<GLint, 6> initial = {4 * 65536, 4 * 65536, 4 * 65536,
                                        4 * 65536, 4 * 65536, 4 * 65536};
  const std::array<GLushort, 3> indices = {0, 1, 2};
  std::array<GLuint, 2> buffers = {};
  glGenBuffers(buffers.size(), buffers.data());
  glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
  glBufferData(GL_ARRAY_BUFFER, sizeof(initial), initial.data(),
               GL_DYNAMIC_DRAW);
  glVertexAttribPointer(0, 2, GL_FIXED, GL_FALSE, 0, nullptr);
  glEnableVertexAttribArray(0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices.data(),
               GL_STATIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
  glViewport(0, 0, 2, 1);
  glClearColor(0, 0, 0, 1);
  auto readPixel = []() {
    std::array<GLubyte, 4> pixel = {};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    return pixel;
  };
  glClear(GL_COLOR_BUFFER_BIT);
  glUseProgram(reader);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  require(readPixel() == std::array<GLubyte, 4>{0, 0, 0, 255},
          "Initial vertex conversion differs");
  const GLint visible = glGetUniformLocation(writer, "makeVisible");
  require(visible >= 0, "Missing graphics storage writer uniform");
  glUseProgram(writer);
  glUniform1i(visible, 1);
  glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, nullptr);
  glMemoryBarrier(GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT |
                  GL_SHADER_STORAGE_BARRIER_BIT);
  glClear(GL_COLOR_BUFFER_BIT);
  glUseProgram(reader);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  require(readPixel() == std::array<GLubyte, 4>{255, 0, 0, 255},
          "Indexed draw left stale vertex conversion");
  glUseProgram(writer);
  glUniform1i(visible, 0);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT |
                  GL_SHADER_STORAGE_BARRIER_BIT);
  glClear(GL_COLOR_BUFFER_BIT);
  glUseProgram(reader);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  require(readPixel() == std::array<GLubyte, 4>{0, 0, 0, 255},
          "Array draw left stale vertex conversion");
  require(glGetError() == GL_NO_ERROR, "Graphics storage invalidation failed");
  glDisableVertexAttribArray(0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
  glDeleteBuffers(buffers.size(), buffers.data());
  glDeleteProgram(reader);
  glDeleteProgram(writer);
  std::puts("GRAPHICS_SSBO_INVALIDATION_PASS arrays=1 indexed=1");
}

static void verifyGraphicsStageLimits() {
  GLint vertexLimit = 0, fragmentLimit = 0, bindingLimit = 0, combinedLimit = 0,
        colorLimit = 0;
  glGetIntegerv(GL_MAX_DRAW_BUFFERS, &colorLimit);
  glGetIntegerv(GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS, &vertexLimit);
  glGetIntegerv(GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS, &fragmentLimit);
  glGetIntegerv(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, &bindingLimit);
  glGetIntegerv(GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS, &combinedLimit);
  const GLint totalLimit = std::min(bindingLimit, combinedLimit);
  const GLint vertices = std::min(vertexLimit, totalLimit / 2);
  const GLint fragments = std::min(fragmentLimit, totalLimit - vertices);
  require(vertices > 0 && fragments > 0,
          "Insufficient simultaneous graphics SSBO bindings");
  std::string vertex =
      "#version 310 es\nprecision highp float; precision highp int;\n";
  std::string fragment =
      "#version 310 es\nprecision highp float; precision highp int;\n";
  for (GLint i = 0; i < vertices; ++i) {
    const std::string n = std::to_string(i);
    vertex += "layout(std430,binding=" + n + ") buffer V" + n +
              " {uint value[];} v" + n + ";\n";
  }
  for (GLint i = 0; i < fragments; ++i) {
    const std::string n = std::to_string(i), b = std::to_string(vertices + i);
    fragment += "layout(std430,binding=" + b + ") buffer F" + n +
                " {uint value[];} f" + n + ";\n";
  }
  vertex += "void main(){ uint id=uint(gl_VertexID);";
  for (GLint i = 0; i < vertices; ++i)
    vertex += "v" + std::to_string(i) +
              ".value[id]=" + std::to_string(100 + i) + "u+id;";
  vertex += "gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);}";
  for (GLint i = 0; i < colorLimit; ++i) {
    const std::string n = std::to_string(i);
    fragment += "layout(location=" + n + ") out vec4 color" + n + ";\n";
  }
  fragment += "void main(){ uint id=uint(gl_FragCoord.x);";
  for (GLint i = 0; i < fragments; ++i)
    fragment += "f" + std::to_string(i) +
                ".value[id]=" + std::to_string(200 + i) + "u+id;";
  for (GLint i = 0; i < colorLimit; ++i)
    fragment += "color" + std::to_string(i) + "=vec4(1);";
  fragment += "}";
  GLuint program = graphicsProgram(vertex.c_str(), fragment.c_str());
  GLuint framebuffer = 0;
  glGenFramebuffers(1, &framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  std::vector<GLuint> colors(colorLimit);
  std::vector<GLenum> attachments(colorLimit);
  glGenTextures(colorLimit, colors.data());
  for (GLint i = 0; i < colorLimit; ++i) {
    attachments[i] = static_cast<GLenum>(GL_COLOR_ATTACHMENT0 + i);
    glBindTexture(GL_TEXTURE_2D, colors[i]);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 2, 1);
    glFramebufferTexture2D(GL_FRAMEBUFFER, attachments[i], GL_TEXTURE_2D,
                           colors[i], 0);
  }
  glDrawBuffers(colorLimit, attachments.data());
  require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE,
          "Graphics SSBO multi-attachment framebuffer incomplete");
  std::vector<GLuint> buffers(vertices + fragments);
  glGenBuffers(static_cast<GLsizei>(buffers.size()), buffers.data());
  const std::array<GLuint, 4> zero = {};
  for (size_t i = 0; i < buffers.size(); ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(i),
                     buffers[i]);
  }
  glUseProgram(program);
  glViewport(0, 0, 2, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  for (size_t i = 0; i < buffers.size(); ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    const auto *p = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    const bool isVertex = i < static_cast<size_t>(vertices);
    const GLuint expected = static_cast<GLuint>((isVertex ? 100 : 200) +
                                                (isVertex ? i : i - vertices));
    require(p && p[0] == expected && p[1] == expected + 1 &&
                p[2] == (isVertex ? expected + 2 : 0) && p[3] == 0,
            "Simultaneous graphics SSBO output or guards differ");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap graphics SSBO");
  }
  for (GLint i = 0; i < colorLimit; ++i) {
    std::array<GLubyte, 4> color = {};
    glReadBuffer(attachments[i]);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, color.data());
    require(color == std::array<GLubyte, 4>{255, 255, 255, 255},
            "Graphics attachment output differs");
  }
  require(glGetError() == GL_NO_ERROR, "Graphics SSBO stage limit test failed");
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDeleteFramebuffers(1, &framebuffer);
  glDeleteTextures(colorLimit, colors.data());
  glDeleteBuffers(static_cast<GLsizei>(buffers.size()), buffers.data());
  glDeleteProgram(program);
  std::printf("GRAPHICS_SSBO_STAGE_LIMIT_PASS vertex=%d fragment=%d color=%d\n",
              vertices, fragments, colorLimit);
}

static void verifyGraphicsAtomicCounters() {
  GLint vertexBuffers = 0, fragmentBuffers = 0, vertexCounters = 0,
        fragmentCounters = 0;
  glGetIntegerv(GL_MAX_VERTEX_ATOMIC_COUNTER_BUFFERS, &vertexBuffers);
  glGetIntegerv(GL_MAX_FRAGMENT_ATOMIC_COUNTER_BUFFERS, &fragmentBuffers);
  glGetIntegerv(GL_MAX_VERTEX_ATOMIC_COUNTERS, &vertexCounters);
  glGetIntegerv(GL_MAX_FRAGMENT_ATOMIC_COUNTERS, &fragmentCounters);
  std::printf("ATOMIC_COUNTER_LIMITS vertex=%d/%d fragment=%d/%d\n",
              vertexBuffers, vertexCounters, fragmentBuffers, fragmentCounters);
  require(vertexBuffers > 0 && fragmentBuffers > 0 && vertexCounters > 0 &&
              fragmentCounters > 0,
          "Graphics atomic counters unavailable");
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(binding=0,offset=0) uniform atomic_uint vertexCounter;
    void main() {
      uint id=uint(gl_VertexID);
      atomicCounterIncrement(vertexCounter);
      memoryBarrierAtomicCounter();
      gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);
    }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(binding=0,offset=4) uniform atomic_uint fragmentCounter;
    layout(location=0) out vec4 color;
    void main() { atomicCounterIncrement(fragmentCounter); memoryBarrierAtomicCounter(); color=vec4(1); }
  )";
  GLuint program = graphicsProgram(vertex, fragment);
  constexpr size_t stride = 256;
  std::array<GLuint, stride * 3 / sizeof(GLuint)> data = {};
  GLuint buffer;
  glGenBuffers(1, &buffer);
  glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffer);
  glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(data), data.data(),
               GL_DYNAMIC_DRAW);
  glUseProgram(program);
  glViewport(0, 0, 2, 1);
  for (GLintptr offset :
       {static_cast<GLintptr>(stride), static_cast<GLintptr>(stride * 2)}) {
    glBindBufferRange(GL_ATOMIC_COUNTER_BUFFER, 0, buffer, offset,
                      2 * sizeof(GLuint));
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glMemoryBarrier(GL_ATOMIC_COUNTER_BARRIER_BIT);
  }
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  const auto *actual = static_cast<const GLuint *>(glMapBufferRange(
      GL_ATOMIC_COUNTER_BUFFER, 0, sizeof(data), GL_MAP_READ_BIT));
  const size_t first = stride / sizeof(GLuint), second = 2 * first;
  if (actual && (actual[first] != 3 || actual[first + 1] != 2 ||
                 actual[second] != 3 || actual[second + 1] != 2)) {
    std::fprintf(stderr, "ATOMIC_COUNTER_VALUES %u %u %u %u\n", actual[first],
                 actual[first + 1], actual[second], actual[second + 1]);
  }
  require(actual && actual[first] == 3 && actual[first + 1] == 2 &&
              actual[second] == 3 && actual[second + 1] == 2 &&
              actual[first - 1] == 0 && actual[second + 2] == 0,
          "Graphics atomic counter values or range guards differ");
  require(glUnmapBuffer(GL_ATOMIC_COUNTER_BUFFER) &&
              glGetError() == GL_NO_ERROR,
          "Graphics atomic counter buffer mapping failed");
  glDeleteBuffers(1, &buffer);
  glDeleteProgram(program);
  std::puts(
      "GRAPHICS_ATOMIC_COUNTER_PASS vertex_fragment=1 range_rebind=1 fences=1");
}

static void verifyGraphicsAtomicCounterLimits() {
  GLint vertexLimit = 0, fragmentLimit = 0, combinedLimit = 0;
  glGetIntegerv(GL_MAX_VERTEX_ATOMIC_COUNTERS, &vertexLimit);
  glGetIntegerv(GL_MAX_FRAGMENT_ATOMIC_COUNTERS, &fragmentLimit);
  glGetIntegerv(GL_MAX_COMBINED_ATOMIC_COUNTERS, &combinedLimit);
  const GLint vertices = std::min(vertexLimit, combinedLimit / 2);
  const GLint fragments = std::min(fragmentLimit, combinedLimit - vertices);
  require(vertices > 0 && fragments > 0,
          "Insufficient simultaneous graphics atomic counters");
  std::string vertex =
      "#version 310 es\nprecision highp float; precision highp int;\n";
  std::string fragment =
      "#version 310 es\nprecision highp float; precision highp int;\n";
  for (GLint i = 0; i < vertices; ++i) {
    vertex += "layout(binding=0,offset=" + std::to_string(i * 4) +
              ") uniform atomic_uint v" + std::to_string(i) + ";\n";
  }
  for (GLint i = 0; i < fragments; ++i) {
    fragment +=
        "layout(binding=0,offset=" + std::to_string((vertices + i) * 4) +
        ") uniform atomic_uint f" + std::to_string(i) + ";\n";
  }
  vertex += "void main(){ uint id=uint(gl_VertexID);";
  for (GLint i = 0; i < vertices; ++i)
    vertex += "atomicCounterIncrement(v" + std::to_string(i) + ");";
  vertex += "gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);}";
  fragment += "layout(location=0) out vec4 color; void main(){";
  for (GLint i = 0; i < fragments; ++i)
    fragment += "atomicCounterIncrement(f" + std::to_string(i) + ");";
  fragment += "color=vec4(1);}";
  GLuint program = graphicsProgram(vertex.c_str(), fragment.c_str());
  std::vector<GLuint> zero(vertices + fragments, 0);
  GLuint buffer;
  glGenBuffers(1, &buffer);
  glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffer);
  glBufferData(GL_ATOMIC_COUNTER_BUFFER, zero.size() * sizeof(GLuint),
               zero.data(), GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, buffer);
  glUseProgram(program);
  glViewport(0, 0, 2, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  const auto *p = static_cast<const GLuint *>(
      glMapBufferRange(GL_ATOMIC_COUNTER_BUFFER, 0,
                       zero.size() * sizeof(GLuint), GL_MAP_READ_BIT));
  require(p, "Cannot map graphics counter buffer");
  for (GLint i = 0; i < vertices + fragments; ++i) {
    require(p[i] == static_cast<GLuint>(i < vertices ? 3 : 2),
            "Graphics atomic counter stage limit differs");
  }
  require(glUnmapBuffer(GL_ATOMIC_COUNTER_BUFFER) &&
              glGetError() == GL_NO_ERROR,
          "Graphics atomic counter stage limit test failed");
  glDeleteBuffers(1, &buffer);
  glDeleteProgram(program);
  std::printf(
      "GRAPHICS_ATOMIC_COUNTER_STAGE_LIMIT_PASS vertex=%d fragment=%d\n",
      vertices, fragments);
}

static void verifyGraphicsStorageTransformFeedback() {
  GLint storageLimit = 0, xfbLimit = 0;
  glGetIntegerv(GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS, &storageLimit);
  glGetIntegerv(GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS, &xfbLimit);
  const GLint count = std::min(storageLimit, xfbLimit);
  require(count > 0, "No storage or transform-feedback bindings");
  std::string vertex =
      "#version 310 es\nprecision highp float; precision highp int;\n";
  vertex += "layout(binding=0,offset=0) uniform atomic_uint counter;\n";
  std::vector<std::string> varyingNames;
  for (GLint i = 0; i < count; ++i) {
    const std::string n = std::to_string(i);
    vertex += "layout(std430,binding=" + n + ") buffer B" + n +
              " {uint value[];} b" + n + ";\n";
    vertex += "out float captured" + n + ";\n";
    varyingNames.push_back("captured" + n);
  }
  vertex += "void main(){ uint id=uint(gl_VertexID); "
            "atomicCounterIncrement(counter); memoryBarrierAtomicCounter(); memoryBarrierBuffer();";
  for (GLint i = 0; i < count; ++i) {
    const std::string n = std::to_string(i);
    vertex += "b" + n + ".value[id]=" + std::to_string(10 * i) + "u+id;";
    vertex += "captured" + n + "=float(" + std::to_string(10 * i) + "u+id);";
  }
  vertex += "gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);}";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; layout(location=0) out vec4 color;
    void main() { color=vec4(1); }
  )";
  const char *sources[] = {vertex.c_str(), fragment};
  const GLenum stages[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
  GLuint program = glCreateProgram();
  for (int i = 0; i < 2; ++i) {
    GLuint shader = glCreateShader(stages[i]);
    glShaderSource(shader, 1, &sources[i], nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
      char log[8192] = {};
      glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
      std::fprintf(stderr, "XFB_SHADER_LOG %s\n", log);
    }
    require(ok, "Transform-feedback storage shader compilation failed");
    glAttachShader(program, shader);
    glDeleteShader(shader);
  }
  std::vector<const char *> varyings;
  for (const auto &name : varyingNames)
    varyings.push_back(name.c_str());
  glTransformFeedbackVaryings(program, count, varyings.data(),
                              GL_SEPARATE_ATTRIBS);
  glLinkProgram(program);
  GLint ok = GL_FALSE;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "XFB_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Transform-feedback storage program linking failed");
  GLuint feedback = 0;
  glGenTransformFeedbacks(1, &feedback);
  glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, feedback);
  std::vector<GLuint> buffers(2 * count + 1);
  glGenBuffers(static_cast<GLsizei>(buffers.size()), buffers.data());
  const std::array<GLuint, 4> zero = {};
  for (GLint i = 0; i < count; ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, buffers[i]);
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[count + i]);
    glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, i, buffers[count + i]);
  }
  glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffers[2 * count]);
  glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(zero), zero.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, buffers[2 * count]);
  glUseProgram(program);
  glEnable(GL_RASTERIZER_DISCARD);
  glBeginTransformFeedback(GL_TRIANGLES);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glEndTransformFeedback();
  glDisable(GL_RASTERIZER_DISCARD);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  for (GLint i = 0; i < count; ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    const auto *storage = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(storage && storage[0] == static_cast<GLuint>(10 * i) &&
                storage[1] == static_cast<GLuint>(10 * i + 1) &&
                storage[2] == static_cast<GLuint>(10 * i + 2) &&
                storage[3] == 0,
            "Storage output differs with transform feedback");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap storage output");
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[count + i]);
    const auto *feedbackValues = static_cast<const GLfloat *>(glMapBufferRange(
        GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(feedbackValues && feedbackValues[0] == 10.0f * i &&
                feedbackValues[1] == 10.0f * i + 1.0f &&
                feedbackValues[2] == 10.0f * i + 2.0f,
            "Transform-feedback output differs");
    require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER),
            "Cannot unmap transform-feedback output");
  }
  glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffers[2 * count]);
  const auto *counter = static_cast<const GLuint *>(glMapBufferRange(
      GL_ATOMIC_COUNTER_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
  if (counter && (counter[0] != 3 || counter[1] != 0)) {
    std::fprintf(stderr, "XFB_COUNTER_VALUES %u %u\n", counter[0], counter[1]);
  }
  require(counter && counter[0] == 3 && counter[1] == 0,
          "Atomic counter differs with transform feedback");
  require(glUnmapBuffer(GL_ATOMIC_COUNTER_BUFFER) &&
              glGetError() == GL_NO_ERROR,
          "Transform-feedback storage test failed");
  glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
  glDeleteTransformFeedbacks(1, &feedback);
  glDeleteBuffers(static_cast<GLsizei>(buffers.size()), buffers.data());
  glDeleteProgram(program);
  std::printf("GRAPHICS_SSBO_XFB_PASS storage=%d feedback=%d counters=1\n",
              count, count);
}

static void verifyGraphicsStorageFeedbackRaster() {
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer Counts { uint value; } data;
    layout(binding=0,offset=0) uniform atomic_uint counter;
    flat out uint captured;
    void main() {
      uint id=uint(gl_VertexID);
      captured=atomicAdd(data.value,1u); atomicCounterIncrement(counter);
      memoryBarrierBuffer(); memoryBarrierAtomicCounter();
      gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1);
    }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int;
    flat in uint captured; layout(location=0) out vec4 color;
    void main() { color=vec4(float(captured)/16.0,0,0,1); }
  )";
  for (int binary = 0; binary < 2; ++binary) {
    const char *sources[] = {vertex, fragment};
    const GLenum stages[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
    GLuint program = glCreateProgram();
    for (int i = 0; i < 2; ++i) {
      GLuint shader = glCreateShader(stages[i]);
      glShaderSource(shader, 1, &sources[i], nullptr);
      glCompileShader(shader);
      GLint ok = GL_FALSE;
      glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
      if (!ok) {
        char log[8192] = {};
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        std::fprintf(stderr, "XFB_RASTER_SHADER_LOG %s\n", log);
      }
      require(ok, "Transform-feedback raster shader compilation failed");
      glAttachShader(program, shader);
      glDeleteShader(shader);
    }
    const char *varying = "captured";
    glTransformFeedbackVaryings(program, 1, &varying, GL_INTERLEAVED_ATTRIBS);
    glProgramParameteri(program, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE);
    glLinkProgram(program);
    GLint ok = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
      char log[8192] = {};
      glGetProgramInfoLog(program, sizeof(log), nullptr, log);
      std::fprintf(stderr, "XFB_RASTER_PROGRAM_LOG %s\n", log);
    }
    require(ok, "Transform-feedback raster program linking failed");
    if (binary)
      program = reloadGraphicsProgramBinary(program);
    GLuint feedback = 0;
    glGenTransformFeedbacks(1, &feedback);
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, feedback);
    std::array<GLuint, 3> buffers = {};
    glGenBuffers(buffers.size(), buffers.data());
    const std::array<GLuint, 4> zero = {};
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
    glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffers[1]);
    glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, buffers[1]);
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[2]);
    glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffers[2]);
    glDisable(GL_RASTERIZER_DISCARD);
    glViewport(0, 0, 2, 1);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program);
    glBeginTransformFeedback(GL_TRIANGLES);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glEndTransformFeedback();
    glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
    const auto *storage = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    if (storage && storage[0] != 3)
      std::fprintf(stderr, "XFB_RASTER_STORAGE_COUNT %u\n", storage[0]);
    require(storage && storage[0] == 3 && storage[1] == 0,
            "Vertex storage executed more than once with feedback and "
            "rasterization");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap XFB raster storage");
    glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffers[1]);
    const auto *counter = static_cast<const GLuint *>(glMapBufferRange(
        GL_ATOMIC_COUNTER_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(counter && counter[0] == 3 && counter[1] == 0,
            "Vertex counter executed more than once with feedback and "
            "rasterization");
    require(glUnmapBuffer(GL_ATOMIC_COUNTER_BUFFER),
            "Cannot unmap XFB raster counter");
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[2]);
    const auto *feedbackValues = static_cast<const GLuint *>(glMapBufferRange(
        GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(feedbackValues, "Cannot map XFB raster output");
    std::array<GLuint, 3> captured = {feedbackValues[0], feedbackValues[1],
                                      feedbackValues[2]};
    require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER),
            "Cannot unmap XFB raster output");
    auto sorted = captured;
    std::sort(sorted.begin(), sorted.end());
    require(sorted == std::array<GLuint, 3>{0, 1, 2},
            "Transform-feedback values differ from vertex invocations");
    std::array<GLubyte, 4> pixel = {};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    bool matches = false;
    for (GLuint value : captured) {
      const int expected = static_cast<int>((value * 255u + 8u) / 16u);
      matches |= std::abs(static_cast<int>(pixel[0]) - expected) <= 1;
    }
    require(matches && pixel[3] == 255 && glGetError() == GL_NO_ERROR,
            "Rasterized vertex output does not match transform feedback");
    // Ending feedback must restore the ordinary shader variant and stop
    // capture.
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT |
                    GL_ATOMIC_COUNTER_BARRIER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
    storage = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(storage && storage[0] == 6,
            "Ordinary draw after transform feedback differs");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap post-feedback storage");
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[2]);
    feedbackValues = static_cast<const GLuint *>(glMapBufferRange(
        GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(feedbackValues &&
                std::equal(captured.begin(), captured.end(), feedbackValues),
            "Transform feedback remained active after ending");
    require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER) &&
                glGetError() == GL_NO_ERROR,
            "Post-feedback draw failed");
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
    glDeleteTransformFeedbacks(1, &feedback);
    glDeleteBuffers(buffers.size(), buffers.data());
    glDeleteProgram(program);
  }
  std::puts("GRAPHICS_SSBO_XFB_RASTER_PASS binary=1 counter=1 output=1");
}

static void verifyFeedbackInstancesAndOffsets() {
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer Counts { uint value; } data;
    flat out uint captured;
    void main() {
      uint id=uint(gl_VertexID); atomicAdd(data.value,1u);
      captured=id+uint(gl_InstanceID)*100u;
      uint p=(id+1u)%3u;
      gl_Position=vec4(p==1u?3.0:-1.0,p==2u?3.0:-1.0,0,1);
    }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int;
    flat in uint captured; layout(location=0) out vec4 color;
    void main(){ color=vec4(float(captured%4u)/4.0,0,0,1); }
  )";
  const char *sources[] = {vertex, fragment};
  const GLenum stages[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
  GLuint program = glCreateProgram();
  for (int i = 0; i < 2; ++i) {
    GLuint shader = glCreateShader(stages[i]);
    glShaderSource(shader, 1, &sources[i], nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
      char log[8192] = {};
      glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
      std::fprintf(stderr, "XFB_INSTANCED_SHADER_LOG %s\n", log);
    }
    require(ok, "Instanced XFB shader compilation failed");
    glAttachShader(program, shader);
    glDeleteShader(shader);
  }
  const char *varying = "captured";
  glTransformFeedbackVaryings(program, 1, &varying, GL_INTERLEAVED_ATTRIBS);
  glLinkProgram(program);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "XFB_INSTANCED_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Instanced XFB program linking failed");
  constexpr GLintptr offset = 256;
  const std::array<GLuint, 9> expected = {2, 3, 4, 102, 103, 104, 5, 6, 7};
  for (int raster = 0; raster < 2; ++raster) {
    GLuint feedback = 0;
    glGenTransformFeedbacks(1, &feedback);
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, feedback);
    std::array<GLuint, 2> buffers = {};
    glGenBuffers(buffers.size(), buffers.data());
    const std::array<GLuint, 4> zero = {};
    std::vector<GLuint> initial((offset / 4) + expected.size() + 4,
                                0xccccccccu);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[1]);
    glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, initial.size() * sizeof(GLuint),
                 initial.data(), GL_DYNAMIC_DRAW);
    glBindBufferRange(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffers[1], offset,
                      expected.size() * sizeof(GLuint));
    if (raster)
      glDisable(GL_RASTERIZER_DISCARD);
    else
      glEnable(GL_RASTERIZER_DISCARD);
    glViewport(0, 0, 2, 1);
    glUseProgram(program);
    glBeginTransformFeedback(GL_TRIANGLES);
    glDrawArraysInstanced(GL_TRIANGLES, 2, 3, 2);
    glDrawArrays(GL_TRIANGLES, 5, 3);
    glEndTransformFeedback();
    glDisable(GL_RASTERIZER_DISCARD);
    glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
    const auto *counter = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    if (counter && counter[0] != 9)
      std::fprintf(stderr, "XFB_INSTANCE_COUNTER raster=%d value=%u\n", raster,
                   counter[0]);
    require(counter && counter[0] == 9,
            "Instanced feedback vertex count differs");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap instanced feedback counter");
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[1]);
    const auto *actual = static_cast<const GLuint *>(
        glMapBufferRange(GL_TRANSFORM_FEEDBACK_BUFFER, 0,
                         initial.size() * sizeof(GLuint), GL_MAP_READ_BIT));
    if (actual &&
        !std::equal(expected.begin(), expected.end(), actual + offset / 4)) {
      std::fprintf(stderr, "XFB_INSTANCE_VALUES raster=%d", raster);
      for (size_t i = 0; i < expected.size(); ++i)
        std::fprintf(stderr, " %u", actual[offset / 4 + i]);
      std::fputc('\n', stderr);
    }
    require(
        actual && actual[offset / 4 - 1] == 0xccccccccu &&
            actual[offset / 4 + expected.size()] == 0xccccccccu &&
            std::equal(expected.begin(), expected.end(), actual + offset / 4),
        "Instanced feedback data or guards differ");
    require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER) &&
                glGetError() == GL_NO_ERROR,
            "Instanced feedback mapping failed");
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
    glDeleteTransformFeedbacks(1, &feedback);
    glDeleteBuffers(buffers.size(), buffers.data());
  }
  glDeleteProgram(program);
  std::puts("GRAPHICS_SSBO_XFB_INSTANCE_PASS raster=both draws=2 first=nonzero "
            "guard=1");
}

static GLuint separableProgram(GLenum stage, const char *source) {
  GLuint shader = glCreateShader(stage);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    std::fprintf(stderr, "PIPELINE_SHADER_LOG %s\n", log);
  }
  require(ok, "Separable storage shader compilation failed");
  GLuint program = glCreateProgram();
  glProgramParameteri(program, GL_PROGRAM_SEPARABLE, GL_TRUE);
  glAttachShader(program, shader);
  glDeleteShader(shader);
  glLinkProgram(program);
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "PIPELINE_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Separable storage shader linking failed");
  return program;
}

static void verifyFeedbackSeparablePipeline() {
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer Counts {uint value;} data;
    flat out uint captured;
    void main(){ uint id=uint(gl_VertexID); captured=atomicAdd(data.value,1u);
      gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1); }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int; flat in uint captured;
    layout(location=0) out vec4 color;
    void main(){color=vec4(float(captured)/16.0,0,0,1);}
  )";
  GLuint shader = glCreateShader(GL_VERTEX_SHADER);
  const char *src = vertex;
  glShaderSource(shader, 1, &src, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  require(ok, "Separable XFB vertex compile failed");
  GLuint vp = glCreateProgram();
  glProgramParameteri(vp, GL_PROGRAM_SEPARABLE, GL_TRUE);
  glAttachShader(vp, shader);
  glDeleteShader(shader);
  const char *varying = "captured";
  glTransformFeedbackVaryings(vp, 1, &varying, GL_INTERLEAVED_ATTRIBS);
  glLinkProgram(vp);
  glGetProgramiv(vp, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramInfoLog(vp, sizeof(log), nullptr, log);
    std::fprintf(stderr, "XFB_PIPELINE_PROGRAM_LOG %s\n", log);
  }
  require(ok, "Separable XFB vertex linking failed");
  GLuint fp = separableProgram(GL_FRAGMENT_SHADER, fragment), pipeline = 0;
  glGenProgramPipelines(1, &pipeline);
  glUseProgram(0);
  glBindProgramPipeline(pipeline);
  glUseProgramStages(pipeline, GL_VERTEX_SHADER_BIT, vp);
  glUseProgramStages(pipeline, GL_FRAGMENT_SHADER_BIT, fp);
  glValidateProgramPipeline(pipeline);
  glGetProgramPipelineiv(pipeline, GL_VALIDATE_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramPipelineInfoLog(pipeline, sizeof(log), nullptr, log);
    std::fprintf(stderr, "XFB_PIPELINE_LOG %s\n", log);
  }
  require(ok, "Separable XFB pipeline validation failed");
  GLuint feedback = 0;
  glGenTransformFeedbacks(1, &feedback);
  glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, feedback);
  std::array<GLuint, 2> buffers = {};
  glGenBuffers(buffers.size(), buffers.data());
  const std::array<GLuint, 4> zero = {};
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
  glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
  glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[1]);
  glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, sizeof(zero), zero.data(),
               GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffers[1]);
  glDisable(GL_RASTERIZER_DISCARD);
  glViewport(0, 0, 2, 1);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glBeginTransformFeedback(GL_TRIANGLES);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glEndTransformFeedback();
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[0]);
  const auto *counter = static_cast<const GLuint *>(glMapBufferRange(
      GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
  if (counter && counter[0] != 3)
    std::fprintf(stderr, "XFB_PIPELINE_COUNTER %u\n", counter[0]);
  require(counter && counter[0] == 3, "Separable XFB vertex storage differs");
  require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
          "Cannot unmap XFB pipeline counter");
  glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffers[1]);
  const auto *values = static_cast<const GLuint *>(glMapBufferRange(
      GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
  require(values, "Cannot map separable feedback");
  std::array<GLuint, 3> captured = {values[0], values[1], values[2]};
  require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER),
          "Cannot unmap separable feedback");
  auto sorted = captured;
  std::sort(sorted.begin(), sorted.end());
  require(sorted == std::array<GLuint, 3>{0, 1, 2},
          "Separable feedback data differs");
  std::array<GLubyte, 4> pixel = {};
  glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
  bool matches = false;
  for (GLuint v : captured)
    matches |= std::abs(static_cast<int>(pixel[0]) -
                        static_cast<int>((v * 255u + 8u) / 16u)) <= 1;
  require(matches && pixel[3] == 255 && glGetError() == GL_NO_ERROR,
          "Separable feedback raster output differs");
  glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
  glDeleteTransformFeedbacks(1, &feedback);
  glBindProgramPipeline(0);
  glDeleteProgramPipelines(1, &pipeline);
  glDeleteBuffers(buffers.size(), buffers.data());
  glDeleteProgram(vp);
  glDeleteProgram(fp);
  std::puts("GRAPHICS_SSBO_XFB_PIPELINE_PASS");
}

static void verifyGraphicsStoragePipeline() {
  constexpr char vertex[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=0) buffer V { uint data[]; } v;
    void main(){ uint id=uint(gl_VertexID); v.data[id]=(v.data.length()==4?100u+id:0u);
      gl_Position=vec4(id==1u?3.0:-1.0,id==2u?3.0:-1.0,0,1); }
  )";
  constexpr char fragment[] = R"(#version 310 es
    precision highp float; precision highp int;
    layout(std430,binding=1) buffer F { uint data[]; } f;
    layout(location=0) out vec4 color;
    void main(){ uint x=uint(gl_FragCoord.x); f.data[x]=(f.data.length()==4?200u+x:0u); color=vec4(1); }
  )";
  GLuint vp = separableProgram(GL_VERTEX_SHADER, vertex),
         fp = separableProgram(GL_FRAGMENT_SHADER, fragment), pipeline = 0;
  glGenProgramPipelines(1, &pipeline);
  glUseProgram(0);
  glBindProgramPipeline(pipeline);
  glUseProgramStages(pipeline, GL_VERTEX_SHADER_BIT, vp);
  glUseProgramStages(pipeline, GL_FRAGMENT_SHADER_BIT, fp);
  glValidateProgramPipeline(pipeline);
  GLint ok = GL_FALSE;
  glGetProgramPipelineiv(pipeline, GL_VALIDATE_STATUS, &ok);
  if (!ok) {
    char log[8192] = {};
    glGetProgramPipelineInfoLog(pipeline, sizeof(log), nullptr, log);
    std::fprintf(stderr, "STORAGE_PIPELINE_LOG %s\n", log);
  }
  require(ok, "Storage program pipeline validation failed");
  std::array<GLuint, 2> buffers = {};
  glGenBuffers(buffers.size(), buffers.data());
  const std::array<GLuint, 4> zero = {};
  for (size_t i = 0; i < buffers.size(); ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    glBufferData(GL_SHADER_STORAGE_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, static_cast<GLuint>(i),
                     buffers[i]);
  }
  glViewport(0, 0, 2, 1);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  for (size_t i = 0; i < buffers.size(); ++i) {
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[i]);
    const auto *p = static_cast<const GLuint *>(glMapBufferRange(
        GL_SHADER_STORAGE_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    const GLuint base = i == 0 ? 100u : 200u;
    require(p && p[0] == base && p[1] == base + 1 &&
                p[2] == (i == 0 ? base + 2 : 0) && p[3] == 0,
            "Separable graphics storage output differs");
    require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER),
            "Cannot unmap separable storage output");
  }
  require(glGetError() == GL_NO_ERROR, "Separable storage draw failed");
  glBindProgramPipeline(0);
  glDeleteProgramPipelines(1, &pipeline);
  glDeleteBuffers(buffers.size(), buffers.data());
  glDeleteProgram(vp);
  glDeleteProgram(fp);
  std::puts("GRAPHICS_SSBO_PIPELINE_PASS vertex_fragment=1");
}

static void verifyGLES30Feedback() {
  constexpr char vertex[] = R"(#version 300 es
    precision highp float; precision highp int;
    out float captured; flat out int value;
    void main(){ int id=gl_VertexID; captured=float(id+1); value=id+1;
      gl_Position=vec4(id==1?3.0:-1.0,id==2?3.0:-1.0,0,1); }
  )";
  constexpr char fragment[] = R"(#version 300 es
    precision highp float; precision highp int;
    flat in int value; layout(location=0) out vec4 color;
    void main(){ color=vec4(float(value)/4.0,0,0,1); }
  )";
  const char *sources[] = {vertex, fragment};
  const GLenum stages[] = {GL_VERTEX_SHADER, GL_FRAGMENT_SHADER};
  GLuint program = glCreateProgram();
  for (int i = 0; i < 2; ++i) {
    GLuint shader = glCreateShader(stages[i]);
    glShaderSource(shader, 1, &sources[i], nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    require(ok, "GLES 3.0 feedback shader compile failed");
    glAttachShader(program, shader);
    glDeleteShader(shader);
  }
  const char *varying = "captured";
  glTransformFeedbackVaryings(program, 1, &varying, GL_INTERLEAVED_ATTRIBS);
  glLinkProgram(program);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  require(ok, "GLES 3.0 feedback link failed");
  for (int raster = 0; raster < 2; ++raster) {
    GLuint feedback = 0, buffer = 0;
    glGenTransformFeedbacks(1, &feedback);
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, feedback);
    glGenBuffers(1, &buffer);
    const std::array<GLuint, 4> zero = {};
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    glBufferData(GL_TRANSFORM_FEEDBACK_BUFFER, sizeof(zero), zero.data(),
                 GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buffer);
    glDisable(GL_RASTERIZER_DISCARD);
    glViewport(0, 0, 2, 1);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!raster)
      glEnable(GL_RASTERIZER_DISCARD);
    glUseProgram(program);
    glBeginTransformFeedback(GL_TRIANGLES);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glEndTransformFeedback();
    glDisable(GL_RASTERIZER_DISCARD);
    glBindBuffer(GL_TRANSFORM_FEEDBACK_BUFFER, buffer);
    const auto *values = static_cast<const GLfloat *>(glMapBufferRange(
        GL_TRANSFORM_FEEDBACK_BUFFER, 0, sizeof(zero), GL_MAP_READ_BIT));
    require(values && values[0] == 1 && values[1] == 2 && values[2] == 3 &&
                values[3] == 0,
            "GLES 3.0 feedback output differs");
    require(glUnmapBuffer(GL_TRANSFORM_FEEDBACK_BUFFER),
            "GLES 3.0 feedback unmap failed");
    std::array<GLubyte, 4> pixel = {};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel.data());
    const GLenum error = glGetError();
    if (!(raster ? pixel[0] > 0 : pixel[0] == 0) || pixel[3] != 255 || error != GL_NO_ERROR)
      std::fprintf(stderr, "GLES30_XFB_PIXEL raster=%d rgba=%u,%u,%u,%u error=%x\n", raster,
                   pixel[0], pixel[1], pixel[2], pixel[3], error);
    require((raster ? pixel[0] > 0 : pixel[0] == 0) && pixel[3] == 255 && error == GL_NO_ERROR,
            "GLES 3.0 feedback rasterization differs");
    glBindTransformFeedback(GL_TRANSFORM_FEEDBACK, 0);
    glDeleteTransformFeedbacks(1, &feedback);
    glDeleteBuffers(1, &buffer);
  }
  glDeleteProgram(program);
  std::puts("GLES30_XFB_PASS raster=both");
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
      verifyGLES30Feedback();
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
        verifyGraphicsStorage();
        verifyGraphicsImages();
        verifyImageAliases();
        verifyGraphicsStorageArrays();
        verifyGraphicsStorageInvalidation();
        verifyGraphicsStageLimits();
        verifyGraphicsStoragePipeline();
        verifyFeedbackSeparablePipeline();
        verifyGraphicsAtomicCounters();
        verifyGraphicsAtomicCounterLimits();
        verifyGraphicsStorageTransformFeedback();
        verifyGraphicsStorageFeedbackRaster();
        verifyFeedbackInstancesAndOffsets();
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
