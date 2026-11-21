For Godot on Windows, run `python tests/platform/windows/windows_private_replay.py --replay
tests/llm-e2e/suites/godot/integration/replays/custom-tools.gd --evidence
<new-directory>` against a frozen project. Do not send OS input or open the
custom handler.

Inspect `custom-quick-select-labels.png` directly. Require visible labels drawn
from the configured x/y alphabet over the intended ISSUE captures. Confirm exact
raw-PTY proof that normal labels only copy and uppercase labels paste digits.

Check modified pointer events resolve only the configured URL pattern and that
the recorded argv preserves spaces, dollar signs, backticks and semicolons as
literal argument text. A recorded command does not prove native OS launching.

Require PTY ioctl grid evidence for font sizes 1, 4 and 7, unchanged process
identity, and a readable restored terminal in `custom-tools-restored.png`.
Write a scoped `visual-review.json` referencing the exact executable hash.
