# Desktop Moonlight controls and cached startup

The desktop client fork lives in sibling `../moonlight` (Moonlight Qt).

## PC-01 — Windowed office sessions

Fresh/unset preferences start streaming in a normal window with desktop-style
absolute mouse input. Explicitly saved settings remain explicit choices. Fullscreen
is entered only through the user's control/command; returning restores a usable
window. Preserve real fullscreen-only platform limitations rather than claiming
windowed support on embedded renderers that cannot provide it.

## PC-02 — Floating session control

One compact (24 logical pixel) floating button has an 18-pixel Sunshine logo.
Both background and logo are 10% opaque while idle and 30% on hover, during a
drag, or while its menu is open, per the revised requirement. Paint their
alpha once: do not multiply it by fading the native window too, and do not leave
an opaque black backing. On macOS attach it above the client as a child
window so focus changes cannot bury it. Create an explicitly transparent SDL
window; changing only NSWindow/image alpha does not prevent SDL's black repaint.
On Windows do not use SDL transparent windows (empty and click-through); use
whole-window opacity, since logo and background share one alpha. Disconnect must
end a running stream (post quit), not merely set the startup-abort flag. A short click toggles a readable vertical context menu
using the system UI font at native display density: numbered host displays and
red Disconnect. Do not add a fullscreen action: use the native window control.
Fetch the versioned `LumenDisplays` metadata through the paired host connection;
never fabricate slots or open a browser instead. Highlight only the host-confirmed
selection. With one display, show `1` disabled; missing/invalid discovery is
unavailable. Selection sends a complete Sunshine display-switch chord, including
modifier releases. Poll off the rendering thread; verify actual capture changes.

Hold 350 ms then drag to reposition. Remember a normalized position and keep it
reachable on resize/fullscreen transitions. Its movement bounds are the entire
client content area, including letterbox margins, not the streamed video rectangle;
it must not escape onto the local desktop. Drag release must not open the menu or
send a remote click. Early accidental movement cancels a click. Test cancellation,
window focus loss, menu direction near either edge, fullscreen Spaces on macOS,
and returning from the host-settings browser. Disconnect ends only the client
connection, not the host application.

Input on local controls must never reach the remote computer. Test physical
modifiers held while entering/leaving the menu; release remote input state safely.
Check that the button remains usable in both absolute and explicitly chosen relative
mouse modes. If window opacity is unsupported, report the platform limitation.

## PC-03 — Encoder capability cache

Lumen may reuse a successful capability probe while the relevant GPU/display state
and encoder configuration are unchanged. Test cold start, unchanged reconnects,
changed codec/encoder/output, monitor hotplug/mode change, and capture/encode failure.
A failed capability test cannot create a valid cache entry; failure during a probe
must not be hidden by its later completion. A streaming failure invalidates cached
results so a subsequent session probes again.

Record probe time separately from negotiation/capture/first-frame time. Verify the
cache-hit log and actual first-frame behavior; a cache policy unit test alone does
not prove reconnect speed or recovery. Do not remove authentication, platform checks,
or configuration invalidation to improve a timing result. GPU reset recovery and
same-session automatic retry require separate validation; do not assume they follow
from reconnect invalidation.

Current automated checks: Lumen `EncoderProbeCache.*` and
`ConfigDefaultsTest.VirtualDisplayRequiresExplicitOptIn`; Moonlight
`tests/sessioncontrols_smoke.cpp`. The latter checks opacity, local action dispatch,
short-click toggling, held-drag nonactivation, and saved position presence in an
isolated settings fixture. It also covers hiding without recursive layout and
positioning in a portrait client's letterbox area. It is not a live-stream/fullscreen
E2E test.

Live macOS → Windows validation: rebuilt client streamed successfully; native
window inspection confirmed a 28×28 control at 0.1 opacity. A real 350 ms hold/drag
moved it from the streamed-video area into the top letterbox of a portrait client.
The vertical menu is a separate, opaque local window (at least 200×84). The button
now stays 24×24 and remains anchored when opening the menu. Automated coverage includes
one-display disabling and correct number-to-switch-action mapping. A controlled
blue-background visual fixture confirmed actual native background transparency,
not merely an alpha value in a generated image. Enable `MOONLIGHT_CONTROL_VISUAL_TEST`
for the smoke executable to hold that fixture open for compositor inspection.

Windows host display discovery now publishes a coherent snapshot of the list used
by the capture session. Never reopen DXGI duplication from the HTTP polling thread:
live tests found that this changed the discovered count from one to zero during
capture. Rebuilt/deployed Windows Lumen and verified repeated polls remained at
one; the actual menu showed a disabled `1`. Multi-display switching still needs
live testing with more than one active output. Native fullscreen, focus recovery,
and reconnect persistence still need full lifecycle validation.
