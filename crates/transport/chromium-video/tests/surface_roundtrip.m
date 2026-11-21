// Run on macOS without a window or GPU context:
// clang native/chromium-video/tests/surface_roundtrip.m -framework Foundation \
//   -framework IOSurface -framework ImageIO -framework CoreGraphics \
//   -o /tmp/graffitty-surface-roundtrip && /tmp/graffitty-surface-roundtrip
#include "../src/surface.m"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>

static void roundtrip(uint32_t width, uint32_t height) {
    NSString *name = [NSString stringWithFormat:@"dev.graffitty.surface-test.%d.%u.%u",
                                               getpid(), width, height];
    void *receiver = gv_receiver_new(name.UTF8String);
    assert(receiver);
    IOSurfaceRef sent = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth: @(width), (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)),
        (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA')});
    assert(sent);
    assert(IOSurfaceLock(sent, 0, NULL) == kIOReturnSuccess);
    uint8_t *base = IOSurfaceGetBaseAddress(sent);
    size_t stride = IOSurfaceGetBytesPerRow(sent);
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        uint8_t *p = base + y * stride + x * 4;
        p[0] = (uint8_t)x; p[1] = (uint8_t)y; p[2] = 173; p[3] = 255;
    }
    IOSurfaceUnlock(sent, 0, NULL);
    struct ChromiumFrameMessage message = {0};
    message.header.msgh_bits = MACH_MSGH_BITS_COMPLEX |
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = (mach_port_t)(uintptr_t)receiver;
    message.body.msgh_descriptor_count = 1;
    message.surface.name = IOSurfaceCreateMachPort(sent);
    message.surface.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.surface.type = MACH_MSG_PORT_DESCRIPTOR;
    message.width = width; message.height = height; message.bgra = 1;
    assert(mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    sizeof(message), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL) == KERN_SUCCESS);
    CFRelease(sent);
    uint32_t received_width = 0, received_height = 0;
    void *received = gv_surface_receive(receiver, &received_width, &received_height);
    assert(received && received_width == width && received_height == height);
    uint8_t *rgba = calloc(width * height, 4);
    assert(gv_surface_rgba(received, rgba) == 0);
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        const uint8_t *p = rgba + (y * width + x) * 4;
        assert(p[0] == 173 && p[1] == (uint8_t)y && p[2] == (uint8_t)x && p[3] == 255);
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba, width, height, 8, width * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *png = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    assert(CGImageDestinationFinalize(destination));
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    assert(CGImageGetWidth(decoded) == width && CGImageGetHeight(decoded) == height);
    uint8_t *decoded_rgba = calloc(width * height, 4);
    CGContextRef decoded_context = CGBitmapContextCreate(decoded_rgba, width, height, 8,
        width * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(decoded_context, CGRectMake(0, 0, width, height), decoded);
    assert(memcmp(rgba, decoded_rgba, width * height * 4) == 0);
    CFRelease(decoded_context); free(decoded_rgba);
    CFRelease(decoded); CFRelease(source); CFRelease(destination); CFRelease(image);
    CFRelease(context); CFRelease(space);
    free(rgba); gv_surface_free(received); gv_receiver_free(receiver);
}
int main(void) {
    @autoreleasepool {
        roundtrip(315, 564);
        roundtrip(480, 565);
        roundtrip(315, 565);
        roundtrip(480, 564);
        puts("PASS: exact BGRA pixels and PNG dimensions survive odd/even Mach IOSurface delivery");
    }
}
