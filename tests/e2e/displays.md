# Displays, PiP, and image quality

## DI-01 — Existing displays, no surprise virtual monitor

Baseline: Lumen virtual displays are disabled. Connect and disconnect from Artemis;
verify the host display count/topology does not acquire another monitor. The initial
stream captures an existing selected/main display.

If virtual displays are deliberately tested later, make creation, resolution,
refresh, scaling, and removal explicit. Do not silently create a fourth display or
assume the requested 4K client resolution means the user wants a new 4K, 1x-scaled
Mac desktop. Increasing video resolution and changing desktop topology are separate.

## DI-02 — Real display discovery

With a known host fixture, compare the actual capturable outputs with the chooser.
It must show exactly those outputs, not 13/14 protocol shortcut slots. Numbered UI
options map consistently to host capture identifiers. Test one and multiple displays,
discovery errors, unsupported hosts, and display attachment/removal.

Discovery must use the authenticated host contract. Unsupported/unavailable discovery
must be explicit; never manufacture a monitor list as a fallback.

## DI-03 — Confirmed active-display badge

Switch each available output; verify both the captured picture and the floating
button/chooser's selected indicator. The badge reflects the host's active capture
output, not merely the last requested number. Show unknown/pending state honestly.
Check failed switches, rapid requests, reconnect, and changes made by another client.

## DI-04 — Switching responsiveness

Measure request-to-picture latency separately from request-to-badge latency. Include
same-resolution and different-resolution displays. Record any capture/encoder
reinitialization and polling delay. Never diagnose a slow picture solely from a stale
badge or claim polling improvements fix capture startup. No fixed latency target was
agreed; record baseline/regressions and seek visibly prompt switching without stale
images, wrong selection, or hung capture.

## DI-05 — PiP is the currently visible region, without bars

Test unzoomed letterboxed video, zoomed/panned video, portrait/landscape, and different
host aspect ratios:

1. Record the actual visible desktop region before entering PiP.
2. Enter PiP through Home/auto-entry and any explicit entry path.
3. Confirm PiP shows that same region, naturally filling its content area without
   carrying over the fullscreen letterbox bars or jumping to a strange offset.
4. Resize/move PiP, then return to fullscreen.

Expected: preserve the current region, not an unconditional fit-to-whole-monitor
reset. Crop/source bounds and aspect ratio follow the visible image. Restore the
previous fullscreen zoom/pan coherently. Hide floating controls/key strip in PiP;
restore them afterward. Respect Android's supported PiP aspect bounds and document
any unavoidable additional crop for extreme shapes rather than distorting the image.

### DI-05a — Tab switching does not enter PiP

With PiP enabled and two live Artemis stream tabs, switch A → B → A using the
tab chooser. The outgoing stream must remain a background tab, never a PiP
window; returning must preserve its live connection. Repeat rapid switches.
Then press Home from the active tab: normal PiP entry and current-region crop
must still work. Repeat on Android 8–11 (legacy entry) and Android 12+ (platform
auto-entry). With PiP disabled, neither Home nor tab switching should enter PiP.
A failed tab launch must not leave PiP disabled for the still-active stream.

## DI-06 — Sharp office text and static quality (deferred; not required)

The user explicitly removed sharper/adaptive-quality work from the current scope.
The notes below preserve the earlier discussion only; this is not a release gate
or remaining implementation task for this work.

Compare a fixed text/browser fixture at baseline resolution and higher stream
resolutions, using supported codecs and measured bitrate. Test after motion stops
and while zoomed. Record source desktop resolution/scaling, stream resolution, codec,
chroma capabilities, bitrate, zoom, and device decoding support.

Requested outcome: crisp zoomed office text, with quality improving on static content
where feasible, comparable to the RustDesk reference. Do not claim client-side zoom
can create pixels absent from the stream, or that bitrate alone fixes a resolution or
chroma cap. No adaptive-static-quality implementation is established by this spec.
Higher-resolution video and a future host-side visible-region stream are candidate
approaches, not completed requirements. Do not enable virtual displays or change the
physical display resolution without making that separate change explicit.

On remote-browser detach, clear display consumers before freeing the decoded
video viewport. Repeated detach must not emit a missing viewport-texture error.
