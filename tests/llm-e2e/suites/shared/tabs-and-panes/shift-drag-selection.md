# Shift+drag terminal selection

Use a disposable workspace and an isolated configuration. Preserve the person's
clipboard and restore it afterward. Record screenshots during selection and
compare copied text exactly, including spaces and Unicode.

## Mouse capture and selection

Run a terminal fixture that enables the alternate screen and SGR mouse reporting
(DEC modes 1000, 1002, 1003 and 1006; test each tracking mode), prints
`Alpha 한글 omega` and a second line, and records received mouse bytes to a
temporary file. An ordinary drag must deliver application mouse events.

Hold Shift before pressing the left mouse button. Drag across the printed text,
release, and copy with the configured terminal Copy shortcut. The native
selection must highlight the intended cells and the clipboard must match the
selected text. The application must receive no button, drag, or release reports
from this gesture. Repeat across lines and through the scrollback boundary.

## Modifiers and pane routing

Release Shift before releasing the mouse: selection must still finish locally,
without leaking the release to the app or leaving a stuck button. Repeat with
Shift+Control and Shift+Command over a hyperlink; no link should open. With
Shift+Alt, verify rectangular selection. Configure a different mouse bypass
modifier and custom mouse bindings that omit Shift: Shift+left must still select.

Test tiled and floating panes at normal and enlarged zoom, including a second
pane and switching tabs. Selection must remain in the pane where the press
started. Afterward an ordinary drag must still reach the application.

## Node forms and real applications

Repeat Shift+drag in the SystemOne question and log areas, a filter node,
and an available mouse-aware terminal application such as vim with `:set mouse=a`.
Node input, focused field, and graph configuration must not change while selecting.
Check an available Codex or Claude terminal too; selecting text must not submit
or modify its draft. Missing optional applications are recorded as untested.

Capture before/during/after views and exact clipboard comparisons. Report
PASS/FAIL/BLOCKED, with app names, mouse modes and layouts exercised. A spec or
headless assertion alone is not evidence of a rendered selection or clipboard
success. No paid model request is needed for this case.

Executable regression: `replays/shift-drag-selection.gd` runs a rendered,
mouse-reporting terminal with graph ports and graph editing active in overview.
It checks exact Unicode clipboard text, early Shift release, absence of leaked
mouse reports, unchanged graph selection, and subsequent ordinary dragging.
