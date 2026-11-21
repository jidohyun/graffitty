#include "../include/frame_protocol_linux.h"
#include "vulkan_readback.h"
#include <sys/mman.h>
#include <sys/stat.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
// NVIDIA's header-only loader leaves its logging parameter unused.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#include <ffnvcodec/dynlink_loader.h>
#pragma GCC diagnostic pop
extern "C" {
struct Video;
Video *gv_encoder(int, int, int, int, int);
void gv_free(Video *);
void gv_set_bitrate(Video *, int);
int gl_encode_pixels(Video *, const uint8_t *, int, int, int, int, const uint8_t **, int *);
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_cuda.h>
}
#include <dlfcn.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <vector>

namespace {
// cuda.h's CUDA_EXTERNAL_MEMORY_DEDICATED; NVIDIA's loader headers omit it.
constexpr unsigned external_memory_dedicated = 0x1;

bool tracing() {
    const char *value = std::getenv("RUST_LOG");
    return value && std::strstr(value, "graffitty_video");
}

struct Device {
    CudaFunctions *cu = nullptr;
    AVBufferRef *hardware = nullptr;
    CUcontext context = nullptr;
    CUfunction scale = nullptr;
    chromium_linux::Hello hello;
    std::mutex mutex;
    int minimum[3][2] = {};
    std::atomic<uint64_t> readbacks{0};
    ~Device() {
        av_buffer_unref(&hardware);
        cuda_free_functions(&cu);
    }
};

// Pushes the shared primary context for the calling thread's CUDA calls.
struct Current {
    Device &device;
    bool pushed;
    explicit Current(Device &d) : device(d), pushed(d.cu->cuCtxPushCurrent(d.context) == CUDA_SUCCESS) {}
    ~Current() {
        CUcontext previous;
        if (pushed) device.cu->cuCtxPopCurrent(&previous);
    }
};

// Vulkan's identity for the CUDA device, which the host must match before it
// exports memory. Loaded at run time: Vulkan is optional for the server itself.
bool vulkan_identity(const CUuuid &uuid, chromium_linux::Hello &hello) {
    void *library = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) return false;
    auto loader = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(library, "vkGetInstanceProcAddr"));
    auto create = loader ? reinterpret_cast<PFN_vkCreateInstance>(loader(nullptr, "vkCreateInstance")) : nullptr;
    VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    application.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    info.pApplicationInfo = &application;
    VkInstance instance = VK_NULL_HANDLE;
    bool found = false;
    if (create && create(&info, nullptr, &instance) == VK_SUCCESS) {
        auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(loader(instance, "vkEnumeratePhysicalDevices"));
        auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties2>(loader(instance, "vkGetPhysicalDeviceProperties2"));
        auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(loader(instance, "vkDestroyInstance"));
        uint32_t count = 0;
        if (enumerate && properties && enumerate(instance, &count, nullptr) == VK_SUCCESS && count) {
            std::vector<VkPhysicalDevice> devices(count);
            if (enumerate(instance, &count, devices.data()) == VK_SUCCESS)
                for (auto physical : devices) {
                    VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
                    VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
                    p.pNext = &id;
                    properties(physical, &p);
                    if (!std::memcmp(id.deviceUUID, uuid.bytes, 16)) {
                        std::memcpy(hello.device_uuid, id.deviceUUID, 16);
                        std::memcpy(hello.driver_uuid, id.driverUUID, 16);
                        found = true;
                    }
                }
        }
        if (destroy) destroy(instance, nullptr);
    }
    // The loader stays mapped: its drivers may have started threads.
    return found;
}

Device *create_device(const char *ptx) {
    auto device = std::make_unique<Device>();
    if (cuda_load_functions(&device->cu, nullptr) < 0) return nullptr;
    auto &cu = *device->cu;
    if (!cu.cuImportExternalMemory || !cu.cuExternalMemoryGetMappedBuffer || !cu.cuDestroyExternalMemory ||
        !cu.cuDeviceGetUuid)
        return nullptr;
    // FFmpeg and these imports share device 0's primary context.
    if (av_hwdevice_ctx_create(&device->hardware, AV_HWDEVICE_TYPE_CUDA, nullptr, nullptr,
                               AV_CUDA_USE_PRIMARY_CONTEXT) < 0)
        return nullptr;
    auto hardware = reinterpret_cast<AVHWDeviceContext *>(device->hardware->data);
    device->context = static_cast<AVCUDADeviceContext *>(hardware->hwctx)->cuda_ctx;
    CUdevice ordinal;
    CUuuid uuid;
    if (cu.cuDeviceGet(&ordinal, 0) != CUDA_SUCCESS || cu.cuDeviceGetUuid(&uuid, ordinal) != CUDA_SUCCESS ||
        !vulkan_identity(uuid, device->hello))
        return nullptr;
    Current current(*device);
    CUmodule module;
    if (!current.pushed || cu.cuModuleLoadData(&module, ptx) != CUDA_SUCCESS ||
        cu.cuModuleGetFunction(&device->scale, module, "graffitty_scale") != CUDA_SUCCESS)
        return nullptr;
    return device.release();
}

// One device for the process lifetime; surfaces and encoders may outlive any capture.
Device *shared_device(const char *ptx) {
    static Device *device = nullptr;
    static std::once_flag once;
    std::call_once(once, [ptx] { device = create_device(ptx); });
    return device;
}

struct Surface {
    std::atomic<int> references{1};
    Device *owner;
    uint32_t width, height, pitch;
    bool bgra;
    CUexternalMemory memory = nullptr; // Null for allocations made here (tests).
    CUdeviceptr pointer = 0;
    std::vector<uint8_t> pixels;
    void *mapping = MAP_FAILED;
    const uint8_t *cpu_pixels() const {
        return mapping != MAP_FAILED ? static_cast<const uint8_t *>(mapping) : pixels.data();
    }
    ~Surface() {
        if (mapping != MAP_FAILED) munmap(mapping, size_t(pitch) * height);
        if (!owner) return;
        Current current(*owner);
        if (pointer) owner->cu->cuMemFree(pointer);
        if (memory) owner->cu->cuDestroyExternalMemory(memory);
    }
};

bool use_cuda(const char *mode) { return !mode || !std::strcmp(mode, "cuda"); }

struct Capture {
    Device *owner = nullptr;
    std::unique_ptr<VulkanReadback> vulkan;
    chromium_linux::Hello hello;
    int listener = -1, peer = -1;
    ~Capture() {
        if (peer >= 0) close(peer);
        if (listener >= 0) close(listener);
    }
};

struct Encoder {
    Device *owner = nullptr;
    Video *upload = nullptr;
    uint32_t width = 0, height = 0;
    uint64_t readbacks = 0;
    AVCodecContext *context = nullptr;
    AVFrame *frame = nullptr;
    AVPacket *packet = nullptr;
    int64_t pts = 0;
    uint64_t frames = 0, scaled = 0, initial_readbacks = 0;
    ~Encoder() {
        gv_free(upload);
        av_packet_free(&packet);
        av_frame_free(&frame);
        avcodec_free_context(&context);
    }
};

Surface *import_cpu(Capture &capture, const chromium_linux::Frame &frame, int fd) {
    auto surface = std::unique_ptr<Surface>(new Surface{{1}, nullptr, frame.width, frame.height,
                                                        frame.width * 4, frame.bgra != 0});
    if (frame.kind == chromium_linux::sealed_memfd) {
        constexpr int required = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK;
        const int seals = fcntl(fd, F_GET_SEALS);
        struct stat statbuf{};
        if (seals >= 0 && (seals & required) == required && fstat(fd, &statbuf) == 0 &&
            S_ISREG(statbuf.st_mode) && statbuf.st_size == static_cast<off_t>(frame.allocation_size))
            surface->mapping = mmap(nullptr, frame.allocation_size, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (surface->mapping == MAP_FAILED) return nullptr;
    } else if (capture.vulkan) {
        if (!capture.vulkan->read(frame, fd, surface->pixels)) return nullptr;
    } else {
        close(fd);
        return nullptr;
    }
    return surface.release();
}

Surface *import(Device &device, const chromium_linux::Frame &frame, int fd) {
    auto &cu = *device.cu;
    Current current(device);
    CUDA_EXTERNAL_MEMORY_HANDLE_DESC handle{};
    handle.type = CU_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD;
    handle.handle.fd = fd;
    handle.size = frame.allocation_size;
    // The host exports every frame as a dedicated buffer allocation; CUDA maps
    // the wrong memory unless the import says so.
    handle.flags = external_memory_dedicated;
    CUexternalMemory memory;
    // On success the driver owns the descriptor.
    if (!current.pushed || cu.cuImportExternalMemory(&memory, &handle) != CUDA_SUCCESS) {
        close(fd);
        return nullptr;
    }
    CUDA_EXTERNAL_MEMORY_BUFFER_DESC buffer{};
    buffer.size = frame.allocation_size;
    CUdeviceptr pointer;
    if (cu.cuExternalMemoryGetMappedBuffer(&pointer, memory, &buffer) != CUDA_SUCCESS) {
        cu.cuDestroyExternalMemory(memory);
        return nullptr;
    }
    auto surface = new Surface{{1}, &device, frame.width, frame.height, frame.width * 4, frame.bgra != 0};
    surface->memory = memory;
    surface->pointer = pointer;
    return surface;
}
} // namespace

extern "C" void *gl_capture_new(const char *name, const char *ptx) {
    auto capture = std::make_unique<Capture>();
    const char *mode = std::getenv("GRAFFITTY_CAPTURE");
    if (use_cuda(mode)) capture->owner = shared_device(ptx);
    if (!capture->owner && (!mode || !std::strcmp(mode, "vulkan")))
        capture->vulkan = VulkanReadback::create();
    if (capture->owner || capture->vulkan) {
        capture->hello = capture->owner ? capture->owner->hello : capture->vulkan->hello;
        capture->hello.kinds = chromium_linux::opaque_fd | chromium_linux::sealed_memfd;
    } else if (mode && std::strcmp(mode, "software")) {
        return nullptr;
    }
    sockaddr_un address;
    socklen_t size = chromium_linux::address(name, address);
    capture->listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (!size || capture->listener < 0 ||
        bind(capture->listener, reinterpret_cast<sockaddr *>(&address), size) ||
        listen(capture->listener, 1))
        return nullptr;
    return capture.release();
}
extern "C" void gl_capture_free(void *p) { delete static_cast<Capture *>(p); }
// Nonblocking. Acknowledges each frame on receipt: the imported allocation is
// independent of the host's next frame, so the host may render while we encode.
extern "C" void *gl_capture_receive(void *p, uint32_t *width, uint32_t *height) {
    auto &capture = *static_cast<Capture *>(p);
    if (capture.peer < 0) {
        int peer = accept4(capture.listener, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (peer < 0) return nullptr;
        const auto &hello = capture.hello;
        if (!chromium_linux::same_user(peer) ||
            send(peer, &hello, sizeof(hello), MSG_NOSIGNAL) != sizeof(hello)) {
            close(peer);
            return nullptr;
        }
        capture.peer = peer;
    }
    chromium_linux::Frame frame;
    int fd;
    const int received = chromium_linux::receive_frame(capture.peer, frame, fd);
    if (received < 0) {
        close(capture.peer);
        capture.peer = -1;
    }
    if (received <= 0) return nullptr;
    const chromium_linux::Ack ack{frame.sequence};
    // A host that exits right after its last frame cannot take the ack; the
    // frame itself is complete, so only the connection ends.
    if (send(capture.peer, &ack, sizeof(ack), MSG_NOSIGNAL | MSG_DONTWAIT) != sizeof(ack)) {
        close(capture.peer);
        capture.peer = -1;
    }
    Surface *surface = frame.kind == chromium_linux::opaque_fd && capture.owner
                           ? import(*capture.owner, frame, fd) : import_cpu(capture, frame, fd);
    if (!surface) return nullptr;
    *width = surface->width;
    *height = surface->height;
    return surface;
}

extern "C" void *gl_surface_clone(void *p) {
    ++static_cast<Surface *>(p)->references;
    return p;
}
extern "C" void gl_surface_free(void *p) {
    auto surface = static_cast<Surface *>(p);
    if (--surface->references == 0) delete surface;
}
extern "C" bool gl_surface_is_software_paint(void *p) {
    return static_cast<Surface *>(p)->mapping != MAP_FAILED;
}
extern "C" int gl_surface_rgba(void *p, uint8_t *out) {
    auto &surface = *static_cast<Surface *>(p);
    if (!surface.owner) {
        const size_t bytes = size_t(surface.pitch) * surface.height;
        std::memcpy(out, surface.cpu_pixels(), bytes);
        if (surface.bgra)
            for (size_t i = 0; i < bytes; i += 4) std::swap(out[i], out[i + 2]);
        return 0;
    }
    auto &device = *surface.owner;
    Current current(device);
    CUDA_MEMCPY2D copy{};
    copy.srcMemoryType = CU_MEMORYTYPE_DEVICE;
    copy.srcDevice = surface.pointer;
    copy.srcPitch = surface.pitch;
    copy.dstMemoryType = CU_MEMORYTYPE_HOST;
    copy.dstHost = out;
    copy.dstPitch = surface.width * 4;
    copy.WidthInBytes = surface.width * 4;
    copy.Height = surface.height;
    if (!current.pushed || device.cu->cuMemcpy2D(&copy) != CUDA_SUCCESS) return -1;
    ++device.readbacks;
    if (surface.bgra)
        for (size_t i = 0; i < size_t(surface.width) * surface.height * 4; i += 4) std::swap(out[i], out[i + 2]);
    return 0;
}
// Construct a device allocation for capability probes and test fixtures.
extern "C" void *gl_surface_from_rgba(const char *ptx, uint32_t width, uint32_t height, const uint8_t *data,
                                      int bgra) {
    Device *device = shared_device(ptx);
    if (!device) return nullptr;
    Current current(*device);
    CUdeviceptr pointer;
    const size_t bytes = size_t(width) * height * 4;
    if (!current.pushed || device->cu->cuMemAlloc(&pointer, bytes) != CUDA_SUCCESS) return nullptr;
    std::vector<uint8_t> pixels(data, data + bytes);
    if (bgra)
        for (size_t i = 0; i < bytes; i += 4) std::swap(pixels[i], pixels[i + 2]);
    if (device->cu->cuMemcpyHtoD(pointer, pixels.data(), bytes) != CUDA_SUCCESS) {
        device->cu->cuMemFree(pointer);
        return nullptr;
    }
    auto surface = new Surface{{1}, device, width, height, width * 4, bgra != 0};
    surface->pointer = pointer;
    return surface;
}

extern "C" void *gl_video_probe_surface(const char *ptx) {
    constexpr uint32_t size = 256;
    std::vector<uint8_t> pixels(size * size * 4, 96);
    const char *mode = std::getenv("GRAFFITTY_CAPTURE");
    if (use_cuda(mode) && shared_device(ptx))
        return gl_surface_from_rgba(ptx, size, size, pixels.data(), 1);
    auto surface = new Surface{{1}, nullptr, size, size, size * 4, true};
    surface->pixels = std::move(pixels);
    return surface;
}

extern "C" int gl_video_minimum(void *p, int codec, uint32_t *width, uint32_t *height) {
    if (!p || !static_cast<Surface *>(p)->owner || codec < 0 || codec > 2) return 0;
    auto &device = *static_cast<Surface *>(p)->owner;
    std::lock_guard lock(device.mutex);
    auto &minimum = device.minimum[codec];
    if (!minimum[0]) {
        minimum[0] = minimum[1] = -1;
        NvencFunctions *functions = nullptr;
        NV_ENCODE_API_FUNCTION_LIST api = {NV_ENCODE_API_FUNCTION_LIST_VER};
        if (nvenc_load_functions(&functions, nullptr) == 0 && functions->NvEncodeAPICreateInstance(&api) == NV_ENC_SUCCESS) {
            NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open = {NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER};
            open.device = device.context;
            open.deviceType = NV_ENC_DEVICE_TYPE_CUDA;
            open.apiVersion = NVENCAPI_VERSION;
            void *session = nullptr;
            if (api.nvEncOpenEncodeSessionEx(&open, &session) == NV_ENC_SUCCESS) {
                const GUID formats[] = {NV_ENC_CODEC_H264_GUID, NV_ENC_CODEC_HEVC_GUID, NV_ENC_CODEC_AV1_GUID};
                NV_ENC_CAPS_PARAM caps = {NV_ENC_CAPS_PARAM_VER};
                int w = 0, h = 0;
                caps.capsToQuery = NV_ENC_CAPS_WIDTH_MIN;
                auto status = api.nvEncGetEncodeCaps(session, formats[codec], &caps, &w);
                caps.capsToQuery = NV_ENC_CAPS_HEIGHT_MIN;
                if (status == NV_ENC_SUCCESS &&
                    api.nvEncGetEncodeCaps(session, formats[codec], &caps, &h) == NV_ENC_SUCCESS && w > 0 &&
                    h > 0 && w <= 4096 && h <= 4096) {
                    minimum[0] = w;
                    minimum[1] = h;
                }
                api.nvEncDestroyEncoder(session);
            }
        }
        nvenc_free_functions(&functions);
    }
    if (minimum[0] < 0) return 0;
    *width = minimum[0];
    *height = minimum[1];
    return 1;
}

extern "C" void *gl_video_new(void *p, int codec, int width, int height, int bitrate, int fps) {
    if (!p || codec < 0 || codec > 2 || width < 16 || height < 16 || width > 4096 || height > 4096 ||
        ((width | height) & 1) || bitrate < 0 || bitrate > 200000000 || fps < 1 || fps > 120)
        return nullptr;
    auto &source = *static_cast<Surface *>(p);
    if (!source.owner) {
        auto encoder = std::make_unique<Encoder>();
        encoder->upload = gv_encoder(codec, width, height, bitrate, fps);
        if (!encoder->upload) return nullptr;
        encoder->width = width;
        encoder->height = height;
        return encoder.release();
    }
    const char *names[] = {"h264_nvenc", "hevc_nvenc", "av1_nvenc"};
    const AVCodec *implementation = avcodec_find_encoder_by_name(names[codec]);
    if (!implementation) return nullptr;
    auto encoder = std::make_unique<Encoder>();
    encoder->owner = source.owner;
    encoder->initial_readbacks = source.owner->readbacks.load();
    encoder->context = avcodec_alloc_context3(implementation);
    encoder->frame = av_frame_alloc();
    encoder->packet = av_packet_alloc();
    if (!encoder->context || !encoder->frame || !encoder->packet) return nullptr;
    // NVENC reads 32-bit RGB directly and converts to YUV 4:2:0 itself.
    const auto format = source.bgra ? AV_PIX_FMT_BGR0 : AV_PIX_FMT_RGB0;
    AVCodecContext *context = encoder->context;
    context->hw_frames_ctx = av_hwframe_ctx_alloc(source.owner->hardware);
    if (!context->hw_frames_ctx) return nullptr;
    auto frames = reinterpret_cast<AVHWFramesContext *>(context->hw_frames_ctx->data);
    frames->format = AV_PIX_FMT_CUDA;
    frames->sw_format = format;
    frames->width = width;
    frames->height = height;
    if (av_hwframe_ctx_init(context->hw_frames_ctx) < 0) return nullptr;
    context->width = width;
    context->height = height;
    context->pix_fmt = AV_PIX_FMT_CUDA;
    context->sw_pix_fmt = format;
    context->time_base = {1, fps};
    context->framerate = {fps, 1};
    context->color_range = AVCOL_RANGE_MPEG;
    context->gop_size = fps * 10;
    context->max_b_frames = 0;
    context->bit_rate = bitrate ? bitrate : int64_t(width) * height * 8;
    context->flags |= AV_CODEC_FLAG_LOW_DELAY;
    context->thread_count = 1;
    AVDictionary *options = nullptr;
    for (auto option : {std::pair{"preset", "p1"}, {"tune", "ull"}, {"zerolatency", "1"}, {"delay", "0"},
                        {"rc-lookahead", "0"}, {"forced-idr", "1"}, {"rgb_mode", "yuv420"}, {"surfaces", "4"}})
        av_dict_set(&options, option.first, option.second, 0);
    const int result = avcodec_open2(context, implementation, &options);
    const bool unrecognized = av_dict_count(options) != 0;
    av_dict_free(&options);
    if (result < 0 || unrecognized) return nullptr;
    if (tracing())
        std::fprintf(stderr, "NVENC CUDA encoder=%s size=%dx%d fps=%d gpu_input=true\n", names[codec], width,
                     height, fps);
    return encoder.release();
}
extern "C" void gl_video_free(void *p) { delete static_cast<Encoder *>(p); }
// NVENC reconfigures its live session for a new average bit rate; VA-API and
// QSV keep the rate they opened with.
extern "C" void gl_video_set_bitrate(void *p, int bitrate) {
    auto *encoder = static_cast<Encoder *>(p);
    if (encoder && encoder->upload) gv_set_bitrate(encoder->upload, bitrate);
    if (encoder && encoder->context && bitrate > 0) encoder->context->bit_rate = bitrate;
}
extern "C" int gl_video_encode(void *p, void *s, int force_key, const uint8_t **bytes, int *key) {
    auto &encoder = *static_cast<Encoder *>(p);
    auto &source = *static_cast<Surface *>(s);
    if (source.owner != encoder.owner) return -1;
    if (encoder.upload) {
        const int size = gl_encode_pixels(encoder.upload, source.cpu_pixels(), source.width, source.height,
                                          source.bgra, force_key, bytes, key);
        if (size >= 0) {
            ++encoder.frames;
            encoder.scaled += source.width != encoder.width || source.height != encoder.height;
            encoder.readbacks += source.mapping == MAP_FAILED;
        }
        return size;
    }
    auto &device = *encoder.owner;
    AVFrame *frame = encoder.frame;
    av_frame_unref(frame);
    if (av_hwframe_get_buffer(encoder.context->hw_frames_ctx, frame, 0) < 0) return -1;
    const unsigned width = encoder.context->width, height = encoder.context->height;
    {
        Current current(device);
        bool copied = current.pushed;
        if (copied && source.width == width && source.height == height) {
            CUDA_MEMCPY2D copy{};
            copy.srcMemoryType = CU_MEMORYTYPE_DEVICE;
            copy.srcDevice = source.pointer;
            copy.srcPitch = source.pitch;
            copy.dstMemoryType = CU_MEMORYTYPE_DEVICE;
            copy.dstDevice = reinterpret_cast<CUdeviceptr>(frame->data[0]);
            copy.dstPitch = frame->linesize[0];
            copy.WidthInBytes = width * 4;
            copy.Height = height;
            copied = device.cu->cuMemcpy2D(&copy) == CUDA_SUCCESS;
        } else if (copied) {
            CUdeviceptr destination = reinterpret_cast<CUdeviceptr>(frame->data[0]);
            unsigned pitch = frame->linesize[0];
            void *arguments[] = {&source.pointer, &source.width, &source.height, &source.pitch,
                                 &destination, const_cast<unsigned *>(&width), const_cast<unsigned *>(&height),
                                 &pitch};
            // NVENC reads the frame after this returns; finish the kernel first.
            copied = device.cu->cuLaunchKernel(device.scale, (width + 15) / 16, (height + 15) / 16, 1, 16, 16, 1, 0,
                                               nullptr, arguments, nullptr) == CUDA_SUCCESS &&
                     device.cu->cuStreamSynchronize(nullptr) == CUDA_SUCCESS;
            encoder.scaled += copied;
        }
        if (!copied) {
            av_frame_unref(frame);
            return -1;
        }
    }
    frame->pts = encoder.pts++;
    frame->pict_type = force_key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    int result = avcodec_send_frame(encoder.context, frame);
    av_frame_unref(frame);
    if (result < 0) return -1;
    ++encoder.frames;
    av_packet_unref(encoder.packet);
    result = avcodec_receive_packet(encoder.context, encoder.packet);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0) return -1;
    *bytes = encoder.packet->data;
    *key = !!(encoder.packet->flags & AV_PKT_FLAG_KEY);
    return encoder.packet->size;
}
extern "C" void gl_video_stats(void *p, uint64_t *frames, uint64_t *scaled, uint64_t *readbacks) {
    auto &encoder = *static_cast<Encoder *>(p);
    *frames = encoder.frames;
    *scaled = encoder.scaled;
    *readbacks = encoder.upload ? encoder.readbacks : encoder.owner->readbacks.load() - encoder.initial_readbacks;
}
