Run the `chromium-clipboard` workspace scenario against a disposable server and
browser. Focus the actual browser surface before injecting keyboard shortcuts.
Set the Android clipboard to Unicode test text, select the DOM field, and paste
through the frontend's Ctrl+V path. Copy a different DOM selection back to the
Android clipboard; cut another selection and require both removal and a browser
input event. Copying a password field must leave the clipboard unchanged.
After a rejected oversized paste, the next clipboard shortcut must immediately
clear the displayed input error, even if the server sends no new browser state.
Restore the original clipboard before reporting assertions. Retain the runtime
checks, logs, screenshots, and fixture cleanup. This checks plain text through
the Godot input path; it does not establish native Android IME composition,
rich MIME data, website-defined clipboard handlers, or file transfer.
