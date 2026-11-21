Use Flat 2D and Flat 3D with Push/Pull tabs and both session flight effects.
Populate tabs with identifiable terminal text. Switch tabs, create a tab, and
close the selected tab to return to a previously hidden one.

During a session switch, deliver a session-list refresh before the destination's
topology. Keep the departing capture pending; the old topology must not start
the new session flight or cancel it when the real destination arrives.

Delay the real owner's incoming terminal snapshots for longer than the depth
animation lasts. The previous view must stay visible and the camera must stay
still. The previous terminal must continue receiving output and repainting while
waiting. Do not freeze an empty destination capture or spend the reveal interval
while the content is unavailable.

Claim the destination layout before preparing its arrival. Delay the layout
acknowledgement and the resized terminal scene independently: a painted snapshot
with the old grid must not release preparation. Deliver the new topology both
before and after its claim acknowledgement; either order must proceed as soon as
both arrive, without waiting for a claim timeout. After the claim, grid and pane
geometry agree across preparation frames, calculate arrival without an additional
fixed quiet-time delay. Recheck geometry after drawing the arrival.

Release scene delivery. Wait for the native terminal to repaint and for the
arrival to draw. Arrival must already contain the destination's text when the
camera/reveal clock starts. Inspect actual GPU textures and midpoint frames.
Both sides of Push/Pull, and the zoom arrival of Fly away, use live terminal
textures: produce new shell output while the transition is held at its midpoint
and verify those pixels update before handoff. The departing tab stays subscribed
until its live layer is gone; all live rendering holds and its background
subscription are released after landing. Closing its shell during departure must
retain its final pixels safely. Both session effects freeze the departing glyphs.
Fly away and in also freezes the arriving glyphs: produce new shell output while
holding its arrival at the midpoint and verify its retained pixels stay unchanged.
After landing, the live terminal must show that new output. Interrupt a zoom
arrival and verify its retiring image freezes before its source is hidden.
At completion, verify the live-content handoff and released viewport holds.

Repeat both session flight effects with a destination pane outside the departing camera's
crop, using a different terminal size from the initial viewport. Paint static
colored markers in that pane. Compare the fully assembled arrival with every
frame through the live handoff and the settled destination: marker positions,
sizes and pixels must match, with no blank frame. Preparation must size the full
terminal even off camera. Keep its rendering active through the flight; release
the capture crop at landing and retain the assembled image until the normal
crop has repainted. Run `uv run tests/godot/test_session_effects.py --case landing
--evidence <fresh-short-directory>` for the rendered Flat 2D/3D regression.

Type through the native key path while each arrival is held at its midpoint.
Particles must originate at the displayed cursor with the pane's current scale,
and 2D effects must stay visible. The 3D pane shader and cursor projection share
the same transform, including changes to camera framing. Frozen glyph arrivals
have no live cursor presentation and must not emit at the hidden landing position.
