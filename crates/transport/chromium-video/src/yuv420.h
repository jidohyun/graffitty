// Android's flexible YUV planes can be planar or interleaved, with independent
// row/pixel strides and an odd crop origin. The caller validates the crop
// against each plane's byte length before entering this conversion.
#ifndef GRAFFITTY_YUV420_H
#define GRAFFITTY_YUV420_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

typedef struct {
    const uint8_t *data;
    int row_stride, pixel_stride;
} GvYuvPlane;

static inline uint8_t gv_yuv_clamp(int value) {
    return value < 0 ? 0 : value > 255 ? 255 : value;
}
static inline void gv_yuv_pixel(const GvYuvPlane planes[3], int x, int y, uint8_t *out) {
    int yy = planes[0].data[(size_t)y * planes[0].row_stride + x * planes[0].pixel_stride] - 16;
    int u = planes[1].data[(size_t)(y / 2) * planes[1].row_stride + (x / 2) * planes[1].pixel_stride] - 128;
    int v = planes[2].data[(size_t)(y / 2) * planes[2].row_stride + (x / 2) * planes[2].pixel_stride] - 128;
    out[0] = gv_yuv_clamp((298 * yy + 409 * v + 128) >> 8);
    out[1] = gv_yuv_clamp((298 * yy - 100 * u - 208 * v + 128) >> 8);
    out[2] = gv_yuv_clamp((298 * yy + 516 * u + 128) >> 8);
    out[3] = 255;
}
#if defined(__aarch64__)
// Read exactly four chroma samples, including at the last row/plane boundary.
// Loading eight interleaved bytes could overread a seven-byte U or V tail.
static inline uint8x8_t gv_yuv_chroma4(const uint8_t *p, int stride) {
    uint32_t packed;
    if (stride == 1) memcpy(&packed, p, sizeof(packed));
    else packed = p[0] | ((uint32_t)p[stride] << 8)
        | ((uint32_t)p[2 * stride] << 16) | ((uint32_t)p[3 * stride] << 24);
    uint8x8_t four = vreinterpret_u8_u32(vcreate_u32(packed));
    return vzip_u8(four, four).val[0];
}
static inline uint8x8_t gv_yuv_channel(int16x8_t y, int16x8_t u, int16x8_t v, int uc, int vc) {
    int32x4_t low = vmull_n_s16(vget_low_s16(y), 298);
    int32x4_t high = vmull_n_s16(vget_high_s16(y), 298);
    if (uc) {
        low = vmlal_n_s16(low, vget_low_s16(u), uc);
        high = vmlal_n_s16(high, vget_high_s16(u), uc);
    }
    if (vc) {
        low = vmlal_n_s16(low, vget_low_s16(v), vc);
        high = vmlal_n_s16(high, vget_high_s16(v), vc);
    }
    // Rounding shift is exactly (value + 128) >> 8, including negative values.
    return vqmovun_s16(vcombine_s16(vrshrn_n_s32(low, 8), vrshrn_n_s32(high, 8)));
}
#endif
// NV12 for conversion on the GPU: full-resolution Y rows, then interleaved
// Cb/Cr rows at half resolution. Semi-planar NV12 sources copy whole rows.
static inline void gv_yuv420_nv12(const GvYuvPlane planes[3], int left, int top,
                                  int width, int height, uint8_t *out) {
    for (int y = 0; y < height; ++y) {
        const uint8_t *row = planes[0].data + (size_t)(y + top) * planes[0].row_stride;
        uint8_t *luma = out + (size_t)y * width;
        if (planes[0].pixel_stride == 1) memcpy(luma, row + left, width);
        else for (int x = 0; x < width; ++x) luma[x] = row[(size_t)(x + left) * planes[0].pixel_stride];
    }
    int chroma_width = (width + 1) / 2, chroma_height = (height + 1) / 2;
    uint8_t *chroma = out + (size_t)width * height;
    int interleaved = planes[1].pixel_stride == 2 && planes[2].pixel_stride == 2 &&
                      planes[2].data == planes[1].data + 1;
    for (int y = 0; y < chroma_height; ++y) {
        size_t row = (size_t)(y + top / 2);
        const uint8_t *u = planes[1].data + row * planes[1].row_stride + (size_t)(left / 2) * planes[1].pixel_stride;
        const uint8_t *v = planes[2].data + row * planes[2].row_stride + (size_t)(left / 2) * planes[2].pixel_stride;
        uint8_t *pair = chroma + (size_t)y * chroma_width * 2;
        if (interleaved) {
            memcpy(pair, u, (size_t)chroma_width * 2);
            continue;
        }
        for (int x = 0; x < chroma_width; ++x) {
            pair[2 * x] = u[(size_t)x * planes[1].pixel_stride];
            pair[2 * x + 1] = v[(size_t)x * planes[2].pixel_stride];
        }
    }
}
static inline void gv_yuv420_rgba(const GvYuvPlane planes[3], int left, int top,
                                  int width, int height, uint8_t *out) {
    for (int y = 0; y < height; ++y) {
        int py = y + top, x = 0;
        uint8_t *row = out + (size_t)y * width * 4;
#if defined(__aarch64__)
        if (planes[0].pixel_stride == 1) {
            // Align the source chroma pair, not the destination pixel position.
            if ((left & 1) && width > 0) {
                gv_yuv_pixel(planes, left, py, row);
                x = 1;
            }
            for (; x + 8 <= width; x += 8) {
                int px = x + left;
                int16x8_t yy = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(
                    planes[0].data + (size_t)py * planes[0].row_stride + px))), vdupq_n_s16(16));
                int16x8_t u = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(gv_yuv_chroma4(
                    planes[1].data + (size_t)(py / 2) * planes[1].row_stride + (px / 2) * planes[1].pixel_stride,
                    planes[1].pixel_stride))), vdupq_n_s16(128));
                int16x8_t v = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(gv_yuv_chroma4(
                    planes[2].data + (size_t)(py / 2) * planes[2].row_stride + (px / 2) * planes[2].pixel_stride,
                    planes[2].pixel_stride))), vdupq_n_s16(128));
                uint8x8x4_t rgba = {{gv_yuv_channel(yy, u, v, 0, 409),
                    gv_yuv_channel(yy, u, v, -100, -208), gv_yuv_channel(yy, u, v, 516, 0), vdup_n_u8(255)}};
                vst4_u8(row + x * 4, rgba);
            }
        }
#endif
        for (; x < width; ++x) gv_yuv_pixel(planes, x + left, py, row + x * 4);
    }
}
#endif
