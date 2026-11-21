extends "terminal-scrolling.gd"

func play() -> void:
	await camera_at_rest()
	view = host.workspace_view
	terminal = host.sessions[host.active_session_id].term
	terminal.set_live_font_family("JetBrainsMono Nerd Font")
	host.world.fx_enabled = true
	terminal.send_text("i=0; while [ $i -lt 120 ]; do printf '\\033[38;2;0;255;0m%03d MMMMMMMMMMMMMMMMMMMM\\033[0m\\n' $i; i=$((i+1)); done\r")
	await hold(.8)
	terminal.scroll_to_row(30)
	await hold(.15)
	var vp: SubViewport = host.sessions[host.active_session_id].vp
	for step in 24:
		await scroll_pixels(1.5 if step < 12 else -1.5)
		var shot := vp.get_texture().get_image()
		var screen := root.get_texture().get_image()
		var grid: Vector2i = terminal.get_grid_size()
		var cell: Vector2 = terminal.get_cell_size()
		var fraction: float = terminal.get_scroll_fraction()
		for row in range(2, grid.y - 2):
			var a := terminal.position + Vector2.ONE * float(terminal.cell_padding) + cell * Vector2(4, row - fraction)
			var b := a + cell * Vector2(18,1)
			a = vp.canvas_transform * a * Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
			b = vp.canvas_transform * b * Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
			var origin: Vector2 = view.terminal_origin(host.pane_focus) + terminal.position + Vector2.ONE * float(terminal.cell_padding)
			var screen_a: Vector2 = view.get_global_transform_with_canvas() * view.view_point(origin + cell * Vector2(4,row-fraction))
			var screen_b: Vector2 = view.get_global_transform_with_canvas() * view.view_point(origin + cell * Vector2(22,row+1-fraction))
			var screen_pixels := 0
			if Rect2(Vector2.ZERO, screen.get_size()).encloses(Rect2(screen_a,screen_b-screen_a)):
				for y in range(ceili(screen_a.y),floori(screen_b.y)):
					for x in range(ceili(screen_a.x),floori(screen_b.x)):
						var c := screen.get_pixel(x,y)
						if c.g > c.r * 1.3 and c.g > c.b * 1.3: screen_pixels += 1
				if screen_pixels < 30:
					screen.save_png("/tmp/scroll-composite-disappearing.png")
					check(false,"Composited row %d disappeared at step %d fraction %.3f" % [row,step,fraction])
			var pixels := 0
			for y in range(maxi(0,ceili(a.y)), mini(shot.get_height(), floori(b.y))):
				for x in range(maxi(0,ceili(a.x)), mini(shot.get_width(), floori(b.x))):
					var c := shot.get_pixel(x,y)
					if c.g > c.r * 1.3 and c.g > c.b * 1.3 and c.a > .2: pixels += 1
			if pixels < 50:
				shot.save_png("/tmp/scroll-disappearing.png")
				check(false, "Row %d disappeared at step %d fraction %.3f (%d pixels)" % [row,step,fraction,pixels])
	check(failures.is_empty(), "All glyph rows remain visible across fractional and integer scroll boundaries")

	# A pane rarely ends exactly on a cell boundary. Cover the physical bottom,
	# including the second partial row exposed by a fractional translation.
	terminal.send_text("i=0; while [ $i -lt 120 ]; do printf '\\033[38;2;0;255;0m%03d ████████████████████████\\033[0m\\n' $i; i=$((i+1)); done\r")
	await hold(.8)
	for fraction_target in [0.0, .25, .5, .75]:
		terminal.scroll_to_row(150)
		await scroll_pixels(-15.0 * fraction_target)
		var shot := vp.get_texture().get_image()
		var cell: Vector2 = terminal.get_cell_size()
		var scale := Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
		var local := terminal.position + Vector2(cell.x * 10, terminal.size.y - 2)
		var mapped := vp.canvas_transform * local * scale
		var color := shot.get_pixelv(Vector2i(mapped))
		check(color.g > .8 and color.r < .2, "Physical bottom remains filled at fraction %.2f" % fraction_target)
		if color.g < .8: shot.save_png("/tmp/scroll-bottom-gap-%s.png" % fraction_target)

		var screen := root.get_texture().get_image()
		var point: Vector2 = view.get_global_transform_with_canvas() * view.view_point(view.terminal_origin(host.pane_focus) + local)
		var displayed := screen.get_pixelv(Vector2i(point))
		check(displayed.g > displayed.r * 1.3 and displayed.g > .3, "Composited bottom remains filled at fraction %.2f" % fraction_target)
		if displayed.g < .3: screen.save_png("/tmp/scroll-bottom-composite-%s.png" % fraction_target)

		var saved_clipboard := DisplayServer.clipboard_get()
		var row := floori((terminal.size.y - 2) / cell.y + terminal.get_scroll_fraction())
		var expected: String = str(terminal.get_text(true).text).split("\n")[int(terminal.get_ui_state().scroll_offset) + row].strip_edges().get_slice(" ", 0)
		var click_point: Vector2 = view.get_global_transform_with_canvas() * view.view_point(view.terminal_origin(host.pane_focus) + terminal.position + Vector2(cell.x * 1.5, terminal.size.y - 2))
		for repeat in 2:
			var click := InputEventMouseButton.new()
			click.device = REPLAY_POINTER_DEVICE
			click.button_index = MOUSE_BUTTON_LEFT
			click.position = click_point
			click.pressed = true
			root.push_input(click, true)
			click = click.duplicate()
			click.pressed = false
			root.push_input(click, true)
		terminal.perform_action("copy")
		check(DisplayServer.clipboard_get() == expected, "Copy selects the physical bottom row at fraction %.2f" % fraction_target)
		DisplayServer.clipboard_set(saved_clipboard)
		await hold(.6)
