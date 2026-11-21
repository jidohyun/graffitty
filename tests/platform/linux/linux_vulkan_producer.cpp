// Standalone GPU-only producer for the actual Godot import/compute/lifetime test.
#include "../../../crates/transport/chromium-video/include/linux_vulkan.h"
#include <cassert>
using namespace chromium_linux;
int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    int peer = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    sockaddr_un a{};
    auto length = address(argv[1], a);
    if (!length || connect(peer, reinterpret_cast<sockaddr *>(&a), length) || !same_user(peer))
        return 3;
    Hello hello;
    if (recv(peer, &hello, sizeof(hello), MSG_TRUNC) != sizeof(hello))
        return 4;
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &app;
    VkInstance instance;
    check(vkCreateInstance(&ci, nullptr, &instance), "instance");
    uint32_t count = 0;
    check(vkEnumeratePhysicalDevices(instance, &count, nullptr), "GPU count");
    std::vector<VkPhysicalDevice> devices(count);
    check(vkEnumeratePhysicalDevices(instance, &count, devices.data()), "GPUs");
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    for (auto p : devices)
        if (same_device(hello, identity(p)))
            physical = p;
    if (!physical)
        return 5;
    buffer_support(physical);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i)
        if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            family = i;
            break;
        }
    assert(family != UINT32_MAX);
    float priority = 1;
    VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    q.queueFamilyIndex = family;
    q.queueCount = 1;
    q.pQueuePriorities = &priority;
    const char *extension = VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME;
    VkPhysicalDeviceBufferDeviceAddressFeatures bda{
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES};
    bda.bufferDeviceAddress = true;
    VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    info.pNext = &bda;
    info.queueCreateInfoCount = 1;
    info.pQueueCreateInfos = &q;
    info.enabledExtensionCount = 1;
    info.ppEnabledExtensionNames = &extension;
    VkDevice device;
    check(vkCreateDevice(physical, &info, nullptr, &device), "device");
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);
    VkPhysicalDeviceMemoryProperties memory;
    vkGetPhysicalDeviceMemoryProperties(physical, &memory);
    uint64_t pending = 0;
    for (uint32_t iteration = 1; iteration <= 64; ++iteration) {
        if (pending) {
            Ack ack;
            if (recv(peer, &ack, sizeof(ack), MSG_TRUNC) != sizeof(ack))
                break;
            assert(ack.sequence == pending);
        }
        Frame frame;
        frame.width = 80 + iteration;
        frame.height = 64 + iteration;
        frame.sequence = iteration;
        frame.bgra = iteration % 2;
        const uint64_t bytes = uint64_t(frame.width) * frame.height * 4;
        Buffer exported;
        create_buffer(exported, device, bytes);
        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(device, exported.buffer, &req);
        uint32_t type = 0;
        while (!(req.memoryTypeBits & (1u << type)) ||
               !(memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
            ++type;
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
        dedicated.buffer = exported.buffer;
        VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
        flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        flags.pNext = &dedicated;
        VkExportMemoryAllocateInfo export_info{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};
        export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        export_info.pNext = &flags;
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc.pNext = &export_info;
        alloc.memoryTypeIndex = type;
        alloc.allocationSize = req.size;
        check(vkAllocateMemory(device, &alloc, nullptr, &exported.memory), "export allocation");
        check(vkBindBufferMemory(device, exported.buffer, exported.memory, 0), "bind export");
        Commands fill;
        fill.begin(device, family);
        vkCmdFillBuffer(fill.command, exported.buffer, 0, bytes,
                        frame.bgra ? 0xff3366ccu : 0xffcc6633u);
        VkBufferMemoryBarrier release{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        release.buffer = exported.buffer;
        release.size = VK_WHOLE_SIZE;
        release.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        release.srcQueueFamilyIndex = family;
        release.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        vkCmdPipelineBarrier(fill.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 1, &release, 0,
                             nullptr);
        fill.finish(queue);
        VkMemoryGetFdInfoKHR fd_info{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};
        fd_info.memory = exported.memory;
        fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        int fd = -1;
        check(proc<PFN_vkGetMemoryFdKHR>(device, "vkGetMemoryFdKHR")(device, &fd_info, &fd),
              "export FD");
        frame.memory_type = type;
        frame.allocation_size = req.size;
        const bool sent = send_frame(peer, frame, fd);
        close(fd);
        if (!sent)
            break;
        pending = frame.sequence;
        // Destroy the producer's allocation immediately. The transferred FD
        // must keep the storage alive until Godot imports and finishes reading.
    }
    close(peer);
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
}
