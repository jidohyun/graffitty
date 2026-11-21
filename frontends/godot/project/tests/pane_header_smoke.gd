extends "res://tests/terminal_space_smoke.gd"
## Runs with --headless, without OS input or changing the user's window focus.


func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(.5).timeout
	var id: int = host.active_session_id
	var key: String = host.pane_focus
	var model: Node = host.session_model(id)
	var pane: Control = host.workspace_view.panes[key]
	var terminal: Control = host.sessions[id].term
	var pid: int = terminal.get_shell_pid()
	var extent: Vector2 = terminal.size
	var raster: Vector2i = host.sessions[id].vp.size
	model.pin_title("Immediate title")
	check(pane.handle.text == "Immediate title", "Live title updates synchronously from the session")
	check(terminal.size == extent and host.sessions[id].vp.size == raster, "Title update preserves terminal geometry and raster")
	pane.header.set_hovered(true)
	var title_width: float = pane.header.part_rect("title").size.x
	pane.set_compact_header(true)
	check(not pane.header.has_part("filetree") and pane.header.part_rect("title").size.x > title_width, "Compact actions yield layout width to the title")
	pane.set_compact_header(false)
	check(pane.header.has_part("filetree"), "Actions return immediately without a polling refresh")
	var monitor_was_visible: bool = host.pane_status_visible
	pane._title_menu_action(1)
	check(host.pane_status_visible != monitor_was_visible, "Context-menu monitor action reaches the host controller")
	# Default docking can make the first invocation close the monitor.
	if not host.pane_status_visible: pane._title_menu_action(1)
	var monitor := preload("res://scenes/PaneStatusDialog.gd").find(host)
	var original_size: Vector2i = monitor.size
	await process_frame
	check(monitor.load_error.is_empty() and monitor.size == original_size and "readout" in monitor.view.hit_keys(), "Monitor shows the panel readout without changing the user's monitor geometry")
	check(host.switch_world("test-custom"), "World with inherited header scene loads")
	await create_timer(.3).timeout
	pane = host.workspace_view.panes[key]
	check(pane.header.scene_file_path == "res://tests/fixtures/CustomPaneHeader.tscn", "World selects its reusable pane header scene")
	check(pane.handle.get_theme_color("font_color").is_equal_approx(Color(.4, .85, 1, 1)), "Inherited header appearance is preserved")
	model.pin_title("After world switch")
	check(pane.handle.text == "After world switch", "Replacement view rebinds the existing title model")
	check(host.sessions[id].term.get_shell_pid() == pid, "Changing header presentation preserves the live shell")
	check(preload("res://scenes/PaneStatusDialog.gd").find(host) == monitor, "World changes preserve the same window-owned monitor")
	monitor._close_panel()
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
	print("PANE_HEADER_PASS" if failures.is_empty() else "PANE_HEADER_FAIL")
	quit(0 if failures.is_empty() else 1)
