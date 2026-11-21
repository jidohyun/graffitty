// VideoToolbox adapter only. Rust validates Annex-B and owns parameter-set state.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "yuv420.h"
#include <stdlib.h>

typedef struct {
    CMVideoFormatDescriptionRef format;
    VTDecompressionSessionRef session;
    CVPixelBufferRef picture;
    OSStatus error;
    uint8_t *pixels;
    size_t capacity;
    int64_t sequence;
} GviDecoder;

int gvi_supported(int codec) {
    // AV1 uses a different sequence-header/container contract; don't advertise it.
    CMVideoCodecType type = codec == 0 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC;
    return (codec == 0 || codec == 1) && VTIsHardwareDecodeSupported(type);
}
void *gvi_new(int codec) { return gvi_supported(codec) ? calloc(1, sizeof(GviDecoder)) : NULL; }

static void picture(void *context, void *source, OSStatus status, VTDecodeInfoFlags flags,
                    CVImageBufferRef image, CMTime pts, CMTime duration) {
    GviDecoder *v = context;
    if (status) { v->error = status; return; }
    if (!image) return;
    if (v->picture) CVPixelBufferRelease(v->picture);
    v->picture = CVPixelBufferRetain(image);
}
static void reset(GviDecoder *v) {
    if (v->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(v->session);
        VTDecompressionSessionInvalidate(v->session);
        CFRelease(v->session);
        v->session = NULL;
    }
    if (v->format) { CFRelease(v->format); v->format = NULL; }
    if (v->picture) { CVPixelBufferRelease(v->picture); v->picture = NULL; }
    v->error = 0;
}
void gvi_free(void *opaque) {
    GviDecoder *v = opaque;
    if (!v) return;
    reset(v);
    free(v->pixels);
    free(v);
}

int gvi_configure(void *opaque, int codec, const uint8_t *const *sets, const size_t *sizes, size_t count) {
    @autoreleasepool {
        GviDecoder *v = opaque;
        reset(v);
        OSStatus status;
        if (codec == 0 && count == 2)
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, sets, sizes, 4, &v->format);
        else if (codec == 1 && count == 3)
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, sets, sizes, 4, NULL, &v->format);
        else return -1;
        if (status) return -1;
        CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(v->format);
        if (size.width <= 0 || size.height <= 0 || size.width > 8192 || size.height > 8192
            || (uint64_t)size.width * size.height > 16 * 1024 * 1024) return -1;
        // The hardware-decoder keys are iOS 17+. Before iOS 17, iOS VideoToolbox
        // has no software H.264/HEVC decoder to fall back to, so the session is
        // hardware without asking.
        bool verify = false;
        NSDictionary *decoder = nil;
        if (@available(iOS 17.0, macOS 10.9, *)) {
            verify = true;
            decoder = @{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        }
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        VTDecompressionOutputCallbackRecord callback = {picture, v};
        status = VTDecompressionSessionCreate(kCFAllocatorDefault, v->format, (__bridge CFDictionaryRef)decoder,
                                              (__bridge CFDictionaryRef)attributes, &callback, &v->session);
        if (status) return -1;
        // Verify the created session too, rather than silently using software.
        if (verify) {
            if (@available(iOS 17.0, macOS 10.9, *)) {
                CFTypeRef hardware = NULL;
                status = VTSessionCopyProperty(v->session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                               kCFAllocatorDefault, &hardware);
                bool accelerated = !status && hardware && CFEqual(hardware, kCFBooleanTrue);
                if (hardware) CFRelease(hardware);
                if (!accelerated) { reset(v); return -1; }
            }
        }
        VTSessionSetProperty(v->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        return 0;
    }
}

int gvi_decode(void *opaque, const uint8_t *bytes, size_t length, int layout,
               const uint8_t **pixels, int *width, int *height) {
    GviDecoder *v = opaque;
    if (layout != 0 && layout != 1) return -1;
    if (length) {
        if (!v->session || length > 8 * 1024 * 1024) return -1;
        CMBlockBufferRef block = NULL;
        CMSampleBufferRef sample = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length,
            kCFAllocatorDefault, NULL, 0, length, 0, &block);
        if (!status) status = CMBlockBufferReplaceDataBytes(bytes, block, 0, length);
        CMSampleTimingInfo timing = {CMTimeMake(1, 60), CMTimeMake(v->sequence++, 60), kCMTimeInvalid};
        if (!status) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, v->format,
            1, 1, &timing, 1, &length, &sample);
        if (!status) status = VTDecompressionSessionDecodeFrame(v->session, sample, 0, NULL, NULL);
        // Synchronous, worker-owned decoding: no UI-thread wait or polling timer.
        if (v->session) VTDecompressionSessionWaitForAsynchronousFrames(v->session);
        if (sample) CFRelease(sample);
        if (block) CFRelease(block);
        if (status || v->error) return -1;
    }
    if (!v->picture) return 0;
    CVPixelBufferRef image = v->picture;
    v->picture = NULL;
    int result = -1;
    if (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        || CVPixelBufferGetPlaneCount(image) != 2) goto done;
    size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image);
    if (!w || !h || w > 8192 || h > 8192 || w * h > 16 * 1024 * 1024) goto done;
    size_t size = layout == 1 ? w*h + ((w+1)/2)*((h+1)/2)*2 : w*h*4;
    if (size > v->capacity) {
        uint8_t *allocated = realloc(v->pixels, size);
        if (!allocated) goto done;
        v->pixels = allocated;
        v->capacity = size;
    }
    if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly)) goto done;
    const uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(image, 0);
    const uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0);
    size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    if (y && uv && y_stride >= w && uv_stride >= ((w+1)/2)*2
        && CVPixelBufferGetHeightOfPlane(image, 0) >= h && CVPixelBufferGetHeightOfPlane(image, 1) >= (h+1)/2) {
        GvYuvPlane planes[3] = {{y, (int)y_stride, 1}, {uv, (int)uv_stride, 2}, {uv+1, (int)uv_stride, 2}};
        if (layout == 1) gv_yuv420_nv12(planes, 0, 0, (int)w, (int)h, v->pixels);
        else gv_yuv420_rgba(planes, 0, 0, (int)w, (int)h, v->pixels);
        *pixels = v->pixels; *width = (int)w; *height = (int)h;
        result = (int)size;
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
done:
    CVPixelBufferRelease(image);
    return result;
}
