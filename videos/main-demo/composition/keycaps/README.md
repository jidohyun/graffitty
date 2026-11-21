# Demo shortcut keycaps

SVG port of [Keyty's PBT renderer](https://github.com/keytyapp/Keyty/blob/e30e0644df03536a4169936c7e19a049229beb5b/Apps/Keyty/Sources/Keyty/Features/Visualizers/Keyboard/Renderers/PBT/PBTKeycapRenderer.swift), revision `e30e0644df03536a4169936c7e19a049229beb5b`.
Copyright (c) 2026 Serhii Bykov; [BSD-3-Clause](KEYTY-LICENSE.txt).

Uses the original 13px rim, 8px dish lift, 18/10px body/dish radii,
2px body inset, 2.5px press travel, key widths, and layered diagonal gradients.
Colors are adapted to neutral gray. Labels and symbols are outlined so SVGs do
not depend on fonts at playback. Regenerate on macOS with:

```sh
swift videos/main-demo/composition/keycaps/legends.swift > videos/main-demo/composition/keycaps/legends.json
python3 videos/main-demo/composition/keycaps/generate.py
```

`shortcuts.py` assembles each partial chord centered in one fixed frame near the
right edge. Modifiers appear 180ms apart; Enter matches the replay's action
frame. The full chord holds for 3 seconds then fades for 250ms. Starting another
shortcut immediately clears the previous chord. SVG is used in Studio; PNGs
rasterized by `rsvg-convert` preserve the same artwork in the delivery compositor.

A brief action label sits above each chord, including “Send to pane 2” above
`2` then `-`. Labels use frozen 24pt medium system-font outlines and share the
keycap's timing. The card extends upward so the keys retain their position.

Legends use Keyty’s 14pt/22pt medium system fonts and right alignment.
Chord stages share integer 60fps boundaries; the export uses frame-index
enables and repeats the stage image through its exact final frame.

The overlay now stays mounted as one clip. Exact GSAP switches replace the
inner images without decimal clip-window gaps. New keys appear over six frames
while existing keys recenter continuously and remain unpressed; adding Enter
does not release/re-press Command. The export uses the same sampled poses.

“Open command line” shows the prefix sequence: Control and A keycaps from the
recorded prefix keydown, then a plain comma (text, not a key) and `:` at the
recorded `:` keydown.

The filetree path-send example shows `2` then `-` in the same frame and style.
The minus key aligns with the captured send action; `2` makes the pane target
explicit. The original take's bare `-` sends to that same connected pane.
