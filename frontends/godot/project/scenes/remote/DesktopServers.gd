extends Window
## Desktop connection controller over the same responsive pages/cards as Android.
## Native window placement and local-session return remain desktop responsibilities.
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
const Page := preload("res://scenes/remote/ConnectionPage.gd")
const Card := preload("res://scenes/remote/ServerCard.gd")
var application: Node
var client: Node
var entries: Array = []
var selected := {}
var editing := {}
var chooser := preload("res://scenes/remote/ServerBrowserPage.gd").new()
var form := Page.new()
var editor := preload("res://scenes/remote/ServerEditor.gd").new()
var status: Label = chooser.status
var local := Button.new()
var startup := CheckBox.new()
var new_window := Button.new()
var confirmation := ConfirmationDialog.new()
var open_when_ready := false
var connect_all := Button.new()
var keep_manager_open := false
var _pending_connections: Array[Dictionary] = []
var _connecting_queue := false
var cards: Array[Dictionary] = []

func _init() -> void:
	visible = false
	transient = true
	exclusive = false
	unresizable = false
	min_size = Vector2i(320, 280)

func _ready() -> void:
	add_to_group(&"server_order_views")
	title = "Servers"
	preload("res://scenes/UIAccent.gd").install()
	add_child(chooser)
	connect_all.text = "Connect all"
	connect_all.custom_minimum_size = Vector2(112, 48)
	Page.style_button(connect_all)
	chooser.status_row.add_child(connect_all)
	connect_all.pressed.connect(_connect_all)
	chooser.add_requested.connect(func(): _edit({}))
	local.text = "This Computer"
	local.custom_minimum_size.y = 48
	Page.style_button(local)
	local.pressed.connect(_return_local)
	chooser.connections.add_child(local)
	chooser.connections.move_child(local, 1)
	startup.text = "Show servers at startup"
	startup.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	startup.button_pressed = application.show_servers_at_startup
	startup.toggled.connect(application.set_show_servers_at_startup)
	chooser.body.add_child(startup)
	chooser.back.text = "Done"
	chooser.footer_actions.alignment = BoxContainer.ALIGNMENT_END
	chooser.back.show()
	chooser.canceled.connect(hide)
	form.title = "Add server"
	form.ok_button_text = "Save and connect"
	add_child(form)
	form.body.add_child(editor)
	new_window.text = "Open in new window"
	new_window.custom_minimum_size.y = 48
	Page.style_button(new_window)
	new_window.pressed.connect(_save.bind(true))
	form.body.add_child(new_window)
	form.confirmed.connect(_save.bind(false))
	form.canceled.connect(_cancel_edit)
	form.hide()
	confirmation.dialog_text = "Remove this saved server and its remembered password? The computer's terminals will keep running."
	confirmation.ok_button_text = "Remove saved server"
	confirmation.cancel_button_text = "Keep server"
	confirmation.confirmed.connect(_forget)
	add_child(confirmation)
	close_requested.connect(hide)
	visibility_changed.connect(func():
		if not visible:
			editor.token.clear()
			open_when_ready = false
			confirmation.hide()
			for row in cards: row.card.actions.hide())
	get_node("/root/Localization").changed.connect(_refresh_status)

func present(source: Node) -> void:
	if not is_embedded():
		current_screen = source.get_window().current_screen
		content_scale_factor = source.get_window().content_scale_factor
	bind_client(source)
	_refresh_list()
	_cancel_edit()
	if not visible: popup_centered_clamped(Vector2i(Vector2(840, 620) * content_scale_factor), 0.9)

func bind_client(source: Node) -> void:
	if client == source: return
	client = source
	var refresh := func(_message = ""):
		if client == source: _refresh_status()
	source.connection.state_changed.connect(refresh)
	source.connection.changed.connect(func():
		if client != source: return
		_refresh_status()
		if open_when_ready and is_instance_valid(source.host) and source.connection.connected:
			open_when_ready = false
			hide()
	, CONNECT_DEFERRED)
	source.connection.authenticated.connect(func():
		if client != source: return
		if not source.settings.get("shared_local", false):
			source.settings.hostname = source.connection.server_hostname
			var error := Authentication.save_connection(source.settings)
			if not error.is_empty(): status.text = error
		_refresh_list()
	, CONNECT_DEFERRED)

func saved_servers_reordered() -> void:
	_refresh_list()

func _server_order_error(_error: String) -> void:
	status.text = tr("Could not reorder servers.")

func _refresh_list() -> void:
	for child in chooser.rows.get_children():
		chooser.rows.remove_child(child)
		child.queue_free()
	cards.clear()
	var loaded := Authentication.read_connections()
	entries = loaded.get("connections", [])
	# Unsaved active connections remain visible without persisting credentials.
	if is_instance_valid(client) and not client.settings.get("shared_local", false):
		if not entries.any(func(entry): return entry.url == client.settings.url):
			entries.append(client.settings.duplicate(true))
	for entry in entries:
		var settings: Dictionary = entry.duplicate(true)
		settings.erase("token")
		var card := Card.new()
		chooser.rows.add_child(card)
		cards.append({"settings": settings, "card": card})
		card.update_identity(settings)
		card.activated.connect(func(): _queue_connection(settings))
		card.edited.connect(func(): _edit(settings))
		card.disconnected.connect(func(): selected = settings; _disconnect())
		card.remove_requested.connect(func(): selected = settings; confirmation.popup_centered())
		var open_new := Button.new()
		open_new.text = "Open in new window"
		open_new.custom_minimum_size.y = 48
		open_new.clip_text = true
		Card._style_action(open_new)
		open_new.pressed.connect(func(): card.actions.hide(); selected = settings; _open(true))
		card.action.get_parent().add_child(open_new)
		preload("res://scenes/remote/ServerReorder.gd").install(card.select, str(settings.url), _server_order_error, card)
	chooser.empty.visible = entries.is_empty()
	_refresh_status()
	if loaded.has("error"): status.text = str(loaded.error)

func _is_current() -> bool:
	return is_instance_valid(client) and not client.settings.get("shared_local", false) and client.settings.get("url") == selected.get("url")

func _connected_client(settings: Dictionary) -> Node:
	for candidate in get_tree().get_nodes_in_group("shared_presentations"):
		if not candidate.is_queued_for_deletion() and not candidate.federated and candidate.settings.get("url") == settings.get("url") and candidate.connection.connected:
			return candidate
	return null

func _refresh_status() -> void:
	if not is_instance_valid(client): return
	var connected_count := entries.filter(func(entry): return _connected_client(entry) != null).size()
	status.text = tr("%d of %d servers connected") % [connected_count, entries.size()]
	connect_all.disabled = entries.is_empty()
	local.disabled = not client.settings.get("shared_local", false) and (client.local_return == null or not is_instance_valid(client.local_return.client))
	for row in cards:
		var connected := _connected_client(row.settings)
		var current: bool = not client.settings.get("shared_local", false) and client.settings.get("url") == row.settings.url
		var card: Card = row.card
		var state := "connected" if connected != null else "disconnected"
		if current:
			state = "connected" if client.connection.connected else ("connecting" if client.connection.enabled else "error")
		card.update_state(state, current or connected != null)
		if current:
			get_node("/root/Localization").text(card.status, client.connection.status_source, client.connection.status_args, &"text", true)
		else:
			card.status.text = tr("Connected") if connected != null else tr("Ready to connect")
		# Disconnect belongs to this window; another window's connection is not ours.
		card.disconnect_button.disabled = not current
		card.remove.disabled = not Authentication.saved_connections().any(func(saved): return saved.url == row.settings.url)

func _edit(entry: Dictionary) -> void:
	if not visible: popup_centered_clamped(Vector2i(Vector2(840, 620) * content_scale_factor), 0.9)
	editing = entry.duplicate(true)
	open_when_ready = false
	chooser.hide()
	form.title = "Add server" if editing.is_empty() else "Edit server / password"
	form.show()
	editor.load_settings(editing)
	editor.endpoint.grab_focus()

func _cancel_edit() -> void:
	editor.token.clear()
	editing = {}
	form.hide()
	chooser.show()

func _input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("ui_cancel") or confirmation.visible: return
	var focus := gui_get_focus_owner()
	if focus is LineEdit and focus.has_ime_text(): return
	set_input_as_handled()
	if form.visible: _cancel_edit()
	else: hide()

func _password(settings: Dictionary) -> String:
	var connected := _connected_client(settings)
	if connected != null: return str(connected.connection.token)
	if settings.get("remember", false):
		var result := Authentication.password(settings.url)
		if result.has("error"): status.text = str(result.error)
		return str(result.get("password", ""))
	return ""

func _save(in_new_window: bool) -> void:
	var settings: Dictionary = editor.settings()
	var address_error := Authentication.normalize_address(settings)
	if not address_error.is_empty():
		editor.form_status.text = address_error
		return
	var password: String = editor.token.text
	if password.is_empty(): password = _password(settings)
	if password.is_empty():
		editor.form_status.text = "Enter the current password shown on the computer."
		return
	var error := Authentication.save_connection(settings)
	if not error.is_empty():
		editor.form_status.text = error
		return
	if not editing.is_empty() and editing.url != settings.url:
		error = Authentication.remove_connection(editing)
		if not error.is_empty():
			editor.form_status.text = error
			return
	selected = settings.duplicate(true)
	_cancel_edit()
	_refresh_list()
	_connect(settings, password, in_new_window)

func _queue_connection(settings: Dictionary) -> void:
	if _connected_client(settings) != null: return
	_pending_connections.append(settings.duplicate(true))
	_drain_connections()

func _drain_connections() -> void:
	if _connecting_queue: return
	_connecting_queue = true
	while not _pending_connections.is_empty():
		# An authenticated server may have no sessions and therefore no host.
		while is_instance_valid(client) and not client.connection.connected and client.connection.enabled:
			await get_tree().process_frame
		selected = _pending_connections.pop_front()
		keep_manager_open = true
		_open(false)
	_connecting_queue = false

func _connect_all() -> void:
	for entry in entries:
		if _connected_client(entry) == null: _pending_connections.append(entry.duplicate(true))
	_drain_connections()
	if chooser.visible: hide()

func _open(in_new_window: bool) -> void:
	if keep_manager_open and _connected_client(selected) != null: return
	if _is_current() and client.connection.connected and not in_new_window:
		hide()
		return
	var connected := _connected_client(selected)
	if connected != null and not in_new_window:
		application.present_desktop_client(connected)
		bind_client(connected)
		hide()
		return
	var password := _password(selected)
	if password.is_empty():
		_edit(selected)
		return
	_connect(selected, password, in_new_window)

## Connect a saved server from the Sessions panel. This window appears only
## when the server is unknown or has no usable password.
func connect_server(source: Node, url: String) -> void:
	keep_manager_open = false
	bind_client(source)
	_refresh_list()
	for row in cards:
		if row.settings.url != url: continue
		selected = row.settings
		if _connected_client(selected) == null:
			for candidate in get_tree().get_nodes_in_group("shared_presentations"):
				# An attempt already under way keeps running.
				if not candidate.is_queued_for_deletion() and not candidate.federated and candidate.settings.get("url") == url and candidate.connection.enabled: return
			if _password(selected).is_empty():
				present(source)
				_edit(selected)
				return
		_open(false)
		return
	present(source)

func _connect(settings: Dictionary, password: String, in_new_window: bool) -> void:
	var connection_settings := settings.duplicate(true)
	connection_settings.token = password
	var next: Node = application.open_remote_server(client, connection_settings, in_new_window)
	if not in_new_window:
		bind_client(next)
		open_when_ready = not keep_manager_open
		if keep_manager_open and visible: grab_focus()
		_refresh_status()

func _return_local() -> void:
	if client.settings.get("shared_local", false):
		hide()
		return
	var saved: Node = client.local_return.client
	application.present_desktop_client(saved)
	bind_client(saved)
	hide()

func _disconnect() -> void:
	if client.local_return != null and is_instance_valid(client.local_return.client):
		var saved: Node = client.local_return.client
		client.detach()
		application.present_desktop_client(saved)
		bind_client(saved)
		hide()
	else:
		client.connection.disconnect_remote()
		client._release_host()
		open_when_ready = false
		_refresh_status()

func _forget() -> void:
	var error := Authentication.remove_connection(selected)
	if not error.is_empty():
		status.text = error
		return
	for candidate in get_tree().get_nodes_in_group("shared_presentations"):
		if not candidate.federated and candidate.settings.get("url") == selected.url:
			candidate.settings.transient = true
			candidate.settings.remember = false
			candidate.remember.button_pressed = false
	selected = {}
	_refresh_list()
