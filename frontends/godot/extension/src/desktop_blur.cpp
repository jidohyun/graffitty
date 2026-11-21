#include <cstdint>

#ifdef _WIN32
#include <windows.h>
extern "C" bool graffitty_desktop_blur(uint64_t handle, bool enabled, int material, uint64_t) {
    using SetAttribute = HRESULT(WINAPI *)(HWND, DWORD, LPCVOID, DWORD);
    static HMODULE library = LoadLibraryW(L"dwmapi.dll");
    static auto set_attribute =
        library ? reinterpret_cast<SetAttribute>(GetProcAddress(library, "DwmSetWindowAttribute"))
                : nullptr;
    if (!handle || !set_attribute)
        return false;
    // DWMWA_SYSTEMBACKDROP_TYPE, available on Windows 11 build 22621+.
    int value = !enabled ? 1 : (material == 1 ? 2 : (material == 2 ? 4 : 3));
    return SUCCEEDED(set_attribute(reinterpret_cast<HWND>(handle), 38, &value, sizeof(value)));
}
#elif defined(__linux__)
#include <dlfcn.h>
#include <algorithm>
#include <cmath>
#include <vector>
extern "C" bool graffitty_desktop_blur(uint64_t handle, bool enabled, int radius, uint64_t display_handle) {
    using Display = void;
    using Atom = unsigned long;
    static void *library = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (!library || !display_handle || !handle)
        return false;
    auto intern =
        reinterpret_cast<Atom (*)(Display *, const char *, int)>(dlsym(library, "XInternAtom"));
    auto change =
        reinterpret_cast<int (*)(Display *, unsigned long, Atom, Atom, int, int,
                                 const unsigned char *, int)>(dlsym(library, "XChangeProperty"));
    auto remove = reinterpret_cast<int (*)(Display *, unsigned long, Atom)>(
        dlsym(library, "XDeleteProperty"));
    auto flush = reinterpret_cast<int (*)(Display *)>(dlsym(library, "XFlush"));
    auto root =
        reinterpret_cast<unsigned long (*)(Display *)>(dlsym(library, "XDefaultRootWindow"));
    auto property =
        reinterpret_cast<int (*)(Display *, unsigned long, Atom, long, long, int, Atom, Atom *,
                                 int *, unsigned long *, unsigned long *, unsigned char **)>(
            dlsym(library, "XGetWindowProperty"));
    auto free_data = reinterpret_cast<int (*)(void *)>(dlsym(library, "XFree"));
    if (!intern || !change || !remove || !flush || !root || !property || !free_data)
        return false;
    auto display = reinterpret_cast<Display *>(display_handle);
    Atom blur = intern(display, "_KDE_NET_WM_BLUR_BEHIND_REGION", true);
    if (!blur)
        return false;
    if (enabled) {
        Atom supported = intern(display, "_NET_SUPPORTED", true), type = 0;
        int format = 0;
        unsigned long count = 0, remaining = 0;
        unsigned char *data = nullptr;
        bool available = false;
        if (supported &&
            property(display, root(display), supported, 0, 4096, false, 4 /* XA_ATOM */, &type,
                     &format, &count, &remaining, &data) == 0 &&
            type == 4 && format == 32 && data) {
            auto atoms = reinterpret_cast<Atom *>(data);
            for (unsigned long i = 0; i < count; ++i)
                available |= atoms[i] == blur;
        }
        if (data)
            free_data(data);
        if (!available)
            return false;
    }
    if (enabled) {
        // KWin blurs the supplied region even where the window alpha is zero.
        // XChangeProperty takes native longs for format-32 CARDINAL values.
        std::vector<unsigned long> region;
        if (radius > 0) {
            auto geometry = reinterpret_cast<int (*)(Display *, unsigned long, unsigned long *,
                    int *, int *, unsigned int *, unsigned int *, unsigned int *, unsigned int *)>(
                    dlsym(library, "XGetGeometry"));
            unsigned long drawable;
            int x, y;
            unsigned int w, h, border, depth;
            if (!geometry || !geometry(display, handle, &drawable, &x, &y, &w, &h, &border, &depth))
                return false;
            auto r = std::min<unsigned long>(radius, std::min(w, h) / 2);
            for (unsigned long row = 0; row < r; ++row) {
                double dy = r - row - 0.5;
                auto inset = static_cast<unsigned long>(std::lround(r - std::sqrt(r * r - dy * dy)));
                region.insert(region.end(), {inset, row, w - 2 * inset, 1,
                                             inset, h - 1 - row, w - 2 * inset, 1});
            }
            region.insert(region.end(), {0, r, w, h - 2 * r});
        }
        change(display, handle, blur, 6 /* XA_CARDINAL */, 32, 0 /* PropModeReplace */,
               reinterpret_cast<const unsigned char *>(region.data()), static_cast<int>(region.size()));
    } else
        remove(display, handle, blur);
    flush(display);
    return true;
}
#endif
