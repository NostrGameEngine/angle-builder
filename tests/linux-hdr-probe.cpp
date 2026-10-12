// SPDX-License-Identifier: BSD-3-Clause
// Real ANGLE/EGL + Wayland window probe. A successful software presentation is
// NOT proof of light output from a physical HDR monitor.
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include "xdg-shell-client-protocol.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

static void Require(bool ok, const std::string &message)
{
    if (!ok)
    {
        char suffix[64];
        std::snprintf(suffix, sizeof(suffix), " (EGL=0x%x)", eglGetError());
        throw std::runtime_error(message + suffix);
    }
}
// Read eglGetError only after the operation has failed, inside Require().
static const char *EglError(const char *operation) { return operation; }
static bool HasExtension(const char *extensions, const char *name)
{
    if (!extensions) return false;
    std::string list = std::string(" ") + extensions + " ";
    return list.find(std::string(" ") + name + " ") != std::string::npos;
}

struct WaylandConnection
{
    wl_display *display = nullptr;
    wl_registry *registry = nullptr;
    wl_compositor *compositor = nullptr;
    xdg_wm_base *shell = nullptr;
    bool colorManagement = false;
    static void Ping(void *, xdg_wm_base *shell, uint32_t serial) { xdg_wm_base_pong(shell, serial); }
    static void Global(void *data, wl_registry *registry, uint32_t name, const char *iface, uint32_t version)
    {
        auto &self = *static_cast<WaylandConnection *>(data);
        if (std::strcmp(iface, "wl_compositor") == 0)
            self.compositor = static_cast<wl_compositor *>(wl_registry_bind(registry, name, &wl_compositor_interface, std::min(version, 4u)));
        else if (std::strcmp(iface, "xdg_wm_base") == 0)
        {
            self.shell = static_cast<xdg_wm_base *>(wl_registry_bind(registry, name, &xdg_wm_base_interface, 1));
            static const xdg_wm_base_listener listener = {Ping};
            xdg_wm_base_add_listener(self.shell, &listener, &self);
        }
        else if (std::strcmp(iface, "wp_color_manager_v1") == 0)
        {
            self.colorManagement = true;
            std::printf("WAYLAND_COLOR_MANAGER version=%u\n", version);
        }
    }
    static void Removed(void *, wl_registry *, uint32_t) {}
    void Initialize()
    {
        display = wl_display_connect(nullptr);
        Require(display != nullptr, "Cannot connect to Wayland; set WAYLAND_DISPLAY and XDG_RUNTIME_DIR");
        registry = wl_display_get_registry(display);
        Require(registry != nullptr, "Cannot get Wayland registry");
        static const wl_registry_listener listener = {Global, Removed};
        Require(wl_registry_add_listener(registry, &listener, this) == 0, "Registry listener failed");
        Require(wl_display_roundtrip(display) >= 0 && compositor && shell, "Wayland compositor/xdg-shell unavailable");
    }
    ~WaylandConnection()
    {
        if (shell) xdg_wm_base_destroy(shell);
        if (compositor) wl_compositor_destroy(compositor);
        if (registry) wl_registry_destroy(registry);
        if (display) wl_display_disconnect(display);
    }
};
struct NativeWindow
{
    wl_surface *surface = nullptr;
    xdg_surface *xdgSurface = nullptr;
    xdg_toplevel *toplevel = nullptr;
    wl_egl_window *eglWindow = nullptr;
    bool configured = false;
    bool closed = false;
    static void Configure(void *data, xdg_surface *surface, uint32_t serial)
    {
        xdg_surface_ack_configure(surface, serial);
        static_cast<NativeWindow *>(data)->configured = true;
    }
    static void Resize(void *, xdg_toplevel *, int32_t, int32_t, wl_array *) {}
    static void Close(void *data, xdg_toplevel *) { static_cast<NativeWindow *>(data)->closed = true; }
    void Initialize(WaylandConnection &wl)
    {
        surface = wl_compositor_create_surface(wl.compositor);
        Require(surface != nullptr, "Cannot create wl_surface");
        xdgSurface = xdg_wm_base_get_xdg_surface(wl.shell, surface);
        Require(xdgSurface != nullptr, "Cannot create xdg_surface");
        static const xdg_surface_listener surfaceListener = {Configure};
        xdg_surface_add_listener(xdgSurface, &surfaceListener, this);
        toplevel = xdg_surface_get_toplevel(xdgSurface);
        Require(toplevel != nullptr, "Cannot create xdg_toplevel");
        static const xdg_toplevel_listener toplevelListener = {Resize, Close, nullptr, nullptr};
        xdg_toplevel_add_listener(toplevel, &toplevelListener, this);
        xdg_toplevel_set_title(toplevel, "ANGLE Linux HDR / SDR validation");
        xdg_toplevel_set_app_id(toplevel, "org.ngengine.angle.hdr-probe");
        wl_surface_commit(surface);
        while (!configured && !closed)
            Require(wl_display_roundtrip(wl.display) >= 0, "Wayland configure failed");
        Require(!closed, "Probe window closed before test");
        eglWindow = wl_egl_window_create(surface, 320, 180);
        Require(eglWindow != nullptr, "Cannot create wl_egl_window");
    }
    ~NativeWindow()
    {
        if (eglWindow) wl_egl_window_destroy(eglWindow);
        if (toplevel) xdg_toplevel_destroy(toplevel);
        if (xdgSurface) xdg_surface_destroy(xdgSurface);
        if (surface) wl_surface_destroy(surface);
    }
};
struct EglDisplay
{
    EGLDisplay display = EGL_NO_DISPLAY;
    ~EglDisplay() { if (display != EGL_NO_DISPLAY) eglTerminate(display); }
};
struct EglDrawable
{
    EGLDisplay display;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    explicit EglDrawable(EGLDisplay value) : display(value) {}
    ~EglDrawable()
    {
        eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    }
};
static EGLint Attribute(EGLDisplay display, EGLConfig config, EGLint attribute)
{
    EGLint value = -1;
    Require(eglGetConfigAttrib(display, config, attribute, &value), EglError("eglGetConfigAttrib"));
    return value;
}
static EGLConfig Choose(EGLDisplay display, bool floating, int rgbBits, int surfaceType)
{
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, surfaceType, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE, rgbBits, EGL_GREEN_SIZE, rgbBits, EGL_BLUE_SIZE, rgbBits,
        EGL_ALPHA_SIZE, 0, EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0,
        EGL_SAMPLE_BUFFERS, 0, EGL_SAMPLES, 0,
        EGL_COLOR_COMPONENT_TYPE_EXT, floating ? EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT : EGL_COLOR_COMPONENT_TYPE_FIXED_EXT,
        EGL_NONE};
    EGLint count = 0;
    Require(eglChooseConfig(display, attributes, nullptr, 0, &count), EglError("eglChooseConfig count"));
    if (count == 0) return nullptr;
    std::vector<EGLConfig> configs(count);
    Require(eglChooseConfig(display, attributes, configs.data(), count, &count), EglError("eglChooseConfig"));
    for (int i = 0; i < count; ++i)
        if (Attribute(display, configs[i], EGL_SAMPLES) == 0)
            return configs[i];
    return nullptr;
}
static GLuint Compile(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint status = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (!status)
    {
        char error[2048] = {};
        glGetShaderInfoLog(shader, sizeof(error), nullptr, error);
        glDeleteShader(shader);
        throw std::runtime_error(std::string("Shader compile failed: ") + error);
    }
    return shader;
}
static GLuint Program()
{
    const char *vertex = R"(#version 300 es
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})";
    const char *fragment = R"(#version 300 es
precision highp float;
uniform float signal;
uniform int pq;
out vec4 color;
void main() {
    float value = signal;
    if (pq != 0) {
        float p = pow(max(value / 10000.0, 0.0), 2610.0 / 16384.0);
        value = pow((3424.0 / 4096.0 + (2413.0 / 128.0) * p) /
                    (1.0 + (2392.0 / 128.0) * p), 2523.0 / 32.0);
    }
    color = vec4(value, value, value, 1.0);
})";
    GLuint vs = Compile(GL_VERTEX_SHADER, vertex);
    GLuint fs = Compile(GL_FRAGMENT_SHADER, fragment);
    GLuint program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs); glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint status = 0; glGetProgramiv(program, GL_LINK_STATUS, &status);
    Require(status != 0, "Program link failed");
    return program;
}
static double PqReference(double nits)
{
    const double p = std::pow(nits / 10000.0, 2610.0 / 16384.0);
    return std::pow((3424.0 / 4096.0 + (2413.0 / 128.0) * p) /
                   (1.0 + (2392.0 / 128.0) * p), 2523.0 / 32.0);
}
static float ReadPixel()
{
    GLint type = 0, format = 0;
    glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE, &type);
    glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT, &format);
    float result = 0;
    if (type == GL_FLOAT)
    {
        GLfloat color[4] = {};
        glReadPixels(8, 8, 1, 1, format, type, color); result = color[0];
    }
    else if (type == GL_HALF_FLOAT)
    {
        GLushort color[4] = {};
        glReadPixels(8, 8, 1, 1, format, type, color);
        unsigned exponent = (color[0] >> 10) & 31;
        unsigned mantissa = color[0] & 1023;
        result = exponent ? std::ldexp(float(1024 + mantissa), int(exponent) - 25)
                          : std::ldexp(float(mantissa), -24);
        if (color[0] & 0x8000) result = -result;
    }
    else if (type == GL_UNSIGNED_INT_2_10_10_10_REV)
    {
        GLuint pixel = 0;
        glReadPixels(8, 8, 1, 1, format, type, &pixel); result = (pixel & 1023) / 1023.f;
    }
    else
    {
        GLubyte color[4] = {};
        glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, color); result = color[0] / 255.f;
    }
    Require(glGetError() == GL_NO_ERROR, "Default-framebuffer readback failed");
    return result;
}
static void RunPhase(EGLDisplay display, EGLConfig config, NativeWindow &window,
                     WaylandConnection &wl, const char *name, EGLint colorspace, bool floating, bool pq)
{
    EglDrawable drawable(display);
    EGLint surfaceAttributes[] = {EGL_GL_COLORSPACE_KHR, colorspace, EGL_NONE};
    drawable.surface = eglCreateWindowSurface(display, config,
        reinterpret_cast<EGLNativeWindowType>(window.eglWindow), surfaceAttributes);
    Require(drawable.surface != EGL_NO_SURFACE, EglError("eglCreateWindowSurface"));
    EGLint actual = 0;
    Require(eglQuerySurface(display, drawable.surface, EGL_GL_COLORSPACE_KHR, &actual) && actual == colorspace,
            "EGL surface colorspace differs from requested colorspace");
    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    drawable.context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    Require(drawable.context != EGL_NO_CONTEXT, EglError("eglCreateContext"));
    Require(eglMakeCurrent(display, drawable.surface, drawable.surface, drawable.context), EglError("eglMakeCurrent"));
    const char *renderer = reinterpret_cast<const char *>(glGetString(GL_RENDERER));
    Require(renderer && std::strstr(renderer, "ANGLE"), "Probe did not load ANGLE GLES renderer");
    std::printf("PHASE_BEGIN %s renderer=%s colorspace=0x%x rgba=%d/%d/%d/%d component=0x%x\n",
        name, renderer, actual, Attribute(display, config, EGL_RED_SIZE), Attribute(display, config, EGL_GREEN_SIZE),
        Attribute(display, config, EGL_BLUE_SIZE), Attribute(display, config, EGL_ALPHA_SIZE),
        Attribute(display, config, EGL_COLOR_COMPONENT_TYPE_EXT));
    const float signal = pq ? 1000.f : floating ? 2.f : colorspace == EGL_GL_COLORSPACE_SRGB_KHR ? .18f : .5f;
    const double expected = pq ? PqReference(signal) :
        colorspace == EGL_GL_COLORSPACE_SRGB_KHR ? 1.055 * std::pow(double(signal), 1.0 / 2.4) - .055 : signal;
    GLuint program = Program();
    glUseProgram(program); glUniform1f(glGetUniformLocation(program, "signal"), signal);
    glUniform1i(glGetUniformLocation(program, "pq"), pq ? 1 : 0);
    glViewport(0, 0, 320, 180);
    glDisable(GL_DITHER);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    Require(glGetError() == GL_NO_ERROR, "Probe draw failed");
    float observed = ReadPixel();
    Require(std::isfinite(observed) && std::abs(observed - expected) < .005,
            "Native drawable clips HDR values or applies incorrect transfer function");
    if (floating) Require(observed > 1.f, "Floating native drawable clipped extended-range content");
    for (int frame = 0; frame < 4; ++frame)
    {
        glDrawArrays(GL_TRIANGLES, 0, 3);
        Require(eglSwapBuffers(display, drawable.surface), EglError("eglSwapBuffers"));
        Require(wl_display_roundtrip(wl.display) >= 0, "Compositor rejected presentation");
        Require(!window.closed, "Window closed during validation");
    }
    glFinish(); glDeleteProgram(program);
    Require(glGetError() == GL_NO_ERROR, "GL error after presentation");
    std::printf("PHASE_PASS %s readback=%.7f expected=%.7f swaps=4 scope=software-presentation\n", name, observed, expected);
}
int main(int argc, char **argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    bool requireHdr = false, requireScrgb = false, requireHdr10 = false;
    for (int i = 1; i < argc; ++i)
    {
        if (!std::strcmp(argv[i], "--require-hdr")) requireHdr = true;
        else if (!std::strcmp(argv[i], "--require-scrgb")) requireScrgb = true;
        else if (!std::strcmp(argv[i], "--require-hdr10")) requireHdr10 = true;
        else { std::fprintf(stderr, "Unknown argument: %s\n", argv[i]); return 2; }
    }
    try
    {
        WaylandConnection wl; wl.Initialize();
        EglDisplay owner;
        auto getDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
        Require(getDisplay != nullptr, "Missing platform EGL entry point");
        owner.display = getDisplay(EGL_PLATFORM_WAYLAND_EXT, wl.display, nullptr);
        Require(owner.display != EGL_NO_DISPLAY && eglInitialize(owner.display, nullptr, nullptr), EglError("eglInitialize Wayland"));
        Require(eglBindAPI(EGL_OPENGL_ES_API), EglError("eglBindAPI"));
        EGLDisplay display = owner.display;
        const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
        std::printf("EGL_VENDOR %s\nEGL_VERSION %s\nEGL_EXTENSIONS %s\n", eglQueryString(display, EGL_VENDOR),
                    eglQueryString(display, EGL_VERSION), extensions ? extensions : "");
        Require(HasExtension(extensions, "EGL_KHR_gl_colorspace"), "No EGL colorspace support");
        EGLint configCount = 0;
        Require(eglGetConfigs(display, nullptr, 0, &configCount), EglError("eglGetConfigs"));
        std::vector<EGLConfig> configs(configCount);
        Require(eglGetConfigs(display, configs.data(), configCount, &configCount), EglError("eglGetConfigs list"));
        int floatWindows = 0, tenBitWindows = 0;
        for (int i = 0; i < configCount; ++i)
        {
            EGLConfig c = configs[i];
            int type = Attribute(display, c, EGL_COLOR_COMPONENT_TYPE_EXT);
            int red = Attribute(display, c, EGL_RED_SIZE), surface = Attribute(display, c, EGL_SURFACE_TYPE);
            if (Attribute(display, c, EGL_SAMPLES) == 0)
                std::printf("CONFIG id=%d rgba=%d/%d/%d/%d type=0x%x surface=0x%x depth=%d stencil=%d\n",
                    Attribute(display,c,EGL_CONFIG_ID), red, Attribute(display,c,EGL_GREEN_SIZE), Attribute(display,c,EGL_BLUE_SIZE),
                    Attribute(display,c,EGL_ALPHA_SIZE), type, surface, Attribute(display,c,EGL_DEPTH_SIZE), Attribute(display,c,EGL_STENCIL_SIZE));
            if (surface & EGL_WINDOW_BIT)
            {
                if (type == EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT && red >= 16) ++floatWindows;
                if (type == EGL_COLOR_COMPONENT_TYPE_FIXED_EXT && red >= 10) ++tenBitWindows;
            }
        }
        std::printf("CONFIG_SUMMARY total=%d fp16_window=%d rgb10_window=%d\n", configCount, floatWindows, tenBitWindows);
        NativeWindow window; window.Initialize(wl);
        EGLConfig sdr = Choose(display, false, 8, EGL_WINDOW_BIT);
        Require(sdr != nullptr, "No SDR EGL window config");
        RunPhase(display, sdr, window, wl, "SDR_before", EGL_GL_COLORSPACE_LINEAR_KHR, false, false);
        int hdrPasses = 0, hdrSkipped = 0;
        bool scrgbPassed = false, hdr10Passed = false;
        for (int index = 0; index < 2; ++index)
        {
            bool floating = index == 0;
            const char *name = floating ? "scRGB_FP16" : "HDR10_PQ_RGB10A2";
            const char *extension = floating ? "EGL_EXT_gl_colorspace_scrgb_linear" : "EGL_EXT_gl_colorspace_bt2020_pq";
            EGLConfig config = Choose(display, floating, floating ? 16 : 10, EGL_WINDOW_BIT);
            if (!HasExtension(extensions, extension) || !config)
            {
                ++hdrSkipped;
                std::printf("HDR_SKIP %s extension=%d window_config=%d (not counted as HDR PASS)\n",
                            name, HasExtension(extensions, extension), config != nullptr);
                continue;
            }
            RunPhase(display, config, window, wl, name,
                floating ? EGL_GL_COLORSPACE_SCRGB_LINEAR_EXT : EGL_GL_COLORSPACE_BT2020_PQ_EXT,
                floating, !floating);
            ++hdrPasses;
            if (floating) scrgbPassed = true;
            else hdr10Passed = true;
            RunPhase(display, sdr, window, wl, "SDR_after_HDR_same_native_window", EGL_GL_COLORSPACE_LINEAR_KHR, false, false);
        }
        const EGLint invalidAttributes[] = {EGL_GL_COLORSPACE_KHR, 0x7ffffffe, EGL_NONE};
        EGLSurface invalid = eglCreateWindowSurface(display, sdr,
            reinterpret_cast<EGLNativeWindowType>(window.eglWindow), invalidAttributes);
        if (invalid != EGL_NO_SURFACE) eglDestroySurface(display, invalid);
        Require(invalid == EGL_NO_SURFACE, "Invalid colorspace incorrectly accepted");
        std::printf("INVALID_COLORSPACE_REJECTION_PASS egl_error=0x%x\n", eglGetError());
        RunPhase(display, sdr, window, wl, "SDR_after_rejection", EGL_GL_COLORSPACE_LINEAR_KHR, false, false);
        RunPhase(display, sdr, window, wl, "SDR_sRGB_encoding", EGL_GL_COLORSPACE_SRGB_KHR, false, false);
        std::printf("LINUX_HDR_SUMMARY hdr_pass=%d hdr_skip=%d sdr=PASS physical_hdr=NOT_TESTED\n", hdrPasses, hdrSkipped);
        if ((requireHdr && hdrPasses == 0) || (requireScrgb && !scrgbPassed) ||
            (requireHdr10 && !hdr10Passed))
        {
            std::puts("REQUIRED_HDR_UNAVAILABLE: returning 77, not success");
            return 77;
        }
        return 0;
    }
    catch (const std::exception &error)
    {
        std::fprintf(stderr, "LINUX_HDR_FAIL %s\n", error.what());
        return 1;
    }
}
