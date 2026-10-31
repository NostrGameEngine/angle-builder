#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#import <Foundation/Foundation.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl31.h>
#import <Metal/Metal.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
constexpr uint32_t kObjects = 96, kWidth = 384, kHeight = 288, kGuard = 0xcdcdcdcd;
struct Object
{
    std::array<float, 4> sphere, color;
};
static_assert(sizeof(Object) == 32);
void require(bool ok, const std::string &message)
{
    if (!ok)
    {
        throw std::runtime_error(message);
    }
}
void checkGL(const char *phase)
{
    const GLenum error = glGetError();
    require(error == GL_NO_ERROR, std::string(phase) + ": GL error " + std::to_string(error));
}
GLuint shader(GLenum stage, const char *source)
{
    GLuint result = glCreateShader(stage);
    glShaderSource(result, 1, &source, nullptr);
    glCompileShader(result);
    GLint ok = 0, length = 0;
    glGetShaderiv(result, GL_COMPILE_STATUS, &ok);
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, &length);
    std::string log(std::max(1, length), '\0');
    glGetShaderInfoLog(result, log.size(), nullptr, log.data());
    require(ok, "Shader compilation: " + log);
    return result;
}
GLuint program(const char *vs, const char *fs, const char *cs)
{
    GLuint result = glCreateProgram();
    for (const auto &stage : std::array<std::pair<GLenum, const char *>, 3>{
             {{GL_VERTEX_SHADER, vs}, {GL_FRAGMENT_SHADER, fs}, {GL_COMPUTE_SHADER, cs}}})
    {
        if (!stage.second)
        {
            continue;
        }
        GLuint compiled = shader(stage.first, stage.second);
        glAttachShader(result, compiled);
        glDeleteShader(compiled);
    }
    glLinkProgram(result);
    GLint ok = 0, length = 0;
    glGetProgramiv(result, GL_LINK_STATUS, &ok);
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, &length);
    std::string log(std::max(1, length), '\0');
    glGetProgramInfoLog(result, log.size(), nullptr, log.data());
    require(ok, "Program link: " + log);
    return result;
}
bool extension(const char *wanted)
{
    GLint count = 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint i = 0; i < count; ++i)
    {
        if (std::strcmp(reinterpret_cast<const char *>(glGetStringi(GL_EXTENSIONS, i)), wanted) ==
            0)
        {
            return true;
        }
    }
    return false;
}

void startCapture(EGLDisplay display, const char *path)
{
    auto queryDisplay = reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBEXTPROC>(
        eglGetProcAddress("eglQueryDisplayAttribEXT"));
    auto queryDevice = reinterpret_cast<PFNEGLQUERYDEVICEATTRIBEXTPROC>(
        eglGetProcAddress("eglQueryDeviceAttribEXT"));
    EGLAttrib device = 0, native = 0;
    require(
        queryDisplay && queryDevice && queryDisplay(display, EGL_DEVICE_EXT, &device) &&
            queryDevice(reinterpret_cast<EGLDeviceEXT>(device), EGL_METAL_DEVICE_ANGLE, &native),
        "Cannot obtain ANGLE's Metal device for capture");
    MTLCaptureManager *manager = [MTLCaptureManager sharedCaptureManager];
    require([manager supportsDestination:MTLCaptureDestinationGPUTraceDocument],
            "GPU trace capture is unavailable; set MTL_CAPTURE_ENABLED=1 before launch");
    NSString *filename = [NSString stringWithUTF8String:path];
    require(![[NSFileManager defaultManager] fileExistsAtPath:filename],
            "Preserve the existing GPU capture; choose a new output path");
    MTLCaptureDescriptor *descriptor = [[MTLCaptureDescriptor alloc] init];
    descriptor.captureObject         = (__bridge id<MTLDevice>)(reinterpret_cast<void *>(native));
    descriptor.destination           = MTLCaptureDestinationGPUTraceDocument;
    descriptor.outputURL             = [NSURL fileURLWithPath:filename];
    NSError *error                   = nil;
    const bool started               = [manager startCaptureWithDescriptor:descriptor error:&error];
    require(started, std::string("Cannot start GPU capture: ") +
                         (error ? error.localizedDescription.UTF8String : "unknown error"));
}
}  // namespace

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        try
        {
            std::setvbuf(stdout, nullptr, _IONBF, 0);
            require(argc == 2, "Usage: metal-culling-probe OUTPUT.ppm");
            const char *capturePath     = std::getenv("ANGLE_METAL_CAPTURE_PATH");
            const char *benchmarkOption = std::getenv("ANGLE_METAL_BENCHMARK");
            const bool benchmark        = benchmarkOption && std::strcmp(benchmarkOption, "1") == 0;
            if (capturePath)
            {
                const char *validation = std::getenv("MTL_SHADER_VALIDATION");
                require(!validation || std::strcmp(validation, "0") == 0,
                        "Run GPU capture separately from Shader Validation");
            }
            const EGLAttrib attributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                                            EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
            EGLDisplay display =
                eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, attributes);
            require(eglInitialize(display, nullptr, nullptr), "ANGLE Metal initialization failed");
            require(eglBindAPI(EGL_OPENGL_ES_API), "GLES API unavailable");
            const EGLint configAttributes[] = {EGL_SURFACE_TYPE,
                                               EGL_PBUFFER_BIT,
                                               EGL_RENDERABLE_TYPE,
                                               EGL_OPENGL_ES3_BIT_KHR,
                                               EGL_RED_SIZE,
                                               8,
                                               EGL_GREEN_SIZE,
                                               8,
                                               EGL_BLUE_SIZE,
                                               8,
                                               EGL_ALPHA_SIZE,
                                               8,
                                               EGL_NONE};
            EGLConfig config;
            EGLint configs = 0;
            require(eglChooseConfig(display, configAttributes, &config, 1, &configs) && configs,
                    "RGBA8 pbuffer configuration unavailable");
            const EGLint contextAttributes[] = {EGL_CONTEXT_MAJOR_VERSION_KHR, 3,
                                                EGL_CONTEXT_MINOR_VERSION_KHR, 1, EGL_NONE};
            EGLContext context =
                eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
            require(context != EGL_NO_CONTEXT,
                    "This probe requires an available GLES 3.1 context");
            const EGLint surfaceAttributes[] = {EGL_WIDTH, kWidth, EGL_HEIGHT, kHeight, EGL_NONE};
            EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
            require(surface != EGL_NO_SURFACE && eglMakeCurrent(display, surface, surface, context),
                    "Cannot activate the pbuffer");
            require(extension("GL_EXT_multi_draw_indirect") && extension("GL_EXT_base_instance"),
                    "Required indirect/base-instance integration extensions are unavailable");
            auto multiDraw = reinterpret_cast<PFNGLMULTIDRAWELEMENTSINDIRECTEXTPROC>(
                eglGetProcAddress("glMultiDrawElementsIndirectEXT"));
            auto referenceDraw = reinterpret_cast<PFNGLDRAWELEMENTSINSTANCEDBASEINSTANCEEXTPROC>(
                eglGetProcAddress("glDrawElementsInstancedBaseInstanceEXT"));
            require(multiDraw && referenceDraw, "Missing draw entry points");
            std::printf("GL_VERSION %s\nGL_RENDERER %s\n", glGetString(GL_VERSION),
                        glGetString(GL_RENDERER));
            constexpr char computeSource[]  = R"(#version 310 es
                layout(local_size_x=64) in;
                struct Object { vec4 sphere; vec4 color; };
                layout(std430,binding=0) readonly buffer Objects { Object data[]; } objects;
                layout(std430,binding=1) writeonly buffer Commands { uint words[]; } commands;
                layout(binding=0,offset=4) uniform atomic_uint visibleCount;
                uniform vec4 camera;
                void main() {
                    uint i=gl_GlobalInvocationID.x;
                    if(i>=96u) return;
                    vec4 sphere=objects.data[i].sphere;
                    bool visible=all(lessThanEqual(abs(sphere.xy-camera.xy), camera.zw+sphere.zz));
                    uint at=64u+8u*i;
                    commands.words[at]=6u; commands.words[at+1u]=visible ? 1u : 0u;
                    commands.words[at+2u]=0u; commands.words[at+3u]=0u; commands.words[at+4u]=i;
                    if(visible) atomicCounterIncrement(visibleCount);
                }
            )";
            constexpr char vertexSource[]   = R"(#version 310 es
                layout(location=0) in vec2 position;
                layout(location=1) in vec4 sphere;
                layout(location=2) in vec4 paint;
                uniform vec4 camera;
                out vec4 color;
                void main() {
                    gl_Position=vec4((sphere.xy+position*sphere.z-camera.xy)/camera.zw,0,1);
                    color=paint;
                }
            )";
            constexpr char fragmentSource[] = R"(#version 310 es
                precision highp float;
                in vec4 color; out vec4 outputColor;
                void main() { outputColor=color; }
            )";
            const GLuint compute            = program(nullptr, nullptr, computeSource);
            const GLuint render             = program(vertexSource, fragmentSource, nullptr);
            GLuint vao;
            glGenVertexArrays(1, &vao);
            glBindVertexArray(vao);
            std::array<Object, kObjects> objects;
            for (uint32_t i = 0; i < kObjects; ++i)
            {
                objects[i] = {{{-11.f / 12.f + float(i % 12) / 6.f, -.875f + float(i / 12) / 4.f,
                                .065f, 0.f}},
                              {{float(i % 12 + 1) / 12.f, float(i / 12 + 1) / 8.f, .65f, 1.f}}};
            }
            constexpr std::array<float, 8> vertices   = {-1, -1, 1, -1, -1, 1, 1, 1};
            constexpr std::array<uint16_t, 6> indices = {0, 1, 2, 2, 1, 3};
            std::array<GLuint, 5> buffers;
            glGenBuffers(buffers.size(), buffers.data());
            glBindBuffer(GL_ARRAY_BUFFER, buffers[0]);
            glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(), GL_STATIC_DRAW);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, nullptr);
            glEnableVertexAttribArray(0);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffers[1]);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices.data(), GL_STATIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, buffers[2]);
            glBufferData(GL_ARRAY_BUFFER, sizeof(objects), objects.data(), GL_STATIC_DRAW);
            for (GLuint location : {1u, 2u})
            {
                glVertexAttribPointer(
                    location, 4, GL_FLOAT, GL_FALSE, sizeof(Object),
                    reinterpret_cast<const void *>(uintptr_t((location - 1) * 16)));
                glEnableVertexAttribArray(location);
                glVertexAttribDivisor(location, 1);
            }
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[2]);
            std::vector<uint32_t> commandWords(64 + kObjects * 8 + 64, kGuard);
            glBindBuffer(GL_DRAW_INDIRECT_BUFFER, buffers[3]);
            glBufferData(GL_DRAW_INDIRECT_BUFFER, commandWords.size() * 4, commandWords.data(),
                         GL_DYNAMIC_DRAW);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[3]);
            std::array<uint32_t, 4> counters = {kGuard, 0, kGuard, kGuard};
            glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, buffers[4]);
            glBufferData(GL_ATOMIC_COUNTER_BUFFER, sizeof(counters), counters.data(),
                         GL_DYNAMIC_DRAW);
            glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, buffers[4]);
            glViewport(0, 0, kWidth, kHeight);
            glDisable(GL_DITHER);
            glClearColor(8.f / 255.f, 12.f / 255.f, 24.f / 255.f, 1.f);
            constexpr std::array<std::array<float, 4>, 3> cameras = {
                {{0, 0, 1, 1}, {.25f, .125f, .5f, .5f}, {-.5f, -.375f, .35f, .375f}}};
            std::vector<uint8_t> gallery(kWidth * 3 * kHeight * 3);
            for (size_t frame = 0; frame < cameras.size(); ++frame)
            {
                const auto &camera = cameras[frame];
                std::array<bool, kObjects> visible;
                uint32_t expectedVisible = 0;
                for (uint32_t i = 0; i < kObjects; ++i)
                {
                    visible[i] = std::abs(objects[i].sphere[0] - camera[0]) <=
                                     camera[2] + objects[i].sphere[2] &&
                                 std::abs(objects[i].sphere[1] - camera[1]) <=
                                     camera[3] + objects[i].sphere[2];
                    expectedVisible += visible[i];
                }
                // The host oracle is rendered before the actual GPU producer.
                glUseProgram(render);
                glUniform4fv(glGetUniformLocation(render, "camera"), 1, camera.data());
                glClear(GL_COLOR_BUFFER_BIT);
                for (uint32_t i = 0; i < kObjects; ++i)
                {
                    if (visible[i])
                    {
                        referenceDraw(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr, 1, i);
                    }
                }
                std::vector<uint8_t> expected(kWidth * kHeight * 4), actual(expected.size());
                glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE, expected.data());
                counters[1] = 0;
                glBufferSubData(GL_ATOMIC_COUNTER_BUFFER, 4, 4, &counters[1]);
                glUseProgram(compute);
                glUniform4fv(glGetUniformLocation(compute, "camera"), 1, camera.data());
                if (frame == 0 && capturePath)
                {
                    startCapture(display, capturePath);
                }
                glDispatchCompute(2, 1, 1);
                glMemoryBarrier(GL_COMMAND_BARRIER_BIT | GL_ATOMIC_COUNTER_BARRIER_BIT |
                                GL_BUFFER_UPDATE_BARRIER_BIT);
                glUseProgram(render);
                glClear(GL_COLOR_BUFFER_BIT);
                // No host argument/visibility read or geometry update between dispatch and draw.
                multiDraw(GL_TRIANGLES, GL_UNSIGNED_SHORT, reinterpret_cast<const void *>(256),
                          kObjects, 32);
                checkGL("compute-to-MDI frame");
                glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE, actual.data());
                if (frame == 0 && capturePath)
                {
                    [[MTLCaptureManager sharedCaptureManager] stopCapture];
                    std::printf("GPU_CAPTURE %s\n", capturePath);
                }
                require(actual == expected,
                        "Indirect image differs from the independent direct-draw oracle");
                if (frame == 0 && benchmark)
                {
                    require(extension("GL_EXT_disjoint_timer_query"),
                            "The benchmark requires GPU timer queries");
                    auto queryTime = reinterpret_cast<PFNGLGETQUERYOBJECTUI64VEXTPROC>(
                        eglGetProcAddress("glGetQueryObjectui64vEXT"));
                    require(queryTime, "GPU timer result function is unavailable");
                    GLuint timer;
                    glGenQueries(1, &timer);
                    const std::array<const char *, 3> methods = {"direct", "indirect_loop", "mdi"};
                    const std::array<int, 6> order            = {0, 1, 2, 2, 1, 0};
                    std::array<std::vector<uint64_t>, 3> cpuSamples, gpuSamples;
                    // All 96 objects are visible in this view. Interleave methods;
                    // discard the first cycle and compare pixels after every sample.
                    for (size_t iteration = 0; iteration < order.size() * 5; ++iteration)
                    {
                        const int method = order[iteration % order.size()];
                        glClear(GL_COLOR_BUFFER_BIT);
                        glBeginQuery(GL_TIME_ELAPSED_EXT, timer);
                        const auto begin = std::chrono::steady_clock::now();
                        if (method == 0)
                        {
                            for (uint32_t i = 0; i < kObjects; ++i)
                            {
                                referenceDraw(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr, 1, i);
                            }
                        }
                        else if (method == 1)
                        {
                            for (uint32_t i = 0; i < kObjects; ++i)
                            {
                                glDrawElementsIndirect(
                                    GL_TRIANGLES, GL_UNSIGNED_SHORT,
                                    reinterpret_cast<const void *>(uintptr_t(256 + i * 32)));
                            }
                        }
                        else
                        {
                            multiDraw(GL_TRIANGLES, GL_UNSIGNED_SHORT,
                                      reinterpret_cast<const void *>(256), kObjects, 32);
                        }
                        const uint64_t cpu = std::chrono::duration_cast<std::chrono::nanoseconds>(
                                                 std::chrono::steady_clock::now() - begin)
                                                 .count();
                        glEndQuery(GL_TIME_ELAPSED_EXT);
                        glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE,
                                     actual.data());
                        require(actual == expected, "Benchmark rendering differs from the oracle");
                        GLuint64 gpu = 0;
                        queryTime(timer, GL_QUERY_RESULT, &gpu);
                        GLboolean disjoint = GL_FALSE;
                        glGetBooleanv(GL_GPU_DISJOINT_EXT, &disjoint);
                        checkGL("draw benchmark");
                        require(!disjoint && gpu > 0, "GPU timing was disjoint or unavailable");
                        if (iteration >= order.size())
                        {
                            cpuSamples[method].push_back(cpu);
                            gpuSamples[method].push_back(gpu);
                            std::printf(
                                "BENCH_SAMPLE method=%s cpu_ns=%llu gpu_ns=%llu image_match=1\n",
                                methods[method], static_cast<unsigned long long>(cpu),
                                static_cast<unsigned long long>(gpu));
                        }
                    }
                    glDeleteQueries(1, &timer);
                    for (size_t method = 0; method < methods.size(); ++method)
                    {
                        auto median = [](std::vector<uint64_t> values) {
                            std::sort(values.begin(), values.end());
                            return (values[values.size() / 2 - 1] + values[values.size() / 2]) / 2;
                        };
                        std::printf("BENCH_MEDIAN method=%s samples=%zu cpu_ns=%llu gpu_ns=%llu "
                                    "draw_api_calls=%u objects=%u\n",
                                    methods[method], cpuSamples[method].size(),
                                    static_cast<unsigned long long>(median(cpuSamples[method])),
                                    static_cast<unsigned long long>(median(gpuSamples[method])),
                                    method == 2 ? 1u : kObjects, kObjects);
                    }
                }
                // Readbacks below are proof collection after rendering, outside the GPU render
                // path.
                glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[3]);
                const auto *commands = static_cast<const uint32_t *>(glMapBufferRange(
                    GL_SHADER_STORAGE_BUFFER, 0, commandWords.size() * 4, GL_MAP_READ_BIT));
                require(commands, "Command proof mapping failed");
                for (uint32_t i = 0; i < kObjects; ++i)
                {
                    commandWords[64 + i * 8]     = 6;
                    commandWords[64 + i * 8 + 1] = visible[i];
                    commandWords[64 + i * 8 + 2] = 0;
                    commandWords[64 + i * 8 + 3] = 0;
                    commandWords[64 + i * 8 + 4] = i;
                }
                require(std::memcmp(commands, commandWords.data(), commandWords.size() * 4) == 0,
                        "Command values or allocation guards differ");
                require(glUnmapBuffer(GL_SHADER_STORAGE_BUFFER), "Command proof unmap failed");
                const auto *count = static_cast<const uint32_t *>(glMapBufferRange(
                    GL_ATOMIC_COUNTER_BUFFER, 0, sizeof(counters), GL_MAP_READ_BIT));
                counters[1]       = expectedVisible;
                require(count && std::memcmp(count, counters.data(), sizeof(counters)) == 0,
                        "Atomic visibility count or guards differ");
                require(glUnmapBuffer(GL_ATOMIC_COUNTER_BUFFER), "Counter proof unmap failed");
                for (uint32_t y = 0; y < kHeight; ++y)
                {
                    for (uint32_t x = 0; x < kWidth; ++x)
                    {
                        for (uint32_t c = 0; c < 3; ++c)
                        {
                            gallery[((kHeight - 1 - y) * kWidth * 3 + frame * kWidth + x) * 3 + c] =
                                actual[(y * kWidth + x) * 4 + c];
                        }
                    }
                }
                std::printf(
                    "FRAME %zu visible=%u/%u image_match=1 command_guards=1 counter_guards=1\n",
                    frame, expectedVisible, kObjects);
            }
            for (size_t index : {0u, 1u, 2u})
            {
                const void *expected = index == 0   ? static_cast<const void *>(vertices.data())
                                       : index == 1 ? static_cast<const void *>(indices.data())
                                                    : static_cast<const void *>(objects.data());
                const size_t size    = index == 0   ? sizeof(vertices)
                                       : index == 1 ? sizeof(indices)
                                                    : sizeof(objects);
                glBindBuffer(GL_ARRAY_BUFFER, buffers[index]);
                const void *actual = glMapBufferRange(GL_ARRAY_BUFFER, 0, size, GL_MAP_READ_BIT);
                require(actual && std::memcmp(actual, expected, size) == 0,
                        "Stable geometry was modified");
                require(glUnmapBuffer(GL_ARRAY_BUFFER), "Geometry proof unmap failed");
            }
            std::ofstream output(argv[1], std::ios::binary);
            output << "P6\n" << kWidth * 3 << " " << kHeight << "\n255\n";
            output.write(reinterpret_cast<const char *>(gallery.data()), gallery.size());
            require(output.good(), "Cannot write the rendered gallery");
            checkGL("proof completion");
            glDeleteBuffers(buffers.size(), buffers.data());
            glDeleteVertexArrays(1, &vao);
            glDeleteProgram(compute);
            glDeleteProgram(render);
            require(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) &&
                        eglDestroySurface(display, surface) &&
                        eglDestroyContext(display, context) && eglTerminate(display),
                    "EGL cleanup failed");
            std::puts("METAL_GPU_CULLING_PASS stable_geometry=1 host_command_reads_before_draw=0");
        }
        catch (const std::exception &error)
        {
            if ([MTLCaptureManager sharedCaptureManager].isCapturing)
            {
                [[MTLCaptureManager sharedCaptureManager] stopCapture];
            }
            std::fprintf(stderr, "METAL_GPU_CULLING_FAIL %s\n", error.what());
            return 1;
        }
    }
    return 0;
}
