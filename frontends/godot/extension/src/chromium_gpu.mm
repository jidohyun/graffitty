#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include "../../../../crates/transport/chromium-video/include/frame_protocol.h"
struct Receiver {
    mach_port_t port = MACH_PORT_NULL;
};
extern "C" void *graffitty_gpu_receiver_create(const char *name) {
    auto *r = new Receiver;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &r->port) != KERN_SUCCESS) {
        delete r;
        return nullptr;
    }
    mach_port_insert_right(mach_task_self(), r->port, r->port, MACH_MSG_TYPE_MAKE_SEND);
    mach_port_limits_t limits = {1};
    mach_port_set_attributes(mach_task_self(), r->port, MACH_PORT_LIMITS_INFO,
                             (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    if (bootstrap_register(bootstrap_port, const_cast<char *>(name), r->port) != KERN_SUCCESS) {
        mach_port_destroy(mach_task_self(), r->port);
        delete r;
        return nullptr;
    }
    return r;
}
extern "C" void graffitty_gpu_receiver_destroy(void *pointer) {
    auto *r = static_cast<Receiver *>(pointer);
    if (r) {
        mach_port_destroy(mach_task_self(), r->port);
        delete r;
    }
}
extern "C" uint64_t graffitty_gpu_receive(void *pointer, uint64_t device_handle, uint32_t *width,
                                        uint32_t *height, uint32_t *bgra, uint64_t *sequence) {
    @autoreleasepool {
        auto *r = static_cast<Receiver *>(pointer);
        if (!r || !device_handle)
            return 0;
        struct {
            ChromiumFrameMessage frame;
            mach_msg_max_trailer_t trailer;
        } packet = {};
        auto &m = packet.frame;
        auto error = mach_msg(&m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(packet),
                              r->port, 0, MACH_PORT_NULL);
        if (error != KERN_SUCCESS)
            return 0;
        if (!(m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) || m.body.msgh_descriptor_count != 1 ||
            m.surface.type != MACH_MSG_PORT_DESCRIPTOR) {
            mach_msg_destroy(&m.header);
            return 0;
        }
        IOSurfaceRef surface = IOSurfaceLookupFromMachPort(m.surface.name);
        mach_msg_destroy(&m.header);
        if (!surface)
            return 0;
        if (m.width != IOSurfaceGetWidth(surface) || m.height != IOSurfaceGetHeight(surface) ||
            m.width > 8192 || m.height > 8192) {
            CFRelease(surface);
            return 0;
        }
        id<MTLDevice> device = (__bridge id<MTLDevice>)(void *)device_handle;
        auto *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:m.bgra ? MTLPixelFormatBGRA8Unorm
                                                      : MTLPixelFormatRGBA8Unorm
                                         width:m.width
                                        height:m.height
                                     mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc iosurface:surface plane:0];
        CFRelease(surface);
        if (!texture)
            return 0;
        *width = m.width;
        *height = m.height;
        *bgra = m.bgra;
        *sequence = m.sequence;
        // Godot's Metal texture_create_from_extension takes ownership (+1).
        return (uint64_t)CFBridgingRetain(texture);
    }
}
