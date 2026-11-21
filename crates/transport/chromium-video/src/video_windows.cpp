#define NOMINMAX
#include <initguid.h>
#include "windows_surface.h"
#include <dxgi1_2.h>
#include <d3d10.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <ffnvcodec/nvEncodeAPI.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
}
using Microsoft::WRL::ComPtr;
using graffitty::WindowsDevice;
using graffitty::WindowsSurface;

namespace {
bool tracing() {
    const char *value = std::getenv("RUST_LOG");
    return value && std::strstr(value, "graffitty_video");
}
void lock_device(void *p) { static_cast<WindowsDevice *>(p)->mutex.lock(); }
void unlock_device(void *p) { static_cast<WindowsDevice *>(p)->mutex.unlock(); }
enum class Backend { Nvenc, Qsv, Amf, Mf };
struct Encoder {
    std::shared_ptr<WindowsDevice> owner;
    AVCodecContext *context = nullptr;
    AVFrame *frame = nullptr;
    AVFrame *mapped = nullptr; // D3D11 view of a QSV input frame.
    AVPacket *packet = nullptr;
    // Reuse the successful negotiation keyframe if the caller supplies the
    // same immutable texture for its first encode.
    ComPtr<ID3D11Texture2D> first_texture;
    ComPtr<ID3D11Query> fence;
    ComPtr<ID3D11VideoDevice> video_device;
    ComPtr<ID3D11VideoContext> video_context;
    ComPtr<ID3D11VideoProcessorEnumerator> enumerator;
    ComPtr<ID3D11VideoProcessor> processor;
    UINT input_width = 0, input_height = 0;
    uint64_t frames = 0, scaled = 0, copies = 0, converted = 0, initial_readbacks = 0;
    int64_t pts = 0;
    ~Encoder() {
        if (tracing() && context && avcodec_is_open(context))
            std::fprintf(stderr, "%s D3D11 frames=%llu scaled=%llu gpu_copies=%llu gpu_conversions=%llu cpu_readbacks=%llu\n",
                context->codec->name, static_cast<unsigned long long>(frames), static_cast<unsigned long long>(scaled),
                static_cast<unsigned long long>(copies),
                static_cast<unsigned long long>(converted),
                static_cast<unsigned long long>(owner->readbacks.load() - initial_readbacks));
        av_frame_free(&mapped);
        av_frame_free(&frame);
        av_packet_free(&packet);
        // Destroy the codec/frames/device contexts before releasing the shared
        // owner referenced by FFmpeg's recursive context-lock callbacks.
        avcodec_free_context(&context);
    }
    bool transfer(WindowsSurface &source, ID3D11Texture2D *destination) {
        D3D11_TEXTURE2D_DESC in{}, out{};
        source.texture->GetDesc(&in); destination->GetDesc(&out);
        if (in.ArraySize != 1 || out.ArraySize != 1)
            return false;
        if (in.Width == out.Width && in.Height == out.Height && in.Format == out.Format) {
            owner->context->CopyResource(destination, source.texture.Get());
            ++copies;
        } else {
            if (!processor || input_width != in.Width || input_height != in.Height) {
                processor.Reset(); enumerator.Reset();
                D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc{};
                desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
                desc.InputWidth = in.Width; desc.InputHeight = in.Height;
                desc.OutputWidth = out.Width; desc.OutputHeight = out.Height;
                desc.InputFrameRate = desc.OutputFrameRate = {60, 1};
                desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
                if (FAILED(video_device->CreateVideoProcessorEnumerator(&desc, &enumerator)) ||
                    FAILED(video_device->CreateVideoProcessor(enumerator.Get(), 0, &processor))) return false;
                input_width = in.Width; input_height = in.Height;
            }
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC input_desc{};
            input_desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
            D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC output_desc{};
            output_desc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
            ComPtr<ID3D11VideoProcessorInputView> input;
            ComPtr<ID3D11VideoProcessorOutputView> output;
            if (FAILED(video_device->CreateVideoProcessorInputView(source.texture.Get(), enumerator.Get(), &input_desc, &input)) ||
                FAILED(video_device->CreateVideoProcessorOutputView(destination, enumerator.Get(), &output_desc, &output))) return false;
            RECT src{0, 0, LONG(in.Width), LONG(in.Height)}, dst{0, 0, LONG(context->width), LONG(context->height)};
            video_context->VideoProcessorSetStreamFrameFormat(processor.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            video_context->VideoProcessorSetStreamSourceRect(processor.Get(), 0, TRUE, &src);
            video_context->VideoProcessorSetStreamDestRect(processor.Get(), 0, TRUE, &dst);
            video_context->VideoProcessorSetOutputTargetRect(processor.Get(), TRUE, &dst);
            video_context->VideoProcessorSetStreamAutoProcessingMode(processor.Get(), 0, FALSE);
            video_context->VideoProcessorSetOutputAlphaFillMode(processor.Get(), D3D11_VIDEO_PROCESSOR_ALPHA_FILL_MODE_OPAQUE, 0);
            D3D11_VIDEO_PROCESSOR_COLOR_SPACE color{}; // Full-range RGB in/out.
            video_context->VideoProcessorSetStreamColorSpace(processor.Get(), 0, &color);
            video_context->VideoProcessorSetOutputColorSpace(processor.Get(), &color);
            D3D11_VIDEO_PROCESSOR_STREAM stream{};
            stream.Enable = TRUE; stream.pInputSurface = input.Get();
            if (FAILED(video_context->VideoProcessorBlt(processor.Get(), output.Get(), 0, 1, &stream))) return false;
            if (in.Width != UINT(context->width) || in.Height != UINT(context->height)) ++scaled;
            if (in.Format != out.Format) ++converted;
        }
        // The encoder runs on its own hardware engine. Complete the GPU copy/scale
        // before handing over the texture; never map its pixels to the CPU.
        owner->context->End(fence.Get()); owner->context->Flush();
        const auto deadline = GetTickCount64() + 3000;
        HRESULT result;
        while ((result = owner->context->GetData(fence.Get(), nullptr, 0, 0)) == S_FALSE) {
            if (GetTickCount64() > deadline) return false;
            Sleep(1);
        }
        return SUCCEEDED(result);
    }
};
}

extern "C" int gw_video_decoder_supported(void *device, int codec) {
    if (!device || codec < 0 || codec > 2) return 0;
    ComPtr<ID3D11VideoDevice> video;
    if (FAILED(static_cast<ID3D11Device *>(device)->QueryInterface(IID_PPV_ARGS(&video)))) return 0;
    const GUID profiles[] = {D3D11_DECODER_PROFILE_H264_VLD_NOFGT,
        D3D11_DECODER_PROFILE_HEVC_VLD_MAIN, D3D11_DECODER_PROFILE_AV1_VLD_PROFILE0};
    for (UINT index = 0; index < video->GetVideoDecoderProfileCount(); ++index) {
        GUID profile{}; BOOL supported = FALSE;
        if (SUCCEEDED(video->GetVideoDecoderProfile(index, &profile)) && profile == profiles[codec] &&
            SUCCEEDED(video->CheckVideoDecoderFormat(&profile, DXGI_FORMAT_NV12, &supported)) && supported)
            return 1;
    }
    return 0;
}

extern "C" void *gw_video_new(void *, int, int, int, int, int);

extern "C" int gw_video_minimum(void *surface, int codec, uint32_t *width, uint32_t *height) {
    if (!surface || codec < 0 || codec > 2) return 0;
    auto &owner = *static_cast<WindowsSurface *>(surface)->owner;
    std::lock_guard lock(owner.mutex);
    auto &minimum = owner.minimum_dimensions[codec];
    if (!minimum[0]) {
        minimum[0] = minimum[1] = -1;
        HMODULE library = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (library) {
            using Create = NVENCSTATUS (NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *);
            auto create = reinterpret_cast<Create>(GetProcAddress(library, "NvEncodeAPICreateInstance"));
            NV_ENCODE_API_FUNCTION_LIST api = {NV_ENCODE_API_FUNCTION_LIST_VER};
            NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open = {NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER};
            open.device = owner.device.Get(); open.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
            open.apiVersion = NVENCAPI_VERSION;
            void *session = nullptr;
            if (create && create(&api) == NV_ENC_SUCCESS &&
                api.nvEncOpenEncodeSessionEx(&open, &session) == NV_ENC_SUCCESS) {
                const GUID formats[] = {NV_ENC_CODEC_H264_GUID, NV_ENC_CODEC_HEVC_GUID, NV_ENC_CODEC_AV1_GUID};
                NV_ENC_CAPS_PARAM caps = {NV_ENC_CAPS_PARAM_VER};
                int w = 0, h = 0;
                caps.capsToQuery = NV_ENC_CAPS_WIDTH_MIN;
                auto status = api.nvEncGetEncodeCaps(session, formats[codec], &caps, &w);
                caps.capsToQuery = NV_ENC_CAPS_HEIGHT_MIN;
                if (status == NV_ENC_SUCCESS &&
                    api.nvEncGetEncodeCaps(session, formats[codec], &caps, &h) == NV_ENC_SUCCESS &&
                    w > 0 && h > 0 && w <= 4096 && h <= 4096) {
                    minimum[0] = w; minimum[1] = h;
                }
                api.nvEncDestroyEncoder(session);
            }
            FreeLibrary(library);
        }
        // Other APIs expose no portable minimum. Use the smallest tested
        // overview size which emits a keyframe on this capture device.
        if (minimum[0] < 0) {
            for (int side : {32, 64, 128, 256}) {
                std::unique_ptr<Encoder> probe(static_cast<Encoder *>(gw_video_new(surface, codec, side, side, 0, 60)));
                if (probe) {
                    minimum[0] = minimum[1] = side;
                    break;
                }
            }
        }
    }
    if (minimum[0] < 0) return 0;
    *width = minimum[0]; *height = minimum[1];
    return 1;
}

static std::unique_ptr<Encoder> open_encoder(WindowsSurface &source, Backend backend, const char *name,
                                             int width, int height, int bitrate, int fps) {
    const AVCodec *implementation = avcodec_find_encoder_by_name(name);
    if (!implementation) return nullptr;
    auto encoder = std::make_unique<Encoder>();
    encoder->owner = source.owner;
    encoder->initial_readbacks = source.owner->readbacks.load();
    encoder->context = avcodec_alloc_context3(implementation);
    encoder->frame = av_frame_alloc(); encoder->packet = av_packet_alloc();
    if (!encoder->context || !encoder->frame || !encoder->packet) return nullptr;
    if (FAILED(source.owner->device.As(&encoder->video_device)) ||
        FAILED(source.owner->context.As(&encoder->video_context))) return nullptr;
    D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
    if (FAILED(source.owner->device->CreateQuery(&query, &encoder->fence))) return nullptr;
    D3D11_TEXTURE2D_DESC texture{}; source.texture->GetDesc(&texture);
    if (texture.Format != DXGI_FORMAT_B8G8R8A8_UNORM && texture.Format != DXGI_FORMAT_R8G8B8A8_UNORM) return nullptr;
    // QSV and MFTs submit work from driver threads outside our owner mutex.
    // Match FFmpeg's D3D11VA device initialization for externally owned devices.
    ComPtr<ID3D10Multithread> multithread;
    if (FAILED(source.owner->device.As(&multithread))) return nullptr;
    multithread->SetMultithreadProtected(TRUE);
    const auto format = backend == Backend::Nvenc ? AV_PIX_FMT_BGRA : AV_PIX_FMT_NV12;
    AVCodecContext *context = encoder->context;
    context->hw_device_ctx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
    if (!context->hw_device_ctx) return nullptr;
    auto hardware = reinterpret_cast<AVHWDeviceContext *>(context->hw_device_ctx->data);
    auto device = static_cast<AVD3D11VADeviceContext *>(hardware->hwctx);
    device->device = source.owner->device.Get(); device->device->AddRef();
    device->lock = lock_device; device->unlock = unlock_device; device->lock_ctx = source.owner.get();
    if (av_hwdevice_ctx_init(context->hw_device_ctx) < 0) return nullptr;
    if (backend == Backend::Qsv) {
        AVBufferRef *qsv = nullptr;
        if (av_hwdevice_ctx_create_derived(&qsv, AV_HWDEVICE_TYPE_QSV, context->hw_device_ctx, 0) < 0)
            return nullptr;
        av_buffer_unref(&context->hw_device_ctx);
        context->hw_device_ctx = qsv;
        encoder->mapped = av_frame_alloc();
        if (!encoder->mapped) return nullptr;
    }
    context->hw_frames_ctx = av_hwframe_ctx_alloc(context->hw_device_ctx);
    if (!context->hw_frames_ctx) return nullptr;
    auto frames = reinterpret_cast<AVHWFramesContext *>(context->hw_frames_ctx->data);
    frames->format = backend == Backend::Qsv ? AV_PIX_FMT_QSV : AV_PIX_FMT_D3D11; frames->sw_format = format;
    frames->width = width; frames->height = height;
    // Individual pooled textures stay alive through codec references. A
    // bounded in-flight pool avoids registering a new CEF texture each frame.
    frames->initial_pool_size = 0;
    if (backend != Backend::Qsv)
        static_cast<AVD3D11VAFramesContext *>(frames->hwctx)->BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (av_hwframe_ctx_init(context->hw_frames_ctx) < 0) return nullptr;
    context->width = width; context->height = height;
    context->pix_fmt = frames->format; context->sw_pix_fmt = format;
    context->time_base = {1, fps}; context->framerate = {fps, 1};
    context->colorspace = AVCOL_SPC_SMPTE170M;
    context->color_range = AVCOL_RANGE_MPEG;
    context->gop_size = fps * 10; context->max_b_frames = 0;
    context->bit_rate = bitrate ? bitrate : int64_t(width) * height * 8;
    context->flags |= AV_CODEC_FLAG_LOW_DELAY; context->thread_count = 1;
    AVDictionary *options = nullptr;
    if (backend == Backend::Nvenc) {
        for (auto option : {std::pair{"preset", "p1"}, {"tune", "ull"}, {"zerolatency", "1"},
                        {"delay", "0"}, {"rc-lookahead", "0"}, {"forced-idr", "1"},
                        {"rgb_mode", "yuv420"}, {"surfaces", "4"}})
            av_dict_set(&options, option.first, option.second, 0);
    } else if (backend == Backend::Qsv) {
        av_dict_set(&options, "async_depth", "1", 0);
        if (implementation->id != AV_CODEC_ID_AV1)
            av_dict_set(&options, "forced_idr", "1", 0);
    } else if (backend == Backend::Amf) {
        av_dict_set(&options, "usage", "ultralowlatency", 0);
        av_dict_set(&options, "async_depth", "1", 0);
    } else {
        av_dict_set(&options, "hw_encoding", "1", 0);
        av_dict_set(&options, "scenario", "display_remoting", 0);
    }
    const int result = avcodec_open2(context, implementation, &options);
    const bool unrecognized = av_dict_count(options) != 0;
    av_dict_free(&options);
    if (result < 0 || unrecognized) return nullptr;
    return encoder;
}
extern "C" void gw_video_free(void *p) { delete static_cast<Encoder *>(p); }
// NVENC reconfigures its live session for a new average bit rate; AMF and QSV
// keep the rate they opened with.
extern "C" void gw_video_set_bitrate(void *p, int bitrate) {
    auto *encoder = static_cast<Encoder *>(p);
    if (encoder && encoder->context && bitrate > 0) encoder->context->bit_rate = bitrate;
}
extern "C" int gw_video_encode(void *p, void *surface, int force_key, const uint8_t **bytes, int *key) {
    auto &encoder = *static_cast<Encoder *>(p);
    auto &source = *static_cast<WindowsSurface *>(surface);
    if (source.owner != encoder.owner) return -1; // Device changes require a new encoder.
    std::lock_guard lock(encoder.owner->mutex);
    if (encoder.first_texture) {
        const bool same = encoder.first_texture.Get() == source.texture.Get();
        encoder.first_texture.Reset();
        if (same) {
            *bytes = encoder.packet->data;
            *key = 1;
            return encoder.packet->size;
        }
        encoder.frames = encoder.scaled = encoder.copies = encoder.converted = 0;
    }
    AVFrame *frame = encoder.frame;
    av_frame_unref(frame);
    if (av_hwframe_get_buffer(encoder.context->hw_frames_ctx, frame, 0) < 0) return -1;
    AVFrame *texture = frame;
    if (encoder.mapped) {
        texture = encoder.mapped;
        av_frame_unref(texture);
        texture->format = AV_PIX_FMT_D3D11;
        if (av_hwframe_map(texture, frame, AV_HWFRAME_MAP_WRITE | AV_HWFRAME_MAP_DIRECT) < 0)
            return -1;
    }
    if (!encoder.transfer(source, reinterpret_cast<ID3D11Texture2D *>(texture->data[0]))) {
        av_frame_unref(frame); return -1;
    }
    frame->pts = encoder.pts++;
    frame->pict_type = (force_key || !encoder.frames) ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    int result = avcodec_send_frame(encoder.context, frame);
    av_frame_unref(frame);
    if (result < 0) return -1;
    ++encoder.frames;
    av_packet_unref(encoder.packet);
    result = avcodec_receive_packet(encoder.context, encoder.packet);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0) return -1;
    *bytes = encoder.packet->data; *key = !!(encoder.packet->flags & AV_PKT_FLAG_KEY);
    return encoder.packet->size;
}
extern "C" void gw_video_stats(void *p, uint64_t *frames, uint64_t *scaled, uint64_t *readbacks) {
    auto &encoder = *static_cast<Encoder *>(p);
    *frames = encoder.frames; *scaled = encoder.scaled;
    *readbacks = encoder.owner->readbacks.load() - encoder.initial_readbacks;
}

extern "C" void *gw_video_new(void *surface, int codec, int width, int height, int bitrate, int fps) {
    if (!surface || codec < 0 || codec > 2 || width < 16 || height < 16 || width > 4096 || height > 4096 ||
        ((width | height) & 1) || bitrate < 0 || bitrate > 200000000 || fps < 1 || fps > 120) return nullptr;
    auto &source = *static_cast<WindowsSurface *>(surface);
    std::lock_guard lock(source.owner->mutex);
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc{};
    if (FAILED(source.owner->device.As(&dxgi)) || FAILED(dxgi->GetAdapter(&adapter)) ||
        FAILED(adapter->GetDesc(&desc))) return nullptr;
    const Backend native = desc.VendorId == 0x8086 ? Backend::Qsv :
                           desc.VendorId == 0x1002 ? Backend::Amf : Backend::Nvenc;
    const char *prefix[] = {"h264", "hevc", "av1"};
    const char *suffix[] = {"nvenc", "qsv", "amf", "mf"};
    for (auto backend : {native, Backend::Mf}) {
        if (backend == Backend::Mf && codec == 2) continue;
        char name[32];
        std::snprintf(name, sizeof(name), "%s_%s", prefix[codec], suffix[static_cast<int>(backend)]);
        auto encoder = open_encoder(source, backend, name, width, height, bitrate, fps);
        if (!encoder) continue;
        // Some drivers open a session but cannot consume this adapter's texture,
        // or need future input to deliver a static page. Try the next backend.
        const uint8_t *bytes = nullptr;
        int key = 0;
        int size = gw_video_encode(encoder.get(), surface, 1, &bytes, &key);
        if (size <= 0 || !key) {
            if (tracing()) std::fprintf(stderr, "D3D11 encoder=%s probe_size=%d key=%d\n", name, size, key);
            continue;
        }
        encoder->first_texture = source.texture;
        if (tracing()) std::fprintf(stderr, "D3D11 encoder=%s size=%dx%d fps=%d gpu_input=true\n", name, width, height, fps);
        return encoder.release();
    }
    return nullptr;
}
