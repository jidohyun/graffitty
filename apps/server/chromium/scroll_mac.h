// Use native scrollWheel to group wheel events and let Chromium finish
// the bounce when the sequence goes idle. CDP dispatchMouseEvent ends
// each event immediately.
//
// Use window-local coordinates and deliver directly to the view.
#include "wheel_event_mac.h"
@interface EmbeddedWheelEvent : NSEvent
@property(nonatomic, strong) NSEvent *source;
@property(nonatomic, weak) NSWindow *targetWindow;
@property(nonatomic) NSPoint point;
@property(nonatomic) CGFloat dx, dy;
@property(nonatomic) NSEventPhase gesturePhase, momentum;
@property(nonatomic) NSTimeInterval time;
@end
@implementation EmbeddedWheelEvent
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (NSWindow *)window { return self.targetWindow; }
- (NSInteger)windowNumber { return self.targetWindow.windowNumber; }
- (NSPoint)locationInWindow { return self.point; }
- (NSTimeInterval)timestamp { return self.time; }
- (NSEventModifierFlags)modifierFlags { return self.source.modifierFlags; }
- (CGFloat)deltaX { return self.dx / 40.0; }
- (CGFloat)deltaY { return self.dy / 40.0; }
- (CGFloat)deltaZ { return 0; }
- (CGFloat)scrollingDeltaX { return self.dx; }
- (CGFloat)scrollingDeltaY { return self.dy; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (NSEventPhase)phase { return self.gesturePhase; }
- (NSEventPhase)momentumPhase { return self.momentum; }
- (CGEventRef)CGEvent { return self.source.CGEvent; }
@end
static NSView *scrollView(NSView *view) {
    // Chrome also hosts tiny WebContents in toolbar controls. Find the content
    // view, not the first RenderWidgetHostViewCocoa in the native hierarchy.
    NSView *best = [NSStringFromClass(view.class) containsString:@"RenderWidgetHostViewCocoa"] ? view : nil;
    for (NSView *child in view.subviews) {
        NSView *found = scrollView(child);
        if (found && (!best || found.bounds.size.width * found.bounds.size.height > best.bounds.size.width * best.bounds.size.height)) best = found;
    }
    return best;
}
static double wheelNumber(CefRefPtr<CefDictionaryValue> p, const char *key) {
    return p->GetType(key) == VTYPE_INT ? p->GetInt(key) : p->GetDouble(key);
}
// Trackpad clients forward AppKit's own finger and momentum phases. Chromium
// stretches only under the fingers and turns momentum into a short bounce.
static NSEventPhase wheelPhase(CefRefPtr<CefDictionaryValue> p, const char *key) {
    const std::string name = p->GetString(key).ToString();
    if (name == "may_begin") return NSEventPhaseMayBegin;
    if (name == "began") return NSEventPhaseBegan;
    if (name == "changed") return NSEventPhaseChanged;
    if (name == "ended") return NSEventPhaseEnded;
    if (name == "cancelled") return NSEventPhaseCancelled;
    return NSEventPhaseNone;
}
static int64_t scrollPhaseField(NSEventPhase phase) {
    switch (phase) {
        case NSEventPhaseMayBegin: return kCGScrollPhaseMayBegin;
        case NSEventPhaseBegan: return kCGScrollPhaseBegan;
        case NSEventPhaseChanged: return kCGScrollPhaseChanged;
        case NSEventPhaseEnded: return kCGScrollPhaseEnded;
        case NSEventPhaseCancelled: return kCGScrollPhaseCancelled;
        default: return 0;
    }
}
static int64_t momentumPhaseField(NSEventPhase phase) {
    switch (phase) {
        case NSEventPhaseBegan: return kCGMomentumScrollPhaseBegin;
        case NSEventPhaseChanged: return kCGMomentumScrollPhaseContinue;
        case NSEventPhaseEnded: case NSEventPhaseCancelled: return kCGMomentumScrollPhaseEnd;
        default: return kCGMomentumScrollPhaseNone;
    }
}
// Fractional pixels not yet delivered in the current phase sequence.
static WheelDeltaCarry wheelCarry;
// Deltas are native: positive scrolls toward the top/left, in view points.
// time is in this host's system uptime, like NSEvent timestamps.
static bool sendWheel(NSView *view, NSPoint point, double dx, double dy, NSEventPhase phase, NSEventPhase momentum,
                      CGEventFlags flags, NSTimeInterval time) {
    int32_t wholeX, wholeY;
    wheelCarry.take(dx, dy, &wholeX, &wholeY);
    CGEventRef cg = createChromiumWheelCGEvent(wholeX, wholeY);
    if (!cg) return false;
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventScrollPhase, scrollPhaseField(phase));
    CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, momentumPhaseField(momentum));
    CGEventSetFlags(cg, flags);
    EmbeddedWheelEvent *event = [EmbeddedWheelEvent new];
    event.source = [NSEvent eventWithCGEvent:cg];
    event.targetWindow = view.window;
    event.point = point;
    event.dx = dx;
    event.dy = dy;
    event.gesturePhase = phase;
    event.momentum = momentum;
    event.time = time;
    [view scrollWheel:event];
    CFRelease(cg);
    return true;
}
// What Chromium believes is in progress, so a lost or interrupted sequence can
// still be finished instead of leaving the page stretched.
static __weak NSView *wheelGestureView;
static NSPoint wheelGesturePoint;
static bool wheelFinger = false, wheelMomentum = false;
static uint64_t wheelGestureSerial = 0;
// Chromium derives the release velocity, and so the bounce, from the spacing
// of event timestamps.
//
// Arrival time on this host adds transport jitter: two events landing
// together read as a fling, a delayed one as a stop.
//
// Keep the spacing of the client's eventTime (seconds on any monotonic client
// clock), mapped onto this host's clock once per sequence.
static NSTimeInterval wheelClockOffset = 0;
static bool wheelClockAnchored = false;
// Never let a late, queued event begin an animation far in the past.
static constexpr NSTimeInterval wheelMaximumLag = 0.1;
static NSTimeInterval wheelEventTime(CefRefPtr<CefDictionaryValue> params) {
    const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    const auto type = params->GetType("eventTime");
    if (type != VTYPE_INT && type != VTYPE_DOUBLE) return now;
    const double client = wheelNumber(params, "eventTime");
    if (!std::isfinite(client)) return now;
    NSTimeInterval time = client + wheelClockOffset;
    if (!wheelClockAnchored || time > now || now - time > wheelMaximumLag) {
        wheelClockOffset = now - client;
        wheelClockAnchored = true;
        time = now;
    }
    return time;
}
static void endWheelGesture() {
    NSView *view = wheelGestureView;
    const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (view && wheelFinger) sendWheel(view, wheelGesturePoint, 0, 0, NSEventPhaseEnded, NSEventPhaseNone, 0, now);
    if (view && wheelMomentum) sendWheel(view, wheelGesturePoint, 0, 0, NSEventPhaseNone, NSEventPhaseEnded, 0, now);
    wheelGestureView = nil;
    wheelFinger = wheelMomentum = false;
    wheelCarry.reset();
    wheelClockAnchored = false;
}
// Parameters are CSS pixels; positions use the view's render scale. Deltas do
// not: the compositor scrolls the emulated page by the raw delta in CSS pixels.
static bool nativeChromiumWheel(CefRefPtr<CefBrowser> chromium, CefRefPtr<CefDictionaryValue> params, double scale) {
    if (!chromium || !params || params->GetString("type") != "mouseWheel") return false;
    NSView *view = scrollView(windowFor(chromium).contentView);
    if (!view) return false;
    const double dx = wheelNumber(params, "deltaX"), dy = wheelNumber(params, "deltaY");
    NSEventPhase phase = wheelPhase(params, "phase"), momentum = wheelPhase(params, "momentumPhase");
    // Discrete wheels and touch scrolling carry no phase: Chromium's synthetic
    // phase handler groups them, and they never overscroll.
    if (wheelGestureView != view || (phase == NSEventPhaseNone && momentum == NSEventPhaseNone)) endWheelGesture();
    if (!wheelGestureView) wheelClockAnchored = false; // A new sequence.
    const NSTimeInterval time = wheelEventTime(params);
    NSPoint local = NSMakePoint(wheelNumber(params, "x") * scale, wheelNumber(params, "y") * scale);
    if (!view.isFlipped) local.y = view.bounds.size.height - local.y;
    const NSPoint point = [view convertPoint:local toView:nil];
    if (phase != NSEventPhaseNone) {
        if ((phase == NSEventPhaseEnded || phase == NSEventPhaseCancelled) && !wheelFinger) return true;
        if (phase == NSEventPhaseChanged && !wheelFinger) phase = NSEventPhaseBegan;
        // Touching the trackpad stops momentum before the next finger sequence.
        if (phase != NSEventPhaseEnded && phase != NSEventPhaseCancelled && wheelMomentum) {
            sendWheel(view, point, 0, 0, NSEventPhaseNone, NSEventPhaseEnded, 0, time);
            wheelMomentum = false;
        }
        if (phase == NSEventPhaseBegan || phase == NSEventPhaseMayBegin) wheelCarry.reset();
        wheelFinger = phase != NSEventPhaseEnded && phase != NSEventPhaseCancelled;
    } else if (momentum != NSEventPhaseNone) {
        if ((momentum == NSEventPhaseEnded || momentum == NSEventPhaseCancelled) && !wheelMomentum) return true;
        // Momentum always follows the fingers' release.
        if (wheelFinger) {
            sendWheel(view, point, 0, 0, NSEventPhaseEnded, NSEventPhaseNone, 0, time);
            wheelFinger = false;
        }
        if (momentum == NSEventPhaseChanged && !wheelMomentum) momentum = NSEventPhaseBegan;
        if (momentum == NSEventPhaseBegan) wheelCarry.reset();
        // Chromium releases the fingers' scroll target 100 ms after their end
        // unless momentum has begun, and then drops the momentum. Touching
        // again re-targets it, whichever side of that window this lands on.
        if (momentum == NSEventPhaseBegan) sendWheel(view, point, 0, 0, NSEventPhaseMayBegin, NSEventPhaseNone, 0, time);
        wheelMomentum = momentum != NSEventPhaseEnded && momentum != NSEventPhaseCancelled;
    }
    int modifiers = params->GetInt("modifiers");
    const CGEventFlags flags = ((modifiers & 1) ? kCGEventFlagMaskAlternate : 0) |
                               ((modifiers & 2) ? kCGEventFlagMaskControl : 0) |
                               ((modifiers & 4) ? kCGEventFlagMaskCommand : 0) |
                               ((modifiers & 8) ? kCGEventFlagMaskShift : 0);
    if (!sendWheel(view, point, -dx, -dy, phase, momentum, flags, time)) return false;
    const auto serial = ++wheelGestureSerial;
    wheelGestureView = wheelFinger || wheelMomentum ? view : nil;
    wheelGesturePoint = point;
    // Real sequences end themselves; this only covers an end that never arrives.
    if (wheelGestureView) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (serial == wheelGestureSerial) endWheelGesture();
    });
    return true;
}

// Alloy has no native view for phased AppKit events. CDP treats each wheel
// sample as a separate scroll, restarting the rubber band. Samples below
// Chromium's 10 px threshold are ignored, so the page twitches.
//
// CEF's windowless wheel groups trackpad samples into one scroll. Its
// synthetic phases stop the page at the edge, as on Windows and Linux.
static WheelDeltaCarry windowlessWheelCarry;
static bool windowlessChromiumWheel(CefRefPtr<CefBrowser> chromium, CefRefPtr<CefDictionaryValue> params, double scale) {
    if (!chromium || !params || params->GetString("type") != "mouseWheel") return false;
    const NSEventPhase phase = wheelPhase(params, "phase"), momentum = wheelPhase(params, "momentumPhase");
    // Each trackpad sequence starts whole; unphased wheels move whole pixels.
    if (phase == NSEventPhaseBegan || phase == NSEventPhaseMayBegin || momentum == NSEventPhaseBegan ||
        (phase == NSEventPhaseNone && momentum == NSEventPhaseNone))
        windowlessWheelCarry.reset();
    int32_t dx, dy;
    windowlessWheelCarry.take(wheelNumber(params, "deltaX"), wheelNumber(params, "deltaY"), &dx, &dy);
    // Lifting the fingers or ending momentum only reports the phase.
    if (dx == 0 && dy == 0) return true;
    CefMouseEvent event;
    event.x = static_cast<int>(std::lround(wheelNumber(params, "x") * scale));
    event.y = static_cast<int>(std::lround(wheelNumber(params, "y") * scale));
    const int modifiers = params->GetInt("modifiers");
    event.modifiers = ((modifiers & 1) ? EVENTFLAG_ALT_DOWN : 0) | ((modifiers & 2) ? EVENTFLAG_CONTROL_DOWN : 0) |
                      ((modifiers & 4) ? EVENTFLAG_COMMAND_DOWN : 0) | ((modifiers & 8) ? EVENTFLAG_SHIFT_DOWN : 0);
    // CDP deltas scroll the page by their sign; CEF's are wheel deltas.
    chromium->GetHost()->SendMouseWheelEvent(event, -dx, -dy);
    return true;
}
