extends CanvasLayer
var host: Node
var root: PanelContainer
var preview: TextureRect
var status: Label
var active: Node
var picker: OptionButton
var close_dialog: ConfirmationDialog
var chrome: Control
var native_button: Button
var return_button: Button
var warning: Label
var _chromium_focus := false
var _arrival := 1.6
var _outgoing: Array[Dictionary] = []


func _ready() -> void:
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.BROWSER
	root = PanelContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var column := VBoxContainer.new()
	root.add_child(column)
	warning = Label.new()
	warning.text = "Chromium sandbox disabled · do not use credentials or sensitive sites"
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(warning)
	var actions := HBoxContainer.new()
	column.add_child(actions)
	chrome = preload("res://scenes/ChromiumChrome.gd").new()
	column.add_child(chrome)
	chrome.close_session_requested.connect(_confirm_close)
	picker = OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.focus_mode = Control.FOCUS_NONE
	actions.add_child(picker)
	picker.item_selected.connect(
		func(i):
			host.select_chromium_surface(picker.get_item_id(i)),
	)
	for label in ["Open full Chrome UI", "Return to preview"]:
		var button := Button.new()
		button.text = label
		button.focus_mode = Control.FOCUS_NONE
		actions.add_child(button)
		if label.begins_with("Open"):
			native_button = button
			button.pressed.connect(
				func():
					if active != null:
						active.open_native(),
			)
		else:
			return_button = button
			button.pressed.connect(
				func():
					if active != null:
						active.return_to_preview(),
			)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	var close_button := Button.new()
	close_button.text = "Close chromium window"
	close_button.focus_mode = Control.FOCUS_NONE
	column.add_child(close_button)
	close_button.pressed.connect(_confirm_close)
	preview = TextureRect.new()
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	column.add_child(preview)
	preview.gui_input.connect(
		func(event):
			if (
				event is InputEventMouseButton and event.pressed
				and event.button_index == MOUSE_BUTTON_LEFT and active != null
			):
				active.open_native(),
	)
	host.ui_changed.connect(refresh)
	refresh()


func refresh() -> void:
	if root == null:
		return
	root.offset_top = host.layout_root.offset_top
	var next: Node = host.visible_chromium()
	if next != active:
		_retire_panel()
		_arrival = 0.0
		root.modulate.a = 0.0
		_chromium_focus = false
	active = next
	root.visible = active != null
	if active != null:
		warning.visible = active.chromium_ready and not active.sandbox_enabled
		native_button.visible = active.can_open_native()
		return_button.visible = active.native_visible and active.can_open_native()
		chrome.refresh(active)
		var split := float(host.workspaces[active.tab_id].split)
		root.anchor_left = split
		root.offset_left = host.layout_root.offset_left * (1.0 - split) + host.layout_root.offset_right * split + 4
		root.offset_right = host.layout_root.offset_right
		status.text = active.status
		preview.texture = active.texture if active.captured_page_id == active.selected_page_id else null
		var ids: Array = host.workspaces[active.tab_id].chromiums
		if picker.get_meta("ids", []) != ids:
			picker.clear()
			for id in ids:
				picker.add_item(tr("Chromium %d") % id, id)
			picker.set_meta("ids", ids.duplicate())
		picker.select(picker.get_item_index(active.session_id))


func _retire_panel() -> void:
	if active == null or root.modulate.a <= 0.001:
		return
	var ghost := Control.new()
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.modulate.a = root.modulate.a
	add_child(ghost)
	# The page retains its media texture; toolbar tiles share copied UI state.
	var page := TextureRect.new()
	page.texture = preview.texture
	page.expand_mode = preview.expand_mode
	page.stretch_mode = preview.stretch_mode
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	page.position = preview.global_position
	page.size = preview.size
	ghost.add_child(page)
	var tiles: Array[Dictionary] = []
	var toolbar := preload("res://scenes/CellShatter.gd").capture_control(chrome)
	ghost.add_child(toolbar)
	for x in 12:
		var tile := TextureRect.new()
		tile.texture = toolbar.get_texture()
		tile.material = ShaderMaterial.new()
		tile.material.shader = preload("res://scenes/chromium_toolbar_tile.gdshader")
		tile.material.set_shader_parameter("slice", Vector2(float(x) / 12, 1.0 / 12))
		tile.material.set_shader_parameter("encode_srgb", not get_viewport().use_hdr_2d)
		tile.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile.position = chrome.global_position + Vector2(float(x) * chrome.size.x / 12, 0)
		tile.size = Vector2(chrome.size.x / 12, chrome.size.y)
		ghost.add_child(tile)
		tiles.append({"node": tile, "origin": tile.position,
			"offset": Vector2((float(x) / 11 - 0.5) * 90, -35 - x % 3 * 12)})
	_outgoing.append({ "node": ghost, "toolbar": toolbar, "tiles": tiles, "age": 0.0, "opacity": ghost.modulate.a })


func _process(dt: float) -> void:
	if root == null or not is_instance_valid(host.world):
		return
	_arrival += dt
	var world: Node = host.world
	var duration: float = maxf(world.FLY_TIME, world.TAB_FX_LEAVE + world.TAB_FX_ARRIVE) if world.tab_fx_t >= 0.0 else world.TAB_FX_ARRIVE
	root.modulate.a = smoothstep(
		0.0,
		1.0,
		clampf((_arrival - duration + world.TAB_FX_ARRIVE) / world.TAB_FX_ARRIVE, 0, 1),
	)
	for i in range(_outgoing.size() - 1, -1, -1):
		var entry: Dictionary = _outgoing[i]
		entry.age += dt
		var p := clampf(float(entry.age) / world.TAB_FX_LEAVE, 0, 1)
		entry.node.modulate.a = float(entry.opacity) * (1.0 - smoothstep(0, 1, p))
		entry.toolbar.request_extent(chrome.size * get_viewport().get_final_transform().get_scale().abs())
		for tile in entry.tiles:
			tile.node.position = tile.origin + tile.offset * p * p
		if p >= 1:
			entry.node.queue_free()
			_outgoing.remove_at(i)


func has_text_focus() -> bool:
	return root.visible and chrome != null and (_chromium_focus or chrome.address.has_focus())


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_chromium_focus = root.visible and root.get_global_rect().has_point(event.position)


func handle_workspace_key(event: InputEvent) -> bool:
	if close_dialog != null and close_dialog.visible:
		return false
	return event is InputEventKey and has_text_focus() and chrome.handle_shortcut(event)


func _confirm_close() -> void:
	if close_dialog != null or active == null:
		return
	var id: int = active.session_id
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Close chromium window?"
	close_dialog.dialog_text = tr("This closes this chromium window and its tabs. Unsaved page state in this window will be lost.") + host.session_end_warning([id])
	add_child(close_dialog)
	close_dialog.confirmed.connect(
		func():
			host.close_chromium_session(id),
	)
	close_dialog.visibility_changed.connect(
		func():
			if not close_dialog.visible:
				close_dialog.queue_free()
				close_dialog = null,
	)
	close_dialog.popup_centered(Vector2i(460, 150))
