extends "effects-settings.gd"
var sequence := 0
var directory: String
var terminal: Node

func command(bytes: String, cell: Vector2i) -> bool:
	sequence += 1
	FileAccess.open(directory.path_join("phase-%d.vt" % sequence), FileAccess.WRITE).store_string(bytes)
	var deadline := Time.get_ticks_msec() + 5000
	while terminal.get_cursor_cell() != cell and Time.get_ticks_msec() < deadline: await process_frame
	return check(terminal.get_cursor_cell() == cell, "Real PTY moves cursor to " + str(cell))

func capture(name: String) -> void:
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join(name + ".png"))

func configure(style: String, preset: String) -> void:
	var dialog := await open_settings()
	dialog.trail.select(Settings.TRAILS.find(style))
	dialog.particles.select(Settings.PARTICLES.find(preset))
	dialog.fields.pane.text = "1"
	dialog.fields.amount.text = "24"
	dialog.fields.scale.text = "2"
	dialog.fields.delay.text = "3"
	dialog.fields["blaze.duration"].text = ".5"
	dialog.fields["lightning.duration"].text = ".5"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Effects applied to this window.", "Effect configuration applies through controls")
	dialog.canceled.emit()
	await process_frame

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Effects raw reader starts in original PTY"): return
	var release: Callable = host.effect_control.hold(["camera.zoom", "camera.tilt", "camera.drift", "camera.shake", "sheet.ripple", "sheet.curvature"])
	await hold(1.0)
	overlay.hide()
	var renderer: Node = host.world.terminal_effects if host.world.terminal_effects != null else host.world.effects_2d
	var trace: Array = []
	for style in ["smear", "blaze", "lightning"]:
		await configure(style, "none")
		if not await command("\u001b[2J\u001b[2 q\u001b[5;5H", Vector2i(4, 4)): return
		await hold(1.2)
		var eye: Vector3 = host.world.proj_eye
		if not await command("\u001b[11;31H", Vector2i(30, 10)): return
		var deadline := Time.get_ticks_msec() + 1000
		while not renderer.trail.active and Time.get_ticks_msec() < deadline: await process_frame
		check(renderer.trail.active, style + " trail follows actual cursor movement")
		capture("trail-" + style + "-peak")
		await hold(1.5)
		capture("trail-" + style + "-after")
		check(not renderer.trail.active and host.world.proj_eye.distance_to(eye) < .0001, style + " decays without moving camera")
		trace.append({"style":style,"cursor":[30,10],"camera_motion":host.world.proj_eye.distance_to(eye)})
	# Hiding an application cursor must suppress its trail.
	sequence += 1
	FileAccess.open(directory.path_join("phase-%d.vt" % sequence), FileAccess.WRITE).store_string("\u001b[?25l\u001b[15;41H")
	await hold(.4)
	check(not renderer.trail.active, "Hidden application cursor suppresses trail")
	if not await command("\u001b[?25h\u001b[11;31H", Vector2i(30, 10)): return
	for preset in ["dots", "fireworks", "flames", "glitter", "sparks"]:
		await configure("off", preset)
		await hold(1.5)
		var previous: int = renderer.burst_count
		await press_key(KEY_X, 120)
		var deadline := Time.get_ticks_msec() + 1000
		while renderer.burst_count == previous and Time.get_ticks_msec() < deadline: await process_frame
		await hold(.04)
		check(renderer.burst_count > previous and renderer.particles.sparks.size() <= 2048, preset + " bursts stay bounded")
		capture("particles-" + preset)
		await configure("off", "none")
		await hold(1.5)
		capture("particles-" + preset + "-off")
		check(renderer.particles.sparks.is_empty(), preset + " particles fully expire")
	release.call()
	FileAccess.open(directory.path_join("effects-trace.json"), FileAccess.WRITE).store_string(JSON.stringify(trace, "  "))
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Effects probe records actual key input"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "xxxxx", "Visual effect controls leak no bytes into PTY")
	check(terminal.get_shell_pid() == pid, "Entire effect pixel matrix preserves original shell")
