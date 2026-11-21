#include "vulkan_readback.h"
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>

// The loader exports trampolines for core commands. Keep it optional so a
// headless server can still receive software frames without a Vulkan install.
#define VULKAN_COMMANDS(X) \
    X(CreateInstance) X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties2) \
    X(GetPhysicalDeviceExternalBufferProperties) X(GetPhysicalDeviceQueueFamilyProperties) \
    X(GetPhysicalDeviceMemoryProperties) X(EnumerateDeviceExtensionProperties) X(CreateDevice) \
    X(DestroyDevice) X(GetDeviceQueue) X(GetDeviceProcAddr) X(CreateBuffer) X(DestroyBuffer) \
    X(GetBufferMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) \
    X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers) X(BeginCommandBuffer) \
    X(EndCommandBuffer) X(CreateFence) X(DestroyFence) X(QueueSubmit) X(WaitForFences) \
    X(CmdPipelineBarrier) X(CmdCopyBuffer) X(MapMemory) X(UnmapMemory) X(InvalidateMappedMemoryRanges)
#define DECLARE(name) static PFN_vk##name vk##name;
VULKAN_COMMANDS(DECLARE)
#undef DECLARE
#include "../include/linux_vulkan.h"

namespace {
using namespace chromium_linux;
bool load_vulkan() {
    static const bool loaded = [] {
        void *lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return false;
#define LOAD(name) if (!(vk##name = reinterpret_cast<PFN_vk##name>(dlsym(lib, "vk" #name)))) return false;
        VULKAN_COMMANDS(LOAD)
#undef LOAD
        return true;
    }();
    return loaded;
}

class Reader final : public VulkanReadback {
  public:
    VkInstance instance{};
    VkDevice device{};
    VkQueue queue{};
    uint32_t family = 0;
    VkPhysicalDeviceMemoryProperties memory{};

    ~Reader() override {
        if (device) vkDestroyDevice(device, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
    }

    bool open(VkPhysicalDevice gpu) {
        VkPhysicalDeviceProperties2 props{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        vkGetPhysicalDeviceProperties2(gpu, &props);
        if (props.properties.apiVersion < VK_API_VERSION_1_2 ||
            props.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) return false;
        // The producer must be able to import CEF's DMA-BUF on this device.
        uint32_t count = 0;
        check(vkEnumerateDeviceExtensionProperties(gpu, nullptr, &count, nullptr), "extension count");
        std::vector<VkExtensionProperties> extensions(count);
        check(vkEnumerateDeviceExtensionProperties(gpu, nullptr, &count, extensions.data()), "extensions");
        for (const char *name : {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
                                VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
                                VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
                                VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME}) {
            if (std::none_of(extensions.begin(), extensions.end(),
                             [name](auto &e) { return !std::strcmp(e.extensionName, name); })) return false;
        }
        buffer_support(gpu);
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, nullptr);
        std::vector<VkQueueFamilyProperties> families(count);
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, families.data());
        for (family = 0; family < count; ++family)
            if (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT) break;
        if (family == count) return false;
        float priority = 1;
        VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        q.queueFamilyIndex = family;
        q.queueCount = 1;
        q.pQueuePriorities = &priority;
        VkPhysicalDeviceBufferDeviceAddressFeatures address{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES};
        address.bufferDeviceAddress = VK_TRUE;
        const char *extension = VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME;
        VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        info.pNext = &address;
        info.queueCreateInfoCount = 1;
        info.pQueueCreateInfos = &q;
        info.enabledExtensionCount = 1;
        info.ppEnabledExtensionNames = &extension;
        check(vkCreateDevice(gpu, &info, nullptr, &device), "capture device");
        vkGetDeviceQueue(device, family, 0, &queue);
        vkGetPhysicalDeviceMemoryProperties(gpu, &memory);
        hello = identity(gpu);
        return true;
    }

    bool read(const Frame &frame, int fd, std::vector<uint8_t> &pixels) override {
        struct Descriptor {
            int fd;
            ~Descriptor() { if (fd >= 0) close(fd); }
        } descriptor{fd};
        try {
            const VkDeviceSize bytes = uint64_t(frame.width) * frame.height * 4;
            Buffer imported;
            create_buffer(imported, device, bytes);
            VkMemoryRequirements req;
            vkGetBufferMemoryRequirements(device, imported.buffer, &req);
            uint32_t type = frame.memory_type;
            if (type >= memory.memoryTypeCount || !(req.memoryTypeBits & (1u << type)) ||
                frame.allocation_size != req.size) return false;
            VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
            dedicated.buffer = imported.buffer;
            VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
            flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
            flags.pNext = &dedicated;
            VkImportMemoryFdInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR};
            import.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
            import.fd = fd;
            import.pNext = &flags;
            VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
            allocation.pNext = &import;
            allocation.memoryTypeIndex = type;
            allocation.allocationSize = req.size;
            check(vkAllocateMemory(device, &allocation, nullptr, &imported.memory), "import frame memory");
            descriptor.fd = -1;
            check(vkBindBufferMemory(device, imported.buffer, imported.memory, 0), "bind imported frame");

            Buffer staging;
            VkDeviceMemory readable = imported.memory;
            const bool direct = memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
            Commands commands;
            commands.begin(device, family);
            VkBufferMemoryBarrier barrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
            barrier.dstQueueFamilyIndex = family;
            barrier.buffer = imported.buffer;
            barrier.size = VK_WHOLE_SIZE;
            barrier.dstAccessMask = direct ? VK_ACCESS_HOST_READ_BIT : VK_ACCESS_TRANSFER_READ_BIT;
            vkCmdPipelineBarrier(commands.command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                direct ? VK_PIPELINE_STAGE_HOST_BIT : VK_PIPELINE_STAGE_TRANSFER_BIT,
                0, 0, nullptr, 1, &barrier, 0, nullptr);
            if (!direct) {
                staging.device = device;
                VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
                info.size = bytes;
                info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
                check(vkCreateBuffer(device, &info, nullptr, &staging.buffer), "readback buffer");
                vkGetBufferMemoryRequirements(device, staging.buffer, &req);
                for (type = 0; type < memory.memoryTypeCount; ++type)
                    if ((req.memoryTypeBits & (1u << type)) &&
                        (memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) break;
                if (type == memory.memoryTypeCount) return false;
                allocation.pNext = nullptr;
                allocation.allocationSize = req.size;
                allocation.memoryTypeIndex = type;
                check(vkAllocateMemory(device, &allocation, nullptr, &staging.memory), "readback allocation");
                check(vkBindBufferMemory(device, staging.buffer, staging.memory, 0), "bind readback");
                VkBufferCopy copy{0, 0, bytes};
                vkCmdCopyBuffer(commands.command, imported.buffer, staging.buffer, 1, &copy);
                barrier.buffer = staging.buffer;
                barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
                barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
                vkCmdPipelineBarrier(commands.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                                     0, 0, nullptr, 1, &barrier, 0, nullptr);
                readable = staging.memory;
            }
            commands.finish(queue);
            pixels.resize(bytes);
            void *mapped;
            check(vkMapMemory(device, readable, 0, VK_WHOLE_SIZE, 0, &mapped), "map frame");
            VkResult result = VK_SUCCESS;
            if (!(memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
                VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
                range.memory = readable;
                range.size = VK_WHOLE_SIZE;
                result = vkInvalidateMappedMemoryRanges(device, 1, &range);
            }
            if (result == VK_SUCCESS) std::memcpy(pixels.data(), mapped, bytes);
            vkUnmapMemory(device, readable);
            check(result, "invalidate frame");
            return true;
        } catch (const std::exception &error) {
            std::fprintf(stderr, "Chromium Vulkan readback: %s\n", error.what());
            return false;
        }
    }
};
} // namespace

std::unique_ptr<VulkanReadback> VulkanReadback::create() {
    if (!load_vulkan()) return nullptr;
    try {
        auto reader = std::make_unique<Reader>();
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.apiVersion = VK_API_VERSION_1_2;
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        info.pApplicationInfo = &app;
        check(vkCreateInstance(&info, nullptr, &reader->instance), "Vulkan instance");
        uint32_t count = 0;
        check(vkEnumeratePhysicalDevices(reader->instance, &count, nullptr), "device count");
        std::vector<VkPhysicalDevice> devices(count);
        check(vkEnumeratePhysicalDevices(reader->instance, &count, devices.data()), "devices");
        for (auto gpu : devices) {
            try {
                if (reader->open(gpu)) return reader;
            } catch (const std::exception &error) {
                std::fprintf(stderr, "Chromium Vulkan device: %s\n", error.what());
            }
        }
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Chromium Vulkan capture: %s\n", error.what());
    }
    return nullptr;
}
