#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

// Subclass individual Godot windows, leaving their original procedure in charge
// of close_requested, focus, IME, system commands and the rendering surface.
namespace {
constexpr UINT_PTR subclass_id = 0x47574348;
struct Frame {
    bool enabled = true;
    bool passthrough = false;
    RECT title = {};
    std::vector<RECT> controls;
    int hover = -1;
    bool pressed = false;
    bool pending = false;
    int64_t receiver = 0;
    void (*callback)(int64_t, const int32_t *) = nullptr;
    std::array<int32_t, 17> caption = {};
    bool published = false;
};
LRESULT CALLBACK window_proc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);

Frame *state(HWND window) {
    DWORD_PTR value = 0;
    return GetWindowSubclass(window, window_proc, subclass_id, &value)
               ? reinterpret_cast<Frame *>(value)
               : nullptr;
}

int metric(HWND window, int index) {
    return GetSystemMetricsForDpi(index, GetDpiForWindow(window));
}

bool active(HWND window, const Frame *frame_state) {
    return frame_state->enabled && (GetWindowLongPtrW(window, GWL_STYLE) & WS_CAPTION);
}

UINT caption_message() {
    static const UINT message = RegisterWindowMessageW(L"Graffitty.NativeCaptionChanged.v1");
    return message;
}

void queue_caption(HWND window, Frame *frame) {
    if (!frame->pending)
        frame->pending = PostMessageW(window, caption_message(), static_cast<WPARAM>(frame->receiver), 0) != 0;
}

std::array<int32_t, 17> caption_state(HWND window, const Frame *frame);

// DWM continues receiving every non-client message, including mouse leave.
// Our observer paints the glyphs without querying global pointer/button state.
void observe_caption(HWND window, Frame *frame, UINT message, WPARAM wparam) {
    switch (message) {
    case WM_NCMOUSEMOVE: {
        frame->hover = wparam == HTMINBUTTON ? 0 : wparam == HTMAXBUTTON ? 1 : wparam == HTCLOSE ? 2 : -1;
        TRACKMOUSEEVENT tracking = {sizeof(tracking), TME_LEAVE | TME_NONCLIENT, window, 0};
        TrackMouseEvent(&tracking);
        break;
    }
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
        frame->pressed = true;
        break;
    case WM_NCLBUTTONUP:
    case WM_LBUTTONUP:
    case WM_CAPTURECHANGED:
    case WM_CANCELMODE:
        frame->pressed = false;
        break;
    case WM_NCMOUSELEAVE:
    case WM_MOUSEMOVE:
        frame->hover = -1;
        break;
    case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) { frame->hover = -1; frame->pressed = false; }
        break;
    case WM_SIZE:
    case WM_WINDOWPOSCHANGED:
    case WM_DPICHANGED:
    case WM_THEMECHANGED:
    case WM_DWMCOMPOSITIONCHANGED:
    case WM_STYLECHANGED:
    case WM_NCACTIVATE:
    case WM_SHOWWINDOW:
        break;
    default:
        return;
    }
    queue_caption(window, frame);
}

void refresh_frame(HWND window, const Frame *frame_state) {
    MARGINS margins = {
        0, 0, active(window, frame_state) ? std::max<LONG>(1, frame_state->title.bottom) : 0, 0};
    DwmExtendFrameIntoClientArea(window, &margins);
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR,
                             DWORD_PTR data) {
    auto *frame_state = reinterpret_cast<Frame *>(data);
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(window, window_proc, subclass_id);
        delete frame_state;
        return DefSubclassProc(window, message, wparam, lparam);
    }
    if (message == caption_message()) {
        if (static_cast<int64_t>(wparam) != frame_state->receiver) return 0;
        frame_state->pending = false;
        auto next = caption_state(window, frame_state);
        if (!frame_state->published || next != frame_state->caption) {
            frame_state->caption = next;
            frame_state->published = true;
            frame_state->callback(frame_state->receiver, next.data());
        }
        return 0;
    }
    observe_caption(window, frame_state, message, wparam);
    if (!active(window, frame_state))
        return DefSubclassProc(window, message, wparam, lparam);
    if (message == WM_NCCALCSIZE && wparam) {
        auto *params = reinterpret_cast<NCCALCSIZE_PARAMS *>(lparam);
        const LONG top = params->rgrc[0].top;
        // Keep Windows' side/bottom resize frame and maximized work-area inset.
        DefSubclassProc(window, message, wparam, lparam);
        params->rgrc[0].top = top + (IsZoomed(window) ? metric(window, SM_CYSIZEFRAME) +
                                                            metric(window, SM_CXPADDEDBORDER)
                                                      : 0);
        return 0;
    }
    if (message == WM_NCHITTEST && frame_state->passthrough)
        return HTTRANSPARENT;
    LRESULT result = 0;
    if (DwmDefWindowProc(window, message, wparam, lparam, &result)) {
        // Some Windows versions also handle the client/caption hit. Only the
        // system buttons and frame edges take precedence over our tab regions.
        if (message != WM_NCHITTEST ||
            (result != HTCLIENT && result != HTCAPTION && result != HTNOWHERE))
            return result;
    }
    if (message == WM_NCHITTEST) {
        POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ScreenToClient(window, &point);
        RECT client;
        GetClientRect(window, &client);
        const auto style = GetWindowLongPtrW(window, GWL_STYLE);
        const int border = metric(window, SM_CYSIZEFRAME) + metric(window, SM_CXPADDEDBORDER);
        if (!IsZoomed(window) && (style & WS_THICKFRAME) && point.y >= 0 && point.y < border) {
            if (point.x < border)
                return HTTOPLEFT;
            if (point.x >= client.right - border)
                return HTTOPRIGHT;
            return HTTOP;
        }
        if (PtInRect(&frame_state->title, point)) {
            for (const auto &control : frame_state->controls)
                if (PtInRect(&control, point))
                    return HTCLIENT;
            return HTCAPTION;
        }
        if (PtInRect(&client, point))
            return HTCLIENT;
    }
    return DefSubclassProc(window, message, wparam, lparam);
}
} // namespace

// The stock 4.7 Windows display server does not forward WM_DPICHANGED. This
// subclass also covers undecorated or transient windows without a caption.
extern "C" void graffitty_dpi_changed(int64_t receiver);
static LRESULT CALLBACK dpi_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam,
                                 UINT_PTR id, DWORD_PTR receiver) {
    if (message == WM_DPICHANGED) {
        const RECT bounds = *reinterpret_cast<const RECT *>(lparam);
        SetWindowPos(window, nullptr, bounds.left, bounds.top, bounds.right - bounds.left,
                     bounds.bottom - bounds.top, SWP_NOACTIVATE | SWP_NOZORDER);
        graffitty_dpi_changed(static_cast<int64_t>(receiver));
        return 0;
    }
    if (message == WM_NCDESTROY)
        RemoveWindowSubclass(window, dpi_proc, id);
    return DefSubclassProc(window, message, wparam, lparam);
}

extern "C" uint32_t graffitty_watch_dpi(uint64_t handle, int64_t receiver) {
    HWND window = reinterpret_cast<HWND>(handle);
    SetWindowSubclass(window, dpi_proc, 1, static_cast<DWORD_PTR>(receiver));
    return GetDpiForWindow(window);
}

// The frontend registers this on build 22000 and newer. Use the published
// ABI values so older Windows SDK headers can compile the same adapter.
extern "C" void graffitty_window_round_corners(uint64_t handle, bool small_corners) {
    constexpr DWORD corner_preference = 33; // DWMWA_WINDOW_CORNER_PREFERENCE
    const DWORD preference = small_corners ? 3 : 2; // DWMWCP_ROUNDSMALL / DWMWCP_ROUND
    DwmSetWindowAttribute(reinterpret_cast<HWND>(handle), corner_preference,
                          &preference, sizeof(preference));
}

extern "C" bool graffitty_window_frame_attach(uint64_t handle, int64_t receiver,
                                              void (*callback)(int64_t, const int32_t *)) {
    HWND window = reinterpret_cast<HWND>(handle);
    if (!IsWindow(window) || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId())
        return false;
    if (state(window) || !receiver || !callback)
        return false;
    const auto style = GetWindowLongPtrW(window, GWL_STYLE);
    if ((style & WS_CHILD) || !(style & WS_CAPTION))
        return false;
    auto *frame_state = new Frame;
    frame_state->receiver = receiver;
    frame_state->callback = callback;
    if (!SetWindowSubclass(window, window_proc, subclass_id,
                           reinterpret_cast<DWORD_PTR>(frame_state))) {
        delete frame_state;
        return false;
    }
    refresh_frame(window, frame_state);
    queue_caption(window, frame_state);
    return true;
}

extern "C" void graffitty_window_frame_detach(uint64_t handle) {
    HWND window = reinterpret_cast<HWND>(handle);
    auto *frame_state = state(window);
    if (!frame_state)
        return;
    RemoveWindowSubclass(window, window_proc, subclass_id);
    frame_state->enabled = false;
    refresh_frame(window, frame_state);
    delete frame_state;
}

extern "C" void graffitty_window_frame_update(uint64_t handle, bool enabled, bool passthrough,
                                            const int32_t *title, const int32_t *rects, int count) {
    HWND window = reinterpret_cast<HWND>(handle);
    auto *frame_state = state(window);
    if (!frame_state)
        return;
    bool changed = frame_state->enabled != enabled || frame_state->title.bottom != title[3];
    frame_state->enabled = enabled;
    frame_state->passthrough = passthrough;
    frame_state->title = {title[0], title[1], title[2], title[3]};
    frame_state->controls.clear();
    for (int i = 0; i < count; ++i, rects += 4)
        frame_state->controls.push_back({rects[0], rects[1], rects[2], rects[3]});
    if (changed) {
        refresh_frame(window, frame_state);
        queue_caption(window, frame_state);
    }
}

extern "C" void graffitty_window_frame_margins(uint64_t handle, int32_t *out) {
    out[0] = out[1] = out[2] = 0;
    HWND window = reinterpret_cast<HWND>(handle);
    const auto *frame_state = state(window);
    if (!frame_state || !active(window, frame_state))
        return;
    RECT buttons = {}, frame, client;
    POINT origin = {};
    GetWindowRect(window, &frame);
    GetClientRect(window, &client);
    ClientToScreen(window, &origin);
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CAPTION_BUTTON_BOUNDS, &buttons,
                                        sizeof(buttons))) &&
        buttons.right > buttons.left) {
        out[1] = std::max<LONG>(0, client.right - (frame.left + buttons.left - origin.x));
        out[2] = std::max<LONG>(0, frame.top + buttons.bottom - origin.y);
    } else {
        out[1] = MulDiv(138, GetDpiForWindow(window), 96);
        out[2] = metric(window, SM_CYCAPTION) + metric(window, SM_CYSIZEFRAME);
    }
}

// Godot's Windows position setter assumes a standard caption when converting
// the requested client origin to an outer rectangle. Use the actual insets for
// our windows, especially while a detached tab follows the desktop pointer.
extern "C" bool graffitty_window_frame_move(uint64_t handle, int dx, int dy) {
    HWND window = reinterpret_cast<HWND>(handle);
    if (!state(window) || IsZoomed(window) || IsIconic(window))
        return false;
    RECT frame;
    GetWindowRect(window, &frame);
    return SetWindowPos(window, nullptr, frame.left + dx, frame.top + dy, 0, 0,
                        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// Saved sizes describe the client area, including our custom caption. Godot's
// standard-caption adjustment would otherwise add that caption a second time.
extern "C" bool graffitty_window_frame_resize(uint64_t handle, int width, int height) {
    HWND window = reinterpret_cast<HWND>(handle);
    if (!state(window) || IsZoomed(window) || IsIconic(window) || width <= 0 || height <= 0)
        return false;
    RECT frame, client;
    if (!GetWindowRect(window, &frame) || !GetClientRect(window, &client))
        return false;
    return SetWindowPos(window, nullptr, 0, 0,
                        width + (frame.right - frame.left) - (client.right - client.left),
                        height + (frame.bottom - frame.top) - (client.bottom - client.top),
                        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

// DWM still owns these buttons and their non-client input (including Snap),
// but Godot's opaque swapchain can cover their glyphs.
//
// Expose their real bounds and interaction state so the canvas can paint them
// above its own surface.
namespace {
std::array<int32_t, 17> caption_state(HWND window, const Frame *frame_state) {
    std::array<int32_t, 17> out = {};
    out[13] = -1;
    if (!active(window, frame_state)) return out;
    TITLEBARINFOEX info = {};
    info.cbSize = sizeof(info);
    SendMessageW(window, WM_GETTITLEBARINFOEX, 0, reinterpret_cast<LPARAM>(&info));
    POINT origin = {};
    ClientToScreen(window, &origin);
    const int indices[] = {2, 3, 5}; // Minimize, maximize/restore, close.
    for (int i = 0; i < 3; ++i) {
        const int index = indices[i];
        const RECT &rect = info.rgrect[index];
        if (info.rgstate[index] & 0x8000 /* STATE_SYSTEM_INVISIBLE */)
            continue;
        out[i * 4] = rect.left - origin.x;
        out[i * 4 + 1] = rect.top - origin.y;
        out[i * 4 + 2] = rect.right - rect.left;
        out[i * 4 + 3] = rect.bottom - rect.top;
    }
    out[12] = GetDpiForWindow(window);
    out[13] = frame_state->hover;
    out[14] = frame_state->pressed;
    out[15] = IsZoomed(window) != 0;
    out[16] = GetForegroundWindow() == window;
    return out;
}
} // namespace
