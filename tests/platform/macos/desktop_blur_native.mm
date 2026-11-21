#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
extern "C" bool graffitty_desktop_blur(uint64_t, bool, int, uint64_t);

@interface BlurTestDelegate : NSObject <NSWindowDelegate>
@property BOOL closeRequested;
@end
@implementation BlurTestDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender {
    self.closeRequested = YES;
    return NO;
}
@end

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *first = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(100, 100, 400, 300)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                                NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        uint64_t handle = (uint64_t)(__bridge void *)first;
        NSView *renderer = first.contentView;
        renderer.wantsLayer = YES;
        CAMetalLayer *metal = [CAMetalLayer layer];
        renderer.layer = metal;
        BlurTestDelegate *delegate = [BlurTestDelegate new];
        first.delegate = delegate;
        assert(!graffitty_desktop_blur(0, true, 20, 0));
        assert(!graffitty_desktop_blur(handle, true, -1, 0));
        NSUInteger children = renderer.subviews.count;
        assert(graffitty_desktop_blur(handle, true, 20, 0));
        assert(first.contentView == renderer && renderer.subviews.count == children);
        NSButton *close = [first standardWindowButton:NSWindowCloseButton];
        NSView *frame = first.contentView.superview;
        NSPoint close_point =
            [close convertPoint:NSMakePoint(NSMidX(close.bounds), NSMidY(close.bounds))
                         toView:frame];
        NSView *hit = [frame hitTest:close_point];
        assert(hit == close || [hit isDescendantOf:close]);
        [close performClick:nil];
        assert(delegate.closeRequested);
        assert(renderer.layer == metal);
        assert(graffitty_desktop_blur(handle, true, 40, 0));
        [first setContentSize:NSMakeSize(600, 400)];
        assert(NSEqualSizes(renderer.frame.size, NSMakeSize(600, 400)));
        assert(graffitty_desktop_blur(handle, false, 0, 0));
        assert(first.contentView == renderer && renderer.layer == metal);
        assert(graffitty_desktop_blur(handle, true, 0, 0));
        printf("Reduce transparency: %s\n",
               NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency
                   ? "enabled"
                   : "disabled");
        puts("DESKTOP_BLUR_NATIVE_PASS");
    }
}
