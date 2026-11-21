extends PanelContainer
## Compact device identity with touch-sized actions kept in a dismissible popup.
const DesktopText := preload("res://scenes/DesktopText.gd")
signal activated
signal edited
signal disconnected
signal remove_requested
const Icons := preload("res://scenes/PaneIcons.gd")
const Names := preload("res://scenes/remote/ConnectionName.gd")
const DANGER := preload("res://scenes/UIAccent.gd").DANGER
var heading := Label.new()
var address := Label.new()
var status := Label.new()
var indicator := PanelContainer.new()
var os_icon := TextureRect.new()
var select := Button.new()
var more := Button.new()
var actions := PopupPanel.new()
var action := Button.new()
var edit := Button.new()
var disconnect_button := Button.new()
var remove := Button.new()

func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", _surface(Color("24252b"), 8, 12))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	add_child(row)
	select.name = "ServerConnectionButton"
	select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_action(select)
	select.pressed.connect(func(): activated.emit())
	row.add_child(select)
	var identity := HBoxContainer.new()
	identity.add_theme_constant_override("separation", 12)
	select.add_child(identity)
	identity.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	identity.minimum_size_changed.connect(func(): select.custom_minimum_size.y = maxf(76, identity.get_combined_minimum_size().y))
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(56, 56)
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tile.add_theme_stylebox_override("panel", _surface(Color("513375"), 8, 8))
	identity.add_child(tile)
	os_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	os_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tile.add_child(os_icon)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.add_theme_constant_override("separation", 4)
	identity.add_child(text)
	for label in [heading, address]:
		label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		text.add_child(label)
	heading.add_theme_font_size_override("font_size", DesktopText.size(20))
	address.add_theme_font_size_override("font_size", DesktopText.size(16))
	address.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	address.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	address.custom_minimum_size.y = 20
	address.clip_text = false
	address.modulate = Color("c4c5cc")
	# Three lines: hostname, colored status/error, then address and port.
	var details := HBoxContainer.new()
	details.add_theme_constant_override("separation", 6)
	text.add_child(details)
	text.move_child(details, 1)
	indicator.custom_minimum_size = Vector2(8, 8)
	indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	details.add_child(indicator)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_size_override("font_size", DesktopText.size(14))
	details.add_child(status)
	more.icon = _icon("ellipsis-vertical")
	more.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	more.tooltip_text = "Server actions"
	more.custom_minimum_size = Vector2(44, 48)
	more.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_action(more)
	more.pressed.connect(show_actions)
	row.add_child(more)
	# A real Button preserves keyboard activation and lets ScrollContainer
	# cancel touch presses when a drag becomes scrolling. Artwork is inert.
	identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for control in identity.find_children("*", "Control", true, false):
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	actions.transparent_bg = true
	actions.add_theme_stylebox_override("panel", _surface(Color("292a30"), 10, 6))
	add_child(actions)
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 2)
	actions.add_child(menu)
	for button in [action, edit, disconnect_button, remove]:
		button.custom_minimum_size.y = 48
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# Wrapping an initially zero-width popup creates a huge minimum height
		# before its first layout. Menu items stay single-line and touch-sized.
		button.clip_text = true
		_style_action(button)
		menu.add_child(button)
	edit.text = "Edit"
	disconnect_button.text = "Disconnect"
	remove.text = "Remove"
	remove.icon = _icon("trash-2")
	remove.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	style_danger(remove)
	action.pressed.connect(func(): actions.hide(); activated.emit())
	edit.pressed.connect(func(): actions.hide(); edited.emit())
	disconnect_button.pressed.connect(func(): actions.hide(); disconnected.emit())
	remove.pressed.connect(func(): actions.hide(); remove_requested.emit())

func _ready() -> void:
	visibility_changed.connect(func():
		if not is_visible_in_tree(): actions.hide())
	get_viewport().size_changed.connect(actions.hide)
	actions.popup_hide.connect(func():
		if is_visible_in_tree(): more.grab_focus())

func update_identity(settings: Dictionary) -> void:
	heading.text = Names.display(settings)
	var username := str(settings.get("username", ""))
	if str(settings.get("name", "")).strip_edges().is_empty() and not username.is_empty():
		heading.text = username + "@" + heading.text
	address.text = Names.address(settings)
	var platform := str(settings.get("platform", ""))
	os_icon.texture = _icon("os-" + platform if platform in ["macos", "windows", "linux"] else "monitor")
	_update_accessible_name()

func update_state(state: String, has_transport: bool) -> void:
	var color := Color("70d194") if state == "connected" else Color("f3a35b") if state in ["offline", "password", "verification", "error"] else Color("a7a9b5")
	indicator.add_theme_stylebox_override("panel", _surface(color, 4, 0))
	status.modulate = color
	action.disabled = state in ["connecting", "authenticating"]
	select.disabled = action.disabled
	action.text = {"connected": "Connected", "offline": "Retry now", "error": "Retry now", "password": "Enter current password", "connecting": "Connecting…", "authenticating": "Signing in…", "verification": "Try sign-in again"}.get(state, "Connect")
	disconnect_button.disabled = not has_transport
	_update_accessible_name()

func _update_accessible_name() -> void:
	# The card already shows these details. A duplicate tooltip covers it while
	# holding to reorder; keep the button named for assistive technology instead.
	select.accessibility_name = "\n".join(PackedStringArray([heading.text, address.text, status.text]))

func show_actions() -> void:
	if not is_inside_tree(): return
	var viewport := get_viewport()
	var width := minf(300, viewport.get_visible_rect().size.x - 24)
	actions.content_scale_factor = 1.0
	if not actions.is_embedded():
		get_node("/root/TerminalApplication").configure_window_scale(actions)
	# Clip-text buttons have no intrinsic text-width minimum; keep the popup
	# from shrinking back to icon/padding width after its first layout.
	actions.min_size = Vector2i((Vector2(width, actions.get_child(0).get_combined_minimum_size().y + 12) * actions.content_scale_factor).ceil())
	actions.size = actions.min_size
	# Embedded popup positions are logical viewport coordinates, not desktop
	# screen coordinates. Applying the OS window offset here pins it top-left.
	var at := more.get_global_transform_with_canvas() * more.size if actions.is_embedded() else preload("res://scenes/ScreenSpace.gd").of(more, more.size)
	at.x -= actions.size.x
	if actions.is_embedded():
		at = at.clamp(Vector2(8, 8), (viewport.get_visible_rect().size - Vector2(actions.size) - Vector2(8, 8)).max(Vector2(8, 8)))
	actions.popup(Rect2i(Vector2i(at.round()), actions.size))
	(edit if action.disabled else action).grab_focus.call_deferred()

static func _icon(kind: String) -> Texture2D:
	return Icons._texture("server:" + kind, "res://scenes/icons/" + kind + ".svg", 1.0)

static func _surface(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style

static func _style_action(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		button.add_theme_stylebox_override(state, _surface(Color("ffffff18") if state in ["hover", "pressed"] else Color.TRANSPARENT, 6, 10))
	var focus := _surface(Color.TRANSPARENT, 6, 0)
	focus.border_color = preload("res://scenes/UIAccent.gd").ACCENT
	focus.set_border_width_all(2)
	button.add_theme_stylebox_override("focus", focus)

static func style_danger(button: Button) -> void:
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, DANGER)
