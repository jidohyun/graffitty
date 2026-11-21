# Touch controls

Use the key strip above the soft keyboard and the floating keyboard, text-size and microphone buttons.

## Keys and gestures

- **Ctrl / Alt / Shift:** tap to cycle off → next key → locked.
- **Arrows:** hold to repeat.
- **Slide the strip sideways:** reach more keys or bring them closer to your thumb. Past either end it stretches and springs back.
- **Shift, then drag on a terminal:** select text, including in mouse-aware apps.
- **Copy / Paste:** use the terminal clipboard actions.
- **Dialog text:** long-press or double-tap to select, then use Android's Copy toolbar.
- **Lists and menus:** drag to scroll; pulling past either end stretches and springs back.
- **Microphone:** see [dictation](dictation.md).

## Choose controls

In `client.toml`:

```toml
[touch]
keys = ["copy", "paste", "escape", "tab", "ctrl", "alt", "shift",
        "left", "down", "up", "right", "home", "end", "page_up", "page_down"]
buttons = ["keyboard", "text_size", "microphone"]
```

- Reorder entries to change their order.
- Remove entries to hide controls.
- Omit a list to keep its defaults.
- Drag floating buttons to position them.

## Custom keys

```toml
[touch]
keys = [
  "escape", "tab", "ctrl", "alt", "shift",
  { label = "⌃A", action = "TogglePrefix" },
  { label = "|", action = "SendText", text = "|" },
]
```

- `action` uses a [key-binding action](../customize/configuration-keyboard.md#change-a-shortcut).
- `SendText` also needs `text`.
- `SetEffectsProfile`, `ToggleEffect`, `OpenPanel` and `Ignore` cannot be touch keys.

## Desktop preview

Launch with `--touch-controls` or set `GRAFFITTY_TOUCH_CONTROLS=1`.

