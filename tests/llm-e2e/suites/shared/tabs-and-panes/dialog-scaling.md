# Dialog typography and display scaling

Open Rename Pane on a normal-density and a Retina/high-DPI display. The input,
hint, and buttons use 20-point text, matching the main pane title size. The dialog
uses the same display scale as its owner. Resize the window: text must not shrink
with the resolution. Move a native dialog between displays: its DPI scale updates.

Repeat with embedded dialogs (the Android UI path). Display scaling is applied
once, through the enclosing window. Newly created dialogs and dynamically added
fields inherit the same policy. An unexpected error dialog is a failure.

Dialog actions form a compact group aligned to the right. In a narrow/mobile
dialog, complete buttons wrap onto multiple rows and each row stays right aligned.
Cancel remains the last action and keeps keyboard focus while resizing. Check all
supported languages, especially French: `Annuler` must stay on one line, never
leave its final `r` on another line. The window-close dialog's confirm action is
`Detach` (`연결만 끊기` in Korean). Changing the language or rotating must
preserve button bounds, readable text, and working Cancel/Detach actions.
Local window-close confirmations additionally show `Kill Server`
(`서버 강제 종료`); verify the three-action layout too. Remote dialogs must never
offer that action.

The fast replay checks native/embedded scaling, font sizes, resize invariance,
the DPI-change handler, and the shared policy. Moving between physical monitors
with different DPI remains a hardware check.
