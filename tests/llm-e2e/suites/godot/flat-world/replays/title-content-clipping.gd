extends "../../../../replay/replay.gd"

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var pane: Control = view.panes[host.pane_focus]
	var terminal: Control = host.sessions[host.active_session_id].term
	host.world.fx_enabled = false
	var grid: Vector2i = terminal.get_grid_size()
	terminal.send_text("printf '\\033[2J\\033[%d;1H\\033[38;2;0;255;0mBOTTOM_STATUS_VISIBLE\\033[0m\\033[1;1H'\r" % grid.y)
	await hold(.5)
	for zoom in [1.0, .7, .4, .25, 1.0]:
		view.overview = true
		view.navigation_center = pane.position + pane.size * .5
		view.navigation_zoom = zoom
		view._apply_navigation()
		await hold(.3)
		check(pane.texture.position.is_equal_approx(Vector2.ZERO) and pane.texture.size.is_equal_approx(pane.body.size), "Title masks top without translating or shrinking terminal at zoom " + str(zoom))
		check(terminal.get_grid_size() == grid, "Zoom retains PTY dimensions")
		if zoom < .5: check(pane.texture.material.get_shader_parameter("content_clip_top") > 0, "Large title masks the upper rows")
		if DisplayServer.get_name() != "headless":
			var shot := root.get_texture().get_image()
			shot.convert(Image.FORMAT_RGBA8)
			var bytes := shot.get_data()
			var green := 0
			for index in range(0, bytes.size(), 4):
				if bytes[index+1] > 80 and bytes[index+1] > bytes[index] * 2 and bytes[index+1] > bytes[index+2] * 2: green += 1
			check(green > 20, "Bottom status line stays rendered through zoom")

	if DisplayServer.get_name() != "headless":
		await check_tab_bar_clip(view)


func check_tab_bar_clip(view: Control) -> void:
	# A changing workspace overlay detects content leaking through transparent
	# gaps between tab controls, without masking the world background.
	var marker := ColorRect.new()
	marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	marker.size = host.layout_root.size
	marker.z_index = 100
	view.foreground_root.add_child(marker)
	var original_bottom: float = view.tab_bar.offset_bottom
	for height in [original_bottom, original_bottom + 24.0]:
		view.tab_bar.offset_bottom = height
		marker.color = Color.RED
		await hold(.15)
		var red := root.get_texture().get_image()
		marker.color = Color.GREEN
		await hold(.15)
		var green := root.get_texture().get_image()
		var density := float(red.get_height()) / float(root.size.y)
		var cutoff := ceili(view.tab_bar.get_global_rect().end.y * density)
		var leaked := 0
		var visible_below := 0
		for y in range(mini(cutoff + int(100 * density), red.get_height())):
			for x in range(0, red.get_width(), 4):
				var a := red.get_pixel(x, y)
				var b := green.get_pixel(x, y)
				if a.r > a.g + .5 and b.g > b.r + .5:
					if y < cutoff: leaked += 1
					else: visible_below += 1
		check(leaked == 0, "Workspace pixels stay out of the tab strip at height %.0f (%d leaked)" % [height, leaked])
		check(visible_below > 100, "Workspace still renders below the tab strip")
	view.tab_bar.offset_bottom = original_bottom
	marker.queue_free()
