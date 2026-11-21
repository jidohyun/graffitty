extends SceneTree
## Retained owner layout must not be cropped to the smaller client canvas.
var evidence_dir: String

func windows_output(term: Node, text: String) -> void:
	var encoded := Marshalls.raw_to_base64(text.to_utf8_buffer())
	term.send_text("[Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))\r" % encoded)

func _initialize() -> void:
	evidence_dir = OS.get_environment("GRAFFITTY_CROP_EVIDENCE")
	if evidence_dir.strip_edges().is_empty():
		printerr("TERMINAL_CROP_FAIL missing evidence directory; run tests/godot/retained_terminal_crop_e2e.py --evidence <directory>")
		quit(1)
		return
	if DirAccess.make_dir_recursive_absolute(evidence_dir) != OK:
		printerr("TERMINAL_CROP_FAIL cannot create evidence directory: " + evidence_dir)
		quit(1)
		return
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(1600, 1000)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null:
		printerr("TERMINAL_CROP_FAIL no host")
		quit(1)
		return
	var host: Node = wrapper.host
	host.switch_world("bistro")
	for index in range(10):
		await wrapper.connection.request_action("create", {"kind":"tab"})
		for frame in range(12):
			await process_frame
			RenderingServer.force_draw(false)
	host.switch_world("")
	host.switch_world("bistro")
	await wrapper.connection.request_action("font_size", {"session": host.active_session_id, "size": 10})
	for unused in range(150):
		await process_frame
		RenderingServer.force_draw(false)
	var id: int = host.active_session_id
	var pair: Dictionary = host.sessions[id]
	var pane: Control = host.workspace_view.panes["%%%d" % id]
	print("METRICS ", {"grid": pair.term.get_grid_size(), "cell":pair.term.get_cell_size(), "term_size":pair.term.size,"pane_size":pane.size,"body_size":pane.body.size,"vp_size":pair.vp.size,"vp_logical":pair.vp.size_2d_override,"transform":pair.vp.canvas_transform,"font":pair.term.get_live_font_size(),"region":host.workspace_view.raster_region})
	if OS.get_name() == "Windows":
		windows_output(pair.term, "\u001b[2J\u001b[1;1HLEFT_TOP\u001b[1;199HRIGHT_TOP\u001b[49;1HLEFT_BOTTOM\u001b[49;197HRIGHT_BOTTOM")
	else:
		pair.term.send_text("printf '\\033[2J\\033[1;1HLEFT_TOP\\033[1;199HRIGHT_TOP\\033[49;1HLEFT_BOTTOM\\033[49;197HRIGHT_BOTTOM'\n")
	for unused in range(90):
		await process_frame
		RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(evidence_dir.path_join("window.png"))
	pair.vp.get_texture().get_image().save_png(evidence_dir.path_join("terminal.png"))
	var rect: Rect2 = host.workspace_view.pane_rects["%%%d" % id]
	var passed: bool = host.workspace_view.raster_region.encloses(rect)
	# Fill every retained tab, then inspect every rendered handoff frame. A
	# settled-only screenshot misses the old crop exposed for a single frame.
	for session in host.sessions.values():
		if OS.get_name() == "Windows":
			windows_output(session.term, "\u001b[2J" + "HANDOFF VISIBILITY ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\r\n".repeat(35))
		else:
			session.term.send_text("printf '\\033[2J'; i=0; while [ $i -lt 35 ]; do printf 'HANDOFF VISIBILITY ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\\n'; i=$((i+1)); done\n")
	# Hidden tabs need not be subscribed. Confirm their actual owner output,
	# rather than timing the flight against a still-echoing shell command.
	var histories := {}
	var receive_history := func(session: int, text: String): histories[session] = text
	wrapper.connection.history_received.connect(receive_history)
	var output_ready := false
	deadline = Time.get_ticks_msec() + 15000
	while not output_ready and Time.get_ticks_msec() < deadline:
		output_ready = true
		for session_id in host.sessions:
			await wrapper.connection.request_action("history", {"session": session_id})
			output_ready = output_ready and str(histories.get(session_id, "")).count("HANDOFF VISIBILITY") >= 35
		if not output_ready: await create_timer(0.05).timeout
	wrapper.connection.history_received.disconnect(receive_history)
	if not output_ready:
		printerr("TERMINAL_CROP_FAIL handoff output did not finish before navigation")
		quit(1)
		return
	host.select_workspace(host.workspace_layout.tabs[0].id)
	var handoff := []
	for frame in range(240):
		await process_frame
		RenderingServer.force_draw(false)
		var world: Node = host.world
		if world.tab_fx_t >= world.tab_fx_dur or (world.tab_fx_t < 0.0 and not handoff.is_empty()):
			var picture := root.get_texture().get_image()
			picture.save_png(evidence_dir.path_join("handoff-%02d.png" % handoff.size()))
			var ink := 0
			var title_ink := 0
			# Text well below the old 500-logical-pixel crop; scenery is not white.
			for y in range(700, 920, 2):
				for x in range(40, 790, 2):
					var pixel := picture.get_pixel(x, y)
					if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.8: ink += 1
			# The whole title strip (pane top to body top), in capture pixels, so a
			# sub-pixel settle cannot move glyphs out of a fixed sample band.
			var to_pixels := Vector2(picture.get_size()) / root.get_visible_rect().size
			var shown: Control = host.workspace_view.panes["%%%d" % host.active_session_id]
			var pane_box: Rect2 = shown.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, shown.size)
			var body_top: float = (shown.body.get_global_transform_with_canvas() * Vector2.ZERO).y
			var title_rows := Vector2i(int(pane_box.position.y * to_pixels.y), int(body_top * to_pixels.y))
			var title_columns := Vector2i(int(pane_box.position.x * to_pixels.x), int(pane_box.end.x * to_pixels.x))
			for y in range(maxi(title_rows.x, 0), mini(title_rows.y, picture.get_height())):
				for x in range(maxi(title_columns.x, 0), mini(title_columns.y, picture.get_width()), 2):
					var pixel := picture.get_pixel(x, y)
					if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.8: title_ink += 1
			handoff.append({"frame": frame, "t": world.tab_fx_t, "lower_text_pixels": ink, "title_pixels": title_ink})
			if handoff.size() == 8: break
	var handoff_passed := handoff.size() == 8
	if handoff_passed:
		var settled: int = handoff.back().lower_text_pixels
		handoff_passed = settled > 500
		for sample in handoff:
			if sample.t < 0.0:
				handoff_passed = handoff_passed and sample.lower_text_pixels >= settled * 0.7
				handoff_passed = handoff_passed and sample.title_pixels >= handoff.back().title_pixels * 0.7
	passed = passed and handoff_passed
	# The same owner page must stay attached to the authored wall, regardless
	# of the client render-window dimensions (not merely look centered on screen).
	var world: Node = host.world
	var view: Control = host.workspace_view
	# Startup may automatically inspect the first pane. This invariant is for
	# Main area, not a saved deliberate inspection camera.
	view.show_main()
	for unused in range(10):
		await process_frame
		RenderingServer.force_draw(false)
	var area: Rect2 = view.content_rect()
	# The page is the retained Main area plus this client's chrome on every
	# side (tab bar, docks, status strip), measured from the canvas origin.
	var visible: Rect2 = view.viewport_content_rect()
	var page_center: Vector2 = area.position - visible.position + (area.size + view.size - visible.size) * 0.5
	var uv: Vector2 = page_center / world._sheet_size()
	var attached: Vector3 = world.uv_origin + world.uv_du * uv.x + world.uv_dv * uv.y
	var attachment_error: float = attached.distance_to(world.surfaces[world.active].global_position)
	var camera_error: float = world.cam.global_position.distance_to(world.surfaces[world.active].eye)
	var before_canvas: Vector2 = view.canvas_size()
	# Exercise a retained owner page, as on a following client. A fitting
	# window would claim the new shape; that is a different layout operation.
	host.session_backend.fit_main_view = false
	root.size = Vector2i(1400, 900)
	for unused in range(20):
		await process_frame
		RenderingServer.force_draw(false)
	uv = page_center / world._sheet_size()
	var resized_attachment: Vector3 = world.uv_origin + world.uv_du * uv.x + world.uv_dv * uv.y
	var attachment_drift := resized_attachment.distance_to(attached)
	var attachment_passed: bool = attachment_error < 0.001 and attachment_drift < 0.001 and view.canvas_size() != before_canvas
	var resized_camera_error: float = world.cam.global_position.distance_to(world.surfaces[world.active].eye)
	passed = passed and attachment_passed and camera_error < 0.001 and resized_camera_error < 0.001
	var report := {"passed": passed, "pane": str(rect), "crop": str(host.workspace_view.raster_region), "grid": str(pair.term.get_grid_size()), "handoff": handoff, "handoff_passed": handoff_passed, "camera_error": camera_error, "resized_camera_error": resized_camera_error, "attachment_error": attachment_error, "attachment_drift": attachment_drift, "attachment_passed": attachment_passed}
	var file := FileAccess.open(evidence_dir.path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	for unused in range(5): await process_frame
	print("TERMINAL_CROP_PASS" if passed else "TERMINAL_CROP_FAIL")
	quit(0 if passed else 1)
