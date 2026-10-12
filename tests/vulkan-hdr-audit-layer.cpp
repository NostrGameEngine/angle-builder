// SPDX-License-Identifier: BSD-3-Clause
// Observation-only Vulkan layer for the HDR probe. No capability, format,
// colorspace, command, or presentation parameter is changed by this layer.
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace {
constexpr const char *LayerName = "VK_LAYER_NGE_hdr_audit";
struct InstanceState {
    VkInstance instance = VK_NULL_HANDLE;
    PFN_vkGetInstanceProcAddr gipa = nullptr;
    PFN_GetPhysicalDeviceProcAddr gpdpa = nullptr;
    PFN_vkDestroyInstance destroy = nullptr;
};
struct DeviceState {
    PFN_vkGetDeviceProcAddr gdpa = nullptr;
    PFN_vkDestroyDevice destroy = nullptr;
    PFN_vkCreateSwapchainKHR createSwapchain = nullptr;
    PFN_vkQueuePresentKHR present = nullptr;
};
std::mutex StateMutex;
std::unordered_map<void *, InstanceState> Instances;
std::unordered_map<void *, DeviceState> Devices;
template <typename T> void *Key(T handle) { return handle ? *reinterpret_cast<void **>(handle) : nullptr; }
InstanceState Instance(void *key) {
    std::lock_guard<std::mutex> lock(StateMutex);
    auto it = Instances.find(key); return it == Instances.end() ? InstanceState{} : it->second;
}
DeviceState Device(void *key) {
    std::lock_guard<std::mutex> lock(StateMutex);
    auto it = Devices.find(key); return it == Devices.end() ? DeviceState{} : it->second;
}
}
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGipa(VkInstance, const char *);
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGdpa(VkDevice, const char *);
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGpdpa(VkInstance, const char *);

static VKAPI_ATTR VkResult VKAPI_CALL NgeCreateInstance(const VkInstanceCreateInfo *info,
                                                       const VkAllocationCallbacks *allocator, VkInstance *instance)
{
    auto *chain = reinterpret_cast<VkLayerInstanceCreateInfo *>(const_cast<void *>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = reinterpret_cast<VkLayerInstanceCreateInfo *>(const_cast<void *>(chain->pNext));
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    auto *link = chain->u.pLayerInfo;
    auto gipa = link->pfnNextGetInstanceProcAddr;
    auto gpdpa = link->pfnNextGetPhysicalDeviceProcAddr;
    chain->u.pLayerInfo = link->pNext;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(gipa(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, instance);
    if (result == VK_SUCCESS) {
        std::lock_guard<std::mutex> lock(StateMutex);
        Instances[Key(*instance)] = {*instance, gipa, gpdpa,
            reinterpret_cast<PFN_vkDestroyInstance>(gipa(*instance, "vkDestroyInstance"))};
        std::fprintf(stderr, "HDR_AUDIT_INSTANCE created observation_only=1\n");
    }
    return result;
}
static VKAPI_ATTR void VKAPI_CALL NgeDestroyInstance(VkInstance instance, const VkAllocationCallbacks *allocator)
{
    void *key = Key(instance); auto state = Instance(key);
    { std::lock_guard<std::mutex> lock(StateMutex); Instances.erase(key); }
    if (state.destroy) state.destroy(instance, allocator);
}
static VKAPI_ATTR VkResult VKAPI_CALL NgeCreateDevice(VkPhysicalDevice physical,
        const VkDeviceCreateInfo *info, const VkAllocationCallbacks *allocator, VkDevice *device)
{
    auto state = Instance(Key(physical));
    auto *chain = reinterpret_cast<VkLayerDeviceCreateInfo *>(const_cast<void *>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = reinterpret_cast<VkLayerDeviceCreateInfo *>(const_cast<void *>(chain->pNext));
    if (!chain || !chain->u.pLayerInfo || !state.instance) return VK_ERROR_INITIALIZATION_FAILED;
    auto *link = chain->u.pLayerInfo;
    auto gdpa = link->pfnNextGetDeviceProcAddr;
    auto create = reinterpret_cast<PFN_vkCreateDevice>(link->pfnNextGetInstanceProcAddr(state.instance, "vkCreateDevice"));
    chain->u.pLayerInfo = link->pNext;
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(physical, info, allocator, device);
    if (result == VK_SUCCESS) {
        std::lock_guard<std::mutex> lock(StateMutex);
        Devices[Key(*device)] = {gdpa,
            reinterpret_cast<PFN_vkDestroyDevice>(gdpa(*device, "vkDestroyDevice")),
            reinterpret_cast<PFN_vkCreateSwapchainKHR>(gdpa(*device, "vkCreateSwapchainKHR")),
            reinterpret_cast<PFN_vkQueuePresentKHR>(gdpa(*device, "vkQueuePresentKHR"))};
        std::fprintf(stderr, "HDR_AUDIT_DEVICE created\n");
    }
    return result;
}
static VKAPI_ATTR void VKAPI_CALL NgeDestroyDevice(VkDevice device, const VkAllocationCallbacks *allocator)
{
    void *key = Key(device); auto state = Device(key);
    { std::lock_guard<std::mutex> lock(StateMutex); Devices.erase(key); }
    if (state.destroy) state.destroy(device, allocator);
}
static VKAPI_ATTR VkResult VKAPI_CALL NgeCreateSwapchain(VkDevice device,
        const VkSwapchainCreateInfoKHR *info, const VkAllocationCallbacks *allocator, VkSwapchainKHR *swapchain)
{
    auto state = Device(Key(device));
    if (!state.createSwapchain) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkResult result = state.createSwapchain(device, info, allocator, swapchain);
    std::fprintf(stderr, "HDR_AUDIT_SWAPCHAIN format=%d colorspace=%d extent=%ux%u result=%d\n",
        int(info->imageFormat), int(info->imageColorSpace), info->imageExtent.width, info->imageExtent.height, int(result));
    return result;
}
static VKAPI_ATTR VkResult VKAPI_CALL NgePresent(VkQueue queue, const VkPresentInfoKHR *info)
{
    auto state = Device(Key(queue));
    if (!state.present) return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkResult result = state.present(queue, info);
    std::fprintf(stderr, "HDR_AUDIT_PRESENT swapchains=%u result=%d\n", info->swapchainCount, int(result));
    return result;
}
static VKAPI_ATTR VkResult VKAPI_CALL NgeInstanceExtensions(const char *layer, uint32_t *count, VkExtensionProperties *)
{
    if (!layer || std::strcmp(layer, LayerName)) return VK_ERROR_LAYER_NOT_PRESENT;
    *count = 0; return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL NgeDeviceExtensions(VkPhysicalDevice physical, const char *layer,
                                                          uint32_t *count, VkExtensionProperties *properties)
{
    if (layer) {
        if (std::strcmp(layer, LayerName)) return VK_ERROR_LAYER_NOT_PRESENT;
        *count = 0; return VK_SUCCESS;
    }
    auto state = Instance(Key(physical));
    auto function = state.gipa ? reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
        state.gipa(state.instance, "vkEnumerateDeviceExtensionProperties")) : nullptr;
    return function ? function(physical, layer, count, properties) : VK_ERROR_INITIALIZATION_FAILED;
}
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGipa(VkInstance instance, const char *name)
{
#define HOOK(n, f) if (!std::strcmp(name, n)) return reinterpret_cast<PFN_vkVoidFunction>(f)
    HOOK("vkGetInstanceProcAddr", NgeGipa);
    HOOK("vkGetDeviceProcAddr", NgeGdpa);
    HOOK("vkCreateInstance", NgeCreateInstance);
    HOOK("vkDestroyInstance", NgeDestroyInstance);
    HOOK("vkCreateDevice", NgeCreateDevice);
    HOOK("vkDestroyDevice", NgeDestroyDevice);
    HOOK("vkCreateSwapchainKHR", NgeCreateSwapchain);
    HOOK("vkQueuePresentKHR", NgePresent);
    HOOK("vkEnumerateInstanceExtensionProperties", NgeInstanceExtensions);
    HOOK("vkEnumerateDeviceExtensionProperties", NgeDeviceExtensions);
    auto state = Instance(Key(instance));
    return state.gipa ? state.gipa(instance, name) : nullptr;
}
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGdpa(VkDevice device, const char *name)
{
    HOOK("vkGetDeviceProcAddr", NgeGdpa);
    HOOK("vkDestroyDevice", NgeDestroyDevice);
    HOOK("vkCreateSwapchainKHR", NgeCreateSwapchain);
    HOOK("vkQueuePresentKHR", NgePresent);
    auto state = Device(Key(device));
    return state.gdpa ? state.gdpa(device, name) : nullptr;
}
#undef HOOK
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL NgeGpdpa(VkInstance instance, const char *name)
{
    auto state = Instance(Key(instance));
    return state.gpdpa ? state.gpdpa(instance, name) : state.gipa ? state.gipa(instance, name) : nullptr;
}
extern "C" __attribute__((visibility("default"))) VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *version)
{
    if (!version || version->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
    version->loaderLayerInterfaceVersion = 2;
    version->pfnGetInstanceProcAddr = NgeGipa;
    version->pfnGetDeviceProcAddr = NgeGdpa;
    version->pfnGetPhysicalDeviceProcAddr = NgeGpdpa;
    return VK_SUCCESS;
}
