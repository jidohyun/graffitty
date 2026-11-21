extends "res://videos/main-demo/recording/systemone/SystemoneDemo.gd"
## Uses shared camera/input helpers and real Python/CLI nodes, never painted UIs.

func wire(source: String, target: String) -> void:
	await camera_at_rest()
	await super.wire(source,target)

func quick_wire(source: String, target: String) -> void:
	var links: Control = host.workspace_view.agent_links
	var transform := links.get_global_transform_with_canvas()
	await point_at(transform * links.port_center(source, true), .08)
	await press()
	check(links.dragging == source, "Grabbed narration-timed output: " + source)
	await point_at(links.get_global_transform_with_canvas() * links.port_center(target, false), .3)
	# The first edge's workspace acknowledgement can update projection while
	# the next drag is in flight. Follow the live socket before releasing.
	for i in 3:
		await point_at(links.get_global_transform_with_canvas() * links.port_center(target, false), .02)
	await release(MOUSE_BUTTON_LEFT, .03)
	if not await until(func(): return graph.edges.has(source + ">" + target), "Narration-timed connection: " + source + " → " + target): return
	check(links.wire_layer.transform == Transform2D.IDENTITY, "Graph wire canvas has no inherited screen-space offset")

func prepare_protocol() -> Dictionary:
	var view: Control = host.workspace_view
	graph = host.agent_api.graph
	if not view.physics_enabled(): view.toggle_physics()
	var agent: String = host.pane_focus
	await hold(1)
	await pinch_overview()
	await move_to(agent,Vector2(1850,1500))
	await resize_pane(agent,Vector2(1000,650),30)
	await enter(agent,"claude")
	var manual := await create_beside(agent,true)
	if manual.is_empty(): return {}
	await move_to(manual,Vector2(0,2600))
	await resize_pane(manual,Vector2(1000,650),28)
	var code := await create_beside(manual)
	if code.is_empty(): return {}
	await move_to(code,Vector2(1350,2600))
	await resize_pane(code,Vector2(1500,850),30)
	var inspector := await create_beside(code)
	if inspector.is_empty(): return {}
	await move_to(inspector,Vector2(3200,1000))
	await resize_pane(inspector,Vector2(1700,1700),26)
	await enter(manual,"gft node manual-prompt")
	await enter(code,"bat node.py")
	await enter(inspector,"gft node payload-inspector")
	await frame_nodes([agent,inspector])
	await wire(agent+"/turn_completed",inspector+"/payload")
	if not failures.is_empty(): return {}
	await camera_at_rest()
	# Keep the connected source and inspector in view throughout the real turn.
	# A completion connection emits after the response, never on each keystroke.
	var intro_effects := hold_full_view()
	await frame_nodes([agent,inspector])
	check("waiting for events" in shell_text(inspector) and not "turn.completed" in shell_text(inspector),
		"The opening inspector is waiting on its connected Claude source")
	return {"agent":agent,"manual":manual,"code":code,"inspector":inspector,"intro_effects":intro_effects}

func play() -> void:
	var prepared := await prepare_protocol()
	if prepared.is_empty(): return
	beats.clear()
	typing_events.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await present_protocol(prepared)

func present_protocol(prepared: Dictionary) -> void:
	# Keep the connected panes and word-timed callouts stable throughout this
	# explanation; only our deliberate graph framing moves the camera.
	var release_camera: Callable = host.disable_effects(["camera.zoom", "camera.tilt", "camera.drift", "camera.shake"])
	var view: Control = host.workspace_view
	var agent: String = prepared.agent
	var manual: String = prepared.manual
	var code: String = prepared.code
	var inspector: String = prepared.inspector
	var intro_effects: Dictionary = prepared.intro_effects
	await say("Protocol: inspector")
	var beat := movie_frame()
	var intro := {"source":agent,"target":inspector,"provider":"claude",
		"source_port":"turn_completed","connected_frame":movie_frame()}
	await snapshot("00-connected-agent")
	await hold(.5)
	await click(on(view.panes[agent].handle))
	host.focus_pane(agent)
	check(host.pane_focus==agent and host.sessions[int(agent.substr(1))].term.has_focus(),
		"Claude is focused while the inspector stays visible")
	intro.prompt_start_frame = movie_frame()
	await human_text("What is HTTP?")
	check(not "turn.completed" in shell_text(inspector),"Typing does not fabricate an inspector event")
	await snapshot("00a-typing-to-claude")
	await hold(.12)
	intro.submitted_frame = movie_frame()
	_send_key(KEY_ENTER,0,{})
	if not await until(func(): return graph.nodes.get(agent,{}).get("status")=="busy", "Claude starts its recorded response"): return
	if not await until(func(): return "HTTP" in live_responses(agent) if "--live-agents" in OS.get_cmdline_user_args() else "HTTP is" in shell_text(agent), "Claude streams its response beside the inspector", 180): return
	intro.response_started_frame = movie_frame()
	var inspector_bounds := Rect2(view.view_point(view.pane_rects[inspector].position),
		view.view_point(view.pane_rects[inspector].end) - view.view_point(view.pane_rects[inspector].position))
	check(view.viewport_content_rect().grow(1).encloses(inspector_bounds),
		"The Payload Inspector remains fully visible while Claude responds")
	await snapshot("00b-agent-responding")
	if not await until(func(): return "session" in shell_text(inspector) and "HTTP" in shell_text(inspector), "Inspector received an actual agent completion on camera",20.0): return
	intro.received_frame = movie_frame()
	var original := shell_text(inspector)
	check("checkpoint" in original and "path" in original,"Inspector shows the session path and checkpoint")
	check(graph.nodes.get(agent,{}).get("status")=="idle","The inspector event follows Claude's completed turn")
	await snapshot("00c-connected-payload")
	await finish_narration("protocol-inspector",beat)
	await say("Protocol: payload")
	beat = movie_frame()
	await frame_nodes([inspector])
	await finish_narration("protocol-payload",beat)
	restore_full_view(intro_effects)
	await snapshot("01-payload-inspector")
	await say("Protocol: code")
	beat = movie_frame()
	await frame_nodes([code])
	# Leave the pointer in empty workspace throughout the code explanation.
	await point_at(view.global_position + Vector2(view.size.x - 100, 100), .15)
	check("@node.on" in shell_text(code) and "message.text.upper()" in shell_text(code),"The real source file is visible")
	await finish_narration("protocol-code",beat)
	await say("Protocol: ports")
	beat = movie_frame()
	await finish_narration("protocol-ports",beat)
	await snapshot("02-minimal-python")
	await say("Protocol: run")
	beat = movie_frame()
	var run_effects := hold_full_view()
	host.focus_pane(code)
	await human_text("uv run node.py", 1)
	_send_key(KEY_ENTER,0,{})
	if not await until(func(): return graph.nodes.get(code,{}).get("manifest",{}).get("name")=="Uppercase", "uv launches the Python SDK node",20.0): return
	await frame_nodes([manual,code,inspector], .25)
	while movie_frame() < beat + int(ceil(float(voice_durations["protocol-run"]) * 60)): await process_frame
	await snapshot("03-uv-running")
	await say("Protocol: connect")
	beat = movie_frame()
	await quick_wire(manual+"/out",code+"/in")
	await quick_wire(code+"/out",inspector+"/payload")
	check(movie_frame() <= beat + int(ceil(float(voice_durations["protocol-connect"]) * 60)) + 6,
		"Both nodes connect during the connect narration")
	while movie_frame() < beat + int(ceil(float(voice_durations["protocol-connect"]) * 60)): await process_frame
	await say("Protocol: connections complete")
	await snapshot("04-connected")
	# Reframe during the intentional pause, then type on the spoken send cue.
	var pause_start := movie_frame()
	await frame_nodes([manual])
	await camera_at_rest()
	host.focus_pane(manual)
	while movie_frame() < pause_start + 90: await process_frame
	await say("Protocol: send")
	beat = movie_frame()
	await human_text("hello graph", 3)
	await say("Protocol: message written")
	await hold(2.0)
	# Reveal the entire route before Enter so both real transfer pulses stay visible.
	await frame_nodes([manual,code,inspector], .25)
	_send_key(KEY_ENTER,0,{})
	await say("Protocol: message submitted")
	# Enter emits typing activity on the next frame. Keep the final manual
	# pinch active through that submission, then let the graph hold still.
	await process_frame
	view.pinch_workspace(view.size * .5, view.size * .5, 1.0)
	var route_lens: Vector4 = host.world.proj_rect
	var route_eye: Vector3 = host.world.proj_eye
	var route_forward: Vector3 = host.world.proj_forward
	if not await until(func(): return "HELLO GRAPH" in shell_text(inspector),"Uppercase result reaches the real inspector",20.0): return
	while movie_frame() < beat + int(ceil(float(voice_durations["protocol-send"]) * 60)): await process_frame
	await hold(1.8)
	check(route_lens.distance_to(host.world.proj_rect) / maxf(route_lens.z, .00001) < .001
		and route_eye.distance_to(host.world.proj_eye) < .0001
		and route_forward.distance_to(host.world.proj_forward) < .0001,
		"The submitted GGP prompt does not restart adaptive zoom after manual navigation")
	await snapshot("04b-message-route")
	await say("Protocol: follow message to inspector")
	# One deliberate move; keep typing-camera follow disabled until the result is read.
	await frame_nodes([inspector], .65)
	await camera_at_rest()
	await say("Protocol: result")
	beat = movie_frame()
	await finish_narration("protocol-result",beat)
	await snapshot("05-result")
	await hold(1.5)
	var delivered := false
	for receipt in graph.receipts:
		if receipt.get("source")==code and receipt.get("target")==inspector and receipt.get("status")=="delivered": delivered=true
	check(delivered,"The inspector acknowledged the Python output")
	var empty_sessions := RegEx.create_from_string('"sessions"\\s*:\\s*\\[\\s*\\]').search(shell_text(inspector)) != null
	check(empty_sessions,"Manual Prompt has no synthetic conversation session")
	for key in [manual,code,inspector]:
		check(not graph.nodes.get(key,{}).has("provider"),"Generic node has no synthetic provider: "+key)
	var evidence := FileAccess.open(output.path_join("graph-evidence.json"),FileAccess.WRITE)
	evidence.store_string(JSON.stringify({"nodes":graph.nodes,"edges":graph.edges.values(),"receipts":graph.receipts,
		"live_agent_intro":intro,
		"command":"uv run node.py","result":"HELLO GRAPH","delivered":delivered,
		"original_session_reference":"checkpoint" in original and "path" in original,
		"empty_manual_sessions":empty_sessions,
		"inspector":shell_text(inspector),"source":shell_text(code)},"\t"))
	evidence.close()
	restore_full_view(run_effects)
	release_camera.call()
