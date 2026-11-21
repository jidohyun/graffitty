# Terminal protocol reference

Use this to implement an application integration. For shell setup, see [Shell integration](terminal-integration.md).

## Application protocol reference

Each row names the supported behavior. Platform limits are explicit; unsupported
operations do not imply full compatibility with another emulator.

### Clipboard and links

| Feature | Behavior |
| --- | --- |
| OSC 52 | Desktop clipboard writes; reads ask by default. `deny` and `allow` policies also supported. 1 MiB text limit; primary-selection fallback where unavailable. |
| OSC 5522 | Chunked writes, strict base64, MIME aliases, typed/chunked reads, MIME listing, and permission/error responses. 64 MiB transfer limit. macOS has native arbitrary-MIME pasteboard access; other platforms currently expose plain text through Godot. Unsupported primary selection returns ENOSYS. Password-based permission reuse is not implemented. |
| OSC 8 | Click links; hover shows the destination. Remote/Android clients allow only HTTP(S). |

### Notifications and application control

| Feature | Behavior |
| --- | --- |
| OSC 9 / 777 / 99 | [Desktop notifications](../../agents/system-notification.md), with OSC 99 icons, buttons, updates, and lifecycle reporting. |
| OSC 4723 | [Pane claims](pane-claim.md) and [effect holds](effect-holds.md). |
| OSC 22 | Set, reset, push, pop and support/current/default queries. Independent primary/alternate stacks; RIS clears them. Supported shapes are reported explicitly; unsupported platform shapes return 0. |
| DCS XTGETTCAP | Hex-encoded capability requests and positive/negative replies for implemented color, cursor, selection, screen and input capabilities. Unknown capabilities return failure. |

### Display and images

| Feature | Behavior |
| --- | --- |
| CSI 22/23 t | Window-title push/pop, bounded to 16 entries. |
| DEC 2026 | Synchronized redraw with one-second recovery timeout. |
| Sixel | Bounded raster decoder (RGB/HLS palettes, repeats, carriage returns, sixel rows, transparency and declared raster dimensions), rendered through the existing graphics path. Basic Sixel advertised in DA. Legacy pixel-aspect and alternate Sixel scrolling modes are not emulated. |
| iTerm images | Inline PNG/JPEG/WebP/BMP, File and MultipartFile/FilePart/FileEnd, size units and aspect ratio. Downloads and animated/PDF image formats are not implemented. |
| Blink | VT cursor-blink state and SGR blinking text drive redraw. |
| Existing paths | Kitty keyboard and graphics, mouse/focus reporting, cursor shapes, colors/queries, title/cwd/progress, resize, scrollback and bracketed paste. |

## Rendering and verification

See [terminal ink rendering](../internals/terminal-ink-rendering.md) for renderer details.
`tests/server/shell_integration_smoke.py` checks supported shell startup and cwd reporting.
Native tests cover control-string parsing, capability replies, images, search,
and command-output selection. These are implementation checks, not a claim of
universal Ghostty, WezTerm, or kitty compatibility.
