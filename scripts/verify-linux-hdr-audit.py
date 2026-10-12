#!/usr/bin/env python3
"""Check actual downstream Vulkan swapchain/present records against probe phases.
This validates software presentation only, never physical monitor emission.
"""
import argparse
import pathlib
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', type=pathlib.Path)
parser.add_argument('--require-hdr', action='store_true')
args = parser.parse_args()
lines = args.log.read_text(errors='replace').splitlines()
latest_swapchain = None
current_phase = None
presents = 0
hdr_passes = 0
phase_passes = 0
failures = []
loaded = False
for number, line in enumerate(lines, 1):
    if 'HDR_AUDIT_INSTANCE created observation_only=1' in line:
        loaded = True
    match = re.search(r'HDR_AUDIT_SWAPCHAIN format=(\d+) colorspace=(\d+) extent=\d+x\d+ result=(-?\d+)', line)
    if match:
        latest_swapchain = tuple(map(int, match.groups()))
    match = re.search(r'PHASE_BEGIN (\S+)', line)
    if match:
        current_phase = match.group(1)
        presents = 0
    match = re.search(r'HDR_AUDIT_PRESENT swapchains=(\d+) result=(-?\d+)', line)
    if match and current_phase:
        count, result = map(int, match.groups())
        if result not in (0, 1000001003):
            failures.append(f'line {number}: vkQueuePresentKHR returned {result}')
        else:
            presents += count
    match = re.search(r'PHASE_PASS (\S+)', line)
    if not match:
        continue
    name = match.group(1)
    if name != current_phase:
        failures.append(f'line {number}: phase boundary mismatch')
        continue
    if latest_swapchain is None or latest_swapchain[2] != 0 or presents < 4:
        failures.append(f'{name}: missing successful real swapchain/presentation evidence')
        continue
    fmt, space, _ = latest_swapchain
    if name == 'scRGB_FP16':
        valid = fmt == 97 and space == 1000104002  # R16G16B16A16_SFLOAT, EXTENDED_SRGB_LINEAR
    elif name == 'HDR10_PQ_RGB10A2':
        valid = fmt in (58, 64) and space == 1000104008  # 10-bit UNORM, HDR10_ST2084
    elif name.startswith('SDR_'):
        valid = space == 0
    else:
        valid = False
    if not valid:
        failures.append(f'{name}: unexpected Vulkan format={fmt}, colorspace={space}')
    else:
        phase_passes += 1
        hdr_passes += name in ('scRGB_FP16', 'HDR10_PQ_RGB10A2')
        print(f'AUDIT_PASS {name} VkFormat={fmt} VkColorSpace={space} presents={presents}')
    current_phase = None
if not loaded:
    failures.append('Observation layer was not loaded; no native Vulkan evidence')
if phase_passes == 0:
    failures.append('No completed presentation phases')
if not any('LINUX_HDR_SUMMARY ' in line for line in lines):
    failures.append('Probe did not reach its summary')
if any('LINUX_HDR_FAIL ' in line for line in lines):
    failures.append('Probe reported a failure')
validation_errors = sum('Validation Error:' in line for line in lines)
if validation_errors:
    failures.append(f'Khronos layer reported {validation_errors} validation errors; not a clean validation run')
if failures:
    for failure in failures:
        print(f'AUDIT_FAIL {failure}', file=sys.stderr)
    sys.exit(1)
print(f'AUDIT_SUMMARY phases={phase_passes} hdr_phases={hdr_passes} physical_hdr=NOT_TESTED')
if args.require_hdr and hdr_passes == 0:
    print('AUDIT_SKIP no HDR software presentation was available')
    sys.exit(77)
