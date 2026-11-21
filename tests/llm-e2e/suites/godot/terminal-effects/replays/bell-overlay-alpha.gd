extends "../../tabs-and-panes/replays/main-area-tiling.gd"
var terminal: Control
var evidence: String
var bells := 0
var measurements: Array = []

func capture(label: String) -> Color:
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	picture.save_png(evidence.path_join(label + ".png"))
	var center := on(terminal, Vector2(.6, .6))
	var sample := Rect2i(Vector2i(center) - Vector2i(16, 16), Vector2i(32, 32))
	var color := Color(0, 0, 0, 0)
	for y in range(sample.position.y, sample.end.y):
		for x in range(sample.position.x, sample.end.x):
			color += picture.get_pixel(x, y)
	color /= 1024.0
	measurements.append({"stage": label, "sample": sample, "rgba": [color.r, color.g, color.b, color.a], "bells": bells})
	FileAccess.open(evidence.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(measurements, "  "))
	return color

func probe(label: String, alpha: float) -> float:
	terminal.configure_advanced({"visual_bell_duration_ms": 2000, "visual_bell_color": Color(1, 0, 0, alpha), "audible_bell": false})
	await hold(.2)
	var baseline := await capture(label + "-before")
	var previous := bells
	_send_key(KEY_B, 98, {})
	var deadline := Time.get_ticks_msec() + 5000
	while bells == previous and Time.get_ticks_msec() < deadline: await process_frame
	check(bells == previous + 1, label + ": real PTY BEL reaches the renderer")
	var peak := await capture(label + "-peak")
	await hold(1.0)
	var middle := await capture(label + "-middle")
	await hold(1.3)
	var after := await capture(label + "-after")
	check(absf(after.r - baseline.r) < .005 and absf(after.g - baseline.g) < .005 and absf(after.b - baseline.b) < .005, label + ": bell restores baseline pixels")
	if alpha == 0:
		check(absf(peak.r - baseline.r) < .005 and absf(peak.g - baseline.g) < .005, "Zero-alpha BEL does not change pixels")
	else:
		check(peak.r > middle.r + .02 and middle.r > baseline.r + .02, label + ": red tint decays through its lifetime")
	# Forward+ blends linear colors; PNGs contain sRGB display values.
	var base_linear := baseline.srgb_to_linear().r
	return (peak.srgb_to_linear().r - base_linear) / maxf(.01, 1.0 - base_linear)

func play() -> void:
	evidence = OS.get_environment("XDG_STATE_HOME").path_join("bell-alpha")
	DirAccess.make_dir_recursive_absolute(evidence)
	await camera_at_rest()
	if not await open_bistro(): return
	host.world.fx_enabled = false
	host.workspace_view.show_main(true)
	await camera_at_rest()
	terminal = host.sessions[host.active_session_id].term
	var pid: int = terminal.get_shell_pid()
	terminal.bell.connect(func(): bells += 1)
	var path: String = ProjectSettings.globalize_path(get_script().resource_path.get_base_dir().path_join("bell-probe.py"))
	await type("python '%s'{enter}" % path.replace("'", "''"))
	var deadline := Time.get_ticks_msec() + 15000
	while "BELL_READY" not in str(terminal.get_text(false).get("text", "")) and Time.get_ticks_msec() < deadline: await process_frame
	if not check("BELL_READY" in str(terminal.get_text(false).get("text", "")), "Raw console probe is ready"): return
	overlay.hide()
	terminal.set_live_background_opacity(1.0)
	var opaque := await probe("opaque", 1.0)
	var quarter := await probe("quarter", .25)
	check(opaque > .8 and absf(quarter / opaque - .25) < .08, "Configured quarter alpha produces a quarter-strength overlay")
	await probe("zero", 0.0)
	terminal.set_live_background_opacity(.4)
	await probe("translucent", .25)
	await cursor_interval()
	check(terminal.get_shell_pid() == pid, "All bell settings preserve the original shell")
	_send_key(KEY_Q, 113, {})
	overlay.show()

func cursor_interval() -> void:
	terminal.set_colors(Color(.1, .1, .1), Color.WHITE, Color.RED, PackedColorArray())
	terminal.configure_advanced({"cursor_blink": 1, "cursor_blink_interval_ms": 1000})
	_send_key(KEY_C, 99, {})
	var deadline := Time.get_ticks_msec() + 5000
	while terminal.get_cursor_cell() != Vector2i(9, 5) and Time.get_ticks_msec() < deadline: await process_frame
	if not check(terminal.get_cursor_cell() == Vector2i(9, 5), "The raw application positions its blinking bar"): return
	var counts: Array = []
	var cell: Vector2 = terminal.get_cell_size()
	var origin: Vector2 = terminal.get_cursor_anchor_local() - Vector2(0, cell.y)
	await RenderingServer.frame_post_draw
	var cursor: Rect2 = terminal.get_cursor_render_info().rect
	var transform: Transform2D = terminal.get_viewport().get_final_transform() * terminal.get_global_transform_with_canvas()
	var raster: Rect2 = transform * Rect2(origin + cursor.position * cell, cursor.size * cell)
	var sample := Rect2i(Vector2i(raster.position.floor()) - Vector2i(2, 2), Vector2i(raster.size.ceil()) + Vector2i(4, 4))
	for i in 5:
		await hold(.15 if i == 0 else .5)
		await RenderingServer.frame_post_draw
		var picture: Image = terminal.get_viewport().get_texture().get_image()
		picture.save_png(evidence.path_join("cursor-interval-%d.png" % i))
		var red := 0
		for y in range(sample.position.y, sample.end.y):
			for x in range(sample.position.x, sample.end.x):
				var pixel := picture.get_pixel(x, y)
				if pixel.r > .7 and pixel.g < .25 and pixel.b < .25: red += 1
		counts.append(red)
	measurements.append({"stage": "cursor-1000ms", "red_pixels": counts, "sample": sample})
	FileAccess.open(evidence.path_join("measurements.json"), FileAccess.WRITE).store_string(JSON.stringify(measurements, "  "))
	# A terminal blinks only while it and its native window hold focus. Background
	# replays never own the window, where the cursor is a steady hollow block.
	if terminal.get_window().has_focus():
		check(counts[0] > 0 and counts[1] > 0 and counts[2] == 0 and counts[3] == 0 and counts[4] > 0, "Integer cursor interval produces a one-second visible and hidden cycle: " + str(counts))
	else:
		check(counts[0] > 0 and counts.all(func(count): return count == counts[0]), "An unfocused window keeps a steady cursor: " + str(counts))
