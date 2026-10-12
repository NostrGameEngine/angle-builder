#!/usr/bin/env python3
"""Compile the actual ANGLE query helper in a mocked Vulkan unit-test harness.
This checks enumeration/error handling ONLY; it is not an HDR runtime test.
"""
from pathlib import Path
import re, subprocess, sys
import argparse, os
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--angle-dir', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
angle_dir = args.angle_dir or Path(os.environ.get('ANGLE_DIR', str(root / 'build/angle')))
src = angle_dir / 'src/libANGLE/renderer/vulkan/DisplayVk.cpp'
s = src.read_text()
m = re.search(r'(?:VkResult|void) GetSupportedFormatColorspaces\(', s)
if not m:
    sys.exit('Query helper not found')
begin = s.index('{', m.start()); depth = 1; end = begin + 1
while depth:
    if s[end] == '{': depth += 1
    elif s[end] == '}': depth -= 1
    end += 1
helper = s[m.start():end]
if not helper.startswith('VkResult'):
    sys.exit('Query helper has not yet been updated to return VkResult')
header = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <vector>
#include <utility>
// Minimal Vulkan ABI-independent types for this logic-only test.
using VkPhysicalDevice = uintptr_t;
using VkSurfaceKHR = uintptr_t;
using VkResult = int;
constexpr VkResult VK_SUCCESS=0, VK_INCOMPLETE=5, VK_ERROR_SURFACE_LOST_KHR=-1000000000;
constexpr int VK_STRUCTURE_TYPE_SURFACE_FORMAT_2_KHR=1;
constexpr int VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SURFACE_INFO_2_KHR=2;
constexpr int VK_FORMAT_UNDEFINED=0, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR=0;
struct VkSurfaceFormatKHR {int format; int colorSpace;};
struct VkSurfaceFormat2KHR {int sType; void *pNext; VkSurfaceFormatKHR surfaceFormat;};
struct VkPhysicalDeviceSurfaceInfo2KHR {int sType; void *pNext; VkSurfaceKHR surface;};
namespace angle {struct Feature {bool enabled=false;}; struct FeaturesVk {Feature supportsSurfaceCapabilities2Extension;};}
#define ASSERT(x) ((void)0)
#define VK_CALL(name, ...) name(__VA_ARGS__)
static int scenario=0, calls=0;
static VkSurfaceFormatKHR pairs[]={{97,1000104002},{64,1000104008},{44,0}};
static VkResult StubQuery(uint32_t *count, VkSurfaceFormatKHR *out) {
    ++calls;
    if(scenario==1 && !out) return VK_ERROR_SURFACE_LOST_KHR;
    if(scenario==2 && out) return VK_ERROR_SURFACE_LOST_KHR;
    if(!out) {
        *count=scenario==5 ? 0 : (scenario==4 && calls==1) ? 2 : 3;
        return VK_SUCCESS;
    }
    auto n=std::min(*count, uint32_t(scenario==3 ? 2 : 3));
    for(uint32_t i=0;i<n;++i) out[i]=pairs[i];
    *count=n;
    if((scenario==4 && calls==2) || scenario==6) return VK_INCOMPLETE;
    return VK_SUCCESS;
}
static VkResult vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice, VkSurfaceKHR, uint32_t *n, VkSurfaceFormatKHR *out) {return StubQuery(n,out);}
static VkResult vkGetPhysicalDeviceSurfaceFormats2KHR(VkPhysicalDevice, const VkPhysicalDeviceSurfaceInfo2KHR*, uint32_t *n, VkSurfaceFormat2KHR *out) {
    if(!out) return StubQuery(n,nullptr);
    std::vector<VkSurfaceFormatKHR> tmp(*n);
    VkResult r=StubQuery(n,tmp.data());
    for(uint32_t i=0;i<*n;++i) out[i].surfaceFormat=tmp[i];
    return r;
}
'''
tail = r'''
int main() {
    int fails=0;
    for(bool v2 : {false,true}) {
        angle::FeaturesVk f; f.supportsSurfaceCapabilities2Extension.enabled=v2;
        for(scenario=0;scenario<7;++scenario) {
            calls=0;
            std::vector<VkSurfaceFormat2KHR> out;
            VkResult result=GetSupportedFormatColorspaces(1,f,2,&out);
            bool good=false;
            if(scenario==1 || scenario==2) good=result==VK_ERROR_SURFACE_LOST_KHR && out.empty();
            else if(scenario==5) good=result==VK_SUCCESS && out.empty() && calls==1;
            else if(scenario==6) good=result==VK_INCOMPLETE && out.empty() && calls==8;
            else {
                const size_t expected=scenario==3?2:3;
                good=result==VK_SUCCESS && out.size()==expected;
                for(size_t i=0;good && i<out.size();++i) good=out[i].surfaceFormat.format==pairs[i].format && out[i].surfaceFormat.colorSpace==pairs[i].colorSpace;
            }
            std::printf("QUERY_UNIT %s api=%s scenario=%d result=%d pairs=%zu calls=%d\n",good?"PASS":"FAIL",v2?"KHR2":"KHR",scenario,result,out.size(),calls);
            if(!good) ++fails;
        }
    }
    std::printf("QUERY_UNIT_SUMMARY failures=%d (MOCKED enumeration; NOT HDR presentation)\n",fails);
    return fails?1:0;
}
'''
outdir = root / 'build/linux-hdr-logic-test'
outdir.mkdir(parents=True, exist_ok=True)
cpp=outdir/'query_helper_extracted.cpp'; exe=outdir/'query-helper-unit'
cpp.write_text(header+'\n'+helper+'\n'+tail)
subprocess.run([os.environ.get('CXX','c++'),'-std=c++17','-O0',str(cpp),'-o',str(exe)],check=True)
r=subprocess.run([str(exe)],capture_output=True,text=True)
(outdir/'query-helper-unit.log').write_text(r.stdout+r.stderr)
print(r.stdout,end=''); print(r.stderr,end='',file=sys.stderr)
sys.exit(r.returncode)
