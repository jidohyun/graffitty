# Mobile demo recording

Record the production mobile UI directly with the desktop Godot engine:

```sh
mise exec -- python3 videos/main-demo/recording/android/desktop.py \
  --output videos/main-demo/assets/takes/android-demo/desktop-current
```

No phone, Android emulator, or Android APK is needed. The runner enables the
existing mobile interaction profile, connects the real remote client to an
isolated server, and drives the same `AndroidDemo.gd` touch scenario used on the
phone. It renders 1968 × 1968 application pixels at the unfolded phone's 2.625 UI
scale. The existing compositor adds the fold animation, system bars, captions,
and simulated Slack notification.

The recording uses a fixed 60 fps clock for gestures, camera motion, and scripted
agent progress, plus the saved human typing schedules. This is a mobile UI demo,
not a test of Android's IME, activity lifecycle, or device-specific rendering.

`record.py` remains the physical-device recorder. Both runners share the offline
shell and agent setup in `fixtures.py`. `--through-wiring` stops either runner
after the connection gestures for a short rehearsal.

Pane close-ups use a title-bar double tap. Double tap the same title again to
return to the overview before focusing the next pane. Setup frames the drag route, then centers the completed three-node group once.
Subsequent navigation uses the native fit/return toggle and returns to that
centered overview. After prompting Codex, frame Codex and Claude together so
the completion handoff is visible. Once Claude receives it, and before Claude
reports the review findings, use a visible two-finger gesture to frame Claude
and Slack together. Keep that shared view through the findings, queued send and
delivery log.
Use the current expanded touch ports in this overview. The five output sockets
must span the pane edge at 44 logical pixels of separation. The delivery verifier
checks their spacing in the encoded phone chapter, preventing an older compact
take from being reused accidentally.

Keep the full opening single-pane recording, including the pointer approach and
split-button click. Do not trim to the agent launch beat: that removes the split
action and makes two panes appear without an explanation. The manager opening
must use the current stacked server cards, centered Graffitty logo, and sticky
Connection/Settings navigation. Authenticate both private servers off camera to
cache their OS artwork; tap the visible server card to connect.

Keep the connected manager tail to 0.2 seconds, capture preroll to 0.15 seconds,
and start the visible split after another 0.1 seconds. Preserve the click itself;
shorten replay waits rather than speeding up footage. The mobile tab strip must
reserve no desktop window-button space, even when captured on macOS.

The main demo omits the workspace-manager explanation. The recorder follows the
shortened detach/attach and Android narration directly. `prepare_manager.py`
keeps the complete current take, including the visible connection click, at 1×;
no static-hold cut or playback retiming is needed.
