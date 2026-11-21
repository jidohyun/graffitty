extends Control
const DesktopText := preload("res://scenes/DesktopText.gd")

class ConnectionState extends RefCounted:
	var state: String
	var message: String
	var args: Array
	func _init(next_state: String, text: String, arguments: Array) -> void:
		state = next_state
		message = text
		args = arguments.duplicate()

const ServerCard := preload("res://scenes/remote/ServerCard.gd")
const ServerStart := preload("res://scenes/remote/ServerStart.gd")
const AboutDialog := preload("res://scenes/AboutDialog.gd")
const Accent := preload("res://scenes/UIAccent.gd")
var about_dialog: AboutDialog
var connect_all := Button.new()
var touch_start: ServerStart
var _open_all_when_ready := false

var localization: Node:
	get: return Engine.get_main_loop().root.get_node("Localization")
## Saved server identities outlive transports. Navigation and connection state
## are independent: editing or canceling never removes a saved server/session.
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
const Client := preload("res://scenes/remote/RemoteClient.gd")
const Page := preload("res://scenes/remote/ConnectionPage.gd")
var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
var view: Node
var view_state := preload("res://scenes/remote/RemoteViewState.gd").new()
var _view_save_timer := Timer.new()
var _view_selection: Array = []
var remote_swipe: Node
var navigation := preload("res://scenes/remote/RemoteNavigation.gd").new()
var chooser := preload("res://scenes/remote/ServerBrowserPage.gd").new()
var dialog := Page.new()
var landing_status: Label = chooser.status
var rows: VBoxContainer = chooser.rows
var connections_section: VBoxContainer = chooser.connections
var settings_section := VBoxContainer.new()
var connection_tab := Button.new()
var settings_tab := Button.new()
var brand: TextureRect = chooser.brand
var editor := preload("res://scenes/remote/ServerEditor.gd").new()
var endpoint: LineEdit = editor.endpoint
var token: LineEdit = editor.token
var label: LineEdit = editor.label
var remember: CheckBox = editor.remember
var form_status: Label = editor.form_status
var stream_options: Dictionary = editor.stream_options
var entries: Dictionary = {}
var transports: Dictionary = {}
var cards: Dictionary[String, ServerCard] = {}
var removal: ConfirmationDialog
var states: Dictionary[String, ConnectionState] = {}
var session_passwords: Dictionary[String, String] = {}
var pending_settings: Dictionary = {}
var editing_key := ""
var open_when_ready := "":
	set(value):
		open_when_ready = value
		_update_restore_cover()
## A label over the server list while startup returns to the last workspace,
## so the wait reads as "opening your work", not as a list to act on.
##
## The list stays visible and usable beneath it. Anything that needs the user
## (a password, an unreachable server) removes the label.
var restore_cover := PanelContainer.new()
var _restoring := false
var keyboard_insets: Node
var terminal_ime: Node
var empty_state: Label = chooser.empty
var save_hint := Label.new()
var keybar: Control
var dictation: Node
## Draggable keyboard, microphone and text-size controls above the workspace.
var floating: CanvasLayer
var font_cache_status := Label.new()
var font_cache_clear: Button
var font_cache_updated := -1000
var font_cache_pending := false

## Workspace scripts compiled ahead of the first workspace, and their loader.
##
## A dedicated thread: a ResourceLoader threaded request or a WorkerThreadPool
## task leaves one load token alive for every resource those scripts preload,
## which Godot reports as leaked ObjectDB instances at exit.
var _workspace_scripts: Array[Resource] = []
var _workspace_compiler: Thread

static func _compile_workspace(paths: PackedStringArray, done: Callable) -> void:
	var loaded: Array[Resource] = []
	for path in paths: loaded.append(load(path))
	done.call_deferred(loaded)

func _workspace_compiled(loaded: Array[Resource]) -> void:
	_workspace_scripts = loaded
	_workspace_compiler.wait_to_finish()

func _init() -> void:
	navigation.manager = self

func _ready() -> void:
	# Compile the workspace scripts on a worker while the server connects; the
	# first workspace otherwise pays for them after the topology has arrived.
	# Preload the mobile default. TerminalHost resolves the selected world.
	var world := "res://scenes/Flat2DWorld.gd" if OS.has_feature("mobile") else str(preload("res://config/UserConfig.gd").world_path(OS.get_cmdline_user_args()))
	var workspace_scripts := PackedStringArray()
	for path in ["res://scenes/TerminalHost.gd", world]:
		if path.begins_with("res://") and ResourceLoader.exists(path): workspace_scripts.append(path)
	_workspace_compiler = Thread.new()
	_workspace_compiler.start(_compile_workspace.bind(workspace_scripts, _workspace_compiled))
	add_to_group(&"server_order_views")
	get_window().set_meta(&"workspace_ui_active", false)
	Accent.install()
	_view_save_timer.one_shot = true
	_view_save_timer.wait_time = 0.4
	_view_save_timer.timeout.connect(_save_settled_view)
	add_child(_view_save_timer)
	get_node("/root/TerminalApplication").configure_window_scale(get_window())
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_tree().root.gui_embed_subwindows = preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	localization.text(get_window(), "Graffitty — Servers", [], &"title")
	get_tree().quit_on_go_back = false
	view = Client.new()
	view.view_state = view_state
	view.managed = true
	view.federated = true
	view.server_chooser = _show_chooser
	view.connection.free()
	view.connection = federation
	view.host_ready.connect(
		func():
			if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
				if is_instance_valid(keybar):
					remove_child(keybar)
					keybar.queue_free()
				keybar = preload("res://scenes/input/TouchKeyBar.gd").new()
				keybar.host = view.host
				keybar.connection = federation
				keybar.terminal_ime = terminal_ime
				add_child(keybar)
				view.host.touch_keybar = keybar
				if is_instance_valid(floating):
					remove_child(floating)
					floating.queue_free()
				floating = preload("res://scenes/input/FloatingButtons.gd").new()
				# client.toml `[touch] buttons` chooses which floating buttons exist.
				var touch_buttons: Array = preload("res://config/UserConfig.gd").touch_config(OS.get_cmdline_user_args()).buttons
				var Face := preload("res://scenes/input/TouchFace.gd")
				if "keyboard" in touch_buttons:
					var keyboard := Button.new()
					keyboard.name = "KeyboardButton"
					keyboard.icon = preload("res://scenes/PaneIcons.gd").keyboard()
					keyboard.tooltip_text = "Tap to toggle keyboard; hold to move"
					floating.add("keyboard", keyboard, Vector2.ONE, Callable(), _toggle_keyboard, true)
					Face.attach(keyboard, {"part": "button", "button": "keyboard"})
				if "text_size" in touch_buttons:
					var text_size := preload("res://scenes/input/TextSizeButton.gd").new()
					text_size.stepped.connect(view.host.change_text_size)
					floating.add("text_size", text_size, Vector2(.5, 1), Callable(), text_size.activate, true, text_size.cancel)
				if is_instance_valid(dictation):
					remove_child(dictation)
					dictation.queue_free()
				dictation = preload("res://scenes/input/Dictation.gd").new()
				dictation.host = view.host
				dictation.floating = floating
				dictation.show_button = "microphone" in touch_buttons
				add_child(dictation)
				floating.movement_allowed = func(): return not dictation.capture.is_busy() and not dictation.processing
				add_child(floating)
				view.host.floating_controls = floating
				# Floating controls belong to the workspace, never over server pages.
				var workspace: Control = view.host.layout_root
				var follow := func():
					var shown := workspace.is_visible_in_tree()
					if is_instance_valid(floating):
						floating.visible = shown
						if not shown: floating.cancel_gesture()
					if is_instance_valid(dictation): dictation.overlay.visible = shown
				workspace.visibility_changed.connect(follow)
				follow.call()
	)
	view.host_ready.connect(_workspace_ready)
	view.host_empty.connect(_show_chooser)
	view.detached.connect(_show_chooser)
	add_child(view)
	chooser.scroll_through_controls = true
	chooser.max_content_width = 1000.0
	add_child(chooser)
	_build_home()
	dialog.title = "Add server"
	dialog.ok_button_text = "Save and connect"
	add_child(dialog)
	_build_editor()
	dialog.confirmed.connect(_submit_connection)
	dialog.canceled.connect(_cancel_editor)
	dialog.hide()
	var restore_style := StyleBoxFlat.new()
	restore_style.bg_color = Color("101720", 0.94)
	restore_style.border_color = Color("384151")
	restore_style.set_border_width_all(1)
	restore_style.set_corner_radius_all(18)
	restore_style.content_margin_left = 22
	restore_style.content_margin_right = 22
	restore_style.content_margin_top = 12
	restore_style.content_margin_bottom = 12
	restore_cover.add_theme_stylebox_override("panel", restore_style)
	restore_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var restoring_label := Label.new()
	restoring_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	localization.text(restoring_label, "Connecting…")
	restore_cover.add_child(restoring_label)
	restore_cover.hide()
	add_child(restore_cover)
	restore_cover.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	restore_cover.grow_horizontal = Control.GROW_DIRECTION_BOTH
	restore_cover.grow_vertical = Control.GROW_DIRECTION_BOTH
	if OS.has_feature("android"):
		terminal_ime = preload("res://scenes/input/AndroidTerminalIme.gd").new()
		terminal_ime.manager = self
		add_child(terminal_ime)
		keyboard_insets = preload("res://scenes/input/AndroidKeyboardInsets.gd").new()
		keyboard_insets.manager = self
		add_child(keyboard_insets)
	get_window().close_requested.connect(func(): get_tree().quit())
	localization.changed.connect(_update_landing_status)
	_show_chooser()
	_load_connections()

func _build_home() -> void:
	chooser.add_requested.connect(_new_connection)
	connect_all.text = "Connect all"
	connect_all.custom_minimum_size = Vector2(112, 48)
	Page.style_button(connect_all)
	chooser.status_row.add_child(connect_all)
	connect_all.pressed.connect(_connect_all)
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		touch_start = ServerStart.new()
		var brand_row := Control.new()
		brand_row.custom_minimum_size.y = 96
		chooser.header.remove_child(brand)
		var layout := chooser.header.get_parent()
		layout.add_child(brand_row)
		layout.move_child(brand_row, 0)
		chooser.header.hide()
		touch_start.brand = brand
		brand_row.add_child(touch_start)
		touch_start.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		touch_start.pressed.connect(_start_connected_workspace)
	settings_section.add_theme_constant_override("separation", 14)
	chooser.body.add_child(settings_section)
	settings_section.add_child(_caption("Language"))
	settings_section.add_child(localization.selector())
	font_cache_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_section.add_child(font_cache_status)
	font_cache_clear = _button("Clear font cache", _clear_font_cache)
	font_cache_clear.tooltip_text = "Remove downloaded fonts. Installed and bundled fonts are kept."
	settings_section.add_child(font_cache_clear)
	settings_section.add_child(_button(tr("Client-side dictation"), func():
		var dialog := preload("res://scenes/input/ClientDictationSettings.gd").new()
		add_child(dialog)
		dialog.popup_centered()
		dialog.close_requested.connect(dialog.queue_free)))
	settings_section.add_child(_button("About Graffitty", _show_build_info))
	save_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chooser.body.add_child(save_hint)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chooser.footer_actions.add_child(center)
	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", 8)
	center.add_child(navigation)
	var group := ButtonGroup.new()
	for spec in [[connection_tab, "Connection", "plug"], [settings_tab, "Settings", "settings"]]:
		var button: Button = spec[0]
		button.text = spec[1]
		button.icon = ServerCard._icon(spec[2])
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(132, 48)
		button.add_theme_font_size_override("font_size", DesktopText.size(16))
		Page.style_button(button)
		button.autowrap_mode = TextServer.AUTOWRAP_OFF
		for color in ["font_pressed_color", "icon_pressed_color"]:
			button.add_theme_color_override(color, Accent.ACCENT)
		navigation.add_child(button)
	connection_tab.pressed.connect(func(): _select_section(false))
	settings_tab.pressed.connect(func(): _select_section(true))
	_select_section(false)

func _select_section(settings: bool) -> void:
	connections_section.visible = not settings
	settings_section.visible = settings
	connection_tab.set_pressed_no_signal(not settings)
	settings_tab.set_pressed_no_signal(settings)
	for button in [connection_tab, settings_tab]:
		var active: bool = button.button_pressed
		for state in ["normal", "hover", "pressed", "hover_pressed"]:
			var style: StyleBoxFlat = button.get_theme_stylebox("normal").duplicate()
			style.bg_color = Accent.ACTIVE if active else Color("293847")
			style.border_color = Accent.ACCENT
			style.set_border_width_all(1 if active else 0)
			button.add_theme_stylebox_override(state, style)
		for property in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
			button.add_theme_color_override(property, Accent.ACCENT if active else Color("e4e4e7"))
	chooser.scroll.scroll_vertical = 0
	if settings: _refresh_font_cache(true)

func _show_build_info() -> void:
	if about_dialog == null:
		about_dialog = AboutDialog.new()
		add_child(about_dialog)
	about_dialog.present()

func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 48
	Page.style_button(button)
	button.pressed.connect(action)
	return button

func _caption(text: String) -> Label:
	var caption := Label.new()
	caption.text = text
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return caption

func _build_editor() -> void:
	dialog.body.add_child(editor)

func _load_connections() -> void:
	var args := OS.get_cmdline_user_args()
	var use_saved := not Array(args).any(func(arg): return arg.begins_with("--remote-connection=") or arg.begins_with("--remote-connections="))
	if use_saved:
		var path := preload("res://graffitty/paths.gd").stdpath("state").path_join("remote.json")
		if FileAccess.file_exists(path): args.append("--remote-connection=" + path)
	for settings in Authentication.launch_connections(args): open_connection(settings)
	if use_saved:
		for settings in Authentication.saved_connections():
			if settings is Dictionary and settings.get("url") is String:
				var key := _connection_key(settings)
				if not entries.has(key): _remember_entry(settings, "disconnected", "Ready to connect")
		if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
			_restore_last_connection()

func _restore_last_connection() -> void:
	var key: String = view_state.last_connection
	if key.is_empty() or not entries.has(key) or bool(entries[key].get("transient", false)): return
	_restoring = true
	open_when_ready = key
	if transports.has(key):
		_open_workspace(key)
	else:
		# Normal vault lookup/authentication applies; missing credentials stay
		# on the manager rather than bypassing sign-in or opening an editor.
		if open_connection(entries[key]) == null: open_when_ready = ""

func _connection_key(settings: Dictionary) -> String:
	return str(settings.url)

func _remember_entry(settings: Dictionary, state: String, message: String) -> String:
	var key := _connection_key(settings)
	entries[key] = settings.duplicate(true)
	entries[key].erase("token")
	entries[key].erase("password_error")
	_set_state(key, state, message)
	return key

func _set_state(key: String, state: String, message: String, args: Array = []) -> void:
	states[key] = ConnectionState.new(state, message, args)
	_refresh_card(key)
	_update_restore_cover()

func _update_restore_cover() -> void:
	var state: String = states[open_when_ready].state if states.has(open_when_ready) else ""
	_restoring = _restoring and state in ["disconnected", "connecting", "authenticating", "connected"] and navigation.current == navigation.Space.MANAGER
	restore_cover.visible = _restoring

func saved_servers_reordered() -> void:
	var order := Authentication.saved_connections().map(func(entry): return str(entry.url))
	var children := rows.get_children()
	children.sort_custom(func(a, b):
		var ai := order.find(str(a.get_meta(&"server_url", "")))
		var bi := order.find(str(b.get_meta(&"server_url", "")))
		if ai != bi: return ai >= 0 and (bi < 0 or ai < bi)
		return a.get_index() < b.get_index())
	for i in children.size(): rows.move_child(children[i], i)

func _server_order_error(_error: String) -> void:
	localization.text(landing_status, "Could not reorder servers.")

func _refresh_card(key: String) -> void:
	if not cards.has(key):
		var created := ServerCard.new()
		created.activated.connect(func(): _activate(key))
		created.edited.connect(func(): _edit_connection(key))
		created.disconnected.connect(func(): _disconnect(key))
		created.remove_requested.connect(func(): _request_remove(key))
		created.set_meta(&"server_url", str(entries[key].url))
		rows.add_child(created)
		cards[key] = created
		if not bool(entries[key].get("transient", false)):
			preload("res://scenes/remote/ServerReorder.gd").install(created.select, str(entries[key].url), _server_order_error, created)
		saved_servers_reordered.call_deferred()
	var card: ServerCard = cards[key]
	card.update_identity(entries[key])
	localization.text(card.status, str(states[key].message), states[key].args, &"text", true)
	card.update_state(states[key].state, transports.has(key))
	_update_landing_status()

func _update_landing_status() -> void:
	_refresh_font_cache()
	empty_state.visible = entries.is_empty()
	var connected_count := federation.connections.filter(func(connection): return connection.connected).size()
	connect_all.disabled = entries.is_empty()
	if is_instance_valid(touch_start): touch_start.available = connected_count > 0
	landing_status.text = "Connect to a computer running Graffitty." if entries.is_empty() else tr("%d of %d servers connected") % [connected_count, entries.size()]

func _start_connected_workspace() -> void:
	for key in transports:
		if transports[key].connected:
			open_when_ready = key
			_open_workspace(key)
			return

func _connect_all() -> void:
	_open_all_when_ready = true
	for key in entries:
		if states[key].state not in ["connected", "connecting", "authenticating"]:
			open_connection(entries[key])
	_start_connected_workspace()

func _activate(key: String) -> void:
	if not entries.has(key): return
	if states[key].state in ["connected", "connecting", "authenticating"]:
		return
	elif states[key].state == "password":
		_edit_connection(key)
	else:
		var transport := open_connection(entries[key])
		if transport == null and states[key].state == "password": _edit_connection(key)

## Connect a saved server from outside the manager (the Sessions panel).
func connect_server(url: String) -> void:
	for key in entries:
		if str(entries[key].url) != url: continue
		# An attempt already under way keeps running; just open it when ready.
		if states[key].state in ["connecting", "authenticating"]: open_when_ready = key
		else:
			open_when_ready = key
			if states[key].state == "connected": _open_workspace(key)
			else: _activate(key)
		return
	_show_chooser()

func open_connection(settings: Dictionary) -> Node:
	settings = settings.duplicate(true)
	var address_error := Authentication.normalize_address(settings)
	if not address_error.is_empty():
		form_status.text = address_error
		return null
	var address: String = settings.url
	# Authenticate the server; restore its last view after session discovery.
	var connection := settings.duplicate()
	connection.preferred_session = str(settings.get("initial_session", view_state.session(address)))
	var key := _connection_key(settings)
	if not entries.has(key): _remember_entry(settings, "disconnected", "Ready to connect")
	var password := str(settings.get("token", session_passwords.get(key, "")))
	if password.is_empty() and bool(settings.get("remember", true)):
		var saved := Authentication.password(address, str(settings.get("credential_id", "")))
		password = str(saved.get("password", ""))
	if password.is_empty():
		_set_state(key, "password", "Password needed · Enter the current password from Remote Access on the computer.")
		return null
	_stop_transport(key)
	session_passwords[key] = password
	settings.token = password
	_remember_entry(settings, "connecting", "Connecting to server…")
	connection.token = password
	var transport := federation.attach(connection)
	var remember_session := func():
		if transports.get(key) != transport: return
		view_state.remember_session(transport)
	transport.session_switched.connect(remember_session)
	transports[key] = transport
	transport.tree_exiting.connect(func():
		if transports.get(key) == transport:
			transports.erase(key)
			_set_state(key, "disconnected", "Disconnected · Server is still saved")
	)
	Authentication.bind(self, transport, settings, bool(settings.get("remember", false)))
	transport.state_changed.connect(func(message):
		if transports.get(key) != transport: return
		var state := "connected" if transport.connected else "offline" if str(message).begins_with("Offline") else "authenticating" if "Authenticat" in str(message) or "code" in str(message) else "connecting"
		_set_state(key, state, transport.status_source, transport.status_args)
		# Temporary network loss keeps the workspace and its selected pane.
		# RemoteConnection retries automatically; status remains visibly offline
		# and disconnected input is discarded, never replayed after recovery.
	)
	transport.session_closed.connect(_session_closed.bind(key, transport), CONNECT_DEFERRED)
	transport.authenticated.connect(func():
		if transports.get(key) != transport: return
		entries[key].alias = transport.server_alias
		# Only authenticated server metadata selects the OS artwork/account name.
		for field in ["hostname", "platform", "username"]:
			settings[field] = transport.get("server_" + field)
			entries[key][field] = settings[field]
		var save_error := Authentication.save_connection(settings)
		if not save_error.is_empty(): save_hint.text = save_error
		_refresh_card(key)
		if settings.has("remember") and not bool(settings.remember):
			var error := Authentication.clear_password(address, str(settings.get("credential_id", "")))
			if not error.is_empty(): save_hint.text = error
	)
	transport.sessions_changed.connect(func():
		if transports.get(key) != transport: return
		if transport.available_sessions.is_empty():
			_restoring = false
			if open_when_ready == key: open_when_ready = ""
			_update_restore_cover()
		_refresh_card(key)
	)
	transport.changed.connect(func():
		if (open_when_ready == key or _open_all_when_ready) and transport.connected: _open_workspace(key)
	, CONNECT_DEFERRED)
	transport.authentication_failed.connect(func(message):
		if transports.get(key) != transport: return
		_stop_transport(key)
		if "Telegram" in str(message):
			_set_state(key, "verification", "Verification failed · %s\nTry signing in again to request a new code.", [str(message)])
		else:
			session_passwords.erase(key)
			_set_state(key, "password", "Sign-in failed · %s\nThe temporary password may have changed. Enter the current password shown on the computer.", [str(message)])
		if not dialog.visible: _show_chooser()
	, CONNECT_DEFERRED)
	transport.connection_failed.connect(_connection_failed.bind(key, transport), CONNECT_DEFERRED)
	_update_landing_status()
	return transport

func _show_unavailable_transport(key: String, transport: Node) -> void:
	if transports.get(key) != transport or transport.connected or dialog.visible: return
	var active: Node = federation.selected
	if is_instance_valid(view) and is_instance_valid(view.host):
		active = federation.owners.get(view.host.active_session_id, active)
	if active == transport or active == null:
		_hide_keyboard()
		_show_chooser()

func _session_closed(key: String, transport: Node) -> void:
	if transports.get(key) != transport: return
	_refresh_card(key)
	if transport.available_sessions.is_empty(): _show_chooser()

func _connection_failed(message: String, key: String, transport: Node) -> void:
	if transports.get(key) != transport: return
	if open_when_ready == key: open_when_ready = ""
	_stop_transport(key)
	_set_state(key, "error", "Connection error · %s", [message])
	_show_chooser()

func _stop_transport(key: String) -> void:
	if not transports.has(key): return
	_remember_view()
	var transport: Node = transports[key]
	transports.erase(key)
	transport.set_block_signals(true)
	federation.remove(transport)

func _disconnect(key: String) -> void:
	if view_state.last_connection == key: view_state.remember_connection("")
	_stop_transport(key)
	if open_when_ready == key: open_when_ready = ""
	_set_state(key, "disconnected", "Disconnected · Server is still saved")

func _request_remove(key: String) -> void:
	if not entries.has(key) or is_instance_valid(removal): return
	_hide_keyboard()
	removal = ConfirmationDialog.new()
	removal.title = "Remove saved server"
	removal.ok_button_text = "Remove"
	removal.cancel_button_text = "Cancel"
	removal.dialog_text = preload("res://scenes/remote/ConnectionName.gd").display(entries[key]) + "\n\n" + tr("Remove this saved server and its remembered password? The computer's terminals will keep running.")
	removal.dialog_autowrap = true
	add_child(removal)
	ServerCard.style_danger(removal.get_ok_button())
	removal.get_ok_button().icon = ServerCard._icon("trash-2")
	var confirmation := removal
	confirmation.confirmed.connect(func():
		_remove_server(key)
		confirmation.queue_free())
	confirmation.canceled.connect(confirmation.queue_free)
	confirmation.popup_centered_clamped(Vector2i(420, 220), 0.9)
	confirmation.get_cancel_button().grab_focus()

func _remove_server(key: String) -> void:
	if not entries.has(key): return
	var settings: Dictionary = entries[key]
	var error := Authentication.remove_connection(settings)
	if not error.is_empty():
		save_hint.text = error
		return
	if view_state.last_connection == key: view_state.remember_connection("")
	_stop_transport(key)
	session_passwords.erase(key)
	entries.erase(key)
	states.erase(key)
	cards[key].queue_free()
	if open_when_ready == key: open_when_ready = ""
	cards.erase(key)
	_update_landing_status()

func _new_connection() -> void:
	open_when_ready = ""
	editing_key = ""
	pending_settings = {}
	_load_stream_options({})
	label.clear()
	editor.server_alias.clear()
	endpoint.clear()
	token.clear()
	remember.button_pressed = true
	form_status.text = ""
	dialog.title = "Add server"
	_show_password_dialog()

func _edit_connection(key: String) -> void:
	open_when_ready = ""
	editing_key = key
	pending_settings = entries[key].duplicate(true)
	_load_stream_options(pending_settings.get("chromium_stream", {}))
	label.text = str(pending_settings.get("name", ""))
	editor.server_alias.text = str(pending_settings.get("alias", ""))
	endpoint.text = str(pending_settings.url)
	token.clear()
	remember.button_pressed = bool(pending_settings.get("remember", false))
	form_status.text = "Enter the current password to reconnect. Your server address is already filled in."
	dialog.title = "Edit server"
	_show_password_dialog()

func _submit_connection() -> void:
	var address := endpoint.text.strip_edges()
	if token.text.is_empty():
		form_status.text = "Enter the current password shown on the computer."
		dialog.scroll.ensure_control_visible.call_deferred(form_status)
		return
	var normalized := {"url": address}
	var address_error := Authentication.normalize_address(normalized)
	if not address_error.is_empty():
		form_status.text = address_error
		dialog.scroll.ensure_control_visible.call_deferred(form_status)
		return
	address = normalized.url
	var settings := pending_settings.duplicate(true)
	if settings.get("url", address) != address:
		for field in ["hostname", "platform", "username"]: settings.erase(field)
		settings.erase("credential_id")
		settings.erase("transient")
	settings.merge({"name": label.text.strip_edges(), "alias": editor.server_alias.text.strip_edges(), "url": address, "remember": remember.button_pressed}, true)
	settings.chromium_stream = {}
	for key in stream_options:
		settings.chromium_stream[key] = stream_options[key].get_selected_id()
	var error := Authentication.save_connection(settings)
	if not error.is_empty():
		form_status.text = error
		return
	var key := _connection_key(settings)
	if not editing_key.is_empty() and editing_key != key:
		_remove_server(editing_key)
	_remember_entry(settings, "disconnected", "Ready to connect")
	settings.token = token.text
	token.clear()
	pending_settings = {}
	editing_key = ""
	open_when_ready = ""
	dialog.hide()
	_show_chooser()
	open_connection(settings)
	_hide_keyboard()

func _hide_keyboard() -> void:
	if is_instance_valid(keyboard_insets): keyboard_insets.prepare_keyboard_close()
	if is_instance_valid(terminal_ime): terminal_ime.hide()
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_hide()

func _toggle_keyboard() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return
	var keyboard_visible: bool = keyboard_insets.keyboard_visible() if is_instance_valid(keyboard_insets) else DisplayServer.virtual_keyboard_get_height() > 0
	if keyboard_visible:
		_hide_keyboard()
	else:
		if is_instance_valid(keyboard_insets): keyboard_insets.prepare_keyboard_open()
		view.host.focus_pane(view.host.pane_focus)
		if is_instance_valid(terminal_ime) and terminal_ime.open(): return
		DisplayServer.virtual_keyboard_show("", Rect2(), DisplayServer.KEYBOARD_TYPE_MULTILINE)

func _cancel_editor() -> void:
	token.clear()
	pending_settings = {}
	editing_key = ""
	dialog.hide()
	_show_chooser()
	_hide_keyboard()

func _show_password_dialog() -> void:
	_set_workspace_visible(false)
	navigation.enter(navigation.Space.EDITOR)
	dialog.scroll.scroll_vertical = 0

func _show_chooser() -> void:
	if dialog.visible: return
	# Explicit navigation cancels a pending automatic open, not the transport.
	_open_all_when_ready = false
	open_when_ready = ""
	if is_instance_valid(dictation): dictation.stop()
	_set_workspace_visible(false)
	_select_section(false)
	navigation.enter(navigation.Space.MANAGER)
	_refresh_font_cache(true)
	_update_landing_status()

## `fly` plays the session transition when this changes the session on screen.
##
## A finger swipe between servers passes false: it draws its own slide. `pane`
## lands on that pane of the server's session, not on its last tab.
func _open_workspace(key: String, fly := true, pane := "") -> void:
	if dialog.visible: return
	var transport: Node = transports.get(key)
	if transport == null or not transport.connected: return
	federation.selected = transport
	if transport.workspace.is_empty():
		open_when_ready = key
		if transport.available_sessions.is_empty(): transport.send_action("session_new", -1, {})
	elif transport.topology.tabs.is_empty():
		open_when_ready = key
	elif view.host != null:
		var host: Node = view.host
		var target: int = host.workspace_layout.active
		if not transport.topology.tabs.any(func(tab): return int(tab.id) == target):
			target = view_state.active_tab(transport)
			if target < 0: target = int(transport.topology.tabs[0].id)
		var wanted: int = host.workspace_layout.containing(pane) if not pane.is_empty() else -1
		if wanted >= 0:
			# select_workspace lands on the tab's focused pane: one flight, no
			# second hop from the tab's previous pane.
			target = wanted
			var group: Dictionary = host.workspace_layout.tab(target)
			preload("res://scenes/WorkspaceLayout.gd").find(group.tree, pane).shown = true
			group.focused = pane
		# Leaving for another server's session is a session change like any
		# other, so it flies; a tab of the session already shown just opens.
		var flying: bool = fly and target != host.workspace_layout.active and navigation.current == navigation.Space.WORKSPACE and is_instance_valid(host.get("world")) and not host.session_switch_in_progress
		if flying:
			_remember_view()
			host.session_switch_in_progress = true
			host.world.begin_session_transition()
		host.select_workspace(target, true)
		if flying:
			host.world.finish_session_transition()
			host.session_switch_in_progress = false
		open_when_ready = ""
		_open_all_when_ready = false
		_set_workspace_visible(true)
		_remember_active_connection()

## Reveal one pane of the shared host (the Agents panel).
##
## A pane on another server is a session change, so it flies like opening that
## server's card; a pane of the server on screen is the ordinary tab switch.
func reveal_pane(pane: String) -> void:
	var host: Node = view.host
	var owner: Node = federation.owners.get(host.workspace_layout.containing(pane))
	if owner != null and owner != federation.owners.get(host.workspace_layout.active):
		for key in transports:
			if transports[key] == owner:
				_open_workspace(key, true, pane)
				break
	host.reveal_pane(pane)

func _workspace_ready() -> void:
	var pointer: Control = view.host.workspace_view.mobile_pointer
	if pointer != null and remote_swipe == null:
		remote_swipe = preload("res://scenes/remote/RemoteSwipe.gd").new()
		remote_swipe.manager = self
		add_child(remote_swipe)
		pointer.remote_swipe_enabled = true
		pointer.remote_swipe.connect(remote_swipe.handle)
	view.host.workspace_view.navigation_changed.connect(_queue_view_save)
	view.host.ui_changed.connect(_remember_selection)
	_view_selection.clear()
	_remember_selection()
	navigation.apply_workspace()
	_update_landing_status()
	if not open_when_ready.is_empty(): _open_workspace(open_when_ready)

func _set_workspace_visible(shown: bool) -> void:
	if not shown:
		if is_instance_valid(remote_swipe): remote_swipe.cancel()
		_remember_view()
	navigation.enter(navigation.Space.WORKSPACE if shown else navigation.Space.MANAGER)
	_update_restore_cover()

func _queue_view_save() -> void:
	# Restart a single deadline; input and animation frames only update memory.
	_view_save_timer.start()

func _remember_active_connection() -> void:
	if navigation.current != navigation.Space.WORKSPACE: return
	var active: Node = federation.selected
	if is_instance_valid(view) and is_instance_valid(view.host):
		active = federation.owners.get(view.host.workspace_layout.active, active)
	for key in transports:
		if transports[key] == active and active.connected and not bool(entries[key].get("transient", false)):
			view_state.remember_connection(key)
			return

func _remember_selection() -> void:
	_remember_active_connection()
	var layout: RefCounted = view.host.workspace_layout
	var selection := [layout.active, layout.tab(layout.active).get("focused", "")]
	if selection != _view_selection:
		_view_selection = selection
		_queue_view_save()

func _save_settled_view() -> void:
	if not is_instance_valid(view) or not is_instance_valid(view.host): return
	if view.host.workspace_view.navigation_in_progress():
		_view_save_timer.start()
		return
	_remember_view()

func _remember_view() -> void:
	if is_instance_valid(view) and is_instance_valid(view.host):
		view_state.capture(view.host, federation.connections)
	_view_save_timer.stop()

func _return_to_workspace() -> void:
	if view.host != null:
		_set_workspace_visible(true)
		view.host.focus_pane(view.host.pane_focus)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_remember_view()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		# Back dismisses workspace menus, never both a menu and the workspace.
		if is_instance_valid(view) and is_instance_valid(view.host):
			if preload("res://scenes/input/WorkspaceMenus.gd").dismiss(view.host): return
		if is_instance_valid(removal):
			removal.hide()
			removal.queue_free()
			return
		for card in cards.values():
			if card.actions.visible:
				card.actions.hide()
				return
		if dialog.visible: _cancel_editor()
		elif not chooser.visible: _show_chooser()
		elif view != null and view.host != null: _return_to_workspace()

func _refresh_font_cache(force := false) -> void:
	if not is_instance_valid(font_cache_clear): return
	var wait := font_cache_updated + 1000 - Time.get_ticks_msec()
	if not force and wait > 0:
		# Throttle directory scans, but still show the state after the last
		# download progress update, such as a finished download.
		if not font_cache_pending and is_inside_tree():
			font_cache_pending = true
			get_tree().create_timer(wait / 1000.0).timeout.connect(func():
				font_cache_pending = false
				_refresh_font_cache(true)
			)
		return
	font_cache_updated = Time.get_ticks_msec()
	var stats := preload("res://scenes/remote/ServerFonts.gd").cache_stats()
	localization.text(font_cache_status, "Font cache: %.1f MiB · files: %d", [float(stats.bytes) / 1048576.0, stats.files])
	if stats.downloading: font_cache_status.text += tr(" · downloading")
	font_cache_clear.disabled = stats.files == 0 or stats.downloading

func _clear_font_cache() -> void:
	var result := preload("res://scenes/remote/ServerFonts.gd").clear_cache()
	_refresh_font_cache(true)
	if not str(result.error).is_empty():
		font_cache_status.text += "\n" + str(result.error)
	else:
		font_cache_status.text += "\n" + tr("Cleared %.1f MiB. Active terminals keep their loaded fonts.") % (float(result.bytes) / 1048576.0)

func _load_stream_options(settings: Dictionary) -> void:
	for key in stream_options:
		var option: OptionButton = stream_options[key]
		option.select(maxi(0, option.get_item_index(int(settings.get(key, 0)))))
