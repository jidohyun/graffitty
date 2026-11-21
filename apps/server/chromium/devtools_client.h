// DevTools is a native auxiliary window, never a captured workspace page.
#pragma once

#include <algorithm>
#include <vector>
#include "include/cef_client.h"

static std::vector<CefRefPtr<CefBrowser>> devToolsBrowsers;
static unsigned pendingDevTools = 0;
static inline bool devToolsOpen() { return pendingDevTools || !devToolsBrowsers.empty(); }

class NativeDevToolsClient final : public CefClient, public CefLifeSpanHandler {
  public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        if (pendingDevTools) --pendingDevTools;
        devToolsBrowsers.push_back(browser);
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        devToolsBrowsers.erase(std::remove_if(devToolsBrowsers.begin(), devToolsBrowsers.end(),
            [&](auto &item) { return item->IsSame(browser); }), devToolsBrowsers.end());
    }
    IMPLEMENT_REFCOUNTING(NativeDevToolsClient);
};

static void configureNativeDevTools(CefWindowInfo &window, CefRefPtr<CefClient> &client,
                                   bool *useDefaultWindow) {
    ++pendingDevTools;
    window.windowless_rendering_enabled = false;
    client = new NativeDevToolsClient;
    *useDefaultWindow = true;
}

static void closeNativeDevTools() {
    auto copy = devToolsBrowsers;
    for (auto &browser : copy) browser->GetHost()->CloseBrowser(true);
}
