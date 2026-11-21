# Filter messages

Route a message to **Matched** or **Unmatched** using a jq condition.
No model or API key is needed.

## Try it

1. Run this in a Graffitty terminal:

   ```sh
   gft node filter --condition 'contains("error")'
   ```

2. Connect the source to **Evaluate**.
3. Connect **Matched** and **Unmatched** to their receivers.

Messages containing `error` take the Matched output; other messages take Unmatched.
An unconnected selected output is an error. To deliberately drop a message,
use a transform that returns `empty`.

## Filter a payload field

| Setting | What it does | Example |
| --- | --- | --- |
| **Input** | Select a value from the incoming event | `.text` (default), `.payload.score` |
| **Condition** | Return one boolean from that value | `contains("error")`, `. < 0.5` |
| **Transform** | Optionally change text or payload using the complete event | `{text: ("Review: " + .text)}` |

### Transform or drop a message

The original message is forwarded when Transform is blank. A transform runs for
both outputs. Return `{}` to keep the content or `empty` to send nothing.

```sh
gft node filter --input .payload.score --condition '. < 0.5'
```

A missing or null selected value is an error. Use a fallback such as
`.payload.message // .text` when both forms are valid for your workflow.

## Edit and retry

Run `gft node filter` to open the form without a preset condition.
Editing pauses delivery.

| Control | Action |
| --- | --- |
| **Tab / Shift+Tab** | Change fields |
| **Ctrl+Enter** | Validate, apply, and retry pending input |
| **Page Up / Page Down** | Scroll the event preview |
| **Ctrl+C** | Stop the node |

A condition error keeps the event pending; it never counts as Unmatched.
Fix the expression or connection, then apply again.

Do not connect an output that can drop events to a Parallel branch that must
finish every round. Parallel still waits for that event.

## Reuse a configuration

```sh
gft node filter --config examples/filter-node/errors.json
gft node filter --config examples/filter-node/review.json --edit
```

CLI flags override file settings. Form edits affect the running process without
rewriting the file. Add `--headless` to run without a form, or `--once` to stop
after one forwarded or explicitly skipped event.

Expressions use the embedded jaq engine; no separate jq installation is needed.
For custom event fields and permissions, see [graph design](../developers/automation-and-extensions/agent-graph.md).
