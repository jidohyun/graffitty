#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cmath>
#include <cstdint>

// Chromium reads a continuous wheel's distance from the CGEvent's integer
// point deltas, not NSEvent's fractional scrollingDelta. AppKit carries the
// sub-pixel remainder from one trackpad event to the next.
//
// Do the same: truncating each event drops most of a slow drag, which is
// exactly how a finger moves while stretching the page at its edge.
struct WheelDeltaCarry {
    double x = 0, y = 0;
    void reset() { x = y = 0; }
    // Whole pixels to send now; the remainder stays within half a pixel.
    void take(double dx, double dy, int32_t *outX, int32_t *outY) {
        auto step = [](double &carry, double delta) {
            carry += std::isfinite(delta) ? delta : 0;
            const double whole = std::round(carry);
            carry -= whole;
            return static_cast<int32_t>(std::clamp(whole, -1e6, 1e6));
        };
        *outX = step(x, dx);
        *outY = step(y, dy);
    }
};

static CGEventRef createChromiumWheelCGEvent(int32_t dx, int32_t dy) {
    // Never pass a double through CGEventCreateScrollWheelEvent's varargs:
    // wheel2 is read as int32_t, turning fractional X noise into huge motion.
    // The typed API keeps both axes in pixels.
    return CGEventCreateScrollWheelEvent2(nullptr, kCGScrollEventUnitPixel, 2, dy, dx, 0);
}
