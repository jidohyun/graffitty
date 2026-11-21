# Jev routing nodes

A FastAPI service that registers directly with the Graffitty Unix socket and
consumes its inbox.

The node reads `OPENROUTER_API_KEY`, uses TypeSafe's `typesafe/jev-1.13` through
[OpenRouter Decisions](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request),
reads the last ten text conversation records from the original session file, and
evaluates the configured question. The selected output forwards the **original
last message**, preserving the incoming graph run ID. Errors never become False.
Pydantic validates configuration, events, and model answers; PydanticAI's chat
model abstraction is unnecessary for the Decisions API.

## Setup

Run inside an Graffitty terminal, which supplies `GRAFFITTY_SOCKET` and
`GRAFFITTY_TOKEN`. Each instance owns its terminal's node identity. Do not run two
instances in the same terminal or share that identity between workers.

```sh
cd examples/jev-node
uv sync --locked
# Set OPENROUTER_API_KEY in this terminal using your usual secret setup.
```

Edit `boolean.json` with your question. Its output IDs are `True` and `False`;
the default threshold is probability >= 0.5. For custom labels and descriptions,
start with `review.json`. Optional `output_colors` maps IDs to `#RRGGBB` colours;
`output_names` overrides their hover tooltip names (an empty name hides the tooltip).
`name` and `icon` configure the node identity displayed instead of Adapter.
`output_icons` chooses the travelling symbol for a successful delivery on each
output (defaults to its label). Icons accept plain text/emoji or an object:

```json
{
  "question": "Are the changes approved?",
  "name": "Review judge",
  "icon": "⚖",
  "output_icons": {
    "True": {"text": "✓", "font": "Symbols Nerd Font Mono"},
    "False": "↩"
  }
}
```

A font family must be installed on the host to render its Nerd Font glyphs.
Alternatively use `{"svg":"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\">...</svg>"}`
with actual SVG content. The host's red × always means a delivery failure, even
when the node supplies its own output icon. False is a normal decision.
The optional `model` field overrides the default.

Start the judge first. It advertises one Evaluate input and an output for each
configured decision. On the canvas, wire the source's Turn completed to Evaluate,
then wire True and False to whichever receiving nodes you want. Their advertised
outputs select Send automatically; no connection-mode dialog is needed.
Each output can connect to multiple receivers, including Codex or Claude.
No destination IDs belong in the configuration.

For example, if the source, judge, and two receivers happen to be terminals
1, 2, 3, and 4, the equivalent CLI commands are:

```sh
gft graph connect --from %1 --to %2 --to-port evaluate --turn-completed
gft graph connect --from %2 --from-port True --to %3 --send
gft graph connect --from %2 --from-port False --to %4 --send
```

Find actual IDs with `gft graph list`. For explicit incoming messages,
create separate `--read` and `--send` wires instead of `--turn-completed`: the judge
requires Read to open the session file. Outgoing filters must accept the forwarded message. An unwired or
fully filtered selected output reports failure.

## Run the node

```sh
export JEV_CONFIG="$PWD/boolean.json"
uv run uvicorn fastapi_node:app --host 127.0.0.1 --port 8765
```

Run one worker, without `--reload`. Startup registers provider `adapter` with
the current terminal's identity. A background task polls `graph.take` every
750 ms, while an independent task maintains heartbeats during model calls.
Shutdown sends `SessionEnd`. To expose the optional HTTP interface on its own
Unix socket, replace the host/port flags with `--uds /tmp/jev-http.sock`. This is
a separate HTTP listener; `GRAFFITTY_SOCKET` remains the host protocol socket.

HTTP endpoints:

| Endpoint | Behavior |
| --- | --- |
| `GET /health` | Host connectivity health; no authentication needed. |
| `GET /manifest` | Advertised input/output IDs, colours, and tooltip names. |
| `POST /events/{event_id}` | Process an event already queued for this node, or return its cached receipt. |

The last two require `Authorization: Bearer <GRAFFITTY_TOKEN>`. They are intended
for local clients in this terminal's trust context. The POST accepts **only an
event ID**, fetching the authoritative payload from the host. It cannot inject
arbitrary local file paths. HTTP and background processing share a lock and
receipt cache, so they cannot forward the same event concurrently.

The current host does not discover HTTP endpoints, fetch `/manifest`, or push
events over HTTP. This example uses its supported socket protocol directly;
the HTTP interface allows inspection and explicit processing. Startup sends
`agent.register` over the host socket, and results use `graph.emit`. The host
selects destinations from the canvas wiring.

## Session parsing is opt-in and local to this node

`common.py` owns the two readers. Graffitty passes its current structured event:

```json
{
  "type": "turn.completed",
  "event_id": "...",
  "run_id": "...",
  "source": "%1",
  "text": "The changes are approved.",
  "sessions": [{
    "provider": "codex", "id": "...", "path": "/absolute/session.jsonl",
    "checkpoint": {"byte_offset": 123456}
  }]
}
```

Additional host fields are accepted. `sessions[].path` requires Read permission;
Turn completed currently implies Read. The node opens that original file and scans
backwards from each reference’s byte checkpoint, stopping after ten matching records
per session (with session identity attached for multiple references) instead
of loading the entire session. Later appended data and incomplete trailing
records are excluded. Jev receives these messages plus `text` separately, since
the hook's latest reply may not yet exist in the transcript.

* Codex: `response_item` / `payload.type == message`, user and assistant roles,
  with `input_text` / `output_text` / `text` content. Duplicate `event_msg`
  records and tool calls/results are excluded.
* Claude: user/assistant `message` records, string or text-block content.
  Sidechain messages and tool-only records are excluded.

This is a text judge, not a universal transcript normalizer. Images, reasoning,
tool results, and custom fields remain in the source file for other readers to
interpret. Unknown providers, missing paths, truncated files, malformed relevant
records, records over 8 MiB, or context over 120 KB cause a failed receipt.
There is no silent last-message-only fallback. The context bound is a local
example limit, not a promise about model token capacity.

The output is sent as a new message from the judge node; it does not impersonate
the source or attach the source's transcript as the judge's own session.

## Delivery semantics

`delivered` means this node evaluated the event and the host accepted the selected
outgoing message into its queue. It does not mean the destination finished work.
The log's `forwarding_status: "queued"` makes that distinction explicit.
Failures log the exception type, failing stage, and an explanation. If Jev
succeeded but routing failed, the receipt also includes the chosen output. Check the terminal's stderr JSON for these details; the current graph
badge itself only reports `failed`. Model response bodies and validation input
contents are not logged.

The last 256 receipts are cached in memory, including failures, so an input ack
retry does not rerun the model or resend the output within that cache window.
No automatic retry is made for an uncertain outgoing send. This is **not** an
exactly-once protocol across process crashes/restarts; durable idempotency would
require additional host support. The example intentionally do not retry external
model calls or equate network failures with negative decisions.

## Verification

```sh
uv run pytest -q
```

Tests exercise both transcript formats, checkpoints, Unicode, partial lines,
boolean/custom outputs, error handling, deduplication, and FastAPI authentication
and lifecycle. Integration tests launch the actual Uvicorn process
against an isolated real Godot `AgentGraph` and `AgentSocket`. Only the Jev HTTP
response is mocked. They require `godot` and the built extension;
they do not open user terminals or inspect user transcripts.

To additionally make two small paid requests using synthetic test context:

```sh
JEV_LIVE_TEST=1 uv run pytest -q tests/test_live.py
```

This explicit live check requires `OPENROUTER_API_KEY`. It verifies the real
Decisions endpoint and boolean/choice response parsing, without sending graph
messages or uploading a real session.


## Codex receiver has no message

Jev calls `graph.emit` with the selected output ID and
`{"decision":"True/False/or-custom-label","text":"the original incoming message"}`.
The host follows that output's Send wires and sends a text envelope, output ID,
and JSON payload through Codex's native `thread/queue/add` endpoint. It does not
type into the terminal. Turn completed is unnecessary on the judge's output wires.

Graffitty discovers ordinary Codex sessions automatically from their process and
session evidence. Daemon sessions support the native queue. Embedded sessions
(`--no-daemon`, or configuration overrides that select local mode) have no external
queue endpoint, so sending fails explicitly. Graffitty does not wrap Codex or
convert it to a remote attachment to supply that capability.

Failed messages are not replayed automatically; trigger a new event after the
receiver is ready. Hover a failed edge badge or run `gft graph list` to
see the full error.

## File, environment, CLI, and interactive configuration

Settings use defaults → JSON file → CLI options. A positional file overrides
`GRAFFITTY_NODE_CONFIG` (or `JEV_CONFIG`). Shared presentation fields match Filter:
`name`, `icon`, `output_names`, `output_colors`, and `output_icons`.
Partial mapping overrides replace the map.

```sh
uv run fastapi_node.py --question 'Approved?' --uds /tmp/jev-http.sock

# With no question supplied, prompt for it on the controlling terminal.
uv run fastapi_node.py
```

Use `--edit` to edit name/question. Other CLI options are `--name`, `--model`,
`--threshold`, and `--options` (a JSON object). Python prompts use prompt_toolkit
on `/dev/tty`. For unattended uvicorn,
supply settings via environment/file; its app factory never prompts.

Jev now routes using `graph.forward`: the original payload and session references
survive the judge. The decision is represented by the chosen output port; it no
longer replaces the payload with `{decision, text}`. Its transcript reader is
still deliberately specific to Codex/Claude session files. Use the Rust Filter
for arbitrary JSON conditions that do not need that history reader.

### Socket/FastAPI credentials

The FastAPI version reads `OPENROUTER_API_KEY`, or prompts on interactive stdin
with echo disabled when it is missing. It fails with the variable name when stdin
is not a terminal. The key stays in memory and is not saved to configuration.
The FastAPI version uses a settings file, `GRAFFITTY_NODE_CONFIG`, CLI flags, and
the question editor; it does not read `GRAFFITTY_NODE_SETTINGS`.
