extends "res://scenes/ElasticScrollContainer.gd"
## Two-line, keyboard-navigable rows with a separate pane-count tooltip target.
signal item_clicked(index: int, at: Vector2, button: int)
signal item_activated(index: int)
var rows: Array[Button] = []
var selected := -1
var box := VBoxContainer.new()
var item_count: int:
 get: return rows.size()
var row_height := 60.0
var icon: Texture2D
var _scroll_remainder := 0.0
var _scroll_anchor := 0.0
## The highlighted row's place and the content height the anchor was measured
## against. Laying rows out moves the scroll too.
var _anchor_layout := -Vector2.ONE
var _revealing_selection := false
const TOUCH_SLOP := 12.0
var _touches: Dictionary = {}
var _touch_origin := Vector2.ZERO
var _touch_last := Vector2.ZERO
var _touch_identity := ""
var _touch_dragged := false
var _touch_canceled := false
const Search := preload("res://scenes/TabListSearch.gd")
const MatchLabel := preload("res://scenes/SearchMatchLabel.gd")

func _ready() -> void:
 focus_mode = Control.FOCUS_ALL
 horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
 # touch_navigation owns fingers, including row activation.
 handles_touch = false
 box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
 box.add_theme_constant_override("separation", 2)
 add_child(box)
 get_v_scroll_bar().value_changed.connect(_scrolled)
 # Exports ship the imported texture, not the raw SVG.
 icon = preload("res://scenes/AgentStatusBadge.gd").icon("layout-template.svg")

func populate(items: Array, active_id: int, font: Font, font_size: int, foreground: Color, background: Color) -> void:
 var same := rows.size() == items.size()
 if same:
  for i in rows.size():
   if rows[i].get_meta("identity") != Search.identity(items[i]): same = false; break
 if not same:
  for row in rows: box.remove_child(row); row.queue_free()
  rows.clear()
  selected = -1
 var title_size := font_size + 2
 var detail_size := maxi(10, font_size - 3)
 row_height = ceilf(font.get_height(title_size) + font.get_height(detail_size) + 24)
 for i in items.size():
  var item: Dictionary = items[i]
  var is_pane: bool = item.get("kind", "tab") == "pane"
  var minimum_height := ceilf(font.get_height(title_size) + 16) if is_pane or not item.get("show_details", true) else row_height
  if not same:
   var row := Button.new()
   row.focus_mode = Control.FOCUS_NONE
   row.toggle_mode = true
   row.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
   row.alignment = HORIZONTAL_ALIGNMENT_LEFT
   row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
   row.custom_minimum_size.y = minimum_height
   row.set_meta("id", int(item.id))
   row.set_meta("identity", Search.identity(item))
   row.set_meta("kind", item.get("kind", "tab"))
   row.set_meta("pane_key", item.get("pane_key", ""))
   for state in ["normal", "hover", "pressed", "hover_pressed"]:
    var style := StyleBoxFlat.new()
    style.bg_color = background.lerp(foreground, 0.12 if state.contains("pressed") else (0.06 if state == "hover" else 0.0))
    style.set_corner_radius_all(4)
    row.add_theme_stylebox_override(state, style)
   var content := VBoxContainer.new()
   content.mouse_filter = Control.MOUSE_FILTER_IGNORE
   content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
   content.offset_left = 30 if is_pane else 10; content.offset_right = -10
   content.offset_top = 8; content.offset_bottom = -8
   content.add_theme_constant_override("separation", 4)
   row.add_child(content)
   var title := MatchLabel.new()
   title.name = "Title"
   title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
   title.configure(font, title_size, foreground)
   content.add_child(title)
   var detail := HFlowContainer.new()
   detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
   detail.add_theme_constant_override("h_separation", 16)
   detail.add_theme_constant_override("v_separation", 4)
   content.add_child(detail)
   content.minimum_size_changed.connect(func(): row.custom_minimum_size.y = maxf(minimum_height, content.get_combined_minimum_size().y + 16))
   row.set_meta("detail", detail)
   row.set_meta("agent_groups", {})
   var panes := Button.new()
   panes.name = "Panes"
   panes.flat = true
   panes.focus_mode = Control.FOCUS_NONE
   panes.icon = icon
   panes.expand_icon = false
   panes.add_theme_constant_override("icon_max_width", detail_size + 2)
   panes.add_theme_font_override("font", font)
   panes.add_theme_font_size_override("font_size", detail_size)
   panes.add_theme_color_override("font_color", foreground.lerp(background, .2))
   # Match the resource SVG stroke color and its dimmed tint.
   var icon_color := Color("#c8d2df") * foreground.lerp(background, .25)
   for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
    panes.add_theme_color_override("icon_" + state + "_color", icon_color)
   for state in ["normal", "hover", "pressed", "focus"]: panes.add_theme_stylebox_override(state, StyleBoxEmpty.new())
   detail.add_child(panes)
   row.set_meta("title_label", title)
   row.set_meta("panes_button", panes)
   var icons := preload("res://scenes/PaneIcons.gd")
   for metric in ["cpu", "ram"]:
    var group := HBoxContainer.new()
    group.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS
    group.mouse_filter = Control.MOUSE_FILTER_PASS
    group.tooltip_text = "Total CPU usage" if metric == "cpu" else "Total RAM usage"
    group.add_theme_constant_override("separation", 5)
    var symbol := TextureRect.new()
    symbol.texture = icons.cpu() if metric == "cpu" else icons.ram()
    symbol.mouse_filter = Control.MOUSE_FILTER_IGNORE
    symbol.custom_minimum_size = Vector2(detail_size + 2, detail_size + 2)
    symbol.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    symbol.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    symbol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    symbol.modulate = foreground.lerp(background, .25)
    group.add_child(symbol)
    var value := Label.new()
    value.mouse_filter = Control.MOUSE_FILTER_IGNORE
    value.add_theme_font_override("font", font)
    value.add_theme_font_size_override("font_size", detail_size)
    value.add_theme_color_override("font_color", foreground.lerp(background, .25))
    group.add_child(value)
    detail.add_child(group)
    row.set_meta(metric + "_label", value)
   row.pressed.connect(func(): select(i); item_clicked.emit(i, Vector2.ZERO, MOUSE_BUTTON_LEFT))
   panes.pressed.connect(func(): select(i); item_clicked.emit(i, Vector2.ZERO, MOUSE_BUTTON_LEFT))
   box.add_child(row)
   rows.append(row)
  var row := rows[i]
  var prefix := "↳ %d.%d · " % [item.ordinal, item.pane_ordinal] if is_pane else "%d: " % item.get("ordinal", i+1)
  row.get_meta("title_label").set_match(str(item.title), item.get("match_indices", PackedInt32Array()), prefix)
  row.get_meta("detail").visible = not is_pane and item.get("show_details", true)
  row.tooltip_text = item.title
  row.get_meta("panes_button").text = str(item.get("pane_count", 0))
  row.get_meta("panes_button").tooltip_text = item.get("pane_tooltip", "")
  var resources: Dictionary = item.get("resources", {})
  for metric in ["cpu", "ram"]:
   row.get_meta(metric + "_label").text = resources.get(metric, "—")
  _update_agents(row, item.get("agents", []), font, detail_size, foreground)
  if not same and not is_pane and int(item.id) == active_id: select(i)

func _update_agents(row: Button, agents: Array, font: Font, font_size: int, foreground: Color) -> void:
 var groups: Dictionary = row.get_meta("agent_groups")
 var wanted := {}
 var detail: Control = row.get_meta("detail")
 for agent: Dictionary in agents:
  var manifest: Dictionary = agent.get("manifest", {})
  var key: String = agent.provider + ":" + agent.status + ":" + str(manifest.get("name", ""))
  wanted[key] = true
  if not groups.has(key):
   var group := HBoxContainer.new()
   group.mouse_filter = Control.MOUSE_FILTER_PASS
   group.add_theme_constant_override("separation", 4)
   var badge := preload("res://scenes/AgentStatusBadge.gd").new()
   group.add_child(badge)
   var count := Label.new()
   count.mouse_filter = Control.MOUSE_FILTER_IGNORE
   count.add_theme_font_override("font", font)
   count.add_theme_font_size_override("font_size", font_size)
   count.add_theme_color_override("font_color", foreground)
   group.add_child(count)
   detail.add_child(group)
   groups[key] = group
  var group: HBoxContainer = groups[key]
  var badge: Node = group.get_child(0)
  badge.set_agent(agent.provider, agent.status, manifest)
  badge.tooltip_text = "%s · %s\n%s" % [str(manifest.get("name", str(agent.provider).capitalize())), preload("res://scenes/AgentStatusBadge.gd").status_label(str(agent.status)), "\n".join(agent.titles)]
  group.tooltip_text = badge.tooltip_text
  group.get_child(1).text = str(agent.count) if agent.count > 1 else ""
  detail.move_child(group, detail.get_child_count() - 1)
 for key in groups.keys():
  if not wanted.has(key):
   detail.remove_child(groups[key])
   groups[key].queue_free()
   groups.erase(key)

func select(index: int, update_anchor := true) -> void:
 selected = index
 for i in rows.size(): rows[i].set_pressed_no_signal(i == index)
 if update_anchor: _update_scroll_anchor()

func _update_scroll_anchor() -> void:
 if selected >= 0 and selected < rows.size():
  _scroll_anchor = clampf(rows[selected].position.y + rows[selected].size.y * 0.5 - scroll_vertical, 0, size.y)
  _anchor_layout = Vector2(rows[selected].position.y, box.size.y)

func _scrolled(value: float) -> void:
 # Touch scrolling and scrollbar dragging move the highlight with the
 # content. Revealing a keyboard/wheel selection must not select a second row.
 if _revealing_selection or selected < 0 or rows.is_empty(): return
 # Rows laid out after the selection, as when the menu opens, move the
 # scroll as well. Re-measure the highlight there instead of following it.
 if Vector2(rows[selected].position.y, box.size.y) != _anchor_layout:
  _update_scroll_anchor()
  return
 var nearest := selected
 var distance := INF
 for i in rows.size():
  var candidate := absf(rows[i].position.y + rows[i].size.y * 0.5 - value - _scroll_anchor)
  if candidate < distance:
   distance = candidate
   nearest = i
 select(nearest, false)
 _anchor_layout = Vector2(rows[nearest].position.y, box.size.y)

func get_item_metadata(index: int) -> int:
 return int(rows[index].get_meta("id"))

func get_item_identity(index: int) -> String:
 return str(rows[index].get_meta("identity")) if index >= 0 and index < rows.size() else ""

func select_identity(identity: String) -> void:
 select(-1)
 for i in rows.size():
  if get_item_identity(i) == identity: select(i); return

func content_height() -> float:
 var total := 0.0
 for row in rows: total += row.get_combined_minimum_size().y + 2
 return total

func get_item_rect(index: int) -> Rect2:
 return Rect2(rows[index].global_position - global_position, rows[index].size)

func ensure_current_is_visible() -> void:
 if selected >= 0 and selected < rows.size():
  _revealing_selection = true
  ensure_control_visible(rows[selected])
  _revealing_selection = false
  _update_scroll_anchor()

func reset_scroll_navigation() -> void:
 _scroll_remainder = 0.0
 reset_touch_navigation()

func reset_touch_navigation() -> void:
 _touches.clear()
 _touch_identity = ""
 _touch_dragged = false
 _touch_canceled = false
 stop_scrolling()

func _row_at(at: Vector2) -> int:
 if not get_global_rect().has_point(at): return -1
 for i in rows.size():
  if rows[i].get_global_rect().has_point(at): return i
 return -1

func touch_navigation(event: InputEvent) -> bool:
 # Own raw touch before child buttons, including the mouse events Godot
 # synthesizes before each touch. Desktop mouse clicks keep their usual path.
 if event is InputEventMouse and event.device == -1:
  return not _touches.is_empty() or (is_visible_in_tree() and get_global_rect().has_point(event.position))
 if event is InputEventScreenTouch:
  if event.pressed:
   if _touches.is_empty():
    if not is_visible_in_tree() or not get_global_rect().has_point(event.position): return false
    _touch_origin = event.position
    _touch_last = event.position
    _touch_identity = get_item_identity(_row_at(event.position))
    _touch_canceled = false
    # A tap that brakes a fling must not also open the row beneath it.
    _touch_dragged = gliding()
    elastic_touch_begin()
   else:
    # Additional fingers cancel activation and scrolling until all lift.
    _touch_identity = ""
    _touch_dragged = true
    _touch_canceled = true
    elastic_touch_end(false)
   _touches[event.index] = true
  elif _touches.has(event.index):
   _touches.erase(event.index)
   _touch_canceled = _touch_canceled or event.canceled
   if _touches.is_empty():
    var index := _row_at(event.position)
    var activate: bool = not _touch_canceled and not _touch_dragged and event.position.distance_to(_touch_origin) <= TOUCH_SLOP and not _touch_identity.is_empty() and get_item_identity(index) == _touch_identity
    elastic_touch_end(not _touch_canceled and _touch_dragged)
    _touch_identity = ""
    if activate:
     select(index)
     item_clicked.emit(index, event.position, MOUSE_BUTTON_LEFT)
  else:
   return false
  return true
 if event is InputEventScreenDrag and _touches.has(event.index):
  if _touches.size() != 1 or _touch_canceled: return true
  var delta: Vector2 = event.position - _touch_last
  _touch_last = event.position
  if not _touch_dragged:
   var displacement: Vector2 = event.position - _touch_origin
   if displacement.length() <= TOUCH_SLOP: return true
   _touch_dragged = true
   # Subtract the threshold so crossing it doesn't jump the content.
   delta = displacement - displacement.normalized() * TOUCH_SLOP
  elastic_touch_move(Vector2(0, delta.y))
  return true
 return false

func scroll_selection(event: InputEvent) -> bool:
 var amount := 0.0
 if event is InputEventMouseButton:
  if event.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]: return false
  if not event.pressed: return true
  amount = event.factor * (-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
 elif event is InputEventPanGesture:
  amount = event.delta.y
 else:
  return false
 if rows.is_empty(): return true
 stop_scrolling()
 if amount * _scroll_remainder < 0: _scroll_remainder = 0.0
 _scroll_remainder += amount
 var steps := int(_scroll_remainder)
 if steps != 0:
  _scroll_remainder -= steps
  select(clampi((selected if selected >= 0 else 0) + steps, 0, rows.size() - 1))
  ensure_current_is_visible()
 return true

func _gui_input(event: InputEvent) -> void:
 if navigate(event): accept_event()

func navigate(event: InputEvent) -> bool:
 if not event is InputEventKey or not event.pressed or event.alt_pressed or event.meta_pressed or event.ctrl_pressed: return false
 if rows.is_empty(): return event.keycode in [KEY_UP, KEY_DOWN, KEY_PAGEUP, KEY_PAGEDOWN, KEY_TAB, KEY_ENTER, KEY_KP_ENTER]
 var next := selected
 match event.keycode:
  KEY_UP: next = rows.size() - 1 if next < 0 else wrapi(next - 1, 0, rows.size())
  KEY_DOWN: next = 0 if next < 0 else wrapi(next + 1, 0, rows.size())
  KEY_TAB:
   next = (rows.size() - 1 if event.shift_pressed else 0) if next < 0 else wrapi(next + (-1 if event.shift_pressed else 1), 0, rows.size())
  KEY_PAGEUP: next -= maxi(1, int(size.y / row_height))
  KEY_PAGEDOWN: next += maxi(1, int(size.y / row_height))
  KEY_ENTER, KEY_KP_ENTER:
   if selected >= 0: item_activated.emit(selected)
   return true
  _: return false
 stop_scrolling()
 select(clampi(next, 0, maxi(rows.size()-1, 0)))
 ensure_current_is_visible()
 return true
