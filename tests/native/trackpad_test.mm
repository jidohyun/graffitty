#import <AppKit/AppKit.h>
#include <cassert>
#include <cmath>
#include <vector>
extern "C" void graffitty_install_trackpad();
struct Packet { double px, py, cx, cy, factor; };
static std::vector<Packet> packets;
static int scrolls = 0;
extern "C" void graffitty_trackpad_event(void *, double, double, double, double,
    double px, double py, double cx, double cy, double factor) {
    packets.push_back({px, py, cx, cy, factor});
}
// This fixture exercises pinch routing; ordinary scrolling stays with Godot.
extern "C" bool graffitty_pan_event(void *, double, double, double, double,
    double, double, uint64_t, uint64_t, uint64_t, double) { return false; }
@interface GodotContentView : NSView
@end
@implementation GodotContentView
- (void)magnifyWithEvent:(NSEvent *)event { assert(false && "Native bridge owns magnification"); }
- (void)scrollWheel:(NSEvent *)event { scrolls++; }
@end
@interface TestTouch : NSTouch
@property NSPoint point;
@end
@implementation TestTouch
- (NSPoint)normalizedPosition { return self.point; }
- (NSSize)deviceSize { return NSMakeSize(100, 100); }
@end
@interface TestGesture : NSEvent
@property NSSet<NSTouch *> *points;
@property NSEventPhase testPhase;
@property CGFloat amount;
@property BOOL forbidTouches;
@end
@implementation TestGesture
- (NSSet<NSTouch *> *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view {
    assert(!self.forbidTouches && "Magnify callbacks must never query raw touches");
    return self.points;
}
- (NSPoint)locationInWindow { return NSMakePoint(100, 100); }
- (NSEventPhase)phase { return self.testPhase; }
- (CGFloat)magnification { return self.amount; }
@end
int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        GodotContentView *view = [[GodotContentView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        window.contentView = view;
        assert(!window.isKeyWindow); // Direct callbacks do not establish native event delivery.
        graffitty_install_trackpad();
        graffitty_install_trackpad(); // Installing for another terminal must be idempotent.
        TestTouch *a = [TestTouch new], *b = [TestTouch new];
        a.point = NSMakePoint(.2, .4); b.point = NSMakePoint(.6, .4);
        TestGesture *event = [TestGesture new];
        event.points = [NSSet setWithObjects:a, b, nil];
        [view scrollWheel:event]; assert(scrolls == 1);
        [view touchesBeganWithEvent:event];
        event.testPhase = NSEventPhaseBegan; event.amount = .2;
        event.forbidTouches = YES;
        [view magnifyWithEvent:event];
        event.forbidTouches = NO;
        assert(packets.size() == 1 && std::abs(packets.back().factor - 1.2) < 1e-6);
        // An asymmetric expansion has centroid motion but no shared pan.
        b.point = NSMakePoint(.7, .4);
        [view touchesMovedWithEvent:event]; assert(packets.size() == 1);
        b.point = NSMakePoint(.6, .4);
        [view touchesMovedWithEvent:event]; assert(packets.size() == 1);
        a.point = NSMakePoint(.3, .5); b.point = NSMakePoint(.7, .5);
        [view touchesMovedWithEvent:event];
        assert(packets.size() == 2);
        // Ten trackpad points translate sixty view points in both axes.
        assert(std::abs(packets.back().cx - packets.back().px - 60) < 1e-6);
        assert(std::abs(packets.back().cy - packets.back().py + 60) < 1e-6);
        [view scrollWheel:event]; assert(scrolls == 1); // No doubled pan.
        event.testPhase = NSEventPhaseEnded; event.amount = 0;
        event.forbidTouches = YES;
        [view magnifyWithEvent:event];
        event.forbidTouches = NO;
        [view scrollWheel:event]; assert(scrolls == 1);
        // Pan continues after native magnification ends, at the same anchor.
        a.point = NSMakePoint(.4, .6); b.point = NSMakePoint(.8, .6);
        [view touchesMovedWithEvent:event];
        assert(packets.size() == 3);
        assert(std::abs(packets.back().cx - packets.back().px - 60) < 1e-6);
        assert(std::abs(packets.back().cy - packets.back().py + 60) < 1e-6);
        auto center = packets.back();
        event.testPhase = NSEventPhaseBegan; event.amount = .1;
        event.forbidTouches = YES;
        [view magnifyWithEvent:event];
        event.forbidTouches = NO;
        assert(packets.back().cx == center.cx && packets.back().cy == center.cy);
        // Lifting one finger restores ordinary scrolling immediately.
        event.points = [NSSet setWithObject:a];
        [view touchesEndedWithEvent:event];
        [view scrollWheel:event]; assert(scrolls == 2);
        auto released = packets.size();
        event.testPhase = NSEventPhaseEnded; event.amount = 0;
        [view magnifyWithEvent:event];
        assert(packets.size() == released);
        [view scrollWheel:event]; assert(scrolls == 3);
        // Native-only devices must not leave scrolling suppressed on gesture end.
        event.testPhase = NSEventPhaseBegan; event.amount = .1;
        event.forbidTouches = YES;
        [view magnifyWithEvent:event];
        event.testPhase = NSEventPhaseEnded; event.amount = 0;
        [view magnifyWithEvent:event];
        event.forbidTouches = NO;
        [view scrollWheel:event]; assert(scrolls == 4);
        event.points = [NSSet setWithObjects:a, b, nil];
        [view touchesBeganWithEvent:event];
        event.testPhase = NSEventPhaseBegan; event.amount = .1;
        [view magnifyWithEvent:event];
        auto count = packets.size();
        [view touchesCancelledWithEvent:event];
        [view scrollWheel:event]; assert(scrolls == 5);
        a.point = NSMakePoint(.5, .7); b.point = NSMakePoint(.9, .7);
        [view touchesMovedWithEvent:event]; assert(packets.size() == count);
        assert(!window.isKeyWindow); // Native handlers must not activate their window.
        puts("PASS native Mac touch-only sampling, continuous pan, anchor retention, lift, native-only zoom, and cancellation");
    }
}
