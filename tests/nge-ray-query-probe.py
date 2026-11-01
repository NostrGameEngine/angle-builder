#!/usr/bin/env python3
"""Exercise GL_NGE_ray_query through explicitly selected angle-builder libraries.

Exit 0: requested checks passed. Exit 77: extension/stage unavailable (SKIP).
Exit 1: setup, shader, GL, or result failure. No system EGL/GLES fallback is used.
This intentionally small probe complements ANGLE's fuller internal test suite.
"""

import argparse
import ctypes as C
import os
from pathlib import Path
import re
import struct
import sys


class Failure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


U = C.c_uint
I = C.c_int
F = C.c_float
P = C.c_void_p
S = C.c_ssize_t
UP = C.POINTER(U)
IP = C.POINTER(I)
FP = C.POINTER(F)
NONE = 0x3038
EXTENSION = "GL_NGE_ray_query"

# GLES extension API constants are private allocations in the delivered ANGLE patch.
MAX_BINDINGS = 0x6000
FAST_TRACE = 1

QUERY = """
precision highp float;
precision highp int;
layout(binding = 0) uniform accelerationStructureEXT scene;
uvec4 trace(vec3 origin) {
    const bool expectedFront = false;
    rayQueryEXT q;
    rayQueryInitializeEXT(q, scene, gl_RayFlagsNoneEXT, 255u,
                         origin, 0.0, vec3(0, 0, 1), 100.0);
    bool candidateValid = true;
    while (rayQueryProceedEXT(q)) {
        candidateValid = candidateValid &&
            rayQueryGetIntersectionTypeEXT(q, false) == gl_RayQueryCandidateIntersectionTriangleEXT;
        candidateValid = candidateValid && rayQueryGetIntersectionPrimitiveIndexEXT(q, false) == 0;
        candidateValid = candidateValid && rayQueryGetIntersectionInstanceCustomIndexEXT(q, false) == 42;
        candidateValid = candidateValid && rayQueryGetIntersectionFrontFaceEXT(q, false) == expectedFront;
        rayQueryConfirmIntersectionEXT(q);
    }
    uint kind = rayQueryGetIntersectionTypeEXT(q, true);
    if (kind == gl_RayQueryCommittedIntersectionNoneEXT) return uvec4(0u);
    bool valid = candidateValid && kind == gl_RayQueryCommittedIntersectionTriangleEXT;
    valid = valid && rayQueryGetIntersectionFrontFaceEXT(q, true) == expectedFront;
    valid = valid && rayQueryGetRayFlagsEXT(q) == gl_RayFlagsNoneEXT;
    valid = valid && rayQueryGetRayTMinEXT(q) == 0.0;
    valid = valid && all(equal(rayQueryGetWorldRayOriginEXT(q), origin));
    valid = valid && all(equal(rayQueryGetWorldRayDirectionEXT(q), vec3(0, 0, 1)));
    mat4x3 objectToWorld = rayQueryGetIntersectionObjectToWorldEXT(q, true);
    mat4x3 worldToObject = rayQueryGetIntersectionWorldToObjectEXT(q, true);
    vec3 objectOrigin = rayQueryGetIntersectionObjectRayOriginEXT(q, true);
    vec3 objectDirection = rayQueryGetIntersectionObjectRayDirectionEXT(q, true);
    valid = valid && all(lessThan(abs(objectToWorld * vec4(objectOrigin, 1) - origin), vec3(0.001)));
    valid = valid && all(lessThan(abs(worldToObject * vec4(origin, 1) - objectOrigin), vec3(0.001)));
    valid = valid && all(lessThan(abs(objectToWorld * vec4(objectDirection, 0) - vec3(0,0,1)), vec3(0.001)));
    valid = valid && rayQueryGetIntersectionInstanceIdEXT(q, true) == 0;
    valid = valid && rayQueryGetIntersectionInstanceShaderBindingTableRecordOffsetEXT(q, true) == 0u;
    valid = valid && rayQueryGetIntersectionGeometryIndexEXT(q, true) == 0;
    valid = valid && all(lessThan(abs(rayQueryGetIntersectionBarycentricsEXT(q, true) -
                                    vec2(0.25, 0.5)), vec2(0.001)));
    return uvec4(valid ? 1u : 0xdeadbeefu,
                 floatBitsToUint(rayQueryGetIntersectionTEXT(q, true)),
                 rayQueryGetIntersectionPrimitiveIndexEXT(q, true),
                 rayQueryGetIntersectionInstanceCustomIndexEXT(q, true));
}
"""
VERTEX = """#version 300 es
void main() {
    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0, 1);
}
"""
FRAGMENT = "#version 300 es\n#extension GL_NGE_ray_query : require\n" + QUERY + """
layout(location = 0) out uvec4 color;
void main() { color = trace(vec3(gl_FragCoord.x < 1.0 ? 0.0 : 4.0, 0, 0)); }
"""
COMPUTE = "#version 310 es\n#extension GL_NGE_ray_query : require\n" + QUERY + """
layout(local_size_x = 2) in;
layout(std430, binding = 0) buffer Results { uvec4 result[2]; };
void main() { result[gl_LocalInvocationID.x] = trace(vec3(float(gl_LocalInvocationID.x) * 4.0, 0, 0)); }
"""

VERTEX_QUERY = "#version 300 es\n#extension GL_NGE_ray_query : require\n" + QUERY + """
flat out uvec4 hit;
void main() {
    gl_Position = vec4(gl_VertexID == 0 ? -0.5 : 0.5, 0, 0, 1);
    gl_PointSize = 1.0;
    hit = trace(vec3(float(gl_VertexID) * 4.0, 0, 0));
}
"""
VERTEX_RESULT = """#version 300 es
precision highp int;
flat in uvec4 hit;
layout(location=0) out uvec4 color;
void main() { color = hit; }
"""


class Libraries:
    def __init__(self, native_dir):
        self.directory = Path(native_dir).resolve(strict=True)
        if sys.platform == "win32":
            self.search_path = os.add_dll_directory(str(self.directory))
            loader, egl_name, gl_name = C.WinDLL, "libEGL.dll", "libGLESv2.dll"
        else:
            loader = C.CDLL
            extension = "dylib" if sys.platform == "darwin" else "so"
            egl_name, gl_name = "libEGL." + extension, "libGLESv2." + extension
        if sys.platform == "darwin":
            # Match the HDR probe: ANGLE install names may be relative to this directory.
            os.chdir(self.directory)
        self.gl_path = (self.directory / gl_name).resolve(strict=True)
        self.egl_path = (self.directory / egl_name).resolve(strict=True)
        # Load GLES first so libEGL's corresponding dependency resolves to this build.
        self.gl = loader(str(self.gl_path), mode=C.RTLD_GLOBAL)
        self.egl = loader(str(self.egl_path), mode=C.RTLD_GLOBAL)
        self.check_module(self.gl.glGetString, self.gl_path)
        self.check_module(self.egl.eglInitialize, self.egl_path)
        print("ANGLE_GLES_LIBRARY", self.gl_path)
        print("ANGLE_EGL_LIBRARY", self.egl_path)

    @staticmethod
    def check_module(function, expected):
        address = C.cast(function, P)
        if sys.platform == "win32":
            kernel = C.WinDLL("kernel32", use_last_error=True)
            module = P()
            get_module = kernel.GetModuleHandleExW
            get_module.argtypes, get_module.restype = [U, P, C.POINTER(P)], I
            require(get_module(6, address, C.byref(module)), "Cannot identify loaded library")
            name = C.create_unicode_buffer(32768)
            get_name = kernel.GetModuleFileNameW
            get_name.argtypes, get_name.restype = [P, C.c_wchar_p, U], U
            require(get_name(module, name, len(name)), "Cannot identify library path")
            actual = Path(name.value)
        else:
            class DlInfo(C.Structure):
                _fields_ = [("filename", C.c_char_p), ("base", P), ("symbol", C.c_char_p), ("address", P)]
            native = C.CDLL(None)
            dladdr = native.dladdr
            dladdr.argtypes, dladdr.restype = [P, C.POINTER(DlInfo)], I
            info = DlInfo()
            require(dladdr(address, C.byref(info)), "Cannot identify loaded library")
            actual = Path(os.fsdecode(info.filename))
        require(actual.resolve() == expected, f"Wrong library loaded: {actual}; expected {expected}")

    def function(self, name, result, args, egl=False):
        function = getattr(self.egl if egl else self.gl, name)
        function.restype, function.argtypes = result, args
        return function


class Probe:
    def __init__(self, libraries, options):
        self.lib, self.options = libraries, options
        self.display = self.surface = self.context = None
        self.gl = {}
        self.programs, self.buffers, self.structures = [], [], []
        self.texture = self.framebuffer = 0
        self.minor = 0
        for name, result, args in [
            ("eglGetProcAddress", P, [C.c_char_p]), ("eglInitialize", U, [P, IP, IP]),
            ("eglBindAPI", U, [U]), ("eglChooseConfig", U, [P, IP, C.POINTER(P), I, IP]),
            ("eglCreatePbufferSurface", P, [P, P, IP]), ("eglCreateContext", P, [P, P, P, IP]),
            ("eglMakeCurrent", U, [P, P, P, P]), ("eglDestroyContext", U, [P, P]),
            ("eglDestroySurface", U, [P, P]), ("eglTerminate", U, [P]),
            ("eglGetError", I, []), ("eglQueryString", C.c_char_p, [P, I]),
        ]:
            setattr(self, name, libraries.function(name, result, args, egl=True))
        for name, result, args in [
            ("glGetString", C.c_char_p, [U]), ("glGetStringi", C.c_char_p, [U, U]),
            ("glGetIntegerv", None, [U, IP]), ("glGetError", U, []),
        ]:
            self.gl[name] = libraries.function(name, result, args)

    def __getattr__(self, name):
        return self.gl[name]

    @staticmethod
    def attrs(*values):
        return (I * (len(values) + 1))(*values, NONE)

    def open(self):
        backend = {"vulkan": 0x3450, "metal": 0x3489, "opengl": 0x320D, "d3d11": 0x3208}[self.options.backend]
        attrs = [0x3203, backend]
        if self.options.backend == "vulkan" and sys.platform.startswith("linux"):
            platform = self.options.native_platform
            if platform == "headless" or (platform == "auto" and not os.environ.get("DISPLAY")):
                attrs += [0x348F, 0x34A5]  # EGL_PLATFORM_VULKAN_DISPLAY_MODE_HEADLESS_ANGLE.
            elif platform == "x11":
                attrs += [0x348F, 0x31D5]  # EGL_PLATFORM_X11_EXT.
        if self.options.validation:
            attrs += [0x3451, 1]
        address = self.eglGetProcAddress(b"eglGetPlatformDisplayEXT")
        require(address, "ANGLE platform display entry point missing")
        prototype = C.WINFUNCTYPE if sys.platform == "win32" else C.CFUNCTYPE
        get_display = prototype(P, U, P, IP)(address)
        self.display = get_display(0x3202, None, self.attrs(*attrs))
        require(self.display and self.eglInitialize(self.display, None, None),
                f"Cannot initialize ANGLE {self.options.backend}: EGL 0x{self.eglGetError():04x}")
        require(self.eglBindAPI(0x30A0), "Cannot bind GLES API")
        config, count = P(), I()
        require(self.eglChooseConfig(self.display, self.attrs(0x3033, 1, 0x3040, 0x40,
                0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8), C.byref(config), 1, C.byref(count)) and count.value,
                "No GLES 3 pbuffer configuration")
        self.surface = self.eglCreatePbufferSurface(self.display, config, self.attrs(0x3057, 2, 0x3056, 1))
        require(self.surface, "Cannot create pbuffer")
        for minor in (1, 0):
            attrs = [0x3098, 3, 0x30FB, minor]
            if self.options.webgl:
                attrs += [0x33AC, 1]
            self.context = self.eglCreateContext(self.display, config, None, self.attrs(*attrs))
            if self.context:
                self.minor = minor
                break
            self.eglGetError()  # Consume the unsuccessful 3.1 capability probe before trying 3.0.
        require(self.context and self.eglMakeCurrent(self.display, self.surface, self.surface, self.context),
                "Cannot create or activate a GLES 3 context")
        print("ANGLE_EGL_VERSION", self.eglQueryString(self.display, 0x3054).decode())
        print("GL_VERSION", self.glGetString(0x1F02).decode())
        print("GL_RENDERER", self.glGetString(0x1F01).decode())
        print("VALIDATION_REQUESTED", self.options.validation)
        if self.options.backend == "vulkan":
            query_display = prototype(U, P, I, C.POINTER(S))(
                self.eglGetProcAddress(b"eglQueryDisplayAttribEXT"))
            query_device = prototype(U, P, I, C.POINTER(S))(
                self.eglGetProcAddress(b"eglQueryDeviceAttribEXT"))
            device, version = S(), S()
            require(query_display(self.display, 0x322C, C.byref(device)), "Cannot query EGL device")
            require(query_device(P(device.value), 0x34A8, C.byref(version)), "Cannot query effective Vulkan version")
            value = version.value
            print("ANGLE_VULKAN_EFFECTIVE_VERSION", f"{(value >> 22) & 127}.{(value >> 12) & 1023}.{value & 4095}")

    def supported(self):
        count = I()
        self.glGetIntegerv(0x821D, C.byref(count))
        extensions = {self.glGetStringi(0x1F03, i).decode() for i in range(count.value)}
        enabled = EXTENSION in extensions
        limit = I(-1)
        self.glGetIntegerv(MAX_BINDINGS, C.byref(limit))
        error = self.glGetError()
        require(error == (0 if enabled else 0x500), "Extension exposure and limit query disagree")
        if self.options.webgl or self.options.backend in ("opengl", "d3d11"):
            require(not enabled, "Ray query incorrectly exposed in an unsupported context")
        if enabled:
            require(limit.value > 0, "Ray query binding limit must be positive")
            print("MAX_ACCELERATION_STRUCTURE_BINDINGS", limit.value)
        return enabled

    def load_commands(self):
        commands = [
            ("glGenAccelerationStructures", None, [I, UP]),
            ("glDeleteAccelerationStructures", None, [I, UP]),
            ("glIsAccelerationStructure", C.c_ubyte, [U]),
            ("glBuildTriangleAccelerationStructure", None, [U, U, S, I, I, U, S, U, I, U]),
            ("glBuildAabbAccelerationStructure", None, [U, U, S, I, I, U]),
            ("glSetAccelerationStructureInstance", None, [U, U, U, FP, U, U, U]),
            ("glBuildTopLevelAccelerationStructure", None, [U, I, U]),
            ("glBindAccelerationStructure", None, [U, U]),
            ("glGenBuffers", None, [I, UP]), ("glDeleteBuffers", None, [I, UP]),
            ("glBindBuffer", None, [U, U]), ("glBufferData", None, [U, S, P, U]),
            ("glCreateShader", U, [U]), ("glShaderSource", None, [U, I, C.POINTER(C.c_char_p), IP]),
            ("glCompileShader", None, [U]), ("glGetShaderiv", None, [U, U, IP]),
            ("glGetShaderInfoLog", None, [U, I, IP, P]), ("glDeleteShader", None, [U]),
            ("glCreateProgram", U, []), ("glAttachShader", None, [U, U]),
            ("glLinkProgram", None, [U]), ("glGetProgramiv", None, [U, U, IP]),
            ("glGetProgramInfoLog", None, [U, I, IP, P]), ("glDeleteProgram", None, [U]),
            ("glGetUniformLocation", I, [U, C.c_char_p]),
            ("glGetActiveUniform", None, [U, U, I, IP, IP, UP, P]),
            ("glUseProgram", None, [U]), ("glGenTextures", None, [I, UP]),
            ("glBindTexture", None, [U, U]), ("glTexStorage2D", None, [U, I, U, I, I]),
            ("glDeleteTextures", None, [I, UP]), ("glGenFramebuffers", None, [I, UP]),
            ("glBindFramebuffer", None, [U, U]), ("glFramebufferTexture2D", None, [U, U, U, U, I]),
            ("glCheckFramebufferStatus", U, [U]), ("glDeleteFramebuffers", None, [I, UP]),
            ("glViewport", None, [I, I, I, I]), ("glDrawArrays", None, [U, I, I]),
            ("glReadPixels", None, [I, I, I, I, U, U, P]),
        ]
        if self.minor >= 1:
            commands += [
                ("glBindBufferBase", None, [U, U, U]), ("glDispatchCompute", None, [U, U, U]),
                ("glMemoryBarrier", None, [U]), ("glMapBufferRange", P, [U, S, S, U]),
                ("glUnmapBuffer", C.c_ubyte, [U]),
                ("glBindImageTexture", None, [U, U, I, C.c_ubyte, I, U, U]),
            ]
        for name, result, args in commands:
            if "AccelerationStructure" in name:
                address = self.eglGetProcAddress(name.encode())
                require(address, "eglGetProcAddress did not export " + name)
                prototype = C.WINFUNCTYPE if sys.platform == "win32" else C.CFUNCTYPE
                function = prototype(result, *args)(address)
                self.lib.check_module(function, self.lib.gl_path)
                self.gl[name] = function
            else:
                self.gl[name] = self.lib.function(name, result, args)

    def check_gl(self, operation):
        error = self.glGetError()
        require(error == 0, f"{operation}: GL error 0x{error:04x}")

    def program(self, shaders):
        program = self.glCreateProgram()
        self.programs.append(program)
        for shader_type, source in shaders:
            shader = self.glCreateShader(shader_type)
            text = C.c_char_p(source.encode())
            self.glShaderSource(shader, 1, C.byref(text), None)
            self.glCompileShader(shader)
            status = I()
            self.glGetShaderiv(shader, 0x8B81, C.byref(status))
            log = C.create_string_buffer(65536)
            self.glGetShaderInfoLog(shader, len(log), None, log)
            if not status.value:
                self.glDeleteShader(shader)
                raise Failure("Shader compile: " + log.value.decode(errors="replace"))
            self.glAttachShader(program, shader)
            self.glDeleteShader(shader)
        status = I()
        self.glLinkProgram(program)
        self.glGetProgramiv(program, 0x8B82, C.byref(status))
        log = C.create_string_buffer(65536)
        self.glGetProgramInfoLog(program, len(log), None, log)
        require(status.value, "Program link: " + log.value.decode(errors="replace"))
        if any("accelerationStructureEXT" in source for _, source in shaders):
            array = any("accelerationStructureEXT scenes[2]" in source for _, source in shaders)
            nested_array = any("accelerationStructureEXT scenes[2][2]" in source for _, source in shaders)
            resource_name, resource_size = ((b"scenes[0][0]", 2) if nested_array else
                                            (b"scenes[0]", 2) if array else (b"scene", 1))
            require(self.glGetUniformLocation(program, resource_name) == -1, "AS resource has a mutable uniform location")
            count = I()
            self.glGetProgramiv(program, 0x8B86, C.byref(count))
            reflected = False
            for index in range(count.value):
                name, size, kind = C.create_string_buffer(256), I(), U()
                self.glGetActiveUniform(program, index, len(name), None, C.byref(size), C.byref(kind), name)
                if name.value == resource_name:
                    require(kind.value == 0x6001 and size.value == resource_size, "Incorrect AS resource reflection")
                    reflected = True
            require(reflected, "AS resource missing from active uniform reflection")
        return program

    def buffer(self, target, data=None, size=None):
        name = U()
        self.glGenBuffers(1, C.byref(name))
        self.buffers.append(name.value)
        self.glBindBuffer(target, name)
        self.glBufferData(target, C.sizeof(data) if data is not None else size, data, 0x88E4)
        return name.value

    def scene(self):
        names = (U * 2)()
        self.glGenAccelerationStructures(2, names)
        self.structures = list(names)
        require(all(self.glIsAccelerationStructure(n) for n in names), "AS name generation failed")
        vertices = (F * 16)(99, 99, 99, 99, -1, -1, 2, 77, 1, -1, 2, 77, 0, 1, 2, 77)
        indices = (C.c_ushort * 4)(99, 0, 1, 2)
        vertex_buffer = self.buffer(0x8892, vertices)
        index_buffer = self.buffer(0x8893, indices)
        self.vertex_buffer, self.index_buffer = vertex_buffer, index_buffer
        self.glBuildTriangleAccelerationStructure(names[0], vertex_buffer, 16, 16, 3,
                                                     index_buffer, 2, 0x1403, 3, FAST_TRACE)
        self.rebuild(0, 0)
        self.check_gl("BLAS/TLAS build and bind")

    def rebuild(self, x, z, mask=255, flags=0, scale_x=1):
        transform = (F * 12)(scale_x, 0, 0, x, 0, 1, 0, 0, 0, 0, 1, z)
        self.glSetAccelerationStructureInstance(self.structures[1], 0, self.structures[0],
                                                  transform, 42, mask, flags)
        self.glBuildTopLevelAccelerationStructure(self.structures[1], 1, FAST_TRACE)
        self.glBindAccelerationStructure(0, self.structures[1])

    def api_errors(self):
        def rejected(label, expected, action):
            self.check_gl("before " + label)
            action()
            actual = self.glGetError()
            require(actual == expected, f"{label}: GL error 0x{actual:04x}, expected 0x{expected:04x}")
            print("RAY_QUERY_API_ERROR_PASS", label)
        rejected("binding_range", 0x501, lambda: self.glBindAccelerationStructure(4, 0))
        rejected("unknown_name", 0x501, lambda: self.glBindAccelerationStructure(0, 0xffffffff))
        rejected("bind_blas", 0x502, lambda: self.glBindAccelerationStructure(0, self.structures[0]))
        rejected("aabb_stride", 0x501, lambda: self.glBuildAabbAccelerationStructure(
            self.structures[0], self.vertex_buffer, 0, 20, 1, 0))
        rejected("aabb_offset", 0x501, lambda: self.glBuildAabbAccelerationStructure(
            self.structures[0], self.vertex_buffer, 4, 24, 1, 0))
        for label, offset, index_type, flags, expected in [
            ("unaligned_vertices", 2, 0x1403, 1, 0x501),
            ("index_format", 16, 0x1401, 1, 0x500),
            ("conflicting_build_flags", 16, 0x1403, 3, 0x501),
        ]:
            rejected(label, expected, lambda: self.glBuildTriangleAccelerationStructure(
                self.structures[0], self.vertex_buffer, offset, 16, 3,
                self.index_buffer, 2, index_type, 3, flags))
        rejected("singular_transform", 0x501, lambda: self.glSetAccelerationStructureInstance(
            self.structures[1], 0, self.structures[0], (F * 12)(), 42, 255, 0))
        rejected("empty_tlas", 0x501, lambda: self.glBuildTopLevelAccelerationStructure(
            self.structures[1], 0, FAST_TRACE))
        rejected("change_object_kind", 0x502, lambda: self.glBuildTopLevelAccelerationStructure(
            self.structures[0], 1, FAST_TRACE))

    def fragment_target(self):
        texture, framebuffer = U(), U()
        self.glGenTextures(1, C.byref(texture))
        self.texture = texture.value
        self.glBindTexture(0x0DE1, texture)
        self.glTexStorage2D(0x0DE1, 1, 0x8D70, 2, 1)  # RGBA32UI: GLES 3 core renderable.
        self.glGenFramebuffers(1, C.byref(framebuffer))
        self.framebuffer = framebuffer.value
        self.glBindFramebuffer(0x8D40, framebuffer)
        self.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, texture, 0)
        require(self.glCheckFramebufferStatus(0x8D40) == 0x8CD5, "Integer framebuffer incomplete")
        self.glViewport(0, 0, 2, 1)

    def trace_fragment(self, program, vertex=False):
        self.glUseProgram(program)
        self.glDrawArrays(0 if vertex else 4, 0, 2 if vertex else 3)
        result = (U * 8)()
        self.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, result)
        self.check_gl("fragment query/readback")
        return list(result)

    def trace_compute(self, program, output):
        self.dispatch_compute(program, output)
        return self.read_compute(output)

    def dispatch_compute(self, program, output):
        self.glUseProgram(program)
        self.glBindBufferBase(0x90D2, 0, output)
        self.glDispatchCompute(1, 1, 1)

    def read_compute(self, output):
        self.glMemoryBarrier(0x200)  # GL_BUFFER_UPDATE_BARRIER_BIT for mapped CPU readback.
        self.glBindBuffer(0x90D2, output)
        address = self.glMapBufferRange(0x90D2, 0, 32, 1)
        require(address, "Cannot map compute query output")
        result = list((U * 8).from_buffer_copy(C.string_at(address, 32)))
        require(self.glUnmapBuffer(0x90D2), "Compute output buffer became invalid")
        self.check_gl("compute query/readback")
        return result

    @staticmethod
    def verify(result, distance, label, custom_index=42):
        require(result[4:] == [0, 0, 0, 0], f"{label}: miss ray unexpectedly hit: {result[4:]}")
        if distance is None:
            require(result[:4] == [0, 0, 0, 0], f"{label}: moved triangle unexpectedly hit")
        else:
            require(result[0] == 1 and result[2:4] == [0, custom_index], f"{label}: incorrect hit/IDs/barycentrics: {result[:4]}")
            actual = struct.unpack("=f", struct.pack("=I", result[1]))[0]
            require(abs(actual - distance) < 0.001, f"{label}: distance {actual}, expected {distance}")
        print("RAY_QUERY_CASE_PASS", label, "distance=" + str(distance))

    def extended(self):
        stages = [self.options.stage] if self.options.stage != "all" else ["fragment", "vertex", "compute"]
        cases = [
            ("opaque", 1, 255, 255, 0, 2),
            ("non_opaque", 2, 255, 255, 0, 2),
            ("terminate_first", 4, 255, 255, 0, 2),
            ("terminate_builtin", 0, 255, 255, 0, 2),
            ("reject_candidate", 0, 255, 255, 0, None),
            ("zero_ray_mask", 0, 0, 255, 0, None),
            ("zero_instance_mask", 0, 255, 0, 0, None),
            ("skip_triangles", 256, 255, 255, 0, None),
            ("cull_non_opaque", 128, 255, 255, 0, None),
            ("force_opaque_instance", 128, 255, 255, 4, 2),
            ("cull_back", 16, 255, 255, 0, None),
            ("flipped_facing", 16, 255, 255, 2, 2),
            ("disable_culling", 16, 255, 255, 1, 2),
        ]
        output = self.buffer(0x90D2, size=32) if "compute" in stages and self.minor >= 1 else None
        for label, flags, ray_mask, instance_mask, instance_flags, distance in cases:
            query = QUERY.replace("gl_RayFlagsNoneEXT", str(flags) + "u")
            query = query.replace("255u,", str(ray_mask) + "u,")
            if instance_flags & 2:
                query = query.replace("expectedFront = false", "expectedFront = true")
            if label == "terminate_builtin":
                query = query.replace("rayQueryConfirmIntersectionEXT(q);",
                                      "rayQueryConfirmIntersectionEXT(q); rayQueryTerminateEXT(q);")
            if label == "reject_candidate":
                query = query.replace("rayQueryConfirmIntersectionEXT(q);", "")
            self.rebuild(0, 0, instance_mask, instance_flags)
            for stage in stages:
                if stage == "compute":
                    if output is None:
                        continue
                    program = self.program([(0x91B9, COMPUTE.replace(QUERY, query))])
                    result = self.trace_compute(program, output)
                elif stage == "vertex":
                    program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, query)), (0x8B30, VERTEX_RESULT)])
                    result = self.trace_fragment(program, vertex=True)
                else:
                    program = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT.replace(QUERY, query))])
                    result = self.trace_fragment(program)
                self.verify(result, distance, stage + "/" + label)

    def graphics_storage(self):
        limit = I()
        self.glGetIntegerv(0x90DA, C.byref(limit))  # GL_MAX_FRAGMENT_SHADER_STORAGE_BLOCKS.
        if limit.value < 1:
            print("RAY_QUERY_GRAPHICS_SSBO_SKIP stage_limit=0")
            return
        self.rebuild(0, 0)
        counter = self.buffer(0x90D2, (U * 8)())
        self.glBindBufferBase(0x90D2, 0, counter)
        vertex = VERTEX.replace("#version 300 es", "#version 310 es")
        fragment = FRAGMENT.replace("#version 300 es", "#version 310 es")
        fragment = fragment.replace(
            "layout(location = 0) out uvec4 color;",
            "layout(std430,binding=0) buffer Counts { uint counts[]; }; "
            "layout(location = 0) out uvec4 color;")
        fragment = fragment.replace("color = trace(",
                                    "atomicAdd(counts[0], 1u); color = trace(")
        program = self.program([(0x8B31, vertex), (0x8B30, fragment)])
        self.verify(self.trace_fragment(program), 2, "fragment/ray_query_and_ssbo")
        actual = self.read_compute(counter)
        require(actual[0] == 2, f"Ray query/SSBO counter differs: {actual}")
        print("RAY_QUERY_GRAPHICS_SSBO_PASS")

    def graphics_image(self):
        limit = I()
        self.glGetIntegerv(0x90CE, C.byref(limit))  # GL_MAX_FRAGMENT_IMAGE_UNIFORMS.
        if limit.value < 1:
            print("RAY_QUERY_GRAPHICS_IMAGE_SKIP stage_limit=0")
            return
        image = U()
        self.glGenTextures(1, C.byref(image))
        try:
            self.glBindTexture(0x0DE1, image)
            self.glTexStorage2D(0x0DE1, 1, 0x8D70, 2, 1)
            self.glBindImageTexture(0, image, 0, False, 0, 0x88B9, 0x8D70)
            vertex = VERTEX.replace("#version 300 es", "#version 310 es")
            fragment = FRAGMENT.replace("#version 300 es", "#version 310 es")
            fragment = fragment.replace(
                "layout(location = 0) out uvec4 color;",
                "layout(rgba32ui,binding=0) writeonly uniform highp uimage2D resultImage;\n"
                "layout(location = 0) out uvec4 color;")
            fragment = fragment.replace(
                "void main() { color = trace(vec3(gl_FragCoord.x < 1.0 ? 0.0 : 4.0, 0, 0)); }",
                "void main() { color = trace(vec3(gl_FragCoord.x < 1.0 ? 0.0 : 4.0, 0, 0)); "
                "imageStore(resultImage, ivec2(int(gl_FragCoord.x), 0), color); }")
            program = self.program([(0x8B31, vertex), (0x8B30, fragment)])
            output = self.trace_fragment(program)
            self.verify(output, 2, "fragment/ray_query_and_image")
            self.glMemoryBarrier(0x400)  # GL_FRAMEBUFFER_BARRIER_BIT.
            self.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, image, 0)
            result = (U * 8)()
            self.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, result)
            self.check_gl("ray query image readback")
            require(list(result) == output, "Ray query output differs in the bound image")
            print("RAY_QUERY_GRAPHICS_IMAGE_PASS")
        finally:
            self.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, self.texture, 0)
            self.glDeleteTextures(1, C.byref(image))

    def queued_lifetime(self):
        if self.minor < 1:
            return
        self.rebuild(0, 0)
        query = self.program([(0x91B9, COMPUTE)])
        writer = self.program([(0x91B9, """#version 310 es
            layout(local_size_x=1) in;
            layout(std430,binding=0) buffer Vertices { highp float v[]; };
            void main() { v[6] = 7.0; v[10] = 7.0; v[14] = 7.0; }
        """)])
        outputs = [self.buffer(0x90D2, size=32) for _ in range(3)]
        self.dispatch_compute(query, outputs[0])
        self.dispatch_compute(writer, self.vertex_buffer)
        # This build consumes GPU-written geometry. No CPU readback/completion
        # separates shader writes, BLAS build, TLAS build or traversal commands.
        self.glBuildTriangleAccelerationStructure(self.structures[0], self.vertex_buffer, 16, 16, 3,
                                                     self.index_buffer, 2, 0x1403, 3, FAST_TRACE)
        self.dispatch_compute(query, outputs[1])  # Old TLAS still pins the old BLAS generation.
        self.rebuild(0, 0)
        self.dispatch_compute(query, outputs[2])
        self.glDeleteAccelerationStructures(len(self.structures), (U * len(self.structures))(*self.structures))
        self.structures = []
        self.check_gl("queued builds, queries and object deletion")
        self.glDispatchCompute(1, 1, 1)
        require(self.glGetError() == 0x502, "Dispatch accepted a deleted TLAS binding")
        print("RAY_QUERY_API_ERROR_PASS deleted_tlas_binding")
        for output, distance, label in zip(outputs, [2, 2, 7],
                                           ["before_rebuild", "old_tlas_generation", "gpu_written_geometry"]):
            self.verify(self.read_compute(output), distance, "compute/queued_" + label)

    def geometry_variants(self, stages):
        self.glBuildTriangleAccelerationStructure(self.structures[0], self.vertex_buffer, 16, 16, 3,
                                                     0, 0, 0, 0, 2)
        self.rebuild(0, 0)
        for stage, trace in stages:
            self.verify(trace(), 2, stage + "/non_indexed_fast_build")
        index32 = self.buffer(0x8893, (U * 4)(99, 0, 1, 2))
        self.glBuildTriangleAccelerationStructure(self.structures[0], self.vertex_buffer, 16, 16, 3,
                                                     index32, 4, 0x1405, 3, 2)
        self.rebuild(0, 0)
        for stage, trace in stages:
            self.verify(trace(), 2, stage + "/uint32_indices")
        self.rebuild(0, 0, scale_x=-1)
        for stage, trace in stages:
            self.verify(trace(), 2, stage + "/mirrored_instance")

    def multiple_instances(self, stages):
        self.rebuild(0, 0)

        # Pending metadata changes must leave the preceding native generation intact.
        moved = (F * 12)(1, 0, 0, 8, 0, 1, 0, 0, 0, 0, 1, 0)
        self.glSetAccelerationStructureInstance(self.structures[1], 0, self.structures[0],
                                                  moved, 42, 255, 0)
        for stage, trace in stages:
            self.verify(trace(), 2, stage + "/pending_instance_unchanged")
        name = U()
        self.glGenAccelerationStructures(1, C.byref(name))
        self.structures.append(name.value)
        vertices = self.buffer(0x8892, (F * 9)(-1, -1, 6, 1, -1, 6, 0, 1, 6))
        self.glBuildTriangleAccelerationStructure(name, vertices, 0, 12, 3, 0, 0, 0, 0, FAST_TRACE)
        identity = (F * 12)(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0)
        self.glSetAccelerationStructureInstance(self.structures[1], 1, name, identity, 43, 255, 0)
        self.glBuildTopLevelAccelerationStructure(self.structures[1], 2, FAST_TRACE)
        query = QUERY.replace("== 42", "== 43").replace("InstanceIdEXT(q, true) == 0", "InstanceIdEXT(q, true) == 1")
        for stage, _ in stages:
            if stage == "compute":
                program = self.program([(0x91B9, COMPUTE.replace(QUERY, query))])
                result = self.trace_compute(program, self.buffer(0x90D2, size=32))
            elif stage == "vertex":
                program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, query)), (0x8B30, VERTEX_RESULT)])
                result = self.trace_fragment(program, vertex=True)
            else:
                program = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT.replace(QUERY, query))])
                result = self.trace_fragment(program)
            self.verify(result, 6, stage + "/multiple_blas_instances", custom_index=43)
        self.rebuild(0, 0)

    def acceleration_structure_parameter(self, stages):
        self.rebuild(0, 0)
        query = QUERY.replace("uvec4 trace(vec3 origin)",
                              "uvec4 trace(accelerationStructureEXT top, vec3 origin)")
        query = query.replace("q, scene,", "q, top,")
        for stage, _ in stages:
            if stage == "compute":
                source = COMPUTE.replace(QUERY, query).replace("trace(vec3(float", "trace(scene, vec3(float")
                program = self.program([(0x91B9, source)])
                result = self.trace_compute(program, self.buffer(0x90D2, size=32))
            elif stage == "vertex":
                source = VERTEX_QUERY.replace(QUERY, query).replace("trace(vec3(float", "trace(scene, vec3(float")
                program = self.program([(0x8B31, source), (0x8B30, VERTEX_RESULT)])
                result = self.trace_fragment(program, vertex=True)
            else:
                source = FRAGMENT.replace(QUERY, query).replace("trace(vec3(gl_Frag", "trace(scene, vec3(gl_Frag")
                program = self.program([(0x8B31, VERTEX), (0x8B30, source)])
                result = self.trace_fragment(program)
            self.verify(result, 2, stage + "/acceleration_structure_parameter")

    def acceleration_structure_array(self, stages):
        self.rebuild(0, 0)
        name = U()
        self.glGenAccelerationStructures(1, C.byref(name))
        self.structures.append(name.value)
        moved = (F * 12)(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 3)
        self.glSetAccelerationStructureInstance(name, 0, self.structures[0], moved, 42, 255, 0)
        self.glBuildTopLevelAccelerationStructure(name, 1, FAST_TRACE)
        self.glBindAccelerationStructure(1, name)
        query = QUERY.replace("uniform accelerationStructureEXT scene;",
                              "uniform accelerationStructureEXT scenes[2];")
        query = query.replace("q, scene,", "q, scenes[1],")
        for stage, _ in stages:
            if stage == "compute":
                program = self.program([(0x91B9, COMPUTE.replace(QUERY, query))])
                result = self.trace_compute(program, self.buffer(0x90D2, size=32))
            elif stage == "vertex":
                program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, query)),
                                        (0x8B30, VERTEX_RESULT)])
                result = self.trace_fragment(program, vertex=True)
            else:
                program = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT.replace(QUERY, query))])
                result = self.trace_fragment(program)
            self.verify(result, 5, stage + "/acceleration_structure_array")
        if any(stage == "compute" for stage, _ in stages):
            dynamic = query.replace("q, scenes[1],", "q, scenes[int(origin.x < 0.0) + 1],")
            program = self.program([(0x91B9, COMPUTE.replace(QUERY, dynamic))])
            self.verify(self.trace_compute(program, self.buffer(0x90D2, size=32)), 5,
                        "compute/acceleration_structure_dynamic_array")
            self.glBindAccelerationStructure(0, 0)
            self.dispatch_compute(program, self.buffer(0x90D2, size=32))
            require(self.glGetError() == 0x502, "Dispatch accepted an unbound array element")
            print("RAY_QUERY_API_ERROR_PASS unbound_array_element")
            self.glBindAccelerationStructure(0, self.structures[1])
            overlap = query.replace("uniform accelerationStructureEXT scenes[2];",
                "uniform accelerationStructureEXT scenes[2];\n"
                "layout(binding=1) uniform accelerationStructureEXT clash;")
            overlap = overlap.replace("    bool candidateValid = true;", """    rayQueryEXT other;
    rayQueryInitializeEXT(other, clash, 0u, 255u, origin, 0.0, vec3(0, 0, 1), 100.0);
    while (rayQueryProceedEXT(other)) rayQueryConfirmIntersectionEXT(other);
    bool candidateValid = true;""")
            try:
                self.program([(0x91B9, COMPUTE.replace(QUERY, overlap))])
            except Failure as error:
                require("distinct bindings" in str(error), "Unexpected overlapping-binding error: " + str(error))
                print("RAY_QUERY_API_ERROR_PASS overlapping_array_bindings")
            else:
                raise Failure("Program linked overlapping acceleration-structure bindings")
            self.glBindAccelerationStructure(2, self.structures[1])
            self.glBindAccelerationStructure(3, name)
            nested = query.replace("scenes[2]", "scenes[2][2]").replace("scenes[1]", "scenes[1][1]")
            program = self.program([(0x91B9, COMPUTE.replace(QUERY, nested))])
            self.verify(self.trace_compute(program, self.buffer(0x90D2, size=32)), 5,
                        "compute/acceleration_structure_multidimensional_array")
            self.glBindAccelerationStructure(2, 0)
            self.glBindAccelerationStructure(3, 0)
        self.glBindAccelerationStructure(1, 0)

    def query_scope(self, stages):
        self.rebuild(0, 0)
        initialize = """rayQueryInitializeEXT(q, scene, gl_RayFlagsNoneEXT, 255u,
                         origin, 0.0, vec3(0, 0, 1), 100.0);"""
        require(initialize in QUERY, "Cannot construct query scope tests")
        helper = """void initQuery(rayQueryEXT state, vec3 origin) {
    rayQueryInitializeEXT(state, scene, gl_RayFlagsNoneEXT, 255u,
                          origin, 0.0, vec3(0, 0, 1), 100.0);
}
"""
        uniform = "layout(binding = 0) uniform accelerationStructureEXT scene;"
        local_array = re.sub(r"\bq\b", "queries[1]", QUERY).replace(
            "rayQueryEXT queries[1];", "rayQueryEXT queries[2];")
        parameter = QUERY.replace(uniform, uniform + "\n" + helper).replace(
            initialize, "initQuery(q, origin);")
        array_parameter = re.sub(r"\bq\b", "queries[1]", parameter).replace(
            "rayQueryEXT queries[1];", "rayQueryEXT queries[2];")
        global_helper = helper.replace("rayQueryEXT state, ", "").replace("state, scene,", "q, scene,")
        global_query = QUERY.replace(uniform, uniform + "\nrayQueryEXT q;\n" + global_helper).replace(
            "    rayQueryEXT q;\n", "").replace(initialize, "initQuery(origin);")
        call = "initQuery(queries[1], origin);"
        dynamic = array_parameter.replace("queries[1]", "queries[0]").replace(
            "initQuery(queries[0], origin);", """int index = 0;
    initQuery(queries[index++], origin);
    if (index != 1) return uvec4(0xdeadbeefu);""")
        comma = array_parameter.replace(call, """int index = 0;
    initQuery((index++, queries[1]), origin);
    if (index != 1) return uvec4(0xdeadbeefu);""")
        short_helper = helper.replace("void initQuery", "bool maybeInitQuery").replace(
            "origin, 0.0, vec3(0, 0, 1), 100.0);", "origin, 0.0, vec3(0, 0, 1), 100.0); return true;")
        short_circuit = dynamic.replace(uniform, uniform + "\n" + short_helper).replace(
            "    initQuery(queries[index++], origin);", """    bool unused = origin.x < 0.0 && maybeInitQuery(queries[index++], origin);
    if (unused || index != 0) return uvec4(0xdeadbeefu);
    initQuery(queries[index++], origin);""")
        sequence = array_parameter.replace(uniform, uniform + "\n" + short_helper).replace(call, """int index = 0;
    bool done = (index = 1, maybeInitQuery(queries[index++], origin));
    if (!done || index != 2) return uvec4(0xdeadbeefu);""")
        conditional_sequence = array_parameter.replace(uniform, uniform + "\n" + short_helper).replace(call, """int index = 0;
    bool done = (origin.x < 0.0 && (index = 1, maybeInitQuery(queries[index++], origin)));
    if (done || index != 0) return uvec4(0xdeadbeefu);
    initQuery(queries[1], origin);""")
        loop_condition = array_parameter.replace(uniform, uniform + "\n" + short_helper).replace(call, """int index = 1;
    for (; index == 1 && maybeInitQuery(queries[index++], origin); ) { break; }
    if (index != 2) return uvec4(0xdeadbeefu);""")
        array_helper = """void initArray(rayQueryEXT state[2], vec3 origin) {
    initQuery(state[1], origin);
}
"""
        array_param_array = array_parameter.replace(uniform + "\n" + helper,
            uniform + "\n" + helper + array_helper).replace(call, "initArray(queries, origin);")
        global_array = global_query.replace("rayQueryEXT q;", "rayQueryEXT q[2];")
        global_array = re.sub(r"\bq\b(?!\[)", "q[1]", global_array).replace(
            "rayQueryEXT q[1][2];", "rayQueryEXT q[2];")
        two_queries = array_parameter.replace(call, """initQuery(queries[1], origin);
    initQuery(queries[0], vec3(4, 0, 0));
    while (rayQueryProceedEXT(queries[0])) { rayQueryConfirmIntersectionEXT(queries[0]); }
    if (rayQueryGetIntersectionTypeEXT(queries[0], true) != gl_RayQueryCommittedIntersectionNoneEXT)
        return uvec4(0xdeadbeefu);""")
        for label, query in [("query_local_array", local_array),
                             ("query_parameter", parameter),
                             ("query_global", global_query),
                             ("query_array_parameter", array_parameter),
                             ("query_dynamic_index", dynamic),
                             ("query_comma_argument", comma),
                             ("query_short_circuit", short_circuit),
                             ("query_sequence_evaluation", sequence),
                             ("query_conditional_sequence", conditional_sequence),
                             ("query_loop_condition", loop_condition),
                             ("query_array_parameter_array", array_param_array),
                             ("query_global_array", global_array),
                             ("query_two_live", two_queries)]:
            for stage, _ in stages:
                if stage == "compute":
                    program = self.program([(0x91B9, COMPUTE.replace(QUERY, query))])
                    result = self.trace_compute(program, self.buffer(0x90D2, size=32))
                elif stage == "vertex":
                    program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, query)),
                                            (0x8B30, VERTEX_RESULT)])
                    result = self.trace_fragment(program, vertex=True)
                else:
                    program = self.program([(0x8B31, VERTEX),
                                            (0x8B30, FRAGMENT.replace(QUERY, query))])
                    result = self.trace_fragment(program)
                self.verify(result, 2, stage + "/" + label)
        if any(stage == "compute" for stage, _ in stages):
            nested = array_parameter.replace("rayQueryEXT queries[2];", "rayQueryEXT queries[2][2];")
            nested = nested.replace("queries[1]", "queries[1][1]")
            program = self.program([(0x91B9, COMPUTE.replace(QUERY, nested))])
            self.verify(self.trace_compute(program, self.buffer(0x90D2, size=32)), 2,
                        "compute/query_multidimensional_array")

    def procedural_aabbs(self, stages):
        names = (U * 2)()
        self.glGenAccelerationStructures(2, names)
        self.structures.extend(names)
        boxes = self.buffer(0x8892, (F * 6)(-1, -1, 2, 1, 1, 3))
        self.glBuildAabbAccelerationStructure(names[0], boxes, 0, 24, 1, FAST_TRACE)
        identity = (F * 12)(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0)
        query = """
precision highp float;
precision highp int;
layout(binding = 0) uniform accelerationStructureEXT scene;
uvec4 trace(vec3 origin) {
    rayQueryEXT q;
    rayQueryInitializeEXT(q, scene, gl_RayFlagsNoneEXT, 255u,
                          origin, 0.0, vec3(0, 0, 1), 100.0);
    bool candidate = false;
    while (rayQueryProceedEXT(q)) {
        if (rayQueryGetIntersectionTypeEXT(q, false) == gl_RayQueryCandidateIntersectionAABBEXT) {
            // AABB candidates can be conservative false positives. Test the
            // actual procedural sphere before committing an intersection.
            vec3 o = rayQueryGetIntersectionObjectRayOriginEXT(q, false) - vec3(0, 0, 2.5);
            vec3 d = rayQueryGetIntersectionObjectRayDirectionEXT(q, false);
            float a = dot(d, d);
            float b = dot(o, d);
            float c = dot(o, o) - 0.25 * 0.25;
            float discriminant = b * b - a * c;
            if (discriminant >= 0.0) {
                candidate = !rayQueryGetIntersectionCandidateAABBOpaqueEXT(q);
                rayQueryGenerateIntersectionEXT(q, (-b - sqrt(discriminant)) / a);
            }
        }
    }
    uint kind = rayQueryGetIntersectionTypeEXT(q, true);
    if (kind == gl_RayQueryCommittedIntersectionNoneEXT) return uvec4(0u);
    bool valid = candidate && kind == gl_RayQueryCommittedIntersectionGeneratedEXT;
    valid = valid && rayQueryGetIntersectionInstanceShaderBindingTableRecordOffsetEXT(q, true) == 0u;
    return uvec4(valid ? 1u : 0xdeadbeefu,
                 floatBitsToUint(rayQueryGetIntersectionTEXT(q, true)),
                 rayQueryGetIntersectionPrimitiveIndexEXT(q, true),
                 rayQueryGetIntersectionInstanceCustomIndexEXT(q, true));
}
"""
        self.glSetAccelerationStructureInstance(names[1], 0, names[0], identity, 42, 255, 0)
        self.glBuildTopLevelAccelerationStructure(names[1], 1, FAST_TRACE)
        self.glBindAccelerationStructure(0, names[1])
        self.check_gl("AABB build and bind")
        for label, flags, expected in [("aabb_generated", "gl_RayFlagsNoneEXT", 2.25),
                                       ("aabb_skipped", "gl_RayFlagsSkipAABBEXT", None)]:
            source = query.replace("gl_RayFlagsNoneEXT", flags)
            for stage, _ in stages:
                if stage == "compute":
                    program = self.program([(0x91B9, COMPUTE.replace(QUERY, source))])
                    result = self.trace_compute(program, self.buffer(0x90D2, size=32))
                elif stage == "vertex":
                    program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, source)),
                                            (0x8B30, VERTEX_RESULT)])
                    result = self.trace_fragment(program, vertex=True)
                else:
                    program = self.program([(0x8B31, VERTEX),
                                            (0x8B30, FRAGMENT.replace(QUERY, source))])
                    result = self.trace_fragment(program)
                self.verify(result, expected, stage + "/" + label)
        # A procedural AABB remains a candidate even when the instance forces
        # opaque traversal. Its candidate-opacity getter must reflect the override.
        self.glSetAccelerationStructureInstance(names[1], 0, names[0], identity, 42, 255, 4)
        self.glBuildTopLevelAccelerationStructure(names[1], 1, FAST_TRACE)
        opaque = query.replace("candidate = !rayQueryGetIntersectionCandidateAABBOpaqueEXT(q);",
                               "candidate = rayQueryGetIntersectionCandidateAABBOpaqueEXT(q);")
        for stage, _ in stages:
            if stage == "compute":
                program = self.program([(0x91B9, COMPUTE.replace(QUERY, opaque))])
                result = self.trace_compute(program, self.buffer(0x90D2, size=32))
            elif stage == "vertex":
                program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, opaque)),
                                        (0x8B30, VERTEX_RESULT)])
                result = self.trace_fragment(program, vertex=True)
            else:
                program = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT.replace(QUERY, opaque))])
                result = self.trace_fragment(program)
            self.verify(result, 2.25, stage + "/aabb_force_opaque")
        self.glBindAccelerationStructure(0, self.structures[1])

    def sparse_binding(self, stages):
        self.rebuild(0, 0)
        self.glBindAccelerationStructure(2, self.structures[1])
        self.glBindAccelerationStructure(0, 0)
        query = QUERY.replace("layout(binding = 0)", "layout(binding = 2)")
        for stage, _ in stages:
            if stage == "compute":
                program = self.program([(0x91B9, COMPUTE.replace(QUERY, query))])
                result = self.trace_compute(program, self.buffer(0x90D2, size=32))
            elif stage == "vertex":
                program = self.program([(0x8B31, VERTEX_QUERY.replace(QUERY, query)), (0x8B30, VERTEX_RESULT)])
                result = self.trace_fragment(program, vertex=True)
            else:
                program = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT.replace(QUERY, query))])
                result = self.trace_fragment(program)
            self.verify(result, 2, stage + "/sparse_binding_2")
        self.glBindAccelerationStructure(0, self.structures[1])

    def run(self):
        self.load_commands()
        self.scene()
        self.api_errors()
        stages = []
        if self.options.stage in ("all", "fragment"):
            fragment = self.program([(0x8B31, VERTEX), (0x8B30, FRAGMENT)])
            self.fragment_target()
            stages.append(("fragment", lambda: self.trace_fragment(fragment)))
        if self.options.stage in ("all", "vertex"):
            vertex = self.program([(0x8B31, VERTEX_QUERY), (0x8B30, VERTEX_RESULT)])
            if not self.framebuffer:
                self.fragment_target()
            stages.append(("vertex", lambda: self.trace_fragment(vertex, vertex=True)))
        compute_missing = self.options.stage in ("all", "compute") and self.minor < 1
        if self.options.stage in ("all", "compute") and not compute_missing:
            compute = self.program([(0x91B9, COMPUTE)])
            output = self.buffer(0x90D2, size=32)
            stages.append(("compute", lambda: self.trace_compute(compute, output)))
        for phase, x, z, distance in [("identity", 0, 0, 2), ("translated_z", 0, 3, 5),
                                       ("translated_x_miss", 8, 0, None)]:
            self.rebuild(x, z)
            self.check_gl("TLAS transform rebuild")
            for stage, trace in stages:
                self.verify(trace(), distance, stage + "/" + phase)
        if compute_missing:
            print("RAY_QUERY_SKIP compute requires a GLES 3.1 context; fragment results above remain valid")
            return 77
        if self.options.extended:
            if self.minor >= 1 and self.options.stage in ("all", "fragment"):
                self.graphics_storage()
                self.graphics_image()
            self.extended()
            self.geometry_variants(stages)
            self.multiple_instances(stages)
            self.sparse_binding(stages)
            self.acceleration_structure_parameter(stages)
            self.acceleration_structure_array(stages)
            self.query_scope(stages)
            self.procedural_aabbs(stages)
            self.queued_lifetime()
        print("RAY_QUERY_PASS", self.options.backend, self.options.stage)
        return 0

    def close(self):
        if self.context:
            if self.structures:
                self.glDeleteAccelerationStructures(len(self.structures), (U * len(self.structures))(*self.structures))
            for program in self.programs:
                self.glDeleteProgram(program)
            if self.buffers:
                self.glDeleteBuffers(len(self.buffers), (U * len(self.buffers))(*self.buffers))
            if self.framebuffer:
                self.glDeleteFramebuffers(1, C.byref(U(self.framebuffer)))
            if self.texture:
                self.glDeleteTextures(1, C.byref(U(self.texture)))
            self.eglMakeCurrent(self.display, None, None, None)
            self.eglDestroyContext(self.display, self.context)
        if self.surface:
            self.eglDestroySurface(self.display, self.surface)
        if self.display:
            self.eglTerminate(self.display)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-dir", required=True, help="Directory containing builder libEGL and libGLESv2")
    parser.add_argument("--backend", choices=("vulkan", "metal", "opengl", "d3d11"),
                        default="metal" if sys.platform == "darwin" else "vulkan")
    parser.add_argument("--stage", choices=("all", "fragment", "compute", "vertex"), default="all")
    parser.add_argument("--native-platform", choices=("auto", "headless", "x11"), default="auto",
                        help="Linux Vulkan display: auto uses DISPLAY when present, otherwise headless")
    parser.add_argument("--validation", action="store_true", help="Request native API validation; diagnostics remain visible")
    parser.add_argument("--extended", action="store_true", help="Also test native masks, opacity and triangle culling")
    parser.add_argument("--webgl", action="store_true", help="Create a WebGL-compatible context and assert extension absence")
    expectations = parser.add_mutually_exclusive_group()
    expectations.add_argument("--require-supported", action="store_true", help="Treat extension absence as failure instead of SKIP")
    expectations.add_argument("--expect-absent", action="store_true", help="Pass only when extension is absent (negative capability test)")
    options = parser.parse_args()
    if options.webgl and options.require_supported:
        parser.error("--webgl tests extension absence and cannot use --require-supported")
    probe = None
    try:
        if options.validation and options.backend == "metal":
            # ANGLE's renderer/metal/doc/ValidationLayers.md documents these switches.
            os.environ["MTL_DEBUG_LAYER"] = "1"
            os.environ["MTL_SHADER_VALIDATION"] = "1"
            os.environ["MTL_DEBUG_LAYER_VALIDATE_UNRETAINED_RESOURCES"] = "4"
        if options.validation and options.backend == "vulkan" and sys.platform.startswith("linux"):
            # ANGLE prepends its own layer directory. Preserve system layer
            # discovery when that directory contains no validation layer.
            paths = [p for p in os.environ.get("VK_LAYER_PATH", "").split(os.pathsep) if p]
            for directory in ("/etc/vulkan/explicit_layer.d", "/usr/share/vulkan/explicit_layer.d"):
                if Path(directory).is_dir() and directory not in paths:
                    paths.append(directory)
            if paths:
                os.environ["VK_LAYER_PATH"] = os.pathsep.join(paths)
        probe = Probe(Libraries(options.native_dir), options)
        probe.open()
        exposed = probe.supported()
        if options.expect_absent or options.webgl:
            require(not exposed, "Extension unexpectedly exposed")
            print("RAY_QUERY_ABSENCE_PASS", options.backend)
            return 0
        if not exposed:
            require(not options.require_supported, "Required GL_NGE_ray_query is unavailable")
            print("RAY_QUERY_SKIP GL_NGE_ray_query is unavailable on this device/context")
            return 77
        return probe.run()
    except (Failure, OSError, AttributeError) as error:
        print("RAY_QUERY_FAIL", error, file=sys.stderr)
        return 1
    finally:
        if probe:
            probe.close()


if __name__ == "__main__":
    sys.exit(main())
