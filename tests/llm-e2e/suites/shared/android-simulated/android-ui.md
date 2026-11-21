# Android client UI

Run desktop Godot with the Android interaction profile and touch-to-mouse emulation against an isolated server. Use the actual remote manager entry scene.

1. Connect, switch between server tabs with finger taps, and check that all mobile toolbar buttons appear.
2. Show a messages panel and dismiss it with a single finger tap.
3. Open Connections, check that the window is embedded, and close it by touch. Open and dismiss File/View/Help menus and About.
4. Check the keyboard and microphone float above the workspace, the normal keyboard uses a Lucide icon, and its tap bypasses trackpad capture. Drag the keyboard button by touch: it follows the finger without terminal input, rises above an open keyboard, returns when it closes, and stays on-screen on a folded screen.
5. Check no keyboard-switching or settings buttons remain. OS keyboard presentation requires Android device testing.
6. Tap Fit pane, then drag in the workspace. Navigation resumes without a held terminal mouse button.
7. Fail on every unexpected engine or script error, including errors inside the child client.

Repeat message dismissal and connection-form open/cancel in a 400-pixel portrait window. Every action must remain on-screen after resizing.
