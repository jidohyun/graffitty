extends RefCounted
## Shared vector icons and hover surfaces for tab-strip actions.


static func apply(
	button: Button,
	path: String,
	radius: int,
	diameter := 28.0,
	background := Color.TRANSPARENT,
) -> void:
	button.text = ""
	button.icon = DPITexture.create_from_string(
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="%s" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
		% path
	)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	apply_surface(button, radius, diameter, background)


static func apply_surface(
	button: Button,
	radius: int,
	diameter := 28.0,
	background := Color.TRANSPARENT,
) -> void:
	button.custom_minimum_size = Vector2.ONE * diameter
	button.flat = false
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var style := StyleBoxFlat.new()
		var opacity := (
			0.10
			if state == "hover"
			else (0.16 if state in ["pressed", "hover_pressed"] else 0.0)
		)
		style.bg_color = background.blend(Color(1, 1, 1, opacity))
		style.set_corner_radius_all(radius)
		style.corner_detail = 12
		style.set_content_margin_all((diameter - 16.0) * 0.5)
		button.add_theme_stylebox_override(state, style)
