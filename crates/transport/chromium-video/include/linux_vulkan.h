#pragma once
#include <vulkan/vulkan.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>
#include "frame_protocol_linux.h"

namespace chromium_linux {
inline void check(VkResult result, const char *what) {
    if (result != VK_SUCCESS)
        throw std::runtime_error(std::string(what) + ": " + std::to_string(result));
}
template <class T> T proc(VkDevice device, const char *name) {
    auto p = reinterpret_cast<T>(vkGetDeviceProcAddr(device, name));
    if (!p)
        throw std::runtime_error(std::string("Vulkan extension unavailable: ") + name);
    return p;
}
constexpr VkBufferUsageFlags buffer_usage =
    VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
    VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
struct Buffer {
    VkDevice device = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    ~Buffer() {
        if (buffer)
            vkDestroyBuffer(device, buffer, nullptr);
        if (memory)
            vkFreeMemory(device, memory, nullptr);
    }
    Buffer() = default;
    Buffer(const Buffer &) = delete;
    Buffer &operator=(const Buffer &) = delete;
};
inline void create_buffer(Buffer &b, VkDevice device, uint64_t bytes) {
    b.device = device;
    VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
    external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    info.pNext = &external;
    info.size = bytes;
    info.usage = buffer_usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    check(vkCreateBuffer(device, &info, nullptr, &b.buffer), "create external buffer");
}
inline Hello identity(VkPhysicalDevice physical) {
    VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
    VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
    p.pNext = &id;
    vkGetPhysicalDeviceProperties2(physical, &p);
    Hello h;
    h.kinds = opaque_fd;
    std::memcpy(h.device_uuid, id.deviceUUID, 16);
    std::memcpy(h.driver_uuid, id.driverUUID, 16);
    return h;
}
inline bool same_device(const Hello &a, const Hello &b) {
    return a.magic == magic && a.version == version && b.magic == magic && b.version == version &&
           !std::memcmp(a.device_uuid, b.device_uuid, 16) &&
           !std::memcmp(a.driver_uuid, b.driver_uuid, 16);
}
inline void buffer_support(VkPhysicalDevice physical) {
    VkPhysicalDeviceExternalBufferInfo info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO};
    info.usage = buffer_usage;
    info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    VkExternalBufferProperties props{VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
    vkGetPhysicalDeviceExternalBufferProperties(physical, &info, &props);
    VkExternalMemoryFeatureFlags required =
        VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT | VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT;
    if ((props.externalMemoryProperties.externalMemoryFeatures & required) != required)
        throw std::runtime_error("Vulkan OPAQUE_FD storage buffers cannot be shared on this GPU");
}
// Used only on the owning thread; Godot callers must be on its render thread.
// Wait before destroying borrowed CEF resources, even on a slow GPU.
class Commands {
    VkDevice device_ = VK_NULL_HANDLE;
    VkCommandPool pool_ = VK_NULL_HANDLE;
    VkFence fence_ = VK_NULL_HANDLE;
    bool submitted_ = false;

  public:
    VkCommandBuffer command = VK_NULL_HANDLE;
    ~Commands() {
        if (submitted_)
            vkWaitForFences(device_, 1, &fence_, VK_TRUE, UINT64_MAX);
        if (fence_)
            vkDestroyFence(device_, fence_, nullptr);
        if (pool_)
            vkDestroyCommandPool(device_, pool_, nullptr);
    }
    void begin(VkDevice device, uint32_t family) {
        device_ = device;
        VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
        pool.queueFamilyIndex = family;
        pool.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
        check(vkCreateCommandPool(device, &pool, nullptr, &pool_), "command pool");
        VkCommandBufferAllocateInfo a{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        a.commandPool = pool_;
        a.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        a.commandBufferCount = 1;
        check(vkAllocateCommandBuffers(device, &a, &command), "command buffer");
        VkCommandBufferBeginInfo b{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        b.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(vkBeginCommandBuffer(command, &b), "begin commands");
    }
    void finish(VkQueue queue) {
        check(vkEndCommandBuffer(command), "end commands");
        VkFenceCreateInfo f{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
        check(vkCreateFence(device_, &f, nullptr, &fence_), "fence");
        VkSubmitInfo s{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        s.commandBufferCount = 1;
        s.pCommandBuffers = &command;
        check(vkQueueSubmit(queue, 1, &s, fence_), "submit GPU copy");
        submitted_ = true;
        check(vkWaitForFences(device_, 1, &fence_, VK_TRUE, UINT64_MAX), "finish GPU copy");
        submitted_ = false;
    }
};
} // namespace chromium_linux
