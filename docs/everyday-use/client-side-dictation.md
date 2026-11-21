# Client-side dictation

Use a device-local Gemini or OpenAI key to transcribe audio directly with that provider.

## Set it up

1. On the connection screen, open **Settings → Client-side dictation**.
2. Choose **Gemini** or **OpenAI**, enter the provider’s API key, and select **Save**. To switch back to a provider whose key is already saved, leave the key field blank.
3. Record up to 60 seconds. Press **Stop** to send the audio and receive the final transcript.

Each provider has its own key in the device credential store. **Use server** removes the active provider’s local key and returns to server dictation.

## Behavior

| Setting | Result |
| --- | --- |
| Gemini selected | Send audio directly to Google using `gemini-2.5-flash` |
| OpenAI selected | Send audio directly to OpenAI using `gpt-transcribe` |
| Stop | Upload buffered audio and return the final transcript to the original dictation target |
| Cancel | Discard the audio and cancel any pending request |

Direct dictation returns text after Stop. If transcription fails, check the selected provider’s device key, quota, and model access. Graffitty does not retry with server credentials.
