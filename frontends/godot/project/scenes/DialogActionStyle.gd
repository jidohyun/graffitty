extends RefCounted
## Consistent action colors for tab and session close dialogs.


static func apply(button: Button, color: Color) -> void:
	for state in ["normal", "hover", "pressed"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBoxFlat
		if style == null:
			continue
		style.bg_color = color.lightened(.12) if state == "hover" else color.darkened(.15) if state == "pressed" else color
		button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, Color.WHITE)
