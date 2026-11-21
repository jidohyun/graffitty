extends Control
## Native geometry/gesture adapter for the pane-header mod. The hidden Label
## supplies font metrics and inherited scene styling, never painted chrome.
signal title_input(event: InputEvent)
signal action_requested(action: StringName)
const ACTIONS := [&"filetree", &"chromium", &"split_right", &"split_down", &"close"]
const Badge := preload("res://scenes/AgentStatusBadge.gd")
var terminal_actions := true
var compact := false
var compact_close := false
var available_width := INF
var hovered := false
var touch_actions := false
var agent_status := ""
var status_strip_shown := false
var filetree_open := false
var view: Control
var _syncing := false
var title: Label:
 get: return get_node("Title")

func _ready() -> void:
 title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
 title.mouse_filter = Control.MOUSE_FILTER_IGNORE
 title.modulate.a = 0.0
 mouse_filter = Control.MOUSE_FILTER_PASS
 set_process(false)
 view = preload("res://scenes/mods/EmbeddedMod.gd").create("pane-header", {})
 view.mouse_filter = Control.MOUSE_FILTER_STOP
 view.focus_mode = Control.FOCUS_NONE
 add_child(view)
 view.gui_input.connect(_view_input)
 add_to_group(&"pane_header_%d" % int(view.copy_id()))
 resized.connect(_sync)
 set_touch_presentation(preload("res://scenes/input/InteractionProfile.gd").touch_controls())
 _sync()

func _view_input(event: InputEvent) -> void:
 if event is InputEventMouseButton or event is InputEventMouseMotion:
  if action_at(get_global_transform() * event.position).is_empty():
   var translated: InputEvent = event.duplicate()
   translated.position -= title.position
   title_input.emit(translated)

func configure(is_terminal: bool) -> void:
 terminal_actions = is_terminal
 _sync()

func set_touch_presentation(enabled: bool) -> void:
 touch_actions = enabled
 _sync()

func set_compact(value: bool, show_close := false) -> void:
 if compact == value and compact_close == show_close: return
 compact = value
 compact_close = show_close
 _sync()

func set_available_width(value: float) -> void:
 if is_equal_approx(available_width, value): return
 available_width = value
 _sync()

func set_hovered(value: bool) -> void:
 if hovered == value: return
 hovered = value
 _sync()

func set_status_strip_shown(value: bool) -> void:
 if status_strip_shown == value: return
 status_strip_shown = value
 _sync()

func set_agent_status(status: String) -> void:
 var shown := status if status in ["waiting", "blocked"] else ""
 if agent_status == shown: return
 agent_status = shown
 _sync()

func set_filetree_open(active: bool) -> void:
 if filetree_open == active: return
 filetree_open = active
 _sync()

func _sync() -> void:
 if view == null or _syncing: return
 _syncing = true
 var width := minf(available_width, size.x if size.x > 0 else 400.0)
 view.size = Vector2(maxf(1, width), maxf(30, size.y))
 preload("res://scenes/mods/EmbeddedMod.gd").set_props(view, {"part": "header", "width": width, "terminal": terminal_actions,
  "compact": compact, "compact_close": compact_close, "hovered": hovered, "touch": touch_actions, "status": agent_status,
  "status_label": Badge.status_label(agent_status), "status_strip": status_strip_shown,
  "filetree_open": filetree_open, "gap": get_theme_constant("separation", "HBoxContainer"),
  "icon_color": "#" + get_theme_color("icon_normal_color", "Button").to_html(),
  "tooltips": {
   "filetree": "Close filetree for this pane" if filetree_open else "Open filetree for this pane",
   "chromium": "Open a new Chromium for this terminal", "close": "Close pane",
   "split_right": "Tap: new pane right. Press and hold: new pane left." if touch_actions else "Left-click: new pane right. Right-click: new pane left.",
   "split_down": "Tap: new pane below. Press and hold: new pane above." if touch_actions else "Left-click: new pane below. Right-click: new pane above.",
  }})
 var error: String = view.render_now()
 if not error.is_empty(): push_error("Pane header: " + error)
 var rect: Rect2 = view.hit_rect("title")
 title.position = rect.position
 title.size = rect.size
 _syncing = false

func has_part(part: String) -> bool:
 return view != null and view.hit_rect(part).has_area()

## Rectangles in header-local coordinates, from the same Rust layout that paints.
func part_rect(part: String) -> Rect2:
 return view.hit_rect(part) if view != null else Rect2()

func action_at(sheet_point: Vector2) -> String:
 if not is_visible_in_tree(): return ""
 var local := get_global_transform().affine_inverse() * sheet_point
 for action in ACTIONS:
  if part_rect(action).has_point(local): return action
 return ""

## ModService routes by copy identity, never by the currently focused pane.
func activate(action: String) -> void:
 if action in ACTIONS and has_part(action): action_requested.emit(StringName(action))

func _notification(what: int) -> void:
 if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_TRANSLATION_CHANGED:
  if is_node_ready(): _sync()
