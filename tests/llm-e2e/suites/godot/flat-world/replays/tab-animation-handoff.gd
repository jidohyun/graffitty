extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/flat-world/tab-animation-handoff.md


## The printed lines, in window pixels: two rows just above the cursor.
func printed_lines() -> Rect2:
	var world: Node = host.world
	var cell: Vector2 = world.fx_cell_px
	var cursor: Vector2 = world._camera_cursor_uv() * world._sheet_size()
	var left: float = (world._terminal_sheet_origin() + Vector2(world.term.position)).x
	var lines := Rect2(Vector2(left, cursor.y - 3.0 * cell.y), Vector2(32.0 * cell.x, 2.4 * cell.y))
	return Rect2(
		host.workspace_view.window_point(lines.position),
		host.workspace_view.window_point(lines.end)
		- host.workspace_view.window_point(lines.position),
	)


## The focused window's title bar, in window pixels.
func title_bar() -> Rect2:
	var header: Control = host.workspace_view.panes[host.pane_focus].header
	return Rect2(on(header, Vector2.ZERO), on(header, Vector2.ONE) - on(header, Vector2.ZERO))


## Capture named frames around a tab switch.
##
## - The last frame before the click.
## - The first and last frames with pieces in flight.
## - The first frame after landing.
## - Any named fractions of the transition in `moments`.
func switch_frames(index: int, moments: Dictionary) -> Dictionary:
	# Tooltips belong to the tab strip, not the terminal being captured.
	for button in host.workspace_view.tab_bar.tabs.buttons.values():
		button.tooltip_text = ""
	await point_at(tab_grip(index))
	var flying: Array[bool] = []
	var at := { }
	var frames := await frames_during(
		tap,
		func():
			var t: float = host.world.tab_fx_t
			flying.append(t >= 0.0)
			var share: float = t / maxf(host.world.tab_fx_dur, 0.001)
			for name in moments:
				if t >= 0.0 and share >= moments[name].x and share < moments[name].y and not at.has(name):
					at[name] = root.get_texture().get_image()
					if name == "crossing":
						# Push/Pull moves whole panes: no separate letters or dust.
						at["whole"] = not host.world.tab_fx_out.is_empty() and not host.world.tab_fx_in.is_empty()
						for layer in host.world.tab_fx_out + host.world.tab_fx_in:
							at["whole"] = at["whole"] and layer.get_meta("depth_mode", false) and not layer.get_meta("glyph_layer", false)
					if name == "assembled":
						at["departed"] = not host.world.tab_fx_out.is_empty()
						for layer in host.world.tab_fx_out:
							at["departed"] = at["departed"] and layer._material().get_shader_parameter("fly") >= 1.0
			return not flying[-1],
	)
	check(flying[0], "The switch animates from the first frame after the click")
	# A window that nothing drew in time for is no evidence either way.
	var missed: Array = moments.keys().filter(
		func(name):
			return not at.has(name),
	)
	check(
		missed.is_empty(),
		"A frame was drawn for each moment checked%s"
		% ("" if missed.is_empty() else ", not for " + ", ".join(missed)),
	)
	for name in missed:
		at[name] = frames[0]
	at["before"] = frames[0]
	at["first"] = frames[1]
	at["last pieces"] = frames[-2]
	at["landed"] = frames[-1]
	return at


## How unlike two frames are in a window-pixel rectangle: mean luminance
## difference where they line up best, and by how many pixels that is.
func unlike(a: Image, b: Image, rect: Rect2) -> Dictionary:
	return best_shift(luma(a, rect), luma(b, rect))


## A handoff between neighbouring frames: the same text, in the same place, as
## sharp.
func check_handoff(a: Image, b: Image, rect: Rect2, label: String) -> void:
	var moved := unlike(a, b, rect)
	check(
		moved.shift == Vector2i.ZERO,
		"%s: the text does not shift (%s px)" % [label, moved.shift],
	)
	var sharp_a := edge_steepness(a, rect)
	var sharp_b := edge_steepness(b, rect)
	check(
		sharp_a > 0.1 and sharp_b >= sharp_a * 0.9,
		"%s: the text neither vanishes nor blurs (%.2f then %.2f)" % [label, sharp_a, sharp_b],
	)


## The share of `a`'s bright marks in a rectangle, a title bar's text and
## buttons, still there in `b`. Pieces flying across it only add marks.
func marks_kept(a: Image, b: Image, rect: Rect2) -> float:
	var before: Dictionary = luma(a, rect)
	var after: Dictionary = luma(b, rect)
	var sorted: PackedFloat32Array = before.v.duplicate()
	sorted.sort()
	var ground: float = sorted[sorted.size() / 2]
	var marks := 0
	var kept := 0
	for i in sorted.size():
		if before.v[i] > ground + 0.25:
			marks += 1
			if after.v[i] > ground + 0.15:
				kept += 1
	return float(kept) / marks if marks >= 20 else 0.0


## The window's frame is in `b` as in `a`; across a handoff, not a pixel off.
func check_frame_kept(a: Image, b: Image, bar: Rect2, label: String, handoff := false) -> void:
	var kept := marks_kept(a, b, bar)
	var moved: Vector2i = unlike(a, b, bar).shift if handoff else Vector2i.ZERO
	check(
		kept > (0.97 if handoff else 0.9) and moved == Vector2i.ZERO,
		"%s: the title bar is there%s (%d%% of it)"
		% [label, ", unmoved" if handoff else "", roundi(kept * 100.0)],
	)


func switch(index: int, leaving: String, arriving: String) -> void:
	var lines := printed_lines()
	var bar := title_bar()
	# Push/Pull: both tabs' whole panes share one dolly clock and crossfade
	# over the full transition. The assembled frame is drawn once at its end.
	var at := await switch_frames(
		index,
		{
			"crossing": Vector2(0.35, 0.65),
			"assembled": Vector2(1.0, INF),
		},
	)
	var landed_lines := printed_lines()
	var landed_bar := title_bar()
	var evidence := evidence_path("tab-handoff-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(evidence)
	for name in at:
		if at[name] is Image: at[name].save_png(evidence.path_join("%d-%s.png" % [index, name]))
	FileAccess.open(evidence.path_join("%d-regions.json" % index), FileAccess.WRITE).store_string(JSON.stringify({"bar":[bar.position.x,bar.position.y,bar.size.x,bar.size.y],"landed_bar":[landed_bar.position.x,landed_bar.position.y,landed_bar.size.x,landed_bar.size.y],"logical_size":[root.get_visible_rect().size.x,root.get_visible_rect().size.y]}))
	print("TAB_HANDOFF_EVIDENCE ", evidence)
	check_handoff(at.before, at.first, lines, "As %s text becomes pieces" % leaving)
	check_frame_kept(at.before, at.first, bar, "As %s text becomes pieces" % leaving, true)
	check(at.get("whole", false), "Both tabs cross as whole panes, with no separate letters or dust")
	check(marks_kept(at.before, at.crossing, bar) < 0.5, "Midway, %s frame has left its place with its text" % leaving)
	check(
		unlike(at.before, at.crossing, lines).difference > 0.02,
		"Midway, %s text has left its lines" % leaving,
	)
	check(
		# The arriving panes occupy these pixels by now. Every departing layer
		# must have completed its own motion before the live handoff.
		at.get("departed", false),
		"Once %s panes have gone, all departing layers have completed" % leaving,
	)
	var arriving_marks := marks_kept(at.landed, at.crossing, landed_bar)
	check(arriving_marks < .5,
		"Midway, %s frame is still approaching its place (%d%% of final marks)" % [arriving, roundi(arriving_marks * 100)])
	check(
		unlike(at.landed, at.crossing, landed_lines).difference > 0.02,
		"Midway, %s text is still on its way" % arriving,
	)
	check_handoff(at["last pieces"], at.landed, landed_lines, "As %s text lands" % arriving)
	check_frame_kept(at.landed, at["last pieces"], landed_bar, "As %s text lands" % arriving, true)


func play() -> void:
	use_config(get_script().resource_path.get_base_dir().path_join("../tab-animation-handoff.conf"))
	await open_tabs(2)
	for i in 2:
		await select_tab(i)
		# Startup inspection can precede the replay's logical viewport resize.
		# This fixed-view pixel comparison uses Main Area in both tabs.
		host.workspace_view.show_main()
		await camera_at_rest()
		await type("printf 'HANDOFF ALIGNMENT 0123456789\\nSECOND LINE 0123456789\\n'{enter}")
		# Hidden terminals do not render cells, so confirm the output while this
		# tab is the visible one.
		var deadline: float = overlay.clock + 10.0
		var shown := ""
		while overlay.clock < deadline:
			shown = terminal_text(host.active_session_id)
			if shown.contains("HANDOFF ALIGNMENT") and shown.contains("SECOND LINE 0123456789\n"): break
			await process_frame
		check(shown.contains("HANDOFF ALIGNMENT") and shown.contains("SECOND LINE"), "Setup: tab %d shows the printed lines" % (i + 1))
	await select_tab(0)
	await camera_at_rest()
	await hold(1.0)

	await say("Click the second tab and let the animation finish")
	await switch(1, "the first tab's", "the second tab's")

	await say("Switch back to the first tab and let it finish")
	await camera_at_rest()
	await switch(0, "the second tab's", "the first tab's")
