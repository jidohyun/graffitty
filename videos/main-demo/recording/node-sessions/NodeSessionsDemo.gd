extends "res://videos/main-demo/recording/protocol/ProtocolDemo.gd"
## Prepared Bistro sessions revealed through actual compact-sidebar clicks.
var chapter_frames := {}

func select_demo_session(name: String) -> bool:
	if not await demo_sessions.select(name): return false
	graph = host.agent_api.graph
	return true

func prepare_extra_sessions() -> void:
	pass

func present_extra_sessions() -> void:
	pass

func center_graph(nodes: Array, side := 0) -> void:
	# Prepare a saved floating layout in one real workspace transaction.
	#
	# Moving panes separately through Main View can dock them and change their
	# sizes. side -1 keeps the graph left of Main View and 1 keeps it right, at
	# eye level.
	var view: Control = host.workspace_view
	var layout = preload("res://scenes/WorkspaceLayout.gd")
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var bounds: Rect2 = view.pane_rects[nodes[0]]
	for key in nodes: bounds = bounds.merge(view.pane_rects[key])
	var center: Vector2 = view.size * .5
	center.x += side * ((bounds.size.x + view.content_rect().size.x) * .5 + 600.0)
	var shift: Vector2 = center - bounds.get_center()
	if side != 0:
		# A tall pane's close-up can show more empty horizontal space than the
		# complete graph. Reserve clearance for every subset the replay frames.
		for mask in range(1, 1 << nodes.size()):
			var subset := Rect2()
			var first := true
			for i in nodes.size():
				if mask & (1 << i):
					var rect: Rect2 = view.pane_rects[nodes[i]]
					subset = rect if first else subset.merge(rect)
					first = false
			var goal: Dictionary = view.fit_frame(subset.grow(45),view.viewport_content_rect(),view.size,.9)
			var half: float = view.size.x / goal.zoom * .5
			if side < 0:
				shift.x = minf(shift.x, view.content_rect().position.x - 200.0 - (goal.center.x + half))
			else:
				shift.x = maxf(shift.x, view.content_rect().end.x + 200.0 - (goal.center.x - half))
	var sizes := {}
	group.tree["tiling"] = false
	for key in nodes:
		var rect: Rect2 = view.pane_rects[key]
		sizes[key] = rect.size
		var item: Dictionary = layout.find(group.tree,key)
		item["rect"] = Rect2(rect.position + shift,rect.size)
		item["stashed"] = false
		item["graph_floating"] = true
	view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	await frame_nodes(nodes)
	if side != 0:
		var visible: Rect2 = Rect2(view.navigation_center - view.size / view.navigation_zoom * .5, view.size / view.navigation_zoom)
		check(not visible.intersects(view.content_rect()), "Graph overview excludes the Main View border")
	for key in nodes:
		check(view.pane_rects[key].size.is_equal_approx(sizes[key]), "Centering preserves pane size " + key)
	for i in nodes.size():
		for j in range(i + 1,nodes.size()):
			check(not view.pane_rects[nodes[i]].intersects(view.pane_rects[nodes[j]]), "Centered graph panes remain separate")

func play() -> void:
	check(host.switch_world("bistro"), "Bistro World loads for every node chapter")
	await hold(1)
	var effects_enabled: bool = host.world.fx_enabled
	# Setup is off camera. Avoid waiting for typing effects after every fixture
	# command; restore the actual effects before any recorded interaction.
	host.world.fx_enabled = false
	demo_sessions = preload("res://videos/shared/DemoSessions.gd").new(self)
	# Sessions are created in film order, so each sidebar click moves down.
	if not await demo_sessions.name_current("SystemOne"): return
	FileAccess.open(output.path_join("launch-chapter"),FileAccess.WRITE).store_string("systemone")
	var systemone := await prepare_systemone()
	if systemone.is_empty() or not failures.is_empty(): return
	await center_graph(systemone.nodes, -1)
	if not await demo_sessions.create("Parallel"): return
	FileAccess.open(output.path_join("launch-chapter"),FileAccess.WRITE).store_string("parallel")
	var parallel := await prepare_parallel()
	if parallel.is_empty() or not failures.is_empty(): return
	await center_graph([parallel.a,parallel.b,parallel.c,parallel.join,parallel.reviewer], -1)
	await snapshot("prepared-parallel-bistro")
	if not await demo_sessions.create("Custom nodes"): return
	FileAccess.open(output.path_join("launch-chapter"),FileAccess.WRITE).store_string("protocol")
	var protocol := await prepare_protocol()
	if protocol.is_empty() or not failures.is_empty(): return
	await center_graph([protocol.agent,protocol.manual,protocol.code,protocol.inspector], 1)
	await frame_nodes([protocol.agent,protocol.inspector])
	restore_full_view(protocol.intro_effects)
	await prepare_extra_sessions()
	if not failures.is_empty(): return
	if not await demo_sessions.show_compact(): return
	if not await select_demo_session("Parallel"): return
	await frame_nodes([parallel.a,parallel.b,parallel.c,parallel.join,parallel.reviewer])
	host.world.fx_enabled = effects_enabled
	await hold(.5)
	beats.clear()
	typing_events.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	# Start the Parallel workers before the edit begins, then freeze their
	# fixture clock while SystemOne is on camera. The film opens on SystemOne
	# and its sidebar click returns to the same workers still running.
	await start_parallel_work(parallel)
	if not failures.is_empty(): return
	freeze_parallel_clock()
	await say("SystemOne: session click")
	if not await select_demo_session("SystemOne"): return
	chapter_frames.systemone = movie_frame()
	await present_systemone(systemone)
	if not failures.is_empty(): return
	DirAccess.rename_absolute(output.path_join("graph-evidence.json"), output.path_join("systemone-evidence.json"))
	chapter_frames.parallel = movie_frame()
	await say("Parallel: session click")
	# Workers continue from the pointer approach, so they animate during arrival.
	resume_parallel_clock()
	if not await select_demo_session("Parallel"): return
	# The graph lists only the active session's nodes; check after arrival.
	var workers: Array = [parallel.a,parallel.b,parallel.c]
	check(graph.nodes.get(parallel.reviewer,{}).get("status")=="idle" and workers.all(func(key): return graph.nodes.get(key,{}).get("status")=="busy"),
		"All three Parallel workers are still running when their session returns")
	await say("Parallel: three workers running")
	await finish_parallel(parallel)
	if not failures.is_empty(): return
	chapter_frames.protocol = movie_frame()
	await say("Protocol: session click")
	if not await select_demo_session("Custom nodes"): return
	protocol.intro_effects = hold_full_view()
	await present_protocol(protocol)
	chapter_frames.end = movie_frame()
	FileAccess.open(output.path_join("chapter-frames.json"),FileAccess.WRITE).store_string(JSON.stringify(chapter_frames,"\t"))
	await present_extra_sessions()
