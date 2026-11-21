For Godot Windows, run `python tests/platform/windows/windows_feature_acceptance.py --suite workspace-controls --project <frozen-project> --evidence <new-directory>` with `GRAFFITTY_TEST_SERVER` and `GRAFFITTY_CHROMIUM_HOST` set to the frozen owner and CEF helper. The fixture uses an isolated Windows station and clipboard, actual PowerShell quoting, Godot View controls, private CEF GPU frames and live resource samples. Review its monitor, browser, Messages, internal log, Overview and Fit captures. Compact Overview titles intentionally mask covered top rows without shifting the terminal grid; bottom content remains anchored.

Do not run another GPU fixture concurrently, take focus, use the OS clipboard, or attach personal sessions.

The fixture sends native file-drop events to a real raw PTY and compares every received byte, including quoting, Unicode and separator bytes. Godot file drops must not append a trailing separator. The command-like filename is literal data; it must not execute or add a submitting newline. Modal and chromium focus must suppress terminal drops.

Inspect `workspace-overview.png` and `workspace-fit.png`: the actual Sessions controls change the view, and repeated Fit restores the exact saved view. Check the JSON assertions for unchanged pane IDs and raw input; an attractive screenshot cannot replace those checks.

Inspect `monitor-dragged.png`: the monitor is an independent readable panel at the dragged position. It must show the correct live terminal process identity and peak memory, and keep following owner samples. Godot's monitor is a mod (docs/developers/automation-and-extensions/mods.md): it omits the interval and Select all / Copy selection / Resume updates buttons, and its text cannot be selected or copied. The monitor must block terminal wheel/native gestures only in its actual rectangle.

Inspect `messages-selectable-error.png` and `messages-open-log.png`: the rejected Unicode font path is readable in bounded retained history, selectable/copyable, and present in the actual private frontend log. The Open log button stays within the application. No unreadable labels, clipped controls, missing Unicode, or terminal input leaking from the dialog is acceptable.

Inspect `monitor-chromium-resources.png`: the focused Chromium has its own measured resource identity and a real running sample rather than the owner's shell values. Require the actual decoded chromium and RPC assertions as well as the image.

Record a separate `visual-review.json` with the executable hash, exact files inspected, PASS/FAIL per condition and any limitations. Headless native event replay does not establish physical Finder drag-and-drop or native macOS clipboard integration. Do not mark unavailable resource data as measured zero, or convert fixture/renderer failures into PASS.
