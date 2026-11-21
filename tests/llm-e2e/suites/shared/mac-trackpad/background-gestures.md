# Gesture routing and keyboard focus

On macOS, focus the Graffitty window before pinching, then move both fingers
without lifting to pan. Native pinch recognition requires an active window;
unfocused pinch is not supported. Ordinary two-finger scrolling over an inactive
window should continue to work.

The replay uses two native windows and sends the AppKit bridge's gesture payload
through `Input.parse_input_event`, including its target window and physical pixel
coordinates, checking navigation, focus ownership and active/idle frame limits.
It verifies routing of an already-delivered gesture, not hardware pinch delivery
to an inactive application. Injected events must target their intended window
without changing keyboard focus. After the gesture, that window should return
to its inactive frame limit.

Run `python3 tests/platform/macos/test_macos_trackpad.py` for the native pinch lifecycle,
continuous pan, release, and cancellation. Physical trackpad checks should focus
the window first; synthetic input cannot establish native event delivery.
