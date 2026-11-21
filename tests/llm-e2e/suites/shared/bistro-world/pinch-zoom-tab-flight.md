# A pinch zoom survives a tab flight without a jump cut

Regression: after a pinch zoom, the flight to another wall looked wrong and its
last frame jumped to a different framing.

## Open Bistro

1. Launch from the repository root:

   ```sh
   mise run dev -- --shell=/bin/sh --tabs=1
   ```

2. Choose **View > World > Bistro** and wait for the camera to land.
   If the item is missing, report BLOCKED: the Bistro world is not installed.
3. Create the second tab. It must keep Bistro without reloading the
   world or switching to Flat.

## Pinch zoom a little

1. Over the terminal, pinch outward on the trackpad once, gently: about a
   quarter more zoom. Do not type.
2. Expected: the view zooms in smoothly and stays there.

## Switch tabs and watch the flight

1. Record the screen, then click the second tab in the tab bar.
2. Expected: the camera leaves the first wall and flies to the second in one
   continuous motion. Nothing snaps back to an unzoomed view on the way.
3. Expected: when it lands, the second tab retains its own original framing,
   without a final jump. Arrival overlaps departure; camera and scatter ease
   together through the final 500 ms and stop together. The first tab's pinch must not change the second tab.
4. Fill both terminals with coloured text and repeat. The terminal planes, pane
   backings and borders stay at their world locations as the camera leaves one
   wall and approaches the next. They must not travel with the camera like a
   screen overlay. Letters scatter from and settle onto those anchored planes.
   Longer camera routes delay arrival to keep its final landing synchronized with
   the actual camera endpoint. A layout or zoom retarget during flight must preserve
   that deadline.

## Verify continuity

1. Step through the recording frame by frame around the landing. No frame
   differs sharply from the next. The first transition frame retains the zoomed
   text resolution; there must be no single-frame blur.
2. Click the first tab: the flight must restore its pinched zoom in one motion.
3. Report PASS, FAIL or BLOCKED with the recording and a note of any frame that
   jumps.

Godot's `res://tests/scatter_camera_flight_smoke.gd` additionally captures native
frames during 1.6- and 3.2-second Bistro flights and checks the world anchors,
a mid-flight retarget, visible glyph movement during camera deceleration, and the
handoff to the live wall.
