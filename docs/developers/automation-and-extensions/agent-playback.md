# Scripted agent terminals

Use mocks for repeatable demonstrations without model calls.

## Start a mock

```sh
gft dev codex-mock --response 'Implemented and tested.'
gft dev claude-mock --config examples/agent-playback/claude.json
```

Type a question and press **Enter**. The first question supplies the title.
Tools and edits are simulated unless real execution is explicitly enabled.
UI works outside Graffitty; graph connections require a Graffitty pane.

## Controls

| Key | Action |
| --- | --- |
| Enter | Submit; input during a turn queues for later |
| Shift+Enter / Alt+Enter | Newline |
| Up / Down | Draft movement; history at its edges |
| Escape | Interrupt |
| Ctrl+T / Ctrl+C | Tool details / exit |

| Launch option | Result |
| --- | --- |
| `--prompt TEXT`, `--once` | Start a turn immediately; exit after one turn |
| `--headless`, `--title NAME` | Hide UI; fix title |
| `--think-ms`, `--char-ms` | Thinking and streaming pace |

## Scenarios

Save JSON and pass `--config`:

```json
{
  "think_ms": 1500,
  "char_ms": 12,
  "response": "Finished: {prompt}",
  "turns": [
    {
      "contains": "dashboard",
      "steps": [
        {"type": "think", "ms": 2000},
        {"type": "message", "text": "Inspecting the app."},
        {"type": "tool", "name": "Bash", "input": "rg --files src",
         "output": "src/app.tsx", "ms": 800}
      ],
      "response": "Built the dashboard."
    }
  ]
}
```

| Matching | Rule |
| --- | --- |
| `prompt` | Exact question |
| `contains` | Case-sensitive substring |
| Neither | Consume sequentially for unmatched questions |

First matching rule wins and may repeat. Sequential exhaustion uses the default
response. `{prompt}` and `{turn}` expand in displayed text, tool input/output,
and titles; turns start at 1. Per-turn `title` overrides the displayed title.

## Step types

| Type | Fields / behavior |
| --- | --- |
| `think`, `wait` | Delay for `ms`; think shows thinking |
| `message` | Stream `text`; optional `char_ms` |
| `tool` | Display input/output; optional `exit_code`, `preview_lines` |
| `edit` | Display `path`, `before`, `after`, optional starting `line` |

Tool/edit duration defaults to 800 ms. Edits never modify files.

## Real tool calling

Enable `--real-tool-calling` or JSON `real_tool_calling: true`:

```json
{
  "real_tool_calling": true,
  "turns": [{"steps": [{
    "type": "tool", "name": "exec_command",
    "input": "gft chromium list",
    "command": ["gft", "chromium", "list"]
  }], "response": "Listed the browsers."}]
}
```

Each tool needs a literal `command` array. Use `exec_command` for Codex or
`Bash` for Claude. Commands inherit directory/environment, without shell or
placeholder expansion. Output/exit status are real. Failure stops later steps;
Escape stops the active command. Edits remain display-only.

## Repeatable timing and appearance

| Field | Use |
| --- | --- |
| `stream.seed` | Repeat rhythm |
| `stream.mode` | `words` default, or `characters` |
| `stream.jitter_percent` | Variation, 0–100 |
| `completion` | Pin `elapsed_ms`, `completed_at`, Claude `verb` |
| `model`, `directory`, `tip` | Display labels |
| `char_ms: 0` | Immediate text |

Timing uses elapsed wall time. An optional `animation_clock` file drives UI
animation for recordings; real commands retain real timing.

## Graph integration

Send/Read/Turn completed ports work normally. Incoming text selects the scenario;
the transcript keeps the full event. Interrupting returns to idle without completion.
Transcripts live under `${XDG_STATE_HOME:-$HOME/.local/state}/graffitty/recording-sessions/`
and can be removed after recording.

## Scripted SystemOne decisions

```sh
gft dev systemone-mock --scenario examples/agent-playback/systemone.json
```

`--config` supplies settings; `--scenario` supplies scripted decision rules.
Rules use exact `prompt`, substring `contains`, or sequential matching.
`answer` must match the mode's Decisions shape; the example uses `choice`
outputs `sonnet`, `opus`, `astra`. Invalid/unmatched answers retain input and
fail visibly. No model request or credential lookup occurs.
