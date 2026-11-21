# Gather conversation history


```sh
gft node read-session-file --last 10
```

1. Connect the agents' **Read** outputs to **Trigger / Read**.
2. Connect a Manual Prompt output to the same input to trigger gathering.
3. Connect the reader's **Output** to your consumer.

Each trigger gathers the last ten user/assistant messages from each permitted session.
The result keeps your prompt and adds source-labeled conversation history.

## Use the result in another node

The prompt is `.text`; history is `.payload.history`. An input expression such
as `{prompt: .text, history: .payload.history}` passes both to a decision node.

## Choose sources

- Leave the path and source fields blank to gather all connected sessions.
- **Source node filter** selects one permitted source; **Session path override** reads one explicit JSONL file.

## Preview and apply

- **Preview / F5** gathers without sending.
- **Read now / Ctrl+Enter** applies settings and sends immediately, without a current prompt.
- Read permission alone never triggers gathering. A **Turn completed** connection grants Read and triggers it automatically.
- Editing pauses incoming delivery. Apply the settings to resume.
- A read error keeps the event pending instead of sending incomplete history.

See [Automation nodes](automation.md) for other tools.
