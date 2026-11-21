# Chat message reference

A **Message template · jq** expression receives one graph event and returns
one message object. See [formatting recipes](chat-message-format.md) to try it.

## Default message

```jq
{text: (.text // ""), content: (.content // []), renderings: (.renderings // {})}
```

| Field | Contract |
| --- | --- |
| `text` | Plain readable fallback |
| `content` | Ordered `text`, `image`, `audio`, `video`, or `file` parts |
| `renderings` | Explicit options for individual chat services |

## Text and attachments

```jq
{
  text: .text,
  content: [{type: "image", path: .payload.screenshot, mime_type: "image/png"}]
}
```

| Content | What is sent |
| --- | --- |
| Empty | Fallback text |
| Contains text parts | Those parts replace the fallback |
| Media only | Fallback once, then the media |

Common text uses `format: "plain"`. Unknown types or unsupported formats fail.
Discord uses its normal markup; mention notifications are off by default.

Media requires an **absolute local path**. `mime_type` and `caption` are optional;
images also accept `alt`. Slack/Discord carry that description; this Telegram
upload method has no image-alt parameter.

All files are checked before sending. Uploads preserve content order and must
meet the service's size/format limits. Long plain text splits automatically;
shorten oversized formatted text or captions yourself.
Remote downloads, voice-note recording, and live streaming are unsupported.

## Native layouts

```jq
{
  text: .text,
  renderings: {
    slack: {blocks: [{type: "section", text: {type: "mrkdwn", text: .text}}]},
    discord: {embeds: [{title: "Result", description: .text}]}
  }
}
```

Slack blocks and Discord embeds replace common content for that service.
Supply a nonempty fallback for other services. Layouts are not converted between providers.

| Service | Accepted native fields |
| --- | --- |
| Slack | `blocks`, `mrkdwn`, `thread_ts`, `unfurl_links`, `unfurl_media` |
| Discord | `embeds`, `allowed_mentions`, `message_reference`, `flags` |
| Telegram | `parse_mode`, `disable_notification`, `protect_content` |

Telegram `parse_mode` needs text-only output with correctly escaped markup.
Unknown fields fail locally. Message data cannot change credentials or destinations.
Interactive buttons and callbacks are unsupported.

## Reuse a format

Select custom payload fields explicitly, for example
`{text: ("Build #" + (.payload.build_id | tostring) + ": " + .text)}`.
A Filter can set `text`, `content`, and `renderings` once before fan-out to chat nodes.
