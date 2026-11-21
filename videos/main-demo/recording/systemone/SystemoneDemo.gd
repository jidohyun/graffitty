extends "res://videos/main-demo/recording/parallel/ParallelDemo.gd"
## The shared replay drives actual terminal input, navigation, and graph ports.
const AGENT_COLUMN_X := 3600.0

func resize_pane(key: String, size: Vector2, font := 24) -> void:
	var view: Control = host.workspace_view
	var rect: Rect2 = view.pane_rects[key]
	await frame_rect(rect.merge(Rect2(rect.position, size)))
	await drag(view.window_point(rect.end-Vector2(10,10)), view.window_point(rect.position+size-Vector2(10,10)), .4)
	await owner_at_rest()
	host.focus_pane(key)
	var term = host.sessions[int(key.substr(1))].term
	for step in range(20):
		if term.get_live_font_size() >= font: break
		host.change_text_size(1)
		await hold(.08)

func wire(source: String, target: String) -> void:
	var links: Control = host.workspace_view.agent_links
	if not await until(func(): return links.has_socket(source,true) and links.has_socket(target,false), "Named ports visible"): return
	var count: int = graph.edges.size()
	var transform: Transform2D = links.get_global_transform_with_canvas()
	await point_at(transform*links.port_center(source,true), .35)
	await press()
	if not check(links.dragging==source, "Grabbed " + source): return
	await hold(.1)
	await point_at(transform*links.port_center(target,false), 1.625)
	await release()
	await until(func(): return graph.edges.size()==count+1, "Connected " + source + " → " + target)
	await hold(.3)

## Seconds into a narration clip where the given word starts.
func word_start(id: String, word: String) -> float:
	var audio: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("demo-audio.json")))
	for voice in audio.get("voices", []):
		if voice.id != id: continue
		for entry in voice.get("words", []):
			if str(entry.text).strip_edges() == word: return float(entry.start)
	check(false, "Narration %s times the word %s" % [id, word])
	return 0.0

func prepare_systemone() -> Dictionary:
	var view: Control = host.workspace_view
	graph = host.agent_api.graph
	var routing: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("routing.json")))
	if not view.physics_enabled(): view.toggle_physics()
	var claude: String = host.pane_focus
	await hold(1)
	host.sessions[int(claude.substr(1))].term.send_text("clear\r")
	await hold(.3)
	await pinch_overview()
	# Build and wire the pipeline off camera; the chapter opens on the finished graph.
	await move_to(claude,Vector2(AGENT_COLUMN_X,2400))
	await resize_pane(claude,Vector2(820,500),24)
	await enter(claude,"claude")
	var codex := await create_beside(claude,true)
	if codex.is_empty(): return {}
	await enter(codex,"codex")
	await move_to(codex,Vector2(AGENT_COLUMN_X,3070))
	var manual := await create_beside(codex)
	if manual.is_empty(): return {}
	await move_to(manual,Vector2(0,2750))
	await resize_pane(manual,Vector2(850,650),24)
	var router := await create_beside(manual)
	if router.is_empty(): return {}
	await move_to(router,Vector2(1100,2500))
	await resize_pane(router,Vector2(1900,1050),24)
	await enter(manual,"gft node manual-prompt")
	await enter(router,"gft node systemone")
	if not await until(func(): return graph.nodes.get(manual,{}).get("manifest",{}).get("name")=="Manual Prompt", "Manual Prompt running"): return {}
	if not await until(func(): return (graph.nodes.get(router,{}).get("manifest",{}).get("name")=="SystemOne JEV"
		and graph.nodes.get(router,{}).get("manifest",{}).get("outputs",[]).size()==routing.outputs.size()), "SystemOne JEV starts from its saved settings with Claude and Codex outputs"): return {}
	if not await until(func(): return graph.nodes.get(codex,{}).get("provider")=="codex", "Claude and Codex ready off camera"): return {}
	# Title the node panes as a user would, so the middle node reads as JEV.
	for pair in [[manual,"Manual Prompt"],[router,"SystemOne JEV"]]:
		if not check(await host.set_pane_title(pair[0],pair[1]), "Pane titled " + pair[1]): return {}
	# Every port must be on screen for the real pointer drags.
	var nodes := [manual,router,claude,codex]
	await camera_at_rest()
	await frame_nodes(nodes)
	await hold(.8)
	await wire(manual+"/out",router+"/evaluate")
	if not failures.is_empty(): return {}
	var manual_edge: Dictionary = graph.edges[manual+"/out>"+router+"/evaluate"]
	if not check(view.agent_links.wire_pattern(manual_edge) == "solid", "Manual Prompt directly emits over a solid wire"): return {}
	var agents := {"claude":claude,"codex":codex}
	for id in agents:
		await wire(router+"/"+id,agents[id]+"/in")
		if not failures.is_empty(): return {}
		var route_edge: Dictionary = graph.edges[router+"/"+id+">"+agents[id]+"/in"]
		if not check(view.agent_links.wire_pattern(route_edge) == "solid", "SystemOne automatically sends over a solid " + id + " wire"): return {}
	if not check(graph.edges.values().filter(func(edge): return edge["from"] in nodes).size()==3,"Three routing connections"): return {}
	await camera_at_rest()
	await frame_nodes(nodes)
	return {"claude":claude,"codex":codex,"manual":manual,"router":router,"nodes":nodes,"agents":agents,"routing":routing}

func play() -> void:
	var prepared := await prepare_systemone()
	if prepared.is_empty(): return
	beats.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await present_systemone(prepared)

func present_systemone(prepared: Dictionary) -> void:
	var view: Control = host.workspace_view
	var manual: String = prepared.manual
	var router: String = prepared.router
	var nodes: Array = prepared.nodes
	var agents: Dictionary = prepared.agents
	var routing: Dictionary = prepared.routing
	await say("SystemOne: intro")
	var beat := movie_frame()
	await snapshot("01-routing-graph")
	# Move in on JEV as the narration introduces the middle node.
	var jev_frame := beat + int(round(word_start("systemone-intro","This") * 60))
	while movie_frame() < jev_frame: await process_frame
	await frame_nodes([router],.8)
	check(view.panes[router].handle.text=="SystemOne JEV","The middle node is titled SystemOne JEV")
	await snapshot("02-jev-node")
	await finish_narration("systemone-intro",beat)
	await say("SystemOne: prompt")
	var target: String = agents[routing.route]
	await enter(manual,str(routing.prompt))
	await say("SystemOne: route")
	await frame_nodes(nodes,.6)
	if not await until(func(): return graph.nodes.get(target,{}).get("status")=="busy", "JEV routes the prompt to " + str(routing.route)): return
	for id in agents:
		if agents[id]!=target: check(graph.nodes.get(agents[id],{}).get("status")!="busy", "The other agent stays idle: "+id)
	await hold(.9)
	await frame_nodes([target])
	if not await until(func(): return graph.nodes.get(target,{}).get("status")=="idle", str(routing.route)+" finished responding", 180): return
	if "--live-agents" in OS.get_cmdline_user_args():
		check("429" in live_responses(target), "The routed agent answers the HTTP 429 question")
	await hold(1.7)
	await snapshot("03-response")
	var evidence := FileAccess.open(output.path_join("graph-evidence.json"),FileAccess.WRITE)
	evidence.store_string(JSON.stringify({"nodes":graph.nodes,"edges":graph.edges.values().filter(func(edge): return edge["from"] in nodes),
		"route":{"output":routing.route,"node":target,"prompt":routing.prompt,"text":shell_text(target)},
		"jev_title":view.panes[router].handle.text},"\t"))
	evidence.close()
