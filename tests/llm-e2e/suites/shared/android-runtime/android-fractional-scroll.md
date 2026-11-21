# Fractional remote terminal scrolling

Populate scrollback with coloured rows. Precision scrolling should move on the
first small input, stop between rows and reverse without a dead zone. Inspect
the partially visible bottom row for blank space. The server grid stays fixed;
typing returns to the live prompt. App-controlled scrolling remains discrete.

The shared replay injects precision events into the production terminal viewport
with a real remote server and samples its rendered bottom edge.
