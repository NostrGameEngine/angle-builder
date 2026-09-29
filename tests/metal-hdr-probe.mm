#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>

static void require(bool ok, const char *message)
{
    if (!ok) throw std::runtime_error(message);
}

int main()
{
    @autoreleasepool {
        try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 240)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            window.title = @"ANGLE native HDR / SDR regression";
            window.contentView.wantsLayer = YES;
            CAMetalLayer *layer = [CAMetalLayer layer];
            layer.frame = window.contentView.bounds;
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            layer.colorspace = srgb;
            window.contentView.layer = layer;
            [window center];
            [window makeKeyAndOrderFront:nil];
            [NSApp finishLaunching];
            [NSApp activateIgnoringOtherApps:YES];

            auto getDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
                eglGetProcAddress("eglGetPlatformDisplayEXT"));
            require(getDisplay != nullptr, "Missing ANGLE platform display entry point");
            const EGLint displayAttributes[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
            EGLDisplay display = getDisplay(EGL_PLATFORM_ANGLE_ANGLE, nullptr, displayAttributes);
            require(eglInitialize(display, nullptr, nullptr), "Cannot initialize ANGLE Metal");
            require(eglBindAPI(EGL_OPENGL_ES_API), "Cannot select GLES API");
            std::printf("ANGLE_VERSION %s\n", eglQueryString(display, EGL_VERSION));

            EGLConfig sdrConfig = nullptr;
            for (int phase = 0; phase < 5; ++phase) {
                const bool hdr = phase == 1;
                const bool srgbSurface = phase == 4;
                if (phase == 3) layer.colorspace = nullptr; // Fresh, untagged SDR layer.
                const EGLint configAttributes[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                    EGL_RED_SIZE, hdr ? 16 : 8, EGL_GREEN_SIZE, hdr ? 16 : 8,
                    EGL_BLUE_SIZE, hdr ? 16 : 8, EGL_ALPHA_SIZE, hdr ? 16 : 8,
                    hdr ? EGL_COLOR_COMPONENT_TYPE_EXT : EGL_NONE, EGL_COLOR_COMPONENT_TYPE_FLOAT_EXT, EGL_NONE};
                EGLConfig config = nullptr;
                EGLint count = 0;
                require(eglChooseConfig(display, configAttributes, &config, 1, &count) && count > 0,
                        "Required EGL window configuration is missing");
                if (!hdr) sdrConfig = config;
                const EGLint surfaceAttributes[] = {hdr || srgbSurface ? EGL_GL_COLORSPACE_KHR : EGL_NONE,
                    hdr ? EGL_GL_COLORSPACE_SCRGB_LINEAR_EXT : EGL_GL_COLORSPACE_SRGB_KHR, EGL_NONE};
                EGLSurface surface = eglCreateWindowSurface(display, config,
                    (__bridge EGLNativeWindowType)layer, surfaceAttributes);
                require(surface != EGL_NO_SURFACE, "Cannot create requested window surface");
                const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
                EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
                require(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context),
                        "Cannot activate EGL context");
                require(layer.pixelFormat == (hdr ? MTLPixelFormatRGBA16Float :
                    srgbSurface ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm),
                        "EGL config and actual Metal drawable disagree");
                require(layer.wantsExtendedDynamicRangeContent == hdr, "Stale or missing Metal EDR flag");
                CGColorSpaceRef expectedSpace = hdr ? CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB) : srgb;
                require(layer.colorspace && CFEqual(layer.colorspace, expectedSpace),
                        "Stale or incorrect Metal color space");
                if (hdr) CGColorSpaceRelease(expectedSpace);

                // Final display values: HDR stays linear above 1; SDR is encoded exactly once.
                const GLfloat value = hdr ? 2.f : 1.055f * std::pow(.18f, 1.f / 2.4f) - .055f;
                const GLfloat input = srgbSurface ? .18f : value;
                const GLfloat clear[] = {input, input, input, 1.f};
                glClearBufferfv(GL_COLOR, 0, clear);
                float actual = 0;
                if (hdr) {
                    GLint type = 0;
                    glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_TYPE, &type);
                    if (type == GL_HALF_FLOAT) {
                        _Float16 color[4] = {};
                        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_HALF_FLOAT, color);
                        actual = color[0];
                    } else {
                        GLfloat color[4] = {};
                        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_FLOAT, color);
                        actual = color[0];
                    }
                } else {
                    GLubyte color[4] = {};
                    glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, color);
                    actual = color[0] / 255.f;
                }
                require(glGetError() == GL_NO_ERROR && std::abs(actual - value) < .005f,
                        "Native drawable clips HDR or changes SDR colors");
                for (int frame = 0; frame < (hdr ? 120 : 2); ++frame) {
                    glClearBufferfv(GL_COLOR, 0, clear);
                    require(eglSwapBuffers(display, surface), "Cannot present native drawable");
                    NSEvent *event;
                    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                                                        inMode:NSDefaultRunLoopMode dequeue:YES])) {
                        [NSApp sendEvent:event];
                    }
                    [NSApp updateWindows];
                    [CATransaction flush];
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.025]];
                }
                NSScreen *screen = window.screen;
                std::printf("METAL_OUTPUT_PASS phase=%d hdr=%d pixelFormat=%lu readback=%.6f headroom=%.3f potential=%.3f\n",
                    phase, hdr, (unsigned long)layer.pixelFormat, actual,
                    screen.maximumExtendedDynamicRangeColorComponentValue,
                    screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
                eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
                eglDestroyContext(display, context);
                eglDestroySurface(display, surface);

                if (hdr) {
                    EGLSurface invalid = eglCreateWindowSurface(display, sdrConfig,
                        (__bridge EGLNativeWindowType)layer, surfaceAttributes);
                    require(invalid == EGL_NO_SURFACE && eglGetError() == EGL_BAD_MATCH,
                            "8-bit surface incorrectly accepted linear scRGB HDR");
                    std::puts("HDR_REFUSAL_PASS 8-bit scRGB rejected; reusing layer for SDR next");
                }
            }
            eglTerminate(display);
            CGColorSpaceRelease(srgb);
            [window orderOut:nil];
            std::puts("METAL_HDR_SDR_PASS");
            return 0;
        } catch (const std::exception &error) {
            std::fprintf(stderr, "METAL_HDR_SDR_FAIL %s (EGL=0x%x GL=0x%x)\n", error.what(), eglGetError(), glGetError());
            return 1;
        }
    }
}
