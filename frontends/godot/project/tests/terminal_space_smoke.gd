extends SceneTree
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Commands := preload("res://scenes/TilingCommands.gd")
var failures: Array[String] = []


class ErrorWatch extends Logger:
	var errors: Array[String] = []


	func _log_error(
		_function: String,
		_file: String,
		_line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		_error_type: int,
		_backtraces: Array[ScriptBacktrace],
	) -> void:
		errors.append(rationale if not rationale.is_empty() else code)


	func _log_message(_message: String, _error: bool) -> void:
		pass


var error_watch := ErrorWatch.new()


class TestHost extends "res://scenes/TerminalHost.gd":
	func _plugin_entry(path: String) -> String:
		if path == "test-custom":
			return "res://tests/fixtures/CustomSpaceWorld.gd"
		if path == "test-basic":
			return "res://tests/fixtures/BasicTerminalWorld.gd"
		return super._plugin_entry(path)


func check(value: bool, message: String) -> void:
	print(("PASS " if value else "FAIL ") + message)
	if not value:
		failures.append(message)


func _initialize() -> void:
	OS.add_logger(error_watch)
	var isolated := OS.get_cache_dir().path_join("terminal-space-test-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated.path_join("config"))
	OS.set_environment("XDG_STATE_HOME", isolated.path_join("state"))
	_start_test.call_deferred()


func _start_test() -> void:
	# Headless display initialization otherwise resets _initialize's size to
	# 64x64, below the minimum height where the workspace creates its panes.
	root.size = Vector2i(1280, 800)
	run()


func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(0.5).timeout
	check(host.workspace_view != null, "Bundled Flat explicitly installs TerminalSpace")
	check(not host.workspace_view.toolbar.visible, "Default workspace has no view toolbar")
	# Save entries are static actions; the Resume submenus are per-checkpoint callables.
	for entry in host.application.checkpoints.menu_entries().filter(func(item): return item.action is String):
		var matches := host.menu_entries.filter(func(item): return item.label == entry.label)
		check(matches.size() == 1, "Fresh config exposes %s exactly once" % entry.label)
		if matches.size() == 1:
			check(matches[0].action == entry.action, "Default snapshot menu dispatches %s" % entry.action)
			check(matches[0].get("tag", "manual") == entry.get("tag", "manual"), "Default snapshot menu uses the correct history")
	for entry in host._workspace_menu_entries():
		if not entry.label.begins_with("View::"): continue
		check(entry.enabled.call(host), "View action enabled for TerminalSpace")
	var first: String = host.pane_focus
	var terminal_id := int(first.substr(1))
	var pid: int = host.sessions[terminal_id].term.get_shell_pid()
	var response := Commands.dispatch(
		host,
		terminal_id,
		"tiling.layout",
		{ "layouts": ["h_tiles"] },
	)
	check(response.has("result") and response.result.tiling, "CLI enables horizontal tiles")
	Commands.dispatch(host, terminal_id, "tiling.new-window", { })
	await create_timer(0.2).timeout
	var second: String = host.pane_focus
	Commands.dispatch(host, terminal_id, "tiling.new-window", { })
	await create_timer(0.2).timeout
	var third: String = host.pane_focus
	Commands.dispatch(host, terminal_id, "tiling.focus", { "direction": "left" })
	check(host.pane_focus == second, "Directional focus picks the adjacent tile")
	Commands.dispatch(host, terminal_id, "tiling.join-with", { "direction": "right" })
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	check(
		group.tree.tiles.axis == "h" and group.tree.tiles.children[1].axis == "v",
		"Join-with creates AeroSpace's opposite-axis group",
	)
	Commands.dispatch(host, terminal_id, "tiling.move", { "direction": "down" })
	check(
		host.workspace_view.pane_rects[second].position.y
		> host.workspace_view.pane_rects[third].position.y,
		"Move down places the focused tile after its neighbor",
	)
	var before: Dictionary = group.tree.duplicate(true)
	response = Commands.dispatch(
		host,
		terminal_id,
		"tiling.layout",
		{ "layouts": ["floating", "invalid"] },
	)
	check(
		response.has("error") and group.tree == before,
		"Invalid layout lists make no partial mutation",
	)
	Commands.dispatch(host, terminal_id, "tiling.view", { "mode": "overview" })
	check(host.workspace_view.overview, "CLI opens Overview")
	Commands.dispatch(host, terminal_id, "tiling.view", { "mode": "main" })
	check(not host.workspace_view.overview, "CLI returns to Main")
	var stash := Rect2(-800, 100, 500, 400)
	Layout.place(group.tree, third, stash, host.workspace_view.content_rect())
	host.workspace_view.refresh()
	before = group.tree.duplicate(true)
	check(host.world_viewport.msaa_3d == Viewport.MSAA_4X, "World geometry has 4x MSAA")
	var scenery := SubViewport.new()
	var ink := SubViewport.new()
	host.world._configure_scenery_antialiasing(scenery, host.world_viewport)
	host.world._configure_ink_antialiasing(ink)
	check(
		scenery.msaa_3d == Viewport.MSAA_4X and ink.msaa_3d == Viewport.MSAA_DISABLED,
		"Scenery inherits MSAA while terminal ink stays unblurred",
	)
	scenery.free()
	ink.free()
	host.tiling_config.gap = 24.0
	host.workspace_view.refresh()
	var gap_tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(gap_tree.tiling_gap == 24.0, "Configured gap reaches live layout")
	host.tiling_config.gap = 8.0
	host.workspace_view.refresh()
	check(host.switch_world("test-basic"), "Basic world loads")
	await create_timer(0.3).timeout
	check(
		host.workspace_view == null,
		"Basic world has no canvas, tiling controls or main-area view",
	)
	for entry in host._workspace_menu_entries():
		if not entry.label.begins_with("View::"): continue
		check(not entry.enabled.call(host), "View action disabled for basic world")
	check(
		not host.world._floating(),
		"Basic terminal is rendered independently of workspace layout",
	)
	check(
		Commands.dispatch(host, terminal_id, "tiling.layout", { "layouts": ["tiles"] }).get("error", { }).get(
			"code"
		)
		== "unsupported_layout",
		"CLI cannot opt an unwilling world into tiling",
	)
	check(host.sessions[terminal_id].term.get_shell_pid() == pid, "Opting out preserves the shell")
	check(host.switch_world(""), "Return to full TerminalSpace")
	await create_timer(0.3).timeout
	check(
		host.workspace_view != null and group.tree == before,
		"Opting back in restores tiling and stash state",
	)
	check(
		host.workspace_view.pane_rects[third].is_equal_approx(stash),
		"Stashed pane placement survives a basic world",
	)
	check(host.switch_world("test-custom"), "World opts into a customized TerminalSpace scene")
	await create_timer(0.2).timeout
	check(
		host.workspace_view.tab_bar == host.workspace_view.get_node("MyTabs"),
		"Scene-authored tab strip is bound automatically",
	)
	check(
		host.workspace_view.tile_button == host.workspace_view.get_node("MyTile"),
		"Scene-authored tiling button is wired automatically",
	)
	host.workspace_view.tile_button.pressed.emit()
	check(not group.tree.tiling, "Custom button uses the shared layout controller")
	var view: Control = host.workspace_view
	check(
		view.split_right_button == view.get_node("MySplitRight"),
		"Custom split-right button is wired",
	)
	check(
		view.split_down_button == view.get_node("MySplitDown"),
		"Custom split-down button is wired",
	)
	group.tree["physics"] = false
	host.focus_pane(third)
	view.refresh()
	var count_before := Layout.keys(group.tree).size()
	check(
		not view.split_right_button.disabled and not view.split_down_button.disabled,
		"Stashed panes can create floating neighbors",
	)
	view.split_window("h")
	check(Layout.keys(group.tree).size() == count_before + 1, "Stash split creates one floating neighbor")
	check(Layout.find(group.tree, host.pane_focus).get("stashed", false), "Stash neighbor remains outside managed tiles")
	check(view.pane_rects[third].is_equal_approx(stash), "Splitting preserves the original stash position")
	count_before = Layout.keys(group.tree).size()
	host.focus_pane(first)
	view.split_right_button.pressed.emit()
	var right: String = host.pane_focus
	check(
		not group.tree.tiling and Layout.keys(group.tree).size() == count_before + 1,
		"Right split preserves floating mode and creates exactly one pane",
	)
	check(
		view.pane_rects[right].position.x > view.pane_rects[first].position.x,
		"New pane appears to the right",
	)
	view.split_down_button.pressed.emit()
	var below: String = host.pane_focus
	check(Layout.keys(group.tree).size() == count_before + 2, "Down split creates exactly one pane")
	check(
		view.pane_rects[below].position.y > view.pane_rects[right].position.y,
		"New pane appears below",
	)
	check(
		host.sessions[terminal_id].term.get_shell_pid() == pid,
		"Directional splits preserve existing shell",
	)
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
	print("TERMINAL_SPACE_PASS" if failures.is_empty() else "TERMINAL_SPACE_FAIL")
	quit(0 if failures.is_empty() else 1)
