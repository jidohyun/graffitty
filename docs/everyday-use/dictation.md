# Dictation

| Gesture | Action |
| --- | --- |
| Hold the microphone, then release | Record and insert the transcript |
| Tap the microphone | Record hands-free; tap the square to stop |
| Slide left while holding | Cancel the recording |
| Tap × on the preview | Discard the draft |
| Double-tap, hold the second touch, then drag | Move the button; discards the recording started by the first tap |

- Server dictation shows words while speaking. Client-side dictation returns text after Stop.
- Text goes to the original terminal or browser field without pressing Enter.
- Errors or backgrounding preserve received text as a draft.
- Edit the draft or stop again to cancel a pending final result.
- The recording limit is ten minutes for server dictation and 60 seconds for client-side dictation.
- On Android, allow microphone access in **Settings → Apps → Graffitty → Permissions → Microphone**.

## Set up transcription

Choose [server configuration](#enable-on-the-server), or use a
[device-local Gemini or OpenAI key](client-side-dictation.md).

## Enable on the server

In `~/.config/graffitty/server.toml`:

```toml
[dictation]
enabled = true
```

1. Configure a provider key on the server.
2. Enable dictation.
3. Save a checkpoint and restart with `gft server restart`.

Clients do not need API keys. Server dictation requires `enabled = true`.

## Choose a provider

| Provider | Default credential variable | Live microphone |
| --- | --- | --- |
| Gemini | `GRAFFITTY_GEMINI_API_KEY` | Yes |
| OpenAI | `GRAFFITTY_OPENAI_API_KEY` | Yes |
| `openai-compatible` | Named credential required | Upload API only |

`provider = "auto"` chooses the first configured key: Gemini, OpenAI, then a custom provider.

To select OpenAI:

```toml
[dictation]
enabled = true
provider = "openai"
language = "" # Automatic; use "ko" or "ko-KR" for a hint.
```

## Models and credentials

Leave these defaults unchanged unless you need a particular model or endpoint.

```toml
[dictation.providers.gemini]
model = "gemini-3.5-transcribe-live"
base_url = "https://generativelanguage.googleapis.com/v1beta"

[dictation.providers.openai]
model = "gpt-live-transcribe"
base_url = "https://api.openai.com/v1"
```

- Both built-in providers default to live text while speaking.
- Add `credential = "NAME"` to select a [secrets.toml source](../developers/automation-and-extensions/secrets.md) instead of the default environment variable.
- Custom providers require `model`, `credential` and `base_url`.
- Restart the server after changing settings or credentials.
