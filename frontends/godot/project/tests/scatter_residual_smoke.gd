extends "../../../../tests/llm-e2e/replay/replay.gd"
## After chunks leave, neither pane backings nor the live sheet may retain ink.

func marked_pixels(name: String) -> int:
	overlay.hide()
	for _i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	var folder := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not folder.is_empty(): shot.save_png(folder.path_join(name + ".png"))
	var total := 0
	for y in shot.get_height():
		for x in shot.get_width():
			var p := shot.get_pixel(x, y)
			if p.r > .45 and p.b > .35 and p.g < minf(p.r, p.b) * .5: total += 1
	return total

func play() -> void:
	use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
	await labelled_tabs(["SOURCE", "DESTINATION"])
	await type("printf '\\033[38;2;255;0;255mSCATTER MUST REMOVE THIS TEXT FROM THE SHEET\\033[0m\\n'{enter}")
	await hold(.2)
	await camera_at_rest()
	check(await marked_pixels("live-source") > 100, "Coloured source text is visible before switching")
	await point_at(tab_grip(1))
	tap()
	var world: Node = host.world
	var deadline := Time.get_ticks_msec() + 3000
	while world.tab_fx_out.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	if not check(not world.tab_fx_out.is_empty(), "Outgoing production layers exist"): return
	world.set_process(false)
	# Show precisely the assembled capture, then retire only flying glyphs.
	# Keep all backings at their original pose to expose a duplicated live copy.
	for layer in world.tab_fx_out: layer.set_fly(world.tab_fx_out_target, 0.0)
	check(await marked_pixels("captured-source") > 100, "Capture really contains the departing text")
	for layer in world.tab_fx_out:
		if layer.get_meta("glyph_layer", false): layer.set_fly(world.tab_fx_out_target, 1.0)
	var leftover := await marked_pixels("after-glyph-departure")
	check(leftover == 0, "No stationary text remains after glyph departure: %d pixels" % leftover)
	world.set_process(true)
	await camera_at_rest()
	check(await marked_pixels("destination") == 0, "Departed source text does not return at handoff")
