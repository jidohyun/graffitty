extends PanelContainer
## Find in page, drawn where Chrome draws its find bar: the top-right corner
## of the page.
##
## Chromium's own find engine matches, highlights and scrolls; this box only
## edits the query and shows Chromium's "active/count" result.
const DesktopText := preload("res://scenes/DesktopText.gd")
signal closed

const WIDTH := 360.0
const MARGIN := 16.0

var session: Node
var field := LineEdit.new()
var result := Label.new()
var previous: Button
var next: Button
var close_button: Button
var _row := HBoxContainer.new()
var _page_id := -1


func _ready() -> void:
	name = "ChromiumFindBar"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color("20242c")
	style.set_corner_radius_all(8)
	style.corner_detail = 16
	style.anti_aliasing = true
	style.content_margin_left = 10
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 8
	style.shadow_offset = Vector2(0, 2)
	add_theme_stylebox_override("panel", style)
	var row := _row
	row.add_theme_constant_override("separation", 4)
	add_child(row)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.placeholder_text = tr("Find in page")
	field.context_menu_enabled = true
	field.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	field.add_theme_color_override("font_color", Color("e1e7f2"))
	field.add_theme_font_size_override("font_size", DesktopText.size(13))
	field.text_changed.connect(_query_changed)
	field.gui_input.connect(_field_input)
	row.add_child(field)
	result.add_theme_color_override("font_color", Color("8b93a3"))
	result.add_theme_font_size_override("font_size", DesktopText.size(12))
	result.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(result)
	var divider := VSeparator.new()
	divider.add_theme_constant_override("separation", 6)
	row.add_child(divider)
	previous = _button(row, "up", "Previous match", func(): step(true))
	next = _button(row, "down", "Next match", func(): step(false))
	close_button = _button(row, "close", "Close find bar", close)


func _button(parent: Control, kind: String, label: String, pressed: Callable) -> Button:
	var button := Button.new()
	button.flat = true
	button.focus_mode = Control.FOCUS_NONE
	button.accessibility_name = tr(label)
	button.icon = _icon(kind)
	button.custom_minimum_size = Vector2(26, 26)
	button.pressed.connect(pressed)
	parent.add_child(button)
	return button


static func _icon(kind: String) -> Texture2D:
	var paths := {
		"up": '<path d="m4 10 4-4 4 4"/>',
		"down": '<path d="m4 6 4 4 4-4"/>',
		"close": '<path d="m4 4 8 8m0-8-8 8"/>',
	}
	var image := Image.new()
	image.load_svg_from_string(
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><g fill="none" stroke="#d9e1ef" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>'
		% paths[kind], 2.0)
	return ImageTexture.create_from_image(image)


## Top-right of the page area, `page_top` pixels below the pane body's top.
## A narrow pane drops the arrow buttons; Enter and Shift+Enter still step.
func place(body_size: Vector2, page_top: float) -> void:
	var compact := body_size.x < 260.0
	previous.visible = not compact
	next.visible = not compact
	_row.update_minimum_size()
	update_minimum_size()
	var margin := MARGIN if not compact else 4.0
	var width := maxf(minf(WIDTH, body_size.x - margin * 2.0), get_combined_minimum_size().x)
	size = Vector2(width, 0)
	position = Vector2(maxf(body_size.x - width - margin, 0.0), page_top + 8.0)


## Chrome's Cmd+F: show the box with the previous query selected, and search
## for it again so its matches are highlighted.
func open() -> void:
	if not is_instance_valid(session): return
	visible = true
	_page_id = session.selected_page_id
	if field.is_inside_tree(): field.grab_focus()
	field.select_all()
	if not field.text.is_empty():
		session.find(field.text)
	refresh()


## Next (or previous) match; Cmd+G also opens a closed box first.
func step(backward: bool) -> void:
	if not visible:
		open()
	if is_instance_valid(session) and not field.text.is_empty():
		session.find(field.text, backward, true)


func close() -> void:
	if not visible: return
	visible = false
	if is_instance_valid(session):
		session.stop_finding()
	closed.emit()


func refresh() -> void:
	if not visible or not is_instance_valid(session): return
	# Chromium's find state belongs to one page; a different tab ends it.
	if session.selected_page_id != _page_id:
		close()
		return
	var found: Dictionary = session.find_result
	var searching := not field.text.is_empty()
	result.visible = searching
	var count := int(found.get("count", 0))
	result.text = "%d/%d" % [int(found.get("active", 0)), count] if not found.is_empty() else ""
	var missing := searching and not found.is_empty() and bool(found.get("final", false)) and count == 0
	result.add_theme_color_override("font_color", Color("ff8a80") if missing else Color("8b93a3"))
	previous.disabled = count == 0
	next.disabled = count == 0


func _query_changed(text: String) -> void:
	if not is_instance_valid(session): return
	if text.is_empty():
		session.stop_finding(true)
	else:
		session.find(text)
	refresh()


func _field_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed: return
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			step(event.shift_pressed)
			field.accept_event()
		KEY_ESCAPE:
			close()
			field.accept_event()
