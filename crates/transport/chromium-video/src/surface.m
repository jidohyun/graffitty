#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <CoreVideo/CoreVideo.h>
#include <servers/bootstrap.h>
#include "../include/frame_protocol.h"

// VideoToolbox encodes RGB IOSurfaces as full-range YUV even when the codec
// requests video range. Convert on the GPU into an explicitly limited-range
// NV12 pixel buffer, matching the transport's BT.601 client conversion.
void *gv_surface_video_pixel(void *value) {
    @autoreleasepool {
        IOSurfaceRef source = value;
        if (!source) return NULL;
        const size_t width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source);
        if (!width || !height || (width | height) & 1) return NULL;
        OSType format = IOSurfaceGetPixelFormat(source);
        if (format != 'BGRA' && format != 'RGBA') return NULL;
        static id<MTLDevice> device;
        static id<MTLCommandQueue> queue;
        static id<MTLComputePipelineState> pipeline;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            device = MTLCreateSystemDefaultDevice();
            queue = [device newCommandQueue];
            NSString *shader = @"#include <metal_stdlib>\nusing namespace metal;\n"
                "kernel void nv12(texture2d<float,access::read> src [[texture(0)]],"
                "texture2d<float,access::write> y [[texture(1)]],"
                "texture2d<float,access::write> uv [[texture(2)]],uint2 p [[thread_position_in_grid]]) {"
                "if(p.x>=uv.get_width()||p.y>=uv.get_height())return;"
                "float3 average=0;for(uint j=0;j<2;++j)for(uint i=0;i<2;++i){"
                "uint2 q=p*2+uint2(i,j);float3 rgb=src.read(q).rgb;average+=rgb*.25;"
                "float l=dot(rgb,float3(.256788,.504129,.097906))+16.0/255.0;"
                "y.write(float4(l,0,0,1),q);}"
                "float u=dot(average,float3(-.148223,-.290993,.439216))+128.0/255.0;"
                "float v=dot(average,float3(.439216,-.367788,-.071427))+128.0/255.0;"
                "uv.write(float4(u,v,0,1),p);}";
            id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:nil];
            id<MTLFunction> function = [library newFunctionWithName:@"nv12"];
            if (function) pipeline = [device newComputePipelineStateWithFunction:function error:nil];
            [function release]; [library release];
        });
        if (!queue || !pipeline) return NULL;
        CVPixelBufferRef pixel = NULL;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                     (id)kCVPixelBufferMetalCompatibilityKey:@YES};
        if (CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                               (CFDictionaryRef)attributes, &pixel) != kCVReturnSuccess) return NULL;
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            format == 'BGRA' ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRGBA8Unorm
            width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> input = [device newTextureWithDescriptor:desc iosurface:source plane:0];
        desc.usage = MTLTextureUsageShaderWrite;
        desc.pixelFormat = MTLPixelFormatR8Unorm;
        IOSurfaceRef output = CVPixelBufferGetIOSurface(pixel);
        id<MTLTexture> y = [device newTextureWithDescriptor:desc iosurface:output plane:0];
        desc.pixelFormat = MTLPixelFormatRG8Unorm;
        desc.width = width / 2; desc.height = height / 2;
        id<MTLTexture> uv = [device newTextureWithDescriptor:desc iosurface:output plane:1];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLComputeCommandEncoder> compute = input && y && uv ? [command computeCommandEncoder] : nil;
        if (compute) {
            [compute setComputePipelineState:pipeline];
            [compute setTexture:input atIndex:0]; [compute setTexture:y atIndex:1]; [compute setTexture:uv atIndex:2];
            [compute dispatchThreads:MTLSizeMake(width / 2, height / 2, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [compute endEncoding]; [command commit]; [command waitUntilCompleted];
        }
        BOOL complete = compute && command.status == MTLCommandBufferStatusCompleted;
        [input release]; [y release]; [uv release];
        if (!complete) { CVPixelBufferRelease(pixel); return NULL; }
        return (void *)pixel;
    }
}

void *gv_surface_crop(void *value, uint32_t width, uint32_t height) {
    @autoreleasepool {
        IOSurfaceRef source=value;
        if (!source || !width || !height || width>IOSurfaceGetWidth(source) ||
            height>IOSurfaceGetHeight(source) || IOSurfaceGetPixelFormat(source)!='BGRA') return NULL;
        static id<MTLDevice> device;
        static id<MTLCommandQueue> queue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];});
        if (!queue) return NULL;
        size_t stride=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,(size_t)width*4);
        IOSurfaceRef output=IOSurfaceCreate((CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),
            (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@(stride),
            (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
        if (!output) return NULL;
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:IOSurfaceGetWidth(source) height:IOSurfaceGetHeight(source) mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> input=[device newTextureWithDescriptor:desc iosurface:source plane:0];
        desc.width=width;desc.height=height;
        id<MTLTexture> target=[device newTextureWithDescriptor:desc iosurface:output plane:0];
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=input && target ? [command blitCommandEncoder] : nil;
        if (blit) {
            [blit copyFromTexture:input sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(width,height,1) toTexture:target destinationSlice:0
                destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [blit endEncoding];[command commit];[command waitUntilCompleted];
        }
        BOOL complete=blit && command.status==MTLCommandBufferStatusCompleted;
        [input release];[target release];
        if (!complete) {CFRelease(output);return NULL;}
        return (void *)output;
    }
}

void *gv_surface_scale(void *value, uint32_t width, uint32_t height) {
    @autoreleasepool {
        IOSurfaceRef source=value;
        if (!source || !width || !height || width>IOSurfaceGetWidth(source) ||
            height>IOSurfaceGetHeight(source) || IOSurfaceGetPixelFormat(source)!='BGRA') return NULL;
        static id<MTLDevice> device;
        static id<MTLCommandQueue> queue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];});
        if (!queue) return NULL;
        size_t stride=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,(size_t)width*4);
        IOSurfaceRef output=IOSurfaceCreate((CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),
            (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@(stride),
            (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
        if (!output) return NULL;
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:IOSurfaceGetWidth(source) height:IOSurfaceGetHeight(source) mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> input=[device newTextureWithDescriptor:desc iosurface:source plane:0];
        desc.width=width;desc.height=height;
        id<MTLTexture> target=[device newTextureWithDescriptor:desc iosurface:output plane:0];
        id<MTLCommandBuffer> command=[queue commandBuffer];
        MPSImageBilinearScale *scale=[[MPSImageBilinearScale alloc] initWithDevice:device];
        BOOL ready=input && target && scale;
        if (ready) {
            [scale encodeToCommandBuffer:command sourceTexture:input destinationTexture:target];
            [command commit];[command waitUntilCompleted];
        }
        BOOL complete=ready && command.status==MTLCommandBufferStatusCompleted;
        [scale release];[input release];[target release];
        if (!complete) {CFRelease(output);return NULL;}
        return (void *)output;
    }
}

void *gv_surface_from_rgba(uint32_t width, uint32_t height, const uint8_t *rgba) {
    @autoreleasepool {
        if (!width || !height || width > 8192 || height > 8192 || !rgba) return NULL;
        size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 4);
        IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height),
            (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@(stride),
            (id)kIOSurfacePixelFormat:@((uint32_t)'BGRA')});
        if (!surface) return NULL;
        if (IOSurfaceLock(surface, 0, NULL) != kIOReturnSuccess) { CFRelease(surface); return NULL; }
        uint8_t *base = IOSurfaceGetBaseAddress(surface);
        for (size_t y=0; y<height; ++y) for (size_t x=0; x<width; ++x) {
            const uint8_t *p = rgba + (y * width + x) * 4;
            uint8_t *q = base + y * stride + x * 4;
            q[0]=p[2]; q[1]=p[1]; q[2]=p[0]; q[3]=p[3];
        }
        IOSurfaceUnlock(surface, 0, NULL);
        return (void *)surface;
    }
}

void *gv_receiver_new(const char *name) {
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) return NULL;
    mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_limits_t limits = {1};
    mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
                            (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    if (bootstrap_register(bootstrap_port, (char *)name, port) != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), port); return NULL;
    }
    return (void *)(uintptr_t)port;
}
void gv_receiver_free(void *receiver) {
    mach_port_destroy(mach_task_self(), (mach_port_t)(uintptr_t)receiver);
}
void *gv_surface_receive(void *receiver, uint32_t *width, uint32_t *height) {
    struct { struct ChromiumFrameMessage frame; mach_msg_max_trailer_t trailer; } packet = {0};
    struct ChromiumFrameMessage *m = &packet.frame;
    if (mach_msg(&m->header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(packet),
                 (mach_port_t)(uintptr_t)receiver, 0, MACH_PORT_NULL) != KERN_SUCCESS) return NULL;
    if (m->header.msgh_size != sizeof(*m) || !(m->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
        m->body.msgh_descriptor_count != 1 || m->surface.type != MACH_MSG_PORT_DESCRIPTOR) {
        mach_msg_destroy(&m->header); return NULL;
    }
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(m->surface.name);
    mach_msg_destroy(&m->header);
    if (!surface) return NULL;
    if (m->width != IOSurfaceGetWidth(surface) || m->height != IOSurfaceGetHeight(surface) ||
        m->width < 16 || m->height < 16 || m->width > 4096 || m->height > 4096 ||
        IOSurfaceGetPixelFormat(surface) != 'BGRA') {
        CFRelease(surface); return NULL;
    }
    // BGRA captures and compatibility PNGs support odd dimensions. Chroma
    // alignment is an encoder constraint, not a property of the source image;
    // rejecting it here silently freezes every client at its previous frame.
    *width = m->width; *height = m->height;
    return (void *)surface;
}
void gv_surface_free(void *surface) { CFRelease(surface); }
// Compatibility images only. The video path never calls this function.
int gv_surface_rgba(void *value, uint8_t *out) {
    IOSurfaceRef surface = value;
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) return -1;
    const uint8_t *base = IOSurfaceGetBaseAddress(surface);
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        const uint8_t *p = base + y * stride + x * 4;
        uint8_t *q = out + (y * width + x) * 4;
        q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = p[3];
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return 0;
}
