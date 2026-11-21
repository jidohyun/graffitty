// clang -O2 -fsanitize=undefined tests/native/chromium_yuv_test.c -o /tmp/chromium-yuv-test
// /tmp/chromium-yuv-test
// Build without sanitizers and pass --bench [width height] for conversion timing.
#include "../../crates/transport/chromium-video/src/yuv420.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

static uint32_t seed = 0x82635f91;
static uint8_t random_byte(void) {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
    return (uint8_t)seed;
}
static uint8_t clamp_reference(int n) { return n < 0 ? 0 : n > 255 ? 255 : n; }
__attribute__((noinline)) static void reference(const GvYuvPlane p[3], int left, int top,
                                               int width, int height, uint8_t *out) {
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        int sx = x + left, sy = y + top;
        int luma = p[0].data[(size_t)sy * p[0].row_stride + sx * p[0].pixel_stride] - 16;
        int cb = p[1].data[(size_t)(sy / 2) * p[1].row_stride + (sx / 2) * p[1].pixel_stride] - 128;
        int cr = p[2].data[(size_t)(sy / 2) * p[2].row_stride + (sx / 2) * p[2].pixel_stride] - 128;
        size_t index = ((size_t)y * width + x) * 4;
        out[index] = clamp_reference((298 * luma + 409 * cr + 128) >> 8);
        out[index + 1] = clamp_reference((298 * luma - 100 * cb - 208 * cr + 128) >> 8);
        out[index + 2] = clamp_reference((298 * luma + 516 * cb + 128) >> 8);
        out[index + 3] = 255;
    }
}
__attribute__((noinline)) static void convert(const GvYuvPlane p[3], int left, int top,
                                             int width, int height, uint8_t *out) {
    gv_yuv420_rgba(p, left, top, width, height, out);
}
static void allocate_planes(GvYuvPlane p[3], int width, int height, int stride, int pad) {
    for (int i = 0; i < 3; ++i) {
        int w = i ? (width + 1) / 2 : width, h = i ? (height + 1) / 2 : height;
        p[i].pixel_stride = i ? (i == 2 && pad == 2 ? stride % 3 + 1 : stride) : (pad == 3 ? 2 : 1);
        p[i].row_stride = (w - 1) * p[i].pixel_stride + 1 + pad + (i == 2 && pad == 2 ? 5 : 0);
        // No trailing padding beyond the final valid sample. ASan will catch
        // chroma loads that assume an interleaved plane owns its neighbour byte.
        size_t length = (size_t)(h - 1) * p[i].row_stride + (w - 1) * p[i].pixel_stride + 1;
        uint8_t *data = malloc(length);
        assert(data);
        for (size_t j = 0; j < length; ++j) data[j] = random_byte();
        p[i].data = data;
    }
}
static void release_planes(GvYuvPlane p[3]) {
    for (int i = 0; i < 3; ++i) free((void *)p[i].data);
}
// Exercise exact end-of-plane storage next to an inaccessible page, without
// relying on a sanitizer allocator. This includes seven-byte interleaved tails.
static void guarded_tails(void) {
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    for (int width = 7; width <= 25; ++width)
    for (int left = 0; left <= 1; ++left)
    for (int top = 0; top <= 1; ++top)
    for (int stride = 1; stride <= 3; ++stride) {
        const int height = 3;
        GvYuvPlane planes[3]; void *mapping[4];
        for (int i = 0; i < 4; ++i) {
            mapping[i] = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            assert(mapping[i] != MAP_FAILED);
            assert(mprotect((uint8_t *)mapping[i] + page, page, PROT_NONE) == 0);
        }
        for (int i = 0; i < 3; ++i) {
            int w = i ? (width + left + 1) / 2 : width + left;
            int h = i ? (height + top + 1) / 2 : height + top;
            planes[i].pixel_stride = i ? stride : 1;
            planes[i].row_stride = (w - 1) * planes[i].pixel_stride + 1;
            size_t length = (size_t)planes[i].row_stride * h;
            uint8_t *data = (uint8_t *)mapping[i] + page - length;
            for (size_t j = 0; j < length; ++j) data[j] = random_byte();
            planes[i].data = data;
        }
        size_t length = (size_t)width * height * 4;
        uint8_t *out = (uint8_t *)mapping[3] + page - length, expected[25 * 3 * 4];
        reference(planes, left, top, width, height, expected);
        convert(planes, left, top, width, height, out);
        assert(!memcmp(out, expected, length));
        for (int i = 0; i < 4; ++i) assert(munmap(mapping[i], page * 2) == 0);
    }
    puts("PASS guarded YUV source/output tails");
}
static double milliseconds(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--bench")) {
        int width = argc > 2 ? atoi(argv[2]) : 2560;
        int height = argc > 3 ? atoi(argv[3]) : 1600;
        assert(width > 0 && height > 0);
        GvYuvPlane planes[3]; allocate_planes(planes, width, height, 2, 1);
        uint8_t *a = malloc((size_t)width * height * 4), *b = malloc((size_t)width * height * 4);
        assert(a && b);
        const int iterations = 100;
        double start = milliseconds();
        for (int n = 0; n < iterations; ++n) reference(planes, 0, 0, width, height, a);
        double scalar = (milliseconds() - start) / iterations;
        start = milliseconds();
        for (int n = 0; n < iterations; ++n) convert(planes, 0, 0, width, height, b);
        double optimized = (milliseconds() - start) / iterations;
        assert(!memcmp(a, b, (size_t)width * height * 4));
        printf("%dx%d scalar=%.3fms optimized=%.3fms speedup=%.2fx\n", width, height, scalar, optimized, scalar / optimized);
        free(a); free(b); release_planes(planes);
        return 0;
    }
    unsigned cases = 0;
    for (int width = 1; width <= 65; ++width)
    for (int height = 1; height <= 9; height += 2)
    for (int left = 0; left <= 3; ++left)
    for (int top = 0; top <= 3; ++top)
    for (int stride = 1; stride <= 3; ++stride)
    for (int pad = 0; pad <= 3; ++pad) {
        GvYuvPlane planes[3]; allocate_planes(planes, width + left, height + top, stride, pad);
        size_t length = (size_t)width * height * 4;
        uint8_t *a = malloc(length), *b = malloc(length);
        assert(a && b);
        reference(planes, left, top, width, height, a);
        convert(planes, left, top, width, height, b);
        if (memcmp(a, b, length)) {
            fprintf(stderr, "Mismatch width=%d height=%d crop=%d,%d stride=%d pad=%d\n", width, height, left, top, stride, pad);
            return 1;
        }
        free(a); free(b); release_planes(planes); ++cases;
    }
    printf("PASS %u YUV crop/stride/tail cases\n", cases);
    guarded_tails();
    return 0;
}
