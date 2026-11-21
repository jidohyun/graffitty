#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <algorithm>
#include <cmath>

// AppKit's magnification event omits centroid motion from Godot's gesture.
// Keep ordinary two-finger scrolling unchanged; direct panning starts only
// once AppKit recognizes a pinch and continues until the two-touch sequence ends.
extern "C" void graffitty_trackpad_event(void *window, double width, double height,
    double x, double y, double px, double py, double cx, double cy, double factor);
extern "C" bool graffitty_pan_event(void *window, double width, double height,
    double x, double y, double dx, double dy, uint64_t phase, uint64_t momentum, uint64_t flags, double time);

@interface GraffittyPinch : NSObject
@property BOOL tracking;
@property BOOL active;
@property NSRect touchBounds;
@property NSPoint anchor;
@property NSPoint center;
@end
@implementation GraffittyPinch
@end
static char pinch_key;
// Indirect trackpad movement needs more travel than direct touchscreen input.
// Apply gain before accumulating the anchor so pan and native zoom stay aligned.
static constexpr double pinch_pan_gain = 6.0;
using Handler = void (*)(id, SEL, NSEvent *);
static Handler original_magnify, original_scroll, original_moved, original_began, original_ended, original_cancelled;
using PanHandler = void (*)(id, SEL, NSEvent *, double, double);
static PanHandler original_pan;
static GraffittyPinch *state(NSView *view) {
    GraffittyPinch *s = objc_getAssociatedObject(view, &pinch_key);
    if (!s) {
        s = [GraffittyPinch new];
        objc_setAssociatedObject(view, &pinch_key, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}
static void emit(NSView *view, GraffittyPinch *s, NSPoint previous, double factor) {
    if (!view.window || view.bounds.size.width <= 0 || view.bounds.size.height <= 0) return;
    graffitty_trackpad_event((__bridge void *)view.window, view.bounds.size.width, view.bounds.size.height,
        s.anchor.x, s.anchor.y, previous.x, previous.y, s.center.x, s.center.y, factor);
}
static void track(NSView *view, NSEvent *event) {
    GraffittyPinch *s = state(view);
    NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseTouching inView:view];
    if (touches.count != 2) { s.tracking = NO; s.active = NO; return; }
    NSPoint lo = NSMakePoint(INFINITY, INFINITY), hi = NSMakePoint(-INFINITY, -INFINITY);
    for (NSTouch *touch in touches) {
        NSPoint p = NSMakePoint(touch.normalizedPosition.x * touch.deviceSize.width,
            -touch.normalizedPosition.y * touch.deviceSize.height);
        lo.x = std::min(lo.x, p.x); lo.y = std::min(lo.y, p.y);
        hi.x = std::max(hi.x, p.x); hi.y = std::max(hi.y, p.y);
    }
    if (s.tracking && s.active) {
        // Pan only the motion shared by both fingers on each axis. A stationary
        // finger plus an expanding pinch must not drag the cursor's zoom anchor.
        auto shared = [](double a, double b) {
            return a * b > 0 ? std::copysign(std::min(std::abs(a), std::abs(b)), a) : 0.0;
        };
        NSPoint previous = s.center;
        s.center = NSMakePoint(previous.x + shared(lo.x - NSMinX(s.touchBounds), hi.x - NSMaxX(s.touchBounds)) * pinch_pan_gain,
            previous.y + shared(lo.y - NSMinY(s.touchBounds), hi.y - NSMaxY(s.touchBounds)) * pinch_pan_gain);
        if (!NSEqualPoints(previous, s.center)) emit(view, s, previous, 1.0);
    }
    s.touchBounds = NSMakeRect(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y);
    s.tracking = YES;
}
static void magnify(id obj, SEL, NSEvent *event) {
    NSView *view = obj;
    GraffittyPinch *s = state(view);
    const bool finishing = event.phase & (NSEventPhaseEnded | NSEventPhaseCancelled);
    // A trailing gesture-end event must not start another interaction after
    // touchesEnded has already released the fingers.
    if (!s.active && finishing) return;
    if (!s.active) {
        NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
        if (!view.isFlipped) p.y = view.bounds.size.height - p.y;
        s.anchor = p;
        s.center = p;
        s.active = YES;
    }
    // AppKit only guarantees current NSTouch positions in touch callbacks.
    // Reading them here can rewind the centroid to an older touch sample.
    if (event.magnification != 0.0) emit(view, s, s.center, 1.0 + event.magnification);
    // Magnification can finish before the fingers lift. Retain the same pan
    // anchor through that transition, including a subsequent magnify gesture.
    // Devices without raw touches still use the native gesture lifecycle.
    if ((event.phase & NSEventPhaseCancelled) || (finishing && !s.tracking)) s.active = NO;
}
static void scroll(id obj, SEL sel, NSEvent *event) {
    if (!state(obj).active) original_scroll(obj, sel, event);
}
// Godot's pan gesture drops AppKit's phases and event time.
//
// Chromium needs the phases to tell finger travel from momentum, and the time
// for the release velocity of its rubber band; emit the same gesture with
// both attached.
static void pan(id obj, SEL sel, NSEvent *event, double dx, double dy) {
    NSView *view = obj;
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    if (!view.isFlipped) p.y = view.bounds.size.height - p.y;
    if (!view.window || view.bounds.size.width <= 0 || view.bounds.size.height <= 0
        || !graffitty_pan_event((__bridge void *)view.window, view.bounds.size.width, view.bounds.size.height,
            p.x, p.y, -dx, -dy, event.phase, event.momentumPhase, event.modifierFlags, event.timestamp))
        original_pan(obj, sel, event, dx, dy);
}
static void began(id obj, SEL sel, NSEvent *event) { track(obj, event); original_began(obj, sel, event); }
static void moved(id obj, SEL sel, NSEvent *event) { track(obj, event); original_moved(obj, sel, event); }
static void ended(id obj, SEL sel, NSEvent *event) { track(obj, event); original_ended(obj, sel, event); }
static void cancelled(id obj, SEL sel, NSEvent *event) { state(obj).active = NO; state(obj).tracking = NO; original_cancelled(obj, sel, event); }
template <typename F> static void replace(Class cls, SEL sel, F replacement, F *original) {
    Method method = class_getInstanceMethod(cls, sel);
    // Godot's private pan helper may be renamed; its gesture then stays stock.
    if (!method) return;
    *original = (F)method_getImplementation(method);
    // Override inherited NSResponder handlers on Godot's class only.
    if (!class_addMethod(cls, sel, (IMP)replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)replacement);
}
static void enable(NSView *view, Class cls) {
    if ([view isKindOfClass:cls]) view.allowedTouchTypes |= NSTouchTypeMaskIndirect;
    for (NSView *child in view.subviews) enable(child, cls);
}
extern "C" void graffitty_install_trackpad() {
    Class cls = objc_getClass("GodotContentView");
    if (!cls) return;
    static bool installed = false;
    if (!installed) {
        replace(cls, @selector(magnifyWithEvent:), magnify, &original_magnify);
        replace(cls, @selector(scrollWheel:), scroll, &original_scroll);
        replace(cls, @selector(processPanEvent:dx:dy:), pan, &original_pan);
        replace(cls, @selector(touchesBeganWithEvent:), began, &original_began);
        replace(cls, @selector(touchesMovedWithEvent:), moved, &original_moved);
        replace(cls, @selector(touchesEndedWithEvent:), ended, &original_ended);
        replace(cls, @selector(touchesCancelledWithEvent:), cancelled, &original_cancelled);
        installed = true;
    }
    for (NSWindow *window in NSApp.windows) enable(window.contentView, cls);
}
