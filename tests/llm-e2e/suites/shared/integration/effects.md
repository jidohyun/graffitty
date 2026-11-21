For Godot Windows use `tests/platform/windows/windows_feature_acceptance.py --suite effects
--project <frozen-project> --evidence <fresh-directory>`. Its four independently
invocable `windows_effects_e2e.py` modes are controls (default), `--pixels`,
`--camera`, and `--isolation`; rerun only the affected mode when repairing a gap.
The actual View > Effects dialog edits a validated draft. Rendered tests run on
a private Windows desktop and drive a real raw ConPTY fixture. Inspect both
dialog scroll positions, paired trail/particle captures, typing camera captures,
and the unrelated native window. Require exact PTY input, bounded particles,
identical terminal-content pixels after decay, and an independent ray/plane
caret projection error below 0.75 pixels.
Do not use desktop input or the OS clipboard.

## Inspect cursor trails from terminal output

Compare each `trail-{smear,blaze,lightning}-peak.png` with its matching `-after.png`. The real terminal application moves its cursor through CUP sequences while the typing camera is disabled. Require visibly different trail styles at the projected terminal cell, a stable terminal sheet/camera, and a clean final image after decay. A changing telemetry flag alone is insufficient. Hiding the application cursor must remove the trail, and no trail may jump between unrelated panes or windows.

## Inspect particle presets and configured typing camera

Compare each `particles-{dots,fireworks,flames,glitter,sparks}.png` against its corresponding `-off.png`. The preset must contribute visible pixels at the actual caret and removing it must remove only those pixels. Check that the particle count remains bounded and switching preset does not restart the PTY.

Compare `typing-configured-peak.png` and `typing-configured-after.png`. With 50% intensity and a configured 2× maximum, the live camera reaches 1.5×. Godot's follow, lean and drift may move the caret on screen: require the independent camera-ray/terminal-plane inverse to recover its unchanged canvas position within 0.75 pixels, as recorded in `typing-projection.json`. The terminal title and content move together, and configured hold/decay restore the original view. Verify saved controls and rejected out-of-range inputs through the same frontend action path.

## Inspect Effects controls

Inspect the Effects dialog captures, opened through the actual View menu. Presets, trail style, intensity, parameter editor and Apply/Cancel must be readable and fit without overlap. The existing Input, Selection and Notifications controls must remain in their prior positions. Record exact images and observations in `visual-review.json`, keeping failed runs and their executable hashes.
