# Browser method reference

These are workspace RPC methods. For CLI examples, see [Browser automation](agent-chromium-api.md).

## Methods

| Method | Request / effect |
| --- | --- |
| `identify` | Caller tab/terminal identity and API version |
| `surface.list`, `chromium.list` | Only caller-owned surfaces |
| `chromium.create` | Create a browser; see [creation options](#creation-options) |
| `chromium.select` | `chromium`; selects its embedded surface without switching workspace |
| `chromium.navigate` | `chromium`, `url` |
| `chromium.set_title` | Session-server frontends: caller-owned `chromium`, `title`; empty title restores the latest page title |
| `chromium.snapshot` | `chromium`; main-document text and interactive element refs |
| `chromium.click`, `chromium.fill` | `chromium`, `ref`; fill also takes `text` |
| `chromium.press` | `chromium`, `key`: Enter, Tab, Escape, Backspace, Delete, arrows, Space |
| `chromium.scroll` | `chromium`, `x`, `y` pixel deltas |
| `chromium.eval` | `chromium`, `expression`; returns JSON-serializable result |
| `chromium.wait` | `chromium`, optional `selector` or `text`, `timeout_ms` ≤30000; default waits for document complete |
| `chromium.present` | `chromium`, `mode`: native/embedded |
| `chromium.attach` | `chromium`; returns single-client `endpoint`, `lease`, `target_id`, `expires_in_ms`; same workspace only, macOS |
| `chromium.detach` | `chromium`, `lease`; releases only the matching attachment, preserving chromium/page state |
| `chromium.close` | `chromium`; closes this Chromium window and its tabs; sibling windows retain the shared session |
| `chromium.restart` | `chromium` whose browser stopped unexpectedly (state `crashed`, `restartable`); relaunches it under the same handle, reopening `lastUrls` with the selected page first; a running chromium returns an error |

## Response fields

`chromium.create` returns `chromium`, `surface`, `tab_id`, `profile`,
`temporary_profile`, and `profile_template`. Attachment returns `endpoint`,
`lease`, `target_id`, and `expires_in_ms`; treat the endpoint as a credential.

## Creation options

- `url`: HTTP, HTTPS, or `about:blank`.
- `profile`: persistent profile directory.
- `profile_template`: directory copied to temporary storage; cannot be combined with `profile`.

The result includes browser/surface IDs, tab ID, and profile details.
See [Chromium profiles](../../customize/chromium-profiles.md).

RPC creation starts hidden. `gft chromium new --side right`, or `--at X,Y --size WxH`,
adds `pane.place` to show the new pane.
