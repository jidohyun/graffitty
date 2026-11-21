extends "input-routing.gd"

func _initialize() -> void:
	var fixture_home := OS.get_environment("XDG_CONFIG_HOME")
	super._initialize()
	OS.set_environment("XDG_CONFIG_HOME", fixture_home)

func play() -> void:
	if OS.get_environment("GRAFFITTY_CONFIG_TABS_ONLY") == "1":
		await verify_new_tab()
		return
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var term: Node = host.active_terminal()
	var original_id: int = host.active_session_id
	var pid: int = term.get_shell_pid()
	check(pid > 0, "Configured startup owns a live shell")
	check(app.max_fps == 73 and app.inactive_max_fps == 19, "Startup retains automatic and explicit FPS settings")
	check(term.get_live_font_size() == 23, "Owner-configured font size reaches first renderer")
	check(is_equal_approx(host.tiling_config.gap, 31.0), "Configured gap reaches workspace controls")
	check(host.world.get_script().resource_path.contains("bistro"), "Configured Bistro world selected at startup")
	var receipt := directory.path_join("shell.json")
	var command := "[ordered]@{ cwd=(Get-Location).Path; literal=$env:ACCEPTANCE_LITERAL_CONFIG; pid=$PID } | ConvertTo-Json -Compress | Set-Content -LiteralPath '%s' -Encoding utf8" % receipt.replace("'", "''")
	await type(command + "{enter}")
	if check(await wait_file(receipt), "Actual shell writes configured cwd/environment receipt"):
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(receipt).trim_prefix("\ufeff"))
		check(data.cwd.replace("\\", "/").to_lower() == directory.path_join("configured cwd").replace("\\", "/").to_lower(), "First shell starts in explicit configured cwd")
		check(data.literal == "$(Write-Output MUST_NOT_EXECUTE); café 한글", "Environment value stays literal inside shell")
		check(int(data.pid) == pid, "Receipt identifies original shell process")
	host.create_terminal_window("", "h")
	var deadline := Time.get_ticks_msec() + 10000
	while host.sessions.size() != 2 and Time.get_ticks_msec() < deadline: await process_frame
	if not check(host.sessions.size() == 2, "Subsequent split creates independent shell"): return
	await camera_at_rest()
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	check(is_equal_approx(float(group.tree.tiling_gap), 31.0), "Actual shared layout preserves configured gap after split")
	var canonical: Dictionary = host.session_backend.connection.topology.workspace_state.layout.tabs[str(group.id)]
	check(is_equal_approx(float(canonical.gap), 31.0), "Owner acknowledges configured gap in canonical layout")
	term = host.active_terminal()
	check(term.get_live_font_size() == 23 and term.get_shell_pid() != pid, "New split uses configured default font with independent PID")
	check(host.sessions[original_id].term.get_shell_pid() == pid, "Startup and split preserve original shell")
	overlay.hide()
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("configured-startup.png"))

func verify_new_tab() -> void:
	var original: int = host.workspace_layout.active
	var pid: int = host.active_terminal().get_shell_pid()
	await camera_at_rest()
	var saved: Dictionary = host.session_backend.connection.topology.workspace_state.layout.tabs[str(original)].duplicate(true)
	host.world.create_terminal_tab()
	var deadline := Time.get_ticks_msec() + 10000
	while host.workspace_layout.active == original and Time.get_ticks_msec() < deadline: await process_frame
	check(host.workspace_layout.active != original, "New tab becomes active")
	await camera_at_rest()
	var next: Dictionary = host.session_backend.connection.topology.workspace_state.layout.tabs[str(host.workspace_layout.active)]
	check(is_equal_approx(float(next.gap), 31.0), "New tab commits configured gap to owner")
	check(host.active_terminal().get_live_font_size() == 23, "New tab retains configured font default")
	check(host.session_backend.connection.topology.workspace_state.layout.tabs[str(original)] == saved, "New tab preserves previous tab layout")
	check(host.sessions[original].term.get_shell_pid() == pid, "New tab preserves previous shell PID")
