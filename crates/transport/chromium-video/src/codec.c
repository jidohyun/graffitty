#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
#ifdef _WIN32
#include <libavutil/hwcontext_d3d11va.h>
int gw_video_decoder_supported(void *device, int codec);
#endif
#ifdef __APPLE__
#include <VideoToolbox/VideoToolbox.h>
#endif
#ifdef GRAFFITTY_VA_LOADER
int graffitty_va_load(void);
#endif

// Encoder and decoder capability probes can run in either order. Load the
// system VA dispatch table before allowing FFmpeg to call any of its entries.
static int create_video_device(AVBufferRef **device, enum AVHWDeviceType type) {
#ifdef GRAFFITTY_VA_LOADER
    if (type == AV_HWDEVICE_TYPE_VAAPI && !graffitty_va_load())
        return AVERROR(ENOSYS);
#endif
    return av_hwdevice_ctx_create(device, type, NULL, NULL, 0);
}

typedef struct {
    AVCodecContext *context;
    AVFrame *frame, *transfer;
    AVPacket *packet;
    struct SwsContext *scale;
    enum AVPixelFormat hardware;
    int64_t pts;
    // The decoded frame, reused across frames and valid until the next decode.
    uint8_t *output;
    size_t capacity;
} Video;
#define GV_NV12 1

void gv_free(Video *video) {
    if (!video) return;
    avcodec_free_context(&video->context);
    av_frame_free(&video->frame);
    av_frame_free(&video->transfer);
    av_packet_free(&video->packet);
    sws_freeContext(video->scale);
    free(video->output);
    free(video);
}
static uint8_t *output_buffer(Video *v, size_t size) {
    if (size > v->capacity) {
        uint8_t *grown = realloc(v->output, size);
        if (!grown) return NULL;
        v->output = grown;
        v->capacity = size;
    }
    return v->output;
}
static Video *allocate(const AVCodec *codec) {
    if (!codec) return NULL;
    Video *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    v->context = avcodec_alloc_context3(codec);
    v->frame = av_frame_alloc();
    v->transfer = av_frame_alloc();
    v->packet = av_packet_alloc();
    v->hardware = AV_PIX_FMT_NONE;
    if (!v->context || !v->frame || !v->transfer || !v->packet) {
        gv_free(v); return NULL;
    }
    return v;
}
static Video *encoder_create(int codec, int width, int height, int surface, int bitrate, int fps) {
    if (width < 16 || height < 16 || width > 4096 || height > 4096 || (width|height)&1)
        return NULL;
#ifdef __APPLE__
    const char *suffixes[] = {"videotoolbox", NULL};
#elif defined(_WIN32)
    const char *suffixes[] = {"nvenc", "amf", "qsv", "mf", NULL};
#else
    const char *suffixes[] = {"nvenc", "vaapi", "qsv", NULL};
#endif
    const char *prefix = codec == 0 ? "h264" : codec == 1 ? "hevc" : "av1";
    for (int i = 0; suffixes[i]; ++i) {
        char name[64];
        snprintf(name, sizeof(name), "%s_%s", prefix, suffixes[i]);
        Video *v = allocate(avcodec_find_encoder_by_name(name));
        if (!v) continue;
        AVCodecContext *c = v->context;
        c->width = width; c->height = height;
        c->time_base = (AVRational){1, fps}; c->framerate = (AVRational){fps, 1};
        c->pix_fmt = surface ? AV_PIX_FMT_VIDEOTOOLBOX : AV_PIX_FMT_NV12;
        c->sw_pix_fmt = AV_PIX_FMT_NV12;
        c->color_range = AVCOL_RANGE_MPEG;
        // Client NV12 shaders and the CPU input converter use BT.601 limited
        // range. VideoToolbox's RGB-surface conversion otherwise chooses its
        // own matrix, shifting colours when those planes reach the client.
        c->colorspace = AVCOL_SPC_SMPTE170M;
        // Reliable transport and explicit recovery keyframes (joins, resets,
        // new generations) make periodic IDRs mostly overhead; on slow links
        // each one stalls the stream. A long interval still self-heals any
        // undetected decoder corruption.
        c->gop_size = fps * 10; c->max_b_frames = 0;
        c->bit_rate = bitrate > 0 ? bitrate : (int64_t)width * height * 8;
        c->flags |= AV_CODEC_FLAG_LOW_DELAY;
        c->thread_count = 1;
        AVDictionary *options = NULL;
        if (!strcmp(suffixes[i], "videotoolbox")) {
            av_dict_set(&options, "allow_sw", "0", 0);
            av_dict_set(&options, "realtime", "1", 0);
            // Bound reference retention for interactive streams.
            // Unconstrained VT HEVC at 1000x700 exhausts Qualcomm Codec2
            // surface attachment accounting even with no B frames.
            //
            // Bound decoder reference storage without assuming this property
            // maps directly to the bitstream DPB.
#ifdef __APPLE__
            if (__builtin_available(macOS 13.0, *))
                av_dict_set(&options, "max_ref_frames", "2", 0);
#endif
        } else if (!strcmp(suffixes[i], "nvenc")) {
            av_dict_set(&options, "preset", "p1", 0);
            av_dict_set(&options, "tune", "ull", 0);
            av_dict_set(&options, "zerolatency", "1", 0);
            // No future input frame is guaranteed for a static browser page.
            av_dict_set(&options, "delay", "0", 0);
            av_dict_set(&options, "rc-lookahead", "0", 0);
            av_dict_set(&options, "surfaces", "4", 0);
            av_dict_set(&options, "forced-idr", "1", 0);
        } else if (!strcmp(suffixes[i], "amf")) {
            av_dict_set(&options, "usage", "ultralowlatency", 0);
#ifdef _WIN32
            av_dict_set(&options, "async_depth", "1", 0);
        } else if (!strcmp(suffixes[i], "mf")) {
            av_dict_set(&options, "hw_encoding", "1", 0);
            av_dict_set(&options, "scenario", "display_remoting", 0);
#endif
        } else {
            enum AVHWDeviceType type = !strcmp(suffixes[i], "vaapi") ? AV_HWDEVICE_TYPE_VAAPI : AV_HWDEVICE_TYPE_QSV;
            AVBufferRef *device = NULL;
            if (create_video_device(&device, type) < 0) {
                av_dict_free(&options); gv_free(v); continue;
            }
#ifdef _WIN32
            if (type == AV_HWDEVICE_TYPE_QSV) {
                av_dict_set(&options, "async_depth", "1", 0);
                if (codec != 2) av_dict_set(&options, "forced_idr", "1", 0);
            }
#endif
            if (type == AV_HWDEVICE_TYPE_VAAPI)
                av_dict_set(&options, "async_depth", "1", 0);
            c->pix_fmt = type == AV_HWDEVICE_TYPE_VAAPI ? AV_PIX_FMT_VAAPI : AV_PIX_FMT_QSV;
            c->hw_frames_ctx = av_hwframe_ctx_alloc(device);
            av_buffer_unref(&device);
            if (!c->hw_frames_ctx) { av_dict_free(&options); gv_free(v); continue; }
            AVHWFramesContext *frames = (AVHWFramesContext *)c->hw_frames_ctx->data;
            frames->format = c->pix_fmt; frames->sw_format = AV_PIX_FMT_NV12;
            frames->width = width; frames->height = height; frames->initial_pool_size = 4;
#ifdef _WIN32
            // QSV processor targets use individual renderable D3D11 textures.
            frames->initial_pool_size = 0;
#endif
            if (av_hwframe_ctx_init(c->hw_frames_ctx) < 0) {
                av_dict_free(&options); gv_free(v); continue;
            }
        }
        int result = avcodec_open2(c, c->codec, &options);
        av_dict_free(&options);
        if (result < 0) { gv_free(v); continue; }
        v->frame->format = AV_PIX_FMT_NV12; v->frame->width = width; v->frame->height = height;
        if (!surface && av_frame_get_buffer(v->frame, 32) < 0) { gv_free(v); continue; }
        return v;
    }
    return NULL;
}
/* A new average bit rate for the next frames. VideoToolbox (patched, see
 * videotoolbox-live-bitrate.patch) and NVENC apply it to the live session
 * without a keyframe; other encoders keep the rate they opened with. */
void gv_set_bitrate(Video *v, int bitrate) {
    if (v && v->context && bitrate > 0) v->context->bit_rate = bitrate;
}
Video *gv_encoder(int codec, int width, int height, int bitrate, int fps) {
    return encoder_create(codec, width, height, 0, bitrate, fps);
}
#ifdef __APPLE__
Video *gv_surface_encoder(int codec, int width, int height, int bitrate, int fps) {
    return encoder_create(codec, width, height, 1, bitrate, fps);
}
// The immutable IOSurface is owned by the caller. VideoToolbox retains the
// CVPixelBuffer for asynchronous encoding; no readback, PNG, or swscale here.
static void release_pixel(void *opaque, uint8_t *data) { (void)data; CVPixelBufferRelease(opaque); }
extern void *gv_surface_video_pixel(void *surface);
int gv_encode_surface(Video *v, void *surface, int force_key, const uint8_t **bytes, int *key) {
    CVPixelBufferRef pixel = gv_surface_video_pixel(surface);
    if (!pixel) return -1;
    AVFrame *frame = v->frame;
    av_frame_unref(frame);
    frame->format = AV_PIX_FMT_VIDEOTOOLBOX;
    frame->width = v->context->width; frame->height = v->context->height;
    frame->data[3] = (uint8_t *)pixel;
    frame->buf[0] = av_buffer_create((uint8_t *)pixel, 1, release_pixel, pixel, 0);
    if (!frame->buf[0]) { CVPixelBufferRelease(pixel); return -1; }
    frame->pts = v->pts++;
    frame->pict_type = force_key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    int result = avcodec_send_frame(v->context, frame);
    av_frame_unref(frame);
    if (result < 0) return -1;
    av_packet_unref(v->packet);
    result = avcodec_receive_packet(v->context, v->packet);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0) return -1;
    *bytes = v->packet->data; *key = !!(v->packet->flags & AV_PKT_FLAG_KEY);
    return v->packet->size;
}
#endif
// One complete access unit per packet; the caller retains all reference packets.
static int encode_pixels(Video *v, const uint8_t *pixels, int width, int height,
                         enum AVPixelFormat format, int force_key, const uint8_t **bytes, int *key) {
    AVCodecContext *c = v->context;
    if (av_frame_make_writable(v->frame) < 0) return -1;
    v->scale = sws_getCachedContext(v->scale, width, height, format,
        c->width, c->height, AV_PIX_FMT_NV12, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!v->scale) return -1;
    const uint8_t *src[4] = {pixels}; int stride[4] = {width * 4};
    if (sws_scale(v->scale, src, stride, 0, height, v->frame->data, v->frame->linesize) <= 0) return -1;
    v->frame->pts = v->pts++;
    v->frame->pict_type = force_key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
    AVFrame *frame = v->frame;
    if (c->hw_frames_ctx) {
        av_frame_unref(v->transfer);
        if (av_hwframe_get_buffer(c->hw_frames_ctx, v->transfer, 0) < 0 ||
            av_hwframe_transfer_data(v->transfer, frame, 0) < 0) return -1;
        v->transfer->pts = frame->pts; v->transfer->pict_type = frame->pict_type;
        frame = v->transfer;
    }
    if (avcodec_send_frame(c, frame) < 0) return -1;
    av_packet_unref(v->packet);
    int result = avcodec_receive_packet(c, v->packet);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0) return -1;
    *bytes = v->packet->data; *key = !!(v->packet->flags & AV_PKT_FLAG_KEY);
    return v->packet->size;
}
int gv_encode(Video *v, const uint8_t *rgba, int force_key, const uint8_t **bytes, int *key) {
    return encode_pixels(v, rgba, v->context->width, v->context->height, AV_PIX_FMT_RGBA,
                         force_key, bytes, key);
}
#ifdef __linux__
int gl_encode_pixels(Video *v, const uint8_t *pixels, int width, int height, int bgra,
                     int force_key, const uint8_t **bytes, int *key) {
    return encode_pixels(v, pixels, width, height, bgra ? AV_PIX_FMT_BGRA : AV_PIX_FMT_RGBA,
                         force_key, bytes, key);
}
#endif
static enum AVPixelFormat hardware_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    Video *v = context->opaque;
    for (; *formats != AV_PIX_FMT_NONE; ++formats)
        if (*formats == v->hardware) return *formats;
    return AV_PIX_FMT_NONE; // Never silently fall back to a software decoder.
}
Video *gv_decoder(int codec) {
#ifdef __APPLE__
    CMVideoCodecType type = codec == 0 ? kCMVideoCodecType_H264 : codec == 1 ? kCMVideoCodecType_HEVC : 'av01';
    if (!VTIsHardwareDecodeSupported(type)) return NULL;
#endif
    const char *name = codec == 0 ? "h264" : codec == 1 ? "hevc" : "av1";
    const AVCodec *implementation = avcodec_find_decoder_by_name(name);
    if (!implementation) return NULL;
    for (int i = 0;; ++i) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(implementation, i);
        if (!config) break;
        if (!(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) continue;
        Video *v = allocate(implementation);
        if (!v) return NULL;
        if (create_video_device(&v->context->hw_device_ctx, config->device_type) < 0) {
            gv_free(v); continue;
        }
#ifdef _WIN32
        if (config->device_type == AV_HWDEVICE_TYPE_D3D11VA) {
            AVHWDeviceContext *hardware = (AVHWDeviceContext *)v->context->hw_device_ctx->data;
            AVD3D11VADeviceContext *device = hardware->hwctx;
            // Opening an FFmpeg decoder alone does not check this adapter's
            // profiles. Older NVIDIA GPUs must not advertise AV1 decoding.
            if (!gw_video_decoder_supported(device->device, codec)) {
                gv_free(v); continue;
            }
        }
#endif
        v->hardware = config->pix_fmt;
        v->context->opaque = v;
        v->context->get_format = hardware_format;
        v->context->flags |= AV_CODEC_FLAG_LOW_DELAY;
        v->context->thread_count = 1;
        if (avcodec_open2(v->context, implementation, NULL) == 0) return v;
        gv_free(v);
    }
    return NULL;
}
int gv_decode(Video *v, const uint8_t *bytes, int length, int format, const uint8_t **out, int *width, int *height) {
    if (length) {
    av_packet_unref(v->packet);
    if (av_new_packet(v->packet, length) < 0) return -1;
    memcpy(v->packet->data, bytes, length);
    if (avcodec_send_packet(v->context, v->packet) < 0) return -1;
    }
    av_frame_unref(v->frame);
    int result = avcodec_receive_frame(v->context, v->frame);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0 || v->frame->format != v->hardware) return -1;
    av_frame_unref(v->transfer);
    if (av_hwframe_transfer_data(v->transfer, v->frame, 0) < 0) return -1;
    AVFrame *frame = v->transfer;
    if (frame->width < 16 || frame->height < 16 || frame->width > 4096 || frame->height > 4096) return -1;
    *width = frame->width; *height = frame->height;
    size_t luma = (size_t)*width * *height;
    int chroma_width = (*width + 1) / 2, chroma_height = (*height + 1) / 2;
    size_t size = format == GV_NV12 ? luma + (size_t)chroma_width * chroma_height * 2 : luma * 4;
    uint8_t *output = output_buffer(v, size);
    if (!output) return -1;
    if (format == GV_NV12 && frame->format == AV_PIX_FMT_NV12) {
        // Hardware decoders transfer NV12: copy its planes without conversion.
        for (int y = 0; y < *height; ++y)
            memcpy(output + (size_t)y * *width, frame->data[0] + (size_t)y * frame->linesize[0], *width);
        for (int y = 0; y < chroma_height; ++y)
            memcpy(output + luma + (size_t)y * chroma_width * 2,
                   frame->data[1] + (size_t)y * frame->linesize[1], (size_t)chroma_width * 2);
    } else {
        enum AVPixelFormat target = format == GV_NV12 ? AV_PIX_FMT_NV12 : AV_PIX_FMT_RGBA;
        v->scale = sws_getCachedContext(v->scale, *width, *height, frame->format,
            *width, *height, target, SWS_FAST_BILINEAR, NULL, NULL, NULL);
        if (!v->scale) return -1;
        uint8_t *dst[] = {output, output + luma};
        int stride[] = {format == GV_NV12 ? *width : *width * 4, chroma_width * 2};
        if (sws_scale(v->scale, (const uint8_t *const *)frame->data, frame->linesize,
            0, *height, dst, stride) <= 0) return -1;
    }
    *out = output;
    return (int)size;
}

Video *gv_decoder_named(int codec, const char *name, int width, int height) { (void)name; (void)width; (void)height; return gv_decoder(codec); }
