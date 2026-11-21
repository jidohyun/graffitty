extends "../../../../tests/llm-e2e/replay/replay.gd"

func play() -> void:
	await camera_at_rest()
	var term: Control = host.sessions[host.active_session_id].term
	term.send_text("printf 'TINY_FONT_CHECK\\n'\r")
	await hold(1.0)
	var previous := Vector2i.ZERO
	for size in [16, 5, 3, 2, 1]:
		host.world._set_terminal_font_size(size)
		await hold(0.5)
		check(term.get_live_font_size() == size, "Native terminal accepts size %d" % size)
		var grid: Vector2i = term.get_grid_size()
		check(grid.x >= previous.x and grid.y >= previous.y, "Smaller fonts preserve or increase usable cells")
		check(term.get_cell_size().x > 0 and term.get_cell_size().y > 0, "Tiny glyph metrics stay nonzero")
		previous = grid
		print("FONT size=", size, " grid=", grid, " cell=", term.get_cell_size())
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-tiny-font.png")
	host.world._set_terminal_font_size(2)
	await hold(0.5)
	check(term.get_live_font_size() == 2, "Enlarging from the minimum works immediately")
	host.world._set_terminal_font_size(16)
	await hold(0.5)
	check(term.get_live_font_size() == 16, "Normal font size restores")
