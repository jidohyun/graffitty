# Format chat messages

Open your [chat node](chat-integrations.md), then edit **Message template · jq**.
Paste one expression below into that field, replacing its current contents.
Press **F5** to inspect the next event before sending.

## Add a label

```jq
{text: ("Build result: " + .text)}
```

For incoming text `passed`, the preview should show `Build result: passed`.

1. Press **F5** to preview the next queued message without sending it.
2. Press **Ctrl+Enter** to apply and resume sending.

## Attach an image

```jq
{
  text: .text,
  content: [{type: "image", path: .payload.screenshot, mime_type: "image/png"}]
}
```

The screenshot field must contain an absolute path to a local file.
Files are checked before sending. Use `type: "file"`, `"audio"`, or `"video"`
for other attachments.

## Reuse a template

Save the jq expression as `build.jq`:

```sh
gft node slack-send --channel-id C0123456789 \
  --message-template-file build.jq --edit
```

Saving in the form updates that file. Paths supplied in a config are relative
to the config; CLI paths are relative to your working directory.

## Preview a saved event

```sh
gft node slack-send --channel-id C0123456789 \
  --message-template-file build.jq --preview event.json
```

`event.json` must contain a graph event. This checks local attachment paths
and prints the planned requests. No token is needed and nothing is sent.

## Use Slack blocks or Discord embeds

See the [message reference](chat-message-reference.md) for native layouts,
the full content format, and provider-specific fields.
