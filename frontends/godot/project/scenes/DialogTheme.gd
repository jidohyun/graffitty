extends RefCounted
## Shared application dialogs; native window decorations remain OS-owned.
const Accent := preload("res://scenes/UIAccent.gd")

static func surface(color: Color, radius: int, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.corner_detail = 16
	box.set_content_margin_all(12)
	return box


static func apply(theme: Theme) -> void:
	Accent.apply(theme)
	var panel := surface(Color("242830"), 16, Color("414853"))
	panel.set_border_width_all(0)
	panel.corner_radius_top_left = 0
	panel.corner_radius_top_right = 0
	panel.content_margin_top = 12
	panel.content_margin_bottom = 12
	theme.set_stylebox("panel", "AcceptDialog", panel)
	for state in ["embedded_border", "embedded_unfocused_border"]:
		var frame: StyleBoxFlat = ThemeDB.get_default_theme().get_stylebox(state, "Window").duplicate()
		frame.bg_color = Color("242830")
		frame.border_color = Color("414853")
		frame.set_border_width_all(1)
		frame.set_corner_radius_all(18)
		frame.corner_detail = 16
		frame.shadow_color = Color(0, 0, 0, .35)
		frame.shadow_size = 12
		frame.shadow_offset = Vector2(0, 5)
		theme.set_stylebox(state, "Window", frame)
	theme.set_color("title_color", "Window", Color("edf0f5"))
	theme.set_color("title_outline_modulate", "Window", Color.TRANSPARENT)
	theme.set_color("font_color", "Label", Color("d8dde6"))
	theme.set_constant("buttons_min_width", "AcceptDialog", 104)
	theme.set_constant("buttons_min_height", "AcceptDialog", 42)
	theme.set_constant("buttons_separation", "AcceptDialog", 12)
	for entry in [["normal", "343b46"], ["hover", "424c5b"], ["pressed", "2a313c"], ["disabled", "292e36"]]:
		var button := surface(Color(entry[1]), 10, Color("515c6c"))
		button.content_margin_left = 14
		button.content_margin_right = 14
		button.content_margin_top = 6
		button.content_margin_bottom = 6
		theme.set_stylebox(entry[0], "Button", button)
	# Button's custom padding must not leak into the base Button text layout
	# while CheckBox/CheckButton draw their indicators using native padding.
	# Pin each toggle's styles so both drawing paths resolve the same margins.
	for kind in ["CheckBox", "CheckButton"]:
		for state in ["normal", "hover", "pressed", "disabled", "hover_pressed", "focus"]:
			theme.set_stylebox(state, kind, ThemeDB.get_default_theme().get_stylebox(state, kind).duplicate())
		theme.set_constant("h_separation", kind, 8)
	var focus := surface(Color.TRANSPARENT, 11, Accent.ACCENT)
	focus.draw_center = false
	focus.set_border_width_all(2)
	focus.set_expand_margin_all(2)
	theme.set_stylebox("focus", "Button", focus)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, "Button", Color("eef2f8"))
	theme.set_color("font_disabled_color", "Button", Color("838c99"))
