# Fractional terminal scrolling

Fill scrollback with numbered, alternating coloured rows. Slowly scroll with two
fingers: the first small movement must move text, and stopping must allow a
partial row. Reverse direction without a dead zone. Inspect the top and bottom
edges for blank strips; select and copy text in partially visible rows. Scroll
to both boundaries and type: no fractional blank strip or displaced prompt may
remain. A device without scroll phases, such as a mouse wheel, stops at each
boundary; the pull past it is covered by `rubber-band`.
Repeat with multiple font sizes. Vim and other apps with alternate screens or
mouse reporting must keep whole-row app-controlled scrolling and fixed chrome.

The replay checks fractional offsets, distance, a rendered bottom edge, grid
stability, copying the exposed row, boundaries, real Vim isolation, typing reset,
font-independent distance and synthetic event-to-repaint timing (not physical
input-to-screen latency).
