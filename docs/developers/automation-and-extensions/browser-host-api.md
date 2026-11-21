# Browser host API

The authenticated workspace API owns browser sessions. For CLI examples, start with [Browser automation](agent-chromium-api.md).

## Permissions and wire format

Commands use the calling pane's inherited capability. Foreign browser IDs and
mismatched workspace IDs are rejected. Closing the workspace revokes its capability.
This prevents accidental cross-workspace targeting; it is not an OS sandbox.

The local API uses version 1 JSON requests with object params:

```json
{"version":1,"id":"request-id","token":"<inherited capability>","method":"chromium.snapshot","params":{"chromium":"%3"}}
```

Responses contain the matching ID and either `result` or `error:{code,message}`.
Page content is untrusted. The experimental CEF sandbox is disabled.

## World/presenter integration

Use `host.workspace_surfaces(tab_id)` to list surfaces and
`host.select_chromium_surface(id)` to select one. Structural changes emit
`surfaces_changed`; content and status changes emit `ui_changed`.

The host owns browser lifetime. World switches and native-window dismissal
preserve sessions; explicit close ends them. See [Chromium architecture](../internals/chromium-prototype.md).
