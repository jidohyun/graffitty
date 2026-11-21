# Remote update traffic

Use this reference to distinguish structural updates, field deltas, and terminal content.

| Message | When it is sent | Client action |
| --- | --- | --- |
| `topology` | After authentication, on `sync`, or after a structural change | Replace workspace structure |
| `pane_update` | Volatile fields change | Merge known IDs into retained topology |
| Scene transaction | Subscribed terminal content changes | Apply revision/base under the credit window |

## Terminal content

Clients subscribe to panes in their active tab. Hidden tabs and unsubscribed
panes send no terminal content. Scene transactions use 64 KiB chunks;
a slow client receives a fresh snapshot instead of accumulated changes.
Chromium frame delivery also waits for viewer acknowledgements.

## Topology and `pane_update`

Topology includes tabs, pane rectangles and grids, chromiums, workspace layout,
agent graph, and font manifest. Volatile fields are excluded from structural
comparison: changing a title cannot resend topology.

```json
{"type":"pane_update",
 "panes":[{"id":7,"title":"⠹ building","automatic_title":"⠹ building"}],
 "tabs":[{"id":3,"title":"⠹ building"}],
 "chromiums":[]}
```

### Delta fields

Deltas include only changed fields for IDs the client already knows.

| Object | Volatile fields |
| --- | --- |
| Pane | `title`, `title_is_fallback`, `automatic_title`, `app`, `effect_holds`, `filetree`, `filetree_open` |
| Tab | `title` |
| Chromium | `title`, `automatic_title`, `state` |

### Scheduling

Coalesce visible subscriptions and their tabs at 200 ms. Hidden objects wait
at least 450 ms. The hidden interval avoids sampling common 800 ms/1 s title
spinners at the same phase each time, which would freeze their displayed titles.

### Client merge rules

Merge by ID and refresh affected panes only. A delta does not advance topology
generation; pending layout claims still wait for structural `topology`.

## Client diagnostics

Android and desktop `--render-stats` emit these engine-log records every
30 seconds; Android uses logcat tag `godot`.

| Record | Inspect |
| --- | --- |
| `[render-stats]` | Memory, nodes, draw calls, process time, and each live SubViewport's size, HDR, update mode, estimated bytes, CPU/GPU time |
| `[frame-profile]` | Average frame process time versus instrumented GDScript callbacks and native terminal work; gaps indicate uninstrumented work |

## Fonts and health

Prioritize font chunks while client pending data stays below 256 KiB, so output
cannot starve cold font caches. Remote write-buffer and protocol failures log
`[network] Client <id> disconnected: <reason>`.

## Recorded performance findings

Before field deltas, animated titles triggered over ten topology updates per
second: about 300 KB/s per idle phone. The phone's main thread and font downloads
stalled.

A separate title-measurement issue cost about 380 ms/frame on a phone. Titles now
cache formatting per text, budget, and font, and use binary-search trimming.
