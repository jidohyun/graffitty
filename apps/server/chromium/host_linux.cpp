#include "linux_control.h"
#include <csignal>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <vector>
#include <algorithm>
#include <string>
#include "linux_gpu_sender.h"
#include "build_info.h"
#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_id_mappers.h"
#include "include/base/cef_callback.h"
#include "include/base/cef_compiler_specific.h"
#include "include/wrapper/cef_closure_task.h"
#include "devtools_client.h"
#include "backend.h"
#include "inspect_menu.h"
#include "page_details.h"
#include "linux_display_platform.h"
#include <chrono>
#include <unistd.h>
static std::string ozonePlatform;
using D = CefRefPtr<CefDictionaryValue>;
using L = CefRefPtr<CefListValue>;
static D object() { return CefDictionaryValue::Create(); }
static CefRefPtr<CefValue> value(D d) {
    auto v = CefValue::Create();
    v->SetDictionary(d);
    return v;
}
static std::string json(D d) { return CefWriteJSON(value(d), JSON_WRITER_DEFAULT).ToString(); }
static D parse(const std::string &s) {
    auto v = CefParseJSON(s, JSON_PARSER_RFC);
    return v && v->GetType() == VTYPE_DICTIONARY ? v->GetDictionary() : nullptr;
}
static D sub(D d, const char *key) {
    auto v = d ? d->GetDictionary(key) : nullptr;
    return v ? v : object();
}
static std::string str(D d, const char *key) { return d ? d->GetString(key).ToString() : ""; }
static std::filesystem::path directory;
static ServerControl control;
static ChromiumPipe chromium;
static bool gpuEnabled = false;
static void close_all();
static GpuSender gpu;
static bool software_screencast() {
    // CEF fixes Alloy's paint mode at browser creation. CDP can read either
    // style's existing compositor without reopening a tab or losing page state.
    return gpu.needs_screencast() || (!alloy() && gpu.software());
}
static void configureLinuxBrowser(CefWindowInfo &info, CefBrowserSettings &settings) {
    configureBrowser(info, settings);
    if (alloy() && gpu.software()) {
        info.shared_texture_enabled = false;
        settings.windowless_frame_rate = 10;
    }
}
static std::vector<CefRefPtr<CefBrowser>> pages;
static CefRefPtr<CefBrowser> active;
static std::map<int, std::string> titles;
static bool visible = false, ending = false, capture = false;
// What a Chromium that should stay embedded did on the desktop anyway. The
// macOS and Windows hosts report the same three counters.
static uint64_t unexpectedWindowOrders = 0, unexpectedKeyEvents = 0, unexpectedActivations = 0;
static int captured = -1;
static int width = 1280, height = 720;
static void event(D d) { if (!control.send(json(d))) close_all(); }
#include "context_menu_windows.h"
static bool chromeStateDirty = true;
static void chromeStateChanged() { chromeStateDirty = true; }
static void publishChromeStateChange() {
    if (!chromeStateDirty || ending) return;
    chromeStateDirty = false;
    auto change = object();
    change->SetString("method", "Graffitty.stateChanged");
    change->SetDictionary("params", object());
    event(change);
}
static void reply(int id, D result = object(), const std::string &error = "") {
    auto d = object();
    d->SetInt("id", id);
    if (error.empty())
        d->SetDictionary("result", result);
    else
        { auto detail = object(); detail->SetString("message", error); d->SetDictionary("error", detail); }
    event(d);
}
static D diagnostics();
static void tab_command(D command);
static std::map<int, int> pageWindows;
static L nativeWindows;
static void native_window_snapshot(D result) {
    nativeWindows = result->GetList("windows")->Copy();
    pageWindows.clear();
    auto tabs = result->GetList("tabs");
    if (tabs) for (size_t i = 0; i < tabs->GetSize(); ++i) {
        auto tab = tabs->GetDictionary(i);
        pageWindows[tab->GetInt("id")] = tab->GetInt("window");
    }
    visible = false;
    // A window on screen that was not presented natively was ordered there
    // unasked; count each time one appears.
    static std::set<int> ordered;
    std::set<int> shown;
    if (nativeWindows) for (size_t i = 0; i < nativeWindows->GetSize(); ++i) {
        auto state = nativeWindows->GetDictionary(i);
        visible |= state->GetBool("native");
        if (state->GetBool("visible") && !state->GetBool("native")) {
            shown.insert(state->GetInt("id"));
            if (!ending && !ordered.count(state->GetInt("id"))) ++unexpectedWindowOrders;
        }
    }
    ordered = std::move(shown);
}
static D native_window(CefRefPtr<CefBrowser> browser) {
    auto found = browser ? pageWindows.find(browser->GetIdentifier()) : pageWindows.end();
    if (found != pageWindows.end() && nativeWindows)
        for (size_t i = 0; i < nativeWindows->GetSize(); ++i) {
            auto state = nativeWindows->GetDictionary(i);
            if (state->GetInt("id") == found->second) return state;
        }
    return object();
}
static void show(bool state, int id = -1) {
    auto command = object();
    command->SetInt("id", id);
    command->SetInt("chromium_id", active ? active->GetIdentifier() : 0);
    command->SetString("action", "window-present");
    command->SetBool("native", state);
    tab_command(command);
}
static void close_all() {
    if (ending)
        return;
    ending = true;
    closeNativeDevTools();
    auto copy = pages;
    for (auto &p : copy)
        p->GetHost()->CloseBrowser(true);
}
#include "windows_tab_bridge.h"
class Observer final : public CefDevToolsMessageObserver {
    bool OnDevToolsMessage(CefRefPtr<CefBrowser> b, const void *bytes, size_t size) override {
        std::string data(static_cast<const char *>(bytes), size);
        auto d = parse(data);
        if (d && tab_message(b, d))
            return true;
        return true;
    }
    IMPLEMENT_REFCOUNTING(Observer);
};
class Client final : public CefClient,
                     public CefLifeSpanHandler,
                     public CefRenderHandler,
                     public CefFocusHandler,
                     public CefKeyboardHandler,
                     public CefCommandHandler,
                     public CefDisplayHandler,
                     public CefLoadHandler,
                     public CefPermissionHandler,
                     public CefFindHandler,
                     public CefContextMenuHandler {
    std::map<int, CefRefPtr<CefRegistration>> registrations;

  public:
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    void OnFindResult(CefRefPtr<CefBrowser>, int identifier, int count, const CefRect &,
                      int active_match, bool final) override {
        auto result = object();
        result->SetInt("identifier", identifier);
        result->SetInt("count", count);
        result->SetInt("active", active_match);
        result->SetBool("final", final);
        auto message = object();
        message->SetString("method", "Graffitty.findResult");
        message->SetDictionary("params", result);
        event(message);
    }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                             CefRefPtr<CefContextMenuParams>, CefRefPtr<CefMenuModel> model) override {
        addAlloyInspect(model);
    }
    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                              CefRefPtr<CefContextMenuParams> params, int command,
                              EventFlags) override {
        return inspectPage(browser, params, command);
    }
    bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        CefRefPtr<CefContextMenuParams>, CefRefPtr<CefMenuModel> model,
                        CefRefPtr<CefRunContextMenuCallback> callback) override {
        if (visible) return false;
        chooseContext(contextSerial, -1);
        ++contextSerial;
        contextCallback = callback;
        contextEvent(contextItems(model));
        return true;
    }
    void OnContextMenuDismissed(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>) override {
        contextCallback = nullptr;
        contextCommands.clear();
        contextEvent(CefListValue::Create());
    }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
                       const CefString &, const CefString &, WindowOpenDisposition,
                       bool, const CefPopupFeatures &, CefWindowInfo &info,
                       CefRefPtr<CefClient> &, CefBrowserSettings &settings,
                       CefRefPtr<CefDictionaryValue> &, bool *) override {
        if (alloy()) configureLinuxBrowser(info, settings);
        return false;
    }
    void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser>, CefWindowInfo &window,
                              CefRefPtr<CefClient> &client, CefBrowserSettings &,
                              CefRefPtr<CefDictionaryValue> &, bool *useDefaultWindow) override {
        configureNativeDevTools(window, client, useDefaultWindow);
    }
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    // Embedded input is injected and carries no native event. A key that does
    // came from the desktop, which an embedded Chromium must never receive.
    bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent &, CefEventHandle native, bool *) override {
        if (native && !alloy() && !visible && !ending) ++unexpectedKeyEvents;
        return false;
    }
    CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool, bool, bool) override {
        chromeStateChanged();
    }
    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
        if (frame && frame->IsMain()) clearPageIcon(browser);
    }
    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString &) override {
        chromeStateChanged();
    }
    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
        updatePageIcon(browser, urls);
    }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                        const CefString &, uint32_t,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        callback->Cancel();
        return true;
    }
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t, const CefString &, uint32_t,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        callback->Continue(CEF_PERMISSION_RESULT_DENY);
        return true;
    }
    void GetViewRect(CefRefPtr<CefBrowser> b, CefRect &rect) override {
        rect = alloy() || (!software_screencast() && capture && !visible && active && active->IsSame(b)) ? CefRect(0, 0, width, height)
                                                                  : CefRect();
    }
    bool capture_view(CefRefPtr<CefBrowser> b, PaintElementType type) {
        return gpuEnabled && capture && !visible && active && active->IsSame(b) && type == PET_VIEW;
    }
    void frame_sent(CefRefPtr<CefBrowser> b) {
        if (captured != b->GetIdentifier()) chromeStateChanged();
        captured = b->GetIdentifier();
    }
    void OnPaint(CefRefPtr<CefBrowser> b, PaintElementType type, const RectList &,
                 const void *pixels, int w, int h) override {
        if (capture_view(b, type) && gpu.transfer(pixels, w, h)) frame_sent(b);
    }
    void OnAcceleratedPaint(CefRefPtr<CefBrowser> b, PaintElementType type, const RectList &,
                            const CefAcceleratedPaintInfo &info) override {
        if (!capture_view(b, type) || software_screencast()) return;
        if (gpu.transfer(info)) frame_sent(b);
        else if (gpu.needs_screencast()) chromeStateChanged();
    }
    void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
        pages.push_back(b);
        active = b;
        chromeStateChanged();
        registrations[b->GetIdentifier()] = b->GetHost()->AddDevToolsMessageObserver(new Observer);
        if (int opener = b->GetHost()->GetOpenerIdentifier(); opener && !alloy()) {
            auto command = object(); command->SetInt("id", -b->GetIdentifier());
            command->SetString("action", "tab-adopt"); command->SetInt("chromium_id", b->GetIdentifier());
            command->SetInt("opener_id", opener); tab_command(command);
        }
    }
    void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString &title) override {
        titles[b->GetIdentifier()] = title.ToString();
        chromeStateChanged();
    }
    void OnGotFocus(CefRefPtr<CefBrowser> b) override {
        // OnSetFocus refuses focus while embedded, so focus that arrives
        // anyway is the desktop activating a Chromium that should be hidden.
        if (!alloy() && !visible && !ending) ++unexpectedActivations;
        if (visible && (!active || !active->IsSame(b))) {
            active = b;
            chromeStateChanged();
        }
    }
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return !alloy() && !visible; }
    bool OnChromeCommand(CefRefPtr<CefBrowser> b, int id, cef_window_open_disposition_t) override {
        const auto count = std::count_if(pages.begin(), pages.end(),
                                         [&](auto &p) { return native_window(p)->GetInt("id") == native_window(b)->GetInt("id"); });
        if (!ending && (id == cef_id_for_command_id_name("IDC_CLOSE_WINDOW") ||
                        id == cef_id_for_command_id_name("IDC_EXIT") ||
                        (id == cef_id_for_command_id_name("IDC_CLOSE_TAB") && count <= 1))) {
            show(false);
            return true;
        }
        return false;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
        auto id = b->GetIdentifier();
        registrations.erase(id);
        titles.erase(id);
        pageIcons.erase(id);
        targets.erase(id);
        pages.erase(
            std::remove_if(pages.begin(), pages.end(), [&](auto &p) { return p->IsSame(b); }),
            pages.end());
        if (active && active->IsSame(b))
            active = pages.empty() ? nullptr : pages.front();
        chromeStateChanged();
        if (pages.empty())
            CefQuitMessageLoop();
    }
    IMPLEMENT_REFCOUNTING(Client);
};
static void alloy_tab_command(D command) {
    int id = command->GetInt("id");
    auto action = str(command, "action");
    CefRefPtr<CefBrowser> target;
    for (auto &page : pages) if (page->GetIdentifier() == command->GetInt("chromium_id")) target = page;
    if (!target) { reply(id, object(), "Unknown Alloy tab"); return; }
    if (action == "tab-new") {
        CefWindowInfo info;
        CefBrowserSettings settings; configureLinuxBrowser(info, settings);
        auto created = CefBrowserHost::CreateBrowserSync(info, new Client, command->GetString("url"),
            settings, nullptr, target->GetHost()->GetRequestContext());
        if (!created) reply(id, object(), "Could not create Alloy tab");
        else alloy_created[created->GetIdentifier()] = {id, tab_now_ms() + 5000};
        return;
    }
    if (action == "tab-select") { active = target; active->GetHost()->SetFocus(true); }
    else if (action == "tab-move") {
        pages.erase(std::find(pages.begin(), pages.end(), target));
        pages.insert(pages.begin() + std::clamp(command->GetInt("index"), 0, (int)pages.size()), target);
    } else { reply(id, object(), "Unsupported Alloy tab operation"); return; }
    chromeStateChanged(); reply(id);
}
static void sync_alloy_capture() {
    if (!alloy()) return;
    static std::map<int, bool> hidden;
    for (auto &page : pages) {
        bool next = !capture || !active || !active->IsSame(page);
        int id = page->GetIdentifier();
        if (!hidden.count(id) || hidden[id] != next) {
            hidden[id] = next;
            if (!next) page->GetHost()->WasResized();
            page->GetHost()->WasHidden(next);
            if (!next) {
                page->GetHost()->Invalidate(PET_VIEW);
            }
        }
    }
    std::erase_if(hidden, [](const auto &entry) {
        return std::none_of(pages.begin(), pages.end(), [&](auto &page) { return page->GetIdentifier() == entry.first; });
    });
}
static D diagnostics() {
    auto result = object();
    result->SetString("backend", backendName());
    result->SetBool("nativeWindowSupported", ozonePlatform != "headless" && !alloy() && native_window(active)->GetBool("supported"));
    result->SetString("ozonePlatform", ozonePlatform);
    result->SetBool("sandboxEnabled", false);
    if (!tab_error.empty()) result->SetString("error", tab_error);
    auto pageTargets = CefListValue::Create();
    auto details = object();
    for (auto &page : pages) {
        auto found = targets.find(page->GetIdentifier());
        if (found != targets.end()) {
            pageTargets->SetString(pageTargets->GetSize(), found->second);
            auto detail = pageDetails(page);
            detail->SetString("title", titles[page->GetIdentifier()]);
            details->SetDictionary(found->second, detail);
        }
    }
    result->SetList("pageTargets", pageTargets);
    result->SetDictionary("pageDetails", details);
    if (!active) return result;

    result->SetString("captureTransport", software_screencast() ? "cdp-screencast" : gpu.software() ? "sealed-memfd" : "vulkan-opaque-fd");
    auto capturedTarget = targets.find(captured);
    auto selectedTarget = targets.find(active->GetIdentifier());
    result->SetString("capturedTargetId", capturedTarget == targets.end() ? "" : capturedTarget->second);
    result->SetString("nativeSelectedTargetId", selectedTarget == targets.end() ? "" : selectedTarget->second);
    result->SetBool("stateEvents", true);
        result->SetInt("runtimeStyle", active->GetHost()->GetRuntimeStyle());
        result->SetBool("windowless", active->GetHost()->IsWindowRenderingDisabled());
        result->SetBool("nativeVisible", visible);
        result->SetBool("nativeUIVisible", native_window(active)->GetBool("visible"));
        result->SetBool("nativeFocused", native_window(active)->GetBool("focused"));
        result->SetDouble("gpuFrames", double(gpu.gpu_frames));
        result->SetDouble("cpuFrames", double(gpu.cpu_frames));
        result->SetDouble("sentFrames", double(gpu.sent));
        result->SetDouble("droppedFrames", double(gpu.dropped));
        result->SetDouble("errors", double(gpu.errors));
        result->SetInt("chromiums", int(pages.size()));
        result->SetInt("windowCount", nativeWindows ? int(nativeWindows->GetSize()) : 0);
        int visibleWindows = 0;
        if (nativeWindows) for (size_t i = 0; i < nativeWindows->GetSize(); ++i)
            visibleWindows += nativeWindows->GetDictionary(i)->GetBool("visible");
        result->SetInt("visibleWindows", visibleWindows);
        result->SetDouble("unexpectedWindowOrders", double(unexpectedWindowOrders));
        result->SetDouble("unexpectedKeyEvents", double(unexpectedKeyEvents));
        result->SetDouble("unexpectedActivations", double(unexpectedActivations));
        result->SetBool("tabBridgeReady", alloy() || tab_ready);

    return result;
}

static void dispatch(const std::string &bytes) {
    auto message = parse(bytes);
    if (!message || !message->HasKey("method")) { close_all(); return; }
    int id = message->GetInt("id");
    auto method = str(message, "method");
    auto params = sub(message, "params");
    if (method == "Graffitty.diagnostics") { reply(id, diagnostics()); return; }
    if (!active) { reply(id, object(), "Chromium is not ready"); return; }
    if (method == "Graffitty.contextMenuSelect") {
        chooseContext(params->GetInt("menu_id"), params->GetInt("command_id"));
    } else if (method == "Graffitty.present") {
        if (ozonePlatform == "headless" && str(params, "mode") == "native") {
            reply(id, object(), "Native presentation requires a display server"); return;
        }
        if (alloy()) { reply(id, object(), "Alloy has no native browser window"); return; }
        auto mode = str(params, "mode");
        if (mode != "native" && mode != "embedded") { reply(id, object(), "mode must be native or embedded"); return; }
        show(mode == "native", id);
        return;
    } else if (method == "Graffitty.capture") {
        capture = params->GetBool("enabled");
        auto result = object();
        result->SetBool("softwareScreencast", software_screencast());
        result->SetBool("nativeVisible", visible);
        reply(id, result);
        return;
    } else if (method == "Graffitty.resize") {
        width = std::clamp(params->GetInt("width"), 64, 4096);
        height = std::clamp(params->GetInt("height"), 64, 4096);
        if (alloy()) active->GetHost()->WasResized();
        // Chrome capture sizes its RenderWidgetHostView from GetViewRect;
        // embedded layout must not depend on native window-manager constraints.
    } else if (method == "Graffitty.select") {
        CefRefPtr<CefBrowser> target;
        for (auto &page : pages) {
            auto found = targets.find(page->GetIdentifier());
            if (found != targets.end() && found->second == str(params, "targetId")) target = page;
        }
        if (!target) { reply(id, object(), "Capture target is not ready"); return; }
        if (!active->IsSame(target)) {
            active = target;
            auto command = object(); command->SetInt("id", id);
            command->SetString("action", "tab-select"); command->SetInt("chromium_id", target->GetIdentifier());
            tab_command(command); return;
        }
    } else if (method == "Graffitty.moveTab") {
        CefRefPtr<CefBrowser> target;
        for (auto &page : pages) if (targets[page->GetIdentifier()] == str(params, "targetId")) target = page;
        if (!target) { reply(id, object(), "Unknown tab"); return; }
        auto command = object(); command->SetInt("id", id); command->SetString("action", "tab-move");
        command->SetInt("chromium_id", target->GetIdentifier()); command->SetInt("index", params->GetInt("index"));
        tab_command(command); return;
    } else if (method == "Graffitty.classify") {
        if (!params->HasKey("text") || params->GetType("text") != VTYPE_STRING) {
            reply(id, object(), "Expected address text"); return;
        }
        tab_classify(active, id, params->GetString("text")); return;
    } else if (method == "Graffitty.historyQuery") {
        if (!params->HasKey("text") || params->GetType("text") != VTYPE_STRING ||
            !params->HasKey("limit") || params->GetType("limit") != VTYPE_INT) {
            reply(id, object(), "Expected history text and limit"); return;
        }
        history_query(active, id, params->GetString("text"), params->GetInt("limit")); return;
    } else if (method == "Graffitty.createTab") {
        auto command = object(); command->SetInt("id", id);
        command->SetString("action", "tab-new"); command->SetInt("chromium_id", active->GetIdentifier());
        command->SetString("url", params->GetString("url"));
        tab_command(command); return;
    } else if (method == "Graffitty.zoom") {
        int direction = params->GetInt("direction");
        if (direction < -1 || direction > 1) { reply(id, object(), "Invalid zoom direction"); return; }
        if (alloy()) zoomAlloy(active, direction);
        else active->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name(
            direction > 0 ? "IDC_ZOOM_PLUS" : direction < 0 ? "IDC_ZOOM_MINUS" : "IDC_ZOOM_NORMAL"), CEF_WOD_CURRENT_TAB);
    } else if (method == "Graffitty.find") {
        // Chromium's find-in-page engine; Graffitty draws the find box.
        if (params->GetType("text") != VTYPE_STRING) { reply(id, object(), "Find text is empty or too long"); return; }
        std::string text = params->GetString("text").ToString();
        if (text.empty() || text.size() > 4096) { reply(id, object(), "Find text is empty or too long"); return; }
        active->GetHost()->Find(text, !params->GetBool("backward"), params->GetBool("matchCase"), params->GetBool("findNext"));
    } else if (method == "Graffitty.stopFinding") {
        // Like Chrome's Escape, closing keeps the active match selected.
        active->GetHost()->StopFinding(params->GetBool("clearSelection"));
    } else if (method.starts_with("Graffitty.")) {
        reply(id, object(), "Unknown chromium control method"); return;
    } else if (method == "Browser.close") {
        reply(id); close_all(); return;
    } else {
        if (method == "Input.dispatchMouseEvent" && str(params, "type") == "mousePressed" && str(params, "button") == "right") {
            contextRequest = str(params, "contextMenuRequest");
            params->Remove("contextMenuRequest");
        }
        auto protocol = json(message);
        if (!chromium.send(protocol)) close_all();
        return;
    }
    reply(id);
}
static void poll() {
    if (ending) return;
    if (!control.poll([](const std::string& message) { dispatch(message); return true; })) { close_all(); return; }
    if (!chromium.poll([](const std::string &message) { return control.send(message); })) { close_all(); return; }
    tab_tick();
    sync_alloy_capture();
    if (gpuEnabled) gpu.flush();
    publishChromeStateChange();
}
static void tick() {
    poll();
    if (!ending)
        CefPostDelayedTask(TID_UI, base::BindOnce(&tick), 20);
}
class App final : public CefApp, public CefBrowserProcessHandler {
  public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    CefRefPtr<CefClient> GetDefaultClient() override { return new Client; }
    void OnBeforeCommandLineProcessing(const CefString &type, CefRefPtr<CefCommandLine> c) override {
        // Rubber-banding a captured chromium surface looks like frame jitter.
        auto disabled = c->GetSwitchValue("disable-features").ToString();
        // In this Linux CEF SDK the GWP-ASan sampler uses pthread TLS. On a
        // new thread glibc can calloc a TLS block inside the allocation hook,
        // recursively entering the sampler until the host exhausts its stack.
        c->AppendSwitchWithValue("disable-features", disabled + (disabled.empty() ? "" : ",") +
                                 "ElasticOverscroll,GwpAsanMalloc,GwpAsanPartitionAlloc");
        // ANGLE on Vulkan needs only the GPU.
        //
        // The default GLX path depends on the X server's GL driver, which
        // VNC, Xvfb and remote sessions lack; without GPU compositing CEF
        // delivers no DMA-BUF frames at all.
        if (type.empty()) {
            if (gpu.software() && !alloy()) {
                // Chrome's unmapped window needs an offscreen GL compositor.
                c->AppendSwitchWithValue("use-gl", "angle");
                c->AppendSwitchWithValue("use-angle", "swiftshader");
                c->AppendSwitch("ignore-gpu-blocklist");
            } else if (gpu.software()) {
                c->AppendSwitch("disable-gpu");
            } else {
                c->AppendSwitchWithValue("use-angle", "vulkan");
                auto enabled = c->GetSwitchValue("enable-features").ToString();
                c->AppendSwitchWithValue("enable-features", enabled + (enabled.empty() ? "" : ",") +
                                                                 "Vulkan,DefaultANGLEVulkan,VulkanFromANGLE");
            }
        }
        if (!alloy()) c->AppendSwitch("graffitty-chrome-gpu-capture");
        // Alloy uses only the bridge's omnibox classification, not its tab strip.
        c->AppendSwitch("graffitty-native-tabs");
        // Address-bar suggestions from Chrome's omnibox history ranking.
        c->AppendSwitch("graffitty-history");
        if (type.empty()) c->AppendSwitch("remote-debugging-pipe");
        c->AppendSwitch("disable-backgrounding-occluded-windows");
        c->AppendSwitchWithValue("ozone-platform", ozonePlatform);
        c->AppendSwitch("disable-renderer-backgrounding");
    }
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> c) override {
        c->AppendSwitch("graffitty-native-chrome-ui");
    }
    IMPLEMENT_REFCOUNTING(App);
};
// Chromium reseeds the stack guard after forking a zygote child.
NO_STACK_PROTECTOR
int main(int argc, char **argv) {
    if (argc == 3 && std::string(argv[1]) == "--write-build-info")
        return write_build_info(std::filesystem::path(argv[2]));
    auto platform = graffitty::linux_display_platform(
        std::getenv("GRAFFITTY_CHROMIUM_OZONE_PLATFORM"),
        std::getenv("WAYLAND_DISPLAY"), std::getenv("WAYLAND_SOCKET"), std::getenv("DISPLAY"));
    if (!platform) {
        fprintf(stderr, "GRAFFITTY_CHROMIUM_OZONE_PLATFORM must be x11, wayland or headless\n");
        return 2;
    }
    ozonePlatform = *platform;
    CefMainArgs args(argc, argv);
    auto app = CefRefPtr<App>(new App);
    int exit = CefExecuteProcess(args, app, nullptr);
    if (exit >= 0)
        return exit;
    std::string profile, endpoint, controlPath, url = "about:blank";
    pid_t serverPid = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        std::string a = argv[i];
        if (a == "--artifacts")
            directory = argv[++i];
        else if (a == "--gpu-endpoint")
            endpoint = argv[++i];
        else if (a == "--profile")
            profile = argv[++i];
        else if (a == "--backend") { if (!parseBackend(argv[++i])) return 2; }
        else if (a == "--server-control") controlPath = argv[++i];
        else if (a == "--server-pid") serverPid = std::stoi(argv[++i]);
        else if (a == "--url")
            url = argv[++i];
    }
    if (directory.empty() || controlPath.empty())
        return 2;
    if (profile.empty())
        profile = (directory / "cef-profile").string();
    std::signal(SIGPIPE, SIG_IGN);
    if (!control.connect(controlPath, serverPid)) return 3;
    std::error_code pathError;
    profile = std::filesystem::weakly_canonical(profile, pathError).string();
    if (pathError)
        return 2;
    if (!chromium.prepare()) return 6;
    if (!endpoint.empty()) { if (!gpu.start(endpoint)) return 3; gpuEnabled = true; }
    CefSettings settings;
    settings.command_line_args_disabled = true;
    settings.no_sandbox = true; // Matches the existing isolated-profile hosts.
    settings.windowless_rendering_enabled = true;
    CefString(&settings.root_cache_path) = profile;
    CefString(&settings.cache_path) = (std::filesystem::path(profile) / "Default").string();
    CefString(&settings.log_file) = (directory / "cef.log").string();
    if (!CefInitialize(args, settings, app, nullptr))
        return CefGetExitCode();
    CefWindowInfo info;
    CefString(&info.window_name) = "Graffitty Chromium";
    info.bounds = CefRect(100, 100, 1280, 800);
    CefBrowserSettings chromium_settings;
    configureLinuxBrowser(info, chromium_settings);
    CefBrowserHost::CreateBrowser(info, new Client, url, chromium_settings, nullptr, nullptr);
    CefPostDelayedTask(TID_UI, base::BindOnce(&tick), 20);
    CefRunMessageLoop();
    nativeWindows = nullptr;
    tab_shutdown();
    active = nullptr;
    pages.clear();
    gpu.shutdown();
    CefShutdown();
    return 0;
}
