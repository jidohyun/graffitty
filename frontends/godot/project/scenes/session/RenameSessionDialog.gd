extends ConfirmationDialog
var peer: Node
var target := ""
var custom_name := ""
var session_name := LineEdit.new()
var error_label := Label.new()
var saving := false

func _ready() -> void:
	title = tr("Rename Session")
	ok_button_text = tr("Rename")
	exclusive = true
	dialog_hide_on_ok = false
	var column := VBoxContainer.new()
	column.custom_minimum_size.x = minf(380, get_parent().get_viewport().get_visible_rect().size.x * .9 - 32)
	session_name.text = custom_name
	session_name.placeholder_text = tr("Automatic name")
	column.add_child(session_name)
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(error_label)
	add_child(column)
	confirmed.connect(_save)
	canceled.connect(queue_free)
	session_name.text_submitted.connect(func(_value): _save())
	var fitting := preload("res://scenes/input/ResponsiveDialogs.gd").new()
	add_child(fitting)
	fitting.watch(self)

func _save() -> void:
	if saving: return
	if not is_instance_valid(peer) or not peer.connected:
		error_label.text = tr("Server is not connected")
		return
	saving = true
	get_ok_button().disabled = true
	var response: Dictionary = await peer.request_action("session_rename", {"name": target, "new_name": session_name.text})
	saving = false
	get_ok_button().disabled = false
	if response.get("type") == "error":
		error_label.text = tr("Could not rename session")
		return
	queue_free()
