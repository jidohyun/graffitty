extends Node3D
var localization: Node:
	get: return Engine.get_main_loop().root.get_node("Localization")
## Per-window workspace host. World resources are optional and loaded at runtime.
const SessionNameEdit := preload("res://scenes/session/SessionNameEdit.gd")
const API_VERSION := 1
const UserConfig := preload("res://config/UserConfig.gd")
const Paths := preload("res://graffitty/paths.gd")
const WorldConfig := preload("res://graffitty/world_config.gd")
## Built-in world paths. Mobile defaults to Flat 2D; desktop to Flat 3D.
const FLAT_3D := "flat-3d"
const FLAT_2D := "flat-2d"
const SessionModel := preload("res://scenes/TerminalSession.gd")
const UIService := preload("res://scenes/TerminalUI.gd")
const ChromiumPanel := preload("res://scenes/ChromiumPanel.gd")
const ResourceMonitor := preload("res://scenes/TerminalResourceMonitor.gd")
const HostActions := preload("res://scenes/HostActions.gd")
## View menu actions that show or hide one dockable panel, by panel name.
const PANEL_ACTIONS := {"Agents": "agents", "ResourceMonitor": "resource-monitor", "StatusLine": "status-line"}
var touch_keybar: Control
var dictation_preview: Control
var navigator := preload("res://scenes/WorkspaceNavigator.gd").new()
var prefix_commands := preload("res://scenes/WorkspacePrefix.gd").new()
var effect_control := preload("res://scenes/EffectControl.gd").new()
## This window's effects profile; it follows the window across world switches.
var effect_profiles := preload("res://scenes/EffectProfiles.gd").new(OS.get_cmdline_user_args())
var context_rules := preload("res://scenes/ContextRules.gd").new()
var pane_effect_holds := preload("res://scenes/PaneEffectHolds.gd").new()
## Effects the user switched off (status line, `ToggleEffect`): name → the
## release of its hold. Host-owned, so they survive world switches.
var effect_switches: Dictionary = {}
var command_line: CanvasLayer # Created on first use by open_command_line().
var notification_overlay: CanvasLayer
var tiling_config = UserConfig.tiling_config(OS.get_cmdline_user_args())
var power_settings = UserConfig.power_config(OS.get_cmdline_user_args())
var power: Node:
	get:
		return application.power_monitor() if application != null else null
var _spawn_directories: Dictionary[int, String] = { }
var terminal_config = UserConfig.terminal_config(OS.get_cmdline_user_args())
## Resolved client.toml bindings: the only source of shortcuts.
var bindings = UserConfig.bindings(OS.get_cmdline_user_args())
## keycode → action for direct shortcuts still held; releases and repeats
## belong to the consumed press.
var binding_held_keys: Dictionary = {}
# Touch-emulated mouse positions do not establish hover for keyboard shortcuts.
var pointer_can_hover := not OS.has_feature("android")
var resource_monitor_service: RefCounted
var agent_api: Node
var workspaces: Dictionary = { }
const WorkspaceLayout := preload("res://scenes/WorkspaceLayout.gd")
var workspace_layout := WorkspaceLayout.new()
var workspace_view: Control
var layout_transaction := false
## Scoped to drag-preview selection, including synchronous world callbacks.
var instant_workspace_switch := false
var session_switch_in_progress := false
var pane_status_visible: bool:
	get: return preload("res://scenes/PaneStatusDialog.gd").find(self) != null
	set(value):
		if value:
			preload("res://scenes/PaneStatusDialog.gd").open(self)
		else:
			var dialog := preload("res://scenes/PaneStatusDialog.gd").find(self)
			if dialog != null: dialog._close_panel()
var pane_focus := "":
	set(value):
		if pane_focus != value:
			navigator.focus_changed()
			if is_instance_valid(workspace_view): workspace_view.cancel_typing_effects()
			if is_instance_valid(world): world.cancel_typing_effects()
		pane_focus = value
		refresh_app_context()
		if application != null and application.get("mods") != null: application.mods.publish_window(self)
var world_viewport: SubViewport
var desktop_blur: Node
var world_container: SubViewportContainer
var layout_root: Control
var presentation_active := true
var _presentation_suspended := false
signal presentation_changed
const AboutDialog := preload("res://scenes/AboutDialog.gd")
var info_dialog: AboutDialog
var diagnostic_panel: Node
var _spawning_tab := -1
signal surfaces_changed(tab_id: int)
var chromiums: Dictionary = { }
var chromium_panel: Node
var chromium_split_layout := true
const UI_API_VERSION := 1
signal ui_changed
var _session_ui_pending := false
signal session_added(id: int)
signal active_session_changed(id: int)
signal session_requested(id: int)
var ui = UIService.new()
var active_session_id := -1
var _tab_definitions: Array[Dictionary] = []
var world: Node
var sessions: Dictionary = { }
var selected_session := -1
var current_plugin := ""
const MobileMenu := preload("res://scenes/input/MobileMenu.gd")
var window_menu: PanelContainer
var mobile_menu_expanded := false
var menu_layer: CanvasLayer
var popup_menus: Dictionary = { }
var native_menus: Dictionary = { }
var owned_menus: Array[RID] = []
var native_menu_items: Array[Dictionary] = []
var menu_entries: Array[Dictionary] = []
var server_chooser: Callable
var floating_controls: CanvasLayer
var mounted_packs: Dictionary[String, bool] = { }
var close_dialog: ConfirmationDialog
var application: Node
## Remote presentation reuses this host, with no local PTYs.
var session_backend: RefCounted = preload("res://scenes/session/SessionBackend.gd").new()
var restoring_window := false
var initial_surfaces: Array = []
var initial_surface: Node
var moving_window := false


func allocate_session_id() -> int:
	return application.allocate_id()


func _init() -> void:
	ui.host = self


func _ready() -> void:
	localization.changed.connect(_language_changed)
	navigator.host = self
	get_window().focus_exited.connect(navigator.focus_lost)
	prefix_commands.host = self
	prefix_commands.settings = UserConfig.prefix_config(OS.get_cmdline_user_args())
	# Arming or cancelling the prefix emits ui_changed; the status line shows it.
	ui_changed.connect(func(): if application != null and application.get("mods") != null: application.mods.publish_prefix(self))
	context_rules.rules = UserConfig.context_rules(OS.get_cmdline_user_args())
	get_window().focus_exited.connect(prefix_commands.focus_lost)
	application = get_node("/root/TerminalApplication")
	application.register_host(self)
	notification_overlay = preload("res://scenes/NotificationOverlay.gd").new()
	notification_overlay.host = self
	add_child(notification_overlay)
	get_window().files_dropped.connect(_files_dropped)
	mounted_packs = application.mounted_packs
	resource_monitor_service = application.resource_monitor_service
	agent_api = application.agent_api
	for id in workspaces:
		application.claim(id, self)
	application.checkpoints.prepare_startup(self)
	_build_workspace_layout()
	diagnostic_panel = preload("res://scenes/DiagnosticPanel.gd").new()
	add_child(diagnostic_panel)
	var plugin := current_plugin
	if not restoring_window and plugin.is_empty():
		plugin = UserConfig.world_path(OS.get_cmdline_user_args())
	if not restoring_window and power_settings.enabled and power.available:
		plugin = power_settings.battery_world if power.on_battery else power_settings.external_world
	var no_plugin := false
	for arg in ([] if restoring_window else OS.get_cmdline_user_args()):
		if arg.begins_with("--plugin="):
			plugin = UserConfig.expand_home(arg.substr(9))
		elif arg == "--no-plugin":
			no_plugin = true
	if not no_plugin:
		plugin = resolve_world(plugin)
	if no_plugin or plugin.is_empty():
		plugin = default_world()
	world = _load_plugin(plugin)
	if world == null:
		plugin = default_world()
		world = _load_plugin(plugin)
	current_plugin = plugin
	world.set("host", self)
	world.set("effect_control", effect_control)
	world.name = "World"
	_configure_terminal_space(world)
	world_viewport.add_child(world)
	print("[host] world=%s" % world.get_script().resource_path)
	desktop_blur = preload("res://scenes/DesktopBlur.gd").new()
	add_child(desktop_blur)
	desktop_blur.configure(self, UserConfig.window_config(OS.get_cmdline_user_args()))
	_restore_effect_switches()
	effect_profiles.apply(self)
	_build_menu()
	application.checkpoints.history_changed.connect(_checkpoints_changed)
	_install_world_chromium_presenter()
	if not restoring_window and OS.get_cmdline_user_args().has("--chromium"):
		create_chromium_session("", -1, true)
	if power_settings.enabled and power_settings.follow_changes:
		power.source_changed.connect(_power_source_changed)
	refresh_app_context()
	preload("res://scenes/ListDockSpace.gd").restore_open.call_deferred(self)


func refresh_app_context() -> void:
	if not is_instance_valid(world): return
	var app := {}
	var holds: Array = []
	if is_terminal_pane(pane_focus):
		var pair: Dictionary = sessions.get(int(pane_focus.substr(1)), {})
		if pair.has("model"):
			app = pair.model.foreground_app
			holds = pair.model.effect_holds
	pane_effect_holds.update(self, holds)
	context_rules.update(self, pane_focus, app)


## Release every effect hold of the focused pane on the server, whatever its scope.
func release_effect_holds() -> void:
	if not is_terminal_pane(pane_focus): return
	if not session_backend.is_remote: return
	await session_backend.connection.remote_call(int(pane_focus.substr(1)), "effects.release", {})


func settle_effects(effects: Array) -> void:
	effect_control.settle(effects)
	_expire_effect_triggers(effects)


func disable_effects(effects: Array) -> Callable:
	var release := effect_control.hold(effects)
	_expire_effect_triggers(effects)
	return release


## Whether the user's switch for `effect` is on; profiles and pane holds still apply.
func effect_enabled(effect: String) -> bool:
	return not effect_switches.has(effect)


func toggle_effect(effect: String) -> void:
	set_effect_enabled(effect, not effect_enabled(effect))


func set_effect_enabled(effect: String, enabled: bool) -> void:
	if effect not in preload("res://graffitty/effects.gd").NAMES:
		push_error("Unknown effect: " + effect)
		return
	if enabled:
		if not effect_switches.has(effect): return
		var release: Callable = effect_switches[effect]
		effect_switches.erase(effect)
		release.call()
	elif not effect_switches.has(effect):
		effect_switches[effect] = disable_effects([effect])
	UserConfig.remember(OS.get_cmdline_user_args(), {"effects": {"disabled": effect_switches.keys()}})
	if application != null and application.get("mods") != null: application.mods.publish_window(self)


## Switch off the effects that were off when the app last ran (or that
## client.toml's `[effects] disabled` names).
func _restore_effect_switches() -> void:
	var disabled = UserConfig._section(OS.get_cmdline_user_args(), "effects").get("disabled", [])
	for effect in disabled if disabled is Array else []:
		if effect in preload("res://graffitty/effects.gd").NAMES and not effect_switches.has(effect):
			effect_switches[effect] = disable_effects([effect])


func _expire_effect_triggers(effects: Array) -> void:
	if "pane_zoom" in effects and is_instance_valid(workspace_view):
		workspace_view.cancel_pane_zoom()
	# A whole typing selection can use the original activity timeout. Partial
	# selections retain shared activity and return only their selected channels.
	var typing: Array = preload("res://graffitty/effects.gd").GROUPS.typing
	if typing.all(func(name): return name == "pane_zoom" or name in effects):
		if is_instance_valid(world): world.cancel_typing_effects()


func _power_source_changed(_on_battery: bool) -> void:
	_apply_power_world.call_deferred()


func _apply_power_world() -> void:
	if is_queued_for_deletion() or not power_settings.enabled or not power.available:
		return
	switch_world(
		power_settings.battery_world if power.on_battery else power_settings.external_world
	)


## A world is a pack, `<id>.pck`, with its manifest `<id>.json` beside it.
func _plugin_manifest(path: String) -> String:
	return path.get_basename() + ".json" if path.ends_with(".pck") else ""


func _plugin_entry(path: String) -> String:
	if path == FLAT_3D:
		return "res://scenes/FlatTerminalSpaceWorld.gd"
	if path == FLAT_2D:
		return "res://scenes/Flat2DWorld.gd"
	if not path.ends_with(".pck"):
		push_warning("A world is a .pck file or a world id: %s; world not loaded" % path)
		return ""
	var manifest_path := _plugin_manifest(path)
	if not FileAccess.file_exists(manifest_path):
		push_warning("Plugin manifest missing: %s; world not loaded" % manifest_path)
		return ""
	var parser := JSON.new()
	var parse_error := parser.parse(FileAccess.get_file_as_string(manifest_path))
	if parse_error != OK or not parser.data is Dictionary:
		push_warning("Invalid plugin manifest; world not loaded")
		return ""
	var manifest: Dictionary = parser.data
	if manifest.get("api", 0) != API_VERSION:
		push_warning("Unsupported plugin API; world not loaded")
		return ""
	var entry := str(manifest.get("entry", ""))
	if not entry.begins_with("res://worlds/"):
		push_warning("Plugin entry must be under res://worlds/; world not loaded")
		return ""
	# The configured pack is the world. Packed files are read before loose
	# project files, so a linked source checkout never stands in for it, and
	# a pack never replaces host resources.
	if not mounted_packs.has(path):
		if not ProjectSettings.load_resource_pack(path, false):
			push_warning("Cannot mount plugin pack; keeping current world")
			return ""
		mounted_packs[path] = true
	# Imported scenes refer to texture UIDs as well as paths. Register only
	# missing IDs, preserving every resource already owned by the host.
	var uid_value = manifest.get("resource_uids", { })
	var uids: Dictionary = uid_value if uid_value is Dictionary else { }
	for uid_text in uids:
		var uid := ResourceUID.text_to_id(str(uid_text))
		if uid != ResourceUID.INVALID_ID and not ResourceUID.has_id(uid):
			ResourceUID.add_id(uid, str(uids[uid_text]))
	if not ResourceLoader.exists(entry):
		push_warning("Plugin entry missing: " + entry)
		return ""
	return entry


func _load_plugin(path: String) -> Node:
	var entry := _plugin_entry(path)
	return _instantiate_world(entry) if not entry.is_empty() else null


func _instantiate_world(entry: String) -> Node:
	var resource = load(entry)
	var instance: Node
	if resource is PackedScene:
		instance = resource.instantiate()
	elif resource is Script and resource.can_instantiate():
		instance = resource.new() as Node
	if instance == null:
		push_warning("Plugin entry must instantiate a Node; world not loaded")
		return null
	if not "host" in instance:
		instance.free()
		push_warning("Plugin must expose a host property; world not loaded")
		return null
	return instance


## Validate local directories only; OSC 7 may describe a remote SSH directory.
func _local_directory(value: String) -> String:
	if value.is_empty():
		return ""
	if value.begins_with("file://"):
		var slash := value.find("/", 7)
		if slash < 0:
			return ""
		var hostname := value.substr(7, slash - 7)
		if hostname not in [
			"",
			"localhost",
			OS.get_environment("HOSTNAME"),
			OS.get_environment("HOST"),
		]:
			return ""
		value = value.substr(slash).uri_decode()
		if OS.get_name() == "Windows" and value.length() > 3 and value[0] == "/" and value[2] == ":":
			value = value.substr(1)
	if value.begins_with("~/"):
		value = OS.get_environment("HOME").path_join(value.substr(2))
	value = ProjectSettings.globalize_path(value)
	return value if value.is_absolute_path() and DirAccess.dir_exists_absolute(value) else ""


func _shell_directory(terminal: Node) -> String:
	if not is_instance_valid(terminal) or terminal.is_exited():
		return ""
	var pid: int = terminal.get_shell_pid()
	if pid > 0:
		if OS.get_name() == "Linux":
			var proc := DirAccess.open("/proc/%d" % pid)
			if proc != null:
				return _local_directory(proc.read_link("cwd"))
		elif OS.get_name() == "macOS":
			# Query once when spawning, including shells without OSC 7 integration.
			var output: Array = []
			if OS.execute("/usr/sbin/lsof", ["-a", "-p", str(pid), "-d", "cwd", "-Fn"], output) == 0:
				for line in str(output[0]).split("\n"):
					if line.begins_with("n"):
						return _local_directory(line.substr(1))
	if terminal.has_method("get_ui_state"):
		return _local_directory(str(terminal.get_ui_state().get("cwd", "")))
	return ""


func terminal_start_directory(
	configured := "",
	origin: Node = null,
	explicit_origin := false,
) -> String:
	if application.initial_directory.is_empty():
		var requested := ""
		var args := OS.get_cmdline_user_args()
		for i in args.size():
			if args[i].begins_with("--cwd="):
				requested = args[i].substr(6)
			elif args[i] == "--cwd" and i + 1 < args.size():
				requested = args[i + 1]
		if (
			not requested.is_empty() and not requested.is_absolute_path()
			and not requested.begins_with("~/")
		):
			requested = Paths.launch_directory().path_join(requested).simplify_path()
		for candidate in [
			requested,
			configured,
			Paths.launch_directory(),
			Paths.expand_home("~"),
		]:
			var directory := _local_directory(candidate)
			if not directory.is_empty():
				application.initial_directory = directory
				break
	if _spawn_directories.has(_spawning_tab):
		return _spawn_directories[_spawning_tab]
	if not explicit_origin:
		origin = active_terminal()
	var inherited := _shell_directory(origin)
	if not inherited.is_empty():
		return inherited
	var initial := _local_directory(application.initial_directory)
	# If the original directory itself was deleted, use a valid home directory.
	return initial if not initial.is_empty() else _local_directory(Paths.expand_home("~"))


func active_terminal() -> Node:
	return world.get("term") if world != null else null


func show_messages() -> void:
	if diagnostic_panel != null:
		diagnostic_panel.show_history()


func session_for(index: int, presenter: Node) -> Dictionary:
	if not sessions.has(index):
		ensure_workspace(index)
		_spawning_tab = index
		sessions[index] = presenter._make_terminal()
		preload("res://scenes/TerminalViewportUpdates.gd").set_enabled(sessions[index].vp, presentation_active)
		_spawn_directories.erase(index)
		_spawning_tab = -1
		var model := SessionModel.new()
		model.name = "Session%d" % index
		model.configure(index, sessions[index].term)
		model.exited.connect(application._on_session_exited.bind(index), CONNECT_DEFERRED)
		sessions[index]["model"] = model
		application.add_child(model)
		var monitor := ResourceMonitor.new()
		monitor.name = "ResourceMonitor"
		monitor.configure(
			resource_monitor_service,
			index,
			sessions[index].term,
			presenter._merged_terminal_config(),
			session_backend.is_remote,
		)
		model.add_child(monitor)
		sessions[index]["resource_monitor"] = monitor
		model.changed.connect(_on_session_changed)
		session_added.emit(index)
		ui_changed.emit()
	return sessions[index]


func activate_session(pair: Dictionary) -> void:
	for session in sessions.values():
		var vp: SubViewport = session.vp
		var selected: bool = session.term == pair.get("term")
		preload("res://scenes/TerminalViewportInput.gd").set_disabled(vp, not selected)
		# WorkspaceView owns visibility for every pane in the current tab. Focus
		# must not disable its other panes, including when this session is already
		# active and no layout refresh follows. Standalone worlds show only one.
		if workspace_view == null:
			preload("res://scenes/TerminalViewportUpdates.gd").set_visible(vp, selected)
	var index := -1
	for key in sessions:
		if sessions[key].term == pair.get("term"):
			index = key
			break
	if active_session_id != index:
		active_session_id = index
		if index >= 0 and not layout_transaction:
			var group: int = workspace_layout.containing("%%%d" % index)
			if group >= 0:
				workspace_layout.active = group
				workspace_layout.tab(group).focused = "%%%d" % index
				pane_focus = "%%%d" % index
		_refresh_workspace_layout()
		active_session_changed.emit(index)
		ui_changed.emit()


func session_model(index: int) -> Node:
	return sessions[index].model if sessions.has(index) else null


func is_terminal_pane(key: String) -> bool:
	if not preload("res://scenes/PaneTargets.gd").valid(key): return false
	var id := int(key.substr(1))
	return not chromiums.has(id) and (sessions.has(id) or workspaces.has(id))


func is_chromium_pane(key: String) -> bool:
	return preload("res://scenes/PaneTargets.gd").valid(key) and chromiums.has(int(key.substr(1)))


func resource_monitor_for(index: int) -> Node:
	if chromiums.has(index):
		return chromiums[index].resource_monitor
	return sessions.get(index, { }).get("resource_monitor")


func active_session() -> Node:
	return session_model(active_session_id)


func set_tabs(definitions: Array[Dictionary]) -> void:
	_tab_definitions = definitions.duplicate(true)
	for definition in definitions:
		ensure_workspace(int(definition.id))
		application.claim(int(definition.id), self)
		if not layout_transaction:
			workspace_layout.ensure_terminal(int(definition.id), application.tiling_default)
	ui_changed.emit()


func get_terminal_tabs() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for definition in _tab_definitions:
		var item: Dictionary = definition.duplicate(true)
		var model := session_model(int(item.id))
		item["title"] = (
			model.title
			if model != null and not model.title.is_empty()
			else str(item.get("label", "Terminal"))
		)
		item["active"] = int(item.id) == active_session_id
		item["opened"] = model != null
		item["progress_state"] = model.progress_state if model != null else 0
		item["progress_value"] = model.progress_value if model != null else -1
		item["exited"] = model.has_exited if model != null else false
		result.append(item)
	return result


func _show_rename_dialog(caption: String, current: String, apply: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.name = "RenameDialog"
	dialog.title = caption
	dialog.ok_button_text = "Rename"
	dialog.exclusive = true
	var column := VBoxContainer.new()
	var field := LineEdit.new()
	field.name = "Title"
	field.max_length = 200
	field.text = current
	field.custom_minimum_size.x = 380
	column.add_child(field)
	var hint := Label.new()
	hint.text = "Leave empty to restore the automatic title."
	column.add_child(hint)
	dialog.add_child(column)
	add_child(dialog)
	dialog.confirmed.connect(
		func():
			apply.call(field.text),
	)
	field.text_submitted.connect(
		func(_text):
			dialog.confirmed.emit()
			dialog.hide(),
	)
	dialog.visibility_changed.connect(
		func():
			if not dialog.visible:
				dialog.queue_free(),
	)
	dialog.popup_centered()
	field.grab_focus()
	field.select_all()


func rename_pane(key: String) -> void:
	var id := int(key.substr(1))
	var model: Node = session_model(id) if self.is_terminal_pane(key) else chromiums.get(id)
	if model == null:
		return
	_show_rename_dialog(
		"Rename Pane",
		model.title,
		func(value):
			await set_pane_title(key, value),
	)


func set_pane_title(key: String, value: String) -> bool:
	var id := int(key.substr(1))
	var terminal := self.is_terminal_pane(key)
	var model: Node = session_model(id) if terminal else chromiums.get(id)
	if not is_instance_valid(model): return false
	if session_backend.is_remote:
		var params := {"title": value}
		if not terminal: params["chromium"] = key
		var response: Dictionary = await session_backend.connection.remote_call(
			id if terminal else model.tab_id,
			"window.set_title" if terminal else "chromium.set_title", params)
		if response.has("error"):
			application.notifications.post(tr("Rename Pane"), str(response.error), self, "info", 8.0, "", {"title": "Rename Pane"})
			return false
	if not is_instance_valid(model): return false
	model.pin_title(value)
	ui_changed.emit()
	workspace_view.refresh()
	return true


func rename_tab(id: int) -> void:
	var group := workspace_layout.tab(id)
	if group.is_empty():
		return
	var current := str(group.get("title", ""))
	for tab in get_tabs():
		if int(tab.id) == id:
			current = tab.title
	_show_rename_dialog(
		"Rename Tab",
		current,
		func(value):
			if workspace_layout.tab(id).is_empty():
				return
			workspace_layout.set_title(id, value)
			if session_backend.is_remote:
				session_backend.connection.remote_call(active_session_id, "tab.set_title", {"id": id, "title": value})
			ui_changed.emit(),
	)


## Tabs of the session the active tab belongs to. A window that shows several
## servers' sessions keeps each session's tabs in a strip of their own.
func session_tabs() -> Array:
	var scope: int = session_backend.session_scope(workspace_layout.active)
	return workspace_layout.tabs.filter(func(group): return session_backend.session_scope(int(group.id)) == scope)


## Every tab in the window, or only the active session's for a tab strip.
func get_tabs(session_only := false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for group in session_tabs() if session_only else workspace_layout.tabs:
		var terminals: Array = WorkspaceLayout.keys(group.tree).filter(
			func(key):
				return self.is_terminal_pane(key),
		)
		var focused: String = str(group.get("focused", ""))
		var all_keys := WorkspaceLayout.keys(group.tree)
		if focused not in all_keys and not all_keys.is_empty():
			focused = all_keys[0]
		var first: int = int(focused.substr(1)) if self.is_terminal_pane(focused) else -1
		var model := session_model(first)
		var title: String = model.title if model != null else ""
		if self.is_chromium_pane(focused):
			var chromium_id := int(focused.substr(1))
			var chromium_owner: Node = application.chromium_host(chromium_id)
			if chromium_owner != null:
				var chromium: Node = chromium_owner.chromiums[chromium_id]
				title = chromium.title if not chromium.title.is_empty() else "Chromium"
		if title.is_empty():
			title = "Terminal" if first >= 0 else "Chromium"
		var count := all_keys.size()
		var pinned := str(group.get("title", ""))
		if not pinned.is_empty():
			title = pinned
		result.append(
			{
				"id": group.id,
				"title": title,
				"label": title,
				"pinned": not pinned.is_empty(),
				"active": group.id == workspace_layout.active,
				"opened": model != null,
				"progress_state": model.progress_state if model != null else 0,
				"progress_value": model.progress_value if model != null else -1,
				"exited": false,
				"chromium_count": count - terminals.size(),
				"attention": application.agent_attention.marker(terminals) if application != null and application.agent_attention != null else {"state": "", "count": 0},
			}
		)
	return result


func get_tab_menu_items() -> Array[Dictionary]:
	var items := get_tabs(true)
	for item in items:
		var group: Dictionary = workspace_layout.tab(int(item.id))
		var keys := WorkspaceLayout.numbered_keys(group.get("tree", {}), group.get("focused", ""))
		var descriptions := PackedStringArray()
		var samples: Array = []
		var agents: Array = []
		var panes: Array[Dictionary] = []
		for key in keys:
			var id := int(key.substr(1))
			var title := pane_title(key).replace("\n", " ")
			panes.append({"key": key, "title": title, "ordinal": panes.size() + 1})
			var description := "%s — %s" % [key, title]
			if is_terminal_pane(key) and agent_api != null:
				var agent: Dictionary = agent_api.graph.public_node(key).duplicate(true)
				if str(agent.get("provider", "")) not in ["", "shell"]:
					agent.title = description
					agents.append(agent)
					description += " · %s · %s" % [str(agent.provider).capitalize(), preload("res://scenes/AgentStatusBadge.gd").status_label(str(agent.get("status", "unknown")))]
			descriptions.append(description)
			var monitor := resource_monitor_for(id)
			samples.append(monitor.snapshot() if monitor != null else {})
		item["pane_count"] = keys.size()
		item["panes"] = panes
		item["pane_tooltip"] = "\n".join(descriptions)
		item["resources"] = preload("res://scenes/TabListSummary.gd").resources(samples)
		item["agents"] = preload("res://scenes/TabListSummary.gd").agents(agents)
	return items


## A pane's title as the tab list shows it.
func pane_title(key: String) -> String:
	var id := int(key.substr(1))
	if self.is_chromium_pane(key):
		var owner: Node = application.chromium_host(id)
		return str(owner.chromiums[id].title) if owner != null else "Terminal"
	var model := session_model(id)
	if model != null and not model.title.is_empty() and not model.title_is_fallback:
		return str(model.title)
	var tab := workspace_layout.tab(workspace_layout.containing(key))
	var position := WorkspaceLayout.numbered_keys(tab.get("tree", {}), tab.get("focused", "")).find(key) + 1
	return ".%d (%s)" % [position, key] if position > 0 else key


func create_chromium_session(
	url := "",
	tab_id := -1,
	reveal := true,
	profile: Variant = null,
) -> Node:
	if tab_id < 0:
		tab_id = active_session_id
	if not workspaces.has(tab_id):
		return null
	var result: Dictionary = await session_backend.create_chromium_remote(self, tab_id, url, reveal, profile)
	if result.has("error"): return null
	var key := str(result.get("result", {}).get("chromium", ""))
	return chromiums.get(int(key.substr(1))) if self.is_chromium_pane(key) else null


func select_session(index: int) -> void:
	if chromiums.has(index):
		select_chromium_surface(index)
		return
	for item in _tab_definitions:
		if int(item.id) == index:
			if sessions.has(index) and sessions[index].term == world.term:
				activate_session(sessions[index])
				return
			session_requested.emit(index)
			return


func create_session() -> void:
	session_backend.create_tab(self)



func create_terminal_window(beside := "", axis := "h", before := false) -> void:
	session_backend.create_pane(self, beside, axis, before)



## `destination` is a position in the tab strip, which holds one session's tabs.
func move_session(id: int, destination: int) -> void:
	var strip := session_tabs()
	if not strip.is_empty() and strip.size() != workspace_layout.tabs.size():
		destination = workspace_layout.tabs.find(strip[clampi(destination, 0, strip.size() - 1)])
	workspace_layout.reorder(id, destination)
	if world != null and world.has_method("follow_tab_order"):
		world.follow_tab_order()
	ui_changed.emit()


func session_has_running_process(index: int) -> bool:
	if not sessions.has(index):
		return false
	var terminal: Node = sessions[index].term
	if OS.get_name() == "Windows":
		return terminal.has_running_child_processes()
	if terminal.is_exited():
		return false
	if not terminal.has_method("get_shell_pid") or OS.get_name() not in ["macOS", "Linux"]:
		return true # Unknown is never permission to kill silently.
	var pid: int = terminal.get_shell_pid()
	var output: Array = []
	if pid <= 0 or OS.execute("/bin/ps", ["-axo", "pid=,ppid=,stat=,comm="], output) != 0:
		return true
	var shell_found := false
	for line in str(output[0]).split("\n"):
		var fields := line.strip_edges().split(" ", false)
		if fields.size() < 4:
			continue
		if int(fields[1]) == pid and not str(fields[2]).begins_with("Z"):
			return true # Includes background and stopped jobs.
		if int(fields[0]) == pid:
			shell_found = true
			var executable := str(fields[3]).get_file().trim_prefix("-")
			if executable not in ["sh", "zsh", "bash", "fish", "dash", "ksh", "nu"]:
				return true # The shell may have exec'd an application in place.
	return not shell_found


func request_close_terminal(index := -1) -> void:
	if close_dialog != null and is_instance_valid(close_dialog):
		return
	if index < 0:
		index = active_session_id
	if not _tab_definitions.any(
		func(item):
			return int(item.id) == index,
	):
		return
	var warning := session_end_warning([index])
	if (
		warning.is_empty()
		and not session_has_running_process(index)
		and workspaces.get(index, { }).get("chromiums", []).is_empty()
	):
		_close_terminal_pane(index)
		return
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Close terminal pane?"
	close_dialog.dialog_text = tr("Close this terminal pane and its attached chromiums? Running processes and unsaved chromium state will be lost.") + warning
	close_dialog.ok_button_text = "Close Pane"
	_name_largest_close(close_dialog, [index])
	add_child(close_dialog)
	close_dialog.confirmed.connect(
		func():
			if _tab_definitions.any(
				func(item):
					return int(item.id) == index,
			):
				_close_terminal_pane(index),
	)
	close_dialog.visibility_changed.connect(
		func():
			if is_instance_valid(close_dialog) and not close_dialog.visible:
				close_dialog.queue_free()
				close_dialog = null,
	)
	close_dialog.popup_centered(Vector2i(460, 150))
	close_dialog.get_cancel_button().grab_focus()


func _close_terminal_pane(index: int) -> void:
	session_backend.close_pane(self, index)


## Extra dialog text when closing these terminals and chromiums empties their
## session: that ends the session, so always ask first.
func session_end_warning(ids: Array) -> String:
	var impact: Dictionary = session_backend.session_close_impact(ids)
	if impact.is_empty(): return ""
	var warning := tr("This closes the remaining panes in session “%s” and ends the session.") % impact.session
	return "\n\n" + warning + preload("res://scenes/session/KillSessionDialog.gd").server_close_warning(self, impact.stops_server)


func _name_largest_close(dialog: ConfirmationDialog, ids: Array) -> void:
	preload("res://scenes/session/KillSessionDialog.gd").name_largest_close(dialog, session_backend.session_close_impact(ids))


func _remove_session_mirror(index: int) -> void:
	var close_origin := _pane_close_origin("%%%d" % index)
	var group: int = workspace_layout.containing("%%%d" % index)
	for id in workspaces.get(index, { }).get("chromiums", []).duplicate():
		var owner: Node = application.chromium_host(id)
		# Remote chromium lifetime comes from topology. A filetree close can
		# detach its chromium in this same update; preserve that live mirror.
		if not session_backend.is_remote and owner == self and workspace_layout.containing("%%%d" % id) == group:
			close_chromium_session(id)
	workspace_layout.take_pane("%%%d" % index)
	workspaces.erase(index)
	application.forget(index)
	var removed: Dictionary = sessions.get(index, { })
	var surface_index := -1
	for i in world.surfaces.size():
		if int(world.surfaces[i].session_id) == index:
			surface_index = i
			break
	if surface_index < 0:
		return
	sessions.erase(index)
	if active_session_id == index: active_session_id = -1
	world.remove_terminal_tab(surface_index)
	var pane_key := "%%%d" % index
	if is_instance_valid(workspace_view) and workspace_view.panes.has(pane_key):
		workspace_view.panes[pane_key].texture.texture = null
	if not removed.is_empty():
		# Transition presentations own immutable draw state and resource references.
		for node in [removed.model, removed.vp]:
			if is_instance_valid(node): node.queue_free()
	if not layout_transaction:
		if workspace_layout.active >= 0:
			select_workspace(workspace_layout.active)
		_refresh_workspace_layout()
		_finish_pane_close(close_origin)
	ui_changed.emit()
	if not layout_transaction:
		application.retire_empty_host(self)


func close_chromium_session(index: int) -> void:
	if not chromiums.has(index):
		return
	var chromium: Node = chromiums[index]
	if session_backend.is_remote and not layout_transaction:
		chromium.close()
		return
	var close_origin := _pane_close_origin("%%%d" % index)
	var tab_id: int = chromium.tab_id
	var owner: Node = application.host_for_workspace(tab_id)
	if owner != null and owner.workspaces.has(tab_id):
		owner.workspaces[tab_id].chromiums.erase(index)
		var remaining: Array = owner.workspaces[tab_id].chromiums
		if owner.workspaces[tab_id].chromium == index:
			owner.workspaces[tab_id].chromium = remaining[0] if not remaining.is_empty() else -1
	workspace_layout.take_pane("%%%d" % index)
	chromiums.erase(index)
	if not session_backend.is_remote:
		chromium.close()
	chromium.retire()
	_refresh_workspace_layout()
	surfaces_changed.emit(tab_id)
	ui_changed.emit()
	if not layout_transaction:
		if workspace_layout.active >= 0:
			select_workspace(workspace_layout.active)
		_finish_pane_close(close_origin)
		application.retire_empty_host.call_deferred(self)


func _pane_close_origin(key: String) -> Dictionary:
	if (
		layout_transaction or workspace_view == null
		or workspace_layout.containing(key) != workspace_layout.active
	):
		return { }
	if not workspace_view.pane_rects.has(key):
		return { }
	return {
		"key": key,
		"tab": workspace_layout.active,
		"rects": workspace_view.pane_rects.duplicate(),
		"center": workspace_view.navigation_center,
		"zoom": workspace_view.navigation_zoom,
		"overview": workspace_view.overview,
		"typing_time": world.fx_last_key,
	}


func _finish_pane_close(origin: Dictionary) -> void:
	if origin.is_empty() or workspace_layout.active != origin.tab:
		return
	var tab: Dictionary = workspace_layout.tab(origin.tab)
	if tab.is_empty():
		return
	var from: Vector2 = origin.rects[origin.key].get_center()
	var nearest := ""
	var distance := INF
	for key in WorkspaceLayout.keys(tab.tree, true):
		if key == origin.key or not origin.rects.has(key):
			continue
		var candidate: float = from.distance_squared_to(origin.rects[key].get_center())
		if candidate < distance:
			nearest = key
			distance = candidate
	if nearest.is_empty():
		return
	focus_pane(nearest)
	# Settle typing effects on ordinary focus changes.
	#
	# When the focused pane closes, keep the Main View camera animation
	# running while selecting a survivor. That selection is not a typing event.
	if not origin.overview:
		world.fx_last_key = origin.typing_time
	workspace_view.pan_after_close(nearest, origin)


func ensure_workspace(tab_id: int) -> void:
	if not workspaces.has(tab_id):
		workspaces[tab_id] = { "id": tab_id, "chromiums": [], "chromium": -1, "split": 0.55 }
	if application != null:
		application.claim(tab_id, self)


func terminal_environment() -> Dictionary:
	return agent_api.environment_for(_spawning_tab) if agent_api != null and _spawning_tab >= 0 else { }


func workspace_surfaces(tab_id: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not workspaces.has(tab_id):
		return result
	if sessions.has(tab_id):
		result.append({ "id": "%%%d" % tab_id, "kind": "terminal", "tab_id": tab_id })
	for id in workspaces[tab_id].chromiums:
		var owner: Node = application.chromium_host(id)
		if owner == null:
			continue
		var chromium: Node = owner.chromiums[id]
		result.append(
			{
				"id": "%%%d" % id,
				"chromium_id": id,
				"kind": "chromium",
				"tab_id": tab_id,
				"texture": chromium.texture,
				"native_visible": chromium.native_visible,
				"exited": chromium.pid <= 0,
			}
		)
	return result


func select_chromium_surface(id: int) -> void:
	if not chromiums.has(id):
		return
	var tab_id: int = chromiums[id].tab_id
	var owner: Node = application.host_for_workspace(tab_id)
	if owner != null:
		owner.workspaces[tab_id].chromium = id
	# Choosing a chromium within a background workspace never activates that tab.
	_refresh_workspace_layout()
	ui_changed.emit()


func visible_chromium() -> Node:
	var group: Dictionary = workspace_layout.tab(workspace_layout.active)
	if group.is_empty():
		return null
	var shown := WorkspaceLayout.keys(group.tree, true)
	var preferred: int = workspaces.get(active_session_id, { }).get("chromium", -1)
	if ("%%%d" % preferred) in shown:
		return chromiums.get(preferred)
	for key in WorkspaceLayout.keys(group.tree, true):
		if self.is_chromium_pane(key):
			return chromiums.get(int(key.substr(1)))
	return null


## Presses, touches and gestures mean this window is the one in use, so a main
## view that fits its client may take the shared size back. Hovering does not.
static func _is_user_activity(event: InputEvent) -> bool:
	if event is InputEventKey:
		return event.pressed and not event.echo
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		return event.pressed
	return event is InputEventGesture


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		pointer_can_hover = false
	elif event is InputEventMouse and event.device != InputEvent.DEVICE_ID_EMULATION:
		pointer_can_hover = true
	if is_instance_valid(dictation_preview) and dictation_preview.visible: return
	if _is_user_activity(event):
		session_backend.note_activity(self)
	if touch_keybar != null and event is InputEventKey:
		touch_keybar.apply_modifiers(event)
	if event is InputEventKey and get_viewport().gui_get_focus_owner() is SessionNameEdit:
		if _zoom_hovered_panel(event): get_viewport().set_input_as_handled()
		return
	if diagnostic_panel != null and diagnostic_panel.handle_shortcut(event):
		get_viewport().set_input_as_handled()
		return
	# The tab search owns editing and navigation keys, including Select All.
	if all_tabs_open(): return
	if prefix_commands.handle(event):
		get_viewport().set_input_as_handled()
		return
	if navigator.handle(event):
		get_viewport().set_input_as_handled()
		return
	# Keys typed into the command line must not trigger window shortcuts.
	if command_line_open():
		return
	if event is InputEventKey and binding_held_keys.has(event.keycode):
		# IMEs may commit presses without releases. Only an actual release or
		# repeat belongs to the consumed shortcut; a fresh press starts anew.
		if not event.pressed or event.echo:
			var held: String = binding_held_keys[event.keycode]
			if not event.pressed:
				binding_held_keys.erase(event.keycode)
			elif held in HostActions.REPEATABLE:
				HostActions.run(self, held)
			get_viewport().set_input_as_handled()
			return
		binding_held_keys.erase(event.keycode)
	if event is InputEventKey and _zoom_hovered_panel(event):
		get_viewport().set_input_as_handled()
		return
	# Direct shortcuts run before the focused pane receives the key. Actions
	# that do not apply to the current focus leave the key to the pane.
	if event is InputEventKey and event.pressed and not event.echo:
		var action: String = bindings.direct_action(event.get_keycode_with_modifiers())
		# A focused terminal runs terminal actions from its own key table.
		var native := self.is_terminal_pane(pane_focus) and (HostActions.TERMINAL.has(action) or HostActions.FONT_SIZE.has(action))
		if not action.is_empty() and not native and _run_bound_action(action):
			binding_held_keys[event.keycode] = action
			get_viewport().set_input_as_handled()
			return
	# A 3D toolbar's offscreen viewport has no SubViewportContainer of its own.
	# Route focused address input before the world/terminal receives the event.
	if is_instance_valid(chromium_panel) and chromium_panel.has_method("handle_workspace_key"):
		if chromium_panel.handle_workspace_key(event):
			get_viewport().set_input_as_handled()
			return


func _zoom_hovered_panel(event: InputEventKey) -> bool:
	if not event.pressed or not pointer_can_hover: return false
	var action: String = bindings.direct_action(event.get_keycode_with_modifiers())
	if not HostActions.FONT_SIZE.has(action): return false
	var panel: Window = preload("res://scenes/mods/PanelWindow.gd").under_pointer(self)
	if panel == null: return false
	panel.zoom_step(HostActions.FONT_SIZE[action])
	return true


func _unhandled_key_input(event: InputEvent) -> void:
	if is_instance_valid(dictation_preview) and dictation_preview.visible:
		get_viewport().set_input_as_handled()
		return
	if not self.is_terminal_pane(pane_focus):
		return
	var pair: Dictionary = sessions.get(active_session_id, { })
	if pair.is_empty():
		return
	pair.vp.push_input(event.duplicate(), true)
	get_viewport().set_input_as_handled()


func set_chromium_presenter(presenter: Node, use_split := true) -> void:
	# Plugins supply visuals, never a replacement session/process owner.
	if presenter == null or not "host" in presenter or not presenter.has_method("refresh"):
		push_error("Chromium presenter requires host property and refresh()")
		return
	if is_instance_valid(chromium_panel) and chromium_panel != workspace_view:
		chromium_panel.queue_free()
	chromium_panel = presenter
	chromium_split_layout = use_split
	presenter.host = self
	if presenter.get_parent() == null:
		add_child(presenter)
	_refresh_workspace_layout()


## Fit the world render to the window within the GPU's texture limit.
##
## A tiling window manager can squeeze the window into a sliver that spans
## tens of thousands of logical pixels. Reduce render resolution if the
## texture would exceed the limit, so subsequent draws still work.
func _fit_world_viewport() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	# Size the final 3D compositor in backing pixels. Controls use display
	# points. On Retina, rendering only those points blurs terminal detail
	# even when the glyph and canvas textures are sharp.
	var density := get_viewport().get_final_transform().get_scale().abs()
	density = density.max(Vector2.ONE)
	world_container.scale = Vector2.ONE / density
	world_container.size = (layout_root.size * density).round()
	world_viewport.size_2d_override = Vector2i(layout_root.size.round())
	world_viewport.size_2d_override_stretch = true
	var device := RenderingServer.get_rendering_device()
	var limit := 8192.0
	if device != null:
		limit = minf(float(device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D)), 16384.0)
	var size := world_container.size
	world_container.stretch_shrink = maxi(1, ceili(maxf(size.x, size.y) / maxf(limit, 1.0)))
	_sync_world_chrome_clip()


func _sync_world_chrome_clip() -> void:
	if world_container == null:
		return
	var top := 0.0
	if is_instance_valid(workspace_view) and is_instance_valid(workspace_view.tab_bar):
		var bounds := world_container.get_global_rect()
		top = clampf((workspace_chrome_bottom() - bounds.position.y) / maxf(bounds.size.y, 1.0), 0.0, 1.0)
	# The backdrop still fills the window, including gaps between tabs. Worlds
	# clip their foreground after projection without changing input coordinates.
	if is_instance_valid(world) and world.has_method("set_workspace_clip_top"):
		world.set_workspace_clip_top(top)


func _install_world_chromium_presenter() -> void:
	# Workspace chrome is fixed in window space; chromiums keep application lifetimes.
	if workspace_view != null:
		chromium_panel = workspace_view
	_refresh_workspace_layout()


func _build_workspace_layout() -> void:
	layout_root = Control.new()
	layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(layout_root)
	world_container = SubViewportContainer.new()
	world_container.stretch = true
	world_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	world_container.set_process_input(false)
	world_container.set_process_unhandled_input(false)
	var composite := ShaderMaterial.new()
	composite.shader = preload("res://scenes/terminal_composite.gdshader")
	world_container.material = composite
	layout_root.add_child(world_container)
	world_viewport = SubViewport.new()
	world_viewport.size = Vector2i(get_viewport().get_visible_rect().size)
	world_viewport.transparent_bg = true
	world_viewport.msaa_3d = get_viewport().msaa_3d
	# Keep the 3D world isolated across presentation switches. Flat 2D disables
	# 3D rendering itself and creates no 3D cameras, meshes or lights.
	world_viewport.own_world_3d = true
	preload("res://scenes/RenderUpdates.gd").configure(world_viewport)
	world_container.add_child(world_viewport)
	layout_root.resized.connect(_fit_world_viewport)
	layout_root.visibility_changed.connect(_sync_presentation_activity)
	get_window().visibility_changed.connect(_sync_presentation_activity)
	get_window().size_changed.connect(_sync_presentation_activity)
	get_window().focus_entered.connect(_sync_presentation_activity.call_deferred)
	get_window().focus_exited.connect(_sync_presentation_activity.call_deferred)
	# Window has no mode-changed signal. On Windows, minimizing an already
	# unfocused window need not emit visibility, size or focus notifications.
	#
	# Keep this timer outside layout_root so it also detects restoration while
	# presentation is disabled, without keeping the render loop active.
	var presentation_timer := Timer.new()
	presentation_timer.wait_time = 0.25
	presentation_timer.timeout.connect(_sync_presentation_activity)
	add_child(presentation_timer)
	presentation_timer.start()
	get_viewport().size_changed.connect(_fit_world_viewport)
	# A per-monitor move can preserve the entire logical layout while changing
	# every backing texture. Read the transform after the Window applies its DPI.
	get_window().dpi_changed.connect(_fit_world_viewport, CONNECT_DEFERRED)
	get_window().dpi_changed.connect(_refresh_workspace_layout, CONNECT_DEFERRED)
	_fit_world_viewport()
	get_viewport().size_changed.connect(_refresh_workspace_layout)


func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("TerminalHost._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_presentation_suspended = true
		_sync_presentation_activity()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_presentation_suspended = false
		_sync_presentation_activity()
		repaint_all_viewports.call_deferred()
		# The platform can hand back the surface a little after the resume event.
		if is_inside_tree(): get_tree().create_timer(0.25).timeout.connect(repaint_all_viewports)


## Redraw each enabled viewport once when the app returns from the background.
## Keep hidden and suspended viewports off.
##
## The window surface may have changed size or been replaced. Until a redraw,
## a sleeping viewport can show stale or undefined pixels.
func repaint_all_viewports() -> void:
	if not is_inside_tree() or not presentation_active: return
	var render_updates := preload("res://scenes/RenderUpdates.gd")
	render_updates.before_draw(func():
		if not is_inside_tree(): return
		for viewport: SubViewport in get_window().find_children("*", "SubViewport", true, false):
			# A drawn UPDATE_ONCE viewport sleeps; writing ONCE again redraws it.
			# A sleeping DISABLED one differs from a switched-off one only in
			# its metadata.
			if viewport.render_target_update_mode == SubViewport.UPDATE_ONCE:
				viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			elif viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED \
					and viewport.get_meta("render_updates_enabled", true) \
					and preload("res://scenes/TerminalViewportUpdates.gd").is_active(viewport) \
					and not viewport.has_meta("render_updates_resume_mode"):
				# Asleep after its last draw, not switched off: wake it once.
				viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	)


func _sync_presentation_activity() -> void:
	if not is_instance_valid(layout_root) or not is_instance_valid(world_viewport) or not is_inside_tree(): return
	var window := get_window()
	# The headless display server reports every window as minimized; that is
	# not a user minimizing the workspace.
	var minimized := window.mode == Window.MODE_MINIMIZED and DisplayServer.get_name() != "headless"
	var active := not _presentation_suspended and layout_root.is_visible_in_tree() and window.visible and not minimized
	if active == presentation_active: return
	presentation_active = active
	# World/effects/chrome are presentation-only. The host and transport stay
	# alive for session topology, status and lifecycle notifications.
	layout_root.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	preload("res://scenes/RenderUpdates.gd").set_tree_enabled(world_viewport, active)
	for pair in sessions.values():
		preload("res://scenes/TerminalViewportUpdates.gd").set_enabled(pair.vp, active)
	if active: _refresh_workspace_layout()
	presentation_changed.emit()


## World authors opt in by supplying a TerminalSpace scene. No scene means no
## canvas, layout chrome, pointer interception or main-area constraints.
func _configure_terminal_space(presenter: Node) -> void:
	var scene: PackedScene = presenter.terminal_space_scene if "terminal_space_scene" in presenter else null
	if (
		workspace_view != null and scene != null
		and workspace_view.scene_file_path == scene.resource_path
	):
		return
	if is_instance_valid(chromium_panel) and chromium_panel != workspace_view:
		chromium_panel.free()
	if workspace_view != null:
		application.cancel_drag()
		for pair in sessions.values():
			pair.vp.reparent(self)
		workspace_view.canvas.free()
		workspace_view.free()
		workspace_view = null
	chromium_panel = null
	if scene != null:
		workspace_view = ui.create_terminal_space(scene)
		if workspace_view != null:
			layout_root.add_child(workspace_view)
			workspace_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sync_world_chrome_clip()


func _refresh_workspace_layout() -> void:
	if is_inside_tree() and get_window().has_meta(&"list_dock_space"):
		get_window().get_meta(&"list_dock_space").queue_reflow()
	if not presentation_active or layout_transaction or is_queued_for_deletion() or not is_inside_tree():
		return
	if workspace_view != null and workspace_view.is_inside_tree():
		workspace_view.refresh()
	elif is_instance_valid(chromium_panel):
		chromium_panel.refresh()


func _on_session_changed() -> void:
	# A transport batch can update every pane's title. Refresh shared controls
	# once after the batch; pane-specific signals still update immediately.
	if _session_ui_pending: return
	_session_ui_pending = true
	_flush_session_ui.call_deferred()


func _flush_session_ui() -> void:
	if not _session_ui_pending: return
	_session_ui_pending = false
	ui_changed.emit()


func session_count() -> int:
	return maxi(_tab_definitions.size(), sessions.size())


static func default_world() -> String:
	return FLAT_2D if OS.has_feature("mobile") else FLAT_3D


## A world value without a path separator or `.pck` suffix is a world id:
## a built-in world, or the manifest `id` of a discovered world.
static func is_world_id(value: String) -> bool:
	return not value.is_empty() and not ("/" in value or "\\" in value or value.ends_with(".pck"))


## The path to load for a configured world value, or "" for an id that no
## discovered world has. Paths and built-in ids are returned unchanged.
func resolve_world(value: String) -> String:
	if value in [FLAT_3D, FLAT_2D] or not is_world_id(value):
		return value
	for available in available_worlds():
		if available.id == value:
			return available.path
	push_warning("No installed world has id '%s'; world not loaded" % value)
	return ""


var _world_id_cache := ["", ""]


## The manifest id of the loaded world (built-ins are their own id).
func current_world_id() -> String:
	if current_plugin in [FLAT_3D, FLAT_2D]:
		return current_plugin
	if _world_id_cache[0] != current_plugin:
		var manifest = JSON.parse_string(FileAccess.get_file_as_string(_plugin_manifest(current_plugin)))
		_world_id_cache = [current_plugin, str(manifest.get("id", "")) if manifest is Dictionary else ""]
	return _world_id_cache[1]


func switch_world(path: String) -> bool:
	if path.is_empty(): path = default_world()
	path = resolve_world(path)
	if path.is_empty():
		return false
	if path == current_plugin:
		return true
	# Validate cheap metadata first; missing/bad manifests leave the live world intact.
	var entry := _plugin_entry(path)
	if entry.is_empty():
		return false
	var previous_path := current_plugin
	selected_session = int(world.active) if world != null and "active" in world else 0
	# The tabs and their windows stay as they are; only the world around them
	# changes. The same window keeps the keyboard.
	var focused := str(workspace_layout.tab(workspace_layout.active).get("focused", ""))
	activate_session({ })
	# Release scene resources before reading the next model. Instantiating first
	# held two full scenery sets at once, even though only one was visible.
	if world != null:
		world.free()
	world = null
	RenderingServer.force_sync()
	var next: Node = _instantiate_world(entry)
	var loaded := next != null
	if not loaded:
		# Shells are host-owned and survive even a malformed scene. Restore the
		# previous presentation; fall back to the platform default if it cannot load.
		next = _load_plugin(previous_path) if not previous_path.is_empty() else null
		if next == null:
			previous_path = default_world()
			next = _load_plugin(previous_path)
	world = next
	current_plugin = path if loaded else previous_path
	world.set("host", self)
	world.set("effect_control", effect_control)
	world.name = "World"
	_configure_terminal_space(world)
	application.update_frame_limit()
	world_viewport.add_child(world)
	if workspace_layout.containing(focused) >= 0:
		focus_pane(focused)
	_install_world_chromium_presenter()
	if desktop_blur != null:
		desktop_blur.apply.call_deferred()
	effect_profiles.apply(self)
	# Entries scoped to a world appear and disappear with it.
	if (window_menu != null or not native_menus.is_empty()) and UserConfig.menu_entries(OS.get_cmdline_user_args()).any(func(entry): return entry.has("world")):
		_rebuild_menu()
	else:
		_update_menu()
	return loaded


func available_worlds() -> Array[Dictionary]:
	var result: Array[Dictionary] = [
		{ "name": "Flat 3D", "path": FLAT_3D, "id": FLAT_3D },
		{ "name": "Flat 2D", "path": FLAT_2D, "id": FLAT_2D },
	]
	if OS.has_feature("mobile"):
		return result
	# Installed worlds: <data>/worlds/<id>/<id>.pck. Any other pack is
	# selected by its path in the configuration or with --plugin.
	var directory := UserConfig.stdpath("data").path_join("worlds")
	var candidates: Array[String] = []
	if DirAccess.dir_exists_absolute(directory):
		for subdir in DirAccess.get_directories_at(directory):
			var pack := directory.path_join(subdir).path_join(subdir + ".pck")
			if FileAccess.file_exists(pack):
				candidates.append(pack)
	var seen := { FLAT_3D: true, FLAT_2D: true }
	for candidate in candidates:
		var manifest_path := _plugin_manifest(candidate)
		if not FileAccess.file_exists(manifest_path):
			continue
		var parser := JSON.new()
		if (
			parser.parse(FileAccess.get_file_as_string(manifest_path)) != OK
			or not parser.data is Dictionary
		):
			continue
		var manifest: Dictionary = parser.data
		var id := str(manifest.get("id", ""))
		if manifest.get("api", 0) != API_VERSION or id.is_empty() or seen.has(id):
			continue
		seen[id] = true
		result.append(
			{
				"name": str(manifest.get("name", id.capitalize())),
				"path": candidate,
				"id": id,
				"menu": str(manifest.get("menu", "")),
			}
		)
	return result


func terminal_menu_action(action: String) -> void:
	if self.is_terminal_pane(pane_focus) and sessions.has(active_session_id):
		focus_pane(pane_focus)
		sessions[active_session_id].term.perform_action(action)


## Floating controls keep pane focus, and resize only that pane's content.
func change_text_size(direction: int) -> void:
	if self.is_chromium_pane(pane_focus):
		var id := int(pane_focus.substr(1))
		if chromiums.has(id): chromiums[id].change_text_size(direction)
	elif self.is_terminal_pane(pane_focus) and sessions.has(active_session_id) and world != null:
		world._on_terminal_shortcut("increase_font_size" if direction > 0 else ("decrease_font_size" if direction < 0 else "reset_font_size"))


## Run a direct shortcut's action through its menu entry when it has one, so
## the menu's enabled state applies; false leaves the key to the focused pane.
func _run_bound_action(action: String) -> bool:
	if action in HostActions.PARAMETERIZED:
		return false # Only the focused terminal's native key table runs these.
	for entry in menu_entries:
		if entry.action is String and entry.action == action and (entry.has("menu") or entry.has("popup")):
			_update_menu()
			var disabled: bool = (
				entry.popup.is_item_disabled(entry.index)
				if entry.has("popup")
				else NativeMenu.is_item_disabled(entry.menu, entry.index)
			)
			if disabled:
				# Session stepping owns its chord even when there is nowhere to go.
				return action in ["NextSession", "PreviousSession"]
			if not HostActions.applicable(self, action):
				return false
			_on_menu_action(entry)
			return true
	return HostActions.run(self, action)


## The key sequence shown for `action`: its first direct shortcut, else its
## prefix sequence, else "".
func shortcut_text(action: String) -> String:
	if action in HostActions.PARAMETERIZED:
		return ""
	var key: int = bindings.direct_key(action)
	if key != KEY_NONE:
		return prefix_commands.key_label(key)
	return prefix_commands.shortcut_label(action)


func close_focused_pane() -> void:
	if self.is_terminal_pane(pane_focus):
		request_close_terminal(int(pane_focus.substr(1)))
	elif self.is_chromium_pane(pane_focus):
		workspace_view.panes[pane_focus]._confirm_chromium_close()


func _workspace_menu_entries() -> Array[Dictionary]:
	var available := func(h):
		return is_instance_valid(h.workspace_view)
	var entries: Array[Dictionary] = []
	# Shortcuts and enabled states come from the shared bindings and actions.
	for spec in [
		["Shell::New Tab", "NewTab"],
		["Shell::New Chromium", "NewChromium"],
		["Shell::New Pane Right", "NewPaneRight"],
		["Shell::New Pane Left", "NewPaneLeft"],
		["Shell::New Pane Below", "NewPaneBelow"],
		["Shell::New Pane Above", "NewPaneAbove"],
		["Shell::Rename Pane…", "RenamePane"],
		["Shell::Close Pane", "ClosePane"],
		["Shell::New Window", "NewWindow"],
		["Edit::Copy", "Copy"],
		["Edit::Paste", "Paste"],
		["Edit::Find…", "Find"],
		["Edit::Copy Mode", "CopyMode"],
		["View::Overview", "Overview"],
		["View::Show All Tabs", "ShowAllTabs"],
		["View::Agents", "Agents"],
		["View::Pane Status", "PaneStatus"],
		["View::Resource Monitor", "ResourceMonitor"],
		["View::Status Line", "StatusLine"],
		["View::Messages", "Messages"],
		["View::Notifications", "Notifications"],
		["View::Fit to Pane", "FitToPane"],
		["View::Fit to Main Area", "FitToMainArea"],
	]:
		var entry := {"label": spec[0], "action": spec[1], "enabled": available}
		if spec[1] == "Notifications":
			entry.erase("enabled")
		elif spec[1] == "NewWindow":
			entry.enabled = func(_h): return not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		# A panel's entry is ticked while that panel is open in this window.
		if PANEL_ACTIONS.has(spec[1]):
			var panel_name: String = PANEL_ACTIONS[spec[1]]
			entry.checked = func(h): return preload("res://scenes/mods/PanelWindow.gd").find(h, panel_name) != null
		elif spec[1] == "PaneStatus":
			entry.checked = func(h): return h.pane_status_visible
		elif spec[1] == "Notifications":
			entry.checked = func(h): return is_instance_valid(h.notification_overlay) and h.notification_overlay.history_open()
		elif spec[1] == "Messages":
			entry.checked = func(h): return h.diagnostic_panel != null and is_instance_valid(h.diagnostic_panel.window)
		entries.append(entry)
	entries.append({
		"label": "View::Toggle Side Panels",
		"action": "ToggleSidePanels",
		"checked": func(h): return not h.get_window().get_meta(&"side_panels_hidden", false),
	})
	entries.append({
		"label": "View::Agent sounds",
		"action": func(h): h.application.agents.toggle_sounds(),
		"checked": func(h): return h.application.agents.sounds_enabled(),
	})
	if not preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		entries.append_array([
			{
				"label": "Sessions::Remote Access",
				"action": func(h): h.application.set_remote_access(not h.application.remote_access_enabled()),
				"checked": func(h): return h.application.remote_access_enabled(),
			},
			{
				"label": "Sessions::Remote Access Settings…",
				"action": func(h):
					var settings := preload("res://scenes/remote/RemoteAccessSettings.gd").new()
					settings.application = h.application
					h.add_child(settings),
			},
		])
	else:
		for option in [["One Finger", 1], ["Three Fingers", 3]]:
			var count: int = option[1]
			entries.append({
				"label": "View::Terminal Touch Scrolling::" + option[0],
				"action": func(h): h.application.set_terminal_touch_scroll_fingers(count),
				"enabled": available,
				"checked": func(h): return h.application.terminal_touch_scroll_fingers == count,
			})
	entries.append_array([
		{
			"label": "Edit::Input Settings…",
			"enabled": available,
			"action": func(h):
				var settings := preload("res://scenes/TerminalInputSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "View::Effects…",
			"enabled": available,
			"action": func(h):
				var settings := preload("res://scenes/TerminalEffectsSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "View::Appearance…",
			"enabled": available,
			"action": func(h):
				var settings := preload("res://scenes/TerminalAppearanceSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "View::Fonts…",
			"enabled": func(h):
				# Fonts apply to the local session server; a backend without a
				# connection (fixtures, early startup) has none to apply to.
				if not "connection" in h.session_backend: return false
				var connection: Node = h.session_backend.connection
				return connection != null and "url" in connection and connection.url == "shared://local",
			"action": func(h):
				var settings := preload("res://scenes/TerminalFontSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "Edit::Selection Preferences…",
			"enabled": available,
			"action": func(h):
				var settings := preload("res://scenes/TerminalSelectionSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "Edit::Terminal Bell…",
			"enabled": available,
			"action": func(h):
				var settings := preload("res://scenes/TerminalBellSettings.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "Shell::Session Defaults…",
			"action": func(h):
				var settings := preload("res://scenes/TerminalSessionDefaults.gd").new()
				settings.host = h
				h.add_child(settings),
		},
		{
			"label": "View::Floating Pane Physics",
			"action": func(h):
				if is_instance_valid(h.workspace_view):
					h.workspace_view.toggle_physics(),
			"enabled": available,
			"checked": func(h):
				return is_instance_valid(h.workspace_view) and h.workspace_view.physics_enabled(),
		},
		# Shared sessions: this device's windows either size the main area
		# whenever they are used last, or letterbox the size the server keeps.
		{
			"label": "View::Main View Size::Fit to This Window",
			"action": func(h): h.application.set_fit_main_view(true),
			"enabled": available,
			"checked": func(h): return h.application.fit_main_view,
		},
		{
			"label": "View::Main View Size::Follow Server",
			"action": func(h): h.application.set_fit_main_view(false),
			"enabled": available,
			"checked": func(h): return not h.application.fit_main_view,
		},	])
	return entries


var _cursor_trail_delay := 1


func cursor_trail_style() -> String:
	if not is_instance_valid(world) or world.get("fx_cfg") == null:
		return "off"
	var settings = world.fx_cfg.cursor_trail_settings()
	return "off" if settings.delay == 0 else settings.style


func set_cursor_trail_style(style: String) -> void:
	if style not in ["off", "smear", "blaze", "lightning"]:
		return
	if not is_instance_valid(world) or world.get("fx_cfg") == null:
		return
	var settings = world.fx_cfg.cursor_trail_settings()
	if settings.delay > 0:
		_cursor_trail_delay = settings.delay
	var delay: int = 0 if style == "off" else _cursor_trail_delay
	terminal_config.effects.cursor_trail.delay_ms = delay
	world.fx_cfg.set_option("scene.cursor_trail", "delay", delay)
	if style != "off":
		terminal_config.effects.cursor_trail.style = style
		world.fx_cfg.set_option("scene.cursor_trail", "style", style)
	if world.get("terminal_config") != null:
		world.terminal_config.effects.cursor_trail.delay_ms = delay
		if style != "off":
			world.terminal_config.effects.cursor_trail.style = style
	var remembered := {"delay_ms": delay}
	if style != "off": remembered.style = style
	UserConfig.remember(OS.get_cmdline_user_args(), {"terminal": {"effects": {"cursor_trail": remembered}}})
	for property in ["terminal_effects", "effects_2d"]:
		var renderer = world.get(property)
		if renderer != null:
			renderer.configure(world.fx_cfg)
	_update_menu()


func _cursor_trail_menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for style in ["off", "smear", "blaze", "lightning"]:
		entries.append(
			{
				"label": "View::Cursor Trail::" + style.capitalize(),
				"action": func(h):
					h.set_cursor_trail_style(style),
				"checked": func(h):
					return h.cursor_trail_style() == style,
				"enabled": func(h):
					return is_instance_valid(h.world) and h.world.get("fx_cfg") != null,
			}
		)
	return entries


func tab_transition_effect() -> String:
	if not is_instance_valid(world) or world.get("fx_cfg") == null or world.tab_fx_disabled:
		return "none"
	return str(world.fx_cfg.scene.tab_switch.effect)


func set_tab_transition_effect(effect: String) -> void:
	if effect not in ["none", "push_pull"]:
		return
	if not is_instance_valid(world) or world.get("fx_cfg") == null:
		return
	world.tab_fx_disabled = false
	world.fx_cfg.set_option("scene.tab_switch", "effect", effect)
	preload("res://graffitty/world_config.gd").remember(world, {"tab_switch": {"effect": effect}})
	world._fx_apply_scene()
	_update_menu()


func set_session_transition_effect(effect: String) -> void:
	if effect not in ["none", "fly_away_and_in", "fly_away"] or not is_instance_valid(world): return
	world.fx_cfg.set_option("scene.session_switch", "effect", effect)
	preload("res://graffitty/world_config.gd").remember(world, {"session_switch": {"effect": effect}})
	_update_menu()

func _session_transition_menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for option in [["None", "none"], ["Fly away and in", "fly_away_and_in"], ["Fly away", "fly_away"]]:
		var effect: String = option[1]
		entries.append({
			"label": "View::Session Transition::" + option[0],
			"action": func(h): h.set_session_transition_effect(effect),
			"checked": func(h): return is_instance_valid(h.world) and h.world.fx_cfg.scene.session_switch.effect == effect,
			"enabled": func(h): return is_instance_valid(h.world) and h.world.get("fx_cfg") != null,
		})
	return entries


func set_effects_profile(name: String) -> void:
	effect_profiles.select(self, name)
	if effect_profiles.selected == name:
		UserConfig.remember(OS.get_cmdline_user_args(), {"effects": {"profile": name}})
	_update_menu()
	if application != null and application.mods != null: application.mods.publish_window(self)


func _effects_profile_menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for name in effect_profiles.names():
		var profile := name
		entries.append({
			"label": "View::Effects Profile::" + effect_profiles.label(profile),
			"literal_label": not effect_profiles.is_builtin(profile),
			"action": func(h): h.set_effects_profile(profile),
			"checked": func(h): return h.effect_profiles.selected == profile,
			"enabled": func(h): return is_instance_valid(h.world) and h.world.get("fx_cfg") != null,
		})
	return entries


func _tab_transition_menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for option in [["None", "none"], ["Push/Pull", "push_pull"]]:
		var effect: String = option[1]
		entries.append({
			"label": "View::Tab Transition::" + option[0],
			"action": func(h): h.set_tab_transition_effect(effect),
			"checked": func(h): return h.tab_transition_effect() == effect,
			"enabled": func(h): return is_instance_valid(h.world) and h.world.get("fx_cfg") != null,
		})
	return entries


## Configured entries replace built-ins by label, or by world target.
## Sessions are grouped by live,
## remote, and saved sessions; the menu bar and command line share this list.
func menu_entry_specs() -> Array[Dictionary]:
	var entries := UserConfig.menu_entries(OS.get_cmdline_user_args())
	# An entry with `world` exists only while that world is active.
	var world_id := current_world_id()
	entries = entries.filter(func(entry): return str(entry.get("world", world_id)) == world_id)
	entries = merge_menu_entries(entries, _workspace_menu_entries() + _world_menu_entries() + _cursor_trail_menu_entries() + _tab_transition_menu_entries() + _session_transition_menu_entries() + _effects_profile_menu_entries() + navigator.menu_entries() + preload("res://scenes/session/LiveSessionMenu.gd").entries(self) + application.checkpoints.menu_entries() + localization.menu_entries())
	if not entries.any(
		func(entry):
			return entry.label == "Help::Info",
	):
		entries.append({ "label": "Help::Info", "action": "Info" })
	# A bound action shows its first direct shortcut as the accelerator.
	for entry in entries:
		# A SendText key and a SendText menu entry carry different texts.
		if entry.action is String and entry.action not in HostActions.PARAMETERIZED:
			var key: int = bindings.direct_key(entry.action)
			if key != KEY_NONE:
				entry.shortcut = preload("res://graffitty/terminal_config.gd").KeyBinding.new(key, "").key
	return preload("res://scenes/session/LiveSessionMenu.gd").order(entries)


static func merge_menu_entries(configured: Array[Dictionary], builtins: Array[Dictionary]) -> Array[Dictionary]:
	var entries := configured.duplicate()
	for entry in builtins:
		if entries.any(func(existing):
			return existing.label == entry.label or (
				entry.action is String and entry.action == "SwitchWorld"
				and existing.action is String and existing.action == "SwitchWorld"
				and existing.path == entry.path
			)):
			continue
		entries.append(entry)
	for entry in entries:
		if entry.action is String and entry.action == "SwitchWorld": entry.literal_label = true
	return entries


func _world_menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for available in available_worlds():
		entries.append({
			"label": "View::World::" + str(available.name),
			"action": "SwitchWorld",
			"path": available.path,
			"literal_label": true,
		})
	return entries


var live_sessions_menu_signature := ""

func refresh_sessions_menu() -> void:
	var profiled_started := Time.get_ticks_usec()
	refresh_sessions_menu_body()
	preload("res://graffitty/frame_profile.gd").add("TerminalHost.refresh_sessions_menu", Time.get_ticks_usec() - profiled_started)


func refresh_sessions_menu_body() -> void:
	if window_menu == null and native_menus.is_empty(): return
	var signature := preload("res://scenes/session/LiveSessionMenu.gd").signature(self)
	if signature == live_sessions_menu_signature: return
	_rebuild_menu()
	if command_line_open(): command_line._on_ui_changed()


func _language_changed() -> void:
	# On macOS only the host that currently owns the global menu rebuilds it.
	# Background windows rebuild with the new language when focused later.
	if window_menu != null or not native_menus.is_empty():
		_rebuild_menu()
	if command_line_open(): command_line._on_ui_changed()


var menu_rebuild_pending := false

## Rebuild the menu after every native menu it touches has closed.
## Native menus reject edits while open with "Can't remove open menu!".
func _rebuild_menu() -> void:
	if _native_menu_open():
		if menu_rebuild_pending: return
		menu_rebuild_pending = true
		get_tree().create_timer(0.2).timeout.connect(_retry_menu_rebuild)
		return
	menu_rebuild_pending = false
	_remove_menu()
	_build_menu()


func _retry_menu_rebuild() -> void:
	menu_rebuild_pending = false
	if not is_inside_tree() or is_queued_for_deletion(): return
	if window_menu == null and native_menus.is_empty(): return
	_rebuild_menu()


func _native_menu_open() -> bool:
	if not NativeMenu.has_feature(NativeMenu.FEATURE_GLOBAL_MENU): return false
	var main := NativeMenu.get_system_menu(NativeMenu.MAIN_MENU_ID)
	if NativeMenu.has_menu(main) and NativeMenu.is_opened(main): return true
	for menu in owned_menus:
		if NativeMenu.has_menu(menu) and NativeMenu.is_opened(menu): return true
	for item in native_menu_items:
		if NativeMenu.has_menu(item.menu) and NativeMenu.is_opened(item.menu): return true
	return false


func _menu_leaf(entry: Dictionary) -> String:
	var source := str(entry.label).split("::")[-1]
	return source if entry.get("literal_label", false) else tr(source)


func _build_menu() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if window_menu != null:
		return
	if not native_menus.is_empty():
		# Stale RIDs (menus freed elsewhere) must not block every later rebuild.
		if native_menus.values().all(
			func(menu):
				return NativeMenu.has_menu(menu),
		):
			return
		_remove_menu()
	if NativeMenu.has_feature(NativeMenu.FEATURE_GLOBAL_MENU):
		for other in application.hosts:
			if other != self:
				other._remove_menu()
	menu_entries = menu_entry_specs()
	live_sessions_menu_signature = preload("res://scenes/session/LiveSessionMenu.gd").signature(self)
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls() or not NativeMenu.has_feature(NativeMenu.FEATURE_GLOBAL_MENU):
		_build_window_menu()
		return
	var main := NativeMenu.get_system_menu(NativeMenu.MAIN_MENU_ID)
	for entry in menu_entries:
		var parts: PackedStringArray = entry.label.split("::")
		var parent := main
		var prefix := ""
		for depth in parts.size() - 1:
			prefix += ("::" if depth > 0 else "") + parts[depth]
			if not native_menus.has(prefix):
				var submenu := RID()
				for index in NativeMenu.get_item_count(parent):
					if NativeMenu.get_item_text(parent, index) == tr(parts[depth]):
						submenu = NativeMenu.get_item_submenu(parent, index)
						break
				if not submenu.is_valid() or not NativeMenu.has_menu(submenu):
					submenu = NativeMenu.create_menu()
					owned_menus.append(submenu)
					var index := NativeMenu.add_submenu_item(parent, tr(parts[depth]), submenu)
					var tag := "graffitty:%d:%s" % [get_instance_id(), prefix]
					NativeMenu.set_item_tag(parent, index, tag)
					native_menu_items.append({ "menu": parent, "tag": tag })
				native_menus[prefix] = submenu
			parent = native_menus[prefix]
		var index: int
		match ("callback" if entry.action is Callable else entry.action):
			"SwitchWorld", "SetWorldSetting":
				index = NativeMenu.add_radio_check_item(
					parent,
					_menu_leaf(entry),
					_on_menu_action,
					Callable(),
					entry,
				)
			"Separator":
				index = NativeMenu.add_separator(parent)
			_:
				if entry.get("checked", Callable()).is_valid():
					index = NativeMenu.add_check_item(
						parent,
						_menu_leaf(entry),
						_on_menu_action,
						Callable(),
						entry,
					)
				else:
					index = NativeMenu.add_item(
						parent,
						_menu_leaf(entry),
						_on_menu_action,
						Callable(),
						entry,
					)
		var key: InputEventKey = entry.get("shortcut")
		if key != null:
			NativeMenu.set_item_accelerator(parent, index, key.get_keycode_with_modifiers())
		entry["menu"] = parent
		entry["index"] = index
		native_menu_items.append({ "menu": parent, "tag": entry })
	_update_menu()


func _sync_window_menu_visibility() -> void:
	if not is_instance_valid(menu_layer): return
	menu_layer.visible = layout_root.is_visible_in_tree()
	if not menu_layer.visible:
		preload("res://scenes/input/WorkspaceMenus.gd").dismiss(self)


func _build_window_menu() -> void:
	if menu_entries.is_empty() or window_menu != null:
		return
	menu_layer = CanvasLayer.new()
	menu_layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.MENU
	add_child(menu_layer)
	if not layout_root.visibility_changed.is_connected(_sync_window_menu_visibility):
		layout_root.visibility_changed.connect(_sync_window_menu_visibility)
	_sync_window_menu_visibility()
	var floating_ui := preload("res://scenes/input/InteractionProfile.gd").touch_controls() or OS.get_name() in ["Windows", "Linux"]
	var floating = MobileMenu.new() if floating_ui else null
	window_menu = floating if floating_ui else PanelContainer.new()
	if not floating_ui: window_menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	menu_layer.add_child(window_menu)
	var bar: HBoxContainer
	if floating_ui:
		bar = floating.buttons
		floating.expanded_changed.connect(func(value: bool): mobile_menu_expanded = value)
	else:
		bar = HBoxContainer.new()
		window_menu.add_child(bar)
	for entry in menu_entries:
		var parts: PackedStringArray = entry.label.split("::")
		var parent: PopupMenu
		var prefix := ""
		for depth in parts.size() - 1:
			prefix += ("::" if depth > 0 else "") + parts[depth]
			if not popup_menus.has(prefix):
				var popup: PopupMenu
				if depth == 0:
					var button := MenuButton.new()
					if floating_ui:
						floating.add_menu(button, parts[depth])
					else:
						button.text = parts[depth]
						button.switch_on_hover = true
						bar.add_child(button)
					popup = button.get_popup()
				else:
					popup = PopupMenu.new()
					popup.name = "Submenu%d" % popup_menus.size()
					parent.add_child(popup)
					parent.add_submenu_item(parts[depth], popup.name)
				popup.prefer_native_menu = not floating_ui and OS.get_name() == "Windows"
				popup.about_to_popup.connect(_update_menu)
				popup.id_pressed.connect(_on_popup_action.bind(popup))
				popup_menus[prefix] = popup
			parent = popup_menus[prefix]
		var index := parent.item_count
		var action: String = "callback" if entry.action is Callable else entry.action
		if action == "Separator":
			parent.add_separator()
		elif action in ["SwitchWorld", "SetWorldSetting"]:
			parent.add_radio_check_item(_menu_leaf(entry), index)
		elif entry.get("checked", Callable()).is_valid():
			parent.add_check_item(_menu_leaf(entry), index)
		else:
			parent.add_item(_menu_leaf(entry), index)
		var key: InputEventKey = entry.get("shortcut")
		if key != null:
			parent.set_item_accelerator(index, key.get_keycode_with_modifiers())
		if entry.get("literal_label", false):
			parent.set_item_auto_translate_mode(index, Node.AUTO_TRANSLATE_MODE_DISABLED)
		entry["popup"] = parent
		entry["index"] = index
	if floating_ui:
		floating.set_expanded(mobile_menu_expanded, false)
	else:
		window_menu.resized.connect(_resize_menu_content)
	_resize_menu_content.call_deferred()
	_update_menu()


func _resize_menu_content() -> void:
	if layout_root == null:
		return
	if window_menu is MobileMenu:
		layout_root.offset_top = 0.0
		window_menu.top = workspace_chrome_bottom() + 8.0
		window_menu.reflow()
		_refresh_workspace_layout()
		return
	var menu_height := window_menu.size.y if is_instance_valid(window_menu) and window_menu.visible else 0.0
	if OS.get_name() in ["Windows", "Linux"]:
		layout_root.offset_top = 0.0
		var tab_bottom := 0.0
		if is_instance_valid(workspace_view) and is_instance_valid(workspace_view.tab_bar):
			var bar: Control = workspace_view.tab_bar
			if bar.is_visible_in_tree(): tab_bottom = bar.get_global_rect().end.y
		if is_instance_valid(window_menu): window_menu.position.y = tab_bottom
		if is_instance_valid(workspace_view): workspace_view._sync_foreground_clip()
		_sync_world_chrome_clip()
	else:
		layout_root.offset_top = menu_height
	_refresh_workspace_layout()


func workspace_chrome_bottom() -> float:
	var bottom := 0.0
	if is_instance_valid(workspace_view) and is_instance_valid(workspace_view.tab_bar):
		var bar: Control = workspace_view.tab_bar
		if bar.is_visible_in_tree(): bottom = bar.get_global_rect().end.y
	if is_instance_valid(window_menu) and window_menu.is_visible_in_tree() and not window_menu is MobileMenu:
		bottom = maxf(bottom, window_menu.get_global_rect().end.y)
	return bottom


func _on_popup_action(id: int, popup: PopupMenu) -> void:
	var index := popup.get_item_index(id)
	for entry in menu_entries:
		if entry.get("popup") == popup and entry.index == index:
			_on_menu_action(entry)
			return


func _on_menu_action(entry: Variant) -> void:
	if is_instance_valid(dictation_preview) and dictation_preview.visible: return
	if all_tabs_open(): return
	_run_menu_action.call_deferred(entry)


func _run_menu_action(entry: Dictionary) -> void:
	if entry.action is Callable:
		if entry.action.is_valid():
			entry.action.call(self)
	elif entry.action == "SwitchWorld":
		switch_world(entry.path)
	elif entry.action == "SetWorldSetting":
		set_world_setting(str(entry.world), str(entry.setting), entry.value)
	elif entry.action != "Separator":
		HostActions.run(self, entry.action, entry)
	if is_inside_tree() and not is_queued_for_deletion():
		_update_menu()


func show_info() -> void:
	if info_dialog == null:
		info_dialog = AboutDialog.new()
		add_child(info_dialog)
	info_dialog.present()


func _on_world_selected(path: Variant) -> void:
	# Native menu callbacks must return before modifying the scene tree.
	switch_world.call_deferred(str(path))


## Whether a menu command is currently `enabled` and `checked`.
func menu_entry_state(entry: Dictionary) -> Dictionary:
	var checked := false
	var enabled := true
	var check_callback: Callable = entry.get("checked", Callable())
	var enable_callback: Callable = entry.get("enabled", Callable())
	# A callback that fails returns null; `bool(null)` is not a conversion.
	if check_callback.is_valid():
		var value: Variant = check_callback.call(self)
		checked = value != null and bool(value)
	if enable_callback.is_valid():
		var value: Variant = enable_callback.call(self)
		enabled = value != null and bool(value)
	if entry.action is Callable:
		pass
	elif entry.action == "SwitchWorld":
		var path: String = entry.path if not entry.path.is_empty() else default_world()
		checked = path == current_plugin or (is_world_id(path) and path == current_world_id())
	elif entry.action == "SetWorldSetting":
		enabled = str(entry.world) == current_world_id()
		checked = enabled and WorldConfig.setting_is(world, str(entry.setting), entry.value)
	return { "enabled": enabled, "checked": checked }


## Set one of the active world's [worlds.<id>] settings, as a SetWorldSetting
## menu entry does. Does nothing unless `world_id` is the active world.
func set_world_setting(world_id: String, setting: String, value: Variant) -> bool:
	if world_id != current_world_id() or not is_instance_valid(world): return false
	var error := WorldConfig.set_setting(world, setting, value)
	if not error.is_empty():
		push_warning("[worlds.%s] %s = %s was not applied: %s" % [world_id, setting, value, error])
		return false
	return true


func _update_menu() -> void:
	for entry in menu_entries:
		if entry.action is String and entry.action == "Separator": continue
		if not entry.has("menu") and not entry.has("popup"):
			continue
		var state := menu_entry_state(entry)
		var checked: bool = state.checked
		var enabled: bool = state.enabled
		if entry.has("popup"):
			if _has_sequence_hint(entry):
				entry.popup.set_item_text(entry.index, _hinted_menu_label(entry))
			entry.popup.set_item_checked(entry.index, checked)
			entry.popup.set_item_disabled(entry.index, not enabled)
		else:
			if not NativeMenu.has_menu(entry.menu):
				continue
			if _has_sequence_hint(entry):
				NativeMenu.set_item_text(entry.menu, entry.index, _hinted_menu_label(entry))
			NativeMenu.set_item_checked(entry.menu, entry.index, checked)
			NativeMenu.set_item_disabled(entry.menu, entry.index, not enabled)


## Actions without a direct shortcut show their prefix sequence in the label,
## which a menu cannot show as an accelerator.
func _has_sequence_hint(entry: Dictionary) -> bool:
	return entry.action is String and not entry.has("shortcut") and not prefix_commands.shortcut_label(entry.action).is_empty()


func _hinted_menu_label(entry: Dictionary) -> String:
	var label: String = _menu_leaf(entry)
	var shortcut: String = prefix_commands.shortcut_label(entry.action) if entry.action is String else ""
	return label if shortcut.is_empty() else "%s (%s)" % [label, shortcut]


func _exit_tree() -> void:
	if moving_window:
		return
	pane_effect_holds.clear()
	context_rules.clear()
	if application != null:
		application.unregister_host(self)
	for pair in sessions.values():
		if is_instance_valid(pair.model):
			pair.model.queue_free()
	for chromium in chromiums.values():
		if is_instance_valid(chromium):
			var owner: Node = application.host_for_workspace(chromium.tab_id)
			if owner != null and owner != self and owner.workspaces.has(chromium.tab_id):
				var associated: Dictionary = owner.workspaces[chromium.tab_id]
				associated.chromiums.erase(chromium.session_id)
				if associated.chromium == chromium.session_id:
					associated.chromium = (
						associated.chromiums[0]
						if not associated \
								.chromiums \
								.is_empty()
						else -1
					)
				owner.ui_changed.emit()
			if not session_backend.is_remote:
				chromium.close()
			chromium.queue_free()
	_remove_menu()


func _remove_menu() -> void:
	if menu_layer != null:
		menu_layer.queue_free()
		menu_layer = null
		window_menu = null
		popup_menus.clear()
		_resize_menu_content()
	# Remove only our entries, including when appended to an existing OS menu.
	for i in range(native_menu_items.size() - 1, -1, -1):
		var item := native_menu_items[i]
		if not NativeMenu.has_menu(item.menu):
			continue
		var index := NativeMenu.find_item_index_with_tag(item.menu, item.tag)
		if index >= 0:
			NativeMenu.remove_item(item.menu, index)
	for i in range(owned_menus.size() - 1, -1, -1):
		if NativeMenu.has_menu(owned_menus[i]):
			NativeMenu.free_menu(owned_menus[i])
	native_menu_items.clear()
	owned_menus.clear()
	native_menus.clear()
	menu_entries.clear()


func take_workspace(id: int, chromium_keys: Array[String] = []) -> Dictionary:
	# Transfer is deliberately separate from close: no revocation or PTY kill.
	var index := -1
	for i in _tab_definitions.size():
		if int(_tab_definitions[i].id) == id:
			index = i
	# Tabs change places in the world, so find the surface by its terminal.
	var surface_index := -1
	for i in world.surfaces.size():
		if int(world.surfaces[i].session_id) == id:
			surface_index = i
	var payload := {
		"id": id,
		"definition": _tab_definitions[index].duplicate(true),
		"workspace": workspaces[id],
		"session": sessions.get(id, { }),
		"chromiums": { },
		"surface": world.surfaces[surface_index].duplicate(),
	}
	for chromium_id in workspaces[id].chromiums:
		if (
			not chromiums.has(chromium_id)
			or (not chromium_keys.is_empty() and not ("%%%d" % chromium_id) in chromium_keys)
		):
			continue
		var chromium: Node = chromiums[chromium_id]
		chromium.changed.disconnect(_on_session_changed)
		payload.chromiums[chromium_id] = chromium
		chromiums.erase(chromium_id)
	if sessions.has(id):
		sessions[id].model.changed.disconnect(_on_session_changed)
		sessions.erase(id)
	workspace_layout.take_pane("%%%d" % id)
	for chromium_id in payload.chromiums:
		workspace_layout.take_pane("%%%d" % chromium_id)
	workspaces.erase(id)
	if active_session_id == id:
		active_session_id = -1
	world.remove_terminal_tab(surface_index)
	_refresh_workspace_layout()
	ui_changed.emit()
	return payload


func receive_workspace(payload: Dictionary) -> void:
	var id: int = payload.id
	workspaces[id] = payload.workspace
	_tab_definitions.append(payload.definition)
	if not payload.session.is_empty():
		sessions[id] = payload.session
		payload.session.vp.reparent(terminal_viewport_parent())
		_adopt_terminal_viewport(payload.session.vp)
		payload.session.model.changed.connect(_on_session_changed)
		# This window's client takes over the terminal's input.
		session_added.emit(id)
	for chromium_id in payload.chromiums:
		var chromium: Node = payload.chromiums[chromium_id]
		chromiums[chromium_id] = chromium
		chromium.connection = session_backend.connection
		chromium.changed.connect(_on_session_changed)
	if application != null:
		application.claim(id, self)
	if not layout_transaction:
		workspace_layout.ensure_terminal(id, application.tiling_default)
		for chromium_id in payload.chromiums:
			workspace_layout.merge(id, WorkspaceLayout.leaf("%%%d" % chromium_id, false))


## Put terminal viewports under the workspace canvas so they draw first.
## Until the canvas exists, keep them under the host.
##
## A pane moved from a parked host can arrive paused and show stale pixels.
## Set its render state to match this host. A Sessions panel drop preview
## is one way the source host becomes parked.
func _adopt_terminal_viewport(vp: SubViewport) -> void:
	var stale: bool = vp.get_meta("render_updates_enabled", true) != presentation_active or vp.has_meta("render_updates_resume_mode")
	if stale: preload("res://scenes/RenderUpdates.gd").set_tree_enabled(vp, presentation_active)
	preload("res://scenes/TerminalViewportUpdates.gd").set_enabled(vp, presentation_active)


func terminal_viewport_parent() -> Node:
	if (
		workspace_view != null and workspace_view.is_node_ready()
		and workspace_view.canvas.is_inside_tree()
	):
		return workspace_view.canvas
	return self


func detach_session(id := -1) -> void:
	application.detach_workspace(self, workspace_layout.active if id < 0 else id)


func request_close_window() -> void:
	if session_backend.is_remote:
		get_parent().request_close_window()
		return
	if close_dialog != null:
		return
	var confirm := not chromiums.is_empty()
	for id in sessions:
		if session_has_running_process(id):
			confirm = true
	if not confirm:
		close_window()
		return
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = "Close window?"
	close_dialog.dialog_text = "Close all workspaces in this window? Running processes and unsaved chromium state will be lost."
	close_dialog.ok_button_text = "Close Window"
	add_child(close_dialog)
	close_dialog.confirmed.connect(close_window)
	close_dialog.visibility_changed.connect(
		func():
			if is_instance_valid(close_dialog) and not close_dialog.visible:
				close_dialog.queue_free()
				close_dialog = null,
	)
	close_dialog.popup_centered(Vector2i(460, 150))
	close_dialog.get_cancel_button().grab_focus()


func close_window() -> void:
	# Teardown once, without navigating through (and spawning) unopened tabs.
	for id in workspaces:
		application.forget(id)
	_tab_definitions.clear()
	workspace_layout.tabs.clear()
	application.retire_empty_host(self)


func _files_dropped(files: PackedStringArray) -> void:
	if all_tabs_open() or command_line_open(): return
	for child in get_window().find_children("*", "Window", true, false):
		if (child is AcceptDialog or child is Popup) and child.visible: return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is RichTextLabel: return
	if not self.is_terminal_pane(pane_focus):
		return
	var target := active_terminal()
	if target == null:
		return
	if not str(target.get_ui_state().get("modal", "")).is_empty(): return
	var shell: String = session_model(active_session_id).shell.replace("\\", "/").get_file().to_lower().trim_suffix(".exe")
	var quoted := PackedStringArray()
	for path in files:
		quoted.append("'" + path.replace("'", "''" if shell in ["pwsh", "powershell"] else "'\"'\"'") + "'")
	target.paste_text(" ".join(quoted))


func select_workspace(id: int, instant := false) -> void:
	var group: Dictionary = workspace_layout.tab(id)
	if group.is_empty():
		return
	var previous_instant := instant_workspace_switch
	instant_workspace_switch = previous_instant or instant
	workspace_layout.active = id
	var key: String = group.focused
	var shown := WorkspaceLayout.keys(group.tree, true)
	if shown.is_empty():
		var retained := WorkspaceLayout.keys(group.tree)
		if retained.is_empty():
			# A close acknowledgement can briefly precede the owner's tab removal.
			instant_workspace_switch = previous_instant
			return
		key = retained[0]
		WorkspaceLayout.find(group.tree, key).shown = true
	elif not key in shown:
		key = shown[0]
	focus_pane(key)
	_refresh_workspace_layout()
	ui_changed.emit()
	instant_workspace_switch = previous_instant


## Shows a hidden pane in its tab, as select_workspace does, then focuses it.
func reveal_pane(key: String) -> void:
	var group: int = workspace_layout.containing(key)
	if group < 0:
		return
	var window := WorkspaceLayout.find(workspace_layout.tab(group).tree, key)
	if not window.get("shown", true):
		window.shown = true
	if group != workspace_layout.active:
		select_workspace(group)
	focus_pane(key)


## Configurable menu/prefix action for the tab bar's down-arrow popup.
func open_tab_menu() -> void:
	if not is_instance_valid(workspace_view): return
	if command_line_open(): command_line.dismiss()
	prefix_commands.cancel()
	workspace_view.tab_bar.navigation.toggle()


func all_tabs_open() -> bool:
	return is_instance_valid(workspace_view) and is_instance_valid(workspace_view.tab_bar) and workspace_view.tab_bar.navigation.menu.visible


## Opens the prefix command line (scenes/CommandLine.gd) with `text` typed.
func open_command_line(text := "") -> void:
	if all_tabs_open(): workspace_view.tab_bar.navigation.menu.hide()
	if command_line == null:
		command_line = preload("res://scenes/CommandLine.gd").new()
		command_line.host = self
		add_child(command_line)
	command_line.open(text)


func command_line_open() -> bool:
	return command_line != null and command_line.visible


func focus_pane(key: String) -> void:
	# Focus moved elsewhere (an agent, a new pane): the terminal takes the
	# keyboard and IME back, so the command line must not stay open.
	if command_line_open():
		command_line.dismiss()
	if all_tabs_open(): workspace_view.tab_bar.navigation.menu.hide()
	var group: int = workspace_layout.containing(key)
	if group < 0:
		return
	workspace_layout.active = group
	workspace_layout.tab(group).focused = key
	pane_focus = key
	if workspace_view != null:
		workspace_view.raise_window(key)
	if self.is_terminal_pane(key):
		select_session(int(key.substr(1)))
		var pair: Dictionary = sessions.get(int(key.substr(1)), { })
		if not pair.is_empty():
			pair.term.grab_focus()
	elif self.is_chromium_pane(key):
		# A browser-focused tab still needs to navigate its workspace sheet.
		# Preserve browser focus while binding the terminal that carries it;
		# about:blank has no bearing on whether this is an animated tab switch.
		var carrier: int = world._first_terminal(workspace_layout.tab(group))
		if carrier >= 0 and world._surface_for_session(carrier) != world.active:
			var previous_transaction := layout_transaction
			layout_transaction = true
			select_session(carrier)
			layout_transaction = previous_transaction
			pane_focus = key
			workspace_layout.active = group
			workspace_layout.tab(group).focused = key
	_refresh_workspace_layout()
	ui_changed.emit()


func toggle_pane_status() -> void:
	pane_status_visible = not pane_status_visible
	_refresh_workspace_layout()


func request_close_session() -> void:
	if close_dialog != null: return
	var peer := preload("res://scenes/session/LiveSessionMenu.gd").transport(self)
	if peer == null: return
	var dialog := preload("res://scenes/session/KillSessionDialog.gd").open(get_window(), peer, peer.workspace)
	if dialog == null: return
	close_dialog = dialog
	dialog.tree_exited.connect(func(): close_dialog = null)


func request_close_tab(index := -1) -> void:
	var id: int = workspace_layout.active if index < 0 else index
	var group: Dictionary = workspace_layout.tab(id)
	if group.is_empty() or close_dialog != null:
		return
	var keys := WorkspaceLayout.keys(group.tree)
	var needs_confirmation := false
	for key in keys:
		needs_confirmation = (
			needs_confirmation or self.is_chromium_pane(key)
			or session_has_running_process(int(key.substr(1)))
		)
	var warning := session_end_warning(keys.map(func(key): return int(str(key).substr(1))))
	if not needs_confirmation and warning.is_empty():
		_close_group(id)
		return
	close_dialog = ConfirmationDialog.new()
	close_dialog.title = 'Close tab?'
	close_dialog.dialog_text = tr('Close all terminals and chromiums in this tab? Running processes and unsaved chromium state will be lost.') + warning
	close_dialog.ok_button_text = 'Close Tab'
	_name_largest_close(close_dialog, keys.map(func(key): return int(str(key).substr(1))))
	add_child(close_dialog)
	preload("res://scenes/DialogActionStyle.gd").apply(close_dialog.get_ok_button(), Color("ad3434"))
	close_dialog.confirmed.connect(_close_group.bind(id))
	close_dialog.visibility_changed.connect(
		func():
			if is_instance_valid(close_dialog) and not close_dialog.visible:
				close_dialog.queue_free()
				close_dialog = null,
	)
	close_dialog.popup_centered(Vector2i(480, 160))
	close_dialog.get_cancel_button().grab_focus()


func _close_group(id: int) -> void:
	session_backend.close_tab(self, id)



func select_next_workspace(step := 1) -> void:
	var items: Array = session_tabs()
	if items.is_empty():
		return
	var current := 0
	for i in items.size():
		if items[i].id == workspace_layout.active:
			current = i
	select_workspace(items[wrapi(current + step, 0, items.size())].id)


## Cmd+1…8 select that tab; Cmd+9 always selects the last one, as in chromiums.
## A missing tab leaves the selection unchanged.
func select_numbered_tab(key: int) -> void:
	var items := session_tabs()
	var last: int = items.size() - 1
	var index: int = last if key == KEY_9 else key - KEY_1
	if index >= 0 and index <= last:
		select_workspace(items[index].id)


## Public configuration callbacks; all windows in this application are captured.
func save_checkpoint(tag := "manual", quit_after_save := false) -> void:
	application.checkpoints.menu_action(
		self,
		{ "action": "SaveCheckpointAndQuit" if quit_after_save else "SaveCheckpoint", "tag": tag },
	)


## Restore one saved checkpoint file into new windows.
func restore_checkpoint(tag: String, checkpoint: String) -> void:
	application.checkpoints.menu_action(
		self,
		{ "action": "RestoreCheckpoint", "tag": tag, "checkpoint": checkpoint },
	)


## Checkpoint submenus list live history; rebuild when it changes.
func _checkpoints_changed() -> void:
	if window_menu != null or not native_menus.is_empty():
		_rebuild_menu()


func create_native_window() -> void:
	if world == null or close_dialog != null:
		return
	await application.open_session_window(self)
