extends "res://scenes/remote/RemoteClient.gd"
## Normal desktop startup is a view of the same durable server used by Slint.
var opening_local_terminal := false
var closing_local_workspace := false
## An additional launcher window supplies its own arguments and directory.
var launch_args: Variant = null
var launch_directory := ""

func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args() if launch_args == null else launch_args
	var config_errors := preload("res://config/UserConfig.gd").validate_startup(args)
	if not config_errors.is_empty():
		for error in config_errors: printerr("Configuration error: " + error)
		get_tree().quit(2)
		return
	if "--check-config" in args:
		var config = preload("res://config/UserConfig.gd").terminal_config(args)
		var window = preload("res://config/UserConfig.gd").window_config(args)
		print(JSON.stringify({"valid": true, "font_size": config.font_size, "font_paths": config.compiled_font_paths(), "max_fps": window.max_fps, "inactive_max_fps": window.inactive_max_fps}))
		get_tree().quit(0)
		return
	var spawn := preload("res://scenes/session/SpawnPreferences.gd").options(args, launch_directory)
	settings = {"shared_local": true, "workspace": "main", "capabilities": {"spawn": spawn, "new_session": true}}
	var world := preload("res://config/UserConfig.gd").world_path(args)
	var power = preload("res://config/UserConfig.gd").power_config(args)
	if power.enabled:
		var monitor: Node = get_node("/root/TerminalApplication").power_monitor()
		if monitor.available: world = power.battery_world if monitor.on_battery else power.external_world
	if not world.is_empty(): settings.startup_world = world
	for argument in args:
		if argument.begins_with("--plugin="):
			settings.startup_world = preload("res://config/UserConfig.gd").expand_home(argument.trim_prefix("--plugin="))
		elif argument == "--no-plugin": settings.startup_world = ""
	if spawn.has("shell"): settings.shell = spawn.shell
	if spawn.has("cwd"): settings.directory = spawn.cwd
	for argument in args:
		if argument.begins_with("--session-connection="):
			settings.descriptor = argument.trim_prefix("--session-connection=")
		elif argument.begins_with("--workspace="):
			settings.workspace = argument.trim_prefix("--workspace=")
			settings.capabilities.erase("new_session")
		elif argument == "--attach-session":
			settings.capabilities.require_workspace = true
		elif argument.begins_with("--shell="):
			settings.shell = argument.trim_prefix("--shell=")
		elif argument.begins_with("--working-directory="):
			settings.directory = argument.trim_prefix("--working-directory=")
	for argument in args:
		if not argument.begins_with("--restore-checkpoint="): continue
		var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(argument.trim_prefix("--restore-checkpoint=")))
		if saved is Dictionary and saved.get("version") == 1 and not saved.get("windows", []).is_empty() and not saved.windows[0].get("panes", []).is_empty():
			settings.workspace = "restore-" + Crypto.new().generate_random_bytes(12).hex_encode()
			settings.capabilities.erase("new_session")
			settings.restore_seed = true
			settings.startup_world = str(saved.windows[0].get("plugin", ""))
			var owners: Array = saved.windows[0].panes.filter(func(pane): return not pane.has("filetree"))
			if not owners.is_empty():
				settings.capabilities.spawn.merge(preload("res://scenes/Checkpoints.gd").spawn_options(owners[0]), true)
				# The session's first pane is the restore's first pane.
				settings.capabilities.saved = preload("res://scenes/Checkpoints.gd").saved_identity(saved, owners[0], true)
	# Choose a session for the first window.
	#
	# 1. Reuse the last session shown by a frontend, as recorded by the server.
	# 2. If there is no remembered session, reuse the oldest one.
	# 3. If the server has no sessions, start one.
	#
	# `--new-session` and additional windows start a fresh session.
	if launch_args == null and settings.capabilities.get("new_session", false) and not "--new-session" in args:
		settings.workspace = ""
		settings.capabilities.erase("new_session")
		settings.capabilities.workspace_fallback = true
	connection.authenticated.connect(func(): opening_local_terminal = false)
	if settings.capabilities.get("new_session", false):
		host_ready.connect(func():
			host.session_backend.apply_new_tab_gap.call_deferred(weakref(host), host.workspace_layout.active, host.tiling_config.gap), CONNECT_ONE_SHOT)
	super._ready()
	get_window().title = "Graffitty"

func _refresh() -> void:
	if transferring or closing_window: return
	# Recover an empty workspace only on initial attachment. Once presented,
	# closing its last pane/tab retires the window instead of spawning a shell.
	if connection.connected and connection.topology.tabs.is_empty():
		dialog.hide()
		if host != null:
			if not closing_local_workspace:
				closing_local_workspace = true
				detach.call_deferred()
			return
		if not opening_local_terminal:
			opening_local_terminal = true
			_open_local_terminal.call_deferred()
		return
	opening_local_terminal = false
	super._refresh()

func _open_local_terminal() -> void:
	if not connection.connected or not connection.topology.tabs.is_empty():
		opening_local_terminal = false
		return
	var spawn: Dictionary = settings.get("capabilities", {}).get("spawn", {}).duplicate(true)
	var response: Dictionary = await connection.request_action("create", {"kind": "tab", "spawn": spawn})
	if response.get("type") == "error":
		opening_local_terminal = false
		var message := "Could not open local terminal: " + str(response.get("message", "Unknown error"))
		_status(message)
		push_error(message)

func detach() -> void:
	connection.disconnect_remote()
	# Detach this window without destroying the server's shells or other windows.
	if host != null:
		host.application.retire_empty_host(host, true)
	else:
		super.detach()
