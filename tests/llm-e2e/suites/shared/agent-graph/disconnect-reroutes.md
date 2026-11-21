# Disconnect removes orphaned reroute dots

Use a disposable Flat workspace with three terminals titled Source, Review, and
Check. Advertise fixture Send/Receive ports; no LLM response is needed. Enter
Overview so every wire and reroute is visible. Do not change personal sessions.

## Single connection

Check that pane IDs and graph node IDs are the same canonical `%N` strings.
Connect Source to Review using those IDs. Require the returned connection's
`from` and `to` to use `%N`, and socket/edge keys to use `%N/port` and
`%N/send>%N/receive`. Keep those identities unchanged through disconnect,
undo/redo, and reconnect. Insert two reroute dots and move them away from the
direct wire so their disappearance is obvious. Capture the connected state.
Drag the connected input socket into empty space and release. Require the wire and both dots to disappear;
clicking or hovering at the old dot positions must not reveal a selectable orphan.
Undo once: restore the wire and exactly the same two dots at their original positions.
Redo once: remove the wire and both dots again. Reconnect the same endpoints:
the new wire must be direct, with no stale reroute path. Remove it before continuing.

## Shared branches

Connect Source to Review and Check through one shared reroute, with an additional
private reroute on the Review branch. Disconnect Review by dragging its input socket into empty space.
Require the Review-only dot to disappear, while the shared dot and Check wire remain.
Disconnect Check: the shared dot must now disappear too. Undo and redo the final
disconnect; verify the shared route is restored and then removed without duplicates.

## External disconnect

Create another routed Source-to-Review connection. Disconnect it through
`gft graph disconnect` (the replay uses the same `graph.disconnect` request).
Refresh/re-enter Overview. Require no route records, orphaned dots, stale selection,
or revived path when reconnecting. Existing terminal shells must remain alive.

## Evidence and result

Retain before/after images or a recording for visual review, including the remaining
shared branch and both undo/redo outcomes. Inspect authoritative edges and visual
route/reroute records as well as rendered dots. PASS requires both topology and
visual checks; a headless replay establishes the topology assertions only.

Replay:

```sh
uv run tests/godot/test_dashboard.py test disconnect-reroutes
```

The replay sets up deterministic wiring/reroute fixtures in the real application,
then drives input-socket disconnects and undo/redo through the actual UI. It does not call a model
and does not claim live-agent coverage. Run its Markdown steps or record the replay
for LLM visual review.
