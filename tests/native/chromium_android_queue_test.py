#!/usr/bin/env python3
"""Compile the production Android decoder against a deterministic fake NDK codec."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'crates/transport/chromium-video/src'
headers = {
    'android/log.h': r'''#pragma once
#define ANDROID_LOG_ERROR 6
int __android_log_print(int priority, const char *tag, const char *format, ...);
''',
    'media/NdkMediaFormat.h': r'''#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef int media_status_t;
#define AMEDIA_OK 0
#define AMEDIA_ERROR_UNKNOWN -10000
typedef struct AMediaFormat AMediaFormat;
extern const char *AMEDIAFORMAT_KEY_MIME, *AMEDIAFORMAT_KEY_WIDTH, *AMEDIAFORMAT_KEY_HEIGHT,
    *AMEDIAFORMAT_KEY_FRAME_RATE, *AMEDIAFORMAT_KEY_COLOR_FORMAT;
AMediaFormat *AMediaFormat_new(void);
media_status_t AMediaFormat_delete(AMediaFormat *format);
void AMediaFormat_setString(AMediaFormat *format, const char *name, const char *value);
void AMediaFormat_setInt32(AMediaFormat *format, const char *name, int32_t value);
bool AMediaFormat_getBuffer(AMediaFormat *format, const char *name, void **data, size_t *size);
''',
    'media/NdkMediaCodec.h': r'''#pragma once
#include "media/NdkMediaFormat.h"
typedef struct AMediaCodec AMediaCodec;
typedef struct { int32_t offset, size; int64_t presentationTimeUs; uint32_t flags; } AMediaCodecBufferInfo;
typedef struct {
    void (*onAsyncInputAvailable)(AMediaCodec *, void *, int32_t);
    void (*onAsyncOutputAvailable)(AMediaCodec *, void *, int32_t, AMediaCodecBufferInfo *);
    void (*onAsyncFormatChanged)(AMediaCodec *, void *, AMediaFormat *);
    void (*onAsyncError)(AMediaCodec *, void *, media_status_t, int32_t, const char *);
} AMediaCodecOnAsyncNotifyCallback;
AMediaCodec *AMediaCodec_createCodecByName(const char *name);
media_status_t AMediaCodec_configure(AMediaCodec *codec, const AMediaFormat *format, void *surface, void *crypto, uint32_t flags);
media_status_t AMediaCodec_start(AMediaCodec *codec);
media_status_t AMediaCodec_stop(AMediaCodec *codec);
media_status_t AMediaCodec_delete(AMediaCodec *codec);
uint8_t *AMediaCodec_getInputBuffer(AMediaCodec *codec, size_t index, size_t *capacity);
uint8_t *AMediaCodec_getOutputBuffer(AMediaCodec *codec, size_t index, size_t *capacity);
media_status_t AMediaCodec_queueInputBuffer(AMediaCodec *codec, size_t index, long offset, size_t size, uint64_t time, uint32_t flags);
media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec *codec, size_t index, bool render);
''',
}
test = r'''
#include "android.c"
#include <assert.h>

struct AMediaCodec { int unused; };
struct AMediaFormat { int index; };
const char *AMEDIAFORMAT_KEY_MIME = "mime", *AMEDIAFORMAT_KEY_WIDTH = "width", *AMEDIAFORMAT_KEY_HEIGHT = "height",
    *AMEDIAFORMAT_KEY_FRAME_RATE = "frame-rate", *AMEDIAFORMAT_KEY_COLOR_FORMAT = "color-format";
static AMediaCodec codec;
static AMediaFormat created, formats[80];
static uint8_t input[64], queued_bytes[64], buffers[80][64];
static int logs, queued, format_reads, released[128], releases, rendered;
// Each output buffer's described layout; type 0 means no image-data.
static MediaImage2 images[80];

int __android_log_print(int priority, const char *tag, const char *format, ...) { (void)priority; (void)tag; (void)format; ++logs; return 0; }
AMediaCodec *AMediaCodec_createCodecByName(const char *name) { (void)name; return &codec; }
media_status_t AMediaCodec_configure(AMediaCodec *c, const AMediaFormat *f, void *s, void *k, uint32_t flags) { (void)c; (void)f; (void)s; (void)k; (void)flags; return AMEDIA_OK; }
media_status_t AMediaCodec_start(AMediaCodec *c) { (void)c; return AMEDIA_OK; }
media_status_t AMediaCodec_stop(AMediaCodec *c) { (void)c; return AMEDIA_OK; }
media_status_t AMediaCodec_delete(AMediaCodec *c) { (void)c; return AMEDIA_OK; }
uint8_t *AMediaCodec_getInputBuffer(AMediaCodec *c, size_t index, size_t *capacity) { (void)c; assert(index == 5); *capacity = sizeof input; return input; }
media_status_t AMediaCodec_queueInputBuffer(AMediaCodec *c, size_t index, long offset, size_t size, uint64_t time, uint32_t flags) {
    (void)c; (void)time; assert(index == 5 && offset == 0 && flags == 0); memcpy(queued_bytes, input, size); ++queued; return AMEDIA_OK;
}
uint8_t *AMediaCodec_getOutputBuffer(AMediaCodec *c, size_t index, size_t *capacity) { (void)c; *capacity = sizeof buffers[index]; return buffers[index]; }
media_status_t AMediaCodec_releaseOutputBuffer(AMediaCodec *c, size_t index, bool render) { (void)c; released[releases++] = (int)index; rendered |= render; return AMEDIA_OK; }
static AMediaFormat *buffer_format(AMediaCodec *c, size_t index) { (void)c; ++format_reads; formats[index].index = (int)index; return &formats[index]; }
AMediaFormat *AMediaFormat_new(void) { created.index = -1; return &created; }
media_status_t AMediaFormat_delete(AMediaFormat *f) { (void)f; return AMEDIA_OK; }
void AMediaFormat_setString(AMediaFormat *f, const char *n, const char *v) { (void)f; (void)n; (void)v; }
void AMediaFormat_setInt32(AMediaFormat *f, const char *n, int32_t v) { (void)f; (void)n; (void)v; }
bool AMediaFormat_getBuffer(AMediaFormat *f, const char *name, void **data, size_t *size) {
    if (f->index < 0 || !images[f->index].type || strcmp(name, "image-data")) return false;
    *data = &images[f->index]; *size = sizeof images[f->index]; return true;
}

static Video *video(int width, int height) {
    Video *v = calloc(1, sizeof *v);
    assert(v && pthread_mutex_init(&v->lock, NULL) == 0);
    v->locked = 1; v->codec = &codec; v->width = width; v->height = height;
    return v;
}
static void output(Video *v, int index, int size) { AMediaCodecBufferInfo info = {0, size, 0, 0}; on_output(&codec, v, index, &info); }
// 4x2 I420 with padded rows: Y rows of 8 bytes, then U and V rows of 4.
static void planar(int index) {
    images[index] = (MediaImage2){MEDIA_IMAGE_TYPE_YUV, 3, 4, 2, 8, 8, {{0, 1, 8, 1, 1}, {16, 1, 4, 2, 2}, {24, 1, 4, 2, 2}}};
}
static void fill(int index, int base) {
    planar(index);
    memset(buffers[index], 0xee, sizeof buffers[index]);
    for (int x = 0; x < 4; ++x) { buffers[index][x] = base + x; buffers[index][8 + x] = base + 10 + x; }
    buffers[index][16] = base + 20; buffers[index][17] = base + 21;
    buffers[index][24] = base + 30; buffers[index][25] = base + 31;
}

int main(void) {
    const uint8_t *frame = NULL; int width = 0, height = 0;
    uint8_t packet[3] = {1, 2, 3};
    // An access unit without an announced input buffer is retained, not lost.
    get_buffer_format = buffer_format;
    Video *v = video(4, 2);
    assert(gv_decode(v, packet, 3, GV_NV12, &frame, &width, &height) == -2 && queued == 0);
    on_input(&codec, v, 5);
    assert(gv_decode(v, packet, 3, GV_NV12, &frame, &width, &height) == 0);
    assert(queued == 1 && !memcmp(queued_bytes, packet, 3));
    // Pictures decoded together are converted one per call, oldest first, from
    // the plane layout the codec described for each buffer.
    fill(1, 1); fill(2, 100);
    output(v, 1, 32); output(v, 2, 32);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 12 && width == 4 && height == 2);
    assert(frame[0] == 1 && releases == 1 && released[0] == 1);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 12);
    const uint8_t nv12[12] = {100, 101, 102, 103, 110, 111, 112, 113, 120, 130, 121, 131};
    assert(!memcmp(frame, nv12, sizeof nv12));
    assert(releases == 2 && released[1] == 2 && !rendered && format_reads == 2);
    // RGBA output from the same planes.
    fill(3, 50); output(v, 3, 32);
    assert(gv_decode(v, NULL, 0, 0, &frame, &width, &height) == 32 && format_reads == 3);
    for (int pixel = 0; pixel < 8; ++pixel) assert(frame[pixel * 4 + 3] == 255);
    // Interleaved chroma and codec padding: a 6x2 buffer shows the stream's
    // 4x2. An output announced before the format change keeps its own layout.
    images[4] = (MediaImage2){MEDIA_IMAGE_TYPE_YUV, 3, 6, 2, 8, 8, {{0, 1, 8, 1, 1}, {16, 2, 8, 2, 2}, {17, 2, 8, 2, 2}}};
    memset(buffers[4], 0, sizeof buffers[4]);
    for (int x = 0; x < 6; ++x) { buffers[4][x] = 1 + x; buffers[4][8 + x] = 11 + x; }
    memcpy(buffers[4] + 16, (uint8_t[]){40, 50, 41, 51, 42, 52}, 6);
    output(v, 4, 24);
    on_format(&codec, v, &created);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 12 && width == 4 && height == 2);
    assert(!memcmp(frame, (uint8_t[]){1, 2, 3, 4, 11, 12, 13, 14, 40, 50, 41, 51}, 12) && format_reads == 4);
    // A plane past the valid bytes fails without keeping the buffer.
    images[5] = images[4];
    releases = 0; output(v, 5, 19);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == -1 && releases == 1 && released[0] == 5);
    // Without a described layout nothing is guessed, and the output is returned.
    releases = 0; output(v, 6, 32);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == -1 && releases == 1 && released[0] == 6);
    // A decoder far behind presentation queues 64 outputs and shows only the
    // two newest of them.
    releases = 0;
    for (int index = 7; index < 77; ++index) { fill(index, index); output(v, index, 32); }
    assert(releases == 6);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 12 && releases == 69 && frame[0] == 69);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 12 && releases == 70 && frame[0] == 70 && !rendered);
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == 0 && releases == 70);
    // A fatal codec error stops decoding.
    on_error(&codec, v, AMEDIA_ERROR_UNKNOWN, 0, "fake");
    assert(gv_decode(v, NULL, 0, GV_NV12, &frame, &width, &height) == -1);
    gv_free(v);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='graffitty-android-queue-') as directory:
    path = Path(directory)
    for name, text in headers.items():
        (path / name).parent.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(text)
    (path / 'test.c').write_text(test)
    subprocess.run(['clang', '-O1', '-g', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                    '-I', str(path), '-I', str(source), str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
print('PASS Android decode: retained input, pictures in order, described planes, padding, bounds, bursts, errors')
