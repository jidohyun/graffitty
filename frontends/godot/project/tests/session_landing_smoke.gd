extends "res://tests/session_effects_smoke.gd"
## Compare an off-canvas terminal's assembled flight with its live presentation.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
var traces: Array = []

func settled(host: Node) -> bool:
	return not host.session_switch_in_progress and host.world.tab_fx_t < 0.0 and not host.world.tab_fx_preparing

func prepare(host: Node, name: String, offset: float) -> void:
	await client.connection.request_action("session_switch", {"name": name})
	if not await until(func(): return settled(host) and host.active_terminal() != null):
		check(false, "Prepare " + name)
		return
	var view: Control = host.workspace_view
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	var key: String = host.pane_focus
	var pane: Dictionary = Layout.find(group.tree, key)
	pane["rect"] = Rect2(offset, 100, 1400, 900)
	pane["stashed"] = false
	pane["graph_floating"] = true
	view.overview = true
	view.navigation_center = Vector2(offset + 700, 550)
	view.navigation_zoom = .55
	view.refresh()
	view._apply_navigation()
	host.session_backend.commit_workspace(host)
	await create_timer(.7).timeout
	# Static, asymmetric blocks reveal both missing pixels and wrong UV mapping.
	client.connection.send_input(host.active_session_id, ("PS1=''; printf '\\033[2J\\033[H\\033[?25l\\033[48;2;255;0;255m\\033[6;12H                    \\033[7;12H                    \\033[8;12H                    \\033[48;2;0;255;255m\\033[15;45H          \\033[16;45H          \\033[0m\\033[25;1HLANDING_READY'\r").to_utf8_buffer())
	check(await until(func(): return "LANDING_READY" in str(host.active_terminal().get_text(false).get("text", ""))), "Paint marker in " + name)
	await create_timer(.3).timeout
	view.save_navigation()

func snapshot(host: Node, label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(evidence.path_join(label + ".png"))
	var panes := []
	for key in host.workspace_view.panes:
		if not host.is_terminal_pane(key): continue
		var pair: Dictionary = host.sessions[int(key.substr(1))]
		panes.append({"key":key, "position":str(host.workspace_view.panes[key].position),
			"size":str(pair.term.size), "grid":str(pair.term.get_grid_size()),
			"viewport":str(pair.vp.size), "crop":str(pair.vp.canvas_transform),
			"active":pair.term.is_render_active(), "painted":pair.term.is_render_snapshot_ready()})
	traces.append({"frame":label,"time":host.world.tab_fx_t,"panes":panes})

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		quit(2)
		return
	root.size = Vector2i(1200, 800)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-3d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	for mode in [["flat-2d", "fly_away_and_in"], ["", "fly_away_and_in"], ["flat-2d", "fly_away"], ["", "fly_away"]]:
		var path: String = mode[0]
		var effect: String = mode[1]
		check(host.switch_world(path), "Open " + path)
		await create_timer(.5).timeout
		var prefix := ("2d-" if path == "flat-2d" else "3d-") + effect + "-"
		host.set_session_transition_effect("none")
		await prepare(host, "beta", -2400)
		await snapshot(host, prefix + "destination")
		await prepare(host, "alpha", 2000)
		host.set_session_transition_effect(effect)
		await client.connection.request_action("session_switch", {"name":"beta"})
		var world: Node = host.world
		var ready := func():
			return world.tab_fx_t >= 0.0 and not world.tab_fx_preparing and (is_instance_valid(world._transition_in) if path == "flat-2d" else not world.tab_fx_in.is_empty())
		if not await until(ready):
			check(false, prefix + "Arrival prepared")
			quit(1)
			return
		world.set_process(false)
		while world.tab_fx_t < world.tab_fx_dur:
			world._process(minf(1.0 / 60, world.tab_fx_dur - world.tab_fx_t))
			await process_frame
		await snapshot(host, prefix + "landed")
		world._process(0.0)
		for index in 6:
			await snapshot(host, prefix + "live-%d" % index)
			await process_frame
		check(not is_instance_valid(world._transition_in) if path == "flat-2d" else world.tab_fx_in.is_empty(), prefix + "Handoff releases arriving layers")
		check(world._tab_fx_prepared_viewports.is_empty(), prefix + "Handoff releases capture holds")
		world.set_process(true)
	FileAccess.open(evidence.path_join("frames.json"), FileAccess.WRITE).store_string(JSON.stringify(traces, "\t"))
	client.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
