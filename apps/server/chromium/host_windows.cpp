#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include "../../../crates/transport/chromium-video/include/windows_adapter.h"
#include <commctrl.h>
#include <shellapi.h>
#include <delayimp.h>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <vector>
#include <algorithm>
#include <string>
#include "windows_gpu_sender.h"
#include "build_info.h"
#include "include/cef_app.h"
#include "include/cef_sandbox_win.h"
#include "include/cef_client.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "windows_server_control.h"
#include "windows_chromium_pipe.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_id_mappers.h"
#include "include/base/cef_callback.h"
#include "include/wrapper/cef_closure_task.h"
#include "devtools_client.h"
#include "backend.h"
#include "inspect_menu.h"
#include "page_details.h"
// Sandboxed children cannot open diagnostic files after lockdown. Preserve
// loader failures on Chromium's inherited log handle before the CRT aborts.
static FARPROC WINAPI reportDelayLoadFailure(unsigned event, PDelayLoadInfo info) {
    if (event != dliFailLoadLib && event != dliFailGetProc) return nullptr;
    char message[512];
    int size = std::snprintf(message, sizeof(message), "Graffitty DLL load failed: %s (error %lu)\n",
                             info->szDll, info->dwLastError);
    auto handle = GetStdHandle(STD_ERROR_HANDLE);
    if (const auto argument = wcsstr(GetCommandLineW(), L"--log-file="))
        handle = reinterpret_cast<HANDLE>(_wcstoui64(argument + 11, nullptr, 10));
    DWORD written;
    if (size > 0 && size < sizeof(message) && handle && handle != INVALID_HANDLE_VALUE)
        WriteFile(handle, message, DWORD(size), &written, nullptr);
    return nullptr;
}
extern "C" const PfnDliHook __pfnDliFailureHook2 = reportDelayLoadFailure;
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
static void trace(const std::string &message) {
    if (GetEnvironmentVariableW(L"RUST_LOG", nullptr, 0))
        std::ofstream(directory / L"control.log", std::ios::app) << GetTickCount64() << " " << message << "\n";
}
static ServerControl control;
static ChromiumPipe chromium;
// Test physical adapters before CEF chooses its compositor. WARP and the
// Basic Render Driver can render a page without exporting a hardware texture.
static bool hasHardwareRenderer() {
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        if (FAILED(factory->EnumAdapters1(index, &adapter))) return false;
        if (!graffitty::is_hardware_adapter(adapter.Get())) continue;
        if (SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
                nullptr, nullptr, nullptr))) return true;
    }
}
static bool gpuEnabled = false;
static uint64_t unexpectedWindowOrders = 0, unexpectedKeyEvents = 0, unexpectedActivations = 0;
static void close_all();
static GpuSender gpu;
static std::vector<CefRefPtr<CefBrowser>> pages;
static CefRefPtr<CefBrowser> active;
static std::map<int, std::string> titles;
static bool visible = false, ending = false, capture = false;
static int captured = -1, queuedCapture = -1;
static int width = 1280, height = 720;
static void event(D d) { if (!control.send(json(d))) close_all(); }
#include "context_menu_windows.h"
static bool chromeStateDirty = true;
static void chromeStateChanged() { chromeStateDirty = true; }
static void publishCapture() {
    if (!capture || visible || !active || active->GetIdentifier() != queuedCapture) gpu.discard();
    else if (gpu.publish()) {
        if (captured != queuedCapture) chromeStateChanged();
        captured = queuedCapture;
    }
}
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
        { auto e = object(); e->SetString("message", error); d->SetDictionary("error", e); }
    event(d);
}
static HWND window(CefRefPtr<CefBrowser> b) {
    return b ? GetAncestor(b->GetHost()->GetWindowHandle(), GA_ROOT) : nullptr;
}
static void show(bool state) {
    if (visible != state) chromeStateChanged();
    visible = state;
    for (auto &p : pages) {
        auto w = window(p);
        if (!w)
            continue;
        if (state && active && window(active) == w) {
            SetWindowLongPtrW(w, GWL_EXSTYLE,
                              GetWindowLongPtrW(w, GWL_EXSTYLE) & ~WS_EX_NOACTIVATE);
            ShowWindow(w, IsIconic(w) ? SW_RESTORE : SW_SHOW);
            DWORD before = 0, after = 0;
            GetWindowThreadProcessId(GetForegroundWindow(), &before);
            const bool activated = SetForegroundWindow(w) != FALSE;
            GetWindowThreadProcessId(GetForegroundWindow(), &after);
            trace("native activation before=" + std::to_string(before) + " after=" +
                  std::to_string(after) + " accepted=" + std::to_string(activated));
            if (GetForegroundWindow() == w)
                active->GetHost()->SetFocus(true);
        } else
            ShowWindow(w, SW_HIDE);
    }
}
static LRESULT CALLBACK keep_window(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR,
                                    DWORD_PTR) {
    static HWND close_pressed = nullptr;
    // Chromium's custom caption button can close its Views widget directly,
    // bypassing WM_CLOSE and OnChromeCommand. Retain it before that teardown.
    if (!ending) {
        if (message == WM_CLOSE || (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_CLOSE)) {
            show(false);
            return 0;
        }
        if (message == WM_NCLBUTTONDOWN && wparam == HTCLOSE) {
            close_pressed = hwnd;
            SetCapture(hwnd);
            return 0;
        }
        if (message == WM_LBUTTONUP && close_pressed == hwnd) {
            POINT point{static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
            ClientToScreen(hwnd, &point);
            const auto hit = SendMessageW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(point.x, point.y));
            close_pressed = nullptr;
            ReleaseCapture();
            if (hit == HTCLOSE)
                show(false);
            return 0;
        }
    }
    if (message == WM_CAPTURECHANGED && close_pressed == hwnd)
        close_pressed = nullptr;
    if (!visible && !ending && message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) ++unexpectedActivations;
    if (!visible && !ending && (message == WM_KEYDOWN || message == WM_SYSKEYDOWN || message == WM_CHAR)) ++unexpectedKeyEvents;
    if (message == WM_WINDOWPOSCHANGING && !visible && !ending) {
        auto position = reinterpret_cast<WINDOWPOS *>(lparam);
        position->flags = (position->flags & ~SWP_SHOWWINDOW) | SWP_HIDEWINDOW | SWP_NOACTIVATE;
    }
    if (message == WM_WINDOWPOSCHANGED && !visible && !ending && IsWindowVisible(hwnd)) ++unexpectedWindowOrders;
    if (message == WM_NCDESTROY)
        RemoveWindowSubclass(hwnd, keep_window, 1);
    return DefSubclassProc(hwnd, message, wparam, lparam);
}
// Chrome may activate its initial widget after OnAfterCreated. Reject that
// transition before Windows changes focus, including the first hidden window.
static LRESULT CALLBACK embedded_activation(int code, WPARAM wparam, LPARAM lparam) {
    const bool devToolsWindow = std::any_of(devToolsBrowsers.begin(), devToolsBrowsers.end(),
        [&](auto &browser) { return window(browser) == reinterpret_cast<HWND>(wparam); });
    if (code == HCBT_ACTIVATE && !visible && !ending && !pendingDevTools && !devToolsWindow) return 1;
    if (code == HCBT_CREATEWND && !visible && !ending && !pendingDevTools) {
        auto creation = reinterpret_cast<CBT_CREATEWNDW *>(lparam)->lpcs;
        if (!(creation->style & WS_CHILD)) {
            creation->style &= ~WS_VISIBLE;
            creation->dwExStyle |= WS_EX_NOACTIVATE;
        }
    }
    return CallNextHookEx(nullptr, code, wparam, lparam);
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
        if (alloy()) configureBrowser(info, settings);
        return false;
    }
    void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser>, CefWindowInfo &window,
                              CefRefPtr<CefClient> &client, CefBrowserSettings &,
                              CefRefPtr<CefDictionaryValue> &, bool *useDefaultWindow) override {
        configureNativeDevTools(window, client, useDefaultWindow);
    }
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
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
        rect = alloy() || (capture && !visible && active && active->IsSame(b)) ? CefRect(0, 0, width, height)
                                                                  : CefRect();
    }
    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList &, const void *, int,
                 int) override {
        if (!softwareCapture) ++gpu.errors;
    }
    void OnAcceleratedPaint(CefRefPtr<CefBrowser> b, PaintElementType type, const RectList &,
                            const CefAcceleratedPaintInfo &info) override {
        if (gpuEnabled && capture && !visible && active && active->IsSame(b) && type == PET_VIEW &&
            info.shared_texture_handle && gpu.transfer(info.shared_texture_handle)) {
            queuedCapture = b->GetIdentifier();
            publishCapture();
        }
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
        if (auto native = window(b)) {
            SetWindowSubclass(native, keep_window, 1, 0);
            if (!visible) ShowWindow(native, SW_HIDE);
        }
    }
    void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString &title) override {
        titles[b->GetIdentifier()] = title.ToString();
        chromeStateChanged();
    }
    void OnGotFocus(CefRefPtr<CefBrowser> b) override {
        if (visible && (!active || !active->IsSame(b))) {
            active = b;
            chromeStateChanged();
        }
    }
    bool OnSetFocus(CefRefPtr<CefBrowser>, FocusSource) override { return !alloy() && !visible; }
    bool OnChromeCommand(CefRefPtr<CefBrowser> b, int id, cef_window_open_disposition_t) override {
        const auto count = std::count_if(pages.begin(), pages.end(),
                                         [&](auto &p) { return window(p) == window(b); });
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
        CefBrowserSettings settings; configureBrowser(info, settings);
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
            page->GetHost()->WasHidden(next);
            if (!next) { page->GetHost()->WasResized(); page->GetHost()->Invalidate(PET_VIEW); }
        }
    }
    std::erase_if(hidden, [](const auto &entry) {
        return std::none_of(pages.begin(), pages.end(), [&](auto &page) { return page->GetIdentifier() == entry.first; });
    });
}
static D diagnostics() {
    auto result = object();
    result->SetString("backend", backendName());
    result->SetString("captureTransport", softwareCapture ? "cdp-screencast" : "d3d-shared-texture");
    result->SetBool("nativeWindowSupported", !alloy());
    result->SetBool("sandboxEnabled", true);
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

    std::vector<HWND> windows;
    for (auto &page : pages)
        if (window(page) && std::find(windows.begin(), windows.end(), window(page)) == windows.end()) windows.push_back(window(page));
    auto capturedTarget = targets.find(captured);
    auto selectedTarget = targets.find(active->GetIdentifier());
    result->SetString("capturedTargetId", capturedTarget == targets.end() ? "" : capturedTarget->second);
    result->SetString("nativeSelectedTargetId", selectedTarget == targets.end() ? "" : selectedTarget->second);
    result->SetBool("stateEvents", true);
        result->SetInt("runtimeStyle", active->GetHost()->GetRuntimeStyle());
        result->SetBool("windowless", active->GetHost()->IsWindowRenderingDisabled());
        result->SetBool("nativeVisible", visible);
        result->SetBool("nativeUIVisible", visible && IsWindowVisible(window(active)));
        result->SetBool("nativeFocused", visible && GetForegroundWindow() == window(active));
        result->SetDouble("gpuFrames", double(gpu.frames));
        result->SetDouble("sentFrames", double(gpu.sent));
        result->SetDouble("droppedFrames", double(gpu.dropped));
        result->SetDouble("errors", double(gpu.errors));
        result->SetInt("chromiums", int(pages.size()));
        result->SetInt("windowCount", int(windows.size()));
        result->SetInt("visibleWindows",
                       int(std::count_if(windows.begin(), windows.end(),
                                         [](HWND w) { return IsWindowVisible(w); })));
        result->SetBool("tabBridgeReady", alloy() || tab_ready);

    result->SetDouble("unexpectedWindowOrders", double(unexpectedWindowOrders));
    result->SetDouble("unexpectedKeyEvents", double(unexpectedKeyEvents));
    result->SetDouble("unexpectedActivations", double(unexpectedActivations));
    return result;
}

static void dispatch(const std::string &bytes) {
    auto message = parse(bytes);
    if (!message || !message->HasKey("method")) { close_all(); return; }
    int id = message->GetInt("id");
    auto method = str(message, "method");
    trace("request " + method);
    auto params = sub(message, "params");
    if (method == "Graffitty.diagnostics") { reply(id, diagnostics()); return; }
    if (!active) { reply(id, object(), "Chromium is not ready"); return; }
    if (method == "Graffitty.contextMenuSelect") {
        chooseContext(params->GetInt("menu_id"), params->GetInt("command_id"));
    } else if (method == "Graffitty.present") {
        if (alloy()) { reply(id, object(), "Alloy has no native browser window"); return; }
        auto mode = str(params, "mode");
        if (mode != "native" && mode != "embedded") { reply(id, object(), "mode must be native or embedded"); return; }
        show(mode == "native");
        reply(id, diagnostics()); return;
    } else if (method == "Graffitty.capture") {
        capture = params->GetBool("enabled");
        auto result = object();
        result->SetBool("softwareScreencast", softwareCapture);
        result->SetBool("nativeVisible", visible);
        reply(id, result);
        return;
    } else if (method == "Graffitty.resize") {
        width = std::clamp(params->GetInt("width"), 64, 4096);
        height = std::clamp(params->GetInt("height"), 64, 4096);
        if (alloy()) active->GetHost()->WasResized();
        else SetWindowPos(window(active), nullptr, 0, 0, width, height,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
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
    if (!control.poll(dispatch)) { close_all(); return; }
    if (!chromium.poll([](const std::string &message) { return control.send(message); })) { close_all(); return; }
    tab_tick();
    sync_alloy_capture();
    publishCapture();
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
        if (type.empty()) {
            c->AppendSwitch("remote-debugging-pipe");
            c->AppendSwitchWithValue("remote-debugging-io-pipes", chromium.handles());
            trace("chromium CDP handles " + chromium.handles());
        }
        // Rubber-banding a captured chromium surface looks like frame jitter.
        auto disabled = c->GetSwitchValue("disable-features").ToString();
        // This CEF SDK enables BackupRefPtr instance tracing. Its allocation
        // samplers can re-enter InstanceTracer::UntraceImpl while that tracer
        // holds its storage mutex, deadlocking CefInitialize. Keep BRP enabled
        // but exclude the incompatible malloc/experimental sampling detectors.
        c->AppendSwitchWithValue("disable-features", disabled + (disabled.empty() ? "" : ",") +
            "ElasticOverscroll,ExtremeLightweightUAFDetector,GwpAsanMalloc");
        if (type.empty()) trace("disabled features " + c->GetSwitchValue("disable-features").ToString());
        if (softwareCapture) c->AppendSwitch("disable-gpu");
        else if (!alloy()) c->AppendSwitch("graffitty-chrome-gpu-capture");
        // Alloy uses only the bridge's omnibox classification, not its tab strip.
        c->AppendSwitch("graffitty-native-tabs");
        // Address-bar suggestions from Chrome's omnibox history ranking.
        c->AppendSwitch("graffitty-history");
        c->AppendSwitch("disable-backgrounding-occluded-windows");
        c->AppendSwitch("disable-direct-composition"); // Validated host workaround.
    }
    void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> c) override {
        c->AppendSwitch("graffitty-native-chrome-ui");
    }
    IMPLEMENT_REFCOUNTING(App);
};
CEF_BOOTSTRAP_EXPORT int RunWinMain(HINSTANCE instance, LPWSTR, int,
                                  void *sandbox_info, cef_version_info_t *) {
    if (!sandbox_info) return 7;
    // Renderer startup must reach CEF before loading shell32/user32. Calling
    // CommandLineToArgvW first breaks Chromium's Win32k sandbox lockdown.
    CefMainArgs args(instance);
    auto app = CefRefPtr<App>(new App);
    int exit = CefExecuteProcess(args, app, sandbox_info);
    if (exit >= 0)
        return exit;
    int info_argc = 0;
    auto info_argv = CommandLineToArgvW(GetCommandLineW(), &info_argc);
    if (info_argc == 3 && std::wstring(info_argv[1]) == L"--write-build-info") {
        auto path = std::filesystem::path(info_argv[2]);
        LocalFree(info_argv);
        return write_build_info(path);
    }
    LocalFree(info_argv);
    int argc = 0;
    auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    std::wstring profile, endpoint, controlPath, url = L"about:blank";
    DWORD serverPid = 0;
    for (int i = 1; i + 1 < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--artifacts")
            directory = argv[++i];
        else if (a == L"--backend") {
            std::wstring name = argv[++i];
            if (!parseBackend(std::string(name.begin(), name.end()))) return 2;
        }
        else if (a == L"--gpu-endpoint")
            endpoint = argv[++i];
        else if (a == L"--server-control")
            controlPath = argv[++i];
        else if (a == L"--server-pid")
            serverPid = std::stoul(argv[++i]);
        else if (a == L"--profile")
            profile = argv[++i];
        else if (a == L"--url")
            url = argv[++i];
    }
    LocalFree(argv);
    if (directory.empty() || controlPath.empty())
        return 2;
    if (profile.empty())
        profile = (directory / L"cef-profile").wstring();
    if (!control.connect(controlPath, serverPid)) return 3;
    trace("control connected");
    // CEF canonicalizes the root itself. Canonicalize both paths together so
    // symlinked parents (e.g. /tmp on macOS) cannot force in-memory storage.
    std::error_code pathError;
    auto canonicalProfile = std::filesystem::weakly_canonical(profile, pathError);
    if (pathError)
        return 2;
    profile = canonicalProfile.wstring();
    if (!endpoint.empty()) {
        if (!gpu.start(std::string(endpoint.begin(), endpoint.end()))) return 3;
        gpuEnabled = true;
    }
    softwareCapture = !hasHardwareRenderer();
    if (!chromium.prepare()) return 6;
    trace("Chromium control pipe prepared");
    CefSettings settings;
    // These argv values belong to our private launcher (including named pipe
    // paths). Chrome must not interpret them as startup URLs or file arguments.
    settings.command_line_args_disabled = true;
    settings.windowless_rendering_enabled = true;
    CefString(&settings.root_cache_path) = profile;
    CefString(&settings.cache_path) = (std::filesystem::path(profile) / L"Default").wstring();
    CefString(&settings.log_file) = (directory / L"cef.log").wstring();
    if (!CefInitialize(args, settings, app, sandbox_info))
        return CefGetExitCode();
    chromium.adopted();
    trace("CEF initialized");
    auto activationHook = SetWindowsHookExW(WH_CBT, embedded_activation, nullptr, GetCurrentThreadId());
    if (!activationHook) { CefShutdown(); return 5; }
    CefWindowInfo info;
    info.SetAsPopup(nullptr, "Graffitty Chromium");
    info.bounds = CefRect(100, 100, 1280, 800);
    info.style &= ~WS_VISIBLE;
    info.ex_style |= WS_EX_NOACTIVATE;
    CefBrowserSettings chromium_settings;
    configureBrowser(info, chromium_settings);
    CefBrowserHost::CreateBrowser(info, new Client, url, chromium_settings, nullptr, nullptr);
    trace("chromium creation queued");
    CefPostDelayedTask(TID_UI, base::BindOnce(&tick), 20);
    CefRunMessageLoop();
    UnhookWindowsHookEx(activationHook);
    tab_shutdown();
    active = nullptr;
    pages.clear();
    CefShutdown();
    return 0;
}
