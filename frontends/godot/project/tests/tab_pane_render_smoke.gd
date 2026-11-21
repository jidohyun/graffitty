extends "../../../../tests/llm-e2e/replay/replay.gd"

func _initialize() -> void:
	super()
	if "--user-config" in OS.get_cmdline_user_args():
		OS.set_environment("XDG_CONFIG_HOME", OS.get_environment("HOME").path_join(".config"))

func play() -> void:
	if "--bistro" in OS.get_cmdline_user_args():
		host.switch_world("bistro")
		await hold(2.0)
	await camera_at_rest()
	host.world.fx_cfg.set_option("scene.tab_switch", "effect", "push_pull")
	host.world.tab_fx = true
	for i in (18 if "--many-tabs" in OS.get_cmdline_user_args() else 1):
		host.create_session()
		await hold(1.45)
		await _check_panes("arrival-%d" % i)
		await hold(2.0)
		await _check_panes("settled-%d" % i)
	var first: int = host.workspace_layout.active
	host.workspace_layout.tab(first).tree.tiling = false
	host.create_terminal_window(host.pane_focus)
	await hold(1.0)
	var original: Array = host.workspace_layout.tab(first).tree.windows.map(func(item): return item.pane)
	for key in original:
		host.sessions[int(key.substr(1))].term.send_text("printf 'TAB_RENDER_CHECK\\n'\r")
	await hold(2.0)
	host.create_session()
	await hold(2.0)
	var second: int = host.workspace_layout.active
	await _check_panes("new-second-tab")
	for i in 4:
		host.select_workspace(first)
		if i % 2 == 1:
			await hold(0.1)
			host.select_workspace(second)
			await hold(0.1)
			host.select_workspace(first)
		if i >= 2: host.workspace_view.show_overview()
		await hold(5.0)
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var frame: Image = root.get_texture().get_image()
			check(_white_fraction(frame) < 0.5, "Final composition is not solid white after interrupted zoom switches")
			frame.save_png("/tmp/graffitty-tab-switch-%d.png" % i)
			for key in original:
				var pane: Control = host.workspace_view.panes[key]
				var image: Image = pane.texture.texture.get_image()
				var white := 0
				var solid := 0
				for x in range(0, image.get_width(), 12):
					for y in range(0, image.get_height(), 12):
						var pixel := image.get_pixel(x, y)
						if pixel.a > 0.9: solid += 1
						if pixel.a > 0.9 and minf(pixel.r, minf(pixel.g, pixel.b)) > 0.9: white += 1
				check(_white_fraction(image) < 0.8, "Terminal is not a solid white texture after tab switch")
				print("RENDER ", key, " size=", image.get_size(), " white=", white, " solid=", solid)
		host.select_workspace(second)
		await hold(3.0)
		await _check_panes("return-second-%d" % i)

func _white_fraction(image: Image) -> float:
	var white := 0
	var samples := 0
	for x in range(0, image.get_width(), 12):
		for y in range(0, image.get_height(), 12):
			var pixel := image.get_pixel(x, y)
			samples += 1
			if pixel.a > 0.9 and minf(pixel.r, minf(pixel.g, pixel.b)) > 0.9: white += 1
	return float(white) / maxf(samples, 1)

func _check_panes(label: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	# The frame-copy mask must retain its transparent canvas-group mode.
	# Checking the source catches white snapshots even if the moving pane is
	# temporarily outside the camera frustum.
	var frame_count := 0
	for layer in host.world.tab_fx_in:
		if not layer.has_meta("panel"): continue
		frame_count += 1
		var source: Texture2D = layer._material().get_shader_parameter("terminal_tex")
		check(source != null and _white_fraction(source.get_image()) < 0.8,
			"%s: transition frame mask does not paint white" % label)
	if label.begins_with("arrival-"):
		check(frame_count > 0, "Arrival check samples actual transition frames")
	frame.save_png("/tmp/graffitty-white-%s.png" % label)
	var ratio := Vector2(frame.get_size()) / root.get_visible_rect().size
	for pane in host.workspace_view.panes.values():
		if not pane.visible: continue
		var white := 0
		var samples := 0
		for x in range(1, 10):
			for y in range(2, 10):
				var point: Vector2 = host.workspace_view.window_point(pane.position + pane.size * Vector2(x / 10.0, y / 10.0)) * ratio
				if not Rect2(Vector2.ZERO, frame.get_size()).has_point(point): continue
				var pixel := frame.get_pixelv(Vector2i(point))
				samples += 1
				if pixel.a > 0.9 and minf(pixel.r, minf(pixel.g, pixel.b)) > 0.9: white += 1
		check(samples == 0 or white < samples * 0.8, "%s %s: final pane is not white (%d/%d)" % [label, pane.key, white, samples])
