extends "../../tabs-and-panes/replays/stash-outside-main-area.gd"

func play() -> void:
	root.content_scale_size = Vector2i(1280, 800)
	await hold(.3)
	if not check(host.switch_world("bistro"), "Bistro opens from its menu manifest"): return
	_stay_awake()
	await camera_at_rest()
	if host.workspace_view.physics_enabled(): await view_menu("Floating Pane Physics")
	var view = host.workspace_view
	var first: String = host.pane_focus
	view.split_window("h", first)
	await hold(.5)
	var second: String = host.pane_focus
	view.split_window("h", second)
	await hold(.5)
	var third: String = host.pane_focus
	await camera_at_rest()
	var keys := [first, second, third]
	var pids := {}
	for key in keys:
		var id := int(key.substr(1))
		pids[key] = host.sessions[id].term.get_shell_pid()
		var style: StyleBoxFlat = view.panes[key].get_theme_stylebox("panel")
		check(is_equal_approx(style.bg_color.a, .85), "Pane %s has an 85%% opaque backdrop" % key)
		host.resource_monitor_for(id).set_interval(.2)
	await hold(1.0)
	# Force a complete draw: background Movie Maker windows may retain an
	# older subviewport even while the overlay continues to animate.
	await screen_image()
	var canvas_image: Image = view.canvas.get_texture().get_image()
	for key in keys:
		var pane: Control = view.panes[key]
		var sample_at: Vector2 = view.canvas.canvas_transform * (pane.position + pane.size * Vector2(.5, .8))
		# Canvas coordinates are logical pixels; its texture is supersampled.
		sample_at *= Vector2(canvas_image.get_size()) / Vector2(view.canvas.size_2d_override)
		var alpha := canvas_image.get_pixelv(Vector2i(sample_at)).a
		check(absf(alpha - .85) < .02, "%s renders an 85%% opaque blank background (%.3f at %s)" % [key, alpha, sample_at])
	await say("Zoom out: replace tiny toolbar buttons with per-pane resources")
	await point_at(content(Vector2(.5, .5)))
	await pinch(.4)
	await hold(1.0)
	var until: float = overlay.clock + 12
	while overlay.clock < until:
		var ready := true
		for key in keys:
			var data: Dictionary = host.resource_monitor_for(int(key.substr(1))).snapshot()
			ready = ready and data.get("cpu_valid", false) and data.get("memory_current", 0) > 0
		if ready: break
		await process_frame
	await hold(.4)
	var before := {}
	for key in keys:
		var hovered_header: Control = await hover_header(key)
		check(view.panes[key].compact_header and not hovered_header.has_part("chromium") and not hovered_header.has_part("split_right"), "%s hides its tiny toolbar" % key)
		var header: Label = view.pane_titles[key]
		check(header.text == view.panes[key].title_for_label(header) and header.get_theme_font_size("font_size") == 20, "%s preserves its original title and header height" % key)
		check(view._pane_screen_rect(view.panes[key]).grow(1.0).encloses(view.title_screen_rect(header)) and is_zero_approx(view.panes[key].texture.offset_bottom), "%s keeps its title inside the pane without shifting terminal content" % key)
		var caption: Control = view.status_strips.get(key)
		if not check(caption != null and caption.visible, "%s has a visible overview caption" % key): continue
		var status: Dictionary = view.pane_status[key]
		caption.render_now()
		var texts: PackedStringArray = caption.texts()
		check(str(status.label).begins_with(".%d (%%%s)" % [keys.find(key) + 1, key.substr(1)]) and status.label in texts and str(status.cpu).ends_with("%") and status.cpu in texts and str(status.memory).ends_with("M") and status.memory in texts, "%s shows its pane UID, live CPU and RAM" % key)
		# A narrow card sized to its content: label, CPU row, RAM row.
		check(caption.size.x <= 140 and caption.size.y >= 56 and caption.size.y <= 76, "%s uses a narrow multiline stats panel (size %s)" % [key, caption.size])
		var rect := func(id: String) -> Rect2: return caption.hit_rect(id)
		check(absf(rect.call("cpu-icon").position.x - rect.call("memory-icon").position.x) < .1 and absf(rect.call("cpu").position.x - rect.call("memory").position.x) < .1, "%s aligns its icon and value columns" % key)
		check(rect.call("label").position.y < rect.call("cpu").position.y and rect.call("cpu").position.y < rect.call("memory").position.y, "%s puts pane UID, CPU and RAM on separate lines" % key)
		for pair in [["cpu-icon", "cpu"], ["memory-icon", "memory"]]:
			check(absf(rect.call(pair[0]).get_center().y - rect.call(pair[1]).get_center().y) <= 1, "%s vertically centers each icon beside its value" % key)
		check(rect.call("cpu-icon").has_area() and rect.call("memory-icon").has_area() and not "CPU" in texts and not "RAM" in texts, "%s uses CPU and RAM icons instead of words" % key)
		check(caption.mouse_filter != Control.MOUSE_FILTER_STOP, "%s stats strip cannot intercept header clicks" % key)
		for pane in view.panes.values():
			check(not view.control_screen_rect(caption).intersects(view._pane_screen_rect(pane)), "%s stats stay outside terminal content" % key)
		before[key] = view.pane_rects[key]
		for other in keys:
			if other != key and view.status_strips.has(other):
				check(not view.control_screen_rect(caption).intersects(view.control_screen_rect(view.status_strips[other])), "Captions %s and %s do not overlap" % [key, other])
	await say("An unfocused pane's live CPU rises during a short workload")
	var first_id := int(first.substr(1))
	# Type only once the shell has drawn its prompt and gone quiet: startup
	# scripts that query the terminal can swallow input typed before that.
	var settled_text := ""
	var settled_since := Time.get_ticks_msec()
	var ready_deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < ready_deadline:
		var shown := terminal_text(first_id).strip_edges()
		if shown != settled_text:
			settled_text = shown
			settled_since = Time.get_ticks_msec()
		elif not shown.is_empty() and Time.get_ticks_msec() - settled_since >= 500:
			break
		await process_frame
	check(not settled_text.is_empty(), "The unfocused pane shows its shell prompt")
	# Busy for a fixed time, not a fixed amount of work: the monitor samples
	# about once a second and counts only live processes, so a workload that
	# finishes between samples on a fast machine would never be seen.
	host.sessions[first_id].term.send_text(("python -c" if OS.get_name() == "Windows" else "python3 -c") + " 'import time; end = time.time() + 6; [0 for _ in iter(lambda: time.time() < end, False)]'\n")
	var busy := false
	until = overlay.clock + 8
	while overlay.clock < until:
		var data: Dictionary = host.resource_monitor_for(first_id).snapshot()
		if data.get("cpu_valid", false) and float(data.get("cpu_percent", 0)) > 5:
			busy = true
			break
		await process_frame
	var running: Array = host.resource_monitor_for(first_id).snapshot().get("processes", []).map(func(process): return process.get("name"))
	check(busy, "The unfocused pane reports real CPU activity (processes %s, screen %s)" % [running, terminal_text(first_id).strip_edges().right(300)])
	await hold(.3)
	check(str(view.pane_status[first].cpu).to_float() > 5 and str(view.pane_status[first].label).begins_with(".1 (%%%s)" % first.substr(1)), "The visible caption updates CPU for the correct unfocused pane (cpu %s, label %s)" % [view.pane_status[first].cpu, view.pane_status[first].label])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.cache/bistro-overview"))
	(await screen_image()).save_png("res://.cache/bistro-overview/overview.png")
	await say("Zoom back in: restore pane controls")
	await pinch(2.5)
	await hold(.5)
	for key in keys:
		check(not view.panes[key].compact_header and not view.status_strips[key].visible, "%s restores its toolbar and hides overview stats" % key)
		check(view.pane_rects[key] == before[key] and host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key], "%s preserves its shell and layout" % key)
	(await screen_image()).save_png("res://.cache/bistro-overview/detail.png")
	await pinch(.4)
	await hold(.5)
	for key in keys: check(view.status_strips[key].visible, "%s restores the resource caption on repeated zoom-out" % key)

	await say("Near the top edge, stats move around panes without covering stdout")
	var top: float = view._pane_screen_rect(view.panes[first]).position.y
	view.pan_workspace(Vector2(0, top - 45) * (0.03 if OS.get_name() == "macOS" else 1.0), view.size * 0.5)
	await hold(.4)
	for key in keys:
		var caption: Control = view.status_strips[key]
		check(caption.visible, "%s finds space along another edge" % key)
		check(view._foreground_rect().grow(1).encloses(view.control_screen_rect(caption)), "%s stats stay fully on screen" % key)
		for pane in view.panes.values():
			check(not view.control_screen_rect(caption).intersects(view._pane_screen_rect(pane)), "%s edge placement leaves all terminal content clear" % key)
	(await screen_image()).save_png("res://.cache/bistro-overview/edge-placement.png")
