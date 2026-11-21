extends RefCounted
## Optional CLI capture/diagnostic routines. Normal world updates never run these.
## Keep the world explicit so probes do not own rendering or session state.
const CellShatterScript := preload("res://scenes/CellShatter.gd")
const CoreTerminalEffects := preload("res://scenes/TerminalEffects.gd")


static func selection_test(world: Node) -> void:
	## Drag a selection with synthetic mouse events and capture it, so [terminal]
	## selection_bg / selection_fg are checked against pixels rather than
	## assumed.
	##
	## The drag goes into the terminal's own SubViewport, which is the same path
	## a real mouse takes.
	await world.get_tree().create_timer(2.0).timeout
	var cell: Vector2 = world.term.call("get_cell_size")
	var grid_origin: Vector2 = world.term.get("position")
	var origin := grid_origin + Vector2(cell.x * 2.0, cell.y * 1.5)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = origin
	world.term_vp.push_input(press, true)
	await world.get_tree().process_frame
	var drag := InputEventMouseMotion.new()
	drag.position = origin + Vector2(cell.x * 20.0, 0.0)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	world.term_vp.push_input(drag, true)
	await world.get_tree().create_timer(0.3).timeout
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = drag.position
	world.term_vp.push_input(release, true)
	await world.get_tree().create_timer(0.5).timeout
	print("[sel] dragged from %s to %s in texture pixels" % [str(origin), str(drag.position)])
	# The TERMINAL's texture, not the window: selection colours are unambiguous
	# there, with no wall, tonemap or sheet shader between them and the measurement.
	await RenderingServer.frame_post_draw
	var img: Image = world.term_vp.get_texture().get_image()
	img.save_png("%s/selection.png" % world.shot_dir)
	print(
		"[sel] saved %s/selection.png  %dx%d" % [world.shot_dir, img.get_width(), img.get_height()]
	)
	print("SELTEST_DONE")
	world.get_tree().quit()


static func signal_test(world: Node) -> void:
	## Every signal docs/developers/worlds-and-plugins/design-plugins.md promises, received rather than assumed,
	## plus the two session calls that let a host own a dead shell.
	var log: Array = []
	world.term.connect(
		"keystroke",
		func(cell, unicode):
			log.append("keystroke  cell %s  U+%04X" % [str(cell), unicode]),
	)
	world.term.connect(
		"cursor_moved",
		func(cell):
			log.append("cursor_moved  cell %s" % str(cell)),
	)
	world.term.connect(
		"grid_resized",
		func(cols, rows):
			log.append("grid_resized  %d x %d" % [cols, rows]),
	)
	world.term.connect(
		"output",
		func(bytes):
			log.append("output  %d bytes" % bytes),
	)
	world.term.connect(
		"bell",
		func():
			log.append("bell"),
	)
	world.term.connect(
		"exited",
		func(code):
			log.append("exited  code %d" % code),
	)

	await world.get_tree().create_timer(1.5).timeout
	var after_start := log.size()
	world.term.call("send_text", "printf 'sent\\n'\n")
	await world.get_tree().create_timer(1.0).timeout
	var after_send := log.size()

	var ev := InputEventKey.new()
	ev.keycode = KEY_A
	ev.unicode = 97
	ev.pressed = true
	world.term_vp.push_input(ev, true)
	await world.get_tree().create_timer(0.6).timeout
	var after_key := log.size()

	world.term.call("paste_text", "pasted")
	await world.get_tree().create_timer(0.6).timeout
	world.term.call("send_text", "\u0007") # BEL
	await world.get_tree().create_timer(0.6).timeout
	# A reflow, which is the only way grid_resized can fire without a resize.
	world.term.call("set_live_font_size", 30)
	await world.get_tree().create_timer(0.6).timeout
	world.term.call("respawn")
	await world.get_tree().create_timer(1.5).timeout

	for line in log:
		print("[signal] ", line)
	print(
		"[signal] counts: start=%d send=+%d key=+%d rest=+%d"
		% [after_start, after_send - after_start, after_key - after_send, log.size() - after_key]
	)
	print("[signal] alive after respawn: %s" % str(world.term.call("is_exited") == false))
	print("SIGNALTEST_DONE")
	world.get_tree().quit()


static func layout_test(world: Node) -> void:
	## Log how the terminal grid fits the window at its current aspect ratio.
	## This helps diagnose resizing by tiling window managers.
	##
	## Report the window, aspect ratios, cover span, cover texture, grid
	## rectangle, and camera frustum. The grid should fill `grid_fraction`
	## of the window.
	var win: Vector2 = world._window_render_size()
	var rect: Rect2 = world._terminal_content_rect(CoreTerminalEffects.layout_size(world.term_vp))
	print(
		"[layout] window %dx%d  aspect %.4f  canvas %.4f  cover span (%.3f, %.3f)"
		% [
			int(win.x),
			int(win.y),
			world._frame_aspect(),
			world._canvas_aspect(),
			world._canvas_span_in_frame().x,
			world._canvas_span_in_frame().y,
		]
	)
	print(
		"[layout] texture %dx%d  grid %dx%d at (%d, %d)  = %.3f x %.3f of the window"
		% [
			world.term_vp.size.x,
			world.term_vp.size.y,
			int(rect.size.x),
			int(rect.size.y),
			int(rect.position.x),
			int(rect.position.y),
			rect.size.x / maxf(world.term_vp.size.x, 1.0) * world._canvas_span_in_frame().x,
			rect.size.y / maxf(world.term_vp.size.y, 1.0) * world._canvas_span_in_frame().y,
		]
	)
	if world.term != null and world.term.has_method("get_grid_size"):
		var cells: Vector2i = world.term.call("get_grid_size")
		var cell: Vector2 = world.term.call("get_cell_size")
		print(
			"[layout] cells %dx%d of %.0fx%.0f px, font %d"
			% [cells.x, cells.y, cell.x, cell.y, int(world.term.call("get_live_font_size"))]
		)
	if world.term != null and world.term.has_method("vt_build_info"):
		print("[layout] vt build: %s" % str(world.term.call("vt_build_info")))
	if world.term != null and world.term.has_method("image_placements"):
		print("[layout] image placements: %s" % str(world.term.call("image_placements")))
	print(
		"[layout] frustum width %.6f (cam.size %.6f / near %.4f), pose half_x %.6f"
		% [world.cam.size / world.cam.near, world.cam.size, world.cam.near, world.pose_half_x]
	)
	if world.term != null and world.term.has_method("get_cursor_anchor_local"):
		var cell: Vector2i = world.term.call("get_cursor_cell")
		var local: Vector2 = world.term.call("get_cursor_anchor_local")
		var point: Vector2 = world._cursor_window_point()
		print(
			"[layout] cursor cell %s  local %s  -> window (%.1f, %.1f)"
			% [str(cell), str(local), point.x, point.y]
		)
	await shot(world, "layout")


static func fx_demo(world: Node) -> void:
	## idle -> typing -> settle, captured at each stage so the behaviour state
	## machine and the sheet deformation are both visible.
	world.term.grab_focus()
	await world.get_tree().process_frame
	await shot(world, "0_idle")
	var line := "ls -la"
	for i in line.length():
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.unicode = line.unicode_at(i)
		world.term_vp.push_input(ev, true)
		world._fx_key(ev)
		await world.get_tree().create_timer(0.08).timeout
	await shot(world, "1_typing")
	await world.get_tree().create_timer(0.35).timeout
	await shot(world, "2_typing_peak")
	await world.get_tree().create_timer(1.6).timeout
	await shot(world, "3_leaving")
	await world.get_tree().create_timer(1.8).timeout
	await shot(world, "4_rest")
	print("FX_DONE")
	world.get_tree().quit()


static func shot(world: Node, tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := world.get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [world.shot_dir, tag]
	img.save_png(path)
	print("SHOT %s  %dx%d" % [path, img.get_width(), img.get_height()])


static func input_test(world: Node) -> void:
	## Reproduce a lost keyboard after switching tabs. Use
	## `Input.parse_input_event` to exercise the normal route without the real
	## keyboard.
	##
	## The event goes through GUI focus, then `_unhandled_input`, then into the
	## terminal's SubViewport. Capture what the wall shows.
	DirAccess.make_dir_recursive_absolute(world.shot_dir)
	var send := func(ch: String) -> void:
		var down := InputEventKey.new()
		down.keycode = ch.to_upper().unicode_at(0)
		down.unicode = ch.unicode_at(0)
		down.pressed = true
		Input.parse_input_event(down)
		await world.get_tree().process_frame
		var up := InputEventKey.new()
		up.keycode = down.keycode
		up.unicode = down.unicode
		up.pressed = false
		Input.parse_input_event(up)
		await world.get_tree().process_frame

	var stage := func(tag: String, text: String) -> void:
		for i in text.length():
			await send.call(text[i])
		await world.get_tree().create_timer(0.6).timeout
		print(
			"[inputtest] %-24s term_focus=%s vp_focus=%s main_focus=%s"
			% [
				tag,
				str(world.term.has_focus()),
				str(world.term_vp.gui_get_focus_owner()),
				str(world.get_viewport().gui_get_focus_owner()),
			]
		)
		await RenderingServer.frame_post_draw
		world.term_vp.get_texture().get_image().save_png("%s/%s.png" % [world.shot_dir, tag])

	await world.get_tree().create_timer(2.5).timeout
	await stage.call("1_startup", "aaa")
	world.tabs.grab_focus()
	await world.get_tree().process_frame
	await stage.call("2_after_tab_click", "bbb")
	world._goto(wrapi(world.active + 1, 0, world.surfaces.size()), false)
	await world.get_tree().create_timer(2.2).timeout
	await stage.call("3_after_flight", "ccc")
	print("TOUR_DONE")
	world.get_tree().quit()


static func lag_test(world: Node) -> void:
	## Frame times across real flights with NO capture, so the measurement cannot
	## manufacture the hitch it is looking for.
	await world.get_tree().create_timer(2.0).timeout
	var pairs := [[13, 12], [12, 13], [13, 12], [12, 13], [13, 12]]
	for pair in pairs:
		world._goto(pair[0], true)
		await world.get_tree().create_timer(0.7).timeout
		print("LAGRUN %d->%d" % [pair[0], pair[1]])
		world._goto(pair[1], false)
		while world.fly_dur > 0.0:
			await world.get_tree().process_frame
		await world.get_tree().create_timer(0.5).timeout
	print("TOUR_DONE")
	world.get_tree().quit()


static func layer_test(world: Node) -> void:
	## Demonstrate a screen split into five layers using `Terminal.cell_glyphs()`.
	## That method supplies each cell's codepoint, style bits, and font slot.
	##
	## Each layer has its own flight timing and motion. Pieces sample UV
	## rectangles from the painted texture and reuse the existing glyphs.
	await world.get_tree().create_timer(2.5).timeout
	var rect: Rect2 = world._terminal_content_rect(CoreTerminalEffects.layout_size(world.term_vp))
	if not world.term.has_method("cell_glyphs"):
		print("[layers] extension has no cell_glyphs(); nothing to split")
		print("LAYERS_DONE")
		world.get_tree().quit()
		return
	# What the call itself costs, since an effect pays it at every start.
	var probe_started := Time.get_ticks_usec()
	for i in 20:
		world.term.call("cell_glyphs")
	var probe_ms := float(Time.get_ticks_usec() - probe_started) / 20000.0
	var split: Dictionary = world._layer_split()
	var buckets: Array = split["cells"]
	var samples: Array = split["samples"]
	var glyphs: Array = []
	glyphs.resize(int(split["total"]))
	# Frame pacing would answer this question for us: on a 120 Hz display every
	# frame takes 8.33 ms whatever the GPU did.
	#
	# Measure with it off, and measure the same scene doing nothing first, or the
	# number means nothing.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var idle: Array[float] = []
	for i in 45:
		var idle_started := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		if i > 4:
			idle.append(float(Time.get_ticks_usec() - idle_started) / 1000.0)
	idle.sort()
	var idle_median: float = idle[idle.size() / 2]
	var pieces: Array = []
	var total := 0
	for i in world.LAYERS.size():
		var spec: Dictionary = world.LAYERS[i]
		var layer := CellShatterScript.new()
		world.add_child(layer)
		var n: int = layer.build_cells(
			world.term,
			world.term_vp,
			rect,
			world.uv_origin,
			world.uv_du,
			world.uv_dv,
			buckets[i],
			spec["motion"],
			spec["when"],
		)
		print(
			"[layers] %-6s %4d cells  motion=%s  arrives %.2f-%.2f  e.g. %s"
			% [spec["name"], n, str(spec["motion"]), spec["when"].x, spec["when"].y, samples[i]]
		)
		total += n
		if n > 0:
			pieces.append(layer)
	var grid_cells: Vector2i = world.term.call("get_grid_size")
	print(
		"[layers] %d cells from %d glyph cells in %d layers" % [total, glyphs.size(), pieces.size()]
	)
	print(
		"[layers] cell_glyphs(): %.3f ms per call, %d of %d cells inked"
		% [probe_ms, glyphs.size(), grid_cells.x * grid_cells.y]
	)
	if pieces.is_empty():
		print("LAYERS_DONE")
		world.get_tree().quit()
		return
	# Same demo shortcut as --shattertest: the source must not show while its
	# pieces are in the air, and hiding the wall is cheaper than masking.
	var wall: MeshInstance3D = world.walls[world.surfaces[world.active].id]
	wall.visible = false
	var marks := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
	var next := 0
	var t := 0.0
	var frames := 0
	var worst := 0.0
	var flight: Array[float] = []
	var started := Time.get_ticks_usec()
	while t <= 1.0001:
		for layer in pieces:
			layer.set_progress(t)
		var frame_started := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		var ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
		var shooting: bool = next < marks.size() and t >= float(marks[next])
		# The first frames pay for shader compilation, and a screenshot frame pays
		# for a GPU readback; neither is what flying costs.
		if frames > 2 and not shooting:
			worst = maxf(worst, ms)
			flight.append(ms)
		frames += 1
		if shooting:
			await shot(world, "layers_%03d" % int(marks[next] * 100.0))
			next += 1
		t += 0.015
	wall.visible = true
	await shot(world, "layers_source")
	flight.sort()
	var median := flight[flight.size() / 2] if not flight.is_empty() else 0.0
	var p95 := flight[int(flight.size() * 0.95)] if not flight.is_empty() else 0.0
	print(
		"[layers] %d frames in %.0f ms; flying frame median %.2f ms, p95 %.2f ms, worst %.2f ms (%d sampled)"
		% [
			frames,
			float(Time.get_ticks_usec() - started) / 1000.0,
			median,
			p95,
			worst,
			flight.size(),
		]
	)
	print(
		"[layers] vsync off: idle %.2f ms -> flying %.2f ms = %+.2f ms for %d pieces"
		% [idle_median, median, median - idle_median, total]
	)
	print("LAYERS_DONE")
	world.get_tree().quit()
