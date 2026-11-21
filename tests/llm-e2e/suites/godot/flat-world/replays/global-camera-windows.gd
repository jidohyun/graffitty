extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/flat-world/global-camera-windows.md


## Adaptive framing is the default zoom mode; this case exercises the fixed
## typing zoom, so select it as `[effects.camera] zoom_mode = "typing"` does.
func use_typing_zoom(zoom: float) -> void:
	var world: Node = host.world
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "typing")
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", zoom)
	world._fx_apply_scene()


func play() -> void:
	use_typing_zoom(1.15)
	await labelled_tabs(["ALPHA", "BRAVO"])
	# Finish selecting the source before setup's drag. Otherwise the tab flight
	# can still be changing the input surface during Movie Maker's paced press.
	await select_tab(tab_index("BRAVO"))
	await camera_at_rest()
	await say("Merge BRAVO into ALPHA")
	await merge_tab("BRAVO", "ALPHA")
	check(host.get_tabs().size() == 1, "Setup merged both panes into one tab")
	if host.get_tabs().size() != 1:
		return
	await say("Setup: the two windows side by side")
	var view: Control = host.workspace_view
	# Narrow enough that, zoomed in on one, part of the other stays in view.
	var width := view.size.x * 0.34
	var left := (view.size.x - 2.0 * width - 24.0) * 0.5
	view.set_window_rect(
		window("ALPHA").key,
		Rect2(left, view.BAR_HEIGHT + 24, width, view.size.y * 0.6),
	)
	view.set_window_rect(
		window("BRAVO").key,
		Rect2(left + width + 24.0, view.BAR_HEIGHT + 24, width, view.size.y * 0.6),
	)
	await camera_at_rest()
	await panes_at_rest()
	var alpha_at_rest := on(handle("ALPHA"))
	var bravo_at_rest := on(handle("BRAVO"))

	await say("Click inside BRAVO and type steadily")
	var bravo_point := visible_point(window("BRAVO").body)
	await click(bravo_point)
	for i in 5:
		await type("echo bravo{enter}")
		await hold(0.4)
	var world: Node = host.world
	var typing_zoom := float(world.fx_cfg.frame("typing")["camera.zoom"])
	check(
		host.pane_focus == window("BRAVO").key
		and screen_text("BRAVO").contains("echo bravo") and typing_zoom > 1.0
		and absf(world.fx_camera.zoom - typing_zoom) < 0.03,
		"BRAVO takes the keyboard and the camera zooms toward it (%.2fx)" % world.fx_camera.zoom,
	)
	check(
		on(handle("ALPHA")).distance_to(alpha_at_rest) > 20,
		"ALPHA moves with the one camera instead of staying put",
	)
	check(
		world.fx_camera.tilt.length() <= deg_to_rad(world.fx_tilt_limit_deg) * 1.42 + 1e-4,
		"The lean stays within its limit",
	)

	await say("Type a bit more, then click inside the visible part of ALPHA")
	await type("echo more{enter}")
	var alpha_point := visible_point(window("ALPHA").body)
	check(alpha_point.is_finite(), "Part of ALPHA is on screen while zoomed")
	start_watching_camera()
	await click(alpha_point)
	await type("echo alpha{enter}")
	await hold(1.5)
	var frames := stop_watching_camera()
	check(
		host.pane_focus == window("ALPHA").key and screen_text("ALPHA").contains("echo alpha")
		and not screen_text("BRAVO").contains("echo alpha"),
		"ALPHA takes the keyboard: the text typed after the click appears in ALPHA",
	)
	check_no_jump_cut(frames, "The camera glides to ALPHA's cursor")

	await say("Stop typing; then pinch over empty background: the whole scene zooms")
	await camera_at_rest(10.0)
	await point_at(content(Vector2(0.5, 0.93)))
	var before: float = on(handle("ALPHA")).distance_to(on(handle("BRAVO")))
	await pinch(1.25)
	await hold(0.2)
	check(
		absf(on(handle("ALPHA")).distance_to(on(handle("BRAVO"))) / before - 1.25) < 0.05,
		"A pinch anywhere zooms the one camera (%.2fx)" % (on(handle("ALPHA")).distance_to(on(handle("BRAVO"))) / before),
	)
	await pinch(0.8)
	await camera_at_rest(10.0)
	var off := maxf(
		on(handle("ALPHA")).distance_to(alpha_at_rest),
		on(handle("BRAVO")).distance_to(bravo_at_rest),
	)
	check(
		off < 0.5,
		"At rest both windows are back exactly where they were arranged (%.2f px off)" % off,
	)
