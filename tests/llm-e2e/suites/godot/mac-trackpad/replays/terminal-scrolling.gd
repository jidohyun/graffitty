extends "../../../../replay/replay.gd"
var terminal: Control
var view: Control

func inject_scroll(pixels: float) -> void:
	var event := InputEventPanGesture.new()
	event.position = view.get_global_transform_with_canvas() * view.view_point(view.terminal_origin(host.pane_focus) + Vector2(150, 150))
	# Godot's macOS backend scales native scroll pixels by 0.03; others pass them through.
	event.delta = Vector2(0, -pixels * (.03 if OS.get_name() == "macOS" else 1.0))
	root.push_input(event, true)

func scroll_pixels(pixels: float) -> void:
	inject_scroll(pixels)
	await hold(.04)

func position() -> float:
	return float(terminal.get_ui_state().scroll_offset) + terminal.get_scroll_fraction()

func play() -> void:
	await camera_at_rest()
	view = host.workspace_view
	terminal = host.sessions[host.active_session_id].term
	host.world.fx_enabled = false
	var grid: Vector2i = terminal.get_grid_size()
	# Each numbered output line must occupy one physical row at this window size.
	# A fixed 120-column pad wraps into blank rows on a narrower shared pane.
	terminal.send_text("i=0; while [ $i -lt 160 ]; do c=$((i % 2)); if [ $c = 0 ]; then printf '\\033[48;2;255;0;0m'; else printf '\\033[48;2;0;255;0m'; fi; printf '%-" + str(grid.x - 1) + "s\\033[0m\\n' ROW_$i; i=$((i+1)); done\r")
	var output_deadline := Time.get_ticks_msec() + 5000
	while not str(terminal.get_text(true).text).contains("ROW_159") and Time.get_ticks_msec() < output_deadline:
		await process_frame
	check(str(terminal.get_text(true).text).contains("ROW_159"), "Numbered scrollback output has reached the shared terminal")
	await hold(.15)
	terminal.scroll_to_row(40)
	await hold(.15)
	var before := position()
	await scroll_pixels(1.5)
	check(absf(position() - (before - .1)) < .001, "Tiny scroll immediately moves a tenth of a row")
	await scroll_pixels(-.75)
	check(absf(position() - (before - .05)) < .001, "Direction reversal has no accumulated dead zone")
	await scroll_pixels(150)
	check(absf(position() - (before - 10.05)) < .001, "150 trackpad units scroll ten rows")
	# Quarter-row scroll exposes part of the next viewport's last row.
	terminal.scroll_to_row(40)
	await scroll_pixels(-3.75)
	check(is_equal_approx(terminal.get_scroll_fraction(), .25), "Viewport can rest between rows")
	var vp: SubViewport = host.sessions[host.active_session_id].vp
	var shot := vp.get_texture().get_image()
	var cell: Vector2 = terminal.get_cell_size()
	var bottom := terminal.position + Vector2(float(terminal.cell_padding) + cell.x * 50, float(terminal.cell_padding) + cell.y * (grid.y - .1))
	var mapped: Vector2 = vp.canvas_transform * bottom
	mapped *= Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
	var color := shot.get_pixelv(Vector2i(mapped))
	check(maxf(color.r, color.g) > .8 and color.b < .1, "Extra bottom row is rendered rather than a blank strip")
	check(terminal.get_grid_size() == grid, "Fractional rendering does not resize the PTY")
	var expected: String = str(terminal.get_text(true).text).split("\n")[40 + grid.y].strip_edges()
	var saved_clipboard := DisplayServer.clipboard_get()
	var click := InputEventMouseButton.new()
	click.device = REPLAY_POINTER_DEVICE
	click.button_index = MOUSE_BUTTON_LEFT
	click.double_click = true
	click.pressed = true
	var selected_point: Vector2 = view.terminal_origin(host.pane_focus) + terminal.position + Vector2(float(terminal.cell_padding) + cell.x * 2.5, float(terminal.cell_padding) + cell.y * (grid.y - .1))
	click.position = view.get_global_transform_with_canvas() * view.view_point(selected_point)
	for repeat in 2:
		click = click.duplicate()
		click.pressed = true
		root.push_input(click, true)
		click = click.duplicate()
		click.pressed = false
		root.push_input(click, true)
	terminal.perform_action("copy")
	print("SCROLL_SELECTION ", {"expected": expected, "copied": DisplayServer.clipboard_get(), "point": selected_point, "terminal_position": terminal.position, "terminal_origin": view.terminal_origin(host.pane_focus)})
	check(not expected.is_empty() and DisplayServer.clipboard_get() == expected, "Selection and copy address the partially exposed bottom row")
	DisplayServer.clipboard_set(saved_clipboard)

	var latencies: Array[float] = []
	for sample in 12:
		await RenderingServer.frame_post_draw
		var painted := [0]
		var watcher := func():
			if painted[0] == 0: painted[0] = Time.get_ticks_usec()
		terminal.frame_changed.connect(watcher)
		var start := Time.get_ticks_usec()
		inject_scroll(1.5 if sample % 2 == 0 else -1.5)
		while painted[0] == 0 and Time.get_ticks_usec() - start < 1_000_000:
			await process_frame
		terminal.frame_changed.disconnect(watcher)
		check(painted[0] > 0, "Fractional input requests a terminal repaint")
		if painted[0] > 0: latencies.append((painted[0] - start) / 1000.0)
	latencies.sort()
	if not latencies.is_empty(): print("SCROLL_TIMING ", {"input_to_paint_p50_ms":latencies[latencies.size()/2],"p95_ms":latencies[ceili(latencies.size()*.95)-1],"fps_limit":Engine.max_fps})
	terminal.scroll_to_row(0)
	await scroll_pixels(5000)
	check(position() == 0, "Top boundary clamps without overscroll")
	terminal.perform_action("scroll_bottom")
	await scroll_pixels(-5000)
	check(terminal.get_scroll_fraction() == 0, "Live bottom has no fractional blank space")
	await scroll_pixels(1.5)
	terminal.send_text("vim -Nu NONE -n -i NONE\r")
	var deadline := Time.get_ticks_msec() + 5000
	while not terminal.get_ui_state().alternate_screen and Time.get_ticks_msec() < deadline:
		await process_frame
	if not terminal.get_ui_state().alternate_screen:
		print("SCROLL_VIM_STARTUP ", terminal.get_text(false))
	check(terminal.get_ui_state().alternate_screen, "Vim has entered its alternate screen before scrolling")
	await scroll_pixels(1.5)
	check(terminal.get_ui_state().alternate_screen and terminal.get_scroll_fraction() == 0, "Full-screen app remains row-based")
	terminal.send_text("\u001b:q!\r")
	deadline = Time.get_ticks_msec() + 5000
	while terminal.get_ui_state().alternate_screen and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not terminal.get_ui_state().alternate_screen, "Vim has returned to the normal screen")
	terminal.scroll_to_row(40)
	await scroll_pixels(1.5)
	terminal.send_text("printf 'SCROLL_RESET_OK\\n'\r")
	await hold(.3)
	check(terminal.get_scroll_fraction() == 0, "Typing returns cleanly to the live prompt")

	var font_size: int = terminal.get_live_font_size()
	terminal.set_live_font_size(font_size + 4)
	await hold(.25)
	terminal.scroll_to_row(40)
	await scroll_pixels(150)
	check(absf(position() - 30) < .001, "Larger text does not slow trackpad scroll distance")
	terminal.set_live_font_size(font_size)
