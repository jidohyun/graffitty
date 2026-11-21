#pragma once
#include "../../../crates/transport/chromium-video/include/linux_vulkan.h"
#include "include/base/cef_logging.h"
#include "include/cef_render_handler.h"
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <poll.h>
#include <memory>
#include <chrono>

// Linux dma-buf UAPI. Jammy's build headers predate sync-file export.
#ifndef DMA_BUF_IOCTL_EXPORT_SYNC_FILE
struct dma_buf_export_sync_file {
    __u32 flags;
    __s32 fd;
};
#define DMA_BUF_IOCTL_EXPORT_SYNC_FILE _IOWR(DMA_BUF_BASE, 2, struct dma_buf_export_sync_file)
#endif

class GpuSender {
    int socket_ = -1;
    uint64_t pending_ = 0;
    chromium_linux::Frame queuedFrame_;
    int queuedFd_ = -1;
    VkInstance instance_ = VK_NULL_HANDLE;
    VkPhysicalDevice physical_ = VK_NULL_HANDLE;
    VkDevice device_ = VK_NULL_HANDLE;
    VkQueue queue_ = VK_NULL_HANDLE;
    uint32_t family_ = 0;
    bool failed_ = false;
    bool software_ = false;
    bool accepts_software_ = false;
    enum class FenceWait { unknown, sync_file, dma_buf };
    FenceWait fence_wait_ = FenceWait::unknown;
    bool use_screencast_ = false;
    void prepare(const chromium_linux::Hello &hello) {
        using namespace chromium_linux;
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.apiVersion = VK_API_VERSION_1_2;
        VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        ci.pApplicationInfo = &app;
        check(vkCreateInstance(&ci, nullptr, &instance_), "Vulkan instance");
        uint32_t count = 0;
        check(vkEnumeratePhysicalDevices(instance_, &count, nullptr), "enumerate GPUs");
        std::vector<VkPhysicalDevice> devices(count);
        check(vkEnumeratePhysicalDevices(instance_, &count, devices.data()), "enumerate GPUs");
        for (auto d : devices)
            if (same_device(hello, identity(d)))
                physical_ = d;
        if (!physical_)
            throw std::runtime_error("CEF host and Godot must use the same Vulkan GPU and driver");
        buffer_support(physical_);
        vkGetPhysicalDeviceQueueFamilyProperties(physical_, &count, nullptr);
        std::vector<VkQueueFamilyProperties> queues(count);
        vkGetPhysicalDeviceQueueFamilyProperties(physical_, &count, queues.data());
        bool found = false;
        for (uint32_t i = 0; i < count; ++i)
            if (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
                family_ = i;
                found = true;
                break;
            }
        if (!found)
            throw std::runtime_error("no Vulkan graphics queue");
        const char *extensions[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
                                    VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
                                    VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
                                    VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME};
        uint32_t extension_count = 0;
        check(vkEnumerateDeviceExtensionProperties(physical_, nullptr, &extension_count, nullptr),
              "device extensions");
        std::vector<VkExtensionProperties> available(extension_count);
        check(vkEnumerateDeviceExtensionProperties(physical_, nullptr, &extension_count,
                                                   available.data()),
              "device extensions");
        for (const char *required : extensions)
            if (std::none_of(available.begin(), available.end(),
                             [&](auto &e) { return !std::strcmp(e.extensionName, required); }))
                throw std::runtime_error(std::string("Missing ") + required +
                                         "; check DRM render-node permissions and driver support");
        float priority = 1;
        VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        q.queueFamilyIndex = family_;
        q.queueCount = 1;
        q.pQueuePriorities = &priority;
        VkPhysicalDeviceBufferDeviceAddressFeatures bda{
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES};
        bda.bufferDeviceAddress = VK_TRUE;
        VkDeviceCreateInfo d{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        d.pNext = &bda;
        d.queueCreateInfoCount = 1;
        d.pQueueCreateInfos = &q;
        d.enabledExtensionCount = std::size(extensions);
        d.ppEnabledExtensionNames = extensions;
        check(vkCreateDevice(physical_, &d, nullptr, &device_), "Vulkan DMA-BUF device");
        vkGetDeviceQueue(device_, family_, 0, &queue_);
    }
    void offer(const chromium_linux::Frame &frame, int fd) {
        if (queuedFd_ >= 0) { close(queuedFd_); ++dropped; }
        queuedFrame_ = frame;
        queuedFd_ = fd;
        flush();
    }
    struct Image {
        VkDevice device;
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        ~Image() {
            if (image)
                vkDestroyImage(device, image, nullptr);
            if (memory)
                vkFreeMemory(device, memory, nullptr);
        }
    };
    void wait_writer(int fd) {
        int sync_fd = -1;
        if (fence_wait_ != FenceWait::dma_buf) {
            dma_buf_export_sync_file request{DMA_BUF_SYNC_READ, -1};
            int status;
            do {
                status = ioctl(fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &request);
            } while (status < 0 && errno == EINTR);
            if (status == 0) {
                sync_fd = request.fd;
                if (fence_wait_ == FenceWait::unknown)
                    LOG(WARNING) << "DMA-BUF writer wait: exported sync_file";
                fence_wait_ = FenceWait::sync_file;
            } else if (errno == ENOTTY || errno == EOPNOTSUPP) {
                fence_wait_ = FenceWait::dma_buf;
                LOG(WARNING) << "DMA-BUF writer wait: implicit POLLIN (sync_file export unavailable)";
            } else {
                throw std::runtime_error(std::string("DMA-BUF writer fence export failed: ") +
                                         std::strerror(errno));
            }
        }
        // POLLIN waits for writers on the borrowed DMA-BUF, or for the
        // equivalent read fence on an exported sync_file.
        using namespace std::chrono;
        pollfd p{sync_fd >= 0 ? sync_fd : fd, POLLIN, 0};
        const auto deadline = steady_clock::now() + seconds(3);
        int status;
        do {
            auto remaining = ceil<milliseconds>(deadline - steady_clock::now()).count();
            status = remaining <= 0 ? 0 : poll(&p, 1, static_cast<int>(remaining));
        } while (status < 0 && errno == EINTR);
        const int error = errno;
        if (sync_fd >= 0) close(sync_fd);
        if (status < 0)
            throw std::runtime_error(std::string("DMA-BUF writer poll failed: ") + std::strerror(error));
        if (status == 0) throw std::runtime_error("DMA-BUF writer poll timed out");
        if ((p.revents & (POLLERR | POLLHUP | POLLNVAL)) || !(p.revents & POLLIN))
            throw std::runtime_error("DMA-BUF writer poll failed, revents=" + std::to_string(p.revents));
    }
    void import_image(const CefAcceleratedPaintInfo &info, Image &image) {
        using namespace chromium_linux;
        if (info.plane_count < 1 || info.plane_count > 4 || info.modifier == UINT64_MAX ||
            info.modifier == 0x00ffffffffffffffull)
            throw std::runtime_error(
                "DMA-BUF needs an explicit DRM modifier and 1-4 memory planes");
        VkSubresourceLayout planes[4]{};
        struct stat first{};
        if (fstat(info.planes[0].fd, &first))
            throw std::runtime_error("invalid DMA-BUF FD");
        for (int i = 0; i < info.plane_count; ++i) {
            struct stat current{};
            if (fstat(info.planes[i].fd, &current) || current.st_ino != first.st_ino ||
                current.st_dev != first.st_dev || !info.planes[i].stride)
                throw std::runtime_error("disjoint DMA-BUF allocations are not supported");
            planes[i].offset = info.planes[i].offset;
            planes[i].rowPitch = info.planes[i].stride;
        }
        wait_writer(info.planes[0].fd);
        VkImageDrmFormatModifierExplicitCreateInfoEXT modifier{
            VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT};
        modifier.drmFormatModifier = info.modifier;
        modifier.drmFormatModifierPlaneCount = info.plane_count;
        modifier.pPlaneLayouts = planes;
        VkExternalMemoryImageCreateInfo external{
            VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
        external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        external.pNext = &modifier;
        VkImageCreateInfo ci{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        ci.pNext = &external;
        ci.imageType = VK_IMAGE_TYPE_2D;
        ci.format = info.format == CEF_COLOR_TYPE_BGRA_8888 ? VK_FORMAT_B8G8R8A8_UNORM
                                                            : VK_FORMAT_R8G8B8A8_UNORM;
        ci.extent = {uint32_t(info.extra.coded_size.width), uint32_t(info.extra.coded_size.height),
                     1};
        ci.mipLevels = 1;
        ci.arrayLayers = 1;
        ci.samples = VK_SAMPLE_COUNT_1_BIT;
        ci.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
        ci.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        check(vkCreateImage(device_, &ci, nullptr, &image.image), "import DMA-BUF image/modifier");
        VkMemoryRequirements requirements;
        vkGetImageMemoryRequirements(device_, image.image, &requirements);
        VkMemoryFdPropertiesKHR properties{VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR};
        check(proc<PFN_vkGetMemoryFdPropertiesKHR>(device_, "vkGetMemoryFdPropertiesKHR")(
                  device_, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, info.planes[0].fd,
                  &properties),
              "DMA-BUF memory types");
        auto bits = requirements.memoryTypeBits & properties.memoryTypeBits;
        if (!bits)
            throw std::runtime_error("DMA-BUF is incompatible with Godot's GPU");
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
        dedicated.image = image.image;
        VkImportMemoryFdInfoKHR import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR};
        import.pNext = &dedicated;
        import.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        import.fd = fcntl(info.planes[0].fd, F_DUPFD_CLOEXEC, 0);
        if (import.fd < 0)
            throw std::runtime_error("duplicate DMA-BUF FD");
        VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        a.pNext = &import;
        a.allocationSize = requirements.size;
        a.memoryTypeIndex = __builtin_ctz(bits);
        auto result = vkAllocateMemory(device_, &a, nullptr, &image.memory);
        if (result != VK_SUCCESS)
            close(import.fd); // Vulkan consumes the FD only on success.
        check(result, "allocate DMA-BUF import");
        check(vkBindImageMemory(device_, image.image, image.memory, 0), "bind DMA-BUF image");
    }

  public:
    uint64_t gpu_frames = 0, cpu_frames = 0, sent = 0, dropped = 0, errors = 0;
    ~GpuSender() { shutdown(); }
    void shutdown() {
        if (queuedFd_ >= 0) close(queuedFd_);
        queuedFd_ = -1;
        if (socket_ >= 0) close(socket_);
        socket_ = -1;
        if (device_)
            vkDestroyDevice(device_, nullptr);
        if (instance_)
            vkDestroyInstance(instance_, nullptr);
        device_ = VK_NULL_HANDLE;
        instance_ = VK_NULL_HANDLE;
    }
    // Keep one in-flight offer and the newest unsent immutable allocation.
    // Poll from the UI tick too: a static page may never paint again after the
    // receiver acknowledges an earlier frame.
    void flush() {
        using namespace chromium_linux;
        if (failed_ || socket_ < 0) return;
        try {
            if (pending_) {
                Ack ack{};
                auto n = recv(socket_, &ack, sizeof(ack), MSG_DONTWAIT | MSG_TRUNC);
                if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
                if (n != sizeof(ack) || ack.sequence != pending_)
                    throw std::runtime_error("invalid frame acknowledgement");
                pending_ = 0;
            }
            if (queuedFd_ >= 0 && send_frame(socket_, queuedFrame_, queuedFd_)) {
                pending_ = queuedFrame_.sequence;
                close(queuedFd_);
                queuedFd_ = -1;
                ++sent;
            }
        } catch (const std::exception &e) {
            if (++errors == 1) fprintf(stderr, "[chromium Vulkan] %s\n", e.what());
            failed_ = true;
        }
    }
    bool start(const std::string &endpoint) {
        sockaddr_un a{};
        auto size = chromium_linux::address(endpoint.c_str(), a);
        if (!size)
            return false;
        // Keep this endpoint above Chrome's reserved debugging pipe descriptors.
        int created = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        socket_ = created < 0 ? -1 : fcntl(created, F_DUPFD_CLOEXEC, 10);
        if (created >= 0)
            close(created);
        using namespace chromium_linux;
        if (socket_ < 0 || connect(socket_, reinterpret_cast<sockaddr *>(&a), size) ||
            !same_user(socket_)) return false;
        // Control is already connected: the server can now pump the frame endpoint.
        pollfd peer{socket_, POLLIN, 0};
        int ready;
        do { ready = poll(&peer, 1, 10000); } while (ready < 0 && errno == EINTR);
        Hello hello;
        if (ready <= 0 || recv(socket_, &hello, sizeof(hello), MSG_TRUNC) != sizeof(hello) ||
            hello.magic != magic || hello.version != version || !hello.kinds ||
            (hello.kinds & ~(opaque_fd | sealed_memfd))) return false;
        accepts_software_ = (hello.kinds & sealed_memfd) != 0;
        if (hello.kinds & opaque_fd) {
            try {
                prepare(hello);
                return true;
            } catch (const std::exception &e) {
                fprintf(stderr, "[chromium Vulkan] %s\n", e.what());
            }
        }
        software_ = accepts_software_;
        return software_;
    }
    bool software() const { return software_; }
    bool needs_screencast() const { return use_screencast_; }
    bool transfer(const void *pixels, int width, int height) {
        using namespace chromium_linux;
        Frame frame;
        frame.sequence = gpu_frames + ++cpu_frames;
        frame.kind = sealed_memfd;
        frame.width = width;
        frame.height = height;
        frame.bgra = 1;
        frame.allocation_size = uint64_t(frame.width) * frame.height * 4;
        if (!software_ || failed_ || !pixels || !valid(frame)) return false;
        int fd = memfd_create("chromium-frame", MFD_CLOEXEC | MFD_ALLOW_SEALING);
        size_t offset = 0;
        while (fd >= 0 && offset < frame.allocation_size) {
            auto n = write(fd, static_cast<const char *>(pixels) + offset,
                           frame.allocation_size - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            offset += n;
        }
        if (offset != frame.allocation_size ||
            fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0) {
            if (fd >= 0) close(fd);
            if (++errors == 1) perror("create immutable Chromium frame");
            return false;
        }
        offer(frame, fd);
        return true;
    }
    bool owner_alive() const {
        pollfd p{socket_, POLLIN, 0};
        return !failed_ && socket_ >= 0 && poll(&p, 1, 0) >= 0 &&
               !(p.revents & (POLLHUP | POLLERR | POLLNVAL));
    }
    bool transfer(const CefAcceleratedPaintInfo &info) {
        using namespace chromium_linux;
        ++gpu_frames;
        try {
            if (failed_ || !device_ || software_) {
                ++dropped;
                return false;
            }
            Frame frame;
            frame.width = info.extra.coded_size.width;
            frame.height = info.extra.coded_size.height;
            frame.sequence = gpu_frames + cpu_frames;
            frame.bgra = info.format == CEF_COLOR_TYPE_BGRA_8888;
            const uint64_t bytes = uint64_t(frame.width) * frame.height * 4;
            frame.allocation_size = bytes;
            if (!valid(frame) || (info.format != CEF_COLOR_TYPE_BGRA_8888 &&
                                  info.format != CEF_COLOR_TYPE_RGBA_8888))
                throw std::runtime_error("unsupported CEF GPU frame size or format");
            Image source{device_};
            import_image(info, source);
            Buffer owned;
            create_buffer(owned, device_, bytes);
            VkMemoryRequirements req;
            vkGetBufferMemoryRequirements(device_, owned.buffer, &req);
            VkPhysicalDeviceMemoryProperties memory;
            vkGetPhysicalDeviceMemoryProperties(physical_, &memory);
            uint32_t type = UINT32_MAX;
            for (uint32_t i = 0; i < memory.memoryTypeCount; ++i)
                if ((req.memoryTypeBits & (1u << i)) &&
                    (memory.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                    type = i;
                    break;
                }
            if (type == UINT32_MAX)
                throw std::runtime_error("no GPU-local exportable memory");
            VkMemoryDedicatedAllocateInfo dedicated{
                VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
            dedicated.buffer = owned.buffer;
            VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
            flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
            flags.pNext = &dedicated;
            VkExportMemoryAllocateInfo export_info{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};
            export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
            export_info.pNext = &flags;
            VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
            a.pNext = &export_info;
            a.allocationSize = req.size;
            a.memoryTypeIndex = type;
            check(vkAllocateMemory(device_, &a, nullptr, &owned.memory),
                  "allocate owned GPU frame");
            check(vkBindBufferMemory(device_, owned.buffer, owned.memory, 0),
                  "bind owned GPU frame");
            Commands commands;
            commands.begin(device_, family_);
            VkImageMemoryBarrier image{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
            image.image = source.image;
            image.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
            image.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
            image.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
            image.srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
            image.dstQueueFamilyIndex = family_;
            image.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            vkCmdPipelineBarrier(commands.command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                 VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1,
                                 &image);
            VkBufferImageCopy copy{};
            copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
            copy.imageExtent = {frame.width, frame.height, 1};
            vkCmdCopyImageToBuffer(commands.command, source.image,
                                   VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, owned.buffer, 1, &copy);
            std::swap(image.oldLayout, image.newLayout);
            std::swap(image.srcQueueFamilyIndex, image.dstQueueFamilyIndex);
            image.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            image.dstAccessMask = 0;
            VkBufferMemoryBarrier buffer{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            buffer.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            buffer.srcQueueFamilyIndex = family_;
            buffer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
            buffer.buffer = owned.buffer;
            buffer.size = VK_WHOLE_SIZE;
            vkCmdPipelineBarrier(commands.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                 VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 1, &buffer, 1,
                                 &image);
            commands.finish(queue_); // CEF's borrowed image is safe to recycle now.
            VkMemoryGetFdInfoKHR get{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};
            get.memory = owned.memory;
            get.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
            int fd = -1;
            check(proc<PFN_vkGetMemoryFdKHR>(device_, "vkGetMemoryFdKHR")(device_, &get, &fd),
                  "export owned GPU frame");
            frame.memory_type = type;
            frame.allocation_size = req.size;
            offer(frame, fd);
            return true;
        } catch (const std::exception &e) {
            if (++errors == 1)
                fprintf(stderr, "[chromium Vulkan] %s\n", e.what());
            ++dropped;
            if (accepts_software_) {
                use_screencast_ = true;
                LOG(WARNING) << e.what() << "; switching to software capture via CDP";
                return false;
            }
            // A GPU-only receiver cannot consume a software fallback.
            failed_ = true;
            return false;
        }
    }
};
