# World controls API

Choose one presentation level. Start with [World UI API](world-ui-api.md).

| Need | Use |
| --- | --- |
| Complete workspace | TerminalSpace scene |
| Some standard controls | Bound controls or tab strip |
| Fully custom visuals | Session models and custom drawing |

## Optional complete terminal space

Set the world's **Terminal Space Scene** to `res://scenes/TerminalSpace.tscn`,
or assign it in code:

```gdscript
extends "res://scenes/SpatialTerminalWorld.gd"

func _init() -> void:
    terminal_space_scene = preload("res://scenes/TerminalSpace.tscn")
```

The host mounts it in window space before world entry and binds persistent
sessions. It supplies tabs, headers, browser controls, monitor, tiling, stashes,
Overview/Main controls, drag previews, camera pan/pinch, and pointer projection.
Basic Terminal/TerminalSurface3D kits do not opt in automatically. `_build_ui()`
may omit chrome; an empty `terminal_space_scene` keeps a basic presentation.

### Customize supplied controls

Inherit TerminalSpace and choose that scene on the root. Theme inheritance
skins it; exported paths bind authored controls without extra signal glue.

| Property | Supplied node |
| --- | --- |
| `pane_header_scene` | Inherited `PaneHeader.tscn` adapter; supplies title metrics/theme to the bundled `pane-header` mod while retaining pane input and session behavior |
| `tab_strip_path` | An instance of `TerminalTabBar.tscn` (or compatible `bind_host`/`tabs` adapter) |
| `tile_button_path` | Button to toggle tiling |
| `split_right_button_path` | Optional extra control to split the focused pane right; default controls live on each pane |
| `split_down_button_path` | Optional extra control to split the focused pane down; default controls live on each pane |
| `overview_button_path` | Button to show the surrounding stash space |
| `main_button_path` | Button to return to the main area |

Empty paths use defaults. `show_tab_strip` and `show_workspace_controls` hide
chrome independently. Custom controls retain parent/layout. The underlying
factory `host.ui.create_terminal_space(scene)` returns an unparented instance.

### Pane chrome ownership

`pane-header/main.js` paints headers; PaneHeader.tscn owns geometry/input and
retains a hidden Title label for font metrics. Theme overrides may change title
size/color. WorkspacePane owns commands/drag; WorkspaceView owns projection.
Title changes refresh props without resizing terminal viewports.

The bundled `pane-strip` mod is drawn per pane in the canvas, with camera/effect
projection. Users can replace it with a mod; world scenes cannot replace it.
Browser frame updates are independent of geometry.

Switching away removes presentation but preserves split trees, stashes, and PTYs.
Returning restores them. `tests/terminal_space_smoke.gd` checks both modes.

### Antialiasing

The project uses 4× MSAA for scenery. A world may override its viewport policy
or `_configure_scenery_antialiasing()`. Ink disables MSAA and screen AA to preserve
native glyph sampling. Custom renderers choose their own passes.

## Optional ordinary Godot controls

### Standard tab strip asset

`TerminalTabBar.tscn` wraps the shared TabStrip: trailing plus, close buttons,
middle-click close, drag preview, shrink-before-scroll, and overflow scrolling.
ChromiumTabStrip uses the same core with different metadata/session commands.

```gdscript
var strip = host.ui.create_tab_strip()
strip.theme = my_theme # optional; inherited Themes also work
$HUD.add_child(strip)
```

For authored scenes, call `strip.bind_host(host)` or set `host_path`.
Style the TerminalTab Theme states and reserve right padding for close.
`minimum_tab_width` / `maximum_tab_width` control sizing; `strip.tabs.plus`
is the plus button.

| Host operation | Effect |
| --- | --- |
| `create_session()` | New tab |
| `request_close_tab(id)` | Close the tab, asking for confirmation where needed. Omitted ID means active tab. |
| `request_close_session()` | Ask to end the active server session and all its tabs. |
| `move_session(id,index)` | Reorder workspace/keyboard navigation without restarting PTYs |

IDs remain stable independently of order. For a custom adapter,
`TabStrip.reconcile(items,selected_id)` takes id/title and optional tooltip/icon.
Handle selected/closed/moved/new_tab signals, then reconcile authoritative order.
The strip core itself owns no sessions.

### Individually bound controls

```gdscript
host.ui.bind($MyTabs, "tabs")             # TabBar
host.ui.bind($MyProgress, "progress")     # ProgressBar, follows active session
host.ui.bind($MyScroll, "scroll")         # HScrollBar or VScrollBar
host.ui.bind($MyTitle, "title")           # Label
host.ui.bind($OtherProgress, "progress", 2) # pinned to session 2
```

Factories `create_tab_bar()`, `create_progress_bar(id=-1)`,
`create_scroll_bar(id=-1)`, and `create_title_label(id=-1)` return unparented controls.
Binding starts on tree entry; bind once. Freeing the control disconnects it.

Bindings own data properties: entries/selection, title, progress state/value,
and scroll range/page/value/visibility. Tabs and scrollbars avoid keyboard focus.
The world owns theme, layout, and animation. Use models for different behavior.

## Custom 3D logic, with no standard chrome

Override `_build_ui()` on a TerminalWorld; `tabs` and `status` may remain null.

```gdscript
var host: Node

func _ready() -> void:
    host.ui_changed.connect(_refresh)
    _refresh()

func _refresh() -> void:
    var session = host.active_session()
    if session == null:
        return
    $Label3D.text = session.title
    $Gauge.visible = session.progress_state != 0
    if session.progress_value >= 0:
        $Gauge.scale.x = maxf(session.progress_value / 100.0, 0.001)
    # Drive your own materials/animations for ERROR, PAUSED or INDETERMINATE.

func clicked_world_terminal(id: int) -> void:
    host.select_session(id)
```

| API | Identity |
| --- | --- |
| `get_tabs()`, `select_workspace(id)` | Workspace IDs; a workspace may contain multiple terminals |
| `get_terminal_tabs()`, `select_session(id)` | Terminal destinations |

`get_tabs()` returns id/label/title/active/opened/progress_state/progress_value/
exited/chromium_count. `ui_changed` covers state and catalog/selection changes;
`session_added` and `active_session_changed` are narrower signals.

Register destinations with `set_tabs([{id: 0, label: "Desk"}, …])` and handle
`session_requested(id)`. Selection requests navigation; it does not move cameras.
Fully custom renderers also own placement and the `session_for(id,presenter)` /
`activate_session(pair)` lifecycle. The shared kit already handles these steps.
