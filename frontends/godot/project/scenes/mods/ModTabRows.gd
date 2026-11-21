extends "res://scenes/TabListRows.gd"
## Native scrolling/focus/gesture adapter; JavaScript owns row presentation.
const Service := preload("res://scenes/mods/ModService.gd")

func populate(items: Array, active_id: int, font: Font, font_size: int, foreground: Color, background: Color) -> void:
 var same := rows.size() == items.size()
 if same:
  for i in rows.size():
   if rows[i].get_meta("identity") != Search.identity(items[i]): same = false; break
 if not same:
  for row in rows: box.remove_child(row); row.queue_free()
  rows.clear()
  selected = -1
 row_height = ceilf(font.get_height(font_size + 2) + font.get_height(maxi(10, font_size - 3)) + 24)
 for i in items.size():
  var item: Dictionary = items[i]
  var is_pane: bool = item.get("kind", "tab") == "pane"
  if not same:
   var row := Button.new()
   row.focus_mode = Control.FOCUS_NONE
   row.toggle_mode = true
   row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
   for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
    row.add_theme_stylebox_override(state, StyleBoxEmpty.new())
   row.set_meta("id", int(item.id))
   row.set_meta("identity", Search.identity(item))
   row.set_meta("kind", item.get("kind", "tab"))
   row.set_meta("pane_key", item.get("pane_key", ""))
   var view := preload("res://scenes/mods/EmbeddedMod.gd").create("tab-menu", {})
   row.add_child(view)
   view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
   row.set_meta("mod_view", view)
   row.pressed.connect(func(): select(i); item_clicked.emit(i, Vector2.ZERO, MOUSE_BUTTON_LEFT))
   row.mouse_entered.connect(func(): _publish_row(row, true))
   row.mouse_exited.connect(func(): _publish_row(row, false))
   box.add_child(row)
   rows.append(row)
  var row := rows[i]
  row.custom_minimum_size.y = ceilf(font.get_height(font_size + 2) + 16) if is_pane or not item.get("show_details", true) else row_height
  var badges := []
  for agent in item.get("agents", []):
   var badge := Service.agent_badge(str(agent.provider), str(agent.status), agent.get("manifest", {}), [])
   badge["count"] = agent.get("count", 1)
   badges.append(badge)
  row.tooltip_text = str(item.title) + "\n" + str(item.get("pane_tooltip", ""))
  row.set_meta("mod_props", {"item": item, "badges": badges, "font_size": font_size, "foreground": "#" + foreground.to_html(), "background": "#" + background.to_html()})
  _publish_row(row)
  if not same and not is_pane and int(item.id) == active_id: select(i)

func _publish_row(row: Button, hover := false) -> void:
 var props: Dictionary = row.get_meta("mod_props", {}).duplicate()
 props["selected"] = row.button_pressed
 props["hover"] = hover
 row.get_meta("mod_view").set_props(JSON.stringify(props))

func select(index: int, update_anchor := true) -> void:
 super(index, update_anchor)
 for row in rows: _publish_row(row)
