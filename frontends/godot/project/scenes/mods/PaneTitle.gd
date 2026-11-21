extends Label
## Keep Godot's inherited font metrics/title fitting API, but paint only through
## the pane-header mod. Native text is transparent; self_modulate does not tint
## the child renderer. Redraw/theme/size notifications publish changes, no timer.
var view: Control
func _ready() -> void:
 self_modulate.a = 0.0
 mouse_filter = Control.MOUSE_FILTER_IGNORE
 view = preload("res://scenes/mods/EmbeddedMod.gd").create("pane-header", {})
 add_child(view)
 _sync()

func _draw() -> void:
 _sync()

func _sync() -> void:
 if view == null: return
 view.size = size
 preload("res://scenes/mods/EmbeddedMod.gd").set_props(view, {"part": "title", "text": text,
  "font_size": get_theme_font_size("font_size"), "color": "#" + get_theme_color("font_color").to_html()})

func _notification(what: int) -> void:
 if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_RESIZED:
  _sync()
