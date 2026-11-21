// Diagnostic-only readback of the actual immutable Vulkan capture allocation.
#include "../../frontends/godot/extension/src/chromium_gpu_linux.cpp"
#include <cstdio>

namespace {
struct Capture {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t family = UINT32_MAX;
    std::unique_ptr<Receiver> receiver;
    ~Capture() {
        receiver.reset();
        if (device) vkDestroyDevice(device, nullptr);
        if (instance) vkDestroyInstance(instance, nullptr);
    }
    void open(const char* endpoint) {
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.apiVersion = VK_API_VERSION_1_2;
        VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        ci.pApplicationInfo = &app;
        check(vkCreateInstance(&ci, nullptr, &instance), "instance");
        uint32_t count = 0;
        check(vkEnumeratePhysicalDevices(instance, &count, nullptr), "GPU count");
        std::vector<VkPhysicalDevice> devices(count);
        check(vkEnumeratePhysicalDevices(instance, &count, devices.data()), "GPUs");
        for (auto candidate : devices) {
            VkPhysicalDeviceProperties properties{};
            vkGetPhysicalDeviceProperties(candidate, &properties);
            if (properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ||
                properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
                physical = candidate;
                break;
            }
        }
        if (!physical) throw std::runtime_error("Hardware Vulkan GPU required");
        buffer_support(physical);
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
        std::vector<VkQueueFamilyProperties> families(count);
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
        for (uint32_t i = 0; i < count; ++i)
            if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
        if (family == UINT32_MAX) throw std::runtime_error("Graphics queue required");
        float priority = 1;
        VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        q.queueFamilyIndex = family;
        q.queueCount = 1;
        q.pQueuePriorities = &priority;
        const char* extension = VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME;
        VkPhysicalDeviceBufferDeviceAddressFeatures bda{
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES};
        bda.bufferDeviceAddress = true;
        VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        info.pNext = &bda;
        info.queueCreateInfoCount = 1;
        info.pQueueCreateInfos = &q;
        info.enabledExtensionCount = 1;
        info.ppEnabledExtensionNames = &extension;
        check(vkCreateDevice(physical, &info, nullptr, &device), "device");
        vkGetDeviceQueue(device, family, 0, &queue);
        receiver.reset(static_cast<Receiver*>(graffitty_gpu_receiver_create(endpoint)));
        if (!receiver) throw std::runtime_error("Capture endpoint unavailable");
    }
    int sample(uint32_t* width, uint32_t* height, uint8_t* rgba) {
        uint32_t bgra = 0;
        uint64_t sequence = 0;
        if (!graffitty_gpu_receive_linux(receiver.get(), reinterpret_cast<uint64_t>(physical),
                reinterpret_cast<uint64_t>(device), reinterpret_cast<uint64_t>(queue),
                family, width, height, &bgra, &sequence)) {
            if (receiver->failed) throw std::runtime_error("Capture import failed");
            return 0;
        }
        Buffer staging;
        staging.device = device;
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        info.size = 4;
        info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        check(vkCreateBuffer(device, &info, nullptr, &staging.buffer), "staging");
        VkMemoryRequirements requirements;
        vkGetBufferMemoryRequirements(device, staging.buffer, &requirements);
        VkPhysicalDeviceMemoryProperties memory;
        vkGetPhysicalDeviceMemoryProperties(physical, &memory);
        uint32_t type = 0;
        const auto flags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        for (; type < memory.memoryTypeCount; ++type)
            if ((requirements.memoryTypeBits & (1u << type)) &&
                (memory.memoryTypes[type].propertyFlags & flags) == flags) break;
        if (type == memory.memoryTypeCount) throw std::runtime_error("Readback memory unavailable");
        VkMemoryAllocateInfo allocation{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocation.memoryTypeIndex = type;
        allocation.allocationSize = requirements.size;
        check(vkAllocateMemory(device, &allocation, nullptr, &staging.memory), "staging memory");
        check(vkBindBufferMemory(device, staging.buffer, staging.memory, 0), "bind staging");
        Commands read;
        read.begin(device, family);
        VkBufferCopy region{(uint64_t(*height / 2) * *width + *width / 2) * 4, 0, 4};
        vkCmdCopyBuffer(read.command, receiver->frames.at(sequence)->buffer, staging.buffer, 1, &region);
        VkBufferMemoryBarrier barrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        barrier.buffer = staging.buffer;
        barrier.size = VK_WHOLE_SIZE;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        vkCmdPipelineBarrier(read.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                             0, 0, nullptr, 1, &barrier, 0, nullptr);
        read.finish(queue);
        void* mapped = nullptr;
        check(vkMapMemory(device, staging.memory, 0, 4, 0, &mapped), "map pixel");
        std::memcpy(rgba, mapped, 4);
        vkUnmapMemory(device, staging.memory);
        if (bgra) std::swap(rgba[0], rgba[2]);
        graffitty_gpu_release_frame(receiver.get(), sequence);
        return 1;
    }
};
}
extern "C" void* gft_linux_capture_new(const char* endpoint) {
    try {
        auto capture = std::make_unique<Capture>();
        capture->open(endpoint);
        return capture.release();
    } catch (const std::exception& error) {
        fprintf(stderr, "Linux capture test: %s\n", error.what());
        return nullptr;
    }
}
extern "C" void gft_linux_capture_free(void* pointer) { delete static_cast<Capture*>(pointer); }
extern "C" int gft_linux_capture_sample(void* pointer, uint32_t* width, uint32_t* height, uint8_t* rgba) {
    try { return static_cast<Capture*>(pointer)->sample(width, height, rgba); }
    catch (const std::exception& error) {
        fprintf(stderr, "Linux capture test: %s\n", error.what());
        return -1;
    }
}
