# Windows pane titles

Run the normal-token and elevated-token cases separately. Each case verifies
the actual shell token, PowerShell 5.1 and 7, with shell integration both enabled
and disabled. Do not infer elevation from an Administrator label or a launcher.

1. Start a private pane. Its initial title must be its working directory,
   never an empty title, a startup marker, or a localized `Administrator:` alone.
2. Set `[Console]::Title` to a short Unicode title. Verify both the owner title
   and the visible pane header, and capture the window.
3. Set a different title through OSC 2. Verify the same title in both places.
4. Pin the pane title, change the underlying application title, and confirm
   that the pin remains. Clear the pin and verify the current application title.
5. Clear the application title and verify that the directory title returns.
6. Confirm that the original shell PID survives every title change. Retain
   per-phase captures and exact expected/actual title receipts.

The elevated adapter must be launched from an already elevated terminal. The
normal adapter must use a normal desktop token. The adapters never elevate
themselves. Unicode title output is separate from Korean IME input acceptance.
