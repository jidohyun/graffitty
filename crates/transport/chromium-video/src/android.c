// Android uses the NDK MediaCodec API; Godot's Java bridge selects a codec
// explicitly reported as hardware accelerated. No JNI VM or FFmpeg runtime.
#include <android/log.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "yuv420.h"
#define GV_NV12 1
// The Godot extension presents up to two pictures in order (its
// PRESENTATION_QUEUE); older decoded pictures are never shown.
#define GV_PRESENTED 2
// Flexible YUV byte buffers are described by a MediaImage2 in the output
// format's "image-data" (frameworks/native media/hardware/VideoAPI.h).
typedef struct {
    uint32_t type, planes, width, height, bit_depth, allocated_depth;
    struct { uint32_t offset; int32_t column, row; uint32_t horizontal, vertical; } plane[4];
} MediaImage2;
#define MEDIA_IMAGE_TYPE_YUV 1
typedef struct { int32_t index, offset, size; } Output;
// Where each 8-bit 4:2:0 plane starts in an output buffer, and its steps.
typedef struct { int width, height; uint32_t offset[3]; int32_t row[3], column[3]; } Layout;
// Codec2's synchronous dequeue calls each wait for a reply from the codec's
// looper, so polling them cost a tablet's decoder thread most of a frame.
//
// The codec instead announces input and output buffers on its callback
// thread; decoding only uses announced buffers.
typedef struct {
    AMediaCodec *codec;
    int width, height;
    int64_t pts;
    pthread_mutex_t lock;
    int locked;
    int32_t inputs[64];
    Output outputs[64];
    int input_count, output_count;
    media_status_t failed;
    // The decoded frame, reused across frames and valid until the next decode.
    uint8_t *frame;
    size_t capacity;
} Video;
void gv_free(Video *v) {
    if (!v) return;
    // Deleting the codec stops its callback thread before this memory is freed.
    if (v->codec) { AMediaCodec_stop(v->codec); AMediaCodec_delete(v->codec); }
    if (v->locked) pthread_mutex_destroy(&v->lock);
    free(v->frame);
    free(v);
}
// Reallocating several megabytes per frame faulted fresh pages in and
// unmapped old ones on every frame, slowing every thread of the process.
static uint8_t *frame_buffer(Video *v, size_t size) {
    if (size > v->capacity) {
        uint8_t *grown = realloc(v->frame, size);
        if (!grown) return NULL;
        v->frame = grown;
        v->capacity = size;
    }
    return v->frame;
}
// The client installs on Android 8, but these calls exist from Android 9.
// Resolve them at runtime so the library still loads there; Android 8
// devices have no hardware decoder and receive PNG frames.
typedef media_status_t (*SetAsyncNotify)(AMediaCodec *, AMediaCodecOnAsyncNotifyCallback, void *);
typedef bool (*IsTransient)(int32_t);
typedef AMediaFormat *(*GetBufferFormat)(AMediaCodec *, size_t);
static SetAsyncNotify set_async_notify;
static IsTransient is_transient;
static GetBufferFormat get_buffer_format;
static pthread_once_t async_api = PTHREAD_ONCE_INIT;
static void load_async_api(void) {
    void *ndk = dlopen("libmediandk.so", RTLD_NOW);
    if (!ndk) return;
    set_async_notify = (SetAsyncNotify)dlsym(ndk, "AMediaCodec_setAsyncNotifyCallback");
    is_transient = (IsTransient)dlsym(ndk, "AMediaCodecActionCode_isTransient");
    get_buffer_format = (GetBufferFormat)dlsym(ndk, "AMediaCodec_getBufferFormat");
}
static void on_input(AMediaCodec *codec, void *data, int32_t index) {
    (void)codec;
    Video *v = data;
    pthread_mutex_lock(&v->lock);
    if (v->input_count < (int)(sizeof v->inputs / sizeof *v->inputs)) v->inputs[v->input_count++] = index;
    pthread_mutex_unlock(&v->lock);
}
static void on_output(AMediaCodec *codec, void *data, int32_t index, AMediaCodecBufferInfo *info) {
    Video *v = data;
    pthread_mutex_lock(&v->lock);
    int full = v->output_count == (int)(sizeof v->outputs / sizeof *v->outputs);
    if (!full) v->outputs[v->output_count++] = (Output){index, info->offset, info->size};
    pthread_mutex_unlock(&v->lock);
    // A decoder this far behind presentation keeps only newer frames.
    if (full) AMediaCodec_releaseOutputBuffer(codec, index, false);
}
// Each output buffer's own format describes its planes; see copy_output.
static void on_format(AMediaCodec *codec, void *data, AMediaFormat *format) { (void)codec; (void)data; (void)format; }
static void on_error(AMediaCodec *codec, void *data, media_status_t error, int32_t action, const char *detail) {
    (void)codec;
    Video *v = data;
    __android_log_print(ANDROID_LOG_ERROR, "GraffittyVideo", "codec error %d (action %d): %s", error, action, detail ? detail : "");
    if (is_transient && is_transient(action)) return;
    pthread_mutex_lock(&v->lock);
    if (!v->failed) v->failed = error ? error : AMEDIA_ERROR_UNKNOWN;
    pthread_mutex_unlock(&v->lock);
}
Video *gv_encoder(int codec, int width, int height, int bitrate, int fps) { (void)codec; (void)width; (void)height; (void)bitrate; (void)fps; return NULL; }
int gv_encode(Video *v, const uint8_t *rgba, int force_key, const uint8_t **bytes, int *key) { (void)v; (void)rgba; (void)force_key; (void)bytes; (void)key; return -1; }
Video *gv_decoder(int codec) { (void)codec; return NULL; }
Video *gv_decoder_named(int codec, const char *name, int width, int height) {
    if (!name || !*name || width < 16 || height < 16 || width > 4096 || height > 4096) return NULL;
    pthread_once(&async_api, load_async_api);
    if (!set_async_notify || !get_buffer_format) return NULL;
    Video *v = calloc(1, sizeof(*v));
    if (!v) return NULL;
    if (pthread_mutex_init(&v->lock, NULL) != 0) { free(v); return NULL; }
    v->locked = 1;
    v->codec = AMediaCodec_createCodecByName(name);
    v->width = width; v->height = height;
    if (!v->codec) { gv_free(v); return NULL; }
    AMediaCodecOnAsyncNotifyCallback callbacks = {on_input, on_output, on_format, on_error};
    if (set_async_notify(v->codec, callbacks, v) != AMEDIA_OK) { gv_free(v); return NULL; }
    AMediaFormat *format = AMediaFormat_new();
    AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, codec == 0 ? "video/avc" : codec == 1 ? "video/hevc" : "video/av01");
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
    // Codec2 otherwise configures 30 fps, and Qualcomm clocks its decoder for
    // that rate: a 60 fps stream waited for input buffers at about 25 fps.
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_FRAME_RATE, 60);
    AMediaFormat_setInt32(format, "operating-rate", 120);
    AMediaFormat_setInt32(format, "priority", 0);
    // Flexible YUV makes the codec describe its output planes (image-data);
    // vendor layouts differ, so none is assumed.
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_COLOR_FORMAT, 0x7f420888); // COLOR_FormatYUV420Flexible
    AMediaFormat_setInt32(format, "low-latency", 1);
    // Use the Qualcomm Codec2 keys to reduce display reordering. Qualcomm
    // ignores the standard key and can hold 10–16 frames even when the
    // stream has no B-frames. Four input buffers then cap decoding near 25 fps.
    //
    // Other vendors ignore these keys.
    AMediaFormat_setInt32(format, "vendor.qti-ext-dec-low-latency.enable", 1);
    AMediaFormat_setInt32(format, "vendor.qti-ext-dec-picture-order.enable", 1);
    // Decode into the codec's byte buffers, not an ImageReader surface.
    //
    // On a Qualcomm tablet any surface output, even an opaque GPU format,
    // queued behind the app's own GPU work: decoded frames arrived 100-150 ms
    // late at about 30 fps while the app rendered.
    //
    // Byte buffers kept 60 fps.
    int status = AMediaCodec_configure(v->codec, format, NULL, NULL, 0);
    AMediaFormat_delete(format);
    if (status != AMEDIA_OK || AMediaCodec_start(v->codec) != AMEDIA_OK) { gv_free(v); return NULL; }
    return v;
}
static int codec_failure(const char *stage, int status) {
    __android_log_print(ANDROID_LOG_ERROR, "GraffittyVideo", "%s failed: %d", stage, status);
    return -1;
}
// Reads where each plane of an output buffer lives. Only 8-bit 4:2:0 layouts
// with forward steps are accepted.
static int read_layout(AMediaFormat *format, Layout *layout) {
    void *data = NULL;
    size_t size = 0;
    MediaImage2 image = {0};
    if (!AMediaFormat_getBuffer(format, "image-data", &data, &size) || size < sizeof image) return 0;
    memcpy(&image, data, sizeof image);
    if (image.type != MEDIA_IMAGE_TYPE_YUV || image.planes != 3 || image.bit_depth != 8 ||
        image.allocated_depth != 8 || !image.width || !image.height || image.width > 4096 || image.height > 4096)
        return 0;
    layout->width = (int)image.width;
    layout->height = (int)image.height;
    for (int p = 0; p < 3; ++p) {
        uint32_t subsampling = p ? 2 : 1;
        if (image.plane[p].horizontal != subsampling || image.plane[p].vertical != subsampling ||
            image.plane[p].column <= 0 || image.plane[p].row <= 0) return 0;
        layout->offset[p] = image.plane[p].offset;
        layout->row[p] = image.plane[p].row;
        layout->column[p] = image.plane[p].column;
    }
    return 1;
}
// Converts one decoded output buffer into the reused frame. The buffer's own
// format is used: outputs announced before a format change keep the layout
// they were decoded with.
static int copy_output(Video *v, Output output, int format, const uint8_t **out, int *width, int *height) {
    AMediaFormat *described = get_buffer_format(v->codec, (size_t)output.index);
    Layout layout;
    int described_layout = described && read_layout(described, &layout);
    if (described) AMediaFormat_delete(described);
    if (!described_layout) return codec_failure("output layout", output.index);
    size_t capacity = 0;
    uint8_t *buffer = AMediaCodec_getOutputBuffer(v->codec, (size_t)output.index, &capacity);
    if (!buffer || output.offset < 0 || output.size <= 0 || (size_t)output.offset + (size_t)output.size > capacity)
        return codec_failure("output buffer", (int)capacity);
    // The visible picture is the stream's size; codecs may pad beyond it.
    int w = layout.width < v->width ? layout.width : v->width;
    int h = layout.height < v->height ? layout.height : v->height;
    GvYuvPlane planes[3];
    for (int p = 0; p < 3; ++p) {
        int shift = p ? 1 : 0;
        size_t last = layout.offset[p] + (size_t)((h - 1) >> shift) * (size_t)layout.row[p] +
                      (size_t)((w - 1) >> shift) * (size_t)layout.column[p];
        if (last >= (size_t)output.size) return codec_failure("output planes", p);
        planes[p] = (GvYuvPlane){buffer + output.offset + layout.offset[p], layout.row[p], layout.column[p]};
    }
    size_t luma = (size_t)w * h;
    size_t size = format == GV_NV12 ? luma + (size_t)((w + 1) / 2) * ((h + 1) / 2) * 2 : luma * 4;
    uint8_t *frame = frame_buffer(v, size);
    if (!frame) return codec_failure("frame allocation", (int)size);
    if (format == GV_NV12) gv_yuv420_nv12(planes, 0, 0, w, h, frame);
    else gv_yuv420_rgba(planes, 0, 0, w, h, frame);
    *out = frame;
    *width = w;
    *height = h;
    return (int)size;
}

int gv_decode(Video *v, const uint8_t *bytes, int length, int format, const uint8_t **out, int *width, int *height) {
    pthread_mutex_lock(&v->lock);
    media_status_t failed = v->failed;
    int32_t index = -1;
    if (!failed && length) {
        // No input was consumed. The Rust worker retains this exact access unit
        // and retries without discarding codec reference state.
        if (v->input_count == 0) { pthread_mutex_unlock(&v->lock); return -2; }
        index = v->inputs[0];
        memmove(v->inputs, v->inputs + 1, (size_t)--v->input_count * sizeof *v->inputs);
    }
    Output stale[sizeof v->outputs / sizeof *v->outputs];
    int stale_count = v->output_count > GV_PRESENTED ? v->output_count - GV_PRESENTED : 0;
    memcpy(stale, v->outputs, (size_t)stale_count * sizeof *stale);
    int has_output = v->output_count > stale_count;
    Output output = has_output ? v->outputs[stale_count] : (Output){-1, 0, 0};
    int taken = stale_count + has_output;
    memmove(v->outputs, v->outputs + taken, (size_t)(v->output_count - taken) * sizeof *v->outputs);
    v->output_count -= taken;
    pthread_mutex_unlock(&v->lock);
    if (failed) return codec_failure("codec", failed);
    if (length) {
        size_t capacity = 0;
        uint8_t *input = AMediaCodec_getInputBuffer(v->codec, (size_t)index, &capacity);
        if (!input || capacity < (size_t)length) return codec_failure("input buffer capacity", (int)capacity);
        memcpy(input, bytes, length);
        media_status_t queued = AMediaCodec_queueInputBuffer(v->codec, (size_t)index, 0, length, (uint64_t)(v->pts++ * 16667), 0);
        if (queued != AMEDIA_OK) return codec_failure("queue input", queued);
    }
    // Codec2 owns announced buffers until they are released. Pictures too old
    // to be shown go back uncopied; every compressed reference was still
    // decoded.
    //
    // One picture is copied per call, oldest first, so pictures decoded
    // together are all shown; the worker calls again after one.
    for (int i = 0; i < stale_count; ++i) {
        media_status_t released = AMediaCodec_releaseOutputBuffer(v->codec, (size_t)stale[i].index, false);
        if (released != AMEDIA_OK) return codec_failure("release output", released);
    }
    if (!has_output) return 0;
    int result = output.size > 0 ? copy_output(v, output, format, out, width, height) : 0;
    media_status_t released = AMediaCodec_releaseOutputBuffer(v->codec, (size_t)output.index, false);
    if (released != AMEDIA_OK) return codec_failure("release output", released);
    return result;
}
