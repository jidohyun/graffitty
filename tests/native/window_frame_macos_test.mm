#import <AppKit/AppKit.h>
#include <cassert>
#include <cmath>
#include <cstdio>

extern "C" void graffitty_install_window_frame();
extern "C" void graffitty_window_fullscreen_content(uint64_t handle);

// Exercise real AppKit widgets without activating or closing a desktop window.
@interface ChromeTestWindow : NSWindow
@property BOOL reportedFullscreen;
@property NSUInteger closes;
@property NSUInteger minimizes;
@property NSUInteger zooms;
@end
@implementation ChromeTestWindow
- (NSWindowStyleMask)styleMask {
    return [super styleMask] | (self.reportedFullscreen ? NSWindowStyleMaskFullScreen : 0);
}
- (BOOL)isKeyWindow {
    return YES;
}
- (void)performClose:(id)sender {
    self.closes++;
}
- (void)performMiniaturize:(id)sender {
    self.minimizes++;
}
- (void)performZoom:(id)sender {
    self.zooms++;
}
@end

// The Godot container's contract: shared hover state and drawing invalidation.
@interface GodotButtonView : NSView
@property BOOL hovered;
- (BOOL)_mouseInGroup:(NSButton *)button;
- (void)displayButtons;
@end
@implementation GodotButtonView
- (BOOL)_mouseInGroup:(NSButton *)button {
    return self.hovered;
}
- (void)displayButtons {
    for (NSView *button in self.subviews)
        [button setNeedsDisplay:YES];
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    [self displayButtons];
}
- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    [self displayButtons];
}
@end

static NSBitmapImageRep *snapshot(NSView *view) {
    NSBitmapImageRep *image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
    return image;
}

static unsigned changed_pixels(NSBitmapImageRep *before, NSBitmapImageRep *after, NSRect frame,
                               NSSize bounds) {
    unsigned count = 0;
    double sx = before.pixelsWide / bounds.width, sy = before.pixelsHigh / bounds.height;
    for (int y = frame.origin.y * sy; y < NSMaxY(frame) * sy; y++) {
        for (int x = frame.origin.x * sx; x < NSMaxX(frame) * sx; x++) {
            NSColor *a = [[before colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            NSColor *b = [[after colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (std::abs(a.redComponent - b.redComponent) +
                    std::abs(a.greenComponent - b.greenComponent) +
                    std::abs(a.blueComponent - b.blueComponent) >
                0.1)
                count++;
        }
    }
    return count;
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        ChromeTestWindow *window = [[ChromeTestWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 300, 100)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        GodotButtonView *group = [[GodotButtonView alloc] initWithFrame:NSMakeRect(10, 10, 60, 14)];
        [window.contentView addSubview:group];
        NSWindowButton kinds[] = {NSWindowCloseButton, NSWindowMiniaturizeButton,
                                  NSWindowZoomButton};
        SEL actions[] = {@selector(performClose:), @selector(performMiniaturize:),
                         @selector(performZoom:)};
        for (int i = 0; i < 3; i++) {
            NSButton *button = [NSWindow standardWindowButton:kinds[i]
                                                 forStyleMask:NSWindowStyleMaskTitled];
            button.frameOrigin = NSMakePoint(23 * i, 0);
            button.target = window;
            button.action = actions[i];
            [group addSubview:button];
        }
        graffitty_install_window_frame();
        graffitty_install_window_frame(); // Each extension setup must remain idempotent.
        NSBitmapImageRep *resting = snapshot(group);
        for (NSButton *hovered in group.subviews) {
            NSEvent *event =
                [NSEvent enterExitEventWithType:NSEventTypeMouseEntered
                                       location:[group convertPoint:hovered.frame.origin toView:nil]
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:window.windowNumber
                                        context:nil
                                    eventNumber:0
                                 trackingNumber:0
                                       userData:nullptr];
            [group mouseEntered:event];
            NSBitmapImageRep *inside = snapshot(group);
            for (NSButton *button in group.subviews) {
                assert(changed_pixels(resting, inside, button.frame, group.bounds.size) > 5);
                assert(!button.highlighted); // Hover must never imitate a pressed button.
            }
            [group mouseExited:event];
            NSBitmapImageRep *outside = snapshot(group);
            assert(changed_pixels(resting, outside, group.bounds, group.bounds.size) == 0);
        }
        for (NSButton *button in group.subviews)
            [button performClick:nil];
        assert(window.closes == 1 && window.minimizes == 1 && window.zooms == 1);
        // Reproduce Godot's opaque titlebar reset at fullscreen entry. The
        // fix must affect fullscreen only and preserve the windowed chrome.
        uint64_t handle = (uint64_t)(__bridge void *)window;
        window.titleVisibility = NSWindowTitleVisible;
        window.titlebarAppearsTransparent = NO;
        graffitty_window_fullscreen_content(handle);
        assert(window.titleVisibility == NSWindowTitleVisible);
        assert(!window.titlebarAppearsTransparent);
        window.styleMask |= NSWindowStyleMaskFullSizeContentView;
        window.reportedFullscreen = YES;
        graffitty_window_fullscreen_content(handle);
        assert(window.titleVisibility == NSWindowTitleHidden);
        assert(window.titlebarAppearsTransparent);
        assert(window.styleMask & NSWindowStyleMaskFullSizeContentView);
        window.reportedFullscreen = NO;
        puts("PASS fullscreen removes opaque native titlebar without changing windowed chrome");
        puts(
            "PASS native traffic lights show all hover symbols, clear on exit, and retain actions");
    }
}
