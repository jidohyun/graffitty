extends Node
## A remote connection supplies sessions to the ordinary Graffitty host.
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
var remember := CheckBox.new()
var auth_bound := false
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")
signal host_empty
signal host_ready
signal detached
var settings: Dictionary = { }
var view_save_timer := Timer.new()
var stream_update_at := 0
var stream_sizes := {}
var stream_background := false
var managed := false
var local_return: RefCounted
var federated := false
var server_chooser: Callable
var connection: Node = Connection.new()
var host: Node
var server_epoch := ""
var topology_signature := ""
var workspace_signature := ""
var applying := false
var closing_window := false
var transferring := false
var moving_presentation := false
var presentation_tabs: Array = []
var primary_presentation := true
var host_bound := false
var pending_focus := -1
## The tab active when pending_focus was requested; -1 always applies it.
var pending_focus_from := -1
var switching_session := false
var switching_topology_generation := -1
## The session this window is switching to after its own session closed.
var fallback_target := ""
var pending_close_origin: Dictionary = {}
## Owner samples can precede pane creation while server fonts are downloading.
var pending_resources: Dictionary = {}
var connection_file := ""
var clipboard_generations: Dictionary = {}
var clipboard_replies: Array[Dictionary] = []
var clipboard_reply_bytes := 0
var clipboard_reply_busy := false
var dialog := AcceptDialog.new()
var endpoint := LineEdit.new()
var secret: LineEdit = preload("res://scenes/SecretInput.gd").new()
var status := Label.new()
var loaded_url := ""
var loaded_secret := ""
## Desktop windows remember their own views. RemoteManager supplies its
## persistent device-local store for the managed workspace.
var view_state: RefCounted = preload("res://scenes/remote/RemoteViewState.gd").new()


func _ready() -> void:
	add_to_group("shared_presentations")
	var application: Node = get_node("/root/TerminalApplication")
	if not federated and application.opens_windows() and (managed or settings.get("shared_local", false)):
		server_chooser = func(): application.show_servers(self)
	get_window().title = "Graffitty"
	add_child(connection)
	view_save_timer.one_shot = true
	view_save_timer.wait_time = .4
	view_save_timer.timeout.connect(_save_view)
	add_child(view_save_timer)
	get_window().close_requested.connect(request_close_window)
	get_window().focus_entered.connect(_follow_server_language)
	if not federated: connection.authenticated.connect(_follow_server_language)
	get_node("/root/Localization").changed.connect(_refresh_localized_status)
	dialog.title = "Connect to Graffitty"
	dialog.ok_button_text = "Connect"
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(520, 130)
	endpoint.placeholder_text = "ws://127.0.0.1:7183"
	secret.placeholder_text = "Password"
	form.add_child(endpoint)
	form.add_child(secret)
	remember.text = "Remember password in system credential store"
	form.add_child(remember)
	form.add_child(status)
	dialog.add_child(form)
	add_child(dialog)
	dialog.confirmed.connect(_connect)
	if local_return != null:
		dialog.add_button("Return to This Computer", true, "local_return")
		dialog.custom_action.connect(func(action):
			if action == "local_return": detach.call_deferred())
		dialog.canceled.connect(detach.call_deferred)
	connection.acknowledged.connect(
		func(message):
			if message.has("created"):
				if host != null and host.application.checkpoints.importing: return
				pending_focus = int(message.created)
				var operation: Variant = host.session_backend.pending_operations.get(int(message.get("request", -1))) if host != null else null
				pending_focus_from = int(operation.get("active", -1)) if operation is Dictionary else -1
				if not primary_presentation and pending_focus not in presentation_tabs:
					presentation_tabs.append(pending_focus)
				_refresh.call_deferred(),
	)
	connection.changed.connect(_refresh)
	connection.changed.connect(func():
		if is_instance_valid(host): host.refresh_sessions_menu.call_deferred())
	connection.panes_updated.connect(_apply_pane_update)
	connection.session_switching.connect(func():
		view_state.capture(host, connection.connections if federated else [connection]))
	connection.session_switched.connect(func():
		pending_resources.clear()
		switching_session = true
		var transport: Node = connection.selected if federated else connection
		switching_topology_generation = transport.topology_generation
		if is_instance_valid(host) and is_instance_valid(host.world):
			host.session_switch_in_progress = true
			# Returning to the session already on screen is not a switch: its
			# view is rebound without the session transition effect.
			if not transport.session_reattached:
				host.world.begin_session_transition()
		if not federated:
			view_state.remember_session(connection)
			primary_presentation = true
			presentation_tabs.clear()
		pending_focus = -1
		pending_focus_from = -1
		pending_close_origin.clear()
		topology_signature = ""
		workspace_signature = "")
	connection.terminal_received.connect(_frame)
	connection.terminal_input_received.connect(_input_activity)
	connection.resources_received.connect(_resources)
	connection.state_changed.connect(_status)
	if connection.has_signal("video_transport_changed"):
		# The status line warns while browser video falls back to the WebSocket.
		connection.video_transport_changed.connect(func():
			if is_instance_valid(host) and host.application != null and host.application.get("mods") != null:
				host.application.mods.publish_window(host))
	connection.chromium_video_received.connect(_chromium_frame)
	connection.chromium_gpu_state_received.connect(func(id: int, active: bool):
		if not active and host != null and host.chromiums.has(id):
			host.chromiums[id].reject_gpu("Shared texture channel closed", false)
	)
	connection.notification_received.connect(_remote_notification)
	connection.clipboard_received.connect(_remote_clipboard)
	if federated:
		return
	connection.connection_failed.connect(func(_message):
		if is_instance_valid(host): host.layout_root.hide()
		_show_connection_ui()
	, CONNECT_DEFERRED)
	if settings.get("shared_local", false):
		connection.session_closed.connect(_local_session_closed)
		connection.authenticated.connect(func():
			settings.workspace = connection.workspace
			settings.get_or_add("capabilities", {}).erase("new_session")
			settings.capabilities.require_workspace = true)
		if host != null: _bind_host()
		connection.connect_shared(settings)
		return
	connection.session_closed.connect(_remote_session_closed, CONNECT_DEFERRED)
	if server_chooser.is_valid():
		connection.authentication_failed.connect(func(_message): _show_connection_ui(), CONNECT_DEFERRED)
		connection.authenticated.connect(func():
			if settings.has("remember") and not settings.remember:
				var error := Authentication.clear_password(str(settings.url), str(settings.get("credential_id", "")))
				if not error.is_empty(): connection._set_state(error)
		)
	if host != null: _bind_host()
	if not settings.is_empty():
		connection.stream_quality = settings.get("chromium_stream", {}).duplicate()
		connection.preferred_session = str(settings.get("initial_session", view_state.session(str(settings.get("url", "")))))
		connection.namespace_ids = managed
		endpoint.text = str(settings.get("url", ""))
		secret.text = str(settings.get("token", ""))
		_connect()
		return
	connection_file = preload("res://graffitty/paths.gd").stdpath("state").path_join("remote.json")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--remote-connection="):
			connection_file = arg.trim_prefix("--remote-connection=")
		if arg.begins_with("--remote-url="):
			endpoint.text = arg.trim_prefix("--remote-url=")
	if FileAccess.file_exists(connection_file):
		_connect()
	else:
		_show_connection_ui()


func _connect() -> void:
	if FileAccess.file_exists(connection_file):
		var settings: Variant = JSON.parse_string(FileAccess.get_file_as_string(connection_file))
		if settings is Dictionary:
			connection.preferred_session = str(settings.get("initial_session", view_state.session(str(settings.get("url", "")))))
			if endpoint.text.is_empty() or endpoint.text == loaded_url:
				endpoint.text = str(settings.get("url", ""))
			if secret.text.is_empty() or secret.text == loaded_secret:
				secret.text = str(settings.get("token", ""))
			loaded_url = str(settings.get("url", ""))
			loaded_secret = str(settings.get("token", ""))
	if secret.text.is_empty() and not endpoint.text.is_empty():
		var saved := Authentication.password(endpoint.text)
		if not saved.has("error"):
			secret.text = saved.password
	if endpoint.text.is_empty() or secret.text.is_empty():
		status.text = "Enter the server URL and password"
		_show_connection_ui()
		return
	if connection.connected and connection.workspace.is_empty():
		connection.send_action("session_new", -1, {})
	elif connection.connected and connection.topology.tabs.is_empty():
		connection.send_action("create", -1, { "kind": "tab" })
	else:
		if not auth_bound:
			settings.url = endpoint.text
			Authentication.bind(self, connection, settings, false)
			connection.authenticated.connect(func():
				settings.alias = connection.server_alias
				if settings.get("remember", false) or remember.button_pressed:
					var error := Authentication.remember(settings.merged({"url": connection.url}, true), connection.token)
					if not error.is_empty():
						status.text = error
			)
			auth_bound = true
		connection.server_alias = str(settings.get("alias", ""))
		connection.controller_identity = str(settings.get("credential_id", endpoint.text))
		connection.connect_remote(endpoint.text, secret.text)
		secret.clear()


func _show_connection_ui() -> void:
	if server_chooser.is_valid() and not settings.get("shared_local", false):
		server_chooser.call()
	else:
		dialog.popup_centered()

func _refresh_localized_status() -> void:
	_status("" if federated else connection.status_message)

## This window's local session ended (killed from the Sessions panel, the CLI
## or another window).
##
## Show another live session in this window instead; retire it only when every
## remaining session is already shown elsewhere. Retiring the last window
## restores a parked remote view, or quits.
func _local_session_closed() -> void:
	var target := ""
	if not transferring and not closing_window and is_instance_valid(host):
		target = _local_fallback_session()
	if not target.is_empty():
		fallback_target = target
		var result: Dictionary = await connection.request_action("session_switch", {"name": target})
		fallback_target = ""
		if result.get("type") != "error": return
		push_warning("Could not show session %s: %s" % [target, str(result.get("message", ""))])
	if connection.connected: connection.disconnect_remote()
	if not transferring and not closing_window and is_instance_valid(host):
		host.application.retire_empty_host.call_deferred(host, true)


func _local_fallback_session() -> String:
	if federated or not connection.connected: return ""
	var shown := PackedStringArray()
	var peers: Array = get_tree().get_nodes_in_group("shared_presentations")
	for other in peers:
		if other == self or other.federated or not is_instance_valid(other.connection) or other.connection.url != connection.url: continue
		if not other.fallback_target.is_empty(): shown.append(other.fallback_target)
		if not other.connection.connected: continue
		# Several windows can present tabs of the closed session. One of them
		# moves on (its primary presentation, else the first); the rest retire.
		if other.connection.workspace == connection.workspace:
			if other.primary_presentation and not primary_presentation: return ""
			if other.primary_presentation == primary_presentation and peers.find(other) < peers.find(self): return ""
		else: shown.append(other.connection.workspace)
	return connection.fallback_session(shown)


func _remote_session_closed() -> void:
	if transferring or closing_window: return
	if connection.available_sessions.is_empty(): _show_connection_ui()

func _show_remote_unavailable() -> void:
	if settings.get("shared_local", false) or connection.connected: return
	if server_chooser.is_valid():
		server_chooser.call()
		return
	if managed: return
	if is_instance_valid(host): host.layout_root.hide()
	_show_connection_ui()

func _status(message: String) -> void:
	if not connection.connected: pending_resources.clear()
	if not federated and not connection.connected and is_instance_valid(host):
		clipboard_generations.clear()
		for session in host.sessions.values():
			if is_instance_valid(session.term): session.term.remote_clipboard_reset(-1)
	var source := message
	var args: Array = []
	if federated:
		source = "%d of %d servers connected"
		args = [connection.connections.filter(func(c): return c.connected).size(), connection.connections.size()]
	elif message == connection.status_message:
		source = connection.status_source
		args = connection.status_args
	var localization := get_node("/root/Localization")
	localization.text(status, source, args, &"text", true)
	if not managed:
		var title := "Graffitty"
		var fonts: RefCounted = connection.get("server_fonts")
		var fetching: bool = fonts != null and fonts.fetch_percent >= 0
		get_window().title = title if connection.connected and not fetching else title + " — " + status.text
	if message.contains("Authentication failed"):
		_show_connection_ui.call_deferred()
	if not federated and message.begins_with("Offline"):
		_show_remote_unavailable.call_deferred()


func _bind_host() -> void:
	if host_bound: return
	host_bound = true
	if not federated and host.application.opens_windows():
		host.server_chooser = server_chooser
		host.application.desktop_client_ready(self)
	if get_window().close_requested.is_connected(host.request_close_window):
		get_window().close_requested.disconnect(host.request_close_window)
	host.ui_changed.connect(_subscribe)
	if not federated and not settings.get("shared_local", false):
		host.ui_changed.connect(func(): if not applying: view_save_timer.start())
		host.workspace_view.navigation_changed.connect(func(): view_save_timer.start())
	host.presentation_changed.connect(_subscribe)
	host.session_added.connect(_bind_terminal_input)
	for id in host.sessions: _bind_terminal_input(id)
	host.ui_changed.connect(_follow_server_language)
	host.ui_changed.connect(host.refresh_sessions_menu.call_deferred)
	host.ui_changed.connect(func():
		settings.startup_world = host.current_plugin
		if not applying: host.session_backend.commit_workspace(host)
	)

func _follow_server_language() -> void:
	if not is_inside_tree() or not get_window().has_focus(): return
	var source: Node = connection
	if federated:
		source = connection.selected
		if is_instance_valid(host):
			var id := int(str(host.pane_focus).trim_prefix("%"))
			source = connection.owners.get(id, connection.owners.get(host.workspace_layout.active, source))
	get_node("/root/Localization").follow_server(source)

func _presentation_state(value: Dictionary) -> Dictionary:
	if federated: return value
	var allowed: Array = presentation_tabs.duplicate()
	if primary_presentation:
		allowed = value.get("tabs", []).map(func(tab): return int(tab.id))
		for other in get_tree().get_nodes_in_group("shared_presentations"):
			if other == self or other.primary_presentation or other.federated: continue
			if other.connection.url != connection.url or other.server_epoch != server_epoch: continue
			if other.connection.workspace != connection.workspace: continue
			for id in other.presentation_tabs: allowed.erase(id)
	# An action acknowledgment can advance canonical order before the next
	# topology broadcast retires its pane mirrors. Do not briefly sort removed
	# tabs to index -1, or recapture/recreate them from that older pane list.
	if value.get("authoritative_layout", false):
		var order: Array = value.workspace_state.order.map(func(id): return int(id))
		allowed = allowed.filter(func(id): return id in order)
	var result := value.duplicate()
	result.tabs = value.get("tabs", []).filter(func(tab): return int(tab.id) in allowed)
	result.panes = value.get("panes", []).filter(func(pane): return int(pane.tab) in allowed)
	result.chromiums = value.get("chromiums", []).filter(func(chromium): return int(chromium.get("tab", chromium.owner)) in allowed)
	return result

## The pane to focus on entering a session: where its server-owned state left
## off (active tab, that tab's focused pane), else the first tab.
static func resume_focus(topology: Dictionary) -> int:
	var ids: Array = topology.get("tabs", []).map(func(tab): return int(tab.id))
	if ids.is_empty(): return -1
	var workspace: Dictionary = topology.get("workspace_state", {}) if topology.get("workspace_state") is Dictionary else {}
	var active := int(workspace.active) if workspace.get("active") != null else -1
	if active not in ids: return int(ids[0])
	var tab: Variant = workspace.get("layout", {}).get("tabs", {}).get(str(active))
	var focused := str(tab.get("focused", "")) if tab is Dictionary else ""
	if not preload("res://scenes/PaneTargets.gd").valid(focused): return active
	var pane := int(focused.substr(1))
	return pane if topology.get("panes", []).any(func(item): return int(item.id) == pane and int(item.tab) == active) else active


func _refresh() -> void:
	var profiled_started := Time.get_ticks_usec()
	_refresh_body()
	if not applying and not switching_session: _flush_resource_samples()
	if not applying and not switching_session and is_instance_valid(host) and host.session_switch_in_progress:
		if is_instance_valid(host.world): host.world.finish_session_transition()
		host.session_switch_in_progress = false
	preload("res://graffitty/frame_profile.gd").add("RemoteClient._refresh", Time.get_ticks_usec() - profiled_started)


func _refresh_body() -> void:
	# Session-list and font updates may arrive before the new topology. Keep
	# the departing capture until the selected session's panes actually arrive.
	if switching_session:
		var transport: Node = connection.selected if federated else connection
		if transport.topology_generation == switching_topology_generation: return
	if not connection.fonts_ready(): return
	if applying or closing_window:
		return
	applying = true
	var state: Dictionary = _presentation_state(connection.topology)
	if switching_session:
		var target: Dictionary = connection.selected.topology if federated else state
		if not target.get("tabs", []).is_empty():
			var transport: Node = connection.selected if federated else connection
			# Restored tab/pane/camera preferences are client-owned. Server focus
			# supplies a first view only when this client has no saved view.
			pending_focus = -1 if view_state.active_tab(transport) >= 0 else resume_focus(target)
			# A switch made to reach one pane (the Agents panel) lands there.
			if is_instance_valid(host) and host.has_meta("session_switch_focus"):
				var wire := int(host.get_meta("session_switch_focus"))
				host.remove_meta("session_switch_focus")
				var wanted := int(connection.local_id(wire)) if connection.has_method("local_id") else wire
				if target.get("panes", []).any(func(pane): return int(pane.id) == wanted): pending_focus = wanted
			pending_focus_from = -1
		switching_session = false
	if state.tabs.is_empty():
		if settings.get("shared_local", false) and is_instance_valid(host):
			host.application.retire_empty_host.call_deferred(host, true)
			applying = false
			return
		_release_host()
		status.text = "Workspace is empty — connect to open a terminal"
		if federated:
			host_empty.emit()
		else:
			_show_connection_ui()
		applying = false
		return
	if server_epoch != connection.epoch:
		server_epoch = connection.epoch
		topology_signature = ""
		workspace_signature = ""
		_release_host()
	# A parked view (for example the source of a Sessions-panel drop preview)
	# can still apply topology, but must not draw over the view replacing it.
	if not managed and connection.connected and is_instance_valid(host) and not host.application.desktop_presentation(self).parked:
		host.layout_root.show()
	var layout_state := state.duplicate()
	layout_state.erase("graph")
	layout_state.erase("edges")
	# Background font downloads replace stand-in faces without a topology change.
	layout_state.fonts = connection.fonts_revision()
	var signature := JSON.stringify(layout_state)
	var next_workspace_signature := workspace_layout_signature(state)
	if host != null and signature == topology_signature and pending_focus < 0:
		applying = false
		return
	var geometry_changed := host == null or next_workspace_signature != workspace_signature
	if host == null:
		host = load("res://scenes/TerminalHost.gd").new()
		host.application = get_node("/root/TerminalApplication")
		host.server_chooser = server_chooser
		host.session_backend = preload("res://scenes/session/RemoteSessionBackend.gd").new(
			connection
		)
		# A fitting client sizes the shared main area when it is used last;
		# otherwise this window letterboxes the area the server keeps.
		host.session_backend.fit_main_view = host.application.fit_main_view
		host.session_backend.workspace_rejected.connect(func():
			workspace_signature = ""
			topology_signature = "")
		host.restoring_window = true
		# A server supplies sessions and layout, never this window's renderer.
		host.current_plugin = str(settings.get("startup_world", preload("res://config/UserConfig.gd").world_path(OS.get_cmdline_user_args())))
		_install_layout(state, false)
		add_child(host)
		_bind_host()
		# Fresh client navigation already fits Main View. Inspecting a pane here
		# enters overview during startup and can land before layout is ready.
		host_ready.emit()
	elif next_workspace_signature != workspace_signature:
		_install_layout(state, true)
	else:
		# Grid/PID/title updates must not replace an in-progress drag with the
		# unchanged owner layout. Titles still refresh independently of geometry.
		host.set_tabs(terminal_definitions(state))
		for tab in state.tabs:
			var group: Dictionary = host.workspace_layout.tab(int(tab.id))
			group.title = str(tab.title) if tab.get("pinned", false) else ""
	workspace_signature = next_workspace_signature
	topology_signature = signature
	# Sessions are real native Terminals backed by a network queue, never PTYs.
	for pane in state.panes:
		var id := int(pane.id)
		var pair: Dictionary = host.session_for(id, host.world)
		var filetree_changed: bool = pair.term.get_meta("filetree_open", false) != bool(pane.get("filetree_open", false))
		pair.term.set_meta("filetree_open", bool(pane.get("filetree_open", false)))
		pair.term.set_meta("filetree_owner", int(pane.filetree_owner) if pane.get("filetree_owner") != null else -1)
		pair.term.set_meta("spawned_by", int(pane.spawned_by) if pane.get("spawned_by") != null else -1)
		pair.model.title_is_fallback = bool(pane.get("title_is_fallback", false))
		pair.model.pin_title(str(pane.get("pinned_title", "")))
		pair.model.builtin_title = str(pane.get("builtin_title", ""))
		pair.model.set_owner_title(str(pane.automatic_title))
		pair.model.foreground_app = pane.get("app", {})
		pair.model.effect_holds = pane.get("effect_holds", [])
		pair.model.shell = str(pane.shell)
		if pair.term.has_method("set_remote_shell_pid"):
			pair.term.set_remote_shell_pid(int(pane.get("pid", -1)))
		var font_size := int(pane.get("font_size", host.world.term_font_size))
		pair.term.set_meta("pane_font_size", font_size)
		geometry_changed = geometry_changed or pair.term.get_meta("server_content_insets", null) != pane.content_insets
		pair.term.set_meta("server_content_insets", pane.content_insets)
		var font_state := {"faces": connection.fonts_for(id).faces, "size": font_size, "metrics": pane.font_metrics, "ligatures": connection.fonts_for(id).config.ligatures}
		var font_signature := JSON.stringify(font_state)
		if pair.term.get_meta("server_font_signature", "") != font_signature:
			geometry_changed = true
			if not pair.term.apply_server_font(font_signature):
				status.text = "Cannot load server font"
				applying = false
				return
			pair.term.set_meta("server_font_signature", font_signature)
		if filetree_changed and host.workspace_view.panes.has("%%%d" % id):
			host.workspace_view.panes["%%%d" % id].refresh()
		if id == host.active_session_id:
			host.world.term_font_size_default = connection.font_default(id)
	var chromiums: Array = state.get("chromiums", [])
	var chromium_ids: Array = chromiums.map(
		func(item):
			return int(item.id),
	)
	for id in host.chromiums.keys():
		if id not in chromium_ids:
			host.chromiums[id].release_rendering()
			# Shader page slots also retain viewport textures until the next draw.
			host.workspace_view._sync_video_layers()
			host.chromiums[id].queue_free()
			host.chromiums.erase(id)
	for workspace in host.workspaces.values():
		workspace.chromiums.clear()
		workspace.chromium = -1
	for item in chromiums:
		var id := int(item.id)
		if not host.chromiums.has(id):
			var chromium := preload("res://scenes/remote/RemoteChromiumSession.gd").new()
			chromium.session_id = id
			chromium.connection = connection
			host.chromiums[id] = chromium
			host.application.add_child(chromium)
			chromium.changed.connect(host._on_session_changed)
			var monitor := preload("res://scenes/ChromiumResourceMonitor.gd").new()
			monitor.name = "ResourceMonitor"
			monitor.configure(chromium, host.world._merged_terminal_config())
			chromium.resource_monitor = monitor
			chromium.add_child(monitor)
		var controller := chromium_controller(chromiums, int(item.owner))
		host.chromiums[id].owner_id = int(item.owner)
		host.chromiums[id].tab_id = controller
		if controller != id:
			host.ensure_workspace(controller)
			host.workspaces[controller].chromiums.append(id)
			host.workspaces[controller].chromium = id
		host.chromiums[id].pinned_title = str(item.pinned_title)
		host.chromiums[id].apply_state(item.state)
	if pending_focus >= 0 and host.sessions.has(pending_focus):
		# Selecting another tab after asking for a pane cancels the automatic jump.
		if pending_focus_from < 0 or host.workspace_layout.active == pending_focus_from:
			# Reveal: a hidden pane focused in place leaves the camera fitting
			# content that is not laid out.
			host.reveal_pane("%%%d" % pending_focus)
		pending_focus = -1
	# Title signals update pane headers directly. Re-arranging every pane and
	# rebuilding graph sockets for each CLI spinner tick monopolizes Android's
	# UI thread even when terminal painting is disabled.
	if geometry_changed: host._refresh_workspace_layout()
	host._finish_pane_close(pending_close_origin)
	pending_close_origin = {}
	host.refresh_app_context()
	_subscribe()
	applying = false


static func chromium_controller(chromiums: Array, owner: int) -> int:
	# A window links to its main chromium pane, but all windows use the same
	# terminal capability when making requests to the shared session server.
	for _step in chromiums.size():
		var parent: Array = chromiums.filter(func(item): return int(item.id) == owner)
		if parent.is_empty() or int(parent[0].owner) == owner: return owner
		owner = int(parent[0].owner)
	return owner


static func workspace_layout_signature(state: Dictionary) -> String:
	var workspace: Dictionary = state.get("workspace_state", {}).duplicate()
	workspace.erase("revision")
	# A federation carries each owner's canonical layout on its tab. Terminal
	# titles, process metadata and grid updates are not geometry changes there
	# either; including whole panes reinstalls every layout on streaming output.
	return JSON.stringify({"workspace": workspace,
		"tabs": state.tabs.map(func(tab): return [int(tab.id), tab.get("canonical_layout", {}), tab.get("canonical_area", [])]),
		"panes": state.panes.map(func(pane): return [int(pane.id), int(pane.tab)]),
		"chromiums": state.get("chromiums", []).map(func(chromium): return [int(chromium.id), int(chromium.owner)])})


## A `pane_update` changed titles, foreground apps, holds or filetree roots of
## existing panes.
##
## Patch those models directly: the layout, fonts and tab set are unchanged,
## so the full `_refresh` pass (and its JSON signature) is skipped.
func _apply_pane_update(ids: Array) -> void:
	var profiled_started := Time.get_ticks_usec()
	_apply_pane_update_body(ids)
	preload("res://graffitty/frame_profile.gd").add("RemoteClient._apply_pane_update", Time.get_ticks_usec() - profiled_started)


func _apply_pane_update_body(ids: Array) -> void:
	if host == null or applying or closing_window or not connection.fonts_ready(): return
	var context_changed := false
	for pane in connection.topology.get("panes", []):
		var id := int(pane.id)
		if id not in ids or not host.sessions.has(id): continue
		var pair: Dictionary = host.sessions[id]
		if not is_instance_valid(pair.term) or not is_instance_valid(pair.model): continue
		var filetree_changed: bool = pair.term.get_meta("filetree_open", false) != bool(pane.get("filetree_open", false))
		pair.term.set_meta("filetree_open", bool(pane.get("filetree_open", false)))
		pair.model.title_is_fallback = bool(pane.get("title_is_fallback", false))
		pair.model.set_owner_title(str(pane.get("automatic_title", "")))
		var app: Dictionary = pane.get("app", {})
		var holds: Array = pane.get("effect_holds", [])
		if pair.model.foreground_app != app or pair.model.effect_holds != holds: context_changed = true
		pair.model.foreground_app = app
		pair.model.effect_holds = holds
		if filetree_changed and host.workspace_view.panes.has("%%%d" % id):
			host.workspace_view.panes["%%%d" % id].refresh()
	# The app in the focused pane decides which rules and effect holds apply,
	# exactly as after a full refresh.
	if context_changed: host.refresh_app_context()
	for chromium in connection.topology.get("chromiums", []):
		var id := int(chromium.id)
		if id not in ids or not host.chromiums.has(id): continue
		var surface: Node = host.chromiums[id]
		if is_instance_valid(surface) and chromium.has("state"):
			surface.apply_state(chromium.state)
	# A named tab's new name is a delta as well; only naming it is structural.
	var renamed := false
	for tab in connection.topology.get("tabs", []):
		var group: Dictionary = host.workspace_layout.tab(int(tab.id))
		if group.is_empty() or not tab.get("pinned", false) or str(group.get("title", "")) == str(tab.title): continue
		group.title = str(tab.title)
		renamed = true
	if renamed: host.ui_changed.emit()


static func terminal_definitions(state: Dictionary) -> Array[Dictionary]:
	var definitions: Array[Dictionary] = []
	for pane in state.panes:
		definitions.append({"id": int(pane.id), "label": str(pane.title)})
	return definitions


func _install_layout(state: Dictionary, preserve: bool) -> void:
	var authoritative: bool = state.get("authoritative_layout", false)
	var snapshot: Dictionary = state.get("workspace_state", {})
	var active: int = host.workspace_layout.active
	var previous_order: Array = host.workspace_layout.tabs.map(func(tab): return int(tab.id))
	var focused: String = host.pane_focus
	var close_origin: Dictionary = { }
	var remaining: Array = state.panes.map(
		func(p):
			return "%%%d" % int(p.id),
	)
	if preserve and host.is_terminal_pane(focused) and focused not in remaining:
		close_origin = host._pane_close_origin(focused)
	# Capture the departing tab while its surfaces and native textures still exist.
	# Selection uses the previous visible order, exactly like the final layout.
	var surviving: Array = state.tabs.map(func(tab): return int(tab.id))
	if preserve and active not in surviving and not surviving.is_empty():
		var destination := Layout.surviving_active(previous_order, active, surviving)
		if not host.workspace_layout.tab(destination).is_empty():
			host.select_workspace(destination)
	var definitions := terminal_definitions(state)
	host.layout_transaction = true
	var ids: Array = state.panes.map(
		func(p):
			return int(p.id),
	)
	for id in host.sessions.keys():
		if id not in ids:
			host._remove_session_mirror(id)
	var previous := { }
	var mirrors := {}
	if preserve:
		for tab in host.workspace_layout.tabs:
			previous[int(tab.id)] = tab.duplicate(true)
			mirrors[int(tab.id)] = tab
		# Allocate one world destination for each new tab.
		#
		# Additional panes stay on their tab's surface; treating every new session
		# as a pane made tabs beyond the world's authored places keep copying the
		# last active wall.
		var new_tabs := {}
		var tab_ordinals := {}
		var tab_order: Array = snapshot.get("order", state.tabs.map(func(tab): return int(tab.id)))
		tab_order = tab_order.map(func(id): return int(id))
		for pane in state.panes:
			var tab_id := int(pane.tab)
			if not previous.has(tab_id) and not new_tabs.has(tab_id):
				new_tabs[tab_id] = true
				tab_ordinals[int(pane.id)] = tab_order.find(tab_id)
		for id in ids:
			if host.world._surface_for_session(id) < 0:
				host.world.add_terminal_window(id, int(tab_ordinals.get(id, -1)))
	host.set_tabs(definitions)
	host.workspace_layout.tabs.clear()
	var ordered: Array = state.tabs.duplicate()
	if authoritative:
		# JSON numbers are floats; Array.find uses type-sensitive comparisons.
		# Missing every ID here gave the sort equal ranks and shuffled the tabs.
		var order: Array = snapshot.get("order", []).map(func(id): return int(id))
		ordered.sort_custom(func(a, b): return order.find(int(a.id)) < order.find(int(b.id)))
	elif preserve:
		var order: Array = previous.keys()
		ordered.sort_custom(func(a,b):
			var ai := order.find(int(a.id))
			var bi := order.find(int(b.id))
			return (ai if ai >= 0 else order.size()) < (bi if bi >= 0 else order.size()))
	for tab in ordered:
		var canonical: Dictionary = tab.get("canonical_layout", snapshot.get("layout", {}).get("tabs", {}).get(str(int(tab.id)), {}))
		canonical = host.session_backend.presentation_layout(int(tab.id), canonical)
		var layout: Dictionary = preload("res://scenes/session/ServerWorkspace.gd").decode_tab(int(tab.id), canonical)
		layout.id = int(tab.id)
		layout.title = str(tab.title) if tab.get("pinned", false) else ""
		# Pane geometry is shared; each client's camera belongs to that client.
		layout.erase("navigation")
		if view_state != null and not previous.has(int(tab.id)):
			var transport: Node = connection.owners.get(int(tab.id)) if federated else connection
			if transport != null: view_state.restore_tab(transport, layout)
		if preserve and previous.has(int(tab.id)) and previous[int(tab.id)].has("navigation"):
			layout.navigation = previous[int(tab.id)].navigation
		var tools: Node = host.workspace_view.agent_links.tools if is_instance_valid(host.workspace_view) else null
		var editing_graph: bool = tools != null and tools.tab_id == int(tab.id) and not tools.before.is_empty()
		if preserve and editing_graph and previous.has(int(tab.id)) and previous[int(tab.id)].has("graph_visual"):
			layout.graph_visual = previous[int(tab.id)].graph_visual
		if preserve and previous.has(int(tab.id)) and not host.application.checkpoints.importing:
			var local_focus: String = str(previous[int(tab.id)].get("focused", ""))
			if local_focus in Layout.keys(layout.tree, true): layout.focused = local_focus
			# Geometry is committed on release. An unrelated topology update
			# during a held drag must not move the pane out from under the hand.
			for key in host.workspace_view.panes:
				var pane: Control = host.workspace_view.panes[key]
				if not (pane._dragging or pane._resizing): continue
				var retained := Layout.find(previous[int(tab.id)].tree, key)
				var incoming := Layout.find(layout.tree, key)
				if retained.is_empty() or incoming.is_empty(): continue
				incoming.rect = retained.rect
				if pane._dragging: layout.tree.physics_anchor = key
		if preserve and not authoritative and Layout.keys(layout.tree).has(focused):
			layout.focused = focused
		if mirrors.has(int(tab.id)):
			var mirror: Dictionary = mirrors[int(tab.id)]
			mirror.clear()
			mirror.merge(layout)
			layout = mirror
		host.workspace_layout.tabs.append(layout)
		host.application.next_id = maxi(host.application.next_id, int(tab.id) + 1)
	if authoritative:
		host.application.tiling_default = bool(snapshot.layout.default_enabled)
		if not preserve: active = int(snapshot.get("active", active))
	host.workspace_layout.active = Layout.surviving_active(
		previous_order, active, host.workspace_layout.tabs.map(func(tab): return int(tab.id)),
	)
	# Reusing the host keeps its mirrors/world alive, but a session switch must
	# restore that session's selection rather than fall back from the old ID to
	# the first surviving tab.
	#
	# Ordinary topology updates retain current focus.
	if (not preserve or host.session_switch_in_progress) and view_state != null:
		var transport: Node = connection.selected if federated else connection
		if transport != null:
			var remembered: int = view_state.active_tab(transport)
			if not host.workspace_layout.tab(remembered).is_empty(): host.workspace_layout.active = remembered
	host.layout_transaction = false
	if preserve:
		var wanted: String = str(host.workspace_layout.tab(host.workspace_layout.active).get("focused", ""))
		if host.pane_focus != wanted:
			host.select_workspace(host.workspace_layout.active, true)
		else:
			host._refresh_workspace_layout()
		host.workspace_view.animate_shared_move(previous.get(host.workspace_layout.active, {}))
		pending_close_origin = close_origin


func _subscribe() -> void:
	if host == null:
		return
	var ids: Array = []
	var tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	for key in (Layout.keys(tab.get("tree", { })) if not stream_background and host.presentation_active else []):
		if preload("res://scenes/PaneTargets.gd").valid(key):
			ids.append(int(key.substr(1)))
	if not stream_background and host.presentation_active:
		for id in host.sessions:
			if id not in ids and int(host.sessions[id].vp.get_meta("terminal_live_users", 0)) > 0:
				ids.append(id)
	if connection.subscriptions != ids:
		for id in ids:
			if id not in connection.subscriptions and host.sessions.has(id):
				host.sessions[id].term.remote_expect_scene()
		connection.subscribe(ids)
	for id in ids: _sync_terminal_theme(int(id))


func _resources(id: int, data: Dictionary, interval: float) -> void:
	var monitor: Node = host.resource_monitor_for(id) if is_instance_valid(host) else null
	if monitor != null:
		monitor.apply_remote(data, interval)
		pending_resources.erase(id)
	elif data.get("status") == "disconnected":
		pending_resources.erase(id)
	else:
		pending_resources[id] = {"data": data.duplicate(true), "interval": interval, "received": Time.get_ticks_msec()}


func _flush_resource_samples() -> void:
	if not is_instance_valid(host) or pending_resources.is_empty(): return
	var ids: Array = connection.topology.get("panes", []).map(func(pane): return int(pane.id))
	for id in pending_resources.keys():
		if id not in ids:
			pending_resources.erase(id)
			continue
		if host.resource_monitor_for(id) == null: continue
		var pending: Dictionary = pending_resources[id]
		var data: Dictionary = pending.data
		if float(data.get("sample_age_seconds", -1.0)) >= 0.0:
			data.sample_age_seconds += (Time.get_ticks_msec() - int(pending.received)) / 1000.0
		_resources(id, data, pending.interval)


func _frame(id: int, frame: Dictionary, _data: PackedByteArray) -> void:
	if host == null or not host.sessions.has(id) or id not in connection.subscriptions:
		return
	var terminal: Node = host.sessions[id].term
	if frame.has("asset_texture"):
		terminal.remote_set_asset_texture(str(frame.asset), frame.asset_texture, int(frame.width), int(frame.height))
	elif frame.has("native"):
		terminal.remote_apply_scene(frame.native)


## Sample the projected content, including edge midpoints on curved sheets.
## Viewport stretch belongs here; CSS layout and input coordinates stay unchanged.
## Zero means the pane is outside the workspace view.
static func chromium_display_height(view: Control, content: Control) -> float:
	return chromium_display_size(view, content).y


## Projected width and height in physical pixels; zero outside the view.
static func chromium_display_size(view: Control, content: Control) -> Vector2:
	var bounds := Rect2()
	var first := true
	var screen := view.get_viewport().get_screen_transform() * view.get_global_transform_with_canvas()
	for x in 3:
		for y in 3:
			var local: Vector2 = view.view_point(content.get_global_transform() * (content.size * Vector2(x * 0.5, y * 0.5)))
			var point := screen * local
			if not point.is_finite(): continue
			bounds = Rect2(point, Vector2.ZERO) if first else bounds.expand(point)
			first = false
	return bounds.size if visible_height(bounds, screen * Rect2(Vector2.ZERO, view.size)) > 0.0 else Vector2.ZERO


## The extent that decides readability: the page's smaller side, in density-
## independent pixels.
##
## A tall sliver is as unreadable as a short strip, and 96 physical pixels on
## a 3x phone are only 32 on a desktop display.
static func chromium_readable_extent(size: Vector2, density: float) -> float:
	return minf(size.x, size.y) / maxf(density, 1.0)


## A paused pane keeps its last picture, so a visible pane that has none yet
## streams until its first frame arrives, however small it is.
static func chromium_pause_extent(extent: float, frames: int) -> float:
	return maxf(extent, RESUME_HEIGHT) if frames == 0 and extent > 0.0 else extent


## Projected height, or zero when the projection misses the visible view.
static func visible_height(bounds: Rect2, visible: Rect2) -> float:
	return bounds.size.y if bounds.intersects(visible, true) else 0.0


## Readable extents (chromium_readable_extent) below this pause the pane.
const PAUSE_HEIGHT := 96.0
## A paused pane resumes only above this, so a pane near the threshold does
## not alternate between keyframe restarts and pauses while the camera moves.
const RESUME_HEIGHT := 128.0


## Pause off-screen and tiny panes. A newly reported pane pauses at once; a
## displayed one only after a stable half second, so a passing camera move
## does not restart its stream.
##
## Panes resume as soon as they are readable.
static func chromium_stream_paused(state: Dictionary, height: float, now: int) -> bool:
	if not state.has("paused"):
		state.paused = height < PAUSE_HEIGHT
	elif state.paused:
		state.paused = height < RESUME_HEIGHT
	elif height >= PAUSE_HEIGHT:
		state.erase("pause_since")
	elif not state.has("pause_since"):
		state.pause_since = now
	elif now - int(state.pause_since) >= 500:
		state.paused = true
	if state.paused: state.erase("pause_since")
	return state.paused


## Each pane settles independently. Restore detail immediately when magnified;
## shrink only after a stable half second, with margin against boundary jitter.
static func chromium_stream_height(state: Dictionary, height: float, now: int) -> int:
	var target := 2160
	for candidate in [144, 240, 360, 540, 720, 1080, 1440, 2160]:
		if height <= candidate:
			target = candidate
			break
	var current := int(state.get("height", 0))
	if current == 0 or target > current:
		state.height = target
		state.erase("candidate")
	elif target == current or height > target * 0.9:
		state.erase("candidate")
	elif int(state.get("candidate", 0)) != target:
		state.candidate = target
		state.since = now
	elif now - int(state.since) >= 500:
		state.height = target
		state.erase("candidate")
	return int(state.height)


func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("RemoteClient", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	if host == null:
		return
	if Time.get_ticks_msec() >= stream_update_at:
		stream_update_at = Time.get_ticks_msec() + 250
		_subscribe()
		var sizes := {}
		var now := Time.get_ticks_msec()
		for id in connection.subscriptions:
			if not host.chromiums.has(id): continue
			var pane: Control = host.workspace_view.panes.get("%%%d" % id)
			if pane == null or pane.texture == null: continue
			# A pane hidden within the active tab keeps stale geometry.
			var size := chromium_display_size(host.workspace_view, pane.texture) if pane.is_visible_in_tree() else Vector2.ZERO
			var height := size.y
			if not size.is_finite(): continue
			if not stream_sizes.has(id): stream_sizes[id] = {}
			# The owner renders each page for its largest displayed viewer.
			# Off-screen and unreadably small panes stay subscribed but pause:
			# height zero stops their frames, and they keep the last picture.
			var chromium: Node = host.chromiums[id]
			var extent := chromium_pause_extent(chromium_readable_extent(size, host.get_window().content_scale_factor), int(chromium.frames))
			var paused := chromium_stream_paused(stream_sizes[id], extent, now)
			sizes[id] = 0 if paused else chromium_stream_height(stream_sizes[id], height, now)
			if chromium.stream_paused != paused:
				chromium.stream_paused = paused
				chromium.changed.emit()
		for id in stream_sizes.keys():
			if not sizes.has(id): stream_sizes.erase(id)
		connection.set_chromium_viewports(sizes)
	for id in connection.subscriptions:
		if not host.sessions.has(id): continue
		var terminal: Node = host.sessions[id].term
		# Inactive panes retain their last scene, but asset requests are scoped to
		# the current subscription.
		#
		# A late scene after a tab switch must not request old assets and cause the
		# owner to reject the connection.
		if connection.connected and id in connection.subscriptions:
			for asset in terminal.remote_take_asset_requests():
				connection.send_action("terminal_asset_request", id, {"asset": asset})


func _bind_terminal_input(id: int) -> void:
	var terminal: Node = host.sessions[id].term
	var flush := _flush_terminal_input.bind(id)
	# A tab moved back from another window is still bound here.
	if not terminal.input_ready.is_connected(flush): terminal.input_ready.connect(flush)
	var sync_theme := _sync_terminal_theme.bind(id)
	if not terminal.colors_changed.is_connected(sync_theme):
		terminal.colors_changed.connect(sync_theme, CONNECT_DEFERRED)
	_sync_terminal_theme(id)


func _sync_terminal_theme(id: int) -> void:
	if not is_instance_valid(host) or not host.sessions.has(id): return
	connection.set_terminal_theme(id, host.sessions[id].term.remote_theme())


func _flush_terminal_input(id: int) -> void:
	if not is_instance_valid(host) or not host.sessions.has(id): return
	var input: PackedByteArray = host.sessions[id].term.remote_take_input()
	var attachment: Dictionary = host.sessions[id].term.remote_take_attachment()
	# Disconnected input is discarded, including input behind an IME boundary.
	if not connection.connected: host.sessions[id].term.remote_discard_input()
	if connection.connected and not input.is_empty():
		_sync_terminal_theme(id)
		connection.send_input(id, input)
	if not attachment.is_empty(): _paste_attachment(id, host.sessions[id].term, attachment)


func _paste_attachment(id: int, terminal: Node, attachment: Dictionary) -> void:
	var failure: String = attachment.get("error", "")
	var transport: Node = connection.owners.get(id) if federated else connection
	if not is_instance_valid(transport):
		terminal.file_paste_finished(false)
		return
	var peer = transport.socket
	var workspace: String = transport.workspace
	var upload := TerminalFileUpload.new()
	if failure.is_empty(): failure = upload.start(str(attachment.name), attachment.data)
	while failure.is_empty():
		if not is_instance_valid(transport) or not transport.connected or transport.socket != peer or transport.workspace != workspace or not is_instance_valid(terminal) or not is_instance_valid(host) or not host.sessions.has(id) or host.sessions[id].term != terminal or (federated and connection.owners.get(id) != transport):
			failure = "Attachment destination disconnected or changed"
			break
		var params: Dictionary = upload.next_chunk()
		if params.is_empty(): break
		var reply: Dictionary = await transport.request_action("rpc", {"session": id, "method": "terminal.put", "params": params}, 30000)
		var result: Dictionary = upload.accept(reply)
		failure = result.get("error", "")
		if result.get("done", false): break
	if is_instance_valid(terminal): terminal.file_paste_finished(failure.is_empty())
	if not failure.is_empty():
		get_node("/root/TerminalApplication").notifications.post(tr("Paste"), tr("Could not paste image"), host, "error", 8.0, "", {"title": "Paste", "body": "Could not paste image"})
		push_warning(failure)


func _release_host() -> void:
	if is_instance_valid(host):
		settings.startup_world = host.current_plugin
		for chromium in host.chromiums.values(): chromium.release_rendering()
		host.world.set_video_layers([])
		host.free()
	host = null
	host_bound = false
	workspace_signature = ""


## Whether any server presented in this window is reachable.
func _window_connected() -> bool:
	for tab in host.get_tabs():
		var transport: Node = connection.owners.get(int(tab.id)) if federated else connection
		if transport != null and transport.connected: return true
	return false


func request_close_window() -> void:
	_save_view()
	if closing_window: return
	if not is_instance_valid(host):
		detach()
		return
	# An offline owner cannot be stopped, but must not trap this window.
	if not _window_connected():
		detach()
		return
	if host.close_dialog != null: return
	# Another window stays open, so this close cannot end anything and there
	# is no server to offer stopping: detach without asking.
	if _other_windows_open():
		detach()
		return
	# Closing a window never ends its sessions: Detach keeps them running.
	# Only a local window may stop its whole server.
	var prompt := ConfirmationDialog.new()
	host.close_dialog = prompt
	prompt.dialog_autowrap = true
	prompt.title = "Close window?"
	prompt.dialog_text = "Detach keeps the session running for later."
	prompt.ok_button_text = "Detach"
	var server_button: Button
	if _can_close_local_server():
		prompt.dialog_text = "Detach keeps every session running for later. Kill Server ends every session on this computer, including detached sessions."
		server_button = prompt.add_button("Kill Server", false, "close_server")
	host.add_child(prompt)
	preload("res://scenes/DialogActionStyle.gd").apply(prompt.get_ok_button(), Color("287346"))
	if server_button != null:
		server_button.icon = preload("res://scenes/PaneIcons.gd").trash()
		preload("res://scenes/DialogActionStyle.gd").apply(server_button, preload("res://scenes/UIAccent.gd").DANGER)
	prompt.confirmed.connect(detach.call_deferred)
	prompt.custom_action.connect(func(action):
		if action == "close_server" and _can_close_local_server():
			prompt.hide()
			_close_local_server.call_deferred())
	prompt.visibility_changed.connect(_close_prompt_hidden.bind(prompt))
	preload("res://scenes/DialogActionLayout.gd").popup_centered(prompt,
		Vector2i(640 if server_button != null else 420, 180 if server_button != null else 140))
	prompt.get_cancel_button().grab_focus()


func _other_windows_open() -> bool:
	var application: Node = get_node_or_null("/root/TerminalApplication")
	return application != null and application.hosts.any(func(other: Node) -> bool:
		return other != host and is_instance_valid(other) and not other.is_queued_for_deletion())


func _close_prompt_hidden(prompt: ConfirmationDialog) -> void:
	if not is_instance_valid(prompt) or prompt.visible: return
	if is_instance_valid(host) and host.close_dialog == prompt: host.close_dialog = null
	prompt.queue_free()


func _can_close_local_server() -> bool:
	return not federated and settings.get("shared_local", false) and connection.connected and connection.url == "shared://local"


func _close_local_server() -> void:
	# Recheck the transport at activation time; no remote server gets this action.
	if closing_window or not _can_close_local_server(): return
	closing_window = true
	var result: Dictionary = await connection.request_action("close_server")
	if result.get("type") == "error" and result.get("code") != "owner_unavailable":
		closing_window = false
		var failure := AcceptDialog.new()
		failure.title = "Could not kill server"
		failure.dialog_text = str(result.get("message", "The session owner did not respond."))
		add_child(failure)
		failure.confirmed.connect(failure.queue_free)
		failure.canceled.connect(failure.queue_free)
		failure.popup_centered()
		return
	detach()


func detach() -> void:
	if local_return != null and local_return.parked and is_instance_valid(local_return.client):
		var window := get_window()
		connection.disconnect_remote()
		_release_host()
		if window.close_requested.is_connected(request_close_window): window.close_requested.disconnect(request_close_window)
		local_return.restore(window)
		queue_free()
		return
	connection.disconnect_remote()
	_release_host()
	closing_window = false
	detached.emit()
	if not managed:
		get_tree().quit()


func _exit_tree() -> void:
	# Promoting a surviving window reparents this same live client. Keep its
	# transport and signals connected while the host changes native windows.
	if moving_presentation or (is_instance_valid(host) and host.moving_window): return
	connection.set_block_signals(true)
	connection.disconnect_remote()
	# Startup validation can exit before _ready attaches these owned nodes.
	for node in [connection, dialog, endpoint, secret, status, remember]:
		if is_instance_valid(node) and node.get_parent() == null: node.free()


func _input_activity(id: int, keys: Array) -> void:
	# Observational effects only. The owner has already written these keys;
	# never inject them back into a viewport or change the user's focus.
	if host == null or not host.presentation_active or not host.sessions.has(id) or host.active_session_id != id:
		return
	if not preload("res://scenes/TerminalViewportUpdates.gd").is_active(host.sessions[id].vp):
		return
	var terminal: Control = host.sessions[id].term
	for key in keys:
		var cell: Array = key.get("cell", [0, 0])
		terminal.keystroke.emit(Vector2i(int(cell[0]), int(cell[1])), int(key.get("unicode", 0)))


func _remote_notification(id: int, event: Dictionary) -> void:
	if host == null or not host.sessions.has(id):
		return
	var terminal: Control = host.sessions[id].term
	if event.get("bell", false):
		# A BEL carries no notification text. Use the terminal's configured
		# sound/flash/attention behavior, not a blank desktop banner.
		terminal.remote_bell()
		return
	var notifications: Node = host.application.system_notifications
	if event.has("binding"):
		var binding: Dictionary = event.binding
		notifications.bind_notification(
			id,
			str(binding.notification_id),
			binding.event,
			str(binding.focus_target),
		)

	elif event.has("packet"):
		notifications.command(terminal, str(event.packet))
	else:
		notifications.notify(
			terminal,
			str(event.get("title", "Graffitty")),
			str(event.get("body", "")),
		)


func _remote_clipboard(id: int, event: Dictionary) -> void:
	if host == null or not host.sessions.has(id): return
	clipboard_generations[id] = int(event.generation)
	var terminal: Control = host.sessions[id].term
	if event.type == "clipboard_reset":
		terminal.remote_clipboard_reset(int(event.generation))
		return
	var reply := _clipboard_reply.bind(id)
	if not terminal.clipboard_reply_ready.is_connected(reply):
		terminal.clipboard_reply_ready.connect(reply)
	var result: Dictionary = terminal.remote_clipboard(int(event.generation), int(event.ticket), JSON.stringify(event.operation))
	if not result.get("pending", false):
		_clipboard_reply(int(event.generation), int(event.ticket), result.get("data", PackedByteArray()), id)


func _clipboard_reply(generation: int, ticket: int, data: PackedByteArray, id: int) -> void:
	if clipboard_generations.get(id, -1) != generation: return
	if clipboard_reply_bytes + data.size() > 128 * 1024 * 1024:
		data = "\u001b]5522;type=read:status=EBUSY\u001b\\".to_utf8_buffer()
	clipboard_replies.append({"generation": generation, "ticket": ticket, "data": data, "id": id})
	clipboard_reply_bytes += data.size()
	if not clipboard_reply_busy: _flush_clipboard_replies()


func _flush_clipboard_replies() -> void:
	clipboard_reply_busy = true
	while not clipboard_replies.is_empty():
		var reply: Dictionary = clipboard_replies.pop_front()
		var data: PackedByteArray = reply.data
		var offset := 0
		while clipboard_generations.get(reply.id, -1) == reply.generation and is_instance_valid(host) and host.sessions.has(reply.id):
			var end := mini(offset + 48 * 1024, data.size())
			var encoded := "" if end == offset else Marshalls.raw_to_base64(data.slice(offset, end))
			if connection.send_action("clipboard_reply", reply.id, {"generation": reply.generation, "ticket": reply.ticket, "offset": offset, "done": end == data.size(), "data": encoded}) < 0: break
			if end == data.size(): break
			offset = end
			await get_tree().process_frame
		clipboard_reply_bytes -= data.size()
	clipboard_reply_busy = false

func _chromium_frame(id: int, header: Dictionary, bytes: PackedByteArray) -> void:
	if host != null and id in connection.subscriptions and host.chromiums.has(id):
		host.chromiums[id].apply_video_frame(header, bytes)

func _save_view() -> void:
	if federated or settings.get("shared_local", false) or not is_instance_valid(host): return
	if is_instance_valid(host.workspace_view) and host.workspace_view.navigation_in_progress():
		view_save_timer.start()
		return
	view_state.capture(host, [connection])


func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("RemoteClient._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_save_view()
		stream_background = true
		_release_video_decoders()
		if is_instance_valid(host): _subscribe()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		stream_background = false
		# Also on resume: a pause notification can be missed, and the
		# resubscribe below is what restarts every stream at a keyframe.
		_release_video_decoders()
		if is_instance_valid(host): _subscribe()


## Hardware decode sessions do not reliably survive suspension.
func _release_video_decoders() -> void:
	if not is_instance_valid(host): return
	for chromium in host.chromiums.values():
		if is_instance_valid(chromium): chromium.release_video_decoder()
