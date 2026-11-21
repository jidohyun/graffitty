#pragma once
#include "include/cef_context_menu_handler.h"

static constexpr int inspectCommand = MENU_ID_USER_FIRST + 1;
static void addAlloyInspect(CefRefPtr<CefMenuModel> menu) {
    if (!alloy()) return;
    if (menu->GetCount()) menu->AddSeparator();
    menu->AddItem(inspectCommand, "Inspect");
}
static bool inspectPage(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefContextMenuParams> params, int command) {
    if (command != inspectCommand) return false;
    CefWindowInfo window;
    // Alloy does not invoke OnBeforeDevToolsPopup. Supply its separate client
    // here so the inspector never inherits the page's render/lifecycle handler.
    // CEF's DevTools frontend requires Chrome style even for an Alloy page.
    window.runtime_style = CEF_RUNTIME_STYLE_CHROME;
#if defined(OS_WIN)
    window.SetAsPopup(nullptr, "Developer Tools");
#endif
    window.bounds = CefRect(100, 100, 1000, 700);
    if (!browser->GetHost()->HasDevTools()) ++pendingDevTools;
    browser->GetHost()->ShowDevTools(window, new NativeDevToolsClient, CefBrowserSettings(),
        CefPoint(params->GetXCoord(), params->GetYCoord()));
    return true;
}
