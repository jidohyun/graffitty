# Korean input investigation

Recorded evidence; these results apply to the named runs and artifacts.

## Current project integration

Godot 4.7.2 drops composition-ending command keys. The native extension activates
IME, paints preedit in its own cell grid, records AppKit command selectors, and
replays only application-owned commands after committed text.

| Callback | Meaning |
| --- | --- |
| setMarkedText / OS_IME_UPDATE | Preedit and caret selection, not a normal key event |
| insertText | Unicode commit with keycode NONE |
| doCommandBySelector | Input method left a command for the application |

Korean Enter and Japanese candidate-confirmation Enter can both commit text;
only selector information distinguishes who owns the key. Inferring consumption
from empty preedit would send spurious Enter.

## The shim

Wrap GodotContentView keyDown to retain original physical identity and pre-composition
state. Wrap the selector callback, then replay with empty characters and scoped
`physical_only` to bypass interpretKeyEvents. Empty characters alone are insufficient.
Preserve modifiers and queue commit before replay; restore flags even with nested dispatch.

Terminal Control/Command chords commit marked text then forward physically.
Option uses terminal Alt conversion; ordinary text controls retain AppKit behavior.
The motion branch accepts the caret-movement command family, a deliberate terminal
policy that would need separate justification in a general engine.

## Duplicate syllables in zsh autosuggestions

Real zsh alone reproduced `한글글 잘됨`: old POSTDISPLAY was retained while
PENDING/KEYS_QUEUED_COUNT was nonzero, then an accept widget appended the stale suffix.
A local plugin patch was reverted. Rust's outgoing queue now ends a batch after
Unicode-only commits and waits for terminal text feedback or 150 ms before later keys.
Normal physical typing is not delayed. Multiple commit codepoints stay together;
disconnect discards the queue. Hidden nodes also run the timeout.

Output is feedback, not an application-ready acknowledgement; unrelated output
or timeout may release the wait. No shell-specific command/protocol was added.
The `--batch` test remains an expected failing reproduction, not a queue pass.

## Preedit and candidate placement

Use terminal font/fallback, ascent, padding, Unicode cell widths, dotted underline,
and trailing caret. `set_preedit` marks paint dirty. Suppress textless composing
physical letters under Kitty keyboard encoding while retaining commits and command keys.

Project local cursor → texture → wall UV → world → window pixels using KEEP_WIDTH.
`get_cursor_anchor_local`, `set_ime_anchor`, and `clear_ime_anchor` form the adapter.
A 3D world at 1600×1000 measured anchor (1337.2,834.8) vs painted corner (1338,835);
Flat's round trip matched texture pixels.

## Alternatives and verification limits

The local WezTerm fix addressed premature preedit clearing; kitty/GLFW separated
commit from replay; Ghostty's selector/consumption/layout handling informed this design.
These were local comparisons, not claims of upstream releases.
The engine proposal was rejected; the native shim remains engine-name dependent.
Pin/check the expected class/method at startup rather than silently losing replay.

`test_macos_terminal_alt.py` simulates callbacks. The zsh test drives the production
Rust queue against a real shell. Adapter tests cover output release, timeout, and
discard. None alone certifies live macOS Korean input-source UI acceptance.

## Commands and examples

### What the extension is allowed to do

```gdscript
DisplayServer.window_set_ime_active(true)
DisplayServer.window_set_ime_position(screen_position_of_the_cursor)
```

### What the extension is allowed to do

```gdscript
func _notification(what: int) -> void:
    if what == NOTIFICATION_OS_IME_UPDATE:
        var composing := DisplayServer.ime_get_text()
        var caret := DisplayServer.ime_get_selection()
        # draw `composing` into the terminal's own cell grid, underlined
```

### The shim

```objc
Class view = NSClassFromString(@"GodotContentView");
Method m = class_getInstanceMethod(view, @selector(doCommandBySelector:));
original = (void (*)(id, SEL, SEL))method_getImplementation(m);
method_setImplementation(m, imp_implementationWithBlock(^(id self, SEL command) {
    graffitty_record_ime_command(command);   // stash it for this key
    original(self, @selector(doCommandBySelector:), command);
}));
```

### The shim

```objc
static void shim_key_down(id self, SEL selector, NSEvent *event) {
    ime_composition_before = [(id)self hasMarkedText];
    original_key_down(self, selector, event);   // insertText: queues the syllable
    const unsigned short key = [event keyCode];
    // ... replay below
}
```

### The shim

```objc
NSEvent *replay = [NSEvent keyEventWithType:NSEventTypeKeyDown ...
                                 characters:@"" keyCode:key];
physical_only = true;
original_key_down(self, selector, replay);
physical_only = false;
```

### Duplicate syllables in zsh autosuggestions

```sh
python3 tests/server/zsh_ime_commit_smoke.py --autosuggestions /path/to/zsh-autosuggestions.zsh
python3 tests/server/zsh_ime_commit_smoke.py --autosuggestions /path/to/zsh-autosuggestions.zsh --batch
```

### Where the candidate window goes

```
get_cursor_anchor_local() -> Vector2    under the cursor cell, next line's top
set_ime_anchor(Vector2i)                where that landed on screen
clear_ime_anchor()                      back to deriving it from global_position
```
