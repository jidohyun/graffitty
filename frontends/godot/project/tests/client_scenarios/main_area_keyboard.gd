extends "res://tests/client_scenarios/workspace.gd"
## Exercise the manager/federation used on phones, including real server claims.
var sampled_frames: Array[Dictionary] = []
var keep_main := false
var left_main := false
var keyboard_height := 0.0
## Canvas points that must stay at these window positions, sampled every frame.
var pinned: Dictionary = {}
var drift := 0.0

func _process(_dt: float) -> void:
	if keep_main and is_instance_valid(view) and view.overview:
		left_main = true
	if is_instance_valid(view):
		for point in pinned:
			drift = maxf(drift, view.window_point(point).distance_to(pinned[point]))

func pin(points: Array) -> void:
	pinned.clear()
	for point in points: pinned[point] = view.window_point(point)
	drift = 0.0

func shown_rect(key: String) -> Rect2:
	return view.get_global_transform_with_canvas() * view._pane_screen_rect(view.panes[key])

func saved_center() -> Vector2:
	var center: Array = host.workspace_layout.tab(host.workspace_layout.active).navigation.center
	return Vector2(center[0], center[1])

func server_area(connection: Node = null) -> Rect2:
	if connection == null: connection = transport
	for tab in connection.topology.get("tabs", []):
		if int(tab.id) == host.workspace_layout.active or connection != transport:
			var area: Array = connection.topology.workspace_state.tabs[str(tab.id)].get("area", [0, 0, 0, 0])
			return Rect2(area[0], area[1], area[2], area[3])
	return Rect2()

func usable_area() -> Rect2:
	# Measure actual chrome in window coordinates, independently of fit helpers.
	# The phone menu floats over content; it does not reserve a full-width row.
	var top := 0.0
	for chrome in [view.tab_bar, view.toolbar]:
		if is_instance_valid(chrome) and chrome.is_visible_in_tree():
			top = maxf(top, chrome.get_global_rect().end.y)
	var left := 0.0
	var right: float = root.get_visible_rect().end.x
	var bottom: float = root.get_visible_rect().end.y - keyboard_height
	if manager.keybar.is_visible_in_tree(): bottom = minf(bottom, manager.keybar.get_global_rect().position.y)
	# Read the actual dock edges, including folded panels and their outer gaps.
	var space: Control = root.get_meta(&"list_dock_space")
	for panel: Control in space.panels:
		if not panel.is_visible_in_tree(): continue
		var rect := panel.get_global_rect()
		match panel.side:
			"left": left = maxf(left, rect.end.x)
			"right": right = minf(right, rect.position.x)
			"top": top = maxf(top, rect.end.y)
			"bottom": bottom = minf(bottom, rect.position.y)
	return Rect2(Vector2(left, top) - view.global_position, Vector2(right - left, bottom - top))

func same_area(a: Rect2, b: Rect2) -> bool:
	return a.position.distance_to(b.position) < 2.0 and a.size.distance_to(b.size) < 2.0

func checkpoint(label: String) -> void:
	var row := {"stage": label, "usable": str(usable_area()), "server": str(server_area()),
		"main": not view.overview, "grid": str(terminal().get_grid_size()),
		"viewport": str(root.get_visible_rect()), "inset": keyboard_height,
		"pane": str(view._pane_screen_rect(view.panes[host.pane_focus])) if view.panes.has(host.pane_focus) else "missing: " + str(view.panes.keys())}
	sampled_frames.append(row)
	print("MAIN_AREA_FRAME ", JSON.stringify(row))
	if not output.is_empty():
		FileAccess.open(output.get_base_dir().path_join("main-area-frames.json"), FileAccess.WRITE).store_string(JSON.stringify(sampled_frames, "  "))
		# Idle/background windows may stop scheduling frames; capture explicitly.
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png(output.get_base_dir().path_join(label + ".png"))

func check_area(label: String) -> void:
	await until(func(): return same_area(server_area(), usable_area()), label + ": server acknowledges the usable Android area", 5.0)
	expect(same_area(view.content_rect(), usable_area()), label + ": main-area ratio follows visible chrome and insets")
	await checkpoint(label)

func keyboard(open: bool, fraction := .35) -> void:
	if OS.has_feature("android"):
		await tap(manager.floating.get_node("KeyboardButton"))
		await until(func(): return (manager.keyboard_insets.keyboard_height() > 0) == open, "Native keyboard opens" if open else "Native keyboard closes")
		await wait(.8)
		keyboard_height = float(manager.keyboard_insets.keyboard_height()) / root.get_final_transform().get_scale().y
	else:
		var target := root.get_visible_rect().size.y * fraction if open else 0.0
		var previous := keyboard_height
		for step in range(1, 7):
			keyboard_height = lerpf(previous, target, float(step) / 6.0)
			manager.terminal_ime._native_keyboard_height(roundi(keyboard_height * root.get_final_transform().get_scale().y))
			await wait(.04)
		await wait(.5)

func competing_client() -> void:
	# Finish the preceding rotation claim before the second client takes over.
	await get_tree().process_frame
	expect(await host.session_backend.flush_workspace(host, host.active_session_id), "Android rotation claim settles before competing client connects")
	var other := preload("res://scenes/remote/RemoteConnection.gd").new()
	add_child(other)
	other.workspace = transport.workspace
	other.connect_remote(transport.url, transport.token)
	if await until(func(): return other.connected and not other.topology.tabs.is_empty(), "Second client connects to the same isolated workspace"):
		var tab: int = other.topology.tabs[0].id
		var snapshot: Dictionary = other.topology.workspace_state
		var other_area := Rect2(0, 34, 1200, 640)
		var reply: Dictionary = await other.request_action("workspace_edit", {"expected_revision": int(other.topology.workspace_revision), "claim": true,
			"edit": {"op": "tab", "tab": tab, "layout": snapshot.layout.tabs[str(tab)],
				"settings": {"area": [0, 34, 1200, 640]}}})
		expect(reply.get("type") == "ack", "Competing size claim acknowledged: " + str(reply.get("message", reply.get("type", "missing"))))
		await until(func(): return same_area(server_area(), other_area), "Idle Android follows the other client's newer size claim")
		await wait(.5)
		expect(same_area(server_area(), other_area), "Idle Android does not fight the newer claim")
		await tap(view.tab_bar.tabs.buttons[host.workspace_layout.active])
		await until(func(): return same_area(server_area(other), usable_area()), "Actual Android touch reclaims its dimensions for both clients")
		await wait(.5)
		expect(same_area(server_area(), usable_area()), "The active Android claim remains stable")
	other.disconnect_remote()
	other.queue_free()

func main_area_keyboard() -> void:
	# Effects must not hide a saved-navigation regression behind typing zoom.
	host.world.fx_enabled = false
	if not current_tree().get("tiling", false): await toggle_tiling()
	if not OS.has_feature("android"):
		# Movie Maker keeps one capture size. Rotate the logical Android surface
		# within it instead of resizing the native capture window mid-recording.
		root.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		# Letterbox the phone surface inside the recording; stretching it would
		# give the 3D compositor a different aspect ratio from the logical phone.
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
		manager.terminal_ime = preload("res://scenes/input/AndroidTerminalIme.gd").new()
		manager.terminal_ime.manager = manager
		manager.add_child(manager.terminal_ime)
		manager.keyboard_insets = preload("res://scenes/input/AndroidKeyboardInsets.gd").new()
		manager.keyboard_insets.manager = manager
		manager.add_child(manager.keyboard_insets)
		manager.keyboard_insets.update_inset(0.0)
	var process_id: int = terminal().get_shell_pid()
	var font_size: int = terminal().get_live_font_size()
	for portrait in [true, false]:
		var label := "portrait" if portrait else "landscape"
		if OS.has_feature("android"):
			DisplayServer.screen_set_orientation(DisplayServer.SCREEN_PORTRAIT if portrait else DisplayServer.SCREEN_LANDSCAPE)
		else:
			root.content_scale_size = Vector2i(480, 900) if portrait else Vector2i(1000, 620)
		await wait(1.2)
		expect((root.get_visible_rect().size.x < root.get_visible_rect().size.y) == portrait, label + ": viewport has the requested orientation")
		await check_area(label)
		if not failures.is_empty(): return
		if portrait: await competing_client()
		if not expect(view.panes.has(host.pane_focus), "Focused terminal has a rendered pane"): return
		view.show_main()
		await wait(.3)
		keep_main = true
		left_main = false
		var full_grid: Vector2i = terminal().get_grid_size()
		var full_area := server_area()
		terminal().send_text("printf '\\033[999;1HBOTTOM_%%s_%%s\\n' VISIBLE %s\r" % label)
		await until(func(): return "BOTTOM_VISIBLE_" + label in text_in("", true).replace("\n", ""), "Bottom-row marker arrives")
		for cycle in 2:
			await keyboard(true)
			await check_area(label + "-open-%d" % cycle)
			await until(func(): return terminal().get_grid_size().y < full_grid.y, "Keyboard reflows the server terminal to fewer rows")
			expect(terminal().get_grid_size().x == full_grid.x, "Keyboard preserves terminal columns")
			expect(server_area().size.y < full_area.size.y - 30.0, "Main area becomes shorter rather than camera-scaled")
			expect(not left_main and not view.overview, "Main View remains selected throughout keyboard opening")
			var shown: Rect2 = view._pane_screen_rect(view.panes[host.pane_focus])
			expect(usable_area().grow(3).encloses(shown), "Complete main pane fits above the accessory bar")
			var caret: Vector2 = view.view_point(view.terminal_origin(host.pane_focus) + terminal().position + terminal().get_cursor_anchor_local())
			print("MAIN_AREA_CARET ", JSON.stringify({"caret": str(caret), "origin": str(view.terminal_origin(host.pane_focus)), "position": str(terminal().position), "size": str(terminal().size), "anchor": str(terminal().get_cursor_anchor_local()), "cell": str(terminal().get_cell_size()), "cursor": str(terminal().get_cursor_cell()), "grid": str(terminal().get_grid_size())}))
			expect(usable_area().grow(3).has_point(caret), "Bottom-row cursor is visible above the keyboard")
			var cell: Vector2 = terminal().get_cell_size()
			var cursor_cell := Rect2(terminal().position + terminal().get_cursor_anchor_local() - Vector2(0, cell.y), cell)
			expect(Rect2(Vector2.ZERO, view.panes[host.pane_focus].body.size).grow(1).encloses(cursor_cell), "Entire cursor cell fits inside the terminal preview")
			# One visible row contains the new prompt after printf's newline.
			# Search retained output, and split the marker so command echo alone
			# cannot satisfy this assertion before the shell actually executes it.
			terminal().send_text("printf '%%s_%%s_%%d\\n' KEYBOARD_REFLOW %s %d\r" % [label, cycle])
			await until(func(): return "KEYBOARD_REFLOW_%s_%d" % [label, cycle] in text_in("", true).replace("\n", ""), "Typing still reaches the same terminal")
			await keyboard(false)
			await check_area(label + "-closed-%d" % cycle)
			await until(func(): return terminal().get_grid_size() == full_grid, "Closing keyboard restores the full terminal grid")
			expect(not left_main and not view.overview, "Main View stays selected through typing and keyboard closing")
		keep_main = false
		await camera(view.content_rect().get_center() + Vector2(30, 20), .8)
		# Navigated content stays put; only the main area changes behind it. A
		# keyboard leaving under 220 px also reclaims the chrome above it.
		for tall in ([false] if portrait or OS.has_feature("android") else [false, true]):
			var stage := label + ("-navigated-tall" if tall else "-navigated")
			var key: String = host.pane_focus
			var pane: Rect2 = view.pane_rects[key]
			var before := shown_rect(key)
			var saved := saved_center()
			pin([Vector2.ZERO, pane.position, pane.get_center(), pane.end])
			await keyboard(true, 1.0 - 200.0 / root.get_visible_rect().size.y if tall else .35)
			var compact: bool = not manager.keyboard_insets.compact_chrome.is_empty()
			if tall: expect(compact, stage + ": a tall keyboard reclaims the chrome")
			expect(view.overview, "Opening keyboard preserves intentional navigation")
			await check_area(stage + "-open")
			# A fractional height rounds the canvas up: under a pixel of squish.
			expect(drift < 3.0, stage + ": opening keyboard leaves content in place (drift %.1f px)" % drift)
			# Compact chrome also moves the main area's top; otherwise it stays.
			if not compact: expect(shown_rect(key).position.distance_to(before.position) < 2.0, stage + ": shorter main area keeps the pane's top edge in place")
			# Saved navigation stays keyboard-free, so a tab switch or restart
			# restores the same place on screen with the keyboard open or closed.
			var live: Vector2 = view.navigation_center
			view.restore_navigation(host.workspace_layout.active)
			expect(saved_center().distance_to(saved) < .5 and view.navigation_center.distance_to(live) < .5, stage + ": saved navigation omits the keyboard (%s, was %s)" % [saved_center(), saved])
			await keyboard(false)
			expect(view.overview, "Closing keyboard does not reset an intentional view")
			await check_area(stage + "-closed")
			expect(drift < 3.0, stage + ": closing keyboard leaves content in place (drift %.1f px)" % drift)
			expect(same_area(shown_rect(key), before), stage + ": closing keyboard restores the pane on screen (%s, was %s)" % [shown_rect(key), before])
			pinned.clear()
	expect(terminal().get_shell_pid() == process_id, "Orientation and keyboard changes preserve the original shell")
	expect(terminal().get_live_font_size() == font_size, "Main-area resizing preserves font size")
