#include "../../../../crates/transport/chromium-video/include/linux_vulkan.h"
#include <map>
#include <memory>

namespace {
using namespace chromium_linux;
struct Receiver {
    int listener = -1, connection = -1;
    VkDevice device = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t family = 0;
    uint64_t last_sequence = 0;
    bool failed = false;
    std::map<uint64_t, std::unique_ptr<Buffer>> frames;
    ~Receiver() {
        if (connection >= 0)
            close(connection);
        if (listener >= 0)
            close(listener);
        // Each dispatched frame retains this receiver through Godot's async
        // completion callback. No outstanding shader reads can reach here.
    }
    bool connect_peer() {
        if (connection >= 0)
            return true;
        int peer = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (peer < 0)
            return false;
        if (!same_user(peer)) {
            close(peer);
            return false;
        }
        auto hello = identity(physical);
        if (send(peer, &hello, sizeof(hello), MSG_NOSIGNAL) != sizeof(hello)) {
            close(peer);
            return false;
        }
        connection = peer;
        return true;
    }
};
} // namespace
extern "C" void *graffitty_gpu_receiver_create(const char *name) {
    auto r = std::make_unique<Receiver>();
    sockaddr_un a{};
    const auto size = chromium_linux::address(name, a);
    if (!size)
        return nullptr;
    r->listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (r->listener < 0 || bind(r->listener, reinterpret_cast<sockaddr *>(&a), size) ||
        listen(r->listener, 1))
        return nullptr;
    return r.release();
}
extern "C" void graffitty_gpu_receiver_destroy(void *pointer) {
    delete static_cast<Receiver *>(pointer);
}
extern "C" void graffitty_gpu_release_frame(void *pointer, uint64_t sequence) {
    auto r = static_cast<Receiver *>(pointer);
    if (r)
        r->frames.erase(sequence);
}
extern "C" uint64_t graffitty_gpu_receive_linux(void *pointer, uint64_t physical_handle,
                                              uint64_t device_handle, uint64_t queue_handle,
                                              uint32_t family, uint32_t *width, uint32_t *height,
                                              uint32_t *bgra, uint64_t *sequence) {
    auto r = static_cast<Receiver *>(pointer);
    if (!r || r->failed || !physical_handle || !device_handle || !queue_handle ||
        r->frames.size() >= 3)
        return 0;
    int fd = -1;
    try {
        auto device = reinterpret_cast<VkDevice>(device_handle);
        if (!r->device) {
            r->device = device;
            r->physical = reinterpret_cast<VkPhysicalDevice>(physical_handle);
            r->queue = reinterpret_cast<VkQueue>(queue_handle);
            r->family = family;
            chromium_linux::buffer_support(r->physical);
            // Godot 4.7 enables one queue per family and chooses the lowest
            // queueFlags value supporting transfer for its upload workers.
            // Their queue mutex is internal to Godot.
            //
            // Reject a shared family instead of racing those workers with our
            // acquire submission.
            uint32_t count = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(r->physical, &count, nullptr);
            std::vector<VkQueueFamilyProperties> families(count);
            vkGetPhysicalDeviceQueueFamilyProperties(r->physical, &count, families.data());
            uint32_t transfer_family = UINT32_MAX;
            VkQueueFlags picked = VK_QUEUE_FLAG_BITS_MAX_ENUM;
            for (uint32_t i = 0; i < count; ++i) {
                if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_TRANSFER_BIT) &&
                    families[i].queueFlags < picked) {
                    picked = families[i].queueFlags;
                    transfer_family = i;
                }
            }
            if (family >= count || transfer_family == UINT32_MAX || transfer_family == family)
                throw std::runtime_error("Vulkan chromium requires separate graphics and upload "
                                         "queue families on stock Godot");
            // This function exists only when Godot enabled external memory FD.
            chromium_linux::proc<PFN_vkGetMemoryFdKHR>(device, "vkGetMemoryFdKHR");
        }
        if (r->device != device || r->family != family ||
            r->queue != reinterpret_cast<VkQueue>(queue_handle))
            throw std::runtime_error("Godot Vulkan device/queue changed during chromium session");
        if (!r->connect_peer())
            return 0;
        Frame frame;
        const int received = receive_frame(r->connection, frame, fd);
        if (!received)
            return 0;
        if (received < 0 || frame.kind != opaque_fd || frame.sequence <= r->last_sequence)
            throw std::runtime_error("invalid or disconnected GPU frame stream");
        auto source = std::make_unique<Buffer>();
        create_buffer(*source, device, uint64_t(frame.width) * frame.height * 4);
        VkMemoryRequirements requirements;
        vkGetBufferMemoryRequirements(device, source->buffer, &requirements);
        if (!(requirements.memoryTypeBits & (1u << frame.memory_type)) ||
            requirements.size != frame.allocation_size)
            throw std::runtime_error(
                "GPU frame allocation doesn't match the receiving Vulkan device");
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
        dedicated.buffer = source->buffer;
        VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
        flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        flags.pNext = &dedicated;
        VkImportMemoryFdInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR};
        import.pNext = &flags;
        import.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        import.fd = fd;
        VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        a.pNext = &import;
        a.allocationSize = frame.allocation_size;
        a.memoryTypeIndex = frame.memory_type;
        check(vkAllocateMemory(device, &a, nullptr, &source->memory), "import owned Vulkan frame");
        fd = -1; // Consumed by Vulkan.
        check(vkBindBufferMemory(device, source->buffer, source->memory, 0),
              "bind imported Vulkan frame");
        Commands commands;
        commands.begin(device, family);
        VkBufferMemoryBarrier acquire{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        acquire.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        acquire.srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
        acquire.dstQueueFamilyIndex = family;
        acquire.buffer = source->buffer;
        acquire.size = VK_WHOLE_SIZE;
        vkCmdPipelineBarrier(commands.command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 1, &acquire, 0,
                             nullptr);
        commands.finish(r->queue);
        VkBufferDeviceAddressInfo info{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO};
        info.buffer = source->buffer;
        auto get_address = reinterpret_cast<PFN_vkGetBufferDeviceAddress>(
            vkGetDeviceProcAddr(device, "vkGetBufferDeviceAddress"));
        if (!get_address)
            get_address = proc<PFN_vkGetBufferDeviceAddress>(device, "vkGetBufferDeviceAddressKHR");
        const uint64_t address = get_address(device, &info);
        if (!address)
            throw std::runtime_error("Godot Vulkan buffer device address is unavailable");
        r->frames.emplace(frame.sequence, std::move(source));
        r->last_sequence = frame.sequence;
        Ack ack{frame.sequence};
        if (send(r->connection, &ack, sizeof(ack), MSG_NOSIGNAL) != sizeof(ack)) {
            r->frames.erase(frame.sequence);
            throw std::runtime_error("GPU frame acknowledgement failed");
        }
        *width = frame.width;
        *height = frame.height;
        *bgra = frame.bgra;
        *sequence = frame.sequence;
        return address;
    } catch (const std::exception &e) {
        if (fd >= 0)
            close(fd);
        fprintf(stderr, "[chromium Vulkan] %s\n", e.what());
        r->failed = true;
        if (r->connection >= 0) {
            close(r->connection);
            r->connection = -1;
        }
        return 0;
    }
}
