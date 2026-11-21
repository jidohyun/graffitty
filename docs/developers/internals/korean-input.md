# Korean input

The macOS extension preserves committed Korean text and the command key that follows it.
The investigation below concerns Godot 4.7.2 and the project's native shim.

## Current input path

1. Let AppKit process composition and commit text.
2. Record whether AppKit requested a command such as Enter or cursor movement.
3. Forward the physical command after the commit only when the input method left it unconsumed.

Candidate-confirmation Enter must stay with the input method. Replaying every key
that ends composition would submit Japanese input unexpectedly.

## Shell suggestions

Committed Unicode ends a Rust output batch. Later keys wait for terminal feedback
or a bounded 150 ms timeout. This gives zsh autosuggestions a chance to refresh;
feedback is not a formal shell acknowledgement.

## Verify the right boundary

`tests/platform/macos/test_macos_terminal_alt.py` checks native callback ordering.
A simulated callback pass does not establish live Korean IME acceptance.
The shared world kit also projects the cursor anchor for the native candidate window.

## Detailed evidence

[Korean input — source notes and results](korean-input-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
