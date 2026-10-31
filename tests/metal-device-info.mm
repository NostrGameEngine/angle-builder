#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

int main() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      std::fputs("No Metal device is available\n", stderr);
      return 1;
    }
    NSDictionary *record = @{
      @"os" : NSProcessInfo.processInfo.operatingSystemVersionString,
      @"device" : device.name,
      @"apple_family_1" : @([device supportsFamily:MTLGPUFamilyApple1]),
      @"apple_family_3" : @([device supportsFamily:MTLGPUFamilyApple3]),
      @"apple_family_4" : @([device supportsFamily:MTLGPUFamilyApple4]),
      @"apple_family_7" : @([device supportsFamily:MTLGPUFamilyApple7]),
      @"mac_family_2" : @([device supportsFamily:MTLGPUFamilyMac2]),
      @"metal_family_3" : @([device supportsFamily:MTLGPUFamilyMetal3]),
      @"argument_buffers_tier" :
          @(device.argumentBuffersSupport == MTLArgumentBuffersTier2 ? 2 : 1),
      @"read_write_texture_tier" : @(device.readWriteTextureSupport),
      @"max_threads_per_threadgroup" : @[
        @(device.maxThreadsPerThreadgroup.width),
        @(device.maxThreadsPerThreadgroup.height),
        @(device.maxThreadsPerThreadgroup.depth)
      ],
      @"max_threadgroup_memory" : @(device.maxThreadgroupMemoryLength),
      @"max_buffer_length" : @(device.maxBufferLength)
    };
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:record
                                        options:NSJSONWritingPrettyPrinted
                                          error:nil];
    std::fwrite(data.bytes, 1, data.length, stdout);
    std::putchar('\n');
  }
  return 0;
}
