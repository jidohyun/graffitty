extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/flat-world/camera-zoom-tab-switch.md


func play() -> void:
	use_config(get_script().resource_path.get_base_dir().path_join("../camera-zoom-tab-switch.conf"))
	await open_tabs(2)
	await select_tab(0)
	await camera_at_rest()
	# Title containment applies while the title and cursor can both fit. Shell
	# startup banners otherwise move PowerShell's cursor below that footprint.
	await type("Clear-Host{enter}" if OS.get_name() == "Windows" else "clear{enter}")
	await hold(0.5)
	await say("Type in the first tab until the camera zooms in")
	for i in 3:
		# Keep the cursor near the title. Executing each line adds a complete
		# user-profile prompt, which can push their combined height beyond the
		# viewport at 2.5x zoom and invalidate this containment precondition.
		await type("echo zoom ")
		await hold(0.3)
	check(
		host.world.fx_camera.zoom > 1.8,
		"Typing zooms the camera in (%.2fx)" % host.world.fx_camera.zoom,
	)

	var view: Control = host.workspace_view
	var pane: Control = view.panes["%%%d" % host.active_session_id]
	var cursor_point: Vector2 = host.world._camera_cursor_uv() * host.world._sheet_size()
	check((view.view_point(cursor_point) - view.view_point(pane.position)).y < view.content_rect().size.y - 40,
		"Title and typing cursor fit together in the zoomed viewport")
	print("CAMERA_TITLE_GEOMETRY ", JSON.stringify({
		"title_y": view.view_point(pane.position).y,
		"content_top": view.content_rect().position.y,
		"cursor": str(host.world._camera_cursor_uv() * host.world._sheet_size()),
		"zoom": host.world.fx_camera.zoom,
	}))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(evidence_path("typing-zoom-title.png"))
	check(view.view_point(pane.position).y >= view.content_rect().position.y - 0.5,
		"Typing zoom preserves the pane title below the tab bar")

	await say("While zoomed in, click the second tab, then let it finish")
	await point_at(tab_grip(1))
	start_watching_camera()
	await press()
	await release()
	await camera_at_rest(10.0)
	var frames := stop_watching_camera()
	check(host.get_tabs()[1].active, "The second tab is active")
	check_no_jump_cut(frames, "Through the switch and back to idle")
	# Camera movement starts alongside cleanup; no hold phase is expected.
	var still := 0
	var longest := 0
	for i in range(1, frames.size()):
		still = still + 1 if frames[i].eye.is_equal_approx(frames[i - 1].eye) and frames[i].zoom > 1.05 else 0
		longest = maxi(longest, still)
	check(longest < 12, "The camera never freezes while zoomed (%d frames still)" % longest)
	check(
		absf(frames[-1].zoom - 1.0) < 0.01,
		"It eases back to idle (%.2fx at the end)" % frames[-1].zoom,
	)

	# Coordinate continuity alone cannot detect a one-frame lens/color change.
	await check_zoomed_appearance()


func appearance(image: Image) -> Dictionary:
	var total := Vector3.ZERO
	var edge := 0.0
	var samples := 0
	# Dense printed rows, away from tab chrome and the blinking prompt cursor.
	for y in range(140, 740, 2):
		for x in range(120, 1240, 2):
			var pixel := image.get_pixel(x, y)
			total += Vector3(pixel.r, pixel.g, pixel.b)
			edge += absf(pixel.get_luminance() - image.get_pixel(x + 1, y).get_luminance())
			samples += 1
	return {"color": total / samples, "edge": edge / samples}


func pixel_difference(a: Image, b: Image) -> float:
	var total := 0.0
	var samples := 0
	for y in range(140, 740, 2):
		for x in range(120, 1240, 2):
			var before := a.get_pixel(x, y)
			var after := b.get_pixel(x, y)
			total += absf(before.r - after.r) + absf(before.g - after.g) + absf(before.b - after.b)
			samples += 3
	return total / samples


func appearance_frame(directory: String, index: int) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(directory.path_join("%03d.png" % index))
	return image


func check_zoomed_appearance() -> void:
	var world: Node = host.world
	world.fx_cfg.set_option("state.typing", "camera.zoom", 1.8)
	world.fx_cfg.set_option("state.typing", "camera.tilt_limit_deg", 12.0)
	world.fx_cfg.set_option("state.typing", "camera.drift_px", 0.0)
	world.fx_cfg.set_option("state.typing", "typing.particles", "none")
	world.fx_cfg.set_option("state.typing", "sheet.ripple", 0.0)
	world.fx_cfg.set_option("scene.sheet", "typing_shape", "saddle")
	world.fx_cfg.set_option("behavior", "idle_after", 10.0)
	world._fx_apply_scene()
	for tab in 2:
		await select_tab(tab)
		await camera_at_rest()
		if OS.get_name() == "Windows":
			await keys("ctrl+c")
			await type("Clear-Host; 0..27 | ForEach-Object { Write-Output ('DEPTH {0:D2} ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ' -f $_) }{enter}")
		else:
			await keys("ctrl+u")
			await type("clear; i=0; while [ $i -lt 28 ]; do printf 'DEPTH %02d ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\\n' $i; i=$((i+1)); done{enter}")
		var terminal: Node = host.active_terminal()
		var deadline := Time.get_ticks_msec() + 10000
		while "DEPTH 27" not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
			await process_frame
		check("DEPTH 27" in str(terminal.get_text(false).text), "The real shell rendered the depth-of-field text fixture")
	# Depth uses whole panes and a different shader: exercise both stacking
	# directions while typing DOF and the curved sheet are still visible.
	#
	# Push/Pull is the only animated tab transition; letters and dust belong to
	# session switches.
	for destination in [1, 0]:
		var effect := "push_pull-to-%d" % destination
		world.fx_cfg.set_option("scene.tab_switch", "effect", "push_pull")
		world._fx_apply_scene()
		# Clicking an already active tab opens prefix commands, which would
		# consume the typing fixture and navigate away before the measured click.
		if not host.get_tabs()[1 - destination].active:
			await select_tab(1 - destination)
		await camera_at_rest()
		check(host.get_tabs()[1 - destination].active, effect + ": start on the source tab")
		await type("printf ZOOMED")
		await hold(0.8)
		await point_at(tab_grip(destination))
		await say("Switch while text is zoomed, blurred and tinted: " + effect)
		world.set_process(false)
		overlay.visible = false
		var directory := evidence_path("zoom-appearance-%d-%s" % [OS.get_process_id(), effect])
		DirAccess.make_dir_recursive_absolute(directory)
		print("ZOOM_APPEARANCE_EVIDENCE ", directory)
		var before := await appearance_frame(directory, 0)
		var initial_radius: float = world.terminal_effects.blur_radius
		check(initial_radius > 8.0 and world.ink_dof != null, effect + ": exercise visible typing DOF")
		var original := appearance(before)
		# A hidden native window can lose GUI hover during GPU readback. Refresh
		# it through the normal button helpers, keeping only the world frozen.
		await press()
		await release(MOUSE_BUTTON_LEFT, 0.0)
		await owner_at_rest()
		var captured := await appearance_frame(directory, 1)
		check(host.get_tabs()[destination].active and world.tab_fx_t >= 0.0,
			effect + ": the click starts a transition to the destination tab")
		var difference := pixel_difference(before, captured)
		var captured_appearance := appearance(captured)
		# Retained drawing state rerasterizes the full pane within the capture
		# budget; the live viewport can rasterize a smaller crop at higher density.
		#
		# The changed sampling phase contributes up to 2% RGB error on these dense
		# rows.
		#
		# Independently bound mean color much more tightly and keep the edge-energy
		# check, so resampling cannot hide tint or focus changes.
		check(difference < 0.02, effect + ": live-to-pieces preserves glyph coverage (pixel difference %.4f)" % difference)
		check(captured_appearance.color.distance_to(original.color) < 0.005,
			effect + ": live-to-pieces preserves mean color and brightness")
		check(absf(captured_appearance.edge / original.edge - 1.0) < 0.12,
			effect + ": capture keeps text sharpness (%.3f to %.3f)" % [original.edge, captured_appearance.edge])
		var previous_radius := initial_radius
		var previous_appearance := captured_appearance
		var last_assembled: Image
		var trace: Array = []
		var worst_lens_step := 0.0
		for frame in 140:
			# Fixed 60 Hz simulation: GPU readback must not skip the bad frames.
			world._process(1.0 / 60.0)
			var image := await appearance_frame(directory, frame + 2)
			var radius: float = world.terminal_effects.blur_radius
			worst_lens_step = maxf(worst_lens_step, absf(radius - previous_radius))
			trace.append({"frame": frame + 2, "radius": radius, "focus": world.terminal_effects.focus_depth, "transition": world.tab_fx_t})
			if frame < 2:
				var current := appearance(image)
				check(absf(current.edge / previous_appearance.edge - 1.0) < 0.15,
					effect + ": motion frame %d has no sharpness pop" % frame)
				check(current.color.distance_to(previous_appearance.color) < 0.035,
					effect + ": motion frame %d has no brightness/color flash" % frame)
				previous_appearance = current
			previous_radius = radius
			if world.tab_fx_t >= world.tab_fx_dur:
				last_assembled = image
			if world.tab_fx_t < 0.0 and world.tab_fx_in.is_empty():
				var settled := await appearance_frame(directory, frame + 3)
				check(last_assembled != null, effect + ": final assembled frame was rendered")
				if last_assembled != null:
					var landing_difference := pixel_difference(last_assembled, settled)
					check(landing_difference < 0.012, effect + ": pieces-to-live keeps brightness and blur (%.4f)" % landing_difference)
				break
		check(world.tab_fx_t < 0.0, effect + ": complete the tab flight")
		check(worst_lens_step < initial_radius * 0.1,
			effect + ": lens changes smoothly each frame (largest step %.3f px)" % worst_lens_step)
		FileAccess.open(directory.path_join("lens.json"), FileAccess.WRITE).store_string(JSON.stringify(trace))
		world.set_process(true)
		overlay.visible = true
		await camera_at_rest()
