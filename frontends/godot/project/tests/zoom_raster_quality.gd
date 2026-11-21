extends SceneTree
var failures: Array[String] = []


func check(ok: bool, message: String) -> void:
	print('[zoom-raster] ', 'PASS ' if ok else 'FAIL ', message)
	if not ok:
		failures.append(message)


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	OS.set_environment(
		'XDG_CONFIG_HOME',
		OS.get_cache_dir().path_join('graffitty-raster-%d' % OS.get_process_id()),
	)
	var host: Node = load('res://scenes/TerminalHost.gd').new()
	root.add_child(host)
	await create_timer(.6).timeout
	root.size = Vector2i(1200, 800)
	var world: Node = host.world
	var view: Control = host.workspace_view
	host.application.set_process(false)
	world.set_process(false)
	view.set_window_rect(host.pane_focus, Rect2(80, 100, 1020, 600))
	await process_frame
	var pair: Dictionary = host.sessions[host.active_session_id]
	pair.term.send_text(
		"printf '\\033[2J\\033[12;1HZoom quality: ABC xyz 0123456789\\033[13;20H'; sleep 30\n"
	)
	for i in 50:
		await create_timer(.1).timeout
		if pair.term.get_cursor_cell() == Vector2i(19, 12):
			break
	check(pair.term.get_cursor_cell() == Vector2i(19, 12), "Shell fixture is ready")
	var grid: Vector2i = pair.term.get_grid_size()
	var font: int = pair.term.get_live_font_size()
	world.fx_last_key = -1e8
	world.fx_cfg.scene.camera.dof_blur_amount = 0.0
	world.fx_cfg.states['idle']['camera.tilt_limit_deg'] = 0.0
	world.fx_cfg.states['idle']['sheet.curvature_deg'] = 0.0
	world.fx_cfg.states['idle']['sheet.ripple'] = 0.0
	var received := { 'point': Vector2.INF }
	pair.term.gui_input.connect(
		func(event):
			if event is InputEventMouseButton:
				received.point = event.position,
	)
	var base_density := 0.0
	for zoom in [1.0, 2.0, 4.0, 6.0, 1.0]:
		world.fx_cfg.states['idle']['camera.zoom'] = zoom
		for i in 180:
			world._fx_step(1.0 / 60)
		world._update_ink_view()
		for i in 4:
			await process_frame
		var density: float = view.canvas_scale()
		if zoom == 1.0:
			base_density = density
		else:
			check(
				density > base_density * zoom * .65,
				'Raster density follows %.0fx zoom (%.2f texels per layout pixel)' % [zoom, density],
			)
		check(
			pair.term.get_grid_size() == grid and pair.term.get_live_font_size() == font,
			'%.0fx zoom preserves terminal grid and font metrics' % zoom,
		)
		check(
			view.canvas.size.x * view.canvas.size.y <= 20_020_000,
			'Canvas stays within its raster budget',
		)
		# Exercise both canvas and terminal crop transforms through real GUI input.
		var sheet_cursor: Vector2 = world._camera_cursor_uv() * world._sheet_size()
		var screen: Vector2 = view.window_point(sheet_cursor)
		var motion := InputEventMouseButton.new()
		motion.button_index = MOUSE_BUTTON_LEFT
		motion.pressed = true
		motion.position = view.pointer.get_global_transform_with_canvas().affine_inverse() * screen
		view._forward_pointer(motion)
		motion.pressed = false
		view._forward_pointer(motion)
		var wanted: Vector2 = sheet_cursor - view.terminal_origin(host.pane_focus) - pair \
				.term \
				.position
		check(
			received.point.distance_to(wanted) < 2.0,
			'%.0fx zoom preserves terminal pointer coordinates: actual %s wanted %s screen %s'
			% [zoom, received.point, wanted, screen],
		)
		if DisplayServer.get_name() != 'headless':
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png('/tmp/graffitty-raster-%dx.png' % int(zoom))
	print('ZOOM_RASTER_PASS' if failures.is_empty() else 'ZOOM_RASTER_FAIL: ' + str(failures))
	quit(0 if failures.is_empty() else 1)
