# SystemOne

Ask a model a question about an incoming message. Use the answer to choose what happens next.

## Try a yes/no decision

1. Set `OPENROUTER_API_KEY`, or use a [saved credential](../developers/automation-and-extensions/secrets.md).
2. Run this in a Graffitty terminal:

   ```sh
   gft node systemone
   ```

3. Choose **OpenRouter**, keep the default model, and enter a question such as **“Does this need human review?”** Keep the default `noul` mode and Yes/No outputs.
4. Connect the source to **Evaluate** and the Yes/No outputs to their next steps.
5. Press **Ctrl+Enter**. Keep the node running.

The selected output sends the original message. The log shows the decision.

## Choose another mode

| Mode | Answer |
| --- | --- |
| `noul` | Yes or no |
| `choice` | One category you define |
| `score` | One of 2–10 levels, lowest to highest |

For `choice`, describe each outcome in **Outputs**. For example:

```json
[
  {"id":"bug","description":"Reports something broken"},
  {"id":"question","description":"Asks for information"}
]
```

Connect each output to an agent or tool. Keep IDs unchanged when renaming outputs to preserve their connections.

## Edit or retry

Editing pauses decisions. After changing settings or fixing an error, press **Ctrl+Enter** to resume.

| Key | Action |
| --- | --- |
| **Tab** | Next field |
| **Enter / F2** | Open a dropdown |
| **Ctrl+Enter** | Apply and resume |
| **Ctrl+C** | Exit |

## Save settings

Start with a settings file:

```sh
printf '{}\n' > systemone.json
gft node systemone --config systemone.json
```

Edit, then press **Ctrl+S**. Run the same command to load it later. API keys are not saved.

Use `gft node systemone --help` for scripting options.
