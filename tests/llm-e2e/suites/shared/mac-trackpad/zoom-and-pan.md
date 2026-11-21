# Zoom and pan

Repeat in Flat and Flat 2D. Start with the mouse over a recognizable glyph. Pinch to zoom while moving both fingers together. The imaginary zoom point begins at the mouse, then moves with the shared finger translation. The chosen glyph must track that point smoothly; the mouse itself stays still.

Without lifting, stop changing finger separation and keep moving both fingers. Panning must continue. Resume magnifying without translation: zoom must now happen around the moved imaginary point, with no snap back to the original mouse position. Combine shrinking and translation in the reverse direction. Finally lift both fingers and begin a new pinch: its anchor must start at the current mouse position.

Retain continuous video and inspect transitions between zoom, pan, and resumed zoom. Check every frame for drift or discontinuity and confirm the terminal grid and shell survive. The native AppKit lifecycle test and sibling rendered replay cover continuous pan, anchor retention, release/cancellation, and both rendering worlds. Synthetic replay is not physical trackpad execution; mark that manual portion BLOCKED unless performed by a person.
