extends "res://tests/client_scenarios/workspace.gd"
var human_typing: RefCounted
var contacts: Control
var started := 0
var desktop_capture := false
var inspected_pane := ""
var overview_center := Vector2.ZERO
var overview_zoom := 1.0
const CHAPTER_END_MSEC := 47000

func data_path(name: String) -> String:
	return output.get_base_dir().path_join(name) if desktop_capture else "user://" + name

func role_labels(panes: Array) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 110
	add_child(layer)
	var names := ["Implement", "Reviewer", "Slack notification"]
	for i in panes.size():
		var label := Label.new()
		label.text = names[i]
		label.add_theme_font_size_override("font_size", 23)
		label.add_theme_color_override("font_color", Color("b8d8f8"))
		label.add_theme_color_override("font_outline_color", Color("15181f"))
		label.add_theme_constant_override("outline_size", 6)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(label)
		var rect: Rect2 = view.pane_rects[panes[i]]
		var top: Vector2 = view.get_global_transform_with_canvas() * view.view_point(Vector2(rect.get_center().x, rect.position.y))
		label.position = top - Vector2(label.get_minimum_size().x * .5, 100)
		label.modulate.a = 0.0
	return layer

func animate_role_labels(layer: CanvasLayer, entering: bool) -> void:
	var labels := layer.get_children()
	var origins: Array[Vector2] = []
	for label in labels: origins.append(label.position)
	var begin := demo_ticks_msec()
	var duration := .30 if entering else .22
	while true:
		var elapsed := (demo_ticks_msec() - begin) / 1000.0
		for i in labels.size():
			var t := clampf((elapsed - i * .04) / duration, 0.0, 1.0)
			var eased := 1.0 - pow(1.0 - t, 3.0)
			labels[i].modulate.a = eased if entering else 1.0 - eased
			labels[i].position = origins[i] + Vector2(0, 8.0 * (1.0 - eased) if entering else -6.0 * eased)
		if elapsed >= duration + (labels.size() - 1) * .04: break
		await get_tree().process_frame

func demo_ticks_msec() -> int:
	if desktop_capture:
		return int(Engine.get_singleton("GraffittyMovieWriter").frames_written() * 1000 / 60)
	return Time.get_ticks_msec()
var beats: Array = []
class Fingers extends Control:
	var positions: Dictionary = {}
	var pointer := Vector2(-100,-100)
	var pressed := false
	func _draw() -> void:
		if pressed and pointer.x >= 0:
			draw_circle(pointer,25,Color(0.15,0.75,1,.22))
			draw_arc(pointer,25,0,TAU,48,Color(.55,.9,1,.95),3,true)
			draw_circle(pointer,5,Color.WHITE)
		for i in positions:
			var p: Vector2 = positions[i]
			draw_circle(p, 25, Color(0.15,0.75,1,0.22))
			draw_arc(p,25,0,TAU,48,Color(0.55,0.9,1,0.95),3,true)
			draw_circle(p,5,Color.WHITE)

func _ready() -> void:
	if desktop_capture:
		human_typing = load("res://videos/shared/typing/HumanTyping.gd").new()
	else:
		human_typing = load("user://human_typing.gd").new("user://typing-timings.json")
	case_name = "demo"
	super._ready()

func until(condition: Callable, message: String, seconds := 12.0) -> bool:
	if not desktop_capture or started == 0:
		return await super.until(condition, message, seconds)
	var deadline := demo_ticks_msec() + int(seconds * 1000)
	while not condition.call() and demo_ticks_msec() < deadline: await wait(.05)
	return expect(condition.call(), message)

func emit_touch(index: int, down: bool, at: Vector2) -> void:
	if down: contacts.positions[index] = at
	else: contacts.positions.erase(index)
	contacts.queue_redraw()
	var event := InputEventScreenTouch.new()
	event.index=index; event.pressed=down; event.position=at
	event.position=root.get_final_transform()*at
	Input.parse_input_event(event)

func emit_drag(index: int, at: Vector2) -> void:
	contacts.positions[index]=at; contacts.queue_redraw()
	var event := InputEventScreenDrag.new()
	event.index=index; event.position=at
	event.position=root.get_final_transform()*at
	Input.parse_input_event(event)

func gesture(from: Vector2, to: Vector2, seconds := 1.0) -> void:
	emit_touch(0,true,from)
	await wait(.08)
	var begin := demo_ticks_msec()
	while demo_ticks_msec()-begin < seconds*1000:
		var t := clampf((demo_ticks_msec()-begin)/(seconds*1000),0,1)
		emit_drag(0,from.lerp(to,smoothstep(0,1,t)))
		await get_tree().process_frame
	emit_drag(0,to); await wait(.04); emit_touch(0,false,to); await wait(.17)

func mouse_move(at: Vector2, held := false) -> void:
	contacts.pointer=at; contacts.queue_redraw()
	var motion := InputEventMouseMotion.new()
	motion.set_meta("direct_touch", true)
	motion.position=root.get_final_transform()*at
	motion.global_position=motion.position
	motion.button_mask=MOUSE_BUTTON_MASK_LEFT if held else 0
	Input.parse_input_event(motion)

func click_right(pane: String) -> String:
	var before: Array = host.sessions.keys()
	var header: Control = view.panes[pane].header
	if not expect(not view.panes[pane].compact_header,"Right-split controls visible before pointer click"): return ""
	var at: Vector2 = view.window_point(header.get_global_transform()*header.part_rect("split_right").get_center())
	var start := at+Vector2(-65,65)
	for i in 16:
		mouse_move(start.lerp(at,float(i)/15))
		await create_timer(.02).timeout
	for down in [true,false]:
		contacts.pressed=down; contacts.queue_redraw()
		var button := InputEventMouseButton.new()
		button.set_meta("direct_touch", true)
		button.position=root.get_final_transform()*at; button.global_position=button.position
		button.button_index=MOUSE_BUTTON_LEFT; button.pressed=down
		button.button_mask=MOUSE_BUTTON_MASK_LEFT if down else 0
		Input.parse_input_event(button)
		await wait(.12)
	mouse_move(at+Vector2(30,45))
	if not await until(func(): return host.sessions.size()==before.size()+1,"Pointer clicks right-split to create one pane"): return ""
	contacts.pointer=Vector2(-100,-100); contacts.queue_redraw()
	for id in host.sessions:
		if id not in before: return "%%%d" % id
	return ""

func beat(label: String) -> void:
	beats.append({"seconds":(demo_ticks_msec()-started)/1000.0,"action":label})
	FileAccess.open(data_path("demo-beats.json"),FileAccess.WRITE).store_string(JSON.stringify(beats))
	print("DEMO_BEAT ",label)

func type_into(pane: String, text: String, closeup := false, fast := false) -> void:
	host.focus_pane(pane)
	await wait(.1 if fast else .25)
	if closeup: await focus_with_double_tap(pane)
	expect(host.pane_focus == pane and terminal(pane).has_focus(),"Typing targets focused pane " + pane)
	var frames: Array = human_typing.frames_before(text)
	for i in text.length():
		if int(frames[i]) > 0: await create_timer(float(mini(int(frames[i]), 2) if fast else int(frames[i])) / 60.0).timeout
		terminal(pane).send_text(text[i])
	await wait(.05 if fast else .4)
	terminal(pane).send_text("\r")
	await wait(.2 if fast else .5)

func move_pane(pane: String, sheet: Vector2) -> void:
	var title: Label = view.pane_titles[pane]
	var from: Vector2 = view.get_global_transform_with_canvas()*view.title_screen_rect(title).get_center()
	var grabbed: Vector2=view.canvas_point_at(view.get_global_transform_with_canvas().affine_inverse()*from)-view.pane_rects[pane].position
	var to: Vector2 = view.window_point(sheet+grabbed)
	await gesture(from,to,.185)

# Use the shared Android E2E input actions, with the demo's finger overlay.
func touch(index: int, down: bool, at: Vector2) -> void:
	emit_touch(index,down,at)
	await wait(.04)

func finger(index: int, at: Vector2) -> void:
	emit_drag(index,at)
	await wait(.04)

# A filmed connection follows the finger every rendered frame. The shared
# stress-test gesture intentionally jogs below the sockets in coarse steps;
# that exercises touch slop but is inappropriate for a smooth demonstration.
func choose_compact_port(endpoint: String, output_port: bool) -> bool:
	var ports = preload("res://scenes/GraphPorts.gd")
	var node: String = ports.node_id(endpoint)
	var declared: Array = ports.ports(host.agent_api.graph.nodes[node], output_port)
	if not view.agent_links.compact_nodes.has(node) or declared.size() <= 1: return true
	var popup: Window
	for frame in 60:
		for candidate in get_tree().get_nodes_in_group(&"touch_menus"):
			if candidate.visible and candidate.model != null: popup = candidate
		if popup != null: break
		await get_tree().process_frame
	if not expect(popup != null, "Compact socket offers the real port menu"): return false
	var index := -1
	for i in declared.size():
		if declared[i].id == ports.port_id(endpoint): index = i
	if not expect(index >= 0 and popup.indices.has(index), "Requested port appears in the menu"): return false
	var row: Button = popup.buttons[popup.indices.find(index)]
	popup.scroll.ensure_control_visible(row)
	await tap(row)
	return true

func connect_graph_ports(source: String, destination: String) -> bool:
	var links: Control = view.agent_links
	var graph: Node = host.agent_api.graph
	var ports = preload("res://scenes/GraphPorts.gd")
	if not await until(func(): return links.has_socket(source,true) and links.has_socket(destination,false),"Both named sockets are available"): return false
	var transform: Transform2D = links.get_global_transform_with_canvas()
	var from: Vector2 = transform * links.port_center(source,true)
	var target: Vector2 = transform * links.port_center(destination,false)
	var grabbed := source
	if links.compact_nodes.has(ports.node_id(source)):
		for endpoint in links.sockets(true):
			if ports.node_id(endpoint) == ports.node_id(source) and links.sockets(true)[endpoint].visible:
				grabbed = endpoint
	emit_touch(0,true,from)
	await wait(.17)
	if not expect(links.dragging==grabbed,"Finger captures node output directly"):
		emit_touch(0,false,from)
		return false
	var begin := demo_ticks_msec()
	var samples := 0
	while demo_ticks_msec()-begin < 350:
		var t := clampf((demo_ticks_msec()-begin)/350.0,0,1)
		emit_drag(0,from.lerp(target,smoothstep(0,1,t)))
		samples += 1
		await get_tree().process_frame
	emit_drag(0,target)
	await wait(.033)
	emit_touch(0,false,target)
	expect(samples>=17,"Wire drag updates at frame cadence: %d samples" % samples)
	if not await choose_compact_port(source, true): return false
	if not await choose_compact_port(destination, false): return false
	return await until(func(): return graph.edges.values().any(func(edge): return ports.endpoint(edge,true)==source and ports.endpoint(edge,false)==destination),"Connected named ports: "+source+" → "+destination)

func double_tap_title(pane: String) -> void:
	var title: Label = view.pane_titles[pane]
	var at: Vector2 = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	if not expect(root.get_visible_rect().has_point(at), "Double-tap title is visible: " + pane): return
	for tap_index in 2:
		emit_touch(0, true, at)
		await wait(.05)
		emit_touch(0, false, at)
		await wait(.05)
	await wait(.35)
	if not await until(func(): return view._inspect_tween == null, "Title-bar double tap settles: " + pane, 2): return

func return_to_overview() -> void:
	if inspected_pane.is_empty(): return
	await double_tap_title(inspected_pane)
	expect(view.navigation_center.distance_to(overview_center) < 1.0 and absf(view.navigation_zoom - overview_zoom) < .001,
		"Title-bar double tap restores overview")
	inspected_pane = ""

func focus_with_double_tap(pane: String) -> void:
	if inspected_pane == pane: return
	await return_to_overview()
	overview_center = view.navigation_center
	overview_zoom = view.navigation_zoom
	await double_tap_title(pane)
	var target: Dictionary = view._inspection_target(pane)
	expect(view.navigation_center.distance_to(target.center) < 1.0 and absf(view.navigation_zoom - target.zoom) < .001,
		"Title-bar double tap focuses pane: " + pane)
	inspected_pane = pane

func establish_overview(bounds: Rect2, seconds := .4) -> void:
	var target: Dictionary = view.fit_frame(bounds.grow(60), view.viewport_content_rect(), view.size, .88)
	# Camera movement in a tutorial must have a visible, reproducible input.
	# Frame the drag route during setup, then center the finished three-node
	# group once.
	#
	# Close-ups use title double taps; the handoff frames Codex and Claude, then
	# one further gesture keeps Claude and Slack together through the findings,
	# queueing and delivery.
	var safe: Rect2 = view.viewport_content_rect().grow(-55)
	var transform: Transform2D = view.get_global_transform_with_canvas()
	var strokes := 0
	while strokes < 16:
		var error: Vector2 = view.view_point(target.center) - view.view_point(view.navigation_center)
		var zoom_ratio: float = target.zoom / view.navigation_zoom
		if error.length() < 1.5 and absf(log(zoom_ratio)) < .003: break
		var fraction := 1.0
		var next_center: Vector2
		var ratio: float
		var from: Vector2
		var to: Vector2
		var radius: float
		for attempt in 12:
			next_center = view.navigation_center.lerp(target.center, fraction)
			ratio = pow(zoom_ratio, fraction)
			var origin: Vector2 = view.view_point(view.navigation_center)
			# Keep the sheet under the old centroid under the new centroid.
			# Center both ends of the stroke in the safe touch area.
			from = (safe.get_center() * 2.0 - origin + view.view_point(next_center) * ratio) / (1.0 + ratio)
			to = safe.get_center() * 2.0 - from
			radius = 80.0 / maxf(ratio, 1.0)
			if safe.has_point(from-Vector2(radius,0)) and safe.has_point(from+Vector2(radius,0)) and safe.has_point(to-Vector2(radius*ratio,0)) and safe.has_point(to+Vector2(radius*ratio,0)): break
			fraction *= .5
		emit_touch(0,true,transform*(from-Vector2(radius,0)))
		emit_touch(1,true,transform*(from+Vector2(radius,0)))
		# Let the shared touch recognizer commit to two-finger navigation.
		await wait(.13)
		if not expect(mobile.gestures.fingers.size()==2 and contacts.positions.size()==2,"Reframe uses two visible captured fingers"): return
		var begin := demo_ticks_msec()
		var duration := maxf(.28, seconds * fraction)
		while demo_ticks_msec()-begin <= duration*1000:
			var t := smoothstep(0,1,minf(1.0,(demo_ticks_msec()-begin)/(duration*1000)))
			var center := from.lerp(to,t)
			var r := lerpf(radius,radius*ratio,t)
			emit_drag(0,transform*(center-Vector2(r,0)))
			emit_drag(1,transform*(center+Vector2(r,0)))
			await get_tree().process_frame
		emit_drag(0,transform*(to-Vector2(radius*ratio,0)))
		emit_drag(1,transform*(to+Vector2(radius*ratio,0)))
		await get_tree().process_frame
		emit_touch(0,false,transform*(to-Vector2(radius*ratio,0)))
		emit_touch(1,false,transform*(to+Vector2(radius*ratio,0)))
		await get_tree().process_frame
		strokes += 1
	var final_error: float = (view.view_point(target.center)-view.view_point(view.navigation_center)).length()
	expect(final_error < 2.0 and absf(log(target.zoom/view.navigation_zoom)) < .005,"Initial overview gesture reaches target: %.2f px, %d strokes" % [final_error,strokes])
	await wait(minf(.3,seconds*.3))

func diagnostics(label: String) -> void:
	var data := {"label":label,"nodes":host.agent_api.graph.nodes,"tabs":host.workspace_layout.tabs,"text":{},"rects":{}}
	for id in host.sessions:
		var k := "%%%d" % id
		data.text[k] = text_in(k)
		data.rects[k] = str(view.pane_rects.get(k))
	FileAccess.open(data_path("demo-debug.json"),FileAccess.WRITE).store_string(JSON.stringify(data))

func demo() -> void:
	Engine.max_fps=60
	if desktop_capture:
		host.localization.set_language("en-US", false)
		mobile.clock_msec = demo_ticks_msec
		root.size = Vector2i(1968, 1968)
		root.content_scale_size = Vector2i.ZERO
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		root.content_scale_factor = 2.625
		await wait(1.0)
	var layer := CanvasLayer.new(); layer.layer=120; add_child(layer)
	contacts=Fingers.new(); contacts.mouse_filter=Control.MOUSE_FILTER_IGNORE; layer.add_child(contacts); contacts.size=root.get_visible_rect().size
	var a: String=host.pane_focus
	terminal(a).send_text("clear\r")
	await wait(1)
	FileAccess.open(data_path("demo-ready"),FileAccess.WRITE).store_string("ready")
	if desktop_capture:
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
		await wait(.15)
	else:
		while not FileAccess.file_exists(data_path("demo-go")): await wait(.1)
	started=demo_ticks_msec()
	FileAccess.open(data_path("geometry.json"),FileAccess.WRITE).store_string(JSON.stringify({"root":str(root.size),"visible":str(root.get_visible_rect()),"transform":str(root.get_final_transform()),"view":str(view.get_global_rect()),"mobile":str(point(mobile))}))
	beat("Android: two-pane tiling")
	expect(view.tab_bar._title_margins == Vector3.ZERO, "Mobile tab strip reserves no desktop window-button space")
	await wait(.1)
	var b := await click_right(a)
	if b.is_empty(): return
	await wait(.1)
	# Clear synthetic mouse hover left behind by the touch-to-pointer bridge.
	for viewport in root.find_children("*","SubViewport",true,false):
		var leave := InputEventMouseMotion.new(); leave.position=Vector2(-100,-100); viewport.push_input(leave,true)
	await wait(.15)
	beat("Android: launch Codex and Claude")
	await type_into(a,"codex",false,true)
	await type_into(b,"claude",false,true)
	var graph: Node=host.agent_api.graph
	if not await until(func(): return graph.nodes.get(a,{}).get("provider")=="codex" and graph.nodes.get(b,{}).get("provider")=="claude","Both mock agents registered",20): return
	beat("Android: arrange workspace")
	var row_y: float=view.content_rect().end.y+view.size.y
	# Show the complete drag route, including each destination, before moving.
	# Keep the pointer and the whole pane in frame throughout both gestures.
	var destination_a := Rect2(Vector2(0,row_y),view.pane_rects[a].size)
	var destination_b := Rect2(Vector2(destination_a.size.x+180,row_y),Vector2(view.content_rect().size.x,view.pane_rects[b].size.y))
	var future_slack := Rect2(destination_b.end - Vector2(0, destination_b.size.y), Vector2(destination_b.size.x * 1.5, destination_b.size.y))
	await establish_overview(view.pane_rects[a].merge(view.pane_rects[b]).merge(destination_a).merge(destination_b).merge(future_slack))
	beat("Android: move terminals beyond Main View")
	await move_pane(a,destination_a.position)
	await move_pane(b,destination_b.position)
	expect(host.workspace_layout.tabs.size()==1,"Moving panes keeps them in the same tab")
	if not view.physics_enabled(): view.toggle_physics()
	# Keep both agents visible while clicking Claude's split control. Do not
	# inspect Claude and return just to expose this button during narration.
	await establish_overview(view.pane_rects[a].merge(view.pane_rects[b]))
	expect(inspected_pane.is_empty(), "Node explanation keeps both agents in the overview")
	var review_width: float=view.pane_rects[b].size.x
	beat("Android: click Claude right-split for Slack")
	var c := await click_right(b)
	if c.is_empty(): return
	expect(view.pane_rects[c].position.x>view.pane_rects[b].position.x,"Slack pane naturally appears to Claude's right")
	diagnostics("Slack created")
	expect(view.pane_rects[c].size.x>=review_width*.85 and view.pane_rects[b].size.x>=review_width*.85,"Claude and Slack preserve source width %.0f: %.0f / %.0f" % [review_width,view.pane_rects[b].size.x,view.pane_rects[c].size.x])
	var slack_rect: Rect2=view.pane_rects[c]
	var spaced := Rect2(slack_rect.position+Vector2(review_width*.3,0),slack_rect.size)
	await establish_overview(view.pane_rects[a].merge(view.pane_rects[b]).merge(slack_rect).merge(spaced))
	beat("Android: drag Slack right for a clear connection")
	await move_pane(c,spaced.position)
	beat("Android: center the three-node overview")
	var node_bounds: Rect2 = view.pane_rects[a].merge(view.pane_rects[b]).merge(view.pane_rects[c])
	await establish_overview(node_bounds)
	var centered: Vector2 = view.view_point(node_bounds.get_center())
	expect(centered.distance_to(view.viewport_content_rect().get_center()) < 2.0,
		"Three-node overview is centered before double-tap navigation")
	await type_into(c,"gft node slack-send",false,true)
	diagnostics("Slack launch")
	if not await until(func(): return graph.nodes.get(c,{}).get("manifest",{}).get("name")=="Slack Send","Local Slack sink registered"): return
	expect(inspected_pane.is_empty(), "Graph setup never detours into a pane close-up")
	var labels := role_labels([a, b, c])
	var explanation_started := demo_ticks_msec()
	beat("Android: connect Turn completed to Receive")
	await animate_role_labels(labels, true)
	if not await connect_graph_ports(a+"/turn_completed",b+"/in"): return
	if not await until(func(): return graph.edges.size()==1,"Completion wire connected"): return
	beat("Android: connect Send to Slack")
	if not await connect_graph_ports(b+"/send",c+"/in"): return
	if not await until(func(): return graph.edges.size()==2,"Slack Send wire connected"): return
	# Completion always emits; Send depends on Claude choosing to notify Slack.
	# Assert the actual shared UI styles so an outdated recording cannot pass.
	var ports = preload("res://scenes/GraphPorts.gd")
	for edge in graph.edges.values():
		var source: String = ports.endpoint(edge, true)
		var expected := "dashed" if source == b+"/send" else "solid"
		expect(view.agent_links.wire_pattern(edge) == expected, source+" wire is "+expected)
	var config: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(data_path("demo-config.json")))
	if config.get("through_wiring",false):
		beat("Wiring rehearsal complete")
		FileAccess.open(data_path("demo-done"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures}))
		return
	# Keep all three roles and both wires visible throughout the explanation.
	while demo_ticks_msec() - explanation_started < 6000: await get_tree().process_frame
	beat("Android: review instructions")
	await wait(5.1)
	await animate_role_labels(labels, false)
	labels.queue_free()
	beat("Android: Claude instructions close-up")
	await type_into(b,"Graffitty will send turn completed payload. Review if it's done right. If not, send me on Slack.",true,true)
	if not await until(func(): return "Ready. I’ll review" in text_in(b) and graph.nodes.get(b,{}).get("status")=="idle","Claude confirms ready before sender starts",15): return
	await wait(.2)
	beat("Android: implement the website")
	var implement_started := demo_ticks_msec()
	await type_into(a,"Implement a website following the spec",true,true)
	await return_to_overview()
	# Show the sender and the reviewer while Codex's completion travels to Claude.
	await establish_overview(view.pane_rects[a].merge(view.pane_rects[b]))
	beat("Android: Codex and reviewer visible together")
	expect(graph.nodes.get(b,{}).get("status")!="busy", "Codex and Claude are framed before the handoff")
	while demo_ticks_msec() - implement_started < 3350: await get_tree().process_frame
	beat("Android: completion payload to reviewer")
	var handoff_started := demo_ticks_msec()
	if not await until(func(): return graph.nodes.get(b,{}).get("status")=="busy","Ready reviewer receives Codex completion",25): return
	# Let Claude's read of the Codex session register, then frame Claude and
	# Slack before the findings appear and keep that view through delivery.
	await wait(.6)
	await establish_overview(view.pane_rects[b].merge(view.pane_rects[c]))
	beat("Android: reviewer and Slack visible together")
	expect(not "missing" in text_in(b).to_lower(), "Claude and Slack are framed before the review findings")
	host.focus_pane(b)
	if not await until(func(): return "missing" in text_in(b).to_lower() and "Keyboard-accessible focus states" in text_in(b),"Reviewer displays all three missing requirements",25): return
	beat("Android: complete missing-requirements list visible")
	await wait(3.0)
	while demo_ticks_msec() - handoff_started < 4300: await get_tree().process_frame
	beat("Android: Slack queue and log")
	if not await until(func(): return "DELIVERED" in text_in(c),"Slack delivery logged",25): return
	# The notification follows the rendered delivery log, never graph.send's
	# earlier queue acknowledgment. Keep this cue in the capture's frame clock.
	await get_tree().process_frame
	if desktop_capture:
		FileAccess.open(data_path("slack-arrival.json"),FileAccess.WRITE).store_string(JSON.stringify({"capture_seconds":demo_ticks_msec()/1000.0,"event":"delivery_logged"}))
	# Hold the delivered result until the accepted chapter end, so the main film
	# keeps its narration placement and later chapters without re-timing.
	var delivered := demo_ticks_msec()
	await return_to_overview()
	expect(started + CHAPTER_END_MSEC - delivered >= 4000, "Slack delivery stays visible for at least 4 seconds")
	while demo_ticks_msec() - started < CHAPTER_END_MSEC: await get_tree().process_frame
	beat("Android: complete")
	FileAccess.open(data_path("demo-done"),FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures}))
