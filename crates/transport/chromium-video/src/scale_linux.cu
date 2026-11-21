// Area-weighted resampling of 32-bit RGBA/BGRA pixels for the Linux NVENC path.
// Channel order is preserved. Each destination pixel averages its source
// footprint, at least one source pixel wide, so downscaling does not alias.
//
// The checked-in scale_linux.ptx is generated from this file; no CUDA toolkit is
// needed to build Graffitty. Regenerate after editing, with clang's NVPTX target:
//   clang -x cuda --cuda-device-only --cuda-gpu-arch=sm_50 -nocudainc -nocudalib \
//     -O3 -S -o scale_linux.ptx scale_linux.cu
#define __global__ __attribute__((global))

typedef unsigned int u32;
typedef unsigned long long u64;

static __attribute__((device)) float clampf(float value, float low, float high) {
    return __builtin_fminf(__builtin_fmaxf(value, low), high);
}

extern "C" __global__ void graffitty_scale(const unsigned char *source, u32 source_width,
                                           u32 source_height, u32 source_pitch,
                                           unsigned char *destination, u32 width, u32 height,
                                           u32 pitch) {
    const u32 x = __nvvm_read_ptx_sreg_ctaid_x() * __nvvm_read_ptx_sreg_ntid_x() +
                  __nvvm_read_ptx_sreg_tid_x();
    const u32 y = __nvvm_read_ptx_sreg_ctaid_y() * __nvvm_read_ptx_sreg_ntid_y() +
                  __nvvm_read_ptx_sreg_tid_y();
    if (x >= width || y >= height)
        return;
    const float sx = (float)source_width / width, sy = (float)source_height / height;
    const float fx = __builtin_fmaxf(sx, 1.0f), fy = __builtin_fmaxf(sy, 1.0f);
    const float cx = (x + 0.5f) * sx, cy = (y + 0.5f) * sy;
    const float x0 = clampf(cx - fx * 0.5f, 0.0f, source_width);
    const float x1 = clampf(cx + fx * 0.5f, 0.0f, source_width);
    const float y0 = clampf(cy - fy * 0.5f, 0.0f, source_height);
    const float y1 = clampf(cy + fy * 0.5f, 0.0f, source_height);
    float sum[4] = {0.0f, 0.0f, 0.0f, 0.0f}, total = 0.0f;
    for (u32 row = (u32)y0; row < source_height && row < y1; ++row) {
        const float wy = __builtin_fminf(y1, row + 1.0f) - __builtin_fmaxf(y0, (float)row);
        if (wy <= 0.0f)
            continue;
        const u32 *line = (const u32 *)(source + (u64)row * source_pitch);
        for (u32 column = (u32)x0; column < source_width && column < x1; ++column) {
            const float w = wy * (__builtin_fminf(x1, column + 1.0f) - __builtin_fmaxf(x0, (float)column));
            if (w <= 0.0f)
                continue;
            const u32 pixel = line[column];
            for (int channel = 0; channel < 4; ++channel)
                sum[channel] += w * ((pixel >> (8 * channel)) & 0xff);
            total += w;
        }
    }
    u32 out = 0;
    if (total > 0.0f)
        for (int channel = 0; channel < 4; ++channel)
            out |= (u32)clampf(sum[channel] / total + 0.5f, 0.0f, 255.0f) << (8 * channel);
    *(u32 *)(destination + (u64)y * pitch + (u64)x * 4) = out;
}
