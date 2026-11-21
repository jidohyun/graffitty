# Chromium architecture

The server owns browser sessions, profiles, and helper processes. Clients
present frames and forward input. Use [Browser automation](../automation-and-extensions/agent-chromium-api.md)
for commands.

## Choose a backend

| Backend | Native presentation |
| --- | --- |
| `chrome` default | Chrome tabs; embedded capture and optional local window |
| `alloy` | Windowless CEF; Graffitty tab controls |

Set `[chromium] backend` on the server. World changes and native-window dismissal
preserve pages; closing the final pane ends the browser session.

## What is and is not embedded

Only page pixels are captured. Native Chrome toolbars/menus remain separate.
The macOS Metal path is borrowed CEF IOSurface → immutable GPU copy → Mach
transfer → render-thread import. It has no CPU readback or PNG fallback.
Unsupported native paths fail explicitly.

Private CDP and `Graffitty.*` commands control helpers. No public debug port or
command-file mailbox is used. The server manages only its own helpers.

## Shared chromium controls

`ChromiumChrome.gd` supplies the toolbar.
`ChromiumTabStrip.gd` adapts metadata to the shared `TabStrip.gd` layout core.

| Behavior | Implementation |
| --- | --- |
| Stable tabs | CEF page IDs survive reordering |
| Chrome updates | `Graffitty.tabs.*` and `TabStripModelObserver` |
| Alloy tabs | Direct CEF browser ordering and selection |
| URL/search classification | Chrome omnibox |
| History suggestions | Local Chrome history providers |

Typed history queries do not reach a search service.
Custom presenters read `ChromiumSession.page_tabs` and issue tab commands;
the server retains process ownership.

Style reusable controls through a Godot `Theme`. Connect
`close_session_requested` to owner-controlled confirmation.

## Native presentation and resizing

Supported local desktop clients can show native UI. Remote clients hide that
control. Dismissing it preserves page state and resumes embedded capture.

Native window bounds control the visible native page. Embedded preview resizing
does not resize that window. Extracting a tab from a visible native window also
shows the new native window.

## Recover from failures

| Failure | Recovery |
| --- | --- |
| Renderer crash | Reload into a new renderer |
| Unresponsive page | Reload through a temporary document to escape the stuck renderer |
| Browser stops | Show reason and Restart/Close; restart reopens URLs |
| Repeated GPU failures | Report the resulting browser stop |

Restart loses live JavaScript and unsaved state. Persistent profiles keep data
already saved; temporary profiles start fresh. Forced process termination cannot
preserve live state.

## Security and lifecycle limitations

The experimental macOS host disables the Chromium sandbox and uses a mock
keychain; permissions default denied. Windows instead requires its native
[sandbox context](windows-chromium.md). Platform capabilities are not interchangeable.
Checkpoints restore URLs/profile choices, not live JavaScript state.

## Build the macOS host

```sh
dvc pull assets.dvc
bash apps/server/chromium/build.sh
```

Keep the full app bundle together. Rebuild the extension for its GPU receiver.
`GRAFFITTY_CHROMIUM_HOST` selects another executable.
The pinned fork recipe lives in `fork/cef/`; see [CEF build](../build-and-run/cef-build.md).

## Tests

`tests/chromium/chromium_window_e2e.py` covers native tab extraction, identity, unsaved
state, ownership, profile/PID continuity, and visibility.
`tests/chromium/chromium_history_e2e.py` covers real history. Use an isolated rebuilt server.

Recorded GPU delivery does not guarantee a frame rate. Physical IME, extensions,
and broad website compatibility need separate validation.
