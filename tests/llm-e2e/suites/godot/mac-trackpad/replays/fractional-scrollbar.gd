extends "terminal-scrolling.gd"

func play() -> void:
	await camera_at_rest()
	view = host.workspace_view
	terminal = host.sessions[host.active_session_id].term
	host.world.fx_enabled = false
	terminal.send_text("i=0; while [ $i -lt 160 ]; do printf 'ROW_%03d\\n' $i; i=$((i+1)); done\r")
	await hold(.8)
	var bar: VScrollBar = host.ui.create_scroll_bar()
	root.add_child(bar)
	bar.position = Vector2(1550, 100)
	bar.size = Vector2(24, 800)
	var model: Node = host.session_model(host.active_session_id)
	terminal.scroll_to_row(40)
	await hold(.15)
	check(terminal.has_signal("ui_state_changed"), "Terminal metadata updates are event-driven")
	await scroll_pixels(1.5)
	check(absf(position() - 39.9) < .001, "Trackpad moves terminal to a fractional row")
	check(absf(bar.value - position()) < .001, "Scrollbar tracks fractional content position within one rendered update")
	await scroll_pixels(-.75)
	check(absf(bar.value - 39.95) < .001, "Scrollbar reverses smoothly with the content")
	check(bar.custom_step == 1, "Scrollbar arrows retain a one-row step")
	check(bar.step == 0, "Scrollbar does not snap drag input to whole rows")
	bar.value = 45.375
	await hold(.04)
	check(absf(position() - 45.375) < .001, "Scrollbar input preserves its fractional position in the terminal")
	check(absf(model.scroll_offset - position()) < .001, "Session state preserves the scrollbar fraction")
	check(absf(bar.value - position()) < .001, "Scrollbar feedback does not round the position")
	bar.value = bar.max_value
	await hold(.04)
	check(terminal.get_scroll_fraction() == 0 and model.scroll_snapshot().at_bottom, "Scrollbar reaches the live bottom without a fractional remainder")
	bar.queue_free()
