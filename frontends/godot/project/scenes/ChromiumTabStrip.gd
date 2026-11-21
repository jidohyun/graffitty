extends "res://scenes/TabStrip.gd"


## Chromium metadata adapter; dragging, layout and controls are shared.
func _init() -> void:
	tab_theme_type = "ChromiumTab"
	connected_tabs = true
	connected_text_outline = false
	maximum_tab_width = 240.0
	minimum_tab_width = 64.0


func _fit_button(button: Button, width: float, height: float) -> void:
	# Chromium's Tab::UpdateIconVisibility prioritizes the active close button;
	# narrow inactive tabs retain their favicon. Overflow and dragging stay in
	# the same TabStrip/TabStripNavigation used by workspace tabs.
	var narrow := width < 100.0
	button.text = "" if narrow else str(button.get_meta("title", ""))
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if narrow and not button.button_pressed else HORIZONTAL_ALIGNMENT_LEFT
	var left := 6.0 if narrow else 10.0
	var right := 6.0 if narrow and not button.button_pressed else 30.0
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style: StyleBox = button.get_theme_stylebox(state)
		if style.content_margin_left != left or style.content_margin_right != right:
			style = style.duplicate()
			style.content_margin_left = left
			style.content_margin_right = right
			button.add_theme_stylebox_override(state, style)
	super._fit_button(button, width, height)


func _update_close_visibility(button: Button, pointer_over := false) -> void:
	if not is_instance_valid(button) or button.is_queued_for_deletion(): return
	if button.size.x < 100.0:
		button.get_node("Close").visible = button.button_pressed and button.size.x >= minimum_tab_width
	else:
		super._update_close_visibility(button, pointer_over)


## Chromium tabs only reorder: their leading edge crosses the neighbour's
## midpoint, regardless of where inside the tab the pointer grabbed it.
func _placement(x: float, others: Array, gap: int) -> Dictionary:
	var slot := _tab_width + 3.0
	var left := x - _grab_offset
	var index := clampi(gap, 0, others.size())
	while index < others.size() and left + _tab_width > (index + 1) * slot + _tab_width * 0.5:
		index += 1
	while index > 0 and left < (index - 1) * slot + _tab_width * 0.5:
		index -= 1
	return { "index": index, "hover": -1 }


func _update_icon(button: Button, page: Dictionary) -> void:
	var id := int(page.id)
	button.tooltip_text = str(page.get("title", tr("New tab"))) + "\n" + str(page.get("url", ""))
	var key := "loading" if page.get("loading", false) else str(page.get("favicon", ""))
	if _icon_keys.get(id, "!") == key:
		return
	_icon_keys[id] = key
	if icon_factory.is_valid():
		button.icon = icon_factory.call("reload" if key == "loading" else "globe")
	if not key.is_empty() and key != "loading" and key.length() < 45000:
		var image := Image.new()
		if image.load_png_from_buffer(Marshalls.base64_to_raw(key)) == OK:
			image.resize(32, 32, Image.INTERPOLATE_LANCZOS)
			button.icon = ImageTexture.create_from_image(image)
