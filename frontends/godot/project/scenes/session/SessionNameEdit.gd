extends LineEdit
## The mod owns layout. Follow the keyed row across scroll, zoom and reorder.
var row_key: String
var peer: Node
var target: String
var saving := false
var original_name: String

func _ready() -> void:
	name = "SessionNameEdit"
	original_name = text
	# The mod paints clipped rows with their own canvas items under the view.
	z_index = 1
	var field := StyleBoxFlat.new()
	field.bg_color = Color("25252b")
	field.set_content_margin_all(4)
	for state in ["normal", "read_only"]:
		add_theme_stylebox_override(state, field)
	placeholder_text = tr("Automatic name")
	accessibility_name = tr("Rename Session")
	expand_to_text_length = false
	add_theme_constant_override("minimum_character_width", 1)
	keep_editing_on_text_submit = true
	text_submitted.connect(_submit)
	_process(0)
	grab_focus()
	edit()
	select_all()

func _process(_delta: float) -> void:
	var view := get_parent()
	var rect: Rect2 = view.hit_rect(row_key)
	if not rect.has_area() or not is_visible_in_tree():
		queue_free()
		return
	var label: Rect2 = view.hit_rect("name-" + row_key)
	if label.has_area():
		rect.position.x = label.position.x
		rect.size.x = label.size.x
	position = rect.position
	size = rect.size

func _input(event: InputEvent) -> void:
	var click: bool = event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] and event.pressed
	var tap: bool = event is InputEventScreenTouch and event.pressed
	if (click or tap) and not Rect2(Vector2.ZERO, size).has_point(make_input_local(event).position):
		_submit(text)

func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not has_ime_text():
		accept_event()
		if not saving: queue_free()

func _submit(value: String) -> void:
	if saving or is_queued_for_deletion(): return
	if value == original_name:
		queue_free()
		return
	saving = true
	editable = false
	var message := ""
	if not is_instance_valid(peer) or not peer.connected:
		message = tr("Server is not connected")
	else:
		var response: Dictionary = await peer.request_action("session_rename", {"name": target, "new_name": value})
		if response.get("type") == "error": message = tr("Could not rename session")
	if not message.is_empty():
		var alert := AcceptDialog.new()
		alert.dialog_text = message
		get_window().add_child(alert)
		alert.confirmed.connect(alert.queue_free)
		alert.canceled.connect(alert.queue_free)
		alert.popup_centered()
	queue_free()
