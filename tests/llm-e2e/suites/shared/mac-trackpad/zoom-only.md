# Zoom only

Open a terminal in Flat, then repeat in Flat 2D. Put the mouse over a recognizable glyph away from the screen center. Keep the mouse still. Pinch outward, then inward, intending only to zoom. Try both a symmetric pinch and moving one finger while the other stays still.

The glyph under the mouse must remain there through every frame. The view must not drift with the raw finger midpoint. Reversing the pinch restores the original size and framing. There must be no jump when the gesture starts or ends, no duplicated magnification, and no terminal resize.

Retain a continuous recording and check mid-gesture frames, not only endpoints. Run `python3 -m unittest tests/platform/macos/test_macos_trackpad.py` to verify the actual AppKit filter rejects asymmetric midpoint drift, then the sibling rendered replay to verify viewport routing in both worlds. The replay drives the same native gesture payload; human finger intent still requires the physical trackpad steps above. Record physical execution as BLOCKED if no person performs it; do not report synthetic input as a physical trackpad test.
