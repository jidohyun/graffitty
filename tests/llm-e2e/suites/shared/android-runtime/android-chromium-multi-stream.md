# Concurrent browser streams

Open three server browsers from the Android client as floating panes stacked
down the view, each tall enough that its page stays readable (a phone's title
and browser toolbar take about 114 of a pane's height; tiled slivers pause by
design), and animate each page at display cadence. Every browser must be
streaming, not paused, before measuring for fifteen seconds.

Each page draws full-frame noise, so the streams need real bandwidth. Every
stream must keep its hardware decoder (no restart) and none may freeze: each
presents at least 60% of the client's main-loop frame rate, capped at 20 fps.
No main-loop interval may exceed 250 ms. Record the P95 interval; the
absolute frame-time gate belongs to the single-stream hardware case. When the
link cannot carry every stream at full quality, the server lowers each
viewer's bitrate tier (`chromium flow bitrate share=` in the trace) instead of
freezing a stream; a frame lost beyond datagram repair is acknowledged by the
client and the next frame restarts the stream at a keyframe. Record each stream's presented and received frame rate,
delivered kbps and decoded size, plus render statistics.

Set `GRAFFITTY_TEST_SERVER` to the current release binary and
`GRAFFITTY_ANDROID_SERVER_HOST` to the owner's reachable interface for the
direct authenticated transport. Run `RUST_LOG=graffitty_video` to retain the
server's flow traces. Closing the browsers must preserve the server terminal.
