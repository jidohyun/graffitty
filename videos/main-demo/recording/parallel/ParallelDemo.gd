extends "res://videos/main-demo/recording/tiling/RecordTilingDemo.gd"
var graph: Node
## The Parallel fixtures follow their own capture clock. It freezes while
## another prepared session is on camera, so the off-screen workers resume
## exactly where they were when their session returns.
var parallel_clock_frozen_at := -1
var parallel_clock_paused := 0

func publish_animation_clock() -> void:
	super.publish_animation_clock()
	var frame := movie_frame() if parallel_clock_frozen_at < 0 else parallel_clock_frozen_at
	var path := output.path_join("parallel-clock")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(str((frame - parallel_clock_paused) * 1000 / 60))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)

func freeze_parallel_clock() -> void:
	if parallel_clock_frozen_at < 0: parallel_clock_frozen_at = movie_frame()

func resume_parallel_clock() -> void:
	if parallel_clock_frozen_at < 0: return
	parallel_clock_paused += movie_frame() - parallel_clock_frozen_at
	parallel_clock_frozen_at = -1

func hold_full_view() -> Dictionary:
	var saved := super.hold_full_view()
	# Fixed zoom=1 does not disable the content-based adaptive camera. These
	# explanations need the whole connected group visible while text is typed.
	saved.release_camera = host.disable_effects(["camera.zoom", "camera.tilt", "camera.drift", "camera.shake"])
	return saved

func restore_full_view(saved: Dictionary) -> void:
	saved.release_camera.call()
	super.restore_full_view(saved)

func check(ok: bool, message: String) -> bool:
	# Verification is recorded as metadata, not intrusive viewer-facing toasts.
	print("[parallel] ","PASS " if ok else "FAIL ",message)
	if not ok: failures.append(message)
	return ok

func frame_rect(bounds: Rect2, seconds := .45) -> void:
	var view: Control = host.workspace_view
	# Use the actual gesture path: direct navigation assignments leave the
	# typing projection running and it zooms back in after the authored move.
	# Fit the displayed bounds, including the frozen adaptive correction.
	view._cancel_main_magnet()
	var padded := bounds.grow(45)
	var shown := Rect2(view.view_point(padded.position), Vector2.ZERO)
	for corner in [Vector2(padded.end.x, padded.position.y), padded.end, Vector2(padded.position.x, padded.end.y)]:
		shown = shown.expand(view.view_point(corner))
	var visible: Rect2 = view.viewport_content_rect()
	var factor := minf(visible.size.x * .9 / shown.size.x, visible.size.y * .9 / shown.size.y)
	var origin := shown.get_center()
	var previous := origin
	var previous_scale := 1.0
	var start: float=overlay.clock
	while true:
		var elapsed := clampf((overlay.clock-start)/seconds, 0.0, 1.0)
		var t := smoothstep(0,1,elapsed)
		var center := origin.lerp(visible.get_center(),t)
		var scale := lerpf(1.0,factor,t)
		view.pinch_workspace(previous,center,scale/previous_scale)
		previous=center
		previous_scale=scale
		if elapsed >= 1.0: break
		await process_frame
	# Sheet curvature can still animate after typing. Inspect the camera itself,
	# rather than mistaking that surface movement for an adaptive zoom rebound.
	var before: Vector4 = host.world.proj_rect
	var before_eye: Vector3 = host.world.proj_eye
	var before_forward: Vector3 = host.world.proj_forward
	await hold(.1)
	if capture_active:
		var change: float = before.distance_to(host.world.proj_rect) / maxf(before.z, .00001)
		check(change < .001 and before_eye.distance_to(host.world.proj_eye) < .0001 and before_forward.distance_to(host.world.proj_forward) < .0001,
			"Manual graph framing stays fixed after navigation without new typing")
		print("GRAPH_CAMERA_HOLD ", JSON.stringify({"frame": movie_frame(), "lens_change": change,
			"eye_change": before_eye.distance_to(host.world.proj_eye), "direction_change": before_forward.distance_to(host.world.proj_forward)}))

func frame_nodes(nodes: Array, seconds := .45) -> void:
	var bounds: Rect2=host.workspace_view.pane_rects[nodes[0]]
	for key in nodes: bounds=bounds.merge(host.workspace_view.pane_rects[key])
	await frame_rect(bounds,seconds)
	if capture_active and "--node-sessions" in OS.get_cmdline_user_args():
		var view: Control = host.workspace_view
		var visible := Rect2(view.navigation_center - view.size / view.navigation_zoom * .5,view.size / view.navigation_zoom)
		check(not visible.intersects(view.content_rect()), "Recorded graph framing excludes Main View")

func enter(key: String,text: String) -> void:
	await frame_nodes([key])
	await click(on(host.workspace_view.panes[key].handle))
	host.focus_pane(key)
	await hold(.1)
	check(host.pane_focus==key and host.sessions[int(key.substr(1))].term.has_focus(),"Focus before typing into "+key)
	await human_text(text)
	await hold(.12)
	_send_key(KEY_ENTER,0,{})
	await hold(.2)

func create_beside(key: String, down := false) -> String:
	await camera_at_rest()
	await frame_nodes([key])
	var before: Array=host.sessions.keys()
	await click(await on_header(key,"split_down" if down else "split_right"))
	if not await until(func(): return host.sessions.size()==before.size()+1,"Create one new pane"): return ""
	for id in host.sessions:
		if id not in before: return "%%%d" % id
	return ""

func move_to(key: String, dest: Vector2) -> void:
	var view: Control=host.workspace_view
	var rect: Rect2=view.pane_rects[key]
	await frame_rect(rect.merge(Rect2(dest,rect.size)))
	var handle: Control=view.panes[key].handle
	var offset: Vector2=handle.get_global_transform()*(handle.size*.5)-rect.position
	await drag(on(handle),view.window_point(dest+offset),.38)
	await hold(.15)

func wire(source: String,target: String) -> void:
	var links: Control=host.workspace_view.agent_links
	if not await until(func(): return links.has_socket(source,true) and links.has_socket(target,false),"Named ports visible"): return
	var n: int=graph.edges.size()
	var transform: Transform2D=links.get_global_transform_with_canvas()
	# RecordTilingDemo scales pointer durations by 0.4: approach in .10s,
	# connect in .20s, then give viewers one hold on the completed graph.
	await point_at(transform*links.port_center(source,true),.25)
	await press()
	if not check(links.dragging==source,"Pointer grabbed the named output"): return
	await hold(.04)
	await point_at(transform*links.port_center(target,false),.5)
	await hold(.05)
	await release()
	await until(func(): return graph.edges.size()==n+1,"Wire connected "+source+" → "+target)
	await hold(.05)

func enlarge(key: String, size: Vector2, label: String) -> bool:
	# Resize by the real grip, then raise this pane's text size to 24.
	var view: Control=host.workspace_view
	var rect: Rect2=view.pane_rects[key]
	await frame_rect(rect.merge(Rect2(rect.position,size)))
	await drag(view.window_point(rect.end-Vector2(10,10)),view.window_point(rect.position+size-Vector2(10,10)),.4)
	await owner_at_rest()
	host.focus_pane(key)
	var term = host.sessions[int(key.substr(1))].term
	for step in range(12):
		if term.get_live_font_size()>=24: break
		host.change_text_size(1)
		await hold(.1)
	return check(view.pane_rects[key].size.x>size.x-100 and view.pane_rects[key].size.y>size.y-150 and term.get_live_font_size()>=24,
		label+" enlarged with readable font: "+str(view.pane_rects[key].size)+", font "+str(term.get_live_font_size()))

func prepare_parallel() -> Dictionary:
	var view: Control=host.workspace_view
	graph=host.agent_api.graph
	# Keep the bundled effects while framing the graph through navigation.
	if not view.physics_enabled(): view.toggle_physics()
	var a: String=host.pane_focus
	await hold(1)
	host.sessions[int(a.substr(1))].term.send_text("clear\r")
	await hold(.3)
	# Arrange outside Main View through real input gestures before capture.
	await pinch_overview()
	await move_to(a,Vector2(0,2200))
	var rect: Rect2=view.pane_rects[a]
	# A compact worker size established by its real resize grip.
	await frame_rect(rect)
	await drag(view.window_point(rect.end-Vector2(10,10)),view.window_point(rect.position+Vector2(760,480)-Vector2(10,10)),.4)
	await owner_at_rest()
	if not check(view.pane_rects[a].size.x<950 and view.pane_rects[a].size.y<600,"Worker resized to compact dimensions: "+str(view.pane_rects[a])): return {}
	await frame_nodes([a])
	overlay.pointer=Vector2(2100,1250)
	await say("Parallel: launch three workers")
	await enter(a,"claude")
	var b := await create_beside(a,true)
	if b.is_empty(): return {}
	await enter(b,"claude")
	var c := await create_beside(b,true)
	if c.is_empty(): return {}
	await enter(c,"codex")
	var origin: Vector2=view.pane_rects[a].position
	await move_to(b,origin+Vector2(0,620))
	await move_to(c,origin+Vector2(0,1240))
	await say("Parallel: create the join")
	var join := await create_beside(b)
	if join.is_empty(): return {}
	await move_to(join,origin+Vector2(1100,620))
	await enter(join,"gft node parallel")
	var reviewer := await create_beside(join)
	if reviewer.is_empty(): return {}
	await move_to(reviewer,origin+Vector2(2600,300))
	await enter(reviewer,"claude")
	# Give the join and reviewer tall, readable panels without changing worker sizes.
	await camera_at_rest()
	await move_to(join,origin+Vector2(1100,300))
	if not await enlarge(join,Vector2(1100,1150),"Parallel panel"): return {}
	# The reviewer's text reads beside the join without a close-up.
	if not await enlarge(reviewer,Vector2(1200,1150),"Reviewer panel"): return {}
	if not await until(func(): return graph.nodes.get(reviewer,{}).get("provider")=="claude" and graph.nodes.get(join,{}).has("manifest"),"All five nodes registered"): return {}
	await hold(.5)
	check(view.physics_enabled(),"Floating pane physics remains enabled")
	var nodes := [a,b,c,join,reviewer]
	for i in nodes.size():
		for j in range(i+1,nodes.size()):
			check(not view.pane_rects[nodes[i]].intersects(view.pane_rects[nodes[j]]),"Physics leaves panes separated: "+nodes[i]+" / "+nodes[j])
	await camera_at_rest()
	await frame_nodes(nodes)
	await say("Parallel: arranged 3–1–1 graph")
	await hold(.65)
	await say("Parallel: connect three completions to one join")
	for key in [a,b,c]: await wire(key+"/turn_completed",join+"/join")
	await wire(join+"/combined",reviewer+"/in")
	if not check(graph.edges.size()==4,"Three workers and one downstream reviewer wired"): return {}
	for edge in graph.edges.values():
		if not check(view.agent_links.wire_pattern(edge) == "solid", "Automatic Parallel pipeline wires are solid"): return {}
	FileAccess.open(output.path_join("wire-styles.json"), FileAccess.WRITE).store_string(JSON.stringify({"combined":"solid", "manifest":graph.nodes[join].manifest, "edges":graph.edges}))
	await snapshot("01-connected")
	await hold(2)
	return {"a":a,"b":b,"c":c,"join":join,"reviewer":reviewer}

func play() -> void:
	if "--through-wiring" in OS.get_cmdline_user_args():
		capture_active = true
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	var prepared := await prepare_parallel()
	if prepared.is_empty(): return
	beats.clear()
	capture_active = true
	Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await present_parallel(prepared)

func present_parallel(prepared: Dictionary) -> void:
	if "--through-wiring" in OS.get_cmdline_user_args(): return
	if "--live-agents" in OS.get_cmdline_user_args():
		await live_turns(prepared.a,prepared.b,prepared.c,prepared.join,prepared.reviewer)
		return
	await start_parallel_work(prepared)
	if not failures.is_empty(): return
	await say("Parallel: three workers running")
	await finish_parallel(prepared)

## Prepare the reviewer and start all three workers; ends on their overview.
func start_parallel_work(prepared: Dictionary) -> void:
	var a: String = prepared.a
	var b: String = prepared.b
	var c: String = prepared.c
	var join: String = prepared.join
	var reviewer: String = prepared.reviewer
	await say("Parallel: prepare reviewer")
	await enter(reviewer,"Graffitty will send you combined implementation of three different specs. Once you receive, review which is the best")
	check(host.world.fx_enabled and peak_typing>0.5,"Real keyboard input activates default typing effects")
	if not await until(func(): return "Ready." in shell_text(reviewer) and graph.nodes.get(reviewer,{}).get("status")=="idle","Reviewer ready before work starts"): return
	await hold(1.2)
	await say("Parallel: implement specs A, B, and C")
	# Keep the typing camera active across the short prompts and transitions,
	# with time to read each close-up before moving to the next worker.
	var idle_after: float = host.world.fx_cfg.behavior.idle_after
	host.world.fx_cfg.set_option("behavior", "idle_after", 4.0)
	await enter(a,"Implement with spec A")
	await hold(1.5)
	await enter(b,"Implement with spec B")
	await hold(1.5)
	await enter(c,"Implement with spec C")
	await hold(1.5)
	if not await until(func(): return [a,b,c].all(func(key): return graph.nodes.get(key,{}).get("status")=="busy"),"All three workers run concurrently"): return
	# The overview must not shift as the last prompt's typing effects settle.
	# Leave adaptive mode enabled so manual navigation freezes the displayed
	# correction. Disabling it here starts a separate return-to-rest animation.
	await frame_nodes([a,b,c,join])
	host.world.fx_cfg.set_option("behavior", "idle_after", idle_after)

## Follow the running workers through the single combined handoff.
func finish_parallel(prepared: Dictionary) -> void:
	var a: String = prepared.a
	var b: String = prepared.b
	var c: String = prepared.c
	var join: String = prepared.join
	var reviewer: String = prepared.reviewer
	await snapshot("02-three-busy")
	if not await until(func(): return graph.nodes.get(a,{}).get("status")=="idle","Spec A completed",90): return
	await say("Parallel: one completed; reviewer still waiting")
	check(graph.nodes.get(reviewer,{}).get("status")=="idle","No delivery after first completion")
	await snapshot("03-one-complete")
	if not await until(func(): return graph.nodes.get(b,{}).get("status")=="idle","Spec B completed",90): return
	await say("Parallel: two completed; reviewer still waiting")
	check(graph.nodes.get(reviewer,{}).get("status")=="idle","No delivery after second completion")
	await snapshot("04-two-complete")
	if not await until(func(): return "ImplementedspecC:" in shell_text(c).replace(" ", "").replace("\n", ""),"Last worker begins its final response",90): return
	await say("Parallel: final worker finishing; follow combined handoff")
	await frame_nodes([join,reviewer])
	await snapshot("04b-combined-handoff")
	if not await until(func(): return graph.nodes.get(reviewer,{}).get("status")=="busy","All three trigger combined delivery",90): return
	check(graph.nodes.get(c,{}).get("status")=="idle","Third worker finished before reviewer starts")
	await say("Parallel: all three completed; compare combined implementation")
	if "--node-sessions" in OS.get_cmdline_user_args():
		await hold(float(voice_durations["parallel-combined"]) - .25)
		await frame_nodes([a,b,c,join,reviewer], .65)
		return
	await hold(1.2)
	await frame_nodes([reviewer])
	if not await until(func(): return "Recommendation:useBasthefoundation." in shell_text(reviewer).replace(" ", "").replace("\n", ""),"Reviewer compares all three implementations",90): return
	await hold(4)
	await snapshot("05-review")
	check(FileAccess.file_exists(output.path_join("received-combined.json")),"Reviewer read all three real session references")
	await frame_nodes([a,b,c,join,reviewer])
	await hold(2)
	await say("Parallel: complete")


func live_records(key: String) -> Array:
	var node: Dictionary = graph.nodes.get(key, {})
	var provider := str(node.get("provider", ""))
	var session := str(node.get("session_id", ""))
	if session.is_empty() or provider not in ["claude", "codex"]: return []
	var folder := OS.get_environment("GRAFFITTY_DEMO_AGENT_HOME").path_join(provider)
	var path := transcript_path(folder.path_join("projects" if provider == "claude" else "sessions"), session)
	if path.is_empty(): return []
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 4 * 1024 * 1024: return []
	var records: Array = []
	while not file.eof_reached():
		var parser := JSON.new()
		if parser.parse(file.get_line()) == OK and parser.data is Dictionary:
			records.append(parser.data)
	return records


func transcript_path(folder: String, session: String) -> String:
	if not DirAccess.dir_exists_absolute(folder): return ""
	for name in DirAccess.get_files_at(folder):
		if name.ends_with(".jsonl") and session in name: return folder.path_join(name)
	for name in DirAccess.get_directories_at(folder):
		if name.begins_with("."): continue
		var found := transcript_path(folder.path_join(name), session)
		if not found.is_empty(): return found
	return ""


func live_responses(key: String) -> String:
	var text := ""
	for record in live_records(key):
		var message: Dictionary = record.get("payload", {}) if record.get("type") == "response_item" else record.get("message", {})
		if message.get("role") != "assistant": continue
		for part in message.get("content", []):
			if part is Dictionary and part.get("type") in ["text", "output_text"]:
				text += str(part.get("text", "")) + "\n"
	return text


func live_turns(a: String, b: String, c: String, join: String, reviewer: String) -> void:
	await say("Parallel: prepare real reviewer")
	await enter(reviewer, "Graffitty will send you combined implementation of three different specs. Once you receive, review which is the best")
	if not await until(func(): return not live_responses(reviewer).is_empty() and graph.nodes.get(reviewer, {}).get("status") == "idle", "Real reviewer ready", 180): return
	var before := live_responses(reviewer)
	await say("Parallel: implement specs A, B, and C")
	await enter(a, "Implement with spec A")
	await enter(b, "Implement with spec B")
	await enter(c, "Implement with spec C")
	await frame_nodes([a, b, c, join])
	await snapshot("02-live-workers")
	var workers := [a, b, c]
	if not await until(func(): return workers.all(func(key): return not live_responses(key).is_empty() and graph.nodes.get(key, {}).get("status") == "idle"), "Three real workers finish their implementations", 240): return
	for spec in ["A", "B", "C"]:
		check(FileAccess.file_exists(OS.get_environment("GRAFFITTY_DEMO_AGENT_HOME").path_join("work/spec-" + spec + ".html")), "Real worker wrote spec " + spec)
	await frame_nodes([join, reviewer])
	if not await until(func(): return live_responses(reviewer).length() > before.length() and graph.nodes.get(reviewer, {}).get("status") == "idle", "Combined delivery produces a real review", 240): return
	var records := live_records(reviewer)
	var delivered := JSON.stringify(records)
	check("parallel.completed" in delivered, "The real reviewer received the Parallel completion payload")
	var review := live_responses(reviewer).trim_prefix(before)
	check("A" in review and "B" in review and "C" in review, "Real review compares all three specs")
	var evidence := {"workers": {}, "reviewer": graph.nodes.get(reviewer, {}), "review": review,
		"parallel_delivery": "parallel.completed" in delivered, "edges": graph.edges}
	for key in workers:
		evidence.workers[key] = {"node": graph.nodes.get(key, {}), "response": live_responses(key)}
	FileAccess.open(output.path_join("live-agents.json"), FileAccess.WRITE).store_string(JSON.stringify(evidence, "\t"))
	await frame_nodes([reviewer])
	await snapshot("05-live-review")
	await hold(4)
	await frame_nodes([a, b, c, join, reviewer])
	await say("Parallel: complete")
