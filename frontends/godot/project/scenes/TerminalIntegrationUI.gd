extends Node
## Window-owned consent and non-blocking notifications for a terminal surface.
var terminal: Control
var dialog: ConfirmationDialog
var shade: ColorRect
var application: Node
var host: Node
var request_id := -1


func _ready() -> void:
	terminal = get_parent()
	terminal.clipboard_read_requested.connect(_clipboard_read_requested)
	terminal.clipboard_cancelled.connect(_clipboard_cancelled)
	terminal.notification_received.connect(_notification_received)
	terminal.notification_command_received.connect(_notification_command_received)
	terminal.bell.connect(_bell)
	terminal.audible_bell_requested.connect(_audible_bell)


func _exit_tree() -> void:
	if is_instance_valid(shade): shade.queue_free()
	if is_instance_valid(dialog):
		dialog.queue_free()


func _clipboard_cancelled() -> void:
	if is_instance_valid(shade): shade.queue_free()
	shade = null
	if is_instance_valid(dialog): dialog.queue_free()
	dialog = null
	request_id = -1


func _clipboard_read_requested(id: int, _selection: String) -> void:
	if is_instance_valid(dialog):
		terminal.answer_clipboard_read(id, false)
		return
	request_id = id
	dialog = ConfirmationDialog.new()
	dialog.title = "Clipboard access"
	var identity: String = terminal.get_ui_state().get("title", "")
	if is_instance_valid(host):
		for pane_id in host.sessions:
			if host.sessions[pane_id].term == terminal:
				identity = "%%%d: %s" % [pane_id, host.session_model(pane_id).title]
				break
	if identity.is_empty(): identity = "Terminal"
	dialog.dialog_text = tr("%s requests clipboard access.\nAllow this request?") % identity.left(200)
	dialog.ok_button_text = "Allow once"
	dialog.cancel_button_text = "Deny"
	shade = ColorRect.new()
	shade.color = Color(0, 0, 0, .32)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	terminal.get_window().add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	terminal.get_window().add_child(dialog)
	dialog.confirmed.connect(_answer.bind(true))
	dialog.canceled.connect(_answer.bind(false))
	dialog.popup_centered()


func _answer(allow: bool) -> void:
	if is_instance_valid(shade): shade.queue_free()
	shade = null
	if is_instance_valid(terminal):
		terminal.answer_clipboard_read(request_id, allow)
	if is_instance_valid(dialog):
		dialog.queue_free()
	dialog = null
	request_id = -1


func _audible_bell() -> void:
	DisplayServer.beep()


func _bell() -> void:
	var window := terminal.get_window()
	if not window.has_focus():
		window.request_attention()


func _notification_received(title: String, body: String) -> void:
	if is_instance_valid(application):
		application.system_notifications.notify(terminal, title, body)


func _notification_command_received(packet: String) -> void:
	if is_instance_valid(application):
		application.system_notifications.command(terminal, packet)
