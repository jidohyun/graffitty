// clang++ -std=c++20 tests/native/chromium_wheel_test.mm -framework CoreGraphics -framework CoreFoundation -o /tmp/chromium-wheel-test && /tmp/chromium-wheel-test
#include "../../apps/server/chromium/wheel_event_mac.h"
#include <cassert>
#include <cstdio>

static void sent(int32_t dx, int32_t dy) {
    CGEventRef event = createChromiumWheelCGEvent(dx, dy);
    assert(event);
    // Chromium reads the underlying CGEvent's integer point deltas.
    assert(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1) == dy);
    assert(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2) == dx);
    assert(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis3) == 0);
    assert(CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous) == 1);
    CFRelease(event);
}

int main() {
    const double deltas[] = {0, .01, -.01, .1, -.1, .5, -.5, 1.25, -1.25, 20, -20, 120, -120};
    int checks = 0;
    for (double dx : deltas) {
        for (double dy : deltas) {
            // A sequence of identical events delivers its whole fractional
            // travel, never more than half a pixel behind, on both axes.
            WheelDeltaCarry carry;
            int64_t totalX = 0, totalY = 0;
            for (int n = 1; n <= 40; ++n, ++checks) {
                int32_t x, y;
                carry.take(dx, dy, &x, &y);
                sent(x, y);
                totalX += x;
                totalY += y;
                assert(std::fabs(dx * n - totalX) <= .5 + 1e-9);
                assert(std::fabs(dy * n - totalY) <= .5 + 1e-9);
            }
        }
    }
    // A slow drag below one pixel per event must still move the page.
    WheelDeltaCarry slow;
    int32_t moved = 0;
    for (int n = 0; n < 10; ++n) {
        int32_t x, y;
        slow.take(0, .4, &x, &y);
        moved += y;
    }
    assert(moved == 4);
    slow.reset();
    assert(slow.x == 0 && slow.y == 0);
    WheelDeltaCarry invalid;
    int32_t x, y;
    invalid.take(NAN, INFINITY, &x, &y);
    assert(x == 0 && y == 0);
    printf("PASS chromium wheel CGEvent: %d carried fractional, vertical, horizontal and diagonal inputs\n", checks);
}
