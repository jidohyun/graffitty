#include "../../apps/server/chromium/linux_display_platform.h"
#include <cassert>

int main() {
    using graffitty::linux_display_platform;
    assert(linux_display_platform(nullptr, nullptr, nullptr, nullptr) == "headless");
    assert(linux_display_platform(nullptr, "", "", "") == "headless");
    assert(linux_display_platform(nullptr, "wayland-0", nullptr, ":1") == "wayland");
    assert(linux_display_platform(nullptr, nullptr, "7", nullptr) == "wayland");
    assert(linux_display_platform("x11", "wayland-0", "7", nullptr) == "x11");
    assert(linux_display_platform("wayland", nullptr, nullptr, nullptr) == "wayland");
    assert(linux_display_platform(nullptr, nullptr, nullptr, ":1") == "x11");
    assert(linux_display_platform("headless", "wayland-0", nullptr, ":1") == "headless");
    assert(!linux_display_platform("auto", "wayland-0", nullptr, nullptr));
    assert(!linux_display_platform("invalid", nullptr, nullptr, nullptr));
}
