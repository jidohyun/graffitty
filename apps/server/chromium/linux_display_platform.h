#pragma once

#include <cstdlib>
#include <optional>
#include <string_view>

namespace graffitty {
// An explicit choice wins, including XWayland on a Wayland desktop. Never
// silently fall back if a requested compositor cannot be reached.
inline std::optional<std::string_view> linux_display_platform(
    const char* requested, const char* wayland_display, const char* wayland_socket,
    const char* x_display) {
    if (requested && *requested) {
        std::string_view platform(requested);
        if (platform == "x11" || platform == "wayland" || platform == "headless") return platform;
        return std::nullopt;
    }
    if ((wayland_display && *wayland_display) || (wayland_socket && *wayland_socket))
        return "wayland";
    return (x_display && *x_display) ? "x11" : "headless";
}
}
