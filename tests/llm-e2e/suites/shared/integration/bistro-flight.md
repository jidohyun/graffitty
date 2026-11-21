# Bistro camera and pane arrival

This specification applies to every required frontend, using the same Bistro
assets and authored terminal placements. Run in an isolated test
session. The automated driver must inject application actions rather than
desktop mouse or keyboard events. Never attach to a personal terminal session.

The Godot adapter captures all fourteen sessions across the nine authored destinations and frame sequences for
the 14-to-13 flight and interrupted return, with camera telemetry and live shell
identities. Review its PNGs under the isolated cache directory as well as its
numeric assertions. On Windows use the interactive desktop renderer.

## Open the real Bistro

1. Start the prototype in offscreen mode and capture the first rendered frame.
2. Confirm recognizable Bistro streets and buildings and the authored terminal placement.
   A colored cube or a photograph standing in for Bistro is a failure.
3. Create fourteen live sessions. Record each pane's session ID and shell PID.
4. Visit each session and capture its rendered view. Require distinct camera poses
   within the authored destination list, a visible terminal, and no error
   diagnostics. After the last authored destination, sessions wrap back to the first
   destination in order while retaining their own independent shell identities.

## Preserve a pinched camera view

1. At session 1, zoom 1.25 times at an off-center point on the terminal.
2. Record the world point under the gesture anchor before and after. It stays
   under the same point unless a documented boundary limits the movement.
3. Switch to session 2. Record the entire flight at a fixed timestep, with camera
   pose and viewport telemetry beside every rendered sample.
4. Session 2 retains its own original view. Returning to session 1 restores session 1's
   zoom and pan without a last-frame jump. Shell PIDs remain unchanged.

## Inspect session 14 to 13 arrival

1. Select session 14, wait for the view to settle, then select session 13.
2. Capture the entire transition, including frames immediately before and
   after the live terminal replaces the incoming transition representation.
3. The incoming terminal background follows Godot's panel fade while its glyph
   chunks assemble along their configured paths. The background remains on the
   terminal sheet; require no added vertical slide or sudden one-frame arrival,
   even when Bistro geometry crosses it.
4. Check rendered pixels as well as opacity telemetry. A correct number in a
   state dump does not establish that a fade is visible.
5. The title, pane edges, terminal glyphs, and final live surface align on the
   handoff frame. The bottom visible terminal row remains available.

## Interrupt the incoming pane

1. Begin session 13 to 14. During the incoming fade, select session 13 again.
2. The outgoing frame begins at the displayed camera pose and opacity. No
   one-frame disappearance, full-opacity flash, or reset to the old pose.
3. Let it settle, then type a unique command and confirm actual shell output.
4. Report PASS, FAIL, or BLOCKED with the capture directory, state trace, and
   exact failing frame. A headless logic-only run cannot establish visual PASS.
