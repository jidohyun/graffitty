// Whether this GPU can run Godot's Metal renderers (see ios_renderer.rs).
#import <Metal/Metal.h>

int gft_ios_metal_renderer_supported(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device != nil && [device supportsFamily:MTLGPUFamilyApple4];
    }
}
