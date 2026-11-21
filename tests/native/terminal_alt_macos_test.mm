#import <AppKit/AppKit.h>
#include <cassert>
#include <cstdio>

extern "C" void graffitty_install_ime_shim();
extern "C" void graffitty_set_terminal_key_focus(void *, uint64_t, bool);

// Exercise the actual hooks against Godot's native input contract: enqueue a
// physical key, then let interpretKeyEvents supply text or start composition.
@interface GodotContentView : NSView
@property NSString *marked;
@property NSMutableArray<NSString *> *text;
@property NSMutableArray<NSEvent *> *keys;
@property NSUInteger interpreted;
@property BOOL koreanCommit;
@property NSMutableArray<NSString *> *delivery;
@property BOOL candidateConsumesEnter;
- (BOOL)hasMarkedText;
- (void)insertText:(id)text replacementRange:(NSRange)range;
- (void)setMarkedText:(id)text selectedRange:(NSRange)selected replacementRange:(NSRange)range;
@end
@implementation GodotContentView
- (BOOL)hasMarkedText { return self.marked.length != 0; }
- (void)setMarkedText:(id)text selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    self.marked = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
}
- (void)insertText:(id)text replacementRange:(NSRange)range {
    [self.text addObject:text];
    [self.delivery addObject:[@"text:" stringByAppendingString:text]];
    self.marked = @"";
}
- (void)keyDown:(NSEvent *)event {
    if (![self hasMarkedText]) {
        [self.keys addObject:event];
        [self.delivery addObject:[NSString stringWithFormat:@"key:%hu",event.keyCode]];
    }
    [self interpretKeyEvents:@[event]];
}
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
    self.interpreted++;
    for (NSEvent *event in events) {
        if (self.koreanCommit) {
            // A replay entering the input method a second time can emit the
            // same final syllable even when its characters string is empty.
            [self insertText:@"글" replacementRange:NSMakeRange(NSNotFound, 0)];
            if (!self.candidateConsumesEnter) [self doCommandBySelector:@selector(moveRight:)];
            continue;
        }
        if (event.keyCode == 14 && (event.modifierFlags & NSEventModifierFlagOption))
            [self setMarkedText:@"´" selectedRange:NSMakeRange(0, 1) replacementRange:NSMakeRange(NSNotFound, 0)];
        else
            [self insertText:event.characters replacementRange:NSMakeRange(NSNotFound, 0)];
    }
}
- (void)doCommandBySelector:(SEL)command {}
@end

static NSEvent *key(NSWindow *window, unsigned short code, NSEventModifierFlags flags, NSString *text) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:0 windowNumber:window.windowNumber context:nil characters:text
        charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        GodotContentView *view = [GodotContentView new];
        view.text = [NSMutableArray new];
        view.keys = [NSMutableArray new];
        view.delivery = [NSMutableArray new];
        window.contentView = view;
        graffitty_install_ime_shim();
        graffitty_set_terminal_key_focus((__bridge void *)window, 1, true);
        for (NSArray *item in @[@[@11, @"∫"], @[@3, @"ƒ"], @[@14, @"´"]]) {
            NSEvent *event = key(window, [item[0] unsignedShortValue], NSEventModifierFlagOption, item[1]);
            NSString *expected = [event charactersByApplyingModifiers:0];
            [view keyDown:event];
            assert(view.interpreted == 0 && !view.hasMarkedText);
            assert([view.text.lastObject isEqual:expected]);
            assert(view.keys.lastObject.modifierFlags & NSEventModifierFlagOption);
        }
        NSEvent *shifted = key(window, 11, NSEventModifierFlagOption | NSEventModifierFlagShift, @"ı");
        [view keyDown:shifted];
        assert([view.text.lastObject isEqual:[shifted charactersByApplyingModifiers:NSEventModifierFlagShift]]);
        // Commit a pending syllable before sending Alt+B, exactly once.
        [view setMarkedText:@"한" selectedRange:NSMakeRange(0,1) replacementRange:NSMakeRange(NSNotFound,0)];
        NSUInteger count = view.text.count, keys = view.keys.count;
        [view keyDown:key(window, 11, NSEventModifierFlagOption, @"∫")];
        assert([view.text[count] isEqual:@"한"] && view.text.count == count + 2);
        assert(view.keys.count == keys + 1 && !view.hasMarkedText);
        // Inactive viewports must not revoke another terminal's ownership.
        graffitty_set_terminal_key_focus((__bridge void *)window, 2, false);
        [view keyDown:key(window, 14, NSEventModifierFlagOption, @"´")];
        assert(view.interpreted == 0 && !view.hasMarkedText);
        // UI text fields retain normal Option characters and dead keys.
        graffitty_set_terminal_key_focus((__bridge void *)window, 1, false);
        [view keyDown:key(window, 11, NSEventModifierFlagOption, @"∫")];
        assert([view.text.lastObject isEqual:@"∫"] && view.interpreted == 1);
        [view keyDown:key(window, 14, NSEventModifierFlagOption, @"´")];
        assert(view.hasMarkedText && view.interpreted == 2);
        view.marked = @"";
        graffitty_set_terminal_key_focus((__bridge void *)window, 1, true);
        [view keyDown:key(window, 11, NSEventModifierFlagOption | NSEventModifierFlagCommand, @"∫")];
        assert(view.interpreted == 2);
        // Every terminal modifier chord commits once and forwards unchanged;
        // no shortcut name or user's shell mapping is part of this decision.
        for (NSNumber *code in @[@1, @8, @11, @0]) {
            [view setMarkedText:@"글" selectedRange:NSMakeRange(0,1) replacementRange:NSMakeRange(NSNotFound,0)];
            NSUInteger textsBefore = view.text.count, keysBefore = view.keys.count;
            NSUInteger interpretedBefore = view.interpreted;
            NSEvent *event = key(window, code.unsignedShortValue, NSEventModifierFlagControl, @"\x13");
            [view keyDown:event];
            assert(view.text.count == textsBefore + 1 && [view.text.lastObject isEqual:@"글"]);
            assert(view.keys.count == keysBefore + 1 && view.keys.lastObject == event);
            assert(view.interpreted == interpretedBefore && !view.hasMarkedText);
        }
        // Arrow delivers committed text before the physical navigation key.
        // Only the original event is interpreted; the replay is physical-only.
        [view setMarkedText:@"글" selectedRange:NSMakeRange(0,1) replacementRange:NSMakeRange(NSNotFound,0)];
        view.koreanCommit = YES;
        [view.delivery removeAllObjects];
        NSUInteger textsBefore = view.text.count, keysBefore = view.keys.count;
        NSUInteger interpretedBefore = view.interpreted;
        [view keyDown:key(window, 124, 0, @"\uF703")];
        assert(view.text.count == textsBefore + 1);
        assert(view.keys.count == keysBefore + 1 && view.keys.lastObject.keyCode == 124);
        assert(view.interpreted == interpretedBefore + 1);
        assert(([view.delivery isEqualToArray:@[@"text:글", @"key:124"]]));
        // A candidate-confirming Enter is consumed by the IME, not replayed.
        view.candidateConsumesEnter = YES;
        [view setMarkedText:@"글" selectedRange:NSMakeRange(0,1) replacementRange:NSMakeRange(NSNotFound,0)];
        keysBefore = view.keys.count;
        [view keyDown:key(window, 36, 0, @"\r")];
        assert(view.keys.count == keysBefore);
        puts("PASS native terminal Alt and IME");
    }
}
