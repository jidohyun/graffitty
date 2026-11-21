// GPU-generated pixels -> OPAQUE_FD -> second Vulkan device -> diagnostic readback.
// This test alone reads pixel bytes back; the production path uses a compute shader.
#include "../../../frontends/godot/extension/src/chromium_gpu_linux.cpp"
#include "../../../apps/server/chromium/linux_gpu_sender.h"
#include <cassert>
#include <thread>
#include <chrono>

struct Device {
    VkDevice handle = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    ~Device() {
        if (handle)
            vkDestroyDevice(handle, nullptr);
    }
};
static void test_dma(VkPhysicalDevice physical, Device &producer, Device &consumer,
                     uint32_t family) {
    const auto endpoint = "graffitty-dma-test." + std::to_string(getpid());
    auto *r = static_cast<Receiver *>(graffitty_gpu_receiver_create(endpoint.c_str()));
    assert(r);
    GpuSender sender;
    assert(sender.start(endpoint));
    uint32_t w = 0, h = 0, bgra = 0;
    uint64_t sequence = 0;
    auto receive = [&]() {
        return graffitty_gpu_receive_linux(
            r, reinterpret_cast<uint64_t>(physical), reinterpret_cast<uint64_t>(consumer.handle),
            reinterpret_cast<uint64_t>(consumer.queue), family, &w, &h, &bgra, &sequence);
    };
    assert(receive() == 0); // Send the device UUID handshake.
    VkDrmFormatModifierPropertiesListEXT modifiers{
        VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT};
    VkFormatProperties2 formats{VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2};
    formats.pNext = &modifiers;
    vkGetPhysicalDeviceFormatProperties2(physical, VK_FORMAT_B8G8R8A8_UNORM, &formats);
    std::vector<VkDrmFormatModifierPropertiesEXT> choices(modifiers.drmFormatModifierCount);
    modifiers.pDrmFormatModifierProperties = choices.data();
    vkGetPhysicalDeviceFormatProperties2(physical, VK_FORMAT_B8G8R8A8_UNORM, &formats);
    uint64_t modifier = UINT64_MAX;
    uint32_t plane_count = 0;
    for (auto &candidate : choices) {
        if (candidate.drmFormatModifierPlaneCount != 1)
            continue;
        VkPhysicalDeviceImageDrmFormatModifierInfoEXT drm{
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT};
        drm.drmFormatModifier = candidate.drmFormatModifier;
        drm.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkPhysicalDeviceExternalImageFormatInfo external{
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO};
        external.pNext = &drm;
        external.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        VkPhysicalDeviceImageFormatInfo2 info{
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};
        info.pNext = &external;
        info.format = VK_FORMAT_B8G8R8A8_UNORM;
        info.type = VK_IMAGE_TYPE_2D;
        info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
        info.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        VkExternalImageFormatProperties ext{VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};
        VkImageFormatProperties2 props{VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2};
        props.pNext = &ext;
        if (vkGetPhysicalDeviceImageFormatProperties2(physical, &info, &props) == VK_SUCCESS &&
            (ext.externalMemoryProperties.externalMemoryFeatures &
             VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT)) {
            modifier = candidate.drmFormatModifier;
            plane_count = 1;
            break;
        }
    }
    assert(plane_count == 1);
    VkImageDrmFormatModifierListCreateInfoEXT drm{
        VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT};
    drm.drmFormatModifierCount = 1;
    drm.pDrmFormatModifiers = &modifier;
    VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
    external.pNext = &drm;
    external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    info.pNext = &external;
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = VK_FORMAT_B8G8R8A8_UNORM;
    info.extent = {128, 64, 1};
    info.mipLevels = info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    info.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage image;
    check(vkCreateImage(producer.handle, &info, nullptr, &image), "test DMA-BUF image");
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(producer.handle, image, &req);
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    dedicated.image = image;
    VkExportMemoryAllocateInfo export_info{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};
    export_info.pNext = &dedicated;
    export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.pNext = &export_info;
    alloc.allocationSize = req.size;
    alloc.memoryTypeIndex = __builtin_ctz(req.memoryTypeBits);
    VkDeviceMemory memory;
    check(vkAllocateMemory(producer.handle, &alloc, nullptr, &memory), "test DMA-BUF allocation");
    check(vkBindImageMemory(producer.handle, image, memory, 0), "test bind image");
    Commands fill;
    fill.begin(producer.handle, family);
    VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.image = image;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(fill.command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &barrier);
    VkClearColorValue red{{1.f, 0.f, 0.f, 1.f}};
    vkCmdClearColorImage(fill.command, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &red, 1,
                         &barrier.subresourceRange);
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = 0;
    barrier.srcQueueFamilyIndex = family;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
    vkCmdPipelineBarrier(fill.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 1,
                         &barrier);
    fill.finish(producer.queue);
    VkMemoryGetFdInfoKHR fd_info{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};
    fd_info.memory = memory;
    fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    int fd = -1;
    check(proc<PFN_vkGetMemoryFdKHR>(producer.handle, "vkGetMemoryFdKHR")(producer.handle, &fd_info,
                                                                          &fd),
          "test export DMA-BUF");
    VkImageSubresource sub{VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT, 0, 0};
    VkSubresourceLayout layout;
    vkGetImageSubresourceLayout(producer.handle, image, &sub, &layout);
    CefAcceleratedPaintInfo paint;
    paint.format = CEF_COLOR_TYPE_BGRA_8888;
    paint.modifier = modifier;
    paint.plane_count = 1;
    paint.planes[0].fd = fd;
    paint.planes[0].offset = layout.offset;
    paint.planes[0].stride = layout.rowPitch;
    paint.planes[0].size = layout.size;
    paint.extra.coded_size = {128, 64};
    assert(sender.transfer(paint));
    assert(receive() && w == 128 && h == 64 && bgra);
    // The sender has already completed its GPU copy. Destroy the original
    // allocation before checking the imported immutable copy's contents.
    close(fd);
    vkDestroyImage(producer.handle, image, nullptr);
    vkFreeMemory(producer.handle, memory, nullptr);
    Buffer staging;
    staging.device = consumer.handle;
    VkBufferCreateInfo buffer{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    buffer.size = uint64_t(w) * h * 4;
    buffer.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    check(vkCreateBuffer(consumer.handle, &buffer, nullptr, &staging.buffer), "DMA test staging");
    vkGetBufferMemoryRequirements(consumer.handle, staging.buffer, &req);
    VkPhysicalDeviceMemoryProperties types;
    vkGetPhysicalDeviceMemoryProperties(physical, &types);
    uint32_t type = 0;
    const auto host = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    while (!(req.memoryTypeBits & (1u << type)) ||
           (types.memoryTypes[type].propertyFlags & host) != host)
        ++type;
    alloc.pNext = nullptr;
    alloc.memoryTypeIndex = type;
    alloc.allocationSize = req.size;
    check(vkAllocateMemory(consumer.handle, &alloc, nullptr, &staging.memory),
          "DMA staging memory");
    check(vkBindBufferMemory(consumer.handle, staging.buffer, staging.memory, 0),
          "DMA staging bind");
    Commands read;
    read.begin(consumer.handle, family);
    VkBufferCopy region{0, 0, buffer.size};
    vkCmdCopyBuffer(read.command, r->frames.at(sequence)->buffer, staging.buffer, 1, &region);
    VkBufferMemoryBarrier host_read{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
    host_read.buffer = staging.buffer;
    host_read.size = VK_WHOLE_SIZE;
    host_read.srcQueueFamilyIndex = host_read.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    host_read.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    host_read.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(read.command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, nullptr, 1, &host_read, 0, nullptr);
    read.finish(consumer.queue);
    void *mapped;
    check(vkMapMemory(consumer.handle, staging.memory, 0, buffer.size, 0, &mapped),
          "DMA diagnostic map");
    for (size_t i = 0; i < buffer.size / 4; ++i)
        assert(static_cast<uint32_t *>(mapped)[i] == 0xffff0000u);
    vkUnmapMemory(consumer.handle, staging.memory);
    graffitty_gpu_release_frame(r, sequence);
    graffitty_gpu_receiver_destroy(r);
    puts("PASS: DMA-BUF modifier import, writer fence, GPU copy, original allocation destroyed, "
         "exact red pixels");
}
int main() {
    int result = 0;
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_2;
    VkInstanceCreateInfo ci{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pApplicationInfo = &app;
    VkInstance instance;
    check(vkCreateInstance(&ci, nullptr, &instance), "instance");
    {
        uint32_t count = 0;
        check(vkEnumeratePhysicalDevices(instance, &count, nullptr), "GPU count");
        std::vector<VkPhysicalDevice> devices(count);
        check(vkEnumeratePhysicalDevices(instance, &count, devices.data()), "GPUs");
        VkPhysicalDevice physical = VK_NULL_HANDLE;
        for (auto p : devices) {
            VkPhysicalDeviceProperties props;
            vkGetPhysicalDeviceProperties(p, &props);
            if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                physical = p;
                break;
            }
        }
        if (!physical)
            throw std::runtime_error("Test requires a hardware Vulkan GPU");
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(physical, &props);
        printf("GPU: %s\n", props.deviceName);
        uint32_t extension_count = 0;
        check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &extension_count, nullptr),
              "extensions");
        std::vector<VkExtensionProperties> available(extension_count);
        check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &extension_count,
                                                   available.data()),
              "extensions");
        const bool has_dma = std::any_of(available.begin(), available.end(), [](auto &e) {
            return !std::strcmp(e.extensionName, VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME);
        });
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
        Device producer, consumer;
        for (auto *d : {&producer, &consumer}) {
            float priority = 1;
            VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
            q.queueFamilyIndex = family;
            q.queueCount = 1;
            q.pQueuePriorities = &priority;
            const char *extensions[] = {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
                                        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
                                        VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
                                        VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME};
            VkPhysicalDeviceBufferDeviceAddressFeatures bda{
                VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES};
            bda.bufferDeviceAddress = true;
            VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
            info.pNext = &bda;
            info.queueCreateInfoCount = 1;
            info.pQueueCreateInfos = &q;
            info.enabledExtensionCount = d == &producer && has_dma ? 4 : 1;
            info.ppEnabledExtensionNames = extensions;
            check(vkCreateDevice(physical, &info, nullptr, &d->handle), "device");
            vkGetDeviceQueue(d->handle, family, 0, &d->queue);
        }
        const std::string endpoint = "graffitty-vulkan-test." + std::to_string(getpid());
        auto *r = static_cast<Receiver *>(graffitty_gpu_receiver_create(endpoint.c_str()));
        assert(r);
        int peer = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
        sockaddr_un address_info{};
        auto size = address(endpoint.c_str(), address_info);
        assert(connect(peer, reinterpret_cast<sockaddr *>(&address_info), size) == 0);
        uint32_t w = 0, h = 0, bgra = 0;
        uint64_t sequence = 0;
        auto receive = [&]() {
            return graffitty_gpu_receive_linux(r, reinterpret_cast<uint64_t>(physical),
                                             reinterpret_cast<uint64_t>(consumer.handle),
                                             reinterpret_cast<uint64_t>(consumer.queue), family, &w,
                                             &h, &bgra, &sequence);
        };
        assert(receive() == 0);
        Hello hello;
        assert(recv(peer, &hello, sizeof(hello), 0) == sizeof(hello));
        assert(same_device(hello, identity(physical)));
        VkPhysicalDeviceMemoryProperties memory;
        vkGetPhysicalDeviceMemoryProperties(physical, &memory);
        // Repeated sizes catch import/retirement and allocation mismatches.
        for (uint32_t iteration = 1; iteration <= 32; ++iteration) {
            Frame frame;
            frame.width = 16 + iteration;
            frame.height = 11 + iteration;
            frame.sequence = iteration;
            const uint64_t bytes = uint64_t(frame.width) * frame.height * 4;
            Buffer exported;
            create_buffer(exported, producer.handle, bytes);
            VkMemoryRequirements req;
            vkGetBufferMemoryRequirements(producer.handle, exported.buffer, &req);
            uint32_t type = 0;
            while (!(req.memoryTypeBits & (1u << type)) ||
                   !(memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
                ++type;
            VkMemoryDedicatedAllocateInfo dedicated{
                VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
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
            check(vkAllocateMemory(producer.handle, &alloc, nullptr, &exported.memory),
                  "export allocation");
            check(vkBindBufferMemory(producer.handle, exported.buffer, exported.memory, 0),
                  "bind export");
            Commands fill;
            fill.begin(producer.handle, family);
            const uint32_t pattern = 0xff123400u + iteration;
            vkCmdFillBuffer(fill.command, exported.buffer, 0, bytes, pattern);
            VkBufferMemoryBarrier release{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            release.buffer = exported.buffer;
            release.size = VK_WHOLE_SIZE;
            release.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            release.srcQueueFamilyIndex = family;
            release.dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL;
            vkCmdPipelineBarrier(fill.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                 VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 1, &release,
                                 0, nullptr);
            fill.finish(producer.queue);
            VkMemoryGetFdInfoKHR fd_info{VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR};
            fd_info.memory = exported.memory;
            fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
            int fd = -1;
            check(proc<PFN_vkGetMemoryFdKHR>(producer.handle, "vkGetMemoryFdKHR")(producer.handle,
                                                                                  &fd_info, &fd),
                  "export FD");
            frame.memory_type = type;
            frame.allocation_size = req.size;
            assert(send_frame(peer, frame, fd));
            close(fd);
            assert(receive() != 0 && w == frame.width && h == frame.height &&
                   sequence == iteration);
            Ack ack;
            assert(recv(peer, &ack, sizeof(ack), 0) == sizeof(ack) && ack.sequence == iteration);
            Buffer staging;
            staging.device = consumer.handle;
            VkBufferCreateInfo buffer{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
            buffer.size = bytes;
            buffer.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
            check(vkCreateBuffer(consumer.handle, &buffer, nullptr, &staging.buffer), "staging");
            vkGetBufferMemoryRequirements(consumer.handle, staging.buffer, &req);
            type = 0;
            const auto host =
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
            while (!(req.memoryTypeBits & (1u << type)) ||
                   (memory.memoryTypes[type].propertyFlags & host) != host)
                ++type;
            alloc.pNext = nullptr;
            alloc.memoryTypeIndex = type;
            alloc.allocationSize = req.size;
            check(vkAllocateMemory(consumer.handle, &alloc, nullptr, &staging.memory),
                  "staging memory");
            check(vkBindBufferMemory(consumer.handle, staging.buffer, staging.memory, 0),
                  "bind staging");
            Commands read;
            read.begin(consumer.handle, family);
            VkBufferCopy region{0, 0, bytes};
            vkCmdCopyBuffer(read.command, r->frames.at(sequence)->buffer, staging.buffer, 1,
                            &region);
            VkBufferMemoryBarrier host_read{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            host_read.buffer = staging.buffer;
            host_read.size = VK_WHOLE_SIZE;
            host_read.srcQueueFamilyIndex = host_read.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
            host_read.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            host_read.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
            vkCmdPipelineBarrier(read.command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                                 VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1, &host_read, 0,
                                 nullptr);
            read.finish(consumer.queue);
            void *mapped = nullptr;
            check(vkMapMemory(consumer.handle, staging.memory, 0, bytes, 0, &mapped),
                  "map diagnostic");
            for (size_t i = 0; i < bytes / 4; ++i)
                assert(static_cast<uint32_t *>(mapped)[i] == pattern);
            vkUnmapMemory(consumer.handle, staging.memory);
            graffitty_gpu_release_frame(r, sequence);
            assert(r->frames.empty());
        }
        close(peer);
        graffitty_gpu_receiver_destroy(r);
        puts("PASS: 32 GPU-filled frames shared between Vulkan devices; exact pixel contents and "
             "retirement");
        if (has_dma)
            test_dma(physical, producer, consumer, family);
        else {
            fputs("SKIP: hardware DMA-BUF unavailable; check DRM render-node permissions/driver "
                  "(exit 77)\n",
                  stderr);
            result = 77;
        }
    }
    vkDestroyInstance(instance, nullptr);
    if (!result)
        puts("PASS: complete Vulkan buffer and DMA-BUF tests");
    return result;
}
