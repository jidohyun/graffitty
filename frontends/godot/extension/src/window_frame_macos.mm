#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// GodotButtonView updates its shared _mouseInGroup: state on enter/exit, but
// only invalidates the buttons' drawing.
//
// AppKit caches that state in each native widget; mouseEnteredOrExited
// refreshes it without pressing the button or changing its target/action.
// Without this, only the hovered green button refreshes itself on current
// macOS.
using DisplayButtons = void (*)(id, SEL);
static DisplayButtons original_display_buttons;

// Godot restores an opaque native titlebar when it removes its custom traffic
// lights on entering fullscreen. The app already draws its own tab strip.
extern "C" void graffitty_window_fullscreen_content(uint64_t handle) {
    NSWindow *window = (__bridge NSWindow *)(void *)handle;
    if (!window || ![NSThread isMainThread] ||
        !(window.styleMask & NSWindowStyleMaskFullScreen))
        return;
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
}

static void display_buttons(id object, SEL selector) {
    original_display_buttons(object, selector);
    SEL refresh = sel_registerName("mouseEnteredOrExited");
    for (NSView *button in [(NSView *)object subviews]) {
        if ([button isKindOfClass:[NSButton class]] && [button respondsToSelector:refresh]) {
            ((void (*)(id, SEL))objc_msgSend)(button, refresh);
            [button setNeedsDisplay:YES];
        }
    }
}

extern "C" void graffitty_install_window_frame() {
    if (original_display_buttons || ![NSThread isMainThread])
        return;
    Class cls = objc_getClass("GodotButtonView");
    if (!cls || !class_getInstanceMethod(cls, sel_registerName("_mouseInGroup:")))
        return;
    Method method = class_getInstanceMethod(cls, sel_registerName("displayButtons"));
    if (!method)
        return;
    original_display_buttons = (DisplayButtons)method_getImplementation(method);
    // Change only Godot's title-button container, never an AppKit class.
    if (!class_addMethod(cls, sel_registerName("displayButtons"), (IMP)display_buttons,
                         method_getTypeEncoding(method))) {
        method_setImplementation(method, (IMP)display_buttons);
    }
}
