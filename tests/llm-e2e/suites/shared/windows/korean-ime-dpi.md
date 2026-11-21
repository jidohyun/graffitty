# Korean IME and native windows at 150% scaling

Windows-only supplement to the shared suites. Use isolated D: state and evidence; do not alter personal profiles. Report each shell separately.

## Verify the physical desktop setup

Record Windows display scaling (150%), display resolution, Korean IME selection, Godot renderer and dev build identity. Use an actual visible desktop window. Do not change layout scaling or redesign typing zoom to satisfy this case.

## Compose Korean through the IME

In separate PowerShell 5.1 and 7 panes, use physical Korean IME composition to enter 한글 입력 테스트. Observe composition underline and candidate placement, commit once, backspace a composed syllable, switch to Latin input, and verify exact text without duplicates. Repeat in Neovim. Injecting finished Unicode strings does not pass this stage.

Record the exact Godot version. Godot 4.7.2 has an upstream Windows IME
regression that can turn this phrase into `글 력 트`: committed syllables disappear
even in a standalone `LineEdit`. See [Godot #123269](https://github.com/godotengine/godot/issues/123269)
and [the upstream fix](https://github.com/godotengine/godot/pull/123274).
This is a failure on that runtime, not a platform exception. Retain the failed
recording and rerun composition after changing the runtime. Native virtual-key
automation can reproduce it through the OS IME; it does not certify the separate
physical-keyboard and candidate-placement review.

## Exercise native focus and window chrome

Resize, maximize, restore and move the native Graffitty window. Drag a tab into a new native window and back, checking PID continuity. Open a live Chromium pane externally, move that window, return to the pane and verify the same chromium session. Check focus, Ctrl+C, clipboard and window controls on the interactive desktop.

## Review scaling and camera behavior

Review mid-drag and final frames for correct hit targets, legible glyphs and correctly placed IME candidates. Where the demo requires it, disable camera zoom, pane zoom and tilt; retain the known physical-pixel layout model. Record evidence paths and distinguish synthetic replay checks from physical-input review.
