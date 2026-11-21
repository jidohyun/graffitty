extends "../../../../replay/replay.gd"
var terminal: Control
var view: Control

## One trackpad pan event: `pixels` scrolls up when positive. `finger` and
## `momentum` are Chromium phase names, or empty for a device without phases.
func scroll_event(pixels: float, finger := "", momentum := "") -> void:
	var event := InputEventPanGesture.new()
	event.position = view.get_global_transform_with_canvas() * view.view_point(view.terminal_origin(host.pane_focus) + Vector2(150, 150))
	# Godot's macOS backend scales native scroll pixels by 0.03; others pass them through.
	event.delta = Vector2(0, -pixels * (.03 if OS.get_name() == "macOS" else 1.0))
	if not finger.is_empty(): event.set_meta("scroll_phase", finger)
	if not momentum.is_empty(): event.set_meta("momentum_phase", momentum)
	root.push_input(event, true)
	await hold(.03)

## A finger scroll of `steps` equal events, still down afterwards.
func finger_scroll(pixels: float, steps: int) -> void:
	await scroll_event(pixels, "began")
	for step in steps - 1:
		await scroll_event(pixels, "changed")

func scroll_position() -> float:
	return float(terminal.get_ui_state().scroll_offset) + terminal.get_scroll_fraction()

func settle(label: String) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	var previous := absf(terminal.get_scroll_stretch())
	var grew := false
	while terminal.get_scroll_stretch() != 0.0 and Time.get_ticks_msec() < deadline:
		await process_frame
		var now := absf(terminal.get_scroll_stretch())
		grew = grew or now > previous + .01
		previous = now
	check(terminal.get_scroll_stretch() == 0.0, label + ": the release settles with no pull left")
	check(not grew, label + ": a rested release only returns")

func play() -> void:
	await camera_at_rest()
	view = host.workspace_view
	terminal = host.sessions[host.active_session_id].term
	host.world.fx_enabled = false
	var grid: Vector2i = terminal.get_grid_size()
	var cell: Vector2 = terminal.get_cell_size()
	# A screen with nothing to scroll yet still pulls, both ways.
	check(int(terminal.get_ui_state().scroll_offset) == 0, "The fresh terminal has no scrollback")
	var pull: float = 200.0 / 20.0 / 15.0 * cell.y
	await finger_scroll(20, 10)
	check(absf(terminal.get_scroll_stretch() + pull) < .01, "An unscrollable screen pulls down")
	await hold(.2)
	await scroll_event(1, "changed")
	await scroll_event(0, "ended")
	await settle("Unscrollable, down")
	await finger_scroll(-20, 10)
	check(absf(terminal.get_scroll_stretch() - pull) < .01, "An unscrollable screen pulls up")
	await hold(.2)
	await scroll_event(-1, "changed")
	await scroll_event(0, "ended")
	await settle("Unscrollable, up")

	terminal.send_text("i=0; while [ $i -lt 160 ]; do c=$((i % 2)); if [ $c = 0 ]; then printf '\\033[48;2;255;0;0m'; else printf '\\033[48;2;0;255;0m'; fi; printf '%-" + str(grid.x - 1) + "s\\033[0m\\n' ROW_$i; i=$((i+1)); done\r")
	var deadline := Time.get_ticks_msec() + 5000
	while not str(terminal.get_text(true).text).contains("ROW_159") and Time.get_ticks_msec() < deadline:
		await process_frame
	check(str(terminal.get_text(true).text).contains("ROW_159"), "Numbered scrollback output has reached the terminal")
	await hold(.15)

	# Devices without phases stop at the edge.
	terminal.scroll_to_row(0)
	await hold(.1)
	await scroll_event(5000)
	check(scroll_position() == 0 and terminal.get_scroll_stretch() == 0.0, "An unphased scroll stops at the top")
	var wheel := InputEventMouseButton.new()
	wheel.device = REPLAY_POINTER_DEVICE
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.factor = 3.0
	wheel.pressed = true
	wheel.position = view.get_global_transform_with_canvas() * view.view_point(view.terminal_origin(host.pane_focus) + Vector2(150, 150))
	for turn in 6:
		root.push_input(wheel.duplicate(), true)
		await hold(.02)
	check(scroll_position() == 0 and terminal.get_scroll_stretch() == 0.0, "A mouse wheel never stretches the content")

	# 200 pixels past the top pull the text down by a twentieth of that,
	# in the terminal's 15 pixels per row.
	await finger_scroll(20, 10)
	var expected: float = -200.0 / 20.0 / 15.0 * cell.y
	print("RUBBER_BAND_PULL ", {"stretch": terminal.get_scroll_stretch(), "expected": expected, "cell": cell})
	check(absf(terminal.get_scroll_stretch() - expected) < .01, "A pull follows the fingers at one twentieth")
	check(scroll_position() == 0, "The viewport stays on the first row while pulled")
	var vp: SubViewport = host.sessions[host.active_session_id].vp
	var shot := vp.get_texture().get_image()
	var scale := Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
	# The first numbered row is red and sits below the prompt line that ran the loop.
	var first := 0
	var lines: PackedStringArray = str(terminal.get_text(true).text).split("\n")
	while first < lines.size() and not lines[first].begins_with("ROW_0"): first += 1
	var left := float(terminal.cell_padding) + cell.x * 20
	var top := float(terminal.cell_padding) + cell.y * first
	var sample := func(y: float) -> Color:
		return shot.get_pixelv(Vector2i((vp.canvas_transform * (terminal.position + Vector2(left, y))) * scale))
	var band_color: Color = sample.call(float(terminal.cell_padding) + absf(expected) * .5)
	var unmoved: Color = sample.call(top + 2.0)
	var moved: Color = sample.call(top + absf(expected) + 2.0)
	print("RUBBER_BAND_PIXELS ", {"first": first, "band": band_color, "unmoved": unmoved, "moved": moved})
	check(maxf(band_color.r, band_color.g) < .8, "The band above the first row shows the terminal background")
	check(not (unmoved.r > .8 and unmoved.g < .2), "The red row has left its resting place")
	check(moved.r > .8 and moved.g < .2, "The red row is drawn one pull lower")

	# Scrolling back gives up the pull before the content moves.
	await scroll_event(-5, "changed")
	check(scroll_position() == 0 and absf(terminal.get_scroll_stretch() - (expected + 5.0 / 15.0 * cell.y)) < .01, "Scrolling back first gives up the pull")
	# Rest so the lift carries no velocity, then lift.
	await hold(.2)
	await scroll_event(1, "changed")
	await scroll_event(0, "ended")
	check(terminal.get_scroll_stretch() != 0.0, "The lift waits briefly for momentum before releasing")
	await settle("Top")
	check(scroll_position() == 0, "The content is back on the first row")

	# Momentum into the edge overshoots and returns.
	terminal.scroll_to_row(2)
	await hold(.1)
	await scroll_event(20, "began")
	await scroll_event(20, "changed")
	await scroll_event(0, "ended")
	await scroll_event(0, "", "began")
	var peak := 0.0
	for step in 6:
		await scroll_event(40, "", "changed")
		peak = minf(peak, terminal.get_scroll_stretch())
	for frame in 20:
		await process_frame
		peak = minf(peak, terminal.get_scroll_stretch())
	await scroll_event(0, "", "ended")
	print("RUBBER_BAND_BOUNCE ", {"peak": peak})
	check(peak < -.5, "Momentum into the top overshoots")
	await settle("Bounce")
	check(scroll_position() == 0, "The bounce ends on the first row")

	# The live bottom pulls the other way.
	terminal.perform_action("scroll_bottom")
	await hold(.1)
	var bottom := scroll_position()
	await finger_scroll(-20, 10)
	check(absf(terminal.get_scroll_stretch() + expected) < .01, "The bottom pulls up by the same mapping")
	check(scroll_position() == bottom, "The viewport stays on the live rows while pulled")
	await hold(.2)
	await scroll_event(-1, "changed")
	await scroll_event(0, "ended")
	await settle("Bottom")

	# Applications that own scrolling are left alone.
	terminal.send_text("vim -Nu NONE -n -i NONE\r")
	deadline = Time.get_ticks_msec() + 5000
	while not terminal.get_ui_state().alternate_screen and Time.get_ticks_msec() < deadline:
		await process_frame
	check(terminal.get_ui_state().alternate_screen, "Vim has entered its alternate screen")
	await finger_scroll(20, 10)
	check(terminal.get_scroll_stretch() == 0.0, "A full-screen application does not stretch")
	await scroll_event(0, "ended")
	terminal.send_text("\u001b:q!\r")
	deadline = Time.get_ticks_msec() + 5000
	while terminal.get_ui_state().alternate_screen and Time.get_ticks_msec() < deadline:
		await process_frame
	check(not terminal.get_ui_state().alternate_screen, "Vim has returned to the normal screen")
