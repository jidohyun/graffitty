extends Node
## Application windows present sessions owned by the common server.
## Hosts own window presentation and reference their assigned live sessions.
const DesktopText := preload("res://scenes/DesktopText.gd")
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
const NativeFrame := preload("res://scenes/NativeWindowFrame.gd")
var hosts: Array[Node] = []
var pane_icon_cache: Dictionary = {}
var window_decorations := "client"
var max_fps := 120
var inactive_max_fps := 30
var ui_scale: Variant = "auto"
## Whether any Graffitty window has focus, including its native dialogs.
## A focused dialog leaves every workspace window unfocused, yet the user is
## working in the app: frames stay at max_fps, not the background cap.
var application_focused := true
## Session default; existing spaces retain their own tiling choice.
var tiling_default := true
var recent_font_size := 0
var _recent_font_loaded := false
## Whether this device's windows fit the shared main view to themselves when
## used last ("Fit to This Window") or letterbox the server's ("Follow Server").
var fit_main_view := true
## Device-local terminal touch behavior; one finger scrolls by default.
var terminal_touch_scroll_fingers := 1

var owners: Dictionary = { }
var mounted_packs: Dictionary[String, bool] = { }
var next_id := 1
## First effective spawn directory, shared by every window for this launch.
var initial_directory := ""
## Explicit preferences for future local PTYs, shared by this app's windows.
var local_spawn_defaults: Dictionary = {}
var remote_identity_maps: Dictionary = {}

var show_servers_at_startup := false
var _servers_startup_shown := false
var desktop_presentations: Array[RefCounted] = []

func desktop_presentation(client: Node) -> RefCounted:
	desktop_presentations = desktop_presentations.filter(func(view): return is_instance_valid(view.client))
	for view in desktop_presentations:
		if view.client == client: return view
	var view := preload("res://scenes/remote/DesktopPresentation.gd").new()
	view.client = client
	desktop_presentations.append(view)
	return view

func session_hosts() -> Array:
	var result: Array = hosts.duplicate()
	for view in desktop_presentations:
		if is_instance_valid(view.client) and is_instance_valid(view.client.host) and view.client.host not in result:
			result.append(view.client.host)
	return result

func present_desktop_client(client: Node) -> void:
	var view := desktop_presentation(client)
	if view.parked:
		var target: Window = view.window
		if not is_instance_valid(target): target = get_tree().root
		for candidate in get_tree().get_nodes_in_group("shared_presentations"):
			if candidate == client or candidate.get_window() != target: continue
			var other := desktop_presentation(candidate)
			if not other.parked and (is_instance_valid(candidate.host) or candidate.connection.connected):
				other.park(candidate)
		view.restore(target)
	var window: Window = client.get_window()
	var servers := window.get_node_or_null("Servers")
	if servers != null: servers.bind_client(client)
	window.show()
	window.grab_focus()
	if mods != null: mods.queue_refresh()

func servers_window(source: Node) -> Node:
	var window: Window = source.get_window()
	var manager := window.get_node_or_null("Servers")
	if manager == null:
		manager = load("res://scenes/remote/DesktopServers.gd").new()
		manager.name = "Servers"
		manager.application = self
		window.add_child(manager)
	return manager

func show_servers(source: Node) -> Node:
	var manager := servers_window(source)
	manager.present(source)
	return manager

## Connect a saved server without showing the Servers window.
func connect_server(source: Node, url: String) -> void:
	servers_window(source).connect_server(source, url)

func desktop_client_ready(client: Node) -> void:
	if not opens_windows() or client.federated: return
	if not _servers_startup_shown and client.settings.get("shared_local", false):
		_servers_startup_shown = true
		_open_startup_servers.call_deferred(client)

func _open_startup_servers(local: Node) -> void:
	# Remote launch arguments add servers to the ordinary desktop application.
	# Attach local first so its live sessions remain available in Sessions.
	var connections := preload("res://scenes/remote/ClientAuthentication.gd").launch_connections(OS.get_cmdline_user_args())
	if connections.is_empty():
		if show_servers_at_startup: show_servers(local)
		return
	var source := local
	for settings in connections:
		# Each connection becomes available in Sessions; keep one normal window.
		# An empty server is still a complete connection and can be parked.
		source = open_remote_server(source, settings)
		while is_instance_valid(source) and source.connection.enabled and not source.connection.connected:
			await get_tree().process_frame

func open_remote_server(source: Node, settings: Dictionary, in_new_window := false) -> Node:
	var window: Window = source.get_window()
	var context: RefCounted
	if source.settings.get("shared_local", false): context = desktop_presentation(source)
	else: context = source.local_return
	if in_new_window:
		context = null
		var target := Window.new()
		target.title = "Graffitty"
		target.size = window.size
		target.min_size = Vector2i(480, 300)
		target.position = window.position + Vector2i(40, 40)
		configure_workspace_frame(target)
		add_child(target)
		configure_window_scale(target)
		window = target
	elif is_instance_valid(source.host) or source.connection.connected:
		desktop_presentation(source).park(source)
	else:
		# A failed/unsubmitted login has no presentation to retain.
		source.connection.disconnect_remote()
		if window.close_requested.is_connected(source.request_close_window): window.close_requested.disconnect(source.request_close_window)
		source.queue_free()
	var client: Node = load("res://scenes/remote/RemoteClient.gd").new()
	client.managed = true
	client.local_return = context
	client.settings = settings.duplicate(true)
	client.server_chooser = func(): show_servers(client)
	client.detached.connect(_close_shared_presentation.bind(client, window))
	window.add_child(client)
	window.show()
	window.grab_focus()
	if in_new_window:
		var manager := show_servers(client)
		manager.open_when_ready = true
	return client

func set_show_servers_at_startup(enabled: bool) -> void:
	show_servers_at_startup = enabled
	_save_presentation()

var checkpoints: Node
var agent_api: Node
var agent_attention: Node
var agents: Node
## JavaScript mods: live data out, actions in. See docs/developers/automation-and-extensions/mods.md.
var mods: Node
var system_notifications: Node
var notifications: Node
var _power_monitor: Node
var remote_control: Node
var remote_access_busy := false
var _remote_startup_applied := false
var resource_monitor_service: RefCounted
enum DragMode {
	REORDER,
	FLOATING,
	DOCKED,
	MERGE,
	BLOCKED,
}
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const DETACH_DISTANCE := 48.0
const DOCK_ENTER_MARGIN := 6.0
const DOCK_LEAVE_MARGIN := 28.0
## Holding a drag over another tab this long opens it.
const HOVER_PREVIEW_MS := 500
const DragPreview := preload("res://scenes/TabDragPreview.gd")
var drag: Dictionary = { }
## Scripted input (a replay) moves no OS pointer: drags follow its events.
var scripted_pointer := false
var _hover_deadline: Timer
var _hover_animation: Tween

# Each native/embedded viewport receives its own captured input stream. Keeping
# the source window mapped preserves the OS grab even outside its bounds.
class DragInput extends Node:
	var application: Node
	func _input(event: InputEvent) -> void:
		application._drag_input(event, get_viewport())

var drag_preview: Window
var _closing := false
var responsive_dialogs: Node


func _ready() -> void:
	# Cache the app and CLI paths now, before an upgrade can rename the files.
	preload("res://graffitty/executables.gd").app()
	preload("res://graffitty/executables.gd").cli()
	DesktopText.install()
	preload("res://scenes/UIAccent.gd").install()
	# Windows and Wayland report a touchpad's scroll phases only to a native
	# listener, which terminals need for their rubber band.
	if ClassDB.class_exists(&"TouchpadPhases"):
		var phases: Node = ClassDB.instantiate(&"TouchpadPhases")
		phases.name = "TouchpadPhases"
		add_child(phases)
	if "--reload" in OS.get_cmdline_user_args() and OS.has_feature("debug"):
		var watcher := preload("res://scenes/DevScriptReload.gd").new()
		watcher.name = "DevScriptReload"
		add_child(watcher)
	var settings = preload("res://config/UserConfig.gd").window_config(OS.get_cmdline_user_args())
	window_decorations = settings.decorations
	configure_workspace_frame(get_tree().root)
	max_fps = settings.max_fps
	inactive_max_fps = settings.inactive_max_fps
	if not (OS.has_feature("android") or OS.has_feature("ios")): ui_scale = settings.ui_scale
	fit_main_view = _load_fit_main_view()
	var preferences := ConfigFile.new()
	if preferences.load(presentation_path()) == OK:
		show_servers_at_startup = preferences.get_value("servers", "show_at_startup", false) == true
	terminal_touch_scroll_fingers = _load_terminal_touch_scroll_fingers()
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		responsive_dialogs = preload("res://scenes/input/ResponsiveDialogs.gd").new()
		add_child(responsive_dialogs)
	get_tree().node_added.connect(_configure_dialog)
	# Godot returns major.minor.build from RtlGetVersion. Corner preferences start at 22000.
	if DisplayServer.get_name() == "Windows" and OS.get_version().get_slice(".", 2).to_int() >= 22000:
		NativeFrame.watch_corners(get_tree().root)
		get_tree().node_added.connect(NativeFrame.watch_corners)
	if DisplayServer.get_name() in ["Windows", "Wayland", "X11"] or ui_scale is not String:
		configure_window_scale(get_tree().root)
		get_tree().node_added.connect(_watch_window_scale)
	preload("res://scenes/RecordScript.gd").attach.call_deferred(get_tree())
	if OS.has_feature("android"):
		_finish_android_launch.call_deferred()


func _finish_android_launch() -> void:
	await RenderingServer.frame_post_draw
	Engine.get_singleton("JavaClassWrapper").wrap("com.graffitty.launch.GraffittyApplication").finishLaunch()


func _exit_tree() -> void:
	# Cached DPI textures must be released while the renderer still exists.
	pane_icon_cache.clear()


func _configure_dialog(node: Node) -> void:
	if node is PopupMenu:
		if OS.get_name() == "macOS" and (node.get_parent() is LineEdit or node.get_parent() is TextEdit):
			# AppKit places the editing menu on the pointer's display and draws shortcut symbols.
			node.prefer_native_menu = true
		# One shared style for main menus, title/link/browser context menus and
		# dynamically created submenus. macOS can still render native menus.
		var menu: WeakRef = weakref(node)
		(func():
			var target: Object = menu.get_ref()
			if is_instance_valid(target): preload("res://scenes/PopupChrome.gd").apply(target)
		).call_deferred()
		return
	if not node is AcceptDialog:
		return
	var dialog := node as AcceptDialog
	var dialog_theme: Theme = dialog.theme.duplicate() if dialog.theme != null else Theme.new()
	dialog_theme.default_font_size = DesktopText.size(20)
	for kind in ["Label", "LineEdit", "TextEdit", "Button", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree"]:
		dialog_theme.set_font_size("font_size", kind, DesktopText.size(20))
	for kind in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
		dialog_theme.set_font_size(kind, "RichTextLabel", DesktopText.size(20))
	preload("res://scenes/DialogTheme.gd").apply(dialog_theme)
	dialog.theme = dialog_theme
	dialog.transparent_bg = true
	if responsive_dialogs != null: responsive_dialogs.watch(dialog)
	_prepare_dialog(dialog)
	var prepare := _prepare_dialog.bind(dialog)
	if not dialog.about_to_popup.is_connected(prepare):
		dialog.about_to_popup.connect(prepare)


func _prepare_dialog(dialog: AcceptDialog) -> void:
	# A new native dialog opens on its owner's display. Embedded dialogs already
	# inherit that display's transform and must not apply the DPI factor twice.
	if not dialog.is_embedded():
		dialog.current_screen = preload("res://scenes/WindowScale.gd").native_owner(dialog).current_screen
		configure_window_scale(dialog)
	elif not OS.has_feature("movie"):
		dialog.content_scale_factor = 1.0
	# Apply at popup time too, after callers have added actions such as Detach.
	preload("res://scenes/DialogActionLayout.gd").apply(dialog)


func power_monitor() -> Node:
	if _power_monitor == null:
		_power_monitor = preload("res://scenes/PowerMonitor.gd").new()
		add_child(_power_monitor)
	return _power_monitor


func recent_font_path() -> String:
	return preload("res://graffitty/paths.gd").stdpath("state").path_join("recent.conf")

func new_pane_font_size(configured: int) -> int:
	if not _recent_font_loaded:
		_recent_font_loaded = true
		var recent := ConfigFile.new()
		if recent.load(recent_font_path()) == OK:
			var value: Variant = recent.get_value("terminal", "font_size", 0)
			if (value is int or value is float) and int(value) >= 1 and int(value) <= 72:
				recent_font_size = int(value)
	return recent_font_size if recent_font_size > 0 else configured

func remember_font_size(value: int) -> void:
	recent_font_size = clampi(value, 1, 72)
	_recent_font_loaded = true
	var recent := ConfigFile.new()
	recent.set_value("terminal", "font_size", recent_font_size)
	var path := recent_font_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if recent.save(path + ".tmp") != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		push_warning("Could not save the recent terminal font size")


func presentation_path() -> String:
	return preload("res://graffitty/paths.gd").stdpath("state").path_join("presentation.conf")


func _load_fit_main_view() -> bool:
	var config := ConfigFile.new()
	if config.load(presentation_path()) != OK:
		return true
	var value: Variant = config.get_value("main_view", "fit_to_window", true)
	return value if value is bool else true


func set_fit_main_view(enabled: bool) -> void:
	fit_main_view = enabled
	_save_presentation()
	for host in hosts:
		if not is_instance_valid(host):
			continue
		if host.session_backend.has_method("set_fit_main_view"):
			host.session_backend.set_fit_main_view(host, enabled)
		host._update_menu()


func _load_terminal_touch_scroll_fingers() -> int:
	var config := ConfigFile.new()
	if config.load(presentation_path()) != OK:
		return 1
	var value: Variant = config.get_value("touch", "terminal_scroll_fingers", 1)
	return value if value is int and value in [1, 3] else 1


func set_terminal_touch_scroll_fingers(count: int) -> void:
	if count not in [1, 3]:
		return
	terminal_touch_scroll_fingers = count
	_save_presentation()
	for host in hosts:
		if is_instance_valid(host):
			host._update_menu()


func _save_presentation() -> void:
	var config := ConfigFile.new()
	config.set_value("main_view", "fit_to_window", fit_main_view)
	config.set_value("servers", "show_at_startup", show_servers_at_startup)
	config.set_value("touch", "terminal_scroll_fingers", terminal_touch_scroll_fingers)
	var path := presentation_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if config.save(path + ".tmp") != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		push_warning("Could not save presentation preferences")


func register_host(host: Node) -> void:
	OS.low_processor_usage_mode = true
	if notifications == null:
		notifications = preload("res://scenes/AppNotifications.gd").new()
		add_child(notifications)
	if hosts.is_empty():
		tiling_default = host.tiling_config.enabled
	if checkpoints == null:
		checkpoints = preload("res://scenes/Checkpoints.gd").new()
		checkpoints.application = self
		add_child(checkpoints)
	if agent_api == null:
		agent_api = preload("res://scenes/AgentAPI.gd").new()
		agent_api.application = self
		add_child(agent_api)
		agents = preload("res://scenes/Agents.gd").new()
		agents.application = self
		add_child(agents)
		agent_attention = preload("res://scenes/AgentAttention.gd").new()
		agent_attention.application = self
		add_child(agent_attention)
		agent_attention.watch_graph(agent_api.graph)
		mods = preload("res://scenes/mods/ModService.gd").new()
		mods.application = self
		add_child(mods)
		system_notifications = preload("res://scenes/SystemNotifications.gd").new()
		system_notifications.application = self
		add_child(system_notifications)
		if ClassDB.class_exists("ResourceMonitorService"):
			resource_monitor_service = ClassDB.instantiate("ResourceMonitorService")
		get_tree().auto_accept_quit = false
		get_tree().root.gui_embed_subwindows = preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	hosts.append(host)
	mods.watch_host(host)
	mods.queue_refresh()
	agent_attention.watch_host(host)
	agent_attention.queue_refresh()
	bind_window(host)
	if not _remote_startup_applied:
		_remote_startup_applied = true
		if _remote_controller().bind(self):
			_sync_remote_access.call_deferred()



func remote_access_enabled() -> bool:
	return is_instance_valid(remote_control) and remote_control.enabled


func _remote_controller() -> Node:
	if not is_instance_valid(remote_control):
		remote_control = preload("res://scenes/remote/RemoteAccessControl.gd").new()
		add_child(remote_control)
		remote_control.bind(self)
	return remote_control


func refresh_remote_access() -> Error:
	return await _remote_controller().refresh()


## The owner may already share by configuration. Until it answers, the menu
## cannot know, so report the state as busy and refresh menus afterward.
func _sync_remote_access() -> void:
	remote_access_busy = true
	await refresh_remote_access()
	remote_access_busy = false
	for host in hosts: host.ui_changed.emit()
	# The server runs, but not the remote access its configuration asks for.
	var reason: String = remote_control.unavailable_text()
	if not reason.is_empty() and not hosts.is_empty():
		notifications.post(tr("Remote access is off"), reason, hosts[0], "warning", 20.0, "remote-access-off",
			{"title": "Remote access is off"})


func set_remote_access(enabled: bool) -> Error:
	if remote_access_busy: return ERR_BUSY
	remote_access_busy = true
	var control := _remote_controller()
	var error: Error
	if enabled:
		var path := preload("res://graffitty/paths.gd").stdpath("state").path_join("remote.json")
		for option in OS.get_cmdline_user_args():
			if option.begins_with("--remote-connection="): path = option.trim_prefix("--remote-connection=")
		error = await control.start(self, "", 0, path)
	else:
		error = await control.stop()
	remote_access_busy = false
	if error != OK: push_error("Remote access: " + control.last_error)
	for host in hosts: host.ui_changed.emit()
	return error


func bind_window(host: Node) -> void:
	var window: Window = host.get_window()
	if not window.has_meta(&"workspace_drag_input"):
		var relay := DragInput.new()
		relay.application = self
		window.add_child(relay)
		window.set_meta(&"workspace_drag_input", relay)
	configure_window_scale(window)
	if OS.has_feature("movie"):
		# Movie Maker fixes the video size when recording starts. Pin the window
		# to that size so a tiling window manager cannot resize it mid-take.
		window.min_size = window.size
		window.max_size = window.size
	if (not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		and DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE) and not window.is_embedded()):
		window.extend_to_title = true
	window.close_requested.connect(host.request_close_window)
	window.focus_entered.connect(host._build_menu.call_deferred)
	if not window.focus_entered.is_connected(update_frame_limit):
		window.focus_entered.connect(update_frame_limit)
		window.focus_exited.connect(update_frame_limit.call_deferred)


func _watch_window_scale(node: Node) -> void:
	if node is Window: configure_window_scale(node)


## Set the decoration request before a workspace or tab preview maps its toplevel.
func configure_workspace_frame(window: Window) -> void:
	var backend := DisplayServer.get_name()
	# Stock Wayland editors need libdecor's first configure before hiding its frame.
	if backend == "X11" or (backend == "Wayland" and (window.is_inside_tree() or ClassDB.class_exists(&"GraffittyWaylandFrame"))):
		window.borderless = window_decorations == "client"


func configure_window_scale(window: Window) -> void:
	preload("res://scenes/WindowScale.gd").watch(window, ui_scale)


func allocate_id() -> int:
	var id := next_id
	next_id += 1
	return id


func claim(id: int, host: Node) -> void:
	owners[id] = host
	next_id = maxi(next_id, id + 1)


func host_for_workspace(id: int) -> Node:
	var host: Node = owners.get(id)
	return host if is_instance_valid(host) else null


func forget(id: int) -> void:
	owners.erase(id)
	if agent_api != null:
		agent_api.revoke(id)


func _on_session_exited(_code: int, id: int) -> void:
	# Resolve ownership when the deferred signal runs: the tab may have moved
	# between windows. Defer teardown until the terminal finishes emitting exit.
	var host := host_for_workspace(id)
	if host == null:
		return
	var session: Node = host.session_model(id)
	if session == null or not session.has_exited:
		return
	host.request_close_terminal(id)


func unregister_host(host: Node) -> void:
	hosts.erase(host)
	if mods != null: mods.queue_refresh()
	if agent_attention != null: agent_attention.queue_refresh()
	# The host is freed at the end of the frame. Drop its global menu now, or a
	# surviving host could rebuild into submenus that are about to be freed.
	host._remove_menu()
	var window: Window = host.get_window()
	if window.close_requested.is_connected(host.request_close_window):
		window.close_requested.disconnect(host.request_close_window)
	if window.focus_entered.is_connected(host._build_menu.call_deferred):
		window.focus_entered.disconnect(host._build_menu.call_deferred)
	if not drag.is_empty() and drag.source == host:
		cancel_drag()
	for id in owners.keys():
		if owners[id] == host:
			forget(id)


var _pointer_frame_timer: Timer


func wake_pointer_frames() -> void:
	if _pointer_frame_timer == null:
		_pointer_frame_timer = Timer.new()
		_pointer_frame_timer.wait_time = .25
		add_child(_pointer_frame_timer)
		_pointer_frame_timer.timeout.connect(func():
			update_frame_limit()
			if not hosts.any(func(h): return is_instance_valid(h) and is_instance_valid(h.world) and Time.get_ticks_msec() < h.world.pointer_active_until):
				_pointer_frame_timer.stop())
	if _pointer_frame_timer.is_stopped(): _pointer_frame_timer.start()
	update_frame_limit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		application_focused = what == NOTIFICATION_APPLICATION_FOCUS_IN
		update_frame_limit()


func update_frame_limit() -> void:
	if application_focused:
		Engine.max_fps = max_fps
		return
	var limit := mini(inactive_max_fps, max_fps)
	for host in hosts:
		if not is_instance_valid(host): continue
		var hovered: bool = is_instance_valid(host.world) and Time.get_ticks_msec() < host.world.pointer_active_until
		if host.get_window().has_focus() or hovered:
			limit = max_fps
	Engine.max_fps = limit


func _take_group(source: Node, id: int) -> Dictionary:
	var item: Dictionary = source.workspace_layout.tab(id).duplicate(true)
	if item.is_empty():
		return { }
	# Associated chromiums created before presentation was built stay with the terminal.
	for key in Layout.keys(item.tree):
		if source.is_terminal_pane(key):
			for chromium_id in source.workspaces.get(int(key.substr(1)), { }).get(
				"chromiums",
				[],
			):
				if source.chromiums.has(chromium_id) and source.workspace_layout.containing(
						"%%%d" % chromium_id
					) < 0:
					item.tree = Layout.insert(
						item.tree,
						key,
						Layout.leaf("%%%d" % chromium_id, false),
						"right",
					)
	var bundle := { "group": item, "terminals": [], "chromiums": { } }
	source.layout_transaction = true
	source.workspace_layout.take(id)
	for key in Layout.keys(item.tree):
		if source.is_terminal_pane(key):
			bundle.terminals.append(
				source.take_workspace(int(key.substr(1)), Layout.keys(item.tree))
			)
	for key in Layout.keys(item.tree):
		if source.is_chromium_pane(key):
			var chromium_id := int(key.substr(1))
			if source.chromiums.has(chromium_id):
				var chromium: Node = source.chromiums[chromium_id]
				chromium.changed.disconnect(source._on_session_changed)
				bundle.chromiums[chromium_id] = chromium
				source.chromiums.erase(chromium_id)
	source.layout_transaction = false
	if source.workspace_layout.active >= 0:
		source.select_workspace(source.workspace_layout.active)
	source._refresh_workspace_layout()
	source.ui_changed.emit()
	return bundle


## `select` shows the received tab. A merge passes false: the tab only carries
## panes on their way into the tab the window already shows.
func _receive_group(
	target: Node,
	bundle: Dictionary,
	instantiate := true,
	same_world := true,
	select := true,
) -> void:
	target.layout_transaction = true
	for payload in bundle.terminals:
		target.receive_workspace(payload)
		if instantiate:
			target.world.import_terminal_tab(payload.id, payload.surface if same_world else null)
			payload.surface.free()
		else:
			target.initial_surfaces.append(payload.surface)
	for id in bundle.chromiums:
		target.chromiums[id] = bundle.chromiums[id]
		target.chromiums[id].connection = target.session_backend.connection
		bundle.chromiums[id].changed.connect(target._on_session_changed)
	target.workspace_layout.tabs.append(bundle.group)
	if select: target.workspace_layout.active = bundle.group.id
	target.layout_transaction = false
	if instantiate and select:
		target.select_workspace(bundle.group.id)


func _compatible_shared_hosts(source: Node, target: Node) -> bool:
	# Regrouping tabs/panes within one presentation stays on its connection.
	# Cross-window transfers require the same server identity and endpoint.
	if source == target: return true
	if not source.session_backend.is_remote and not target.session_backend.is_remote: return true
	if not source.session_backend.is_remote or not target.session_backend.is_remote: return false
	var a: Node = source.get_parent()
	var b: Node = target.get_parent()
	return not a.federated and not b.federated and not a.connection.epoch.is_empty() and a.connection.epoch == b.connection.epoch and a.connection.url == b.connection.url


func _compatible_tab_owners(source: Node, id: int, target: Node, destination: int) -> bool:
	if not _compatible_shared_hosts(source, target): return false
	if source != target: return true
	var connection: Node = source.session_backend.connection
	# A single Android presentation can contain several independent servers.
	# Only tabs belonging to the same transport can be regrouped together.
	return not "owners" in connection or (connection.owners.has(id)
		and connection.owners[id] == connection.owners.get(destination))


func _transfer_tab(source: Node, id: int, target: Node = null) -> Dictionary:
	var client: Node = source.get_parent()
	if client.transferring: return {"type": "error", "message": "Tab transfer already in progress"}
	# Finish pending geometry edits before transferring the persisted tab.
	var deadline := Time.get_ticks_msec() + 10000
	while source.session_backend.work_pending() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if source.session_backend.work_pending():
		return {"type": "error", "message": "Waiting for tab layout to finish"}
	client.transferring = true
	client.applying = true
	var request := {"tab": id}
	if target != null:
		request.destination = target.session_backend.connection.workspace
		# A remote source has not necessarily seen the destination's tabs.
		# Bind the witness through its owning connection before send_action
		# translates source-local IDs back to server IDs.
		if target.workspace_layout.active >= 0:
			request.destination_tab = client.connection.local_id(target.session_backend.connection.wire_id(target.workspace_layout.active))
		target.get_parent().applying = true
	var response: Dictionary = await client.connection.request_action("session_transfer", request)
	if response.get("type") != "error" and target != null:
		# Keep `applying` true until the destination has read through the server's
		# topology barrier. The transfer and topology use different connections.
		# Releasing early lets the destination's stale state remove the moved tab.
		var synced: Dictionary = await target.session_backend.connection.request_action("sync")
		if synced.get("type") == "error": response = synced
	if response.get("type") == "error":
		_finish_transfer(client)
		if target != null: _finish_transfer(target.get_parent())
		push_warning(str(response.get("message", "Tab transfer failed")))
	return response


func _finish_transfer(client: Node) -> void:
	if not is_instance_valid(client): return
	client.transferring = false
	# A parked presentation stays frozen; restore() refreshes it when shown.
	var parked: bool = desktop_presentation(client).parked
	client.applying = parked
	client.topology_signature = ""
	client.workspace_signature = ""
	if client.connection.connected and not parked: client._refresh.call_deferred()

func _close_shared_presentation(client: Node, window: Window) -> void:
	if is_instance_valid(client): client.queue_free()
	# Detaching the root window's session used to leave that window open and
	# empty: only other windows were closed here.
	_vacate_window(window)
	for other in get_tree().get_nodes_in_group("shared_presentations"):
		if other != client and other.primary_presentation:
			other.topology_signature = ""
			other._refresh.call_deferred()

func open_local_session(args: PackedStringArray, directory: String) -> void:
	for argument in args:
		if not argument.begins_with("--workspace="): continue
		var name := argument.trim_prefix("--workspace=")
		for existing in get_tree().get_nodes_in_group("shared_presentations"):
			if existing.settings.get("shared_local", false) and existing.settings.get("workspace") == name:
				existing.get_window().grab_focus()
				return
	var window := Window.new()
	window.title = "Graffitty"
	window.size = Vector2i(1280, 800)
	window.min_size = Vector2i(480, 300)
	if not hosts.is_empty():
		var source: Window = hosts.back().get_window()
		window.size = source.size
		window.position = source.position + Vector2i(40, 40)
		window.content_scale_mode = source.content_scale_mode
		window.content_scale_aspect = source.content_scale_aspect
		window.content_scale_size = source.content_scale_size
		window.content_scale_factor = source.content_scale_factor
	configure_workspace_frame(window)
	add_child(window)
	var client: Node = load("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = args
	client.launch_directory = directory
	client.managed = true
	client.detached.connect(_close_shared_presentation.bind(client, window))
	window.add_child(client)
	window.show()
	window.grab_focus()

## A window's client for `workspace` on the server `source_client` is connected to.
func _session_client(source_client: Node, workspace: String, independent: bool, id: int) -> Node:
	var client: Node = preload("res://scenes/remote/RemoteClient.gd").new()
	client.settings = source_client.settings.duplicate(true)
	client.local_return = source_client.local_return
	if not client.settings.get("shared_local", false):
		client.settings.url = source_client.connection.url
		client.settings.token = source_client.connection.token
	if client.settings.get("shared_local", false): client.settings.workspace = workspace
	else: client.settings.initial_session = workspace
	client.settings.get_or_add("capabilities", {}).erase("new_session")
	client.settings.capabilities.require_workspace = true
	client.managed = true
	client.primary_presentation = independent
	if not independent: client.presentation_tabs = [id]
	client.server_epoch = source_client.connection.epoch
	# Share the source client's ID mapping before exposing the moved controls.
	# A quick drag back may need to translate frontend IDs before destination
	# topology arrives.
	client.connection.local_ids = source_client.connection.local_ids
	return client


## A native window beside `source`'s, sized and scaled like it.
func _session_window(source: Node, position: Vector2i, preview: Window) -> Window:
	var window := preview if is_instance_valid(preview) else Window.new()
	window.title = "Graffitty"
	window.size = source.get_window().size
	window.min_size = Vector2i(480, 300)
	NativeFrame.move_window(window, (
		source.get_window().position + Vector2i(40, 40)
		if position == Vector2i(-1, -1)
		else position
	))
	window.content_scale_mode = source.get_window().content_scale_mode
	window.content_scale_aspect = source.get_window().content_scale_aspect
	window.content_scale_size = source.get_window().content_scale_size
	window.content_scale_factor = source.get_window().content_scale_factor
	if not window.is_inside_tree():
		configure_workspace_frame(window)
		add_child(window)
	return window


## Open a new window with one terminal in a new session.
##
## Create the terminal in a tab of this session so it starts in the
## focused pane's directory. Move it to the new session and keep this
## window's view still so the temporary tab stays hidden.
func open_session_window(source: Node) -> bool:
	if not opens_windows() or not is_instance_valid(source) or source.close_dialog != null: return false
	var source_client: Node = source.get_parent()
	if source_client.federated or source_client.transferring: return false
	var backend: RefCounted = source.session_backend
	var deadline := Time.get_ticks_msec() + 10000
	while backend.work_pending() and Time.get_ticks_msec() < deadline: await get_tree().process_frame
	if backend.work_pending() or source_client.transferring or not is_instance_valid(source): return false
	source_client.transferring = true
	source_client.applying = true
	var origin: int = source.active_session_id
	var created: Dictionary = await source_client.connection.request_action("create", {"session": origin, "kind": "tab", "spawn": backend._spawn_options(source, origin)})
	var response := created
	if created.get("type") != "error":
		response = await source_client.connection.request_action("session_transfer", {"tab": source_client.connection.local_id(int(created.tab))})
	if response.get("type") == "error" or not is_instance_valid(source):
		_finish_transfer(source_client)
		push_warning(str(response.get("message", "Could not open a new window")))
		return false
	var client := _session_client(source_client, str(response.workspace), true, -1)
	client.settings.startup_world = source.current_plugin
	var gap: float = source.tiling_config.gap
	client.host_ready.connect(func():
		client.host.session_backend.apply_new_tab_gap.call_deferred(weakref(client.host), client.host.workspace_layout.active, gap), CONNECT_ONE_SHOT)
	var window := _session_window(source, Vector2i(-1, -1), null)
	client.detached.connect(_close_shared_presentation.bind(client, window))
	window.add_child(client)
	_finish_transfer(source_client)
	window.show()
	window.grab_focus()
	return true


## Android presents one embedded window; nothing may detach into another.
func opens_windows() -> bool:
	return not preload("res://scenes/input/InteractionProfile.gd").touch_controls()


func detach_workspace(source: Node, id: int, position := Vector2i(-1, -1), preview: Window = null, force_session := false) -> Node:
	if not opens_windows(): return null
	if is_instance_valid(source) and source.session_backend.is_remote and source.get_parent().federated: return null
	if (
		not is_instance_valid(source) or source.workspace_layout.tab(id).is_empty()
		or source.close_dialog != null
	):
		return null
	if source.get_tabs().size() == 1 and not force_session:
		if position != Vector2i(-1, -1):
			NativeFrame.move_window(source.get_window(), position)
		source.get_window().grab_focus()
		return source
	var source_client: Node = source.get_parent()
	# Local and authenticated remote windows both get a new server session.
	# A browser may live in a different presentation tab from its terminal.
	# Keep that lifetime dependency in one owner workspace when detaching it.
	var independent := true
	for chromium in source_client.connection.topology.get("chromiums", []):
		var owner_tab := -1
		for pane in source_client.connection.topology.get("panes", []):
			if int(pane.id) == int(chromium.owner): owner_tab = int(pane.tab)
		if owner_tab >= 0 and (int(chromium.tab) == id) != (owner_tab == id):
			independent = false
	if force_session and not independent: return null
	var response: Dictionary
	if independent:
		response = await _transfer_tab(source, id)
	else:
		# Cross-tab browser ownership requires presentation-only partitioning.
		response = {"workspace": source_client.connection.workspace}
		source_client.applying = true
	if response.get("type") == "error": return null
	var client := _session_client(source_client, str(response.workspace), independent, id)
	if not source_client.primary_presentation: source_client.presentation_tabs.erase(id)
	var bundle := _take_group(source, id)
	var window := _session_window(source, position, preview)
	if bundle.is_empty():
		# The source mirror already dropped the tab while the transfer was awaited,
		# so nothing is left to carry.
		#
		# The new session still exists: its window builds a host from the server
		# topology, as a launch does.
		client.detached.connect(_close_shared_presentation.bind(client, window))
		window.add_child(client)
		_finish_transfer(source_client)
		if is_instance_valid(preview): preview.complete_handoff()
		window.show()
		window.grab_focus()
		retire_empty_host(source)
		return null
	var target: Node = load("res://scenes/TerminalHost.gd").new()
	target.session_backend = preload("res://scenes/session/RemoteSessionBackend.gd").new(client.connection)
	target.session_backend.fit_main_view = fit_main_view
	target.application = self
	target.restoring_window = true
	target.current_plugin = source.current_plugin if not bundle.terminals.is_empty() else ""
	_receive_group(target, bundle, false)
	client.host = target
	client.add_child(target)
	client.detached.connect(_close_shared_presentation.bind(client, window))
	window.add_child(client)
	target.select_workspace(id)
	_finish_transfer(source_client)
	if is_instance_valid(preview): preview.complete_handoff()
	window.show()
	window.grab_focus()
	retire_empty_host(source)
	return target


## `select` false keeps the target window on its current tab (see _receive_group).
func move_workspace(source: Node, target: Node, id: int, index := -1, select := true) -> bool:
	if is_instance_valid(source) and is_instance_valid(target) and not _compatible_shared_hosts(source, target): return false
	if not is_instance_valid(source) or not is_instance_valid(target):
		return false
	if source == target:
		source.move_session(id, clampi(index, 0, source.get_tabs().size() - 1))
		return true
	if (
		source.workspace_layout.tab(id).is_empty()
		or source.close_dialog != null or target.close_dialog != null
	):
		return false
	var source_client: Node = source.get_parent()
	var target_client: Node = target.get_parent()
	if source_client.connection.workspace != target_client.connection.workspace:
		var response := await _transfer_tab(source, id, target)
		if response.get("type") == "error": return false
	if not source_client.primary_presentation: source_client.presentation_tabs.erase(id)
	if not target_client.primary_presentation and id not in target_client.presentation_tabs: target_client.presentation_tabs.append(id)
	var bundle := _take_group(source, id)
	if bundle.is_empty():
		# The tab left the source mirror during the transfer; both clients
		# rebuild from the server topology instead of carrying it.
		_finish_transfer(source_client)
		_finish_transfer(target_client)
		return true
	_receive_group(target, bundle, true, source.current_plugin == target.current_plugin, select)
	_finish_transfer(source_client)
	_finish_transfer(target_client)
	source_client._subscribe()
	target_client._subscribe()
	if index >= 0:
		target.move_session(id, index)
	# Re-seating world surfaces during reorder can change terminal focus.
	# The completed drop selects the carried tab, including its subscription.
	if select: target.select_workspace(id)
	target.get_window().grab_focus()
	retire_empty_host(source)
	return true


func merge_workspace(
	source: Node,
	target: Node,
	id: int,
	destination: int,
	pane := "",
	edge := "right",
	commit_layout := true,
) -> bool:
	if source == target and id == destination: return false
	if not _compatible_tab_owners(source, id, target, destination): return false
	var group: Dictionary = source.workspace_layout.tab(id)
	if group.is_empty() or target.workspace_layout.tab(destination).is_empty(): return false
	if source != target and source.session_backend.connection.workspace != target.session_backend.connection.workspace:
		# Cross the session boundary without showing the carried tab: the
		# window stays on the previewed destination while its panes arrive.
		if not await move_workspace(source, target, id, -1, false): return false
		source = target
		group = target.workspace_layout.tab(id)
	var keys: Array = Layout.keys(group.tree)
	# Moving a terminal also carries its attached chromiums. Skip keys already moved.
	for key in keys:
		if not is_instance_valid(source) or source.workspace_layout.containing(key) < 0: continue
		if not await move_pane(source, target, key, destination, pane, edge, commit_layout): return false
	return true


## Every visible connection defines the transfer group, in both directions.
func pane_transfer_connections(source: Node) -> Array:
	var edges: Array = []
	if "agent_api" in source and source.agent_api != null:
		edges.append_array(source.agent_api.graph.edges.values())
	if "chromiums" in source:
		for id in source.chromiums:
			var owner: int = source.chromiums[id].owner_id
			if owner != id: edges.append({"from": "%%%d" % owner, "to": "%%%d" % id, "kind": "chromium"})
	if "sessions" in source:
		for id in source.sessions:
			var owner: int = source.sessions[id].term.get_meta("filetree_owner", -1)
			if owner >= 0: edges.append({"from": "%%%d" % owner, "to": "%%%d" % id, "kind": "filetree"})
	return edges


func pane_transfer_keys(source: Node, key: String) -> Array[String]:
	var keys: Array[String] = [key]
	var from: int = source.workspace_layout.containing(key)
	var edges := pane_transfer_connections(source)
	while true:
		var before := keys.size()
		for edge: Dictionary in edges:
			if edge.from in keys or edge.to in keys:
				for endpoint: String in [edge.from, edge.to]:
					if endpoint not in keys and source.workspace_layout.containing(endpoint) == from: keys.append(endpoint)
		if keys.size() == before: return keys
	return keys


func _can_create_pane_tab(source: Node, target: Node, key: String) -> bool:
	var from: int = source.workspace_layout.containing(key)
	if from < 0: return false
	# A different host can receive the pane as a new session/presentation.
	# Within this host, a pane carries its connected group; a new tab holding
	# everything the old one had would only change its ID.
	if source != target: return true
	var moving := pane_transfer_keys(source, key)
	return Layout.keys(source.workspace_layout.tab(from).tree).any(func(member: String) -> bool: return member not in moving)


func _restore_transfer_rectangles(target: Node, id: int, key: String, original_rectangles: Dictionary) -> void:
	if original_rectangles.size() > 1:
		var tree: Dictionary = target.workspace_layout.tab(id).tree
		tree.physics_anchor = key
		for member in original_rectangles:
			var item := Layout.find(tree, member)
			if not item.is_empty():
				item.rect = original_rectangles[member]
				item.graph_floating = true
				item.stashed = false
		target.workspace_view.refresh()


func move_pane(
	source: Node,
	target: Node,
	key: String,
	destination := -1,
	pane := "",
	edge := "right",
	commit_layout := true,
	original_rectangles: Dictionary = {},
) -> bool:
	if not is_instance_valid(source) or not is_instance_valid(target) or not _compatible_shared_hosts(source, target): return false
	var from: int = source.workspace_layout.containing(key)
	if from < 0 or key == pane or source.close_dialog != null or target.close_dialog != null: return false
	if destination < 0 and not _can_create_pane_tab(source, target, key): return false
	if destination >= 0 and target.workspace_layout.tab(destination).is_empty(): return false
	if destination >= 0 and not _compatible_tab_owners(source, from, target, destination): return false
	var connection: Node = source.session_backend.connection
	if "owners" in connection:
		connection = connection.owners.get(from)
		if connection == null: return false
	if source != target and connection.workspace != target.session_backend.connection.workspace:
		var transfer_tab := from
		if Layout.keys(source.workspace_layout.tab(from).tree).size() > 1:
			var split: Dictionary = await connection.request_action("regroup", {"surface": key, "tab": null})
			if split.get("type") == "error": return false
			transfer_tab = int(split.tab)
			await connection.request_action("sync")
			_apply_topology(source.get_parent())
		# Into an existing tab: keep showing it while the pane arrives.
		if not await move_workspace(source, target, transfer_tab, -1, destination < 0):
			if transfer_tab != from:
				await connection.request_action("regroup", {"surface": key, "tab": from, "restore": true})
			return false
		if destination >= 0:
			return await move_pane(target, target, key, destination, pane, edge, commit_layout, original_rectangles)
		_restore_transfer_rectangles(target, transfer_tab, key, original_rectangles)
		target.focus_pane(key)
		if commit_layout: target.session_backend.commit_workspace(target)
		return true
	var response: Dictionary = await connection.request_action("regroup", {"surface": key, "tab": destination if destination >= 0 else null})
	if response.get("type") == "error":
		push_warning(str(response.get("message", "Pane move failed")))
		return false
	var id := int(response.get("tab", response.get("result", {}).get("tab", -1)))
	if id < 0: return false
	var target_client: Node = target.get_parent()
	if not target_client.primary_presentation and id not in target_client.presentation_tabs: target_client.presentation_tabs.append(id)
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(target) and target.workspace_layout.containing(key) != id and Time.get_ticks_msec() < deadline:
		_apply_topology(target_client)
		await get_tree().process_frame
	if not is_instance_valid(target) or target.workspace_layout.containing(key) != id: return false
	_restore_transfer_rectangles(target, id, key, original_rectangles)
	var transaction: bool = target.layout_transaction
	if not commit_layout: target.layout_transaction = true
	target.focus_pane(key)
	target.layout_transaction = transaction
	if commit_layout: target.session_backend.commit_workspace(target)
	if source != target and is_instance_valid(source): retire_empty_host(source)
	return true


## A parked presentation ignores topology, but a pane leaving one still has to
## see the split the server just made for it.
func _apply_topology(client: Node) -> void:
	var parked: bool = desktop_presentation(client).parked
	if parked: client.applying = false
	client.topology_signature = ""
	client._refresh()
	if parked: client.applying = true


func detach_pane(source: Node, key: String, position := Vector2i(-1, -1), preview: Window = null, rectangles: Dictionary = {}) -> Node:
	var from: int = source.workspace_layout.containing(key)
	# Refuse before regrouping: a pane split into a new tab would stay behind.
	if from < 0 or not opens_windows():
		return null
	if Layout.keys(source.workspace_layout.tab(from).tree).size() == 1:
		return await detach_workspace(source, from, position, preview)
	if not await move_pane(source, source, key, -1, "", "right", true, rectangles):
		return null
	return await detach_workspace(source, source.workspace_layout.active, position, preview)


func chromium_host(id: int) -> Node:
	for host in hosts:
		if host.chromiums.has(id):
			return host
	return null


func retire_empty_host(host: Node, detach_session := false) -> void:
	if (
		not is_instance_valid(host) or host.is_queued_for_deletion()
		or (not detach_session and not host.get_tabs().is_empty())
	):
		return
	var parked: bool = host.session_backend.is_remote and desktop_presentation(host.get_parent()).parked
	var window: Window = host.get_window()
	unregister_host(host)
	host.process_mode = Node.PROCESS_MODE_DISABLED
	var retired_client: Node = host.get_parent() if host.session_backend.is_remote else null
	if retired_client != null:
		retired_client.connection.disconnect_remote()
		retired_client.host = null
		retired_client.queue_free()
	else:
		host.queue_free()
	if parked: return
	_vacate_window(window)


## Close a window after it loses its presentation.
##
## The root Window must stay in the tree. Move a surviving host into it,
## restore a parked desktop presentation, or quit if nothing remains.
func _vacate_window(window: Window) -> void:
	if window != get_tree().root:
		window.hide()
		window.queue_free()
	elif not hosts.is_empty():
		# Move a surviving host into the root Window at the host's desktop
		# position. Retire the old shell after the move.
		#
		# Godot cannot hide or free the root Window. Keep the host's World3D
		# and the persistent session through the move.
		var survivor: Node = hosts.back()
		var old_window: Window = survivor.get_window()
		if old_window.close_requested.is_connected(survivor.request_close_window): old_window.close_requested.disconnect(survivor.request_close_window)
		old_window.size_changed.disconnect(survivor._refresh_workspace_layout)
		old_window.size_changed.disconnect(survivor.world._on_window_size_changed)
		var disable_3d: bool = survivor.world_viewport.disable_3d
		survivor.moving_window = true
		survivor.world_viewport.set_block_signals(true)
		if survivor.session_backend.is_remote:
			var client: Node = survivor.get_parent()
			if old_window.close_requested.is_connected(client.request_close_window): old_window.close_requested.disconnect(client.request_close_window)
			client.reparent(window)
			client.managed = false
			client.primary_presentation = true
			window.close_requested.connect(client.request_close_window)
		else:
			survivor.reparent(window)
		survivor.world_viewport.set_block_signals(false)
		survivor.moving_window = false
		survivor.world_viewport.disable_3d = disable_3d
		window.content_scale_mode = old_window.content_scale_mode
		window.content_scale_aspect = old_window.content_scale_aspect
		window.content_scale_size = old_window.content_scale_size
		window.content_scale_factor = old_window.content_scale_factor
		NativeFrame.move_window(window, old_window.position)
		window.size = old_window.size
		window.mode = old_window.mode
		window.transparent = old_window.transparent
		window.size_changed.connect(survivor._refresh_workspace_layout)
		window.size_changed.connect(survivor.world._on_window_size_changed)
		bind_window(survivor)
		if survivor.session_backend.is_remote and window.close_requested.is_connected(survivor.request_close_window): window.close_requested.disconnect(survivor.request_close_window)
		survivor._build_menu.call_deferred()
		survivor._refresh_workspace_layout()
		old_window.hide()
		old_window.queue_free()
		window.grab_focus()
	elif desktop_presentations.any(func(view): return view.parked and is_instance_valid(view.client) and is_instance_valid(view.client.host)):
		for view in desktop_presentations:
			if view.parked and is_instance_valid(view.client) and is_instance_valid(view.client.host):
				view.restore(window)
				break
	elif not _closing:
		_closing = true
		get_tree().quit()


## Quits without asking, because an upgrade replaced this app's files or is
## about to. Sessions stay on the server.
##
## With `relaunch`, the new version is opened first, and it resumes the
## session that was showing.
func leave_for_update(relaunch: bool) -> void:
	if _closing: return
	_closing = true
	if relaunch:
		# Drop the user arguments (`--cwd`). They would open their pane a second time.
		var arguments := OS.get_cmdline_args()
		if not OS.has_feature("template"):
			# Development launch: the engine removed `--path` and `--headless` from the
			# arguments, so add them back.
			arguments = PackedStringArray(["--path", ProjectSettings.globalize_path("res://")]) + arguments
			if DisplayServer.get_name() == "headless": arguments = PackedStringArray(["--headless"]) + arguments
		# Start it directly so it inherits this process's environment and connects
		# to the same session server.
		OS.create_process(preload("res://graffitty/executables.gd").app(), arguments)
	get_tree().quit()


func begin_drag(source: Node, strip: Control, id: int) -> void:
	if not drag.is_empty():
		if drag.strip == strip:
			return
		cancel_drag()
	drag = _drag_state(
		source,
		strip,
		id,
		"tab",
		DragMode.REORDER,
		str(strip.buttons[id].get_meta("title", "Terminal")),
	)
	# Hovering another tab replaces the visible pane controls. Retain the
	# carried layout now, including the actual sizes of tiled source panes.
	drag.rectangles = {}
	Layout.arrange(source.workspace_layout.tab(id).tree.duplicate(true), source.workspace_view.content_rect(), drag.rectangles)
	drag.grab_offset = Vector2(strip._grab_offset, strip._press_point.y)
	if source.get_tabs().size() == 1 and opens_windows():
		strip.window_drag = true
		strip.buttons[id].position = Vector2.ZERO
		drag.window_drag = true
		drag.window_offset = ScreenSpace.of(strip, strip._press_point) - Vector2(source.get_window().position)
		drag.mode = DragMode.FLOATING


func begin_pane_drag(source: Node, pane: Control, key: String, detach := false) -> void:
	cancel_drag()
	drag = _drag_state(
		source,
		pane,
		source.workspace_layout.containing(key),
		"pane",
		DragMode.FLOATING,
		pane.handle.text,
	)
	drag.pane = key
	drag.rectangles = {}
	drag.keys = pane_transfer_keys(source, key)
	var original: Dictionary = pane.drag_start_rectangles if "drag_start_rectangles" in pane else source.workspace_view.pane_rects
	for member in drag.keys:
		if original.has(member): drag.rectangles[member] = original[member]
	drag.edges = []
	for edge: Dictionary in pane_transfer_connections(source):
		if edge.from in drag.keys and edge.to in drag.keys: drag.edges.append(edge.duplicate(true))
	if drag.keys.size() > 1: drag.title = tr("Move connected group (%d panes)") % drag.keys.size()
	# Shift-drag: releasing over the window's own content detaches it as well.
	drag.detach = detach


func _drag_state(
	source: Node,
	strip: Control,
	id: int,
	kind: String,
	mode: int,
	title: String,
) -> Dictionary:
	return {
		"source": source,
		"strip": strip,
		"id": id,
		"kind": kind,
		"mode": mode,
		"target": null,
		"index": -1,
		"title": title,
		"previews": { },
		"hover_tab": -1,
		"hover_ready": false,
		"hover_host": null,
	}


## A pane dragged back over its own tab's content resumes an ordinary move.
func release_pane_drag() -> void:
	preload("res://scenes/session/SessionPanelDrag.gd").clear(self)
	var previews: Dictionary = drag.get("previews", { })
	_stop_hover()
	drag = { }
	_free_drag_preview()
	_clear_drop_hints()
	_restore_previews(previews)


func _free_drag_preview() -> void:
	if is_instance_valid(drag_preview):
		drag_preview.hide()
		drag_preview.queue_free()
	drag_preview = null


func cancel_drag(restore := true) -> void:
	preload("res://scenes/session/SessionPanelDrag.gd").clear(self)
	var strip: Variant = drag.get("strip")
	var previews: Dictionary = drag.get("previews", { })
	_stop_hover()
	drag = { }
	if restore:
		_restore_previews(previews)
	_free_drag_preview()
	if is_instance_valid(strip):
		strip._cancel_drag()
	_clear_drop_hints()


## Ends a committed drag. Tabs opened only on the way elsewhere close again;
## `keep` is the window receiving the drop, which selects its own result.
func _end_drag(keep: Node) -> void:
	preload("res://scenes/session/SessionPanelDrag.gd").clear(self, keep)
	var previews: Dictionary = drag.get("previews", { })
	cancel_drag(false)
	previews.erase(keep)
	_restore_previews(previews)


func _restore_previews(previews: Dictionary) -> void:
	for host in previews:
		# A window that is closing has nothing left to show.
		if is_instance_valid(host) and host in hosts:
			host.select_workspace(previews[host], true)


## Desktop position of a point in a native window's viewport. Unlike
## CanvasItem.get_screen_transform(), Viewport.get_screen_transform() omits the
## window's own desktop position, which OS hit-testing and the pointer include.
func screen_point(viewport: Viewport, point: Vector2) -> Vector2:
	return Vector2(viewport.get_window().position) + viewport.get_screen_transform() * point


## Tab bars span their window, so a drop beside the last tab still lands there.
func _within_bar(host: Node, position: Vector2, margin := 0.0) -> bool:
	if host.workspace_view == null:
		return false
	var bar: Control = host.workspace_view.tab_bar
	if not is_instance_valid(bar) or not bar.is_visible_in_tree() or not host.get_window().visible:
		return false
	var local := ScreenSpace.into(bar, position)
	return Rect2(Vector2.ZERO, bar.size).grow(margin).has_point(local)


func _strip_at(host: Node, screen_position: Vector2) -> Control:
	return host.workspace_view.tab_bar.tabs if _within_bar(host, screen_position) else null


func _window_at(screen_position: Vector2, ignored: Node = null) -> Node:
	if DisplayServer.get_name() != "headless" and not scripted_pointer and not preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		# Ask the OS which window is in front at the drop point.
		# An obscured tab strip should never receive drops through a window or popup.
		var window_id := DisplayServer.get_window_at_screen_position(Vector2i(screen_position))
		for host in hosts:
			if host != ignored and host.get_window().get_window_id() == window_id and host.workspace_view != null:
				return host
		# The moving source window covers the pointer. Look for a destination
		# underneath it, but never reach through an unrelated application's window.
		if ignored == null or ignored.get_window().get_window_id() != window_id:
			return null
	# No OS pointer: other applications' windows are not in the way, and a
	# window may be embedded in another, so measure what each window shows.
	for i in range(hosts.size() - 1, -1, -1):
		if hosts[i] == ignored:
			continue
		var view: Control = hosts[i].workspace_view
		if (
			hosts[i].get_window().visible and is_instance_valid(view)
			and ScreenSpace.shown(view).has_point(screen_position)
		):
			return hosts[i]
	return null


func _clear_drop_hints() -> void:
	for host in hosts:
		if host.workspace_view == null:
			continue
		var strip: Control = host.workspace_view.tab_bar.tabs
		if strip != null and strip.has_method("set_external_drop_hint"):
			strip.set_external_drop_hint(-1)
			strip.set_hover_hint(-1)
		host.workspace_view.show_drop({ })


## Spring-loaded tabs: holding a drag over another tab opens it, so the drag
## can continue into that tab's content.
func _hover_tab(host: Node, id: int) -> void:
	if host != drag.hover_host or id != drag.hover_tab:
		if is_instance_valid(drag.hover_host):
			drag.hover_host.workspace_view.tab_bar.tabs.set_hover_hint(-1)
		drag.hover_host = host
		drag.hover_tab = id
		_stop_hover()
		if host != null and id >= 0 and host.workspace_layout.active != id:
			schedule_drag_hover()
			var hints: Control = host.workspace_view.tab_bar.tabs
			_hover_animation = create_tween()
			_hover_animation.tween_method(func(progress: float):
				if is_instance_valid(hints): hints.set_hover_hint(id, progress), 0.0, 1.0, float(HOVER_PREVIEW_MS) / 1000.0)
	if host == null or id < 0:
		return
	var strip: Control = host.workspace_view.tab_bar.tabs
	if host.workspace_layout.active == id:
		strip.set_hover_hint(-1)
		return
	if not drag.get("hover_ready", false): return
	if _hover_animation != null: _hover_animation.kill()
	strip.set_hover_hint(-1)
	if not drag.previews.has(host):
		drag.previews[host] = host.workspace_layout.active
	host.select_workspace(id, true)


func _tab_title(host: Node, id: int) -> String:
	for tab in host.get_tabs():
		if int(tab.id) == id:
			return str(tab.title)
	return "Tab"


## Where a dragged pane lands: under the pointer, at the point it was grabbed.
func _pane_drop_rect(host: Node, pane: Control, screen_position: Vector2) -> Rect2:
	var view: Control = host.workspace_view
	var point: Vector2 = view.layout_point(screen_position)
	return view.reachable_rect(pane.key, Rect2(point - pane.grab_offset(), pane._start_rect.size))


func _tab_drop_rectangles(point: Vector2) -> Dictionary:
	var original: Dictionary = drag.get("rectangles", {})
	if original.is_empty(): return {}
	var bounds: Rect2 = original.values()[0]
	for rect: Rect2 in original.values(): bounds = bounds.merge(rect)
	var offset: Vector2 = point - bounds.position - drag.grab_offset
	var placed := {}
	for key in original:
		var rect: Rect2 = original[key]
		placed[key] = Rect2(rect.position + offset, rect.size)
	return placed


func _pane_group_drop_rectangles(anchor: Rect2) -> Dictionary:
	var original: Dictionary = drag.get("rectangles", {})
	if not original.has(drag.pane): return {}
	var delta: Vector2 = anchor.position - original[drag.pane].position
	var placed := {}
	for key in original:
		placed[key] = Rect2(original[key].position + delta, original[key].size)
	return placed


func update_drag(screen_position: Vector2) -> void:
	if drag.is_empty():
		return
	if not is_instance_valid(drag.get("source")) or not is_instance_valid(drag.get("strip")):
		cancel_drag()
		return
	var source: Node = drag.source
	var strip: Control = drag.strip
	if source.workspace_layout.tab(drag.id).is_empty():
		cancel_drag()
		return
	drag.pointer = screen_position
	if preload("res://scenes/session/SessionPanelDrag.gd").update(self, screen_position): return
	var moving_window: bool = drag.get("window_drag", false)
	if moving_window:
		NativeFrame.move_window(source.get_window(), Vector2i((screen_position - drag.window_offset).round()))
	var hit := _window_at(screen_position, source if moving_window else null)
	# Local tab reordering does not transfer ownership. Remote presentations
	# still obey the shared-owner restriction when dragged out of their bar.
	var own_bar: bool = hit == source and drag.kind == "tab" and _within_bar(source, screen_position, DETACH_DISTANCE)
	if hit != null and not own_bar and not _compatible_shared_hosts(source, hit): hit = null
	if moving_window and hit != null and hit != drag.target and not scripted_pointer:
		# The moving source would cover the target's preview. Raise the actual
		# destination while retaining the source window and desktop grab offset.
		hit.get_window().grab_focus()
	var is_tab: bool = drag.kind == "tab"
	if (
		is_tab and drag.mode == DragMode.REORDER and hit == source
		and _within_bar(source, screen_position, DETACH_DISTANCE)
	):
		# The source strip reorders the tab and reports what it rests on.
		_hover_tab(source, strip.hover_id)
		return
	if is_tab and not moving_window:
		strip.set_drag_external(true)
	var dock: Node = null
	if drag.mode == DragMode.DOCKED and is_instance_valid(drag.target):
		if (
			(hit == drag.target or hit == null)
			and _within_bar(drag.target, screen_position, DOCK_LEAVE_MARGIN)
		):
			dock = drag.target
	if (
		dock == null and hit != null and hit.close_dialog == null
		and _within_bar(hit, screen_position, DOCK_ENTER_MARGIN)
	):
		dock = hit
	if dock != null:
		if is_instance_valid(drag_preview):
			drag_preview.hide()
		if is_tab and dock == source:
			_clear_drop_hints()
			drag.mode = DragMode.REORDER
			drag.target = null
			strip.set_drag_external(false)
			strip.set_drag_pointer(screen_position)
			_hover_tab(source, strip.hover_id)
			return
		var destination: Control = dock.workspace_view.tab_bar.tabs
		if drag.target != dock or drag.mode != DragMode.DOCKED:
			_clear_drop_hints()
		# Content placement and tab insertion are mutually exclusive, even
		# when both targets belong to the same native window.
		drag.erase("zone")
		drag.mode = DragMode.DOCKED
		drag.target = dock
		var place: Dictionary = destination.incoming_placement(screen_position)
		if not is_tab and not _can_create_pane_tab(source, dock, drag.pane):
			_clear_drop_hints()
			drag.mode = DragMode.BLOCKED
			drag.target = null
			# Keep spring-loaded tab switching, so the pane can still be dropped
			# into another tab's content without advertising a redundant new tab.
			_hover_tab(dock, place.hover)
			return
		drag.index = place.index
		destination.set_external_drop_hint(drag.index, drag.title)
		_hover_tab(dock, place.hover)
		return
	_hover_tab(null, -1)
	_clear_drop_hints()
	if hit != null and hit.close_dialog == null:
		var zone: Dictionary = hit.workspace_view.drop_zone(screen_position)
		# A drag's own tab is no merge target: tabs detach there and panes move.
		if not zone.is_empty() and not (hit == source and zone.tab == drag.id) and _compatible_tab_owners(source, drag.id, hit, zone.tab):
			if is_tab:
				zone.rect = hit.workspace_view.content_rect()
				zone.label = tr("Join “%s”") % _tab_title(hit, zone.tab)
			else:
				zone.rect = _pane_drop_rect(hit, strip, screen_position)
				zone.label = "Move here"
			drag.mode = DragMode.MERGE
			drag.target = hit
			drag.zone = zone
			hit.workspace_view.show_drop(zone)
			var source_group: Dictionary = source.workspace_layout.tab(drag.id)
			var incoming: Dictionary = (
				source_group.tree
				if is_tab
				else Layout.find(source_group.tree, drag.pane)
			)
			var point: Vector2 = hit.workspace_view.layout_point(screen_position)
			var placements := _tab_drop_rectangles(point) if is_tab else _pane_group_drop_rectangles(zone.rect)
			if not is_tab and drag.get("keys", []).size() > 1:
				incoming = {"windows": []}
				for member in drag.keys:
					var item := Layout.find(source_group.tree, member).duplicate(true)
					item["graph_floating"] = true
					incoming.windows.append(item)
				zone.label = drag.title
			var preview_rect: Rect2 = placements.values()[0] if not placements.is_empty() else zone.rect
			var plan: Dictionary = hit.workspace_view.preview_window_move(
				"",
				preview_rect,
				point,
				incoming,
				placements,
			)
			if not is_tab:
				# Anchor each pane placed by an explicit drop, even for a single pane.
				# This keeps collision physics from moving it away from the preview
				# as soon as the cross-window transaction completes.
				if not plan.is_empty(): plan.tree.physics_anchor = drag.pane
				hit.workspace_view.layout_preview.connections = drag.get("edges", [])
				hit.workspace_view.layout_preview.queue_redraw()
			if not plan.is_empty():
				zone["layout_plan"] = plan
				hit.workspace_view.drop_hint.visible = not hit.workspace_view.layout_preview.visible
			if is_instance_valid(drag_preview):
				drag_preview.hide()
			return
	if not opens_windows():
		# Without another window to create, a release here moves nothing.
		# Do not show a floating preview that suggests otherwise.
		if is_instance_valid(drag_preview): drag_preview.hide()
		drag.mode = DragMode.BLOCKED
		drag.target = null
		drag.index = -1
		return
	if moving_window and drag.target != null and not scripted_pointer:
		source.get_window().grab_focus()
	drag.mode = DragMode.FLOATING
	drag.target = null
	drag.index = -1
	if moving_window:
		return
	if not is_instance_valid(drag_preview):
		drag_preview = DragPreview.new()
		drag_preview.configure(source, strip, drag.id, drag.get("rectangles", {}) if not is_tab and drag.get("keys", []).size() > 1 else {}, drag.get("edges", []))
		add_child(drag_preview)
	drag_preview.follow(screen_position)
	if not drag_preview.visible:
		drag_preview.show()


func finish_drag(screen_position: Vector2) -> bool:
	if drag.is_empty():
		return false
	update_drag(screen_position)
	if drag.is_empty():
		return true
	if drag.has("session_drop"):
		preload("res://scenes/session/SessionPanelDrag.gd").finish(self)
		return true
	var source: Node = drag.source
	var id: int = drag.id
	var key: String = drag.get("pane", "")
	var is_tab: bool = drag.kind == "tab"
	var rectangles: Dictionary = drag.get("rectangles", {})
	match drag.mode:
		DragMode.BLOCKED:
			cancel_drag()
			return true
		DragMode.REORDER:
			preload("res://scenes/session/SessionPanelDrag.gd").clear(self)
			# Leave the strip's drag state intact so it can commit insertion order.
			var previews: Dictionary = drag.previews
			_stop_hover()
			drag = { }
			_free_drag_preview()
			_clear_drop_hints()
			_restore_previews(previews)
			return false
		DragMode.MERGE:
			var target: Node = drag.target
			var zone: Dictionary = drag.zone
			_end_drag(target)
			if is_tab:
				_merge_tab_preview.call_deferred(source, target, id, zone)
			else:
				_merge_pane.call_deferred(source, target, key, zone)
			return true
		DragMode.DOCKED:
			var target: Node = drag.target
			var index: int = drag.index
			_end_drag(target)
			if is_tab:
				move_workspace.call_deferred(source, target, id, index)
			else:
				_dock_pane.call_deferred(source, target, key, index, rectangles)
			return true
	if drag.get("window_drag", false):
		# The original native window has already followed the pointer. Dropping
		# on the desktop (or back over its own content) creates no presentation.
		_end_drag(null)
		return true
	var over := _window_at(screen_position)
	var own: bool = (
		over == source and source.workspace_layout.active == id
		and not source.workspace_view.drop_zone(screen_position).is_empty()
	)
	if over != null and not own:
		# Gaps and chrome of our windows are not drop targets.
		cancel_drag()
		return true
	if own and not is_tab and not drag.get("detach", false):
		var rect := _pane_drop_rect(source, drag.strip, screen_position)
		_end_drag(source)
		source.workspace_view.set_window_rect(key, rect)
		return true
	# Outside every window, or a tab dropped onto its own content: a new window.
	var preview := drag_preview
	var position := preview.position if is_instance_valid(preview) else Vector2i(screen_position - Vector2(30, 16))
	# Keep the decorated native window alive while the server transfers the
	# tab. Its position, size and identity are also the final window's.
	drag_preview = null
	if is_instance_valid(preview): preview.retain_presentation()
	_end_drag(null)
	_finish_detach.call_deferred(source, id, key, is_tab, position, preview, rectangles)
	return true


func _finish_detach(source: Node, id: int, key: String, is_tab: bool, position: Vector2i, preview: Window, rectangles: Dictionary = {}) -> void:
	var target: Node
	if is_tab:
		target = await detach_workspace(source, id, position, preview)
	else:
		target = await detach_pane(source, key, position, preview, rectangles)
	# A failed transfer or a one-pane window move does not consume the preview.
	if is_instance_valid(preview) and (not is_instance_valid(target) or target.get_window() != preview):
		preview.hide()
		preview.queue_free()


func _dock_pane(source: Node, target: Node, key: String, index: int, rectangles: Dictionary = {}) -> void:
	if await move_pane(source, target, key, -1, "", "right", true, rectangles):
		target.move_session(target.workspace_layout.active, index)


func _merge_pane(source: Node, target: Node, key: String, zone: Dictionary) -> void:
	# Regroup membership first, then publish the exact preview in one layout edit.
	# An intermediate default arrangement would race the final preview's CAS,
	# including one committed by a topology refresh during the transfer.
	var backend: RefCounted = target.session_backend
	backend.layout_batch_depth += 1
	var moved: bool = await move_pane(source, target, key, zone.tab, zone.pane, zone.edge, false)
	backend.layout_batch_depth -= 1
	if not moved or not is_instance_valid(target):
		return
	if zone.has("layout_plan"):
		target.workspace_layout.tab(zone.tab).tree = zone.layout_plan.tree
		target.workspace_view.refresh()
	else:
		target.workspace_view.set_window_rect(key, zone.rect)
	target.focus_pane(key)
	target.session_backend.commit_workspace(target)


func _drag_input(event: InputEvent, viewport: Viewport) -> void:
	if drag.is_empty(): return
	if not is_instance_valid(drag.source) or not is_instance_valid(drag.strip):
		cancel_drag()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_drag()
		viewport.set_input_as_handled()
		return
	if not event is InputEventMouse: return
	# Touch controllers forward their own synthetic mouse events. Do not also
	# consume the engine's emulated mouse stream for the same finger.
	if event.device == -1 and preload("res://scenes/input/InteractionProfile.gd").touch_controls(): return
	var point := screen_point(viewport, event.position)
	var strip: Control = drag.strip
	if drag.kind == "pane":
		# Pane moves also update the canvas model. Forward the captured event to
		# its original pane after a spring-loaded tab hides that pane's controls.
		var forwarded: InputEventMouse = event.duplicate()
		var source_viewport := strip.get_viewport()
		# The pane canvas is rendered through the world's camera, not a
		# SubViewportContainer. Use the same projection as ordinary pane input.
		forwarded.position = source_viewport.canvas_transform * drag.source.workspace_view.layout_point(point)
		forwarded.global_position = forwarded.position
		drag.source.workspace_view.pointer_screen = point
		strip._input(forwarded)
	else:
		if event is InputEventMouseMotion:
			strip.set_drag_pointer(point)
			update_drag(point)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			strip.set_drag_pointer(point)
			if not finish_drag(point): strip.commit_drag()
		else: return
	viewport.set_input_as_handled()

func schedule_drag_hover() -> void:
	drag.hover_ready = false
	if _hover_deadline == null:
		_hover_deadline = Timer.new()
		_hover_deadline.one_shot = true
		_hover_deadline.timeout.connect(func():
			if not drag.is_empty() and drag.has("pointer"):
				drag.hover_ready = true
				update_drag(drag.pointer))
		add_child(_hover_deadline)
	_hover_deadline.start(float(HOVER_PREVIEW_MS) / 1000.0)

func _stop_hover() -> void:
	if _hover_deadline != null: _hover_deadline.stop()
	if _hover_animation != null: _hover_animation.kill()

func _merge_tab_preview(source: Node, target: Node, id: int, zone: Dictionary) -> void:
	# Topology refreshes between regroup requests must not queue an intermediate
	# arrangement over the complete multi-pane drop preview.
	var backend: RefCounted = target.session_backend
	var focused: String = source.workspace_layout.tab(id).focused
	backend.layout_batch_depth += 1
	var merged: bool = await merge_workspace(source, target, id, zone.tab, zone.pane, zone.edge, false)
	backend.layout_batch_depth -= 1
	if merged and is_instance_valid(target) and zone.has("layout_plan"):
		target.workspace_layout.tab(zone.tab).tree = zone.layout_plan.tree
		target.workspace_view.refresh()
		# Applying the preview can restore the destination's previous focus.
		# Keep the carried tab's focused pane, as for a single-pane drop.
		target.focus_pane(focused)
		target.session_backend.commit_workspace(target)
