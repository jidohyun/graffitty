extends SceneTree
## Both backends execute this scene and the same scoped virtual keyboard API.
var host: Node
var settings: Dictionary
var output := ""
var capturing := false
var render_index := 0
var frames: Array = []
var events: Array = []
var started_us := 0
var first_movie_frame := 0
var failure := ""
var peer: Node
const SESSION_NAMES := ["Files", "Project", "Code"]


func _initialize() -> void:
	preload("res://llm-e2e/replay/background.gd").install(self)
	root.unfocusable = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-settings="):
			settings = JSON.parse_string(
				FileAccess.get_file_as_string(arg.trim_prefix("--capture-settings="))
			)
	if settings.is_empty():
		push_error("Missing capture settings")
		quit(1)
		return
	root.size = Vector2i(settings.size[0], settings.size[1])
	root.min_size = root.size
	root.max_size = root.size
	output = settings.output
	RenderingServer.frame_pre_draw.connect(hide_pane_labels)
	RenderingServer.frame_post_draw.connect(record_frame)
	run.call_deferred()


func record_frame() -> void:
	if capturing:
		var elapsed := (Time.get_ticks_usec() - started_us) / 1000000.0
		if settings.backend == "live":
			var path := output.path_join("frames/frame%08d.png" % frames.size())
			if root.get_texture().get_image().save_png(path) != OK:
				failure = "Could not save live frame"
		frames.append({ "render_frame": render_index, "time": elapsed })
	render_index += 1


func visible_text() -> String:
	if not host.sessions.has(host.active_session_id): return ""
	# Render glyphs may be culled; readiness must read the terminal grid.
	return str(host.sessions[host.active_session_id].term.get_text(false).get("text", ""))


func input(method: String, params: Dictionary) -> void:
	var response: Dictionary = await host.agent_api.dispatch(host.active_session_id, method, params)
	events.append(
		{ "method": method, "params": params, "response": response, "frame": frames.size() }
	)
	if response.has("error"):
		failure = JSON.stringify(response.error)


func run() -> void:
	var client = load("res://scenes/terminal.tscn").instantiate()
	client.launch_args = OS.get_cmdline_user_args()
	root.add_child(client)
	var startup_deadline := Time.get_ticks_msec() + 20000
	while client.host == null and Time.get_ticks_msec() < startup_deadline:
		await process_frame
	if client.host == null:
		push_error("Recording session failed to start: " + client.status.text)
		quit(1)
		return
	host = client.host
	peer = preload("res://scenes/session/LiveSessionMenu.gd").transport(host)
	if settings.has("plugin") and host.current_plugin != settings.plugin:
		push_error("Requested world plugin failed to load")
		quit(1)
		return
	if not host.world.fx_cfg.warnings.is_empty():
		push_error("Invalid effect configuration: " + str(host.world.fx_cfg.warnings))
		quit(1)
		return
	for pair in host.sessions.values():
		for child in pair.vp.get_children():
			if child is Label:
				child.hide()
	# Present only the terminal, never application chrome or recording metadata.
	host.workspace_view.tab_bar.visible = settings.get("transition", "") == "tab"
	preload("res://scenes/ListDockSpace.gd").for_window(host.get_window()).set_panels_hidden(true)
	host.workspace_view.toolbar.hide()
	host.world.terminal_effects.particles.rng.seed = 1729
	var deadline := Time.get_ticks_msec() + 30000
	while not "CAPTURE_READY" in visible_text():
		if Time.get_ticks_msec() > deadline:
			root.get_texture().get_image().save_png(output.path_join("failed.png"))
			push_error("Shell did not reach CAPTURE_READY; visible text: " + visible_text())
			quit(1)
			return
		await process_frame
	if settings.get("demo", "") == "pane_zoom":
		await input("window.set_title", {"title": "Files"})
		host.session_backend.create_pane(host, host.pane_focus, "h")
		var split_deadline := Time.get_ticks_msec() + 15000
		while (host.sessions.size() < 2 or not "CAPTURE_READY" in visible_text()) and Time.get_ticks_msec() < split_deadline:
			await process_frame
		if host.sessions.size() < 2:
			push_error("Could not split the pane-zoom fixture")
			quit(1)
			return
	await input("window.set_title", {"title": "Terminal"})
	await input("terminal.type", { "text": "unsetopt PROMPT_SP; clear", "interval_ms": 0 })
	await input("terminal.press", { "key": "Enter" })
	await create_timer(0.8).timeout
	if settings.get("demo", "") == "adaptive_zoom":
		# Setup input must return to the overview before capture starts.
		await create_timer(7.0).timeout
	if not str(settings.get("transition", "")).is_empty():
		if settings.transition == "tab":
			for count in [2, 3]:
				host.session_backend.create_tab(host)
				var deadline_tabs := Time.get_ticks_msec() + 15000
				while host.get_tabs().size() < count and Time.get_ticks_msec() < deadline_tabs:
					await process_frame
				if host.get_tabs().size() < count:
					push_error("Could not create fixture tab")
					quit(1)
					return
		for tab in 3:
			await select_fixture(tab, true)
			await create_timer(0.8).timeout
			await input("window.set_title", {"title": SESSION_NAMES[tab]})
			if settings.transition == "tab": await input("tab.set_title", {"title": SESSION_NAMES[tab]})
			var command: String = "unsetopt PROMPT_SP; cp -r /opt/capture/scatter-demo/. .; clear; " + [
				"eza --long --all --color=always",
				"eza --tree --level=3 --color=always",
				"batcat --color=always --style=numbers --paging=never src/main.py",
			][tab]
			await input("terminal.type", {"text": command, "interval_ms": 0})
			await input("terminal.press", {"key": "Enter"})
			await create_timer(0.8).timeout
		await select_fixture(0, true)
		if settings.transition == "session":
			var dock = preload("res://scenes/ListDockSpace.gd").for_window(host.get_window())
			dock.set_panels_hidden(false)
			for panel in get_nodes_in_group("panel_window"):
				if panel.get_parent() == host.get_window(): panel._close_panel()
			await process_frame
			var panel = preload("res://scenes/session/SessionsDialog.gd").open(host)
			if panel == null or not dock.dock_default(panel._desktop, "left"):
				push_error("Could not show the compact session panel")
				quit(1)
				return
			panel.set_compact(true)
		await create_timer(2.8).timeout
	if settings.get("demo", "") == "cursor_motion":
		# Prepare a normal command line; the recording only navigates its text.
		await input(
			"terminal.type",
			{
				"text": "bindkey -e; bindkey '^[[H' beginning-of-line; bindkey '^[[F' end-of-line; clear",
				"interval_ms": 0,
			},
		)
		await input("terminal.press", { "key": "Enter" })
		await create_timer(0.4).timeout
		await input("terminal.type", { "text": "ls", "interval_ms": 0 })
		await input("terminal.press", { "key": "Enter" })
		await create_timer(0.4).timeout
		await input(
			"terminal.type",
			{ "text": "clear; ls; print -z $'ls\\ncd src\\nls'", "interval_ms": 0 },
		)
		await input("terminal.press", { "key": "Enter" })
		await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	first_movie_frame = render_index
	started_us = Time.get_ticks_usec()
	capturing = true
	if settings.backend == "movie":
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	var burst_before: int = host.world.terminal_effects.burst_count
	await create_timer(0.4).timeout
	if settings.get("demo", "") == "cursor_motion":
		for key in [
			"Home",
			"End",
			"ArrowUp",
			"ArrowUp",
			"ArrowDown",
			"ArrowDown",
			"Home",
			"ArrowRight",
			"End",
			"ArrowUp",
			"ArrowDown",
		]:
			await input("terminal.press", { "key": key })
			await create_timer(0.75).timeout
	elif settings.get("demo", "") == "adaptive_zoom":
		await create_timer(1.0).timeout
		for command in ["ls", "cd src", "ls"]:
			await input("terminal.type", {"text": command, "interval_ms": 160})
			# Show the fit before output changes its bounds.
			await create_timer(2.5).timeout
			await input("terminal.press", {"key": "Enter"})
			await create_timer(2.5).timeout
		await create_timer(5.0).timeout
	elif str(settings.get("transition", "")).is_empty():
		for command in ["ls", "cd src", "ls", "cd .."]:
			await input("terminal.type", { "text": command, "interval_ms": settings.interval_ms })
			await create_timer(0.25).timeout
			await input("terminal.press", { "key": "Enter" })
			await create_timer(0.6).timeout
	if not str(settings.get("transition", "")).is_empty():
		for tab in [1, 2, 0]:
			await select_fixture(tab, false)
			await create_timer(2.0).timeout
	await create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	capturing = false
	if settings.backend == "movie":
		Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	var movie_frames := int(Engine.get_singleton("GraffittyMovieWriter").frames_written()) if settings.backend == "movie" else 0
	var result := {
		"movie_frames": movie_frames,
		"backend": settings.backend,
		"effect": settings.effect,
		"first_movie_frame": first_movie_frame,
		"frames": frames,
		"events": events,
		"elapsed_seconds": (Time.get_ticks_usec() - started_us) / 1000000.0,
		"bursts": host.world.terminal_effects.burst_count - burst_before,
		"terminal_text": visible_text(),
		"size": [int(root.get_texture().get_size().x), int(root.get_texture().get_size().y)],
		"error": failure,
	}
	var file := FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("EFFECT_CAPTURE_PASS" if failure.is_empty() else "EFFECT_CAPTURE_FAIL: " + failure)
	host.queue_free()
	await process_frame
	await process_frame
	host = null
	quit(0 if failure.is_empty() else 1)


func select_fixture(index: int, instant: bool) -> void:
	if settings.transition == "tab":
		host.select_workspace(int(host.get_tabs()[index].id), instant)
	else:
		var response: Dictionary = await peer.request_action("session_switch", {"name": SESSION_NAMES[index]})
		if response.get("type") == "error":
			push_error("Could not switch fixture session: " + JSON.stringify(response))
			quit(1)
			return
		# The request acknowledges the server; wait for its topology to reach the UI.
		var deadline := Time.get_ticks_msec() + 15000
		while (not host.sessions.has(host.active_session_id) or host.session_switch_in_progress) and Time.get_ticks_msec() < deadline:
			await process_frame
		if not host.sessions.has(host.active_session_id) or host.session_switch_in_progress:
			push_error("Fixture session did not become ready")
			quit(1)


func hide_pane_labels() -> void:
	if not is_instance_valid(host) or not is_instance_valid(host.workspace_view): return
	# Preserve pane geometry while keeping titles out of effect footage.
	for pane in host.workspace_view.panes.values():
		pane.header.modulate.a = 0.0
	for label in host.workspace_view.pane_titles.values():
		label.modulate.a = 0.0
