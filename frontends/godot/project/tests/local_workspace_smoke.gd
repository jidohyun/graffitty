extends SceneTree
## Production startup, live typing camera and last-pane/tab lifecycle.
var failures: Array[String] = []
var checks: Array[Dictionary] = []
var report: Dictionary = {}

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks.append({"status": "PASS" if value else "FAIL", "name": message})
	if not value: failures.append(message)

func save_report() -> void:
	report.merge({"failures": failures, "checks": checks}, true)
	var file := FileAccess.open(OS.get_environment("GRAFFITTY_TEST_REPORT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))

func key(code: Key, character := 0, command := false, alt := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = character
	# Exercise the host's Command+W / Command+Option+W close routing.
	event.meta_pressed = command
	event.alt_pressed = alt
	event.pressed = true
	root.push_input(event)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event)

func run() -> void:
	root.size = Vector2i(1280, 800)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	check(wrapper.host != null, "production startup creates a host")
	if wrapper.host == null:
		save_report()
		quit(1)
		return
	var host: Node = wrapper.host
	var view: Control = host.workspace_view
	var world: Node = host.world
	var border_seen := false
	var overview_seen := false
	deadline = Time.get_ticks_msec() + 1000
	while Time.get_ticks_msec() < deadline:
		border_seen = border_seen or view.boundary.visible
		overview_seen = overview_seen or view.overview
		await process_frame
	check(not border_seen and not overview_seen, "startup stays in Main View with its border hidden in every frame")
	check(view.content_rect().is_equal_approx(view.viewport_content_rect()), "local Main View uses the full available window area")
	var term: Node = host.active_terminal()
	report.shell_pid = term.get_shell_pid()
	var identity_receipt := OS.get_environment("GRAFFITTY_TEST_PROCESS_RECEIPT")
	if not identity_receipt.is_empty():
		save_report()
		deadline = Time.get_ticks_msec() + 15000
		while not FileAccess.file_exists(identity_receipt) and Time.get_ticks_msec() < deadline:
			await process_frame
		check(FileAccess.file_exists(identity_receipt), "Harness retains original shell process identity before closure")
	if DisplayServer.get_name() != "headless":
		term.send_text("i=0; while [ $i -lt 16 ]; do printf 'DEPTH %02d   ABCDEFGHIJKLMNOPQRSTUVWXYZ   0123456789\\n' $i; i=$((i+1)); done\n")
		deadline = Time.get_ticks_msec() + 5000
		while "DEPTH 15" not in term.get_text(false).text and Time.get_ticks_msec() < deadline: await process_frame
		check("DEPTH 15" in term.get_text(false).text, "terminal contains the depth-of-field text fixture")
		await create_timer(.3).timeout
		var rest_basis: Basis = world.cam.global_basis
		# Real GUI key events must reach both the server's PTY and typing effects.
		term.grab_focus()
		for character in "printf TYPING_CAMERA":
			key(KEY_NONE, character.unicode_at(0))
			await create_timer(.05).timeout
		await create_timer(.25).timeout
		check("printf TYPING_CAMERA" in term.get_text(false).text, "GUI typing reaches the server-owned terminal")
		check(world.fx_typing > .5, "GUI typing activates the effects state")
		var rotation := rest_basis.get_rotation_quaternion().angle_to(world.cam.global_basis.get_rotation_quaternion())
		check(rotation > .01, "fitted Main View renders camera tilt while typing")
		check(world.ink_active and world.ink_dof != null and world.terminal_effects.screen_dof, "terminal depth-of-field compositor is active")
		check(world.terminal_effects.blur_radius > 1.0 and world.terminal_dof_weight > .9, "typing enables terminal depth-of-field blur")
		report.camera_rotation_degrees = rad_to_deg(rotation)
		report.blur_radius = world.terminal_effects.blur_radius
		# Freeze the camera and compare real compositor pixels with blur on/off.
		# Sample the middle rows, away from the blinking cursor and particles.
		var previous_mode: int = world.process_mode
		world.process_mode = Node.PROCESS_MODE_DISABLED
		await RenderingServer.frame_post_draw
		var blurred := root.get_texture().get_image()
		var directory := OS.get_environment("GRAFFITTY_TEST_REPORT").get_base_dir()
		blurred.save_png(directory.path_join("typing.png"))
		world.ink_dof.enabled = false
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var sharp := root.get_texture().get_image()
		sharp.save_png(directory.path_join("typing-without-dof.png"))
		var difference := 0.0
		var samples := 0
		for y in range(int(sharp.get_height() * .3), int(sharp.get_height() * .65), 2):
			for x in range(int(sharp.get_width() * .12), int(sharp.get_width() * .5), 2):
				var a := blurred.get_pixel(x, y)
				var b := sharp.get_pixel(x, y)
				difference += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
				samples += 3
		report.dof_pixel_difference = difference / maxf(samples, 1)
		check(report.dof_pixel_difference > .002, "depth-of-field changes rendered text pixels at the same camera pose")
		world.ink_dof.enabled = true
		world.process_mode = previous_mode
		# Clear the unexecuted command through the PTY before closing.
		term.send_text(String.chr(21))
	view.show_overview()
	await create_timer(.5).timeout
	check(view.boundary.visible, "zooming out reveals the Main View border")
	view.show_main()
	await create_timer(.1).timeout
	check(not view.boundary.visible, "returning to Main View hides the border")
	view._begin_navigation()
	view.navigation_zoom = float(view.main_frame().zoom) * 1.5
	view._apply_navigation()
	await create_timer(.1).timeout
	check(view.boundary.visible, "zoomed-in navigation shows the Main View border")
	var main: Dictionary = view.main_frame()
	view.navigation_zoom = main.zoom
	view.navigation_center = main.center + Vector2(100, 0)
	view._apply_navigation()
	await create_timer(.1).timeout
	check(view.boundary.visible, "same-zoom panning shows the Main View border")
	view.navigation_center = main.center
	view._apply_navigation()
	await create_timer(.1).timeout
	check(not view.boundary.visible, "matching both Main pan and zoom hides the border even in navigation mode")
	view.show_main()
	await check_window_resizing(wrapper)
	if not failures.is_empty():
		save_report()
		quit(1)
		return
	report.close_requested = true
	save_report()
	match OS.get_environment("GRAFFITTY_TEST_SCENARIO"):
		"close-pane": key(KEY_W, 0, true)
		"close-tab": key(KEY_W, 0, true, true)
		"shell-exit": term.send_text("exit\r" if OS.get_name() == "Windows" else "exit\n")
	# Success is a natural application exit, not a test-driven quit.
	await create_timer(8.0).timeout
	check(false, "closing the last pane/tab or exiting its shell quits the application")
	save_report()
	quit(1)

func check_window_resizing(wrapper: Node) -> void:
	var host: Node = wrapper.host
	var view: Control = host.workspace_view
	var term: Node = host.active_terminal()
	var sizes := [Vector2i(800, 1100), Vector2i(1400, 700), Vector2i(1280, 800)]
	var grids: Array[Vector2i] = []
	var cell: Vector2 = term.get_cell_size()
	# Real resize events can arrive faster than owner acknowledgements.
	for step in 8:
		root.size = Vector2i(850 + step * 35, 1000 - step * 40)
		await process_frame
	for extent in sizes:
		root.size = extent
		var deadline := Time.get_ticks_msec() + 5000
		var current := false
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var area: Rect2 = view.viewport_content_rect()
			var saved: Array = wrapper.connection.topology.workspace_state.tabs[str(host.workspace_layout.active)].area
			current = Rect2(saved[0], saved[1], saved[2], saved[3]).is_equal_approx(area)
			if current and not host.session_backend.work_pending(): break
		await create_timer(.3).timeout
		check(current, "owner main area follows window size %s" % extent)
		var pane: Rect2 = view.pane_rects[host.pane_focus]
		var area: Rect2 = view.viewport_content_rect()
		check(pane.size.x >= area.size.x - 20 and pane.size.y >= area.size.y - 20,
			"tiled pane fills width and height at %s" % extent)
		check(view._pane_screen_rect(view.panes[host.pane_focus]).get_center().distance_to(area.get_center()) < 4,
			"pane stays centered in the available window at %s" % extent)
		check(term.get_cell_size().is_equal_approx(cell) and is_equal_approx(float(view.main_frame().zoom), 1.0),
			"window resize reflows text without scaling the font at %s" % extent)
		grids.append(term.get_grid_size())
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_TEST_REPORT").get_base_dir().path_join("window-%dx%d.png" % [extent.x, extent.y]))
	check(grids[0].y > grids[1].y and grids[0].x < grids[1].x, "portrait window gains rows; landscape window gains columns")
	report.resized_grids = grids.map(func(grid): return [grid.x, grid.y])
	var revision: int = wrapper.connection.topology.workspace_revision
	await create_timer(.5).timeout
	check(wrapper.connection.topology.workspace_revision == revision, "settled window size does not generate repeated workspace edits")
