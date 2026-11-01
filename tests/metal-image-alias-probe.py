#!/usr/bin/env python3
"""Exercise overlapping GLES image uniforms through the Metal backend."""

import argparse
import ctypes as C
import importlib.util
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ray_probe", ROOT / "tests/nge-ray-query-probe.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
U, I, P = base.U, base.I, base.P

TEXTURE_2D, TEXTURE_3D, TEXTURE_ARRAY, TEXTURE_CUBE = 0x0DE1, 0x806F, 0x8C1A, 0x8513
RGBA32UI, RGBA8_SNORM, RGBA_INTEGER, UINT = 0x8D70, 0x8F97, 0x8D99, 0x1405
READ_ONLY, WRITE_ONLY, READ_WRITE = 0x88B8, 0x88B9, 0x88BA
FRAMEBUFFER, COLOR_ATTACHMENT0 = 0x8D40, 0x8CE0

VERTEX = """#version 310 es
void main() {
    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0, 1);
}
"""


def fragment(image_type, coordinate, value):
    return f"""#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) coherent writeonly uniform highp {image_type} destination;
layout(rgba32ui, binding=1) coherent readonly uniform highp {image_type} source;
layout(location=0) out highp uvec4 color;
void main() {{
    int x = int(gl_FragCoord.x);
    imageStore(destination, {coordinate}, uvec4(uint({value}+x), 4u, 5u, 6u));
    memoryBarrierImage();
    color = imageLoad(source, {coordinate});
}}
"""


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--native-dir", required=True, help="Directory containing libEGL and libGLESv2")
args = parser.parse_args()
libs = base.Libraries(args.native_dir)
p = base.Probe(libs, SimpleNamespace(backend="metal", validation=True, webgl=False,
                                     native_platform="auto"))
p.open()
for name, result, arguments in [
    ("glCreateShader", U, [U]), ("glShaderSource", None, [U, I, C.POINTER(C.c_char_p), base.IP]),
    ("glCompileShader", None, [U]), ("glGetShaderiv", None, [U, U, base.IP]),
    ("glGetShaderInfoLog", None, [U, I, base.IP, P]), ("glDeleteShader", None, [U]),
    ("glCreateProgram", U, []), ("glAttachShader", None, [U, U]), ("glLinkProgram", None, [U]),
    ("glGetProgramiv", None, [U, U, base.IP]), ("glGetProgramInfoLog", None, [U, I, base.IP, P]),
    ("glDeleteProgram", None, [U]), ("glUseProgram", None, [U]),
    ("glGetProgramBinary", None, [U, I, base.IP, base.UP, P]),
    ("glProgramBinary", None, [U, U, P, I]),
    ("glGenTextures", None, [I, base.UP]), ("glDeleteTextures", None, [I, base.UP]),
    ("glBindTexture", None, [U, U]), ("glTexStorage2D", None, [U, I, U, I, I]),
    ("glTexStorage3D", None, [U, I, U, I, I, I]),
    ("glTexSubImage2D", None, [U, I, I, I, I, I, U, U, P]),
    ("glTexSubImage3D", None, [U, I, I, I, I, I, I, I, U, U, P]),
    ("glBindImageTexture", None, [U, U, I, C.c_ubyte, I, U, U]),
    ("glGenFramebuffers", None, [I, base.UP]), ("glDeleteFramebuffers", None, [I, base.UP]),
    ("glBindFramebuffer", None, [U, U]), ("glFramebufferTexture2D", None, [U, U, U, U, I]),
    ("glCheckFramebufferStatus", U, [U]), ("glViewport", None, [I, I, I, I]),
    ("glDrawArrays", None, [U, I, I]), ("glReadPixels", None, [I, I, I, I, U, U, P]),
    ("glDispatchCompute", None, [U, U, U]), ("glMemoryBarrier", None, [U]),
    ("glGenBuffers", None, [I, base.UP]), ("glDeleteBuffers", None, [I, base.UP]),
    ("glBindBuffer", None, [U, U]), ("glBufferData", None, [U, base.S, P, U]),
    ("glBindBufferBase", None, [U, U, U]), ("glMapBufferRange", P, [U, base.S, base.S, U]),
    ("glUnmapBuffer", C.c_ubyte, [U]),
]:
    p.gl[name] = libs.function(name, result, arguments)


def image(unit, texture, layered=False, layer=0, access=READ_WRITE, fmt=RGBA32UI):
    p.glBindImageTexture(unit, texture, 0, layered, layer, access, fmt)


def expect(program, expected, name):
    p.glUseProgram(program)
    p.glDrawArrays(4, 0, 3)
    pixels = (U * 8)()
    p.glReadPixels(0, 0, 2, 1, RGBA_INTEGER, UINT, pixels)
    p.check_gl(name)
    base.require(list(pixels) == expected, f"{name}: {list(pixels)} != {expected}")
    print("IMAGE_ALIAS_CASE_PASS", name, flush=True)


def expected(value):
    return [value, 4, 5, 6, value + 1, 4, 5, 6]


def reload(program):
    length = I()
    p.glGetProgramiv(program, 0x8741, C.byref(length))
    base.require(length.value > 0, "Missing image-alias program binary")
    data, written, binary_format = C.create_string_buffer(length.value), I(), U()
    p.glGetProgramBinary(program, length.value, C.byref(written), C.byref(binary_format), data)
    restored = p.glCreateProgram()
    p.programs.append(restored)
    p.glProgramBinary(restored, binary_format, data, written.value)
    status = I()
    p.glGetProgramiv(restored, 0x8B82, C.byref(status))
    base.require(status.value, "Image-alias binary did not load")
    return restored


def compute_source(image_type, coordinate, value):
    return f"""#version 310 es
precision highp float;
precision highp int;
layout(local_size_x=2) in;
layout(rgba32ui, binding=0) coherent writeonly uniform highp {image_type} destination;
layout(rgba32ui, binding=1) coherent readonly uniform highp {image_type} source;
layout(std430, binding=0) buffer Result {{ uvec4 result[2]; }} outputData;
void main() {{
    int x = int(gl_GlobalInvocationID.x);
    imageStore(destination, {coordinate}, uvec4(uint({value}+x), 4u, 5u, 6u));
    memoryBarrierImage();
    outputData.result[x] = imageLoad(source, {coordinate});
}}
"""


def snorm_source(image_type, coordinate, compute):
    prefix = ("layout(local_size_x=2) in;\n"
              "layout(std430, binding=0) buffer Result { uvec4 result[2]; } outputData;"
              if compute else "layout(location=0) out highp uvec4 color;")
    x = "int(gl_GlobalInvocationID.x)" if compute else "int(gl_FragCoord.x)"
    result = "outputData.result[x] = encoded;" if compute else "color = encoded;"
    return f"""#version 310 es
precision highp float;
precision highp int;
layout(rgba8_snorm, binding=0) coherent writeonly uniform highp {image_type} destination;
layout(rgba8_snorm, binding=1) coherent readonly uniform highp {image_type} source;
{prefix}
void main() {{
    int x = {x};
    imageStore(destination, {coordinate}, vec4(-1.0, -64.0/127.0, 32.0/127.0, 1.0));
    memoryBarrierImage();
    ivec4 signedValues = ivec4(round(imageLoad(source, {coordinate}) * 127.0));
    uvec4 encoded = uvec4(signedValues + ivec4(128));
    {result}
}}
"""


def mixed_format_source(write_format, write_type, value, read_format, read_type, result):
    return f"""#version 310 es
precision highp float;
precision highp int;
layout({write_format}, binding=0) coherent writeonly uniform highp {write_type} destination;
layout({read_format}, binding=1) coherent readonly uniform highp {read_type} source;
layout(location=0) out highp uvec4 color;
void main() {{
    int x = int(gl_FragCoord.x);
    ivec2 pos = ivec2(x,0);
    imageStore(destination, pos, {value});
    memoryBarrierImage();
    color = {result};
}}
"""


def mixed_shape_source(write_type, write_coord, read_type, read_coord, compute):
    output = ("layout(local_size_x=2) in;\n"
              "layout(std430, binding=0) buffer Result { uvec4 result[2]; } outputData;"
              if compute else "layout(location=0) out highp uvec4 color;")
    x = "int(gl_GlobalInvocationID.x)" if compute else "int(gl_FragCoord.x)"
    store = "outputData.result[x] = observed;" if compute else "color = observed;"
    return f"""#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui,binding=0) coherent writeonly uniform highp {write_type} destination;
layout(rgba32ui,binding=1) coherent readonly uniform highp {read_type} source;
{output}
void main() {{
    int x = {x};
    imageStore(destination, {write_coord}, uvec4(uint(90+x),4u,5u,6u));
    memoryBarrierImage();
    uvec4 observed = imageLoad(source, {read_coord});
    {store}
}}
"""


def expect_compute(program, buffer, wanted, name):
    p.glBindBuffer(0x90D2, buffer)
    p.glBindBufferBase(0x90D2, 0, buffer)
    p.glUseProgram(program)
    p.glDispatchCompute(1, 1, 1)
    p.glMemoryBarrier(0x200 | 0x20)
    address = p.glMapBufferRange(0x90D2, 0, 8 * C.sizeof(U), 1)
    base.require(address, f"{name}: cannot map result")
    actual = list(C.cast(address, C.POINTER(U * 8)).contents)
    base.require(p.glUnmapBuffer(0x90D2), f"{name}: cannot unmap result")
    p.check_gl(name)
    base.require(actual == wanted, f"{name}: {actual} != {wanted}")
    print("IMAGE_ALIAS_CASE_PASS", name, flush=True)


try:
    base.require(p.minor == 1, "GLES 3.1 is unavailable")
    textures = (U * 18)()
    p.glGenTextures(len(textures), textures)
    for texture in textures[:3]:
        p.glBindTexture(TEXTURE_2D, texture)
        p.glTexStorage2D(TEXTURE_2D, 1, RGBA32UI, 4, 1)
    p.glBindTexture(TEXTURE_2D, textures[1])
    values = (U * 8)(17, 4, 5, 6, 18, 4, 5, 6)
    p.glTexSubImage2D(TEXTURE_2D, 0, 0, 0, 2, 1, RGBA_INTEGER, UINT, values)
    framebuffer = U()
    p.glGenFramebuffers(1, C.byref(framebuffer))
    p.glBindFramebuffer(FRAMEBUFFER, framebuffer)
    p.glFramebufferTexture2D(FRAMEBUFFER, COLOR_ATTACHMENT0, TEXTURE_2D, textures[2], 0)
    base.require(p.glCheckFramebufferStatus(FRAMEBUFFER) == 0x8CD5, "Framebuffer incomplete")
    p.glViewport(0, 0, 2, 1)

    image(0, textures[0], access=WRITE_ONLY)
    image(1, textures[0], access=READ_ONLY)
    program = p.program([(0x8B31, VERTEX), (0x8B30, fragment("uimage2D", "ivec2(x,0)", 30))])
    expect(program, expected(30), "fragment_2d_two_units")
    image(1, textures[1], access=READ_ONLY)
    expect(program, expected(17), "rebind_to_distinct_texture")
    image(1, textures[0], access=READ_ONLY)
    expect(program, expected(30), "rebind_to_alias")
    expect(reload(program), expected(30), "writable_alias_binary_reload")

    helper_shader = """#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D destination;
layout(rgba32ui, binding=1) coherent readonly uniform highp uimage2D source;
layout(location=0) out highp uvec4 color;
void put(coherent writeonly highp uimage2D image, ivec2 p, uvec4 v) {
    imageStore(image, p, v);
}
uvec4 fetch(coherent readonly highp uimage2D image, ivec2 p) {
    return imageLoad(image, p);
}
void main() {
    ivec2 p = ivec2(int(gl_FragCoord.x), 0);
    put(destination, p, uvec4(uint(35 + p.x), 4, 5, 6));
    put(destination, ivec2(-1, 0), uvec4(99));
    memoryBarrierImage();
    uvec4 v = fetch(source, p);
    uvec4 outside = fetch(source, ivec2(4, 0));
    color = v + uvec4(uint(imageSize(source).x == 4 && imageSize(source).y == 1),
                      outside.x, outside.y, 0);
}
"""
    helper_program = p.program([(0x8B31, VERTEX), (0x8B30, helper_shader)])
    expect(helper_program, [36, 4, 5, 6, 37, 4, 5, 6], "helper_arguments_size_and_bounds")

    arrays = """#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) coherent readonly uniform highp uimage2D source[2];
layout(rgba32ui, binding=2) coherent writeonly uniform highp uimage2D destination[2];
layout(location=0) out highp uvec4 color;
void main() {
    ivec2 pos = ivec2(int(gl_FragCoord.x), 0);
    imageStore(destination[0], pos, uvec4(uint(100+pos.x), 1, 2, 3));
    imageStore(destination[1], pos, uvec4(uint(200+pos.x), 4, 5, 6));
    memoryBarrierImage();
    color = imageLoad(source[0], pos) + imageLoad(source[1], pos);
}
"""
    for unit, texture in enumerate((textures[0], textures[1], textures[0], textures[1])):
        image(unit, texture)
    array_program = p.program([(0x8B31, VERTEX), (0x8B30, arrays)])
    expect(array_program, [300, 5, 7, 9, 302, 5, 7, 9], "two_independent_alias_groups_in_arrays")

    readwrite_images = """#version 310 es
precision highp float;
precision highp int;
layout(r32ui, binding=0) coherent uniform highp uimage2D images[4];
layout(location=0) out highp uvec4 color;
void main() {
    ivec2 pos = ivec2(int(gl_FragCoord.x), 0);
    uvec4 value = uvec4(uint(90 + pos.x), 1u, 2u, 3u);
    imageStore(images[0], pos, value);
    imageStore(images[1], pos, value);
    imageStore(images[2], pos, value);
    imageStore(images[3], pos, value);
    memoryBarrierImage();
    color = imageLoad(images[0], pos) + imageLoad(images[1], pos) +
            imageLoad(images[2], pos) + imageLoad(images[3], pos);
}
"""
    rw_textures = (U * 4)()
    p.glGenTextures(4, rw_textures)
    for unit, texture in enumerate(rw_textures):
        p.glBindTexture(TEXTURE_2D, texture)
        p.glTexStorage2D(TEXTURE_2D, 1, 0x8236, 4, 1)  # GL_R32UI
        image(unit, texture, fmt=0x8236)
    rw_program = p.program([(0x8B31, VERTEX), (0x8B30, readwrite_images)])
    expect(rw_program, [360, 0, 0, 4, 364, 0, 0, 4], "four_readwrite_images_distinct")
    for unit in range(4):
        image(unit, rw_textures[0], fmt=0x8236)
    expect(rw_program, [360, 0, 0, 4, 364, 0, 0, 4], "four_readwrite_images_aliased")

    readwrite_helper = """#version 310 es
precision highp float;
precision highp int;
layout(r32ui, binding=0) coherent uniform highp uimage2D destination;
layout(location=0) out highp uvec4 color;
void put(coherent highp uimage2D image, ivec2 p, uvec4 v) { imageStore(image, p, v); }
uvec4 fetch(coherent highp uimage2D image, ivec2 p) { return imageLoad(image, p); }
void main() {
    ivec2 p = ivec2(int(gl_FragCoord.x), 0);
    put(destination, p, uvec4(uint(99 + p.x), 0, 0, 0));
    memoryBarrierImage();
    color = fetch(destination, p);
}
"""
    rw_helper_program = p.program([(0x8B31, VERTEX), (0x8B30, readwrite_helper)])
    expect(rw_helper_program, [99, 0, 0, 1, 100, 0, 0, 1], "readwrite_helper_arguments")

    p.glBindTexture(TEXTURE_2D, textures[17])
    p.glTexStorage2D(TEXTURE_2D, 2, RGBA32UI, 4, 2)
    p.glTexSubImage2D(TEXTURE_2D, 1, 0, 0, 2, 1, RGBA_INTEGER, UINT, values)
    p.glBindImageTexture(0, textures[17], 0, False, 0, WRITE_ONLY, RGBA32UI)
    p.glBindImageTexture(1, textures[17], 1, False, 0, READ_ONLY, RGBA32UI)
    program = p.program([(0x8B31, VERTEX), (0x8B30, fragment("uimage2D", "ivec2(x,0)", 30))])
    expect(program, expected(17), "independent_mip_levels")

    vertex = """#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D destination;
layout(rgba32ui, binding=1) coherent readonly uniform highp uimage2D source;
flat out highp uvec4 value;
void main() {
    ivec2 pos = ivec2(gl_VertexID, 0);
    imageStore(destination, pos, uvec4(71u, 4u, 5u, 6u));
    memoryBarrierImage();
    value = imageLoad(source, pos);
    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
    gl_Position = vec4(p, 0, 1);
}
"""
    vertex_frag = """#version 310 es
precision highp float;
precision highp int;
flat in highp uvec4 value;
layout(location=0) out highp uvec4 color;
void main() { color = value; }
"""
    image(0, textures[0], access=WRITE_ONLY)
    image(1, textures[0], access=READ_ONLY)
    vertex_program = p.program([(0x8B31, vertex), (0x8B30, vertex_frag)])
    expect(vertex_program, [71, 4, 5, 6] * 2, "vertex_alias")

    result_buffer = U()
    p.glGenBuffers(1, C.byref(result_buffer))
    p.glBindBuffer(0x90D2, result_buffer)
    p.glBufferData(0x90D2, 8 * C.sizeof(U), None, 0x88E8)
    image(0, textures[0], access=WRITE_ONLY)
    image(1, textures[0], access=READ_ONLY)
    compute = p.program([(0x91B9, compute_source("uimage2D", "ivec2(x,0)", 80))])
    expect_compute(compute, result_buffer, expected(80), "compute_2d_alias")
    coherent_group = """#version 310 es
precision highp int;
layout(local_size_x=2) in;
layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D destination;
layout(rgba32ui, binding=1) coherent readonly uniform highp uimage2D source;
layout(std430, binding=0) buffer Result { uvec4 result[2]; } outputData;
void main() {
    int x = int(gl_LocalInvocationID.x);
    imageStore(destination, ivec2(x,0), uvec4(uint(80+x), 4, 5, 6));
    memoryBarrierImage();
    barrier();
    outputData.result[x] = imageLoad(source, ivec2(1-x,0));
}
"""
    group_program = p.program([(0x91B9, coherent_group)])
    expect_compute(group_program, result_buffer, [81, 4, 5, 6, 80, 4, 5, 6],
                   "compute_coherent_workgroup_exchange")
    image(1, textures[1], access=READ_ONLY)
    expect_compute(compute, result_buffer, expected(200), "compute_rebind_distinct")
    image(1, textures[0], access=READ_ONLY)
    expect_compute(reload(compute), result_buffer, expected(80), "compute_alias_binary_reload")

    p.glBindTexture(TEXTURE_3D, textures[3])
    p.glTexStorage3D(TEXTURE_3D, 1, RGBA32UI, 4, 1, 3)
    p.glBindTexture(TEXTURE_ARRAY, textures[4])
    p.glTexStorage3D(TEXTURE_ARRAY, 1, RGBA32UI, 4, 1, 3)
    p.glBindTexture(TEXTURE_CUBE, textures[5])
    p.glTexStorage2D(TEXTURE_CUBE, 1, RGBA32UI, 4, 4)
    cases = [
        (textures[3], False, 1, "uimage2D", "ivec2(x,0)", 40, "3d_slice"),
        (textures[3], True, 0, "uimage3D", "ivec3(x,0,1)", 50, "layered_3d"),
        (textures[4], True, 0, "uimage2DArray", "ivec3(x,0,1)", 60, "layered_2d_array"),
        (textures[5], True, 0, "uimageCube", "ivec3(x,0,1)", 70, "layered_cube"),
    ]
    for texture, layered, layer, image_type, coordinate, value, name in cases:
        image(0, texture, layered, layer, WRITE_ONLY)
        image(1, texture, layered, layer, READ_ONLY)
        program = p.program([(0x8B31, VERTEX), (0x8B30, fragment(image_type, coordinate, value))])
        expect(program, expected(value), name)
    for texture, layered, layer, image_type, coordinate, value, name in cases:
        image(0, texture, layered, layer, WRITE_ONLY)
        image(1, texture, layered, layer, READ_ONLY)
        program = p.program([(0x91B9, compute_source(image_type, coordinate, value))])
        expect_compute(program, result_buffer, expected(value), "compute_" + name)
    for texture, layered_type, name in ((textures[3], "uimage3D", "3d"),
                                        (textures[4], "uimage2DArray", "array"),
                                        (textures[5], "uimageCube", "cube")):
        for reverse in (False, True):
            write_type = layered_type if reverse else "uimage2D"
            read_type = "uimage2D" if reverse else layered_type
            write_coord = "ivec3(x,0,1)" if reverse else "ivec2(x,0)"
            read_coord = "ivec2(x,0)" if reverse else "ivec3(x,0,1)"
            image(0, texture, reverse, 1, WRITE_ONLY)
            image(1, texture, not reverse, 1, READ_ONLY)
            name_with_direction = name + ("_layered_to_slice" if reverse else "_slice_to_layered")
            source = mixed_shape_source(write_type, write_coord, read_type, read_coord, False)
            program = p.program([(0x8B31, VERTEX), (0x8B30, source)])
            expect(program, expected(90), name_with_direction)
            source = mixed_shape_source(write_type, write_coord, read_type, read_coord, True)
            program = p.program([(0x91B9, source)])
            expect_compute(program, result_buffer, expected(90), "compute_" + name_with_direction)

    p.glBindTexture(TEXTURE_2D, textures[6])
    p.glTexStorage2D(TEXTURE_2D, 1, RGBA8_SNORM, 4, 1)
    p.glBindTexture(TEXTURE_3D, textures[7])
    p.glTexStorage3D(TEXTURE_3D, 1, RGBA8_SNORM, 4, 1, 3)
    p.glBindTexture(TEXTURE_ARRAY, textures[8])
    p.glTexStorage3D(TEXTURE_ARRAY, 1, RGBA8_SNORM, 4, 1, 3)
    p.glBindTexture(TEXTURE_CUBE, textures[9])
    p.glTexStorage2D(TEXTURE_CUBE, 1, RGBA8_SNORM, 4, 4)
    snorm_cases = [
        (textures[6], False, 0, "image2D", "ivec2(x,0)", "2d"),
        (textures[7], False, 1, "image2D", "ivec2(x,0)", "3d_slice"),
        (textures[7], True, 0, "image3D", "ivec3(x,0,1)", "layered_3d"),
        (textures[8], True, 0, "image2DArray", "ivec3(x,0,1)", "layered_2d_array"),
        (textures[9], True, 0, "imageCube", "ivec3(x,0,1)", "layered_cube"),
    ]
    for texture, layered, layer, image_type, coordinate, name in snorm_cases:
        image(0, texture, layered, layer, WRITE_ONLY, RGBA8_SNORM)
        image(1, texture, layered, layer, READ_ONLY, RGBA8_SNORM)
        program = p.program([(0x8B31, VERTEX), (0x8B30, snorm_source(image_type, coordinate, False))])
        expect(program, [1, 64, 160, 255] * 2, "snorm_" + name)
        program = p.program([(0x91B9, snorm_source(image_type, coordinate, True))])
        expect_compute(program, result_buffer, [1, 64, 160, 255] * 2, "compute_snorm_" + name)
    raw_reader = """#version 310 es
precision highp float;
precision highp int;
layout(r32ui, binding=0) readonly uniform highp uimage2D source;
layout(location=0) out highp uvec4 color;
void main() {
    color = uvec4(imageLoad(source, ivec2(int(gl_FragCoord.x), 0)).x, 4u, 5u, 6u);
}
"""
    image(0, textures[6], access=READ_ONLY, fmt=0x8236)  # GL_R32UI
    program = p.program([(0x8B31, VERTEX), (0x8B30, raw_reader)])
    expect(program, [0x7f20c081, 4, 5, 6] * 2, "snorm_independent_raw_readback")
    for texture, fmt in ((textures[10], 0x8D7C), (textures[11], 0x881A),
                         (textures[12], 0x8814), (textures[13], 0x8D8E),
                         (textures[14], 0x8D88), (textures[15], 0x8235),
                         (textures[16], 0x8D82)):
        p.glBindTexture(TEXTURE_2D, texture)
        p.glTexStorage2D(TEXTURE_2D, 1, fmt, 4, 1)
    mixed_cases = [
        (textures[10], 0x8D7C, 0x8236, "rgba8ui", "uimage2D",
         "uvec4(uint(1+x),2u,3u,4u)", "r32ui", "uimage2D",
         "uvec4(imageLoad(source,pos).x,4u,5u,6u)",
         [0x04030201, 4, 5, 6, 0x04030202, 4, 5, 6], "rgba8ui_to_r32ui"),
        (textures[10], 0x8236, 0x8D7C, "r32ui", "uimage2D",
         "uvec4(0x44332211u+uint(x))", "rgba8ui", "uimage2D",
         "imageLoad(source,pos)", [17, 34, 51, 68, 18, 34, 51, 68], "r32ui_to_rgba8ui"),
        (textures[10], 0x8058, 0x8D7C, "rgba8", "image2D",
         "vec4(1.0,0.0,64.0/255.0,1.0)", "rgba8ui", "uimage2D",
         "imageLoad(source,pos)", [255, 0, 64, 255] * 2, "rgba8_to_rgba8ui"),
        (textures[6], RGBA8_SNORM, 0x8236, "rgba8_snorm", "image2D",
         "vec4(-1.0,-64.0/127.0,32.0/127.0,1.0)", "r32ui", "uimage2D",
         "uvec4(imageLoad(source,pos).x,4u,5u,6u)",
         [0x7f20c081, 4, 5, 6] * 2, "snorm_to_r32ui"),
        (textures[11], 0x881A, 0x8D76, "rgba16f", "image2D",
         "vec4(1.0,-2.0,0.5,0.0)", "rgba16ui", "uimage2D",
         "imageLoad(source,pos)", [0x3c00, 0xc000, 0x3800, 0] * 2, "rgba16f_to_rgba16ui"),
        (textures[12], 0x8814, 0x8D70, "rgba32f", "image2D",
         "vec4(1.0,-2.0,0.5,0.0)", "rgba32ui", "uimage2D",
         "imageLoad(source,pos)", [0x3f800000, 0xc0000000, 0x3f000000, 0] * 2, "rgba32f_to_rgba32ui"),
        (textures[13], 0x8D8E, 0x8D7C, "rgba8i", "iimage2D",
         "ivec4(-200,-1,127,200)", "rgba8ui", "uimage2D",
         "imageLoad(source,pos)", [128, 255, 127, 127] * 2, "rgba8i_to_rgba8ui"),
        (textures[14], 0x8D88, 0x8D76, "rgba16i", "iimage2D",
         "ivec4(-40000,-1,32767,40000)", "rgba16ui", "uimage2D",
         "imageLoad(source,pos)", [32768, 65535, 32767, 32767] * 2, "rgba16i_to_rgba16ui"),
        (textures[15], 0x8235, 0x8236, "r32i", "iimage2D",
         "ivec4(-123)", "r32ui", "uimage2D",
         "imageLoad(source,pos)", [0xffffff85, 0, 0, 1] * 2, "r32i_to_r32ui"),
        (textures[15], 0x822E, 0x8236, "r32f", "image2D",
         "vec4(-2.0)", "r32ui", "uimage2D",
         "imageLoad(source,pos)", [0xc0000000, 0, 0, 1] * 2, "r32f_to_r32ui"),
        (textures[16], 0x8D82, 0x8D70, "rgba32i", "iimage2D",
         "ivec4(-1,-2,0,42)", "rgba32ui", "uimage2D",
         "imageLoad(source,pos)", [0xffffffff, 0xfffffffe, 0, 42] * 2, "rgba32i_to_rgba32ui"),
    ]
    for texture, write_fmt, read_fmt, write_layout, write_type, value, read_layout, read_type, result, wanted, name in mixed_cases:
        image(0, texture, access=WRITE_ONLY, fmt=write_fmt)
        image(1, texture, access=READ_ONLY, fmt=read_fmt)
        source = mixed_format_source(write_layout, write_type, value, read_layout, read_type, result)
        program = p.program([(0x8B31, VERTEX), (0x8B30, source)])
        expect(program, wanted, name)
    p.glDeleteBuffers(1, C.byref(result_buffer))
    p.glDeleteFramebuffers(1, C.byref(framebuffer))
    p.glDeleteTextures(len(rw_textures), rw_textures)
    p.glDeleteTextures(len(textures), textures)
    print("METAL_IMAGE_ALIAS_PASS", flush=True)
finally:
    p.close()
