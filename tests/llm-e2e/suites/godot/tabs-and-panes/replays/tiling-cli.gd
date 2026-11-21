extends "main-area-tiling.gd"


func cli(command: String) -> void:
	var marker := OS.get_environment("XDG_STATE_HOME").path_join("tiling-cli-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if OS.get_name() == "Windows":
		await type("& $env:GRAFFITTY_BIN tiling %s > $null; [IO.File]::WriteAllText('%s', [string]$LASTEXITCODE){enter}" % [command, marker.replace("'", "''")])
	else:
		await type('"$GRAFFITTY_BIN" tiling ' + command + " > /dev/null; printf '%s' $? > '" + marker + "'{enter}")
	var deadline := Time.get_ticks_msec() + 10000
	while not FileAccess.file_exists(marker) and Time.get_ticks_msec() < deadline:
		await process_frame
	var ok := FileAccess.file_exists(marker) and FileAccess.get_file_as_string(marker).strip_edges() == "0"
	check(ok, "CLI finishes successfully: " + command)
	if not ok:
		print("CLI_FAILURE ", command, " ", host.workspace_layout.tab(host.workspace_layout.active).tree, " focus=", host.pane_focus)
		print("CLI_TERMINAL ", host.active_terminal().get_text(false).get("text", ""))
	DirAccess.remove_absolute(marker)
	await process_frame


func play() -> void:
	await label_tab(0, "CLI")
	await camera_at_rest()
	# Exact placement is tested with collision responses explicitly disabled.
	if host.workspace_view.physics_enabled():
		await view_menu("Floating Pane Physics")
	var first: String = host.pane_focus
	var caller := int(first.substr(1))
	var pid: int = host.sessions[caller].term.get_shell_pid()
	await say("CLI: horizontal tiles, then two new windows")
	await cli("layout h_tiles")
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	check(group.tree.get("tiling", false), "The real CLI enables tiling")
	await cli("new-window")
	await cli("new-window")
	check(Layout.keys(group.tree).size() == 3, "CLI creates three live panes in one tab")
	await say("CLI: split vertically, then open the fourth pane")
	await cli("split vertical")
	await cli("new-window")
	var bottom: String = host.pane_focus
	await cli("focus up")
	var top: String = host.pane_focus
	check(top != bottom, "Directional CLI focus reaches the upper neighbor")
	await cli("join-with left")
	var view: Control = host.workspace_view
	var joined: Rect2 = view.pane_rects[top]
	await cli("move up")
	check(host.pane_focus == top, "Moving keeps keyboard focus on the same pane")
	check(view.pane_rects[top].position.y < joined.position.y, "Moving up places the pane before its joined neighbor")
	check_tiles()
	await say("CLI: toggle floating and tiling without losing panes")
	var positions: Dictionary = view.pane_rects.duplicate()
	await cli("layout floating tiling")
	check(
		not group.tree.tiling and positions == view.pane_rects,
		"Floating preserves all visible rectangles",
	)
	await cli("layout floating tiling")
	check(group.tree.tiling, "The same layout command toggles back to tiling")
	await cli("layout horizontal vertical")
	check(group.tree.tiles.axis == "v", "Layout cycles root orientation")
	await cli("balance-sizes")
	await say("CLI: Overview, then Main")
	await cli("view overview")
	check(view.overview, "CLI shows Overview")
	await cli("view main")
	check(not view.overview, "CLI returns to Main")
	var state: Dictionary = await app.agent_api.dispatch(caller, "tiling.status", { })
	check(state.get("result", { }).get("panes", []).size() == 4, "Status reports all four panes")
	await open_tabs(2)
	var active: int = host.workspace_layout.active
	var rejected: Dictionary = await app.agent_api.dispatch(
		caller,
		"tiling.layout",
		{ "layouts": ["floating"] },
	)
	check(
		rejected.get("error", { }).get("code") == "inactive_tab"
		and host.workspace_layout.active == active,
		"An inactive tab cannot steal focus or change layout",
	)
	check(
		host.sessions[caller].term.get_shell_pid() == pid,
		"The original shell survives every CLI operation",
	)
