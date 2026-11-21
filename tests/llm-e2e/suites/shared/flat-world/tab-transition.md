# Flat tab transition: push, cross, pull

Run in both Flat and Flat 2D (`--plugin=flat-2d`). Use two tabs with distinct text,
multiple panes, an inline image, and different saved pan/zoom. Capture continuous
motion; still frames alone do not establish smoothness.

Tab changes use **Push/Pull** (or none). Letters and dust belong to session
switches, not tabs. Before motion starts, retain the outgoing view until the
destination's owner snapshot has been repainted and its incoming capture has
drawn. Create, close and ordinary switching share this preparation. Loading does
not consume any of the transition's 420 ms.

## Push the outgoing panes

Switch to a later tab while idle, then while typing has zoomed the camera. The
outgoing panes stay whole: text, backgrounds, frames, the active-pane outline,
the Main View border, chromium pages and images enlarge together toward the
viewer, defocus and fade. Nothing is cut into letters, dust or screenshot-grid
shards, and no pane is squeezed or stretched. The camera starts moving
immediately, toward the destination tab's saved view.

## Cross while the destination arrives

The incoming panes overlap the departure from the first frame: they complete the
reciprocal zoom (2x range) and fade in as the outgoing panes fade out. Every
pane, border and decoration of both tabs shares one quintic smoothstep clock;
saved camera framing must not add a second acceleration. The camera passes
through intermediate framing and lands with the panes at the same deadline:
there is no settling tail after it. No complete live destination may appear
beneath its arriving copy. At completion, replacing the transition with live
panes must not jump or flash, and the camera rests on the destination's saved
view. Switching to an earlier tab reverses the dolly: outgoing panes shrink
away while the incoming ones pull in from in front.
Include coloured and dim prompt text (for example, a coloured hostname). Its
colour and antialiased edges must match at departure and at the arrival handoff;
transition captures must preserve the live terminal's colour space and texel
density, including zoomed/cropped panes on the first frame.

## Interrupt and preserve sessions

Switch again early in the crossing and late in it. Existing panes retire
smoothly, no hidden tab flashes into view, and the camera starts from its
displayed frame and lands on the latest tab's saved view. Low frame rates and
render stalls keep elapsed transition time. Test an instant switch, disabling
tab effects, chromium panes, graph wires and sockets, overview captions, resource
strips, and the monitor. Pane layout, shells and content survive.

Replay: `replays/tab-transition.gd`. Run headless in each renderer for phase,
framing and lifecycle checks, then windowed for shader errors and visual review.
Set `GRAFFITTY_TRANSITION_ARTIFACTS` to save representative rendered stages.
