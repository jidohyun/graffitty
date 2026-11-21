#pragma once
#include <string>
#include "include/cef_browser.h"

// One CEF distribution contains both styles. The embedding host chooses when
// creating each browser; no separate Chromium compilation is necessary.
enum class ChromiumBackend { Alloy, Chrome };
static ChromiumBackend backend = ChromiumBackend::Chrome;
static bool alloy() { return backend == ChromiumBackend::Alloy; }
static const char *backendName() { return alloy() ? "alloy" : "chrome"; }
static bool parseBackend(const std::string &name) {
    if (name == "alloy") backend = ChromiumBackend::Alloy;
    else if (name == "chrome") backend = ChromiumBackend::Chrome;
    else return false;
    return true;
}
#ifdef _WIN32
static bool softwareCapture = false;
#endif
static void configureBrowser(CefWindowInfo &info, CefBrowserSettings &settings) {
    settings.windowless_frame_rate = 60;
    // Browser panes are opaque. CEF otherwise enables transparent painting
    // for Alloy's windowless pages, including newly created tabs and popups.
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);
    if (alloy()) {
        info.SetAsWindowless(0);
#ifdef _WIN32
        info.shared_texture_enabled = !softwareCapture;
#else
        info.shared_texture_enabled = true;
#endif
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    } else info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
}
static void zoomAlloy(CefRefPtr<CefBrowser> browser, int direction) {
    auto host = browser->GetHost();
    host->SetZoomLevel(direction ? host->GetZoomLevel() + direction : 0);
}
