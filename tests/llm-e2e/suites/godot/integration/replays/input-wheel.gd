extends "input-routing.gd"
## Windows native viewport scroll events over real shell history.

func position_of(terminal: Node) -> float:
	var state: Dictionary = terminal.get_ui_state()
	return float(state.scroll_offset) + float(state.scroll_fraction)

func pan(viewport: SubViewport, location: Vector2, pixels: float) -> void:
	var event := InputEventPanGesture.new()
	event.position = location
	event.delta = Vector2(0, pixels)
	viewport.push_input(event, true)
	await process_frame

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("1..160 | ForEach-Object { 'row {0:D3} needle' -f $_ }; Write-Output ('WHEEL_' + 'READY'){enter}")
	var deadline := Time.get_ticks_msec() + 15000
	while "WHEEL_READY" not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check("WHEEL_READY" in str(terminal.get_text(false).text), "Real shell supplies numbered history"):
		return
	var viewport: SubViewport = host.sessions[host.active_session_id].vp
	preload("res://scenes/TerminalViewportInput.gd").set_pointer_inside(viewport, true)
	var config := Config.new()
	config.copy_on_select = "none"
	var observations: Array = []
	for font in [16, 24, 32]:
		host.world._set_terminal_font_size(font)
		await owner_at_rest()
		await hold(.3)
		if not check(terminal.get_live_font_size() == font, "Pane retains requested font size %d" % font):
			return
		config.scroll_multiplier = 1.0
		config.apply_live(terminal)
		terminal.scroll_to_row(20)
		await process_frame
		var location: Vector2 = terminal.get_global_transform() * (Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * Vector2(4.5, 3.5))
		var start := position_of(terminal)
		await pan(viewport, location, 7.5)
		var half := position_of(terminal)
		check(is_equal_approx(half - start, .5), "Font %d: first precision motion retains half a row" % font)
		await process_frame
		RenderingServer.force_draw(false)
		viewport.get_texture().get_image().save_png(directory.path_join("half-row-font-%d.png" % font))
		await pan(viewport, location, 7.5)
		var whole := position_of(terminal)
		check(is_equal_approx(whole - start, 1.0), "Font %d: two precision motions scroll one row" % font)
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		event.position = location
		event.factor = 1.0
		for down in [true, false]:
			event.pressed = down
			viewport.push_input(event, true)
			await process_frame
		var notch := position_of(terminal)
		check(is_equal_approx(notch - whole, 3.0), "Font %d: discrete notch scrolls three rows and release adds none" % font)
		config.scroll_multiplier = 2.0
		config.apply_live(terminal)
		await pan(viewport, location, 7.5)
		var doubled := position_of(terminal)
		check(is_equal_approx(doubled - notch, 1.0), "Font %d: multiplier doubles precision movement" % font)
		config.scroll_multiplier = 0.0
		config.apply_live(terminal)
		await pan(viewport, location, 15.0)
		check(is_equal_approx(position_of(terminal), doubled), "Font %d: disabled multiplier preserves viewport" % font)
		observations.append({"font": font, "cell": str(terminal.get_cell_size()), "start": start, "half": half, "whole": whole, "notch": notch, "doubled": doubled, "disabled": position_of(terminal)})
	FileAccess.open(directory.path_join("wheel-observations.json"), FileAccess.WRITE).store_string(JSON.stringify(observations, "  "))
	check(terminal.get_shell_pid() == pid, "Font and wheel controls retain the original shell")
