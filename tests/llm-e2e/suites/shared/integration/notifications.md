For Godot on Windows, run `python tests/platform/windows/windows_private_replay.py --replay tests/llm-e2e/suites/godot/integration/replays/notifications.gd --evidence <new-directory>`. It opens the actual Terminal Bell controls (without an in-app notification viewer), records delivery in private helpers, and captures native bell pixels without producing OS notifications or sound.

Use a frozen build and a fresh evidence directory. Never invoke native notification/audio helpers, use the human clipboard or synthesize desktop input.

## Inspect notifications and activate the owning pane

Inspect the actual Terminal Bell controls, opened through the Terminal menu: visual bell duration/color and audible preference must be readable and fit without overlapping text. State-only visibility is insufficient.

Require exact OSC99 capability, alive, activation and close replies through the real raw PTY. The capability reply must precede DA1 when both probes occur in the same application write. Activating a notification after another tab gains focus must select the original live pane without replacing its PID. Replacement, expiry, consumed keys and closed-owner keys must reject stale activation. Headless delivery must not launch OS helpers.

## Inspect visual bell lifetime

Compare `bell-before.png`, `bell-peak.png`, `bell-middle.png` and `bell-after.png`. The actual terminal pixels must tint at the peak, diminish at the middle and return to baseline after the configured duration. The terminal contents, title and camera framing must remain readable and stable. A BEL terminating OSC9 must not trigger the bell callback. Enabling audible preference in headless replay records the request without producing sound.

Record inspected files and findings in `visual-review.json`. Keep every failed run and executable hash. Native OS permission prompts, system audio and native focus activation remain unverified by this private-desktop test.
