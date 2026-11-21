extends "../../../../tests/llm-e2e/replay/replay.gd"
## Pane glass must differ from the world visible between tiles, in both renderers.

func sample(image: Image, point: Vector2) -> Color:
	var density := Vector2(image.get_size()) / root.get_visible_rect().size
	return image.get_pixelv(Vector2i(point * density))

func check_pane_backgrounds(opacity: float, label: String) -> void:
	var view: Control = host.workspace_view
	var rects: Array = view.pane_rects.values()
	rects.sort_custom(func(a: Rect2, b: Rect2): return a.position.x < b.position.x)
	check(rects.size() == 2, "Two panes available for background comparison")
	if rects.size() != 2: return
	await process_frame
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	var y: float = rects[0].position.y + rects[0].size.y * .75
	var gap_at := Vector2((rects[0].end.x + rects[1].position.x) * .5, y)
	var gap := sample(shot, view.window_point(gap_at))
	check(absf(gap.a - .85) <= 2.0 / 255.0, "The gap keeps the world backdrop opacity (%s): %s" % [label, gap.a])
	for rect: Rect2 in rects:
		var body := sample(shot, view.window_point(Vector2(rect.position.x + rect.size.x * .65, y)))
		# Configured alpha belongs to pane glass, composited once over the
		# separate world background; it is not the final OS window's alpha.
		var expected := opacity + gap.a * (1.0 - opacity)
		check(absf(body.a - expected) <= 2.0 / 255.0, "Pane glass has the configured opacity (%s): %s, expected %s" % [label, body.a, expected])
		if opacity > 0.0:
			check(body.a - gap.a > .03, "Pane fill is visibly distinct from the gap (%s)" % label)
			if is_equal_approx(opacity, .85):
				var rgb_difference := Vector3(body.r, body.g, body.b).distance_to(Vector3(gap.r, gap.g, gap.b))
				check(rgb_difference > 3.0 / 255.0, "Pane and gap render different colors (%s)" % label)
		else:
			check(absf(body.a - gap.a) < .005, "Zero opacity removes only the pane tint (%s)" % label)
	if is_equal_approx(opacity, .85):
		var output := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
		if not output.is_empty(): shot.save_png(output.path_join(label.validate_filename() + ".png"))

func play() -> void:
	# Replay check toasts would otherwise cover the pixels being measured.
	overlay.hide()
	if DisplayServer.get_name() == "headless":
		check(false, "Pane background regression requires GPU rendering")
		return
	await camera_at_rest()
	host.create_terminal_window(host.pane_focus, "h")
	var deadline := Time.get_ticks_msec() + 10000
	while host.sessions.size() != 2 and Time.get_ticks_msec() < deadline: await process_frame
	await owner_at_rest()
	check(host.sessions.size() == 2, "Production split creates two terminal panes")
	if host.sessions.size() != 2: return
	for path in ["", "flat-2d", ""]:
		check(host.switch_world(path), "Switch renderer: " + path)
		await hold(.5)
		await camera_at_rest()
		host.world.fx_enabled = false
		host.world._settle_camera_at_rest()
		host.world._apply_camera_fx()
		var view: Control = host.workspace_view
		var label: String = "flat-3d" if path.is_empty() else path
		for opacity in [0.0, .35, .85, 1.0]:
			host.world.terminal_config.background.alpha = opacity
			for gap in [8.0, 20.0]:
				host.workspace_layout.tab(host.workspace_layout.active).tree.tiling_gap = gap
				view.refresh()
				await hold(.15)
				await check_pane_backgrounds(opacity, "%s-alpha-%s-gap-%s" % [label, opacity, gap])
		host.world.terminal_config.background.alpha = .85
		view.tab_bar.hide()
		view.refresh()
		await hold(.15)
		await check_pane_backgrounds(.85, label + "-hidden-tabs")
		view.tab_bar.show()
		view.refresh()
