#!/usr/bin/env python3
"""Exercise graphics image load/store through ANGLE's public GLES API."""
import argparse
import ctypes as C
import importlib.util
from pathlib import Path
from types import SimpleNamespace

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ray_probe', root / 'tests/nge-ray-query-probe.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
U, I, P = base.U, base.I, base.P

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native-dir', required=True, help='Directory containing libEGL and libGLESv2')
options = parser.parse_args()
native_dir = Path(options.native_dir)
libs = base.Libraries(native_dir)
p = base.Probe(libs, SimpleNamespace(backend='metal', validation=True, webgl=False,
                                     native_platform='auto'))
p.open()
commands = [
    ('glCreateShader', U, [U]), ('glShaderSource', None, [U, I, C.POINTER(C.c_char_p), base.IP]),
    ('glCompileShader', None, [U]), ('glGetShaderiv', None, [U, U, base.IP]),
    ('glGetShaderInfoLog', None, [U, I, base.IP, P]), ('glDeleteShader', None, [U]),
    ('glCreateProgram', U, []), ('glAttachShader', None, [U, U]), ('glLinkProgram', None, [U]),
    ('glGetProgramiv', None, [U, U, base.IP]), ('glGetProgramInfoLog', None, [U, I, base.IP, P]),
    ('glGetProgramBinary', None, [U, I, base.IP, base.UP, P]),
    ('glProgramBinary', None, [U, U, P, I]),
    ('glDeleteProgram', None, [U]), ('glUseProgram', None, [U]),
    ('glProgramParameteri', None, [U, U, I]),
    ('glGenProgramPipelines', None, [I, base.UP]), ('glBindProgramPipeline', None, [U]),
    ('glUseProgramStages', None, [U, U, U]), ('glDeleteProgramPipelines', None, [I, base.UP]),
    ('glGetUniformLocation', I, [U, C.c_char_p]), ('glUniform1i', None, [I, I]),
    ('glUniform1iv', None, [I, I, base.IP]), ('glActiveTexture', None, [U]),
    ('glGenTextures', None, [I, base.UP]), ('glBindTexture', None, [U, U]),
    ('glDeleteTextures', None, [I, base.UP]), ('glTexStorage2D', None, [U, I, U, I, I]),
    ('glTexSubImage2D', None, [U, I, I, I, I, I, U, U, P]),
    ('glTexParameteri', None, [U, U, I]),
    ('glTexStorage3D', None, [U, I, U, I, I, I]),
    ('glBindImageTexture', None, [U, U, I, C.c_ubyte, I, U, U]),
    ('glGenFramebuffers', None, [I, base.UP]), ('glBindFramebuffer', None, [U, U]),
    ('glFramebufferTexture2D', None, [U, U, U, U, I]), ('glCheckFramebufferStatus', U, [U]),
    ('glFramebufferTextureLayer', None, [U, U, U, I, I]),
    ('glDeleteFramebuffers', None, [I, base.UP]), ('glViewport', None, [I, I, I, I]),
    ('glDrawArrays', None, [U, I, I]), ('glMemoryBarrier', None, [U]),
    ('glDispatchCompute', None, [U, U, U]),
    ('glGenBuffers', None, [I, base.UP]), ('glDeleteBuffers', None, [I, base.UP]),
    ('glBindBuffer', None, [U, U]), ('glBufferData', None, [U, base.S, P, U]),
    ('glBindBufferBase', None, [U, U, U]), ('glMapBufferRange', P, [U, base.S, base.S, U]),
    ('glUnmapBuffer', C.c_ubyte, [U]),
    ('glReadPixels', None, [I, I, I, I, U, U, P]),
]
for name, result, args in commands:
    p.gl[name] = libs.function(name, result, args)

vert = '''#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) writeonly uniform highp uimage2D vertexImage;
void main() {
  imageStore(vertexImage, ivec2(gl_VertexID, 0), uvec4(uint(10 + gl_VertexID), 1u, 2u, 3u));
  vec2 pos = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
  gl_Position = vec4(pos, 0, 1);
}'''
frag = '''#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=1) writeonly uniform highp uimage2D fragmentImage;
layout(location=0) out highp uvec4 color;
void main() {
  int x = int(gl_FragCoord.x);
  imageStore(fragmentImage, ivec2(x, 0), uvec4(uint(20 + x), 4u, 5u, 6u));
  color = uvec4(1, 2, 3, 4);
}'''
read_vert = '''#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) readonly uniform highp uimage2D vertexImage;
flat out highp uint vertexValue;
void main() {
  vertexValue = imageLoad(vertexImage, ivec2(0, 0)).x;
  vec2 pos = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
  gl_Position = vec4(pos, 0, 1);
}'''
read_frag = '''#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=1) readonly uniform highp uimage2D fragmentImage;
flat in highp uint vertexValue;
layout(location=0) out highp uvec4 color;
void main() {
  color = uvec4(vertexValue, imageLoad(fragmentImage, ivec2(int(gl_FragCoord.x), 0)).x, 7u, 8u);
}'''
alias_frag = '''#version 310 es
precision highp float;
precision highp int;
layout(rgba32ui, binding=0) coherent writeonly uniform highp uimage2D firstImage;
layout(rgba32ui, binding=0) coherent readonly uniform highp uimage2D secondImage;
layout(location=0) out highp uvec4 color;
void main() {
  ivec2 pixel = ivec2(int(gl_FragCoord.x), 0);
  imageStore(firstImage, pixel, uvec4(uint(30 + pixel.x), 9u, 8u, 7u));
  memoryBarrierImage();
  color = imageLoad(secondImage, pixel);
}'''

try:
    limits = []
    for key in (0x90CA, 0x90CE, 0x91BD):
        value = I(); p.glGetIntegerv(key, C.byref(value)); limits.append(value.value)
    print('IMAGE_LIMITS vertex=%d fragment=%d compute=%d' % tuple(limits), flush=True)
    base.require(p.minor == 1 and min(limits[:2]) >= 1, 'Graphics image uniforms unavailable')
    program = p.program([(0x8B31, vert), (0x8B30, frag)])
    textures = (U * 3)(); p.glGenTextures(3, textures)
    for texture in textures:
        p.glBindTexture(0x0DE1, texture); p.glTexStorage2D(0x0DE1, 1, 0x8D70, 4, 1)
    for unit in range(2):
        p.glBindImageTexture(unit, textures[unit], 0, False, 0, 0x88BA, 0x8D70)
    framebuffer = U(); p.glGenFramebuffers(1, C.byref(framebuffer))
    p.glBindFramebuffer(0x8D40, framebuffer)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    base.require(p.glCheckFramebufferStatus(0x8D40) == 0x8CD5, 'Framebuffer incomplete')
    p.glViewport(0, 0, 2, 1); p.glUseProgram(program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    reader = p.program([(0x8B31, read_vert), (0x8B30, read_frag)])
    for unit in range(2):
        p.glBindImageTexture(unit, textures[unit], 0, False, 0, 0x88B8, 0x8D70)
    p.glUseProgram(reader); p.glDrawArrays(4, 0, 3)
    read_pixels = (U * 8)()
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image load')
    base.require(list(read_pixels) == [10, 20, 7, 8, 10, 21, 7, 8],
                 f'graphics image load differs: {list(read_pixels)}')
    vertex_location = p.glGetUniformLocation(reader, b'vertexImage')
    fragment_location = p.glGetUniformLocation(reader, b'fragmentImage')
    print('IMAGE_UNIFORM_LOCATIONS', vertex_location, fragment_location, flush=True)
    p.check_gl('graphics image uniform locations')
    p.glUniform1i(vertex_location, 1)
    base.require(p.glGetError() == 0x502, 'GLES 3.1 image uniforms must reject glUniform1i')
    for unit in range(2):
        p.glBindImageTexture(unit, textures[1 - unit], 0, False, 0, 0x88B8, 0x8D70)
    p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image texture rebinding')
    base.require(list(read_pixels) == [20, 10, 7, 8, 20, 11, 7, 8],
                 f'graphics image rebinding differs: {list(read_pixels)}')
    for index, expected in ((0, [10, 1, 2, 3, 11, 1, 2, 3, 12, 1, 2, 3]),
                            (1, [20, 4, 5, 6, 21, 4, 5, 6])):
        p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[index], 0)
        base.require(p.glCheckFramebufferStatus(0x8D40) == 0x8CD5, 'Image framebuffer incomplete')
        pixels = (U * len(expected))()
        p.glReadPixels(0, 0, len(expected) // 4, 1, 0x8D99, 0x1405, pixels)
        p.check_gl('image readback')
        base.require(list(pixels) == expected, f'image {index}: {list(pixels)} != {expected}')
    simple_vert = '''#version 310 es
    void main() {
      vec2 pos = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
      gl_Position = vec4(pos, 0, 1);
    }'''
    # Verify writable aliases use one native read/write resource, including
    # aliases through different GL image units and subsequent rebinding.
    alias = p.program([(0x8B31, simple_vert), (0x8B30, alias_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, textures[0], 0, False, 0, 0x88BA, 0x8D70)
    p.glUseProgram(alias); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image alias on one unit')
    base.require(list(read_pixels) == [30, 9, 8, 7, 31, 9, 8, 7],
                 f'image alias on one unit differs: {list(read_pixels)}')
    dual_alias = p.program([(0x8B31, simple_vert), (0x8B30, alias_frag.replace(
        'binding=0) coherent readonly', 'binding=1) coherent readonly'))])
    p.glBindImageTexture(1, textures[0], 0, False, 0, 0x88BA, 0x8D70)
    p.glUseProgram(dual_alias); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image alias across units')
    base.require(list(read_pixels) == [30, 9, 8, 7, 31, 9, 8, 7],
                 f'image alias across units differs: {list(read_pixels)}')
    p.glBindImageTexture(1, textures[1], 0, False, 0, 0x88B8, 0x8D70)
    p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image draw after alias rebinding')
    base.require(list(read_pixels) == [20, 4, 5, 6, 21, 4, 5, 6],
                 f'graphics image draw after rebinding differs: {list(read_pixels)}')
    read_alias_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui, binding=0) readonly uniform highp uimage2D a;
    layout(rgba32ui, binding=1) readonly uniform highp uimage2D b;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 pixel = ivec2(int(gl_FragCoord.x), 0);
      color = imageLoad(a, pixel) + imageLoad(b, pixel);
    }'''
    read_alias = p.program([(0x8B31, simple_vert), (0x8B30, read_alias_frag)])
    p.glBindImageTexture(0, textures[0], 0, False, 0, 0x88BA, 0x8D70)
    p.glBindImageTexture(1, textures[0], 0, False, 0, 0x88B8, 0x8D70)
    p.glUseProgram(read_alias); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('read-only graphics image aliases')
    base.require(list(read_pixels) == [60, 18, 16, 14, 62, 18, 16, 14],
                 f'read-only graphics image aliases differ: {list(read_pixels)}')
    binary_size = I(); p.glGetProgramiv(read_alias, 0x8741, C.byref(binary_size))
    base.require(binary_size.value > 0, 'Read-only image program binary unavailable')
    binary = C.create_string_buffer(binary_size.value); written = I(); binary_format = U()
    p.glGetProgramBinary(read_alias, binary_size.value, C.byref(written),
                         C.byref(binary_format), binary)
    restored_alias = p.glCreateProgram(); p.programs.append(restored_alias)
    p.glProgramBinary(restored_alias, binary_format, binary, written.value)
    restored_status = I(); p.glGetProgramiv(restored_alias, 0x8B82, C.byref(restored_status))
    base.require(restored_status.value, 'Cannot restore read-only image program')
    p.glUseProgram(restored_alias); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('restored read-only image aliases')
    base.require(list(read_pixels) == [60, 18, 16, 14, 62, 18, 16, 14],
                 'Read-only image qualifiers were lost on binary reload')
    read_array_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui, binding=0) readonly uniform highp uimage2D images[2];
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 pixel = ivec2(int(gl_FragCoord.x), 0);
      color = imageLoad(images[0], pixel) + imageLoad(images[1], pixel);
    }'''
    read_array = p.program([(0x8B31, simple_vert), (0x8B30, read_array_frag)])
    p.glUseProgram(read_array); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('read-only image array aliases')
    base.require(list(read_pixels) == [60, 18, 16, 14, 62, 18, 16, 14],
                 f'Read-only image array differs: {list(read_pixels)}')
    rw_alias_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(r32ui, binding=0) uniform highp uimage2D a;
    layout(r32ui, binding=1) uniform highp uimage2D b;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 pixel = ivec2(int(gl_FragCoord.x), 0);
      color = imageLoad(a, pixel) + imageLoad(b, pixel);
    }'''
    rw_texture = U(); p.glGenTextures(1, C.byref(rw_texture)); p.glBindTexture(0x0DE1, rw_texture)
    p.glTexStorage2D(0x0DE1, 1, 0x8236, 2, 1)  # GL_R32UI
    initial = (U * 2)(5, 6)
    p.glTexSubImage2D(0x0DE1, 0, 0, 0, 2, 1, 0x8D94, 0x1405, initial)
    rw_alias = p.program([(0x8B31, simple_vert), (0x8B30, rw_alias_frag)])
    for unit in range(2):
        p.glBindImageTexture(unit, rw_texture, 0, False, 0, 0x88B8, 0x8236)
    p.glUseProgram(rw_alias); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('read/write shader arguments bound read-only')
    base.require(read_pixels[0] == 10 and read_pixels[4] == 12,
                 f'read/write shader arguments differ: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(rw_texture))
    sampler_alias_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui, binding=0) writeonly uniform highp uimage2D image;
    uniform highp usampler2D sampled;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 pixel = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, pixel, uvec4(77u));
      color = texelFetch(sampled, pixel, 0);
    }'''
    sampler_alias = p.program([(0x8B31, simple_vert), (0x8B30, sampler_alias_frag)])
    p.glActiveTexture(0x84C0); p.glBindTexture(0x0DE1, textures[0])
    p.glTexParameteri(0x0DE1, 0x2801, 0x2600)  # GL_TEXTURE_MIN_FILTER, GL_NEAREST
    p.glTexParameteri(0x0DE1, 0x2800, 0x2600)  # GL_TEXTURE_MAG_FILTER, GL_NEAREST
    p.glBindImageTexture(0, textures[0], 0, False, 0, 0x88B9, 0x8D70)
    p.glUseProgram(sampler_alias); p.glDrawArrays(4, 0, 3)
    base.require(p.glGetError() == 0x502, 'sampling a writable image must be rejected')
    p.glBindTexture(0x0DE1, textures[1])
    p.glTexParameteri(0x0DE1, 0x2801, 0x2600)
    p.glTexParameteri(0x0DE1, 0x2800, 0x2600)
    p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image and different sampled texture')
    base.require(list(read_pixels) == [20, 4, 5, 6, 21, 4, 5, 6],
                 f'graphics image and sampler differ: {list(read_pixels)}')
    array_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D images[2];
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(images[0], p, uvec4(uint(40+p.x), 1u, 2u, 3u));
      imageStore(images[1], p, uvec4(uint(50+p.x), 4u, 5u, 6u));
      color = uvec4(1, 2, 3, 4);
    }'''
    array_program = p.program([(0x8B31, simple_vert), (0x8B30, array_frag)])
    for unit in range(2):
        p.glBindImageTexture(unit, textures[unit], 0, False, 0, 0x88B9, 0x8D70)
    p.glUseProgram(array_program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    for unit, expected in ((0, [40, 1, 2, 3, 41, 1, 2, 3]),
                           (1, [50, 4, 5, 6, 51, 4, 5, 6])):
        p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[unit], 0)
        p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
        p.check_gl('graphics image array')
        base.require(list(read_pixels) == expected, f'image array {unit}: {list(read_pixels)}')
    layered = U(); p.glGenTextures(1, C.byref(layered)); p.glBindTexture(0x806F, layered)
    p.glTexStorage3D(0x806F, 1, 0x8D70, 4, 1, 3)
    layer_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D image;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, p, uvec4(uint(60+p.x), 1u, 2u, 3u));
      color = uvec4(uvec2(imageSize(image)), 0u, 1u);
    }'''
    layer_program = p.program([(0x8B31, simple_vert), (0x8B30, layer_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, layered, 0, False, 2, 0x88B9, 0x8D70)
    p.glUseProgram(layer_program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('image layer size')
    base.require(list(read_pixels) == [4, 1, 0, 1] * 2,
                 f'image layer size differs: {list(read_pixels)}')
    p.glFramebufferTextureLayer(0x8D40, 0x8CE0, layered, 0, 2)
    base.require(p.glCheckFramebufferStatus(0x8D40) == 0x8CD5, 'Layer framebuffer incomplete')
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('graphics image 3D slice')
    base.require(list(read_pixels) == [60, 1, 2, 3, 61, 1, 2, 3],
                 f'image 3D slice differs: {list(read_pixels)}')
    constant_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D image;
    layout(location=0) out highp uvec4 color;
    void main() {
      imageStore(image, ivec2(0), uvec4(61, 2, 3, 4));
      color = uvec4(uvec2(imageSize(image)), 0u, 1u);
    }'''
    constant_program = p.program([(0x8B31, simple_vert), (0x8B30, constant_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, layered, 0, False, 2, 0x88B9, 0x8D70)
    p.glUseProgram(constant_program); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('image-only shader metadata')
    base.require(list(read_pixels) == [4, 1, 0, 1] * 2,
                 f'image-only shader metadata differs: {list(read_pixels)}')
    full_layer_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage3D image;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, ivec3(p, 1), uvec4(uint(70+p.x), 2u, 3u, 4u));
      color = uvec4(uvec3(imageSize(image)), 1u);
    }'''
    full_layer_program = p.program([(0x8B31, simple_vert), (0x8B30, full_layer_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, layered, 0, True, 0, 0x88B9, 0x8D70)
    p.glUseProgram(full_layer_program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('layered 3D image size')
    base.require(list(read_pixels) == [4, 1, 3, 1] * 2,
                 f'layered 3D image size differs: {list(read_pixels)}')
    p.glFramebufferTextureLayer(0x8D40, 0x8CE0, layered, 0, 1)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('layered 3D image contents')
    base.require(list(read_pixels) == [70, 2, 3, 4, 71, 2, 3, 4],
                 f'layered 3D image differs: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(layered))
    array_texture = U(); p.glGenTextures(1, C.byref(array_texture)); p.glBindTexture(0x8C1A, array_texture)
    p.glTexStorage3D(0x8C1A, 1, 0x8D70, 4, 1, 3)
    array_layer_frag = full_layer_frag.replace('uimage3D', 'uimage2DArray').replace('70+p.x', '80+p.x')
    array_layer_program = p.program([(0x8B31, simple_vert), (0x8B30, array_layer_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, array_texture, 0, True, 0, 0x88B9, 0x8D70)
    p.glUseProgram(array_layer_program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    p.glFramebufferTextureLayer(0x8D40, 0x8CE0, array_texture, 0, 1)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('layered 2D array image')
    base.require(list(read_pixels) == [80, 2, 3, 4, 81, 2, 3, 4],
                 f'layered 2D array image differs: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(array_texture))
    cube = U(); p.glGenTextures(1, C.byref(cube)); p.glBindTexture(0x8513, cube)
    p.glTexStorage2D(0x8513, 1, 0x8D70, 2, 2)
    cube_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) writeonly uniform highp uimageCube image;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, ivec3(p, 4), uvec4(uint(90+p.x), 3u, 4u, 5u));
      color = uvec4(uvec2(imageSize(image)), 0u, 1u);
    }'''
    cube_program = p.program([(0x8B31, simple_vert), (0x8B30, cube_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, cube, 0, True, 0, 0x88B9, 0x8D70)
    p.glUseProgram(cube_program); p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x8515 + 4, cube, 0)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('layered cube image')
    base.require(list(read_pixels) == [90, 3, 4, 5, 91, 3, 4, 5],
                 f'layered cube image differs: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(cube))
    sampler_expr = ' + '.join(f'texelFetch(sampled[{i}], ivec2(0), 0).x' for i in range(16))
    sampler_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    uniform highp usampler2D sampled[16];
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D destination[4];
    layout(location=0) out highp uvec4 color;
    void main() {
      uint sum = ''' + sampler_expr + ''';
      imageStore(destination[0], ivec2(0), uvec4(sum, 6u, 7u, 8u));
      imageStore(destination[1], ivec2(0), uvec4(sum+1u, 6u, 7u, 8u));
      imageStore(destination[2], ivec2(0), uvec4(sum+2u, 6u, 7u, 8u));
      imageStore(destination[3], ivec2(0), uvec4(sum+3u, 6u, 7u, 8u));
      color = uvec4(sum, 6u, 7u, 8u);
    }'''
    sampler_program = p.program([(0x8B31, simple_vert), (0x8B30, sampler_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    destinations = (U * 4)(); p.glGenTextures(4, destinations)
    for unit in range(4):
        p.glBindTexture(0x0DE1, destinations[unit]); p.glTexStorage2D(0x0DE1, 1, 0x8D70, 4, 1)
        p.glBindImageTexture(unit, destinations[unit], 0, False, 0, 0x88B9, 0x8D70)
    for unit in range(16):
        p.glActiveTexture(0x84C0 + unit); p.glBindTexture(0x0DE1, textures[0])
        p.glTexParameteri(0x0DE1, 0x2801, 0x2600); p.glTexParameteri(0x0DE1, 0x2800, 0x2600)
    p.glActiveTexture(0x84C0); p.glUseProgram(sampler_program)
    loc = p.glGetUniformLocation(sampler_program, b'sampled[0]')
    p.glUniform1iv(loc, 16, (I * 16)(*range(16)))
    p.glDrawArrays(4, 0, 3)
    p.glMemoryBarrier(0x00000400 | 0x00000020)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('sixteen samplers and graphics image')
    base.require(list(read_pixels) == [640, 6, 7, 8] * 2,
                 f'graphics samplers and image differ: {list(read_pixels)}')
    for unit in range(4):
        p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, destinations[unit], 0)
        value = (U * 4)(); p.glReadPixels(0, 0, 1, 1, 0x8D99, 0x1405, value)
        p.check_gl('graphics image stage limit')
        base.require(list(value) == [640 + unit, 6, 7, 8],
                     f'graphics image stage limit {unit}: {list(value)}')
    p.glDeleteTextures(4, destinations)
    producer_source = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(local_size_x=1) in;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D destination;
    void main() { imageStore(destination, ivec2(0), uvec4(100, 2, 3, 4)); }'''
    cross_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(rgba32ui,binding=0) readonly uniform highp uimage2D sourceImage;
    layout(rgba32ui,binding=1) writeonly uniform highp uimage2D destination;
    layout(location=0) out highp uvec4 color;
    void main() {
      uvec4 value = imageLoad(sourceImage, ivec2(0));
      imageStore(destination, ivec2(int(gl_FragCoord.x), 0), value + uvec4(1));
      color = value;
    }'''
    consumer_source = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(local_size_x=1) in;
    layout(rgba32ui,binding=1) readonly uniform highp uimage2D sourceImage;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D destination;
    void main() {
      uvec4 value = imageLoad(sourceImage, ivec2(1, 0));
      imageStore(destination, ivec2(1, 0), value + uvec4(2));
    }'''
    producer = p.program([(0x91B9, producer_source)])
    cross = p.program([(0x8B31, simple_vert), (0x8B30, cross_frag)])
    consumer = p.program([(0x91B9, consumer_source)])
    for unit in range(2):
        p.glBindImageTexture(unit, textures[unit], 0, False, 0, 0x88BA, 0x8D70)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glUseProgram(producer); p.glDispatchCompute(1, 1, 1); p.glMemoryBarrier(0x20)
    p.glUseProgram(cross); p.glDrawArrays(4, 0, 3); p.glMemoryBarrier(0x20)
    p.glUseProgram(consumer); p.glDispatchCompute(1, 1, 1); p.glMemoryBarrier(0x400)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[0], 0)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('compute graphics image synchronization')
    base.require(list(read_pixels) == [100, 2, 3, 4, 103, 5, 6, 7],
                 f'compute graphics image synchronization differs: {list(read_pixels)}')
    combined_vert = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(std430,binding=0) buffer VertexData { uint values[]; } vertexData;
    layout(rgba32ui,binding=0) writeonly uniform highp uimage2D vertexImage;
    void main() {
      if (gl_VertexID == 0) vertexData.values[0] = uint(vertexData.values.length());
      imageStore(vertexImage, ivec2(gl_VertexID, 0), uvec4(uint(110+gl_VertexID), 1, 2, 3));
      vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
      gl_Position = vec4(p, 0, 1);
    }'''
    combined_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(std430,binding=1) buffer FragmentData { uint values[]; } fragmentData;
    layout(rgba32ui,binding=1) writeonly uniform highp uimage2D fragmentImage;
    layout(location=0) out highp uvec4 color;
    void main() {
      int x = int(gl_FragCoord.x);
      fragmentData.values[x] = uint(fragmentData.values.length());
      imageStore(fragmentImage, ivec2(x, 0), uvec4(uint(120+x), 4, 5, 6));
      color = uvec4(1);
    }'''
    combined = p.program([(0x8B31, combined_vert), (0x8B30, combined_frag)])
    binary_size = I(); p.glGetProgramiv(combined, 0x8741, C.byref(binary_size))
    base.require(binary_size.value > 0, 'Graphics image program binary unavailable')
    binary_data = C.create_string_buffer(binary_size.value); binary_written = I(); binary_format = U()
    p.glGetProgramBinary(combined, binary_size.value, C.byref(binary_written),
                         C.byref(binary_format), binary_data)
    base.require(binary_written.value > 0, 'Cannot save graphics image program binary')
    restored = p.glCreateProgram(); p.programs.append(restored)
    p.glProgramBinary(restored, binary_format, binary_data, binary_written.value)
    binary_status = I(); p.glGetProgramiv(restored, 0x8B82, C.byref(binary_status))
    base.require(binary_status.value, 'Cannot restore graphics image program binary')
    combined = restored
    storage_buffers = (U * 2)(); p.glGenBuffers(2, storage_buffers)
    volume_images = (U * 2)(); p.glGenTextures(2, volume_images)
    for unit, words in enumerate((4, 8)):
        p.glBindBuffer(0x90D2, storage_buffers[unit]); p.glBufferData(0x90D2, words * 4, None, 0x88E8)
        p.glBindBufferBase(0x90D2, unit, storage_buffers[unit])
        p.glBindTexture(0x806F, volume_images[unit]); p.glTexStorage3D(0x806F, 1, 0x8D70, 4, 1, 3)
        p.glBindImageTexture(unit, volume_images[unit], 0, False, 2 - unit, 0x88B9, 0x8D70)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glUseProgram(combined); p.glDrawArrays(4, 0, 3); p.glMemoryBarrier(0x620)
    for unit, expected in ((0, [4]), (1, [8, 8])):
        p.glBindBuffer(0x90D2, storage_buffers[unit])
        address = p.glMapBufferRange(0x90D2, 0, len(expected) * 4, 1)
        base.require(address, 'Cannot map combined graphics storage')
        values = list((U * len(expected)).from_buffer_copy(C.string_at(address, len(expected) * 4)))
        base.require(p.glUnmapBuffer(0x90D2), 'Combined graphics storage became invalid')
        base.require(values == expected, f'combined graphics storage {unit}: {values}')
        p.glFramebufferTextureLayer(0x8D40, 0x8CE0, volume_images[unit], 0, 2 - unit)
        count = 3 if unit == 0 else 2
        pixels = (U * (count * 4))()
        p.glReadPixels(0, 0, count, 1, 0x8D99, 0x1405, pixels)
        first = 110 if unit == 0 else 120
        suffix = [1, 2, 3] if unit == 0 else [4, 5, 6]
        expected_pixels = [component for x in range(count) for component in [first+x, *suffix]]
        base.require(list(pixels) == expected_pixels, f'combined image {unit}: {list(pixels)}')
    p.check_gl('combined graphics images and storage')
    p.glDeleteBuffers(2, storage_buffers); p.glDeleteTextures(2, volume_images)
    def separable(shader_type, source):
        shader = p.glCreateShader(shader_type); text = C.c_char_p(source.encode())
        p.glShaderSource(shader, 1, C.byref(text), None); p.glCompileShader(shader)
        state = I(); p.glGetShaderiv(shader, 0x8B81, C.byref(state))
        base.require(state.value, 'Separable image shader compilation failed')
        program = p.glCreateProgram(); p.programs.append(program)
        p.glProgramParameteri(program, 0x8258, 1)
        p.glAttachShader(program, shader); p.glDeleteShader(shader); p.glLinkProgram(program)
        p.glGetProgramiv(program, 0x8B82, C.byref(state))
        if not state.value:
            log = C.create_string_buffer(8192); p.glGetProgramInfoLog(program, len(log), None, log)
            raise base.Failure('Separable image program: ' + log.value.decode(errors='replace'))
        return program
    vertex_program = separable(0x8B31, vert); fragment_program = separable(0x8B30, frag)
    pipeline = U(); p.glGenProgramPipelines(1, C.byref(pipeline))
    p.glUseProgram(0); p.glBindProgramPipeline(pipeline)
    p.glUseProgramStages(pipeline, 1, vertex_program); p.glUseProgramStages(pipeline, 2, fragment_program)
    for unit in range(2):
        p.glBindImageTexture(unit, textures[unit], 0, False, 0, 0x88B9, 0x8D70)
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glDrawArrays(4, 0, 3); p.glMemoryBarrier(0x420)
    for unit, expected in ((0, [10, 1, 2, 3, 11, 1, 2, 3]),
                           (1, [20, 4, 5, 6, 21, 4, 5, 6])):
        p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[unit], 0)
        p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
        p.check_gl('separable graphics image program')
        base.require(list(read_pixels) == expected,
                     f'separable graphics image program {unit}: {list(read_pixels)}')
    p.glBindProgramPipeline(0); p.glDeleteProgramPipelines(1, C.byref(pipeline))
    float_texture = U(); p.glGenTextures(1, C.byref(float_texture)); p.glBindTexture(0x0DE1, float_texture)
    p.glTexStorage2D(0x0DE1, 1, 0x822E, 2, 1)  # R32F
    float_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(r32f,binding=0) coherent uniform highp image2D image;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, p, vec4(1.5));
      memoryBarrierImage();
      color = uvec4(floatBitsToUint(imageLoad(image, p).x), 2u, 3u, 4u);
    }'''
    float_program = p.program([(0x8B31, simple_vert), (0x8B30, float_frag)])
    p.glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, textures[2], 0)
    p.glBindImageTexture(0, float_texture, 0, False, 0, 0x88BA, 0x822E)
    p.glUseProgram(float_program); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('read/write float image')
    base.require(list(read_pixels) == [0x3fc00000, 2, 3, 4] * 2,
                 f'read/write float image differs: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(float_texture))
    signed_texture = U(); p.glGenTextures(1, C.byref(signed_texture)); p.glBindTexture(0x0DE1, signed_texture)
    p.glTexStorage2D(0x0DE1, 1, 0x8235, 2, 1)  # R32I
    signed_frag = '''#version 310 es
    precision highp float;
    precision highp int;
    layout(r32i,binding=0) coherent uniform highp iimage2D image;
    layout(location=0) out highp uvec4 color;
    void main() {
      ivec2 p = ivec2(int(gl_FragCoord.x), 0);
      imageStore(image, p, ivec4(-123));
      memoryBarrierImage();
      color = uvec4(uint(imageLoad(image, p).x), 2u, 3u, 4u);
    }'''
    signed_program = p.program([(0x8B31, simple_vert), (0x8B30, signed_frag)])
    p.glBindImageTexture(0, signed_texture, 0, False, 0, 0x88BA, 0x8235)
    p.glUseProgram(signed_program); p.glDrawArrays(4, 0, 3)
    p.glReadPixels(0, 0, 2, 1, 0x8D99, 0x1405, read_pixels)
    p.check_gl('read/write signed image')
    base.require(list(read_pixels) == [0xffffff85, 2, 3, 4] * 2,
                 f'read/write signed image differs: {list(read_pixels)}')
    p.glDeleteTextures(1, C.byref(signed_texture))
    p.glDeleteFramebuffers(1, C.byref(framebuffer)); p.glDeleteTextures(3, textures)
    print('GRAPHICS_IMAGES_PASS vertex_load_store=1 fragment_load_store=1 rebind=1 writable_alias=1 readonly_alias=1 array=1 slice3d=1 layered=1 cube=1 samplers16_images4=1 cross_pipeline=1 ssbo=1 binary=1 separable=1 float=1 signed=1')
finally:
    p.close()
