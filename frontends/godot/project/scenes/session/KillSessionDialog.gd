extends ConfirmationDialog
var peer: Node
var target := ""
var label := ""
var pending := false
var error_label := Label.new()


static func open(parent_window: Window, transport: Node, session: String, session_label := "") -> ConfirmationDialog:
	if not is_instance_valid(transport) or not transport.connected or session.is_empty():
		return null
	var dialog := load("res://scenes/session/KillSessionDialog.gd").new() as ConfirmationDialog
	dialog.peer = transport
	dialog.target = session
	dialog.label = session_label
	parent_window.add_child(dialog)
	dialog.popup_centered_clamped(Vector2i(460, 180), .9)
	dialog.get_cancel_button().grab_focus()
	return dialog


static func server_close_warning(context: Node, stops_server: Variant) -> String:
	if stops_server is not bool: return ""
	if stops_server:
		return "\n\n" + context.tr("This is the server’s last session. Closing it will also stop the server.")
	return "\n\n" + context.tr("The server will stay running.")


## A confirmation names the largest thing it ends: the server if closing
## stops it, else the session when `impact` (from `session_close_impact`)
## says its last panes are closing, else what the dialog already names.
static func name_largest_close(dialog: ConfirmationDialog, impact: Dictionary) -> void:
	if impact.is_empty(): return
	if impact.get("stops_server") is bool and impact.stops_server:
		dialog.title = "Stop server?"
		dialog.ok_button_text = "Stop Server"
	else:
		dialog.title = "Close session?"
		dialog.ok_button_text = "Close Session"


func _ready() -> void:
	if label.is_empty():
		label = target
		for session in peer.available_sessions:
			if session.id == target:
				label = preload("res://scenes/session/SessionLabel.gd").display(session)
				break
	title = tr("Kill session %s?") % label
	dialog_text = tr("End all panes and running programs in this session? This cannot be undone.") + server_close_warning(self, peer.session_close_stops_server(target))
	ok_button_text = tr("Kill Session")
	# Name the largest thing this ends.
	if peer.session_close_stops_server(target) == true:
		title = tr("Stop server?")
		ok_button_text = tr("Stop Server")
	dialog_autowrap = true
	dialog_hide_on_ok = false
	exclusive = true
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(error_label)
	get_ok_button().icon = preload("res://scenes/PaneIcons.gd").trash()
	preload("res://scenes/DialogActionStyle.gd").apply(get_ok_button(), preload("res://scenes/UIAccent.gd").DANGER)
	confirmed.connect(_kill)
	canceled.connect(func():
		if not pending: queue_free())
	var fitting := preload("res://scenes/input/ResponsiveDialogs.gd").new()
	add_child(fitting)
	fitting.watch(self)

func _kill() -> void:
	if pending: return
	if not is_instance_valid(peer) or not peer.connected:
		error_label.text = tr("Server is not connected")
		return
	pending = true
	get_ok_button().disabled = true
	get_cancel_button().disabled = true
	var response: Dictionary = await peer.request_action("session_kill", {"name": target})
	pending = false
	get_ok_button().disabled = false
	get_cancel_button().disabled = false
	if response.get("type") == "error":
		error_label.text = tr("Could not kill session")
		return
	queue_free()
