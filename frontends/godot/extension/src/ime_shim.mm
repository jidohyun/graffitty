#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// This is deliberately a narrow bridge around Godot 4's macOS text-input
// client.
//
// Godot drops the application-owned key when a Korean IME commits a syllable,
// even though AppKit has already asked the view to perform that key's
// command.
//
// We let Godot process the original event first (so insertText queues the
// committed Unicode), then replay the same physical key once.

using KeyDownFn = void (*)(id, SEL, NSEvent *);
using InsertTextFn = void (*)(id, SEL, id, NSRange);
using CommandFn = void (*)(id, SEL, SEL);
using InterpretFn = void (*)(id, SEL, NSArray<NSEvent *> *);
using MarkedTextFn = void (*)(id, SEL, id, NSRange, NSRange);

static KeyDownFn original_key_down = nullptr;
static InsertTextFn original_insert_text = nullptr;
static CommandFn original_command = nullptr;
static InterpretFn original_interpret = nullptr;
static MarkedTextFn original_marked_text = nullptr;
static char terminal_owner_key, marked_text_key;
static thread_local bool terminal_alt = false;
static thread_local bool physical_only = false;
static thread_local bool ime_composition_before = false;
static thread_local bool ime_text_committed = false;
static thread_local SEL ime_command = nullptr;
static bool installed = false;

static bool is_motion(unsigned short key) {
    return key == 123 || key == 124 || key == 125 || key == 126 || key == 115 || key == 119 ||
           key == 116 || key == 121;
}

static bool command_matches(SEL command, unsigned short key) {
    if (!command)
        return false;
    NSString *name = NSStringFromSelector(command);
    if (key == 36 || key == 76) {
        return [name isEqualToString:@"insertNewline:"] ||
               [name isEqualToString:@"insertLineBreak:"] ||
               [name isEqualToString:@"insertNewlineIgnoringFieldEditor:"];
    }
    if (key == 48) {
        return [name isEqualToString:@"insertTab:"] || [name isEqualToString:@"insertBacktab:"];
    }
    if (key == 53) {
        return [name isEqualToString:@"cancel:"] || [name isEqualToString:@"cancelOperation:"];
    }
    if (key == 51 || key == 117) {
        return
            [name isEqualToString:@"deleteBackward:"] || [name isEqualToString:@"deleteForward:"];
    }
    return false;
}

// Commit pending preedit before application-owned modifier chords. Godot's
// insertText path clears the marked state before the physical key is queued.
static void commit_terminal_marked(id self) {
    if (![(id)self hasMarkedText]) return;
    NSString *marked = objc_getAssociatedObject(self, &marked_text_key);
    if (marked.length)
        original_insert_text(self, @selector(insertText:replacementRange:), marked,
                             NSMakeRange(NSNotFound, 0));
}

static void shim_key_down(id self, SEL selector, NSEvent *event) {
    // Keep native Option text entry in editors and other controls. Only the
    // terminal's actual input owner opts into terminal Alt semantics.
    const bool terminal = objc_getAssociatedObject([(NSView *)self window], &terminal_owner_key);
    // Commit before forwarding any terminal Control/Command chord, without
    // assigning meaning to individual shortcuts. Navigation remains with the
    // input method until it commits and returns the command to the application.
    if (terminal && (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand))) {
        commit_terminal_marked(self);
        const bool previous = physical_only;
        physical_only = true;
        original_key_down(self, selector, event);
        physical_only = previous;
        return;
    }
    const bool alt = terminal &&
                     (event.modifierFlags & NSEventModifierFlagOption) &&
                     !(event.modifierFlags & NSEventModifierFlagCommand);
    if (alt) {
        commit_terminal_marked(self);
        // Ask the current keyboard layout for Shift/Caps-aware text without
        // Option's symbols or dead keys. Retain Option on the physical event.
        NSString *text = [event charactersByApplyingModifiers:
            event.modifierFlags & ~(NSEventModifierFlagOption | NSEventModifierFlagControl |
                                    NSEventModifierFlagCommand)];
        NSEvent *plain = [NSEvent keyEventWithType:event.type location:event.locationInWindow
            modifierFlags:event.modifierFlags timestamp:event.timestamp windowNumber:event.windowNumber
            context:nil characters:text ?: @"" charactersIgnoringModifiers:event.charactersIgnoringModifiers
            isARepeat:event.isARepeat keyCode:event.keyCode];
        const bool previous = terminal_alt;
        terminal_alt = true;
        original_key_down(self, selector, plain ?: event);
        terminal_alt = previous;
        return;
    }
    ime_composition_before = [(id)self hasMarkedText];
    ime_text_committed = false;
    ime_command = nullptr;
    original_key_down(self, selector, event);

    const unsigned short key = [event keyCode];
    if (ime_composition_before && ime_text_committed && ime_command &&
        (is_motion(key) || command_matches(ime_command, key))) {
        NSEvent *replay = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                           location:[event locationInWindow]
                                      modifierFlags:[event modifierFlags]
                                          timestamp:[event timestamp]
                                       windowNumber:[event windowNumber]
                                            context:nil
                                         characters:@""
                        charactersIgnoringModifiers:@""
                                          isARepeat:[event isARepeat]
                                            keyCode:key];
        if (replay) {
            // Empty characters do not prevent input methods from responding
            // to a physical keycode. Replay only Godot's physical-key path.
            const bool previous = physical_only;
            physical_only = true;
            original_key_down(self, selector, replay);
            physical_only = previous;
        }
    }
    ime_command = nullptr;
    ime_text_committed = false;
}

static void shim_insert_text(id self, SEL selector, id text, NSRange range) {
    ime_text_committed = true;
    original_insert_text(self, selector, text, range);
}

static void shim_command(id self, SEL selector, SEL command) {
    ime_command = command;
    original_command(self, selector, command);
}

static void shim_interpret(id self, SEL selector, NSArray<NSEvent *> *events) {
    if (physical_only) return;
    if (!terminal_alt) {
        original_interpret(self, selector, events);
        return;
    }
    // Give the IME bridge the text for the physical key Godot already queued.
    // The bridge joins the two and preserves modifiers.
    //
    // AppKit's Option interpretation would start a dead key or insert a symbol.
    for (NSEvent *event in events) {
        NSString *text = event.characters;
        if (text.length && [text characterAtIndex:0] >= 32 &&
            [text characterAtIndex:0] != 127 &&
            !([text characterAtIndex:0] >= 0xF700 && [text characterAtIndex:0] <= 0xF8FF))
            original_insert_text(self, @selector(insertText:replacementRange:), text,
                                 NSMakeRange(NSNotFound, 0));
    }
}

static void shim_marked_text(id self, SEL selector, id text, NSRange selected, NSRange replacement) {
    NSString *plain = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
    objc_setAssociatedObject(self, &marked_text_key, plain, OBJC_ASSOCIATION_COPY_NONATOMIC);
    original_marked_text(self, selector, text, selected, replacement);
}

extern "C" void graffitty_set_terminal_key_focus(void *handle, uint64_t owner, bool active) {
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window)
        return;
    NSNumber *current = objc_getAssociatedObject(window, &terminal_owner_key);
    if (active)
        objc_setAssociatedObject(window, &terminal_owner_key, @(owner), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    else if (current.unsignedLongLongValue == owner)
        objc_setAssociatedObject(window, &terminal_owner_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static bool replace_method(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method)
        return false;
    *original = method_getImplementation(method);
    // interpretKeyEvents is inherited from NSResponder. Add an override on
    // GodotContentView rather than changing all AppKit text clients.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
    return true;
}

// Godot's tracking area is active only while its view is first responder.
// Supplement it for inactive windows without activating them or synthesizing
// keyboard focus. The normal Godot handlers still own coordinate conversion.
@interface GraffittyInactivePointerTracker : NSObject
@property(nonatomic, weak) NSView *view;
@end
@implementation GraffittyInactivePointerTracker
- (void)mouseEntered:(NSEvent *)event {
    if (self.view.window && !self.view.window.isKeyWindow)
        [self.view mouseEntered:event];
}
- (void)mouseExited:(NSEvent *)event {
    if (self.view.window && !self.view.window.isKeyWindow)
        [self.view mouseExited:event];
}
- (void)mouseMoved:(NSEvent *)event {
    if (self.view.window && !self.view.window.isKeyWindow)
        [self.view mouseMoved:event];
}
@end

static char inactive_tracker_key;
static void install_inactive_tracking(NSView *view, Class godot_class) {
    if ([view isKindOfClass:godot_class] && !objc_getAssociatedObject(view, &inactive_tracker_key)) {
        GraffittyInactivePointerTracker *tracker = [GraffittyInactivePointerTracker new];
        tracker.view = view;
        objc_setAssociatedObject(view, &inactive_tracker_key, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSTrackingArea *area = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                         NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved
                   owner:tracker userInfo:nil];
        [view addTrackingArea:area];
    }
    for (NSView *child in view.subviews)
        install_inactive_tracking(child, godot_class);
}

extern "C" void graffitty_install_ime_shim() {
    Class cls = objc_getClass("GodotContentView");
    if (!cls)
        return;
    // Called when each terminal is ready, including terminals in new windows.
    for (NSWindow *window in NSApp.windows)
        install_inactive_tracking(window.contentView, cls);
    if (installed)
        return;
    // Preflight every selector before changing any IMP. A future Godot
    // refactor must result in a complete no-op, never a half-installed hook.
    if (!class_getInstanceMethod(cls, @selector(keyDown:)) ||
        !class_getInstanceMethod(cls, @selector(insertText:replacementRange:)) ||
        !class_getInstanceMethod(cls, @selector(doCommandBySelector:)) ||
        !class_getInstanceMethod(cls, @selector(interpretKeyEvents:)) ||
        !class_getInstanceMethod(cls, @selector(setMarkedText:selectedRange:replacementRange:)))
        return;
    if (!replace_method(cls, @selector(keyDown:), (IMP)shim_key_down, (IMP *)&original_key_down))
        return;
    if (!replace_method(cls, @selector(insertText:replacementRange:), (IMP)shim_insert_text,
                        (IMP *)&original_insert_text))
        return;
    if (!replace_method(cls, @selector(doCommandBySelector:), (IMP)shim_command,
                        (IMP *)&original_command))
        return;
    replace_method(cls, @selector(interpretKeyEvents:), (IMP)shim_interpret, (IMP *)&original_interpret);
    replace_method(cls, @selector(setMarkedText:selectedRange:replacementRange:),
                   (IMP)shim_marked_text, (IMP *)&original_marked_text);
    installed = true;
}
