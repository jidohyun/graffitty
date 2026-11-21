#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <cstdint>

extern "C" bool graffitty_desktop_blur(uint64_t handle, bool enabled, int radius, uint64_t) {
    if (!handle || ![NSThread isMainThread] || radius < 0)
        return false;
    using Connection = void *(*)();
    using SetBlur = OSStatus (*)(void *, NSInteger, int);
    static auto connection =
        reinterpret_cast<Connection>(dlsym(RTLD_DEFAULT, "CGSDefaultConnectionForThread"));
    static auto set_blur =
        reinterpret_cast<SetBlur>(dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius"));
    if (!connection || !set_blur)
        return false;
    NSWindow *window = (__bridge NSWindow *)(void *)handle;
    return set_blur(connection(), window.windowNumber, enabled ? radius : 0) == noErr;
}
