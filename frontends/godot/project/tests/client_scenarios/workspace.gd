extends "res://tests/client_scenarios/scenario.gd"
## Desktop workspace regressions adapted to the production Android remote UI.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var case_name := ""
var manager: Control
var host: Node
var view: Control
var mobile: Control
var transport: Node
var initial_id := -1
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()

func _ready() -> void:
	diagnostic_guard.install(get_tree())
	run.call_deferred()

func expect(ok: bool, message: String) -> bool:
	checks.append(message)
	print("[android workspace] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures.append(message)
		if not OS.has_feature("android") and not output.is_empty(): root.get_texture().get_image().save_png(output.get_base_dir().path_join("failure.png"))
	return ok

func wait(seconds := .15) -> void:
	await create_timer(seconds).timeout
	await get_tree().process_frame
	await get_tree().process_frame

func until(condition: Callable, message: String, seconds := 12.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline: await wait(.05)
	return expect(condition.call(), message)

func terminal(key := "") -> Node:
	return host.sessions[host.active_session_id if key.is_empty() else int(key.substr(1))].term

func text_in(key := "", history := false) -> String:
	return str(terminal(key).get_text(history).get("text", ""))

func current_tree() -> Dictionary:
	return host.workspace_layout.tab(host.workspace_layout.active).tree

func point(control: Control) -> Vector2:
	var at := control.get_global_transform_with_canvas() * (control.size * .5)
	if control.get_window() != root: at += Vector2(control.get_window().position)
	return at

func touch(index: int, down: bool, at: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.position = root.get_final_transform() * at
	Input.parse_input_event(event)
	await wait(.04)

func finger(index: int, at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = root.get_final_transform() * at
	Input.parse_input_event(event)
	await wait(.04)

func tap(control: Control) -> void:
	if not expect(is_instance_valid(control), "Touch control exists"): return
	# Popup/container layout and scroll clamping finish on deferred frames.
	# Aim at the displayed target, not coordinates from the previous layout.
	var at := point(control)
	var stable := 0
	for frame_index in 30:
		await get_tree().process_frame
		var next := point(control)
		stable = stable + 1 if next.distance_to(at) < .1 else 0
		at = next
		if stable >= 3: break
	# Floating controls intentionally stay above dialogs. Touch an exposed
	# part of the requested control, never an unrelated floating microphone.
	var exposed := false
	for fraction in [Vector2(.5, .5), Vector2(.15, .5), Vector2(.85, .5), Vector2(.5, .15), Vector2(.5, .85), Vector2(.15, .15), Vector2(.85, .85)]:
		var candidate: Vector2 = control.get_global_transform_with_canvas() * (control.size * fraction)
		if is_instance_valid(view) and control.get_viewport() == view.canvas:
			candidate = view.get_global_transform_with_canvas() * view.view_point(control.get_global_transform() * (control.size * fraction))
		if control.get_window() != root: candidate += Vector2(control.get_window().position)
		var covered := false
		for entry in manager.floating.entries.values():
			var chrome: Control = entry.button
			if not chrome.is_visible_in_tree() or chrome == control or chrome.is_ancestor_of(control) or control.is_ancestor_of(chrome): continue
			if chrome.get_global_rect().has_point(candidate): covered = true; break
		if not covered:
			at = candidate
			exposed = true
			break
	if not expect(exposed, "Touch target has an exposed area: " + str(control.name)): return
	if not expect(root.get_visible_rect().has_point(at), "Touch control is visible: " + str(control.name)): return
	await touch(0, true, at)
	await touch(0, false, at)
	await wait()

func button(parent: Node, label: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == label: return node
	return null

func key(code: Key, ctrl := false, shift := false, unicode := 0, meta := false) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.unicode = unicode
		event.ctrl_pressed = ctrl
		event.meta_pressed = meta
		event.shift_pressed = shift
		event.pressed = pressed
		root.push_input(event, true)
	await wait(.08)

func menu(label: String) -> void:
	for entry in host.menu_entries:
		if entry.label == label:
			if expect(not entry.has("enabled") or entry.enabled.call(host), "Enabled menu action: " + label): host._run_menu_action(entry)
			await wait(.3)
			return
	expect(false, "Menu action exists: " + label)

## Report a keyboard height as the IME bridge does and apply it at once. The
## insets re-read the IME's height on every later layout event.
func keyboard_inset(height: float) -> void:
	if not is_instance_valid(manager.keyboard_insets):
		# Desktop has no IME; add the production IME node and its insets.
		manager.terminal_ime = preload("res://scenes/input/AndroidTerminalIme.gd").new()
		manager.terminal_ime.manager = manager
		manager.add_child(manager.terminal_ime)
		manager.keyboard_insets = preload("res://scenes/input/AndroidKeyboardInsets.gd").new()
		manager.keyboard_insets.manager = manager
		manager.add_child(manager.keyboard_insets)
	manager.terminal_ime._native_keyboard_height(roundi(height * maxf(root.get_final_transform().get_scale().y, 1.0)))
	manager.keyboard_insets.update_inset(height)

## Tiling has no menu entry or button; the layout action is the only switch.
func toggle_tiling() -> void:
	view.toggle_tiling()
	await wait(.3)

func split(from: String, axis := "h", chrome := false) -> String:
	var before: Array = host.sessions.keys()
	if chrome:
		var header: Control = view.panes[from].header
		view.inspect_pane(from)
		await wait(.8)
		var canvas_point: Vector2 = header.get_global_transform() * header.part_rect("split_down" if axis == "v" else "split_right").get_center()
		expect(view.resize_window_at(canvas_point, true).is_empty(), "Header action wins over the invisible touch resize zone")
		var at: Vector2 = view.window_point(canvas_point)
		await touch(0,true,at)
		await touch(0,false,at)
	else:
		host.create_terminal_window(from, axis)
	if not await until(func(): return host.sessions.size() == before.size() + 1, "Remote split creates exactly one session"): return ""
	for id in host.sessions:
		if id not in before:
			await wait(.3)
			return "%%%d" % id
	return ""

func new_tab() -> int:
	var before: Array = host.workspace_layout.tabs.map(func(t): return int(t.id))
	host.create_session()
	if not await until(func(): return host.workspace_layout.tabs.size() == before.size() + 1, "Create remote tab"): return -1
	await wait(.2)
	for tab in host.workspace_layout.tabs:
		if int(tab.id) not in before: return int(tab.id)
	return -1

func select_tab(id: int) -> void:
	await tap(view.tab_bar.tabs.buttons[id])
	expect(host.workspace_layout.active == id, "Touch selects requested tab")
	await wait(.3)

func camera(center: Vector2, zoom: float) -> void:
	view._cancel_main_magnet()
	view.overview = true
	view.navigation_center = center
	view.navigation_zoom = zoom
	view._apply_navigation()
	await wait(.3)

func frame() -> Dictionary:
	return {"center": view.navigation_center, "zoom": view.navigation_zoom}

## How far a browser pane can be zoomed out toward `target_height` screen
## pixels and still stream, and the rendition height it then asks for.
##
## A pane whose narrow side falls below the client's readable extent, measured
## in density-independent pixels, pauses and keeps its last picture instead of
## switching rendition. A tall, narrow pane on a dense portrait display reaches
## that limit long before a wide desktop pane does.
func streaming_zoom(pane: Control, target_height: float) -> Dictionary:
	var Client := preload("res://scenes/remote/RemoteClient.gd")
	var displayed: Vector2 = Client.chromium_display_size(view, pane.texture)
	var readable: float = Client.RESUME_HEIGHT * 1.1 * host.get_window().content_scale_factor
	var factor: float = minf(1.0, maxf(target_height / maxf(displayed.y, 1.0), readable / maxf(minf(displayed.x, displayed.y), 1.0)))
	var rendition := 2160
	for tier in [144, 240, 360, 540, 720, 1080, 1440, 2160]:
		if displayed.y * factor <= tier:
			rendition = tier
			break
	return {"factor": factor, "rendition": rendition}

func same_frame(a: Dictionary, b: Dictionary) -> bool:
	return a.center.distance_to(b.center) < 2 and absf(a.zoom - b.zoom) < .002

func double_start(at: Vector2) -> void:
	await touch(0, true, at)
	await touch(0, false, at)
	await touch(0, true, at)

func agent_attention() -> void:
	expect(ProjectSettings.get_setting("audio/driver/driver") == "Dummy", "Godot audio remains disabled")
	if OS.has_feature("android"):
		expect(not OS.get_granted_permissions().has("android.permission.RECORD_AUDIO"), "Fixture starts without microphone permission")
	var agents: Node = host.application.agents
	var pane: String = host.pane_focus
	# A real, live process registers through the same CLI hook as a provider.
	await run_python("import os,json,subprocess,time\np={'provider':'pi','event':'SessionStart','pid':os.getpid(),'session_id':'attention-fixture','integrated':True}\nsubprocess.run([os.environ['GRAFFITTY_BIN'],'rpc','agent.event','--params',json.dumps(p)],check=True)\ntime.sleep(90)")
	if not await until(func(): return host.agent_api.graph.nodes.get(pane, {}).get("provider") == "pi", "Server reports the fixture Pi agent"): return
	agents.refresh()
	print("[agent diagnostics] hosts=", host.application.hosts.size(), " graph=", host.agent_api.graph.nodes.size(), " rows=", agents.rows.size())
	if not await until(func(): return agents.rows.any(func(row): return row.key == pane), "Production Agents controller lists the server agent"): return
	host.create_session()
	if not await until(func(): return host.active_session_id != initial_id, "A different terminal is focused before choosing the agent"): return
	# Agents opens by default; start closed so the command tests opening it.
	var existing: Window = preload("res://scenes/AgentsDialog.gd").find(host)
	if existing != null:
		existing._close_panel()
		await wait()
	host.open_command_line("Agents")
	await wait()
	expect(Rect2(Vector2.ZERO, root.get_visible_rect().size - Vector2(0, host.command_line._bottom_inset)).encloses(host.command_line._root.get_global_rect()), "Agents command line fits the keyboard-safe viewport")
	host.command_line._accept()
	await wait()
	var dialog: Node
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "agents": dialog = child
	if not expect(is_instance_valid(dialog) and dialog._desktop.is_visible_in_tree(), "Agents command opens the production docked panel"): return
	# Dock gestures have their own scenario. Set up the floating panel here
	# before exercising its title, resize grip and rendered agent row.
	dialog.float_native()
	await wait()
	if not expect(dialog.visible and dialog._desktop.side.is_empty(), "Agents can float outside its dock"): return
	expect(not dialog.exclusive, "Agents is non-modal")
	# Make room to exercise embedded title and border gestures.
	dialog.size = Vector2i(260, 240)
	await wait()
	var old_position: Vector2i = dialog.position
	var at := Vector2(old_position) + Vector2(80, dialog.floating_title_height() * .5)
	await touch(0, true, at)
	await finger(0, at + Vector2(20, 20))
	await touch(0, false, at + Vector2(20, 20))
	expect(dialog.position != old_position, "Touch drags the Agents title")
	var old_size: Vector2i = dialog.size
	at = Vector2(dialog.position + dialog.size) - Vector2(2, 2)
	await touch(0, true, at)
	await finger(0, at + Vector2(15, 20))
	await touch(0, false, at + Vector2(15, 20))
	expect(dialog.size.x > old_size.x and dialog.size.y > old_size.y, "Touch corner resizes Agents width AND height")
	var agent_rows: Array = agents.rows.filter(func(row): return row.key == pane)
	var row_rect: Rect2 = dialog.view.hit_rect("ag-" + str(agent_rows[0].id)) if not agent_rows.is_empty() else Rect2()
	if expect(row_rect.has_area(), "Dialog contains the actual agent row"):
		at = Vector2(dialog.position) + dialog.view.get_global_transform_with_canvas() * row_rect.get_center()
		await touch(0, true, at)
		await touch(0, false, at)
		await wait()
		expect(host.pane_focus == pane and host.active_session_id == initial_id, "Choosing an agent switches back to its tab and pane")
		expect(dialog.visible, "Agents remains open while focus returns to the app")
		dialog.queue_free()
	else: dialog.queue_free()
	var event := {"provider":"pi", "event":"UserPromptSubmit", "session_id":"attention-fixture", "prompt":"fixture"}
	await transport.remote_call(initial_id, "agent.event", event)
	if not await until(func(): return agents.rows.any(func(row): return row.key == pane and row.status == "working"), "Server work transition reaches Agents"): return
	var before: int = agents.audio_state.completed
	event.event = "PermissionRequest"
	await transport.remote_call(initial_id, "agent.event", event)
	if not await until(func(): return agents.rows.any(func(row): return row.key == pane and row.status == "blocked"), "Server attention transition reaches Agents"): return
	if not await until(func(): return agents.audio_state.completed == before + 1, "Native attention output completes with Dummy Godot driver"): return
	expect(agents.audio_state.active == 0 and agents.audio_state.error.is_empty(), "Native output closes after playback")
	for index in 5: agents.refresh()
	await wait(.5)
	expect(agents.audio_state.completed == before + 1, "Repeated snapshots do not replay attention audio")
	agents._sounds.enabled = false
	event.event = "UserPromptSubmit"
	await transport.remote_call(initial_id, "agent.event", event)
	await wait(.3)
	event.event = "PermissionRequest"
	await transport.remote_call(initial_id, "agent.event", event)
	await wait(2)
	expect(agents.audio_state.completed == before + 1, "Client mute prevents subsequent alerts")
	agents._sounds.enabled = true
	# No agent.event hook: an ordinary shell/SSH pane reports an app via OSC.
	host.create_session()
	if not await until(func(): return host.active_session_id != initial_id, "Create an OSC-only agent pane"): return
	var osc_pane: String = host.pane_focus
	await run_python("import sys,time\nsys.stdout.write('\\x1b]7501;state=working:app=pi\\x07');sys.stdout.flush();time.sleep(4)\nsys.stdout.write('\\x1b]7501;state=blocked:app=pi\\x07');sys.stdout.flush();time.sleep(90)")
	if not await until(func(): return host.agent_api.graph.nodes.get(osc_pane, {}).get("status_source") == "program", "OSC status reaches the graph without provider hooks"): return
	expect(host.agent_api.graph.nodes[osc_pane].get("provider") == "shell", "OSC does not invent an authorized provider identity")
	if not await until(func(): return agents.rows.any(func(row): return row.key == osc_pane and row.provider == "pi" and row.status == "working"), "Agents lists the OSC-only Pi program"): return
	if not await until(func(): return agents.rows.any(func(row): return row.key == osc_pane and row.status == "blocked"), "OSC attention transition reaches Agents"): return
	if not await until(func(): return agents.audio_state.completed == before + 2, "OSC-only agent plays attention sound"): return
	expect(agents.audio_state.active == 0 and agents.audio_state.error.is_empty(), "OSC attention output closes cleanly")
	host._run_bound_action("Agents")
	await wait()
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "agents" and not child.is_queued_for_deletion(): dialog = child
	expect(dialog._resize_grip.text.is_empty(), "Agents has no triangle label")
	# Audio diagnostic stays in the controller, not as unsolicited dialog UI.
	agents.test_sound()
	if not await until(func(): return agents.audio_state.completed == before + 3, "Controller sound test uses the native attention output"): return
	expect(agents.audio_state.active == 0 and agents.audio_state.error.is_empty(), "Test sound output closes cleanly")
	if OS.has_feature("android"):
		expect(not OS.get_granted_permissions().has("android.permission.RECORD_AUDIO"), "All alerts and Test sound played without microphone permission")
	dialog.queue_free()

## One finger on a docked sidebar and one on the main area pinch the workspace;
## each surface keeps the gestures it has already decided on.
func sidebar_pinch() -> void:
	if preload("res://scenes/AgentsDialog.gd").find(host) == null:
		host._run_bound_action("Agents")
	await wait()
	var agents: Window
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "agents": agents = child
	if not expect(is_instance_valid(agents) and is_instance_valid(agents._desktop) and agents._desktop.side == "left", "Agents docks into the left sidebar"): return
	var panel: Control = agents._desktop
	panel.space.widths.left = 240
	panel.space.reflow()
	await wait()
	var k: String = host.pane_focus
	host.world.fx_enabled = false
	var target: Dictionary = view._inspection_target(k)
	# Away from the fitted frame, whose detent would pull a small pinch back.
	await camera(target.center, target.zoom * .7)
	var side: Vector2 = panel.slot.get_global_rect().get_center()
	var main: Vector2 = view.get_global_transform_with_canvas() * view.viewport_content_rect().get_center()
	expect(mobile._zone(side) == mobile.Navigation.Zone.YIELDING and mobile._zone(main) == mobile.Navigation.Zone.WORKSPACE, "Sidebar content yields; the main area is workspace")
	# Everything the sidebar is given, whichever of its controls receives it.
	var seen: Array[String] = []
	var stack: Array = [panel]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node != agents.view: continue
		node.gui_input.connect(func(event: InputEvent):
			if event is InputEventScreenTouch: seen.append("cancel" if event.canceled else ("press" if event.pressed else "release"))
			elif event is InputEventScreenDrag: seen.append("drag")
			elif event is InputEventMouseButton and event.device == -1 and event.canceled: seen.append("mouse-cancel"))
	var inverse := view.get_global_transform_with_canvas().affine_inverse()
	# Along the line through both fingers, where a pinch without rotation keeps
	# the resting one exactly in place.
	var spread: Vector2 = main + (main - side).normalized() * 250

	# Sidebar first: its resting finger is canceled there and anchors the pinch.
	var zoom: float = view.navigation_zoom
	var fixed: Vector2 = view.canvas_point_at(inverse * side)
	await touch(0, true, side)
	expect(seen == ["press"] and mobile.gestures.fingers.is_empty(), "A lone sidebar finger belongs to the sidebar")
	await touch(1, true, main)
	expect(mobile.gestures.fingers.size() == 2, "A main-area finger takes the resting sidebar finger into one gesture")
	expect(seen == ["press", "mouse-cancel", "cancel"], "The sidebar sees its contact canceled, mouse first (saw %s)" % [seen])
	seen.clear()
	await wait(.15)
	await finger(1, spread)
	expect(view.navigation_zoom > zoom * 1.05, "Spreading across the sidebar zooms the workspace in")
	expect(view.view_point(fixed).distance_to(inverse * side) < 3, "The pinch stays anchored under the sidebar finger")
	await finger(0, side + Vector2(0, 40))
	await touch(1, false, spread)
	await touch(0, false, side + Vector2(0, 40))
	expect(seen.is_empty() and mobile.gestures.fingers.is_empty(), "The sidebar gets nothing more from a contact it gave up (saw %s)" % [seen])
	await camera(target.center, target.zoom * .7)

	# Main area first: the sidebar never sees the second finger at all.
	zoom = view.navigation_zoom
	await touch(0, true, main)
	await wait(.2)
	await touch(1, true, side)
	expect(mobile.gestures.fingers.size() == 2 and seen.is_empty(), "A sidebar finger joins a resting main-area finger")
	await wait(.15)
	await finger(0, spread)
	expect(view.navigation_zoom > zoom * 1.05, "The pinch works in this order too")
	await touch(0, false, spread)
	await touch(1, false, side)
	expect(seen.is_empty() and mobile.gestures.fingers.is_empty(), "Lifting leaves no click or scroll in the sidebar")
	await camera(target.center, target.zoom)

	# A pane drag under way is not interrupted; the sidebar keeps the second finger.
	var title: Label = view.pane_titles[k]
	var title_at: Vector2 = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	await touch(0, true, title_at)
	await finger(0, title_at + Vector2(45, 30))
	if not await until(func(): return view.moving == k, "Title drag starts", 1.0): return
	await touch(1, true, side)
	expect(view.moving == k and mobile.gestures.fingers.size() == 1 and mobile.gestures.held, "A sidebar touch does not interrupt a pane drag")
	await finger(0, title_at + Vector2(60, 40))
	expect(view.moving == k, "The pane drag keeps following its finger")
	await finger(1, side + Vector2(0, 40))
	expect(seen == ["press", "drag"], "The sidebar scrolls with the second finger meanwhile (saw %s)" % [seen])
	await touch(1, false, side + Vector2(0, 40))
	await finger(0, title_at)
	await touch(0, false, title_at)
	await wait(.4)
	seen.clear()
	await camera(target.center, target.zoom)

	# The sidebar keeps a finger that is already scrolling it, or resting too long.
	zoom = view.navigation_zoom
	await touch(0, true, side)
	await finger(0, side + Vector2(0, 40))
	await touch(1, true, main)
	expect(mobile.gestures.fingers.size() == 1 and "cancel" not in seen, "A scrolling sidebar finger is not taken")
	await finger(0, side + Vector2(0, 80))
	expect(seen.count("drag") == 2, "It keeps scrolling the sidebar")
	await touch(1, false, main)
	await touch(0, false, side + Vector2(0, 80))
	seen.clear()
	await touch(0, true, side)
	await wait(mobile.gestures.YIELD_MS / 1000.0 + .1)
	await touch(1, true, main)
	expect(mobile.gestures.fingers.size() == 1 and "cancel" not in seen, "A finger held on the sidebar stays a long press there")
	await touch(1, false, main)
	var lift := InputEventScreenTouch.new()
	lift.index = 0
	lift.position = root.get_final_transform() * side
	lift.canceled = true
	Input.parse_input_event(lift)
	await wait()
	expect(absf(view.navigation_zoom - zoom) < .002 and mobile.gestures.fingers.is_empty(), "Neither changes the view")
	seen.clear()

	# Resize targets and titles never join, even beside a resting finger.
	var width: float = panel.space.widths.left
	var edge: Vector2 = panel._edge.get_global_rect().get_center()
	for chrome in [edge, panel._header.get_global_rect().position + Vector2(20, 10)]:
		expect(mobile._zone(chrome) == mobile.Navigation.Zone.EXCLUSIVE, "Dock chrome is exclusive")
		await touch(0, true, main)
		await touch(1, true, chrome)
		expect(mobile.gestures.fingers.size() == 1, "Dock chrome keeps its own touch")
		var drop: InputEventScreenTouch = lift.duplicate()
		drop.index = 1
		drop.position = root.get_final_transform() * chrome
		Input.parse_input_event(drop)
		await wait()
		await touch(0, false, main)
		await wait(.4)
	expect(is_equal_approx(panel.space.widths.left, width) and panel.side == "left" and not agents.folded, "Canceled chrome touches change nothing")

func list_docking() -> void:
	if preload("res://scenes/AgentsDialog.gd").find(host) == null:
		host._run_bound_action("Agents")
	await wait()
	var agents: Window
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "agents": agents = child
	if not expect(is_instance_valid(agents) and is_instance_valid(agents._desktop), "Agents opens in the workspace"): return
	expect(agents._desktop.side == "left" and not agents.visible, "Agents docks into the left sidebar by default")
	# The floating checks below start from an undocked window, as a title drag leaves it.
	agents.float_native()
	await wait()
	if not expect(agents.visible and agents._desktop.side.is_empty(), "Undocking floats Agents"): return
	var space: Control = agents._desktop.space
	agents.size = Vector2i(240, 240)
	await wait()
	var floating_size := agents.size
	var floating_position := agents.position
	var title_point := Vector2(agents.position) + Vector2(100, 12)
	await touch(0, true, title_point)
	await touch(0, false, title_point)
	await wait()
	expect(agents.folded and not agents._body.visible and agents.size.y < floating_size.y and agents.position == floating_position, "A floating title tap folds the body without moving the title")
	await touch(0, true, title_point)
	await touch(0, false, title_point)
	await wait()
	expect(not agents.folded and agents.size == floating_size, "A second floating title tap restores its size")
	var old_size := agents.size
	var corner := Vector2(agents.position + agents.size) + Vector2(3, 3)
	await _drag_list(corner, corner + Vector2(25, 30))
	expect(agents.size.x > old_size.x and agents.size.y > old_size.y, "Embedded window corner resizes both dimensions")
	var area: Rect2 = space.bounds()
	expect(not agents._resize_grip.visible and agents.unresizable, "Mobile has no resize grip and no stock top-edge resizing")
	expect(agents.borderless and agents._frame.get_theme_stylebox("panel").border_width_left == 0, "Mobile floating dialog has no painted border")
	var resize_origin := Vector2i(area.position + Vector2(40, 60))
	for edge in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 1)]:
		agents.position = resize_origin
		agents.size = Vector2i(240, 240)
		await wait()
		var point := Vector2(agents.position) + Vector2(0 if edge.x < 0 else (240 if edge.x > 0 else 120), 240 if edge.y > 0 else 120)
		await _drag_list(point, point + edge * 20)
		expect(agents.size == Vector2i(240 + (20 if edge.x != 0 else 0), 240 + (20 if edge.y != 0 else 0)), "Invisible left/right/bottom and bottom-left corner resize on intended axes")
		expect(agents._desktop.side.is_empty(), "Edge resizing does not trigger docking")
	for x in [2, 120, 238]:
		agents.position = resize_origin
		agents.size = Vector2i(240, 240)
		await wait()
		var top := Vector2(agents.position) + Vector2(x, 12)
		await _drag_list(top, top + Vector2(10, 20))
		expect(agents.size == Vector2i(240, 240), "Top edge and corners never resize")
	# Those title drags begin inside the left dock zone and may have docked the
	# window; the floating checks below need it floating again.
	if not agents._desktop.side.is_empty():
		agents.float_native()
		await wait()
	# A phone cannot keep every window whole: dragged toward the side, short of
	# the edge docking target, the window hangs off while its title stays grabbable.
	agents.position = Vector2i(int(area.get_center().x) - 120, resize_origin.y)
	await wait()
	var drop := Vector2(area.end.x - 90, agents.position.y + 12)
	await _drag_list(Vector2(agents.position) + Vector2(20, 12), drop)
	expect(agents._desktop.side.is_empty() and agents.position.x + agents.size.x > area.end.x + 60, "A floating window may hang off the screen edge (side=%s position=%s size=%s area.end=%s)" % [agents._desktop.side, agents.position, agents.size, area.end])
	expect(agents.title_reachable() and agents.position.x <= area.end.x - 44, "A finger's width of its title stays on screen")
	# A grab that begins inside a dock zone but is released far away must not dock.
	agents.position = resize_origin
	await wait()
	await _drag_list(Vector2(agents.position) + Vector2(20, 12), Vector2(area.get_center().x, agents.position.y + 12))
	expect(agents._desktop.side.is_empty() and agents.visible and agents.position.x > resize_origin.x + minf(200, area.size.x * .25), "A title drag that starts near the dock edge but ends in the middle just moves the window (side=%s position=%s)" % [agents._desktop.side, agents.position])
	agents.position = resize_origin
	await wait()
	await _drag_list(Vector2(agents.position) + Vector2(80, 12), area.position + Vector2(3, 100))
	if not expect(agents._desktop.side == "left" and not agents.visible, "Touch title docks Agents into main content"): return
	if preload("res://scenes/session/SessionsDialog.gd").find(host) == null:
		host._run_bound_action("AllSessions")
	await wait()
	var sessions: Window
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "sessions": sessions = child
	if not expect(is_instance_valid(sessions) and is_instance_valid(sessions._desktop) and agents._desktop.side == "left", "Sessions opens without disturbing Agents"): return
	# Sessions joins the left dock by default; the title-drag stacking below starts floating.
	sessions.float_native()
	await wait()
	sessions.size = Vector2i(240, 240)
	await wait()
	await _drag_list(Vector2(sessions.position) + Vector2(80, 12), area.position + Vector2(3, 40))
	if not expect(sessions._desktop.side == "left", "Touch title stacks Sessions above Agents"): return
	var panel: Control = sessions._desktop
	space.widths.left = 240
	space.reflow()
	await wait()
	var stack_height: float = panel.size.y
	var dock_title: Control = panel._header.get_child(0)
	await tap(dock_title)
	await wait()
	expect(sessions.folded and panel._header.visible and absf(panel.size.y - space.MIN_BAND_HEIGHT) < 1.0, "A docked title tap folds only that panel: folded=%s height=%s minimum=%s" % [sessions.folded, panel.size.y, space.MIN_BAND_HEIGHT])
	await tap(dock_title)
	await wait()
	expect(not sessions.folded and absf(panel.size.y - stack_height) < 1, "A second docked title tap restores its proportions")
	var before: Vector2 = panel.size
	var at: Vector2 = panel._divider.get_global_rect().get_center()
	await _drag_list(at, at + Vector2(0, 35))
	expect(panel.size.y > before.y, "Touch divider adjusts proportions")
	at = panel._edge.get_global_rect().get_center()
	await _drag_list(at, at - Vector2(35, 0))
	expect(panel.size.x < before.x, "Touch inner edge adjusts dock width")
	space.toggle_fold("left")
	await wait()
	expect(agents.compact and sessions.compact and absf(panel.size.x - minf(space.COLLAPSED_WIDTH, space.width_limit("left"))) < 1.0 and not panel._header.visible, "Phone sidebar folds without arrow controls")
	at = panel._edge.get_global_rect().get_center()
	await _drag_list(at, at + Vector2(150, 0))
	expect(not sessions.compact, "Touch resizing expands the sidebar")
	# PaneStatus toggles; a monitor restored by the saved dock layout is reused.
	var resources := preload("res://scenes/PaneStatusDialog.gd").find(host)
	if not is_instance_valid(resources):
		host._run_bound_action("PaneStatus")
		await wait()
		resources = preload("res://scenes/PaneStatusDialog.gd").find(host)
	if not expect(is_instance_valid(resources) and is_instance_valid(resources._desktop), "Pane Status opens with shared window chrome"): return
	resources.float_native()
	await wait()
	resources.size = Vector2i(240, 240)
	await wait()
	await _drag_list(Vector2(resources.position) + Vector2(80, 12), area.position + Vector2(3, 20))
	if not expect(resources._desktop.side == "left", "Touch title stacks Pane Status beside the lists"): return
	expect(resources.load_error.is_empty() and "readout" in resources.view.hit_keys(), "Docked Pane Status renders its panel readout")
	host.application.mods.publish_resources(host)
	await wait()
	# The label is localized ("Pane %0 · running", "Panneau %0 · en cours"); the pane ID is not.
	var readout: Array = resources.texts()
	expect(not readout.is_empty() and str(readout[0]).contains(host.pane_focus), "Docked readout names the focused pane (focus=%s texts=%s)" % [host.pane_focus, readout])
	# Exercise the real manager boundary with docked tools and a floating list.
	sessions.float_native()
	space.reflow()
	manager._show_chooser()
	await wait()
	expect(manager.chooser.visible and not host.layout_root.visible and not space.visible and not agents._desktop.visible and not sessions.visible and not resources._desktop.visible, "Workspace manager never overlaps docked or floating tools")
	manager._return_to_workspace()
	await wait()
	expect(not manager.chooser.visible and host.layout_root.visible and space.visible and agents._desktop.visible and sessions.visible and resources._desktop.visible, "Returning restores all tool presentations")
	agents._close_panel()
	sessions._close_panel()
	resources._close_panel()

func dock_camera() -> void:
	# The existing list-docking case covers dragging. Here, exercise camera
	# composition against real dock reservations and a server-owned PTY cursor.
	var world: Node = host.world
	if preload("res://scenes/AgentsDialog.gd").find(host) == null:
		host._run_bound_action("Agents")
	if preload("res://scenes/session/SessionsDialog.gd").find(host) == null:
		host._run_bound_action("AllSessions")
	var status_line: Window = preload("res://scenes/mods/PanelWindow.gd").find(host, "status-line")
	if status_line != null: status_line._close_panel()
	await wait()
	var agents: Window
	var sessions: Window
	for child in host.get_window().get_children():
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "agents": agents = child
		if child is Window and child.is_in_group(&"panel_window") and child.mod_name == "sessions": sessions = child
	if not expect(is_instance_valid(agents) and is_instance_valid(sessions), "Camera fixture opens both real dockable panels"): return
	var space: Control = agents._desktop.space
	var resources := preload("res://scenes/PaneStatusDialog.gd").open(host)
	await run_python("import os,sys,tty,termios,signal\nold=termios.tcgetattr(0)\ntty.setraw(0)\nedge=None\ndef draw():\n if edge is None: return\n cols,rows=os.get_terminal_size()\n row,col=(min(3,rows),min(2,cols)) if edge==b'l' else (max(1,rows-2),max(1,cols-2))\n os.write(1, ('\\x1b[2J\\x1b[?25h\\x1b[2 q\\x1b]12;#00ff00\\x07\\x1b[%d;%dH'%(row,col)).encode())\nsignal.signal(signal.SIGWINCH, lambda *_: draw())\ntry:\n os.write(1,b'\\x1b[2J\\x1b[HDOCK_CAMERA_READY')\n while True:\n  edge=os.read(0,1)\n  if edge==b'q': break\n  draw()\nfinally:\n termios.tcsetattr(0,termios.TCSADRAIN,old)\n")
	if not await until(func(): return text_in().contains("DOCK_CAMERA_READY"), "Real PTY cursor fixture starts"): return
	world.fx_enabled = true
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "typing")
	for state in [str(world.fx_cfg.behavior.active_state), str(world.fx_cfg.behavior.rest_state)]:
		world.fx_cfg.set_option("state." + state, "camera.drift_px", 0.0)
		world.fx_cfg.set_option("state." + state, "camera.tilt_limit_deg", 0.0)
		world.fx_cfg.set_option("state." + state, "camera.shake_px", 0.0)
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.rest_state), "camera.zoom", 1.0)
	var width: float = space.bounds().size.x
	for config in [["left", width * .32, 1.15], ["right", width * .32, 2.0], ["both", width * .22, 1.15], ["both", width * .3, 2.0], ["top", 0.0, 1.15], ["bottom", 0.0, 2.0], ["both-top", width * .22, 2.0], ["both-bottom", width * .22, 1.15], ["none", 0.0, 1.15]]:
		agents.float_native(); agents.hide()
		sessions.float_native(); sessions.hide()
		resources.float_native(); resources.hide()
		var has_left: bool = config[0] == "left" or config[0].begins_with("both")
		var has_right: bool = config[0] == "right" or config[0].begins_with("both")
		var band := "top" if config[0].ends_with("top") else ("bottom" if config[0].ends_with("bottom") else "")
		space.widths.left = maxf(40, config[1])
		space.widths.right = maxf(40, config[1])
		if has_left: space.commit(agents._desktop, space.plan(agents._desktop, space.bounds().get_center(), "left"))
		if has_right: space.commit(sessions._desktop, space.plan(sessions._desktop, space.bounds().get_center(), "right"))
		if not band.is_empty(): space.commit(resources._desktop, space.plan(resources._desktop, space.bounds().get_center(), band))
		# Committing a drop installs the candidate's floating-window height.
		# Set the intended band extent after that placement has been committed.
		space.band_rows = {"top": [120.0], "bottom": [120.0]}
		space.reflow()
		await wait(.5)
		expect((view.dock_insets.x > 0) == has_left and (view.dock_insets.y > 0) == has_right and (view.dock_insets.z > 0) == (band == "top") and (view.dock_insets.w > 0) == (band == "bottom"), "Requested dock reservations are active: %s insets=%s panels=%s" % [config[0], view.dock_insets, [agents._desktop.side, sessions._desktop.side, resources._desktop.side]])
		if not band.is_empty():
			expect(not view.workspace_region().contains(view.get_global_transform_with_canvas().affine_inverse() * resources._desktop.get_global_rect().get_center()), "Band is excluded from workspace pointer region: " + band)
		world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", config[2])
		view.overview = false
		view._apply_navigation()
		for edge in ["l", "r"]:
			terminal().send_text(edge)
			if not await until(func():
				var live_grid: Vector2i = terminal().get_grid_size()
				var expected := Vector2i(mini(2, live_grid.x) - 1, mini(3, live_grid.y) - 1) if edge == "l" else Vector2i(maxi(1, live_grid.x - 2) - 1, maxi(1, live_grid.y - 2) - 1)
				return terminal().get_cursor_cell() == expected
			, "Owner cursor update arrives before measuring camera: %s/%s" % [config[0], edge]):
				print("DOCK_CURSOR_TIMEOUT ", text_in())
				return
			var saved := frame()
			var contained_during_zoom := true
			for sample in 30:
				world.fx_last_key = world.fx_time
				await wait(.04)
				var animated_anchor: Vector2 = view.terminal_origin(host.pane_focus) + (terminal().position + terminal().get_cursor_anchor_local()) * view.terminal_scale(host.pane_focus)
				var animated_cell: Vector2 = terminal().get_cell_size() * view.terminal_scale(host.pane_focus)
				var usable: Rect2 = view.workspace_region().rect().grow(1)
				contained_during_zoom = contained_during_zoom and usable.has_point(view.view_point(animated_anchor - Vector2(0, animated_cell.y))) and usable.has_point(view.view_point(animated_anchor + Vector2(animated_cell.x, 0)))
			expect(contained_during_zoom, "Cursor stays outside docks throughout zoom, not only after settling: %s/%s" % [config[0], edge])
			var applied_zoom: float = world.navigation_camera.zoom if world.navigation_camera_active else world.fx_cam_zoom
			expect(absf(applied_zoom - float(config[2])) < .06, "Typing camera reaches the requested zoom multiplier")
			var cell: Vector2i = terminal().get_cursor_cell()
			var grid: Vector2i = terminal().get_grid_size()
			expect(cell == (Vector2i(mini(2, grid.x) - 1, mini(3, grid.y) - 1) if edge == "l" else Vector2i(maxi(1, grid.x - 2) - 1, maxi(1, grid.y - 2) - 1)), "Server cursor reaches requested edge: %s/%s" % [config[0], edge])
			await RenderingServer.frame_post_draw
			var anchor: Vector2 = view.terminal_origin(host.pane_focus) + (terminal().position + terminal().get_cursor_anchor_local()) * view.terminal_scale(host.pane_focus)
			var cell_size: Vector2 = terminal().get_cell_size() * view.terminal_scale(host.pane_focus)
			var corners := [view.view_point(anchor - Vector2(0, cell_size.y)), view.view_point(anchor + Vector2(cell_size.x, 0))]
			var visible: Rect2 = view.viewport_content_rect()
			expect(visible.grow(1).has_point(corners[0]) and visible.grow(1).has_point(corners[1]), "Zoomed cursor cell stays outside docks and chrome: %s/%s" % [config[0], edge])
			expect(same_frame(saved, frame()), "Cursor follow does not rewrite manual navigation")
			var image := root.get_texture().get_image()
			var pixel_rect := Rect2i(root.get_final_transform() * (view.get_global_transform_with_canvas() * corners[0]), (corners[1] - corners[0]) * root.content_scale_factor).abs().intersection(Rect2i(Vector2i.ZERO, image.get_size()))
			var bright := 0
			for y in range(pixel_rect.position.y, pixel_rect.end.y):
				for x in range(pixel_rect.position.x, pixel_rect.end.x):
					var color := image.get_pixel(x, y)
					if color.g > .65: bright += 1
			if bright <= 2: print("DOCK_CURSOR_PIXELS ", config[0], "/", edge, " rect=", pixel_rect, " cell=", cell, " grid=", grid, " anchor=", anchor, " corners=", corners, " bright=", bright, " cursor=", terminal().get_cursor_render_info(), " pane=", view.panes[host.pane_focus].get_rect(), " crop=", view.panes[host.pane_focus]._layout_region, " raster=", view.raster_region, " focus=", terminal().has_focus(), " terminal=", text_in())
			expect(bright > 2, "Cursor actually paints visible framebuffer pixels: %s/%s" % [config[0], edge])
		# Resizing legitimately reflows the PTY grid and the fitted manual frame.
		# Check live containment separately from the fixed-geometry assertions above.
		if not band.is_empty():
			for height in [160.0, 120.0]:
				space.band_rows[band] = [height]
				space.reflow()
				var contained_during_resize := true
				for sample in 15:
					world.fx_last_key = world.fx_time
					await wait(.04)
					var anchor: Vector2 = view.terminal_origin(host.pane_focus) + (terminal().position + terminal().get_cursor_anchor_local()) * view.terminal_scale(host.pane_focus)
					var cell: Vector2 = terminal().get_cell_size() * view.terminal_scale(host.pane_focus)
					var usable: Rect2 = view.workspace_region().rect().grow(1)
					contained_during_resize = contained_during_resize and usable.has_point(view.view_point(anchor - Vector2(0, cell.y))) and usable.has_point(view.view_point(anchor + Vector2(cell.x, 0)))
				expect(contained_during_resize, "Cursor stays outside the dock while resizing during zoom: %s/%s" % [config[0], height])
		# Exercise inverse projection with a dock present, not just containment.
		world.fx_enabled = false
		var target: Dictionary = view.main_frame()
		await camera(target.center, target.zoom * 1.4)
		var at: Vector2 = view.viewport_content_rect().get_center()
		var canvas_anchor: Vector2 = view.canvas_point_at(at)
		view.pinch_workspace(at, at + Vector2(8, 6), 1.1)
		await wait()
		expect(view.view_point(canvas_anchor).distance_to(at + Vector2(8, 6)) < 3, "Dock-aware pinch preserves the finger anchor: " + config[0])
		world.fx_enabled = true
	terminal().send_text("q")
	agents._close_panel(); sessions._close_panel(); resources._close_panel()

func touch_menus() -> void:
	var popups := preload("res://scenes/PopupChrome.gd")
	const TouchMenu := preload("res://scenes/input/TouchMenu.gd")
	var toolbar: Control = host.window_menu
	await tap(toolbar.expand_button)
	var opener: MenuButton = toolbar.buttons.get_node("View")
	await tap(opener)
	var model := opener.get_popup()
	var popup = popups.presentation(model)
	if not expect(popup is TouchMenu, "Main menu uses shared touch presentation"): return
	if not await until(func(): return popup.visible, "View menu opens from a touch release"): return
	expect(popup.size.y <= 360 and popup.size.x <= 320, "Menu stays compact instead of filling the display")
	expect(Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(Rect2(popup.position, popup.size)), "Menu fits the visible screen")
	var unchecked_options := 0
	for row in popup.indices.size():
		var index: int = popup.indices[row]
		if index < 0 or not model.is_item_checkable(index): continue
		var indicator: TextureRect = popup.buttons[row].get_node_or_null("CheckIndicator")
		expect(indicator != null and indicator.texture != null and indicator.is_visible_in_tree(), "View option displays its state: " + model.get_item_text(index))
		if not model.is_item_checked(index): unchecked_options += 1
	expect(unchecked_options > 0, "View menu exercises visible unchecked options")
	var invoked: Array[int] = []
	model.id_pressed.connect(func(id: int): invoked.append(id))
	var rect := Rect2(Vector2(popup.position) + popup.surface.position, popup.surface.size)
	var start := rect.position + rect.size * Vector2(.5, .8)
	var end := start - Vector2(0, minf(150, rect.size.y * .5))
	await touch(0, true, start)
	for step in range(1, 9): await finger(0, start.lerp(end, step / 8.0))
	expect(popup.scroll.scroll_vertical > 30, "Dragging across real menu items scrolls the menu")
	expect(popup.buttons.all(func(row): return not row.button_pressed), "Scroll owns the gesture; no item keeps focus/pressed highlighting")
	await touch(0, false, end)
	expect(invoked.is_empty() and popup.visible, "Scroll release invokes no command and leaves menu open")
	# Reach the last command by touch, not by assigning the scroll offset.
	for repeat in 4:
		await touch(0, true, start)
		for step in range(1, 7): await finger(0, start.lerp(end, step / 6.0))
		await touch(0, false, end)
	expect(invoked.is_empty(), "Repeated scrolling never leaks item activation")
	var last: Button = popup.buttons.back()
	expect(rect.has_point(point(last)), "Bottom command is reachable by scrolling")
	# Close through Android's shared Back policy, then reopen and toggle the opener.
	expect(preload("res://scenes/input/WorkspaceMenus.gd").dismiss(host), "Back policy dismisses the touch menu stack")
	await wait()
	expect(not popup.visible and not toolbar.expanded, "Back closes popup and expanded toolbar")
	await tap(toolbar.expand_button)
	await tap(opener)
	await wait()
	expect(popup.visible, "Menu reopens after Back")
	await tap(opener)
	expect(not popup.visible, "Tapping the same opener closes without reopening")
	await tap(opener)
	await wait()
	var submenu_row := -1
	for row in popup.indices.size():
		if popup.indices[row] >= 0 and model.get_item_submenu_node(popup.indices[row]) != null:
			submenu_row = row
			break
	if expect(submenu_row >= 0, "Real View menu contains a submenu"):
		popup.scroll.ensure_control_visible(popup.buttons[submenu_row])
		await wait()
		await tap(popup.buttons[submenu_row])
		expect(not popup.stack.is_empty() and popup.model != model, "Submenu shares the bounded scroll presenter")
		await tap(popup.buttons[0])
		expect(popup.stack.is_empty() and popup.model == model, "Submenu Back returns to its parent")
	preload("res://scenes/input/WorkspaceMenus.gd").dismiss(host)
	await wait()

func _drag_list(from: Vector2, to: Vector2) -> void:
	await touch(0, true, from)
	for i in range(1, 9): await finger(0, from.lerp(to, float(i) / 8))
	await touch(0, false, to)
	await wait(.2)

func run_python(source: String) -> void:
	terminal().send_text("python3 -c 'import base64;exec(base64.b64decode(\"%s\"))'\r" % Marshalls.utf8_to_base64(source))

func run() -> void:
	Input.emulate_mouse_from_touch = true
	var directory: String = preload("res://graffitty/paths.gd").stdpath("state")
	DirAccess.make_dir_recursive_absolute(directory)
	FileAccess.open(directory.path_join("remote.json"), FileAccess.WRITE).store_string(JSON.stringify(settings))
	manager = preload("res://scenes/remote_manager.tscn").instantiate()
	add_child(manager)
	if not await until(func(): return manager.view.host != null and not manager.view.host.sessions.is_empty(), "Production manager connects to real server", FIRST_CONNECTION_SECONDS):
		quit(1); return
	if not OS.has_feature("android"):
		root.unfocusable = true
		root.size = Vector2i(1100,750)
		root.content_scale_size = root.size
		root.content_scale_factor = 1.0
		await wait(.3)
	manager._return_to_workspace()
	host = manager.view.host
	view = host.workspace_view
	transport = manager.federation.connections[0]
	initial_id = host.active_session_id
	for child in view.get_children():
		if child.get_script() == preload("res://scenes/input/MobilePointer.gd"): mobile = child
	expect(mobile != null, "Android interaction profile uses direct touch")
	if view.physics_enabled(): await menu("View::Floating Pane Physics")
	await wait(.5)
	await call(case_name.replace("-", "_"))
	await wait(.3)
	expect(is_instance_valid(host) and host.sessions.has(initial_id), "Original server terminal survives scenario")
	if is_instance_valid(mobile): expect(mobile.buttons == 0 and mobile.gestures.fingers.is_empty(), "Scenario releases all contacts and buttons")
	failures.append_array(diagnostic_guard.failures)
	result = {"target": -1, "verify_terminal_commands": false}
	quit(0 if failures.is_empty() else 1)

func text_size() -> void:
	var sizing := preload("res://scenes/TerminalFontSizing.gd")
	var first: String = host.pane_focus
	var first_size: int = terminal().get_meta("pane_font_size")
	var second := await split(first)
	if second.is_empty(): return
	var pill: Button = manager.floating.entries.text_size.button
	expect(pill.size.is_equal_approx(Vector2(104, 52)), "Text size is one floating minus/plus pill (actual %s)" % pill.size)
	var label_size: int = view.tab_bar.tabs.buttons.values()[0].get_theme_font_size("font_size")
	for direction in [1, -1]:
		var before: int = terminal().get_meta("pane_font_size")
		await tap_text_size(direction)
		await until(func(): return int(terminal().get_meta("pane_font_size")) == sizing.step(before, direction > 0), "Floating pill resizes the focused terminal")
	expect(int(terminal(first).get_meta("pane_font_size")) == first_size, "Another terminal keeps its font size")
	expect(view.tab_bar.tabs.buttons.values()[0].get_theme_font_size("font_size") == label_size, "App labels keep their text size")
	expect(host.bindings.direct_key("IncreaseFontSize") & KEY_MASK_CTRL, "Android font shortcuts use Ctrl")
	var hovered_panel: Window = preload("res://scenes/mods/PanelWindow.gd").under_pointer(host)
	print("FONT_SHORTCUT_TARGET ", hovered_panel.mod_name if hovered_panel != null else "terminal", " pointer=", root.get_mouse_position())
	for spec in [[KEY_EQUAL, false], [KEY_EQUAL, true], [KEY_PLUS, false], [KEY_PLUS, true], [KEY_MINUS, false]]:
		var code: int = spec[0]
		var before: int = terminal().get_meta("pane_font_size")
		await key(code, true, spec[1], code)
		await until(func(): return int(terminal().get_meta("pane_font_size")) == sizing.step(before, code != KEY_MINUS), "Ctrl+" + ("Shift+" if spec[1] else "") + OS.get_keycode_string(code) + " changes terminal text once")
	await key(KEY_0, true)
	await until(func(): return int(terminal().get_meta("pane_font_size")) == transport.font_default(host.active_session_id), "Ctrl+0 restores terminal default")
	var previous_bottom: float = host.layout_root.offset_bottom
	if OS.has_feature("android"):
		await tap(manager.floating.get_node("KeyboardButton"))
		if not await until(func(): return manager.keybar.visible, "Accessory Ctrl appears above the IME"): return
	else:
		host.layout_root.offset_bottom = -manager.keybar.HEIGHT
		manager.keybar.show()
	manager.keybar.update_host()
	for code in [KEY_EQUAL, KEY_PLUS]:
		var before: int = terminal().get_meta("pane_font_size")
		await tap(manager.keybar.buttons.ctrl)
		await key(KEY_UNKNOWN, false, false, code)
		await until(func(): return int(terminal().get_meta("pane_font_size")) == sizing.step(before, true), "Accessory Ctrl and IME " + OS.get_keycode_string(code) + " resize terminal text")
	# Verify real PTY bytes, not just the state of the modifier button. The
	# plain U after Ctrl+U must not inherit the consumed one-shot modifier.
	run_python("import os,tty,termios,select,time\nf=0\nold=termios.tcgetattr(f)\ntty.setraw(f)\nprint('CTRL_BYTES_READY',flush=True)\ndata=b''\ndeadline=time.monotonic()+6\nwhile len(data)<3 and time.monotonic()<deadline:\n if select.select([f],[],[],.1)[0]: data+=os.read(f,3-len(data))\ntermios.tcsetattr(f,termios.TCSANOW,old)\nprint('CTRL_BYTES_'+data.hex(),flush=True)")
	if await until(func(): return "CTRL_BYTES_READY" in text_in("", true).replace("\n", "").replace("\r", ""), "Shell is ready to capture Ctrl bytes"):
		await tap(manager.keybar.buttons.ctrl)
		await key(KEY_UNKNOWN, false, false, 117)
		await key(KEY_UNKNOWN, false, false, 117)
		await key(KEY_U, true, false, 117)
		if not await until(func(): return "CTRL_BYTES_157515" in text_in("", true).replace("\n", "").replace("\r", ""), "Accessory Ctrl and hardware Ctrl send real control bytes, without sticking"):
			var captured := RegEx.create_from_string("CTRL_BYTES_[0-9a-f]+").search(text_in("", true).replace("\n", "").replace("\r", ""))
			print("CTRL_BYTES_EVIDENCE ", captured.get_string() if captured else "capture unfinished")
	if OS.has_feature("android"):
		manager.keyboard_insets._hide_keyboard()
		await until(func(): return not manager.keybar.visible, "IME closes before page zoom")
	else:
		manager.keybar.hide()
		host.layout_root.offset_bottom = previous_bottom
	var result: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(result.has("result"), "Creates Chrome for native page zoom"): return
	var id := int(str(result.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Chrome is ready for page zoom"): return
	var chromium: Node = host.chromiums[id]
	host.focus_pane("%%%d" % id)
	await wait(.4)
	# A page handler must not block native chromium zoom.
	await chromium_eval(chromium, "document.onkeydown=e=>e.preventDefault(); window.devicePixelRatio")
	var initial_ratio: float = await chromium_eval(chromium, "window.devicePixelRatio")
	await tap_text_size(1)
	await wait(.4)
	var enlarged_ratio: float = await chromium_eval(chromium, "window.devicePixelRatio")
	expect(enlarged_ratio > initial_ratio, "Floating plus invokes native Chrome page zoom")
	await tap_text_size(-1)
	await wait(.4)
	expect(is_equal_approx(await chromium_eval(chromium, "window.devicePixelRatio"), initial_ratio), "Floating minus restores Chrome page zoom")
	for code in [KEY_EQUAL, KEY_PLUS]:
		await key(code, true, false, code)
		await wait(.4)
		expect(float(await chromium_eval(chromium, "window.devicePixelRatio")) > initial_ratio, "Ctrl shortcut zooms Chrome independently of remote server OS")
		await key(KEY_0, true)
		await wait(.3)
		expect(is_equal_approx(await chromium_eval(chromium, "window.devicePixelRatio"), initial_ratio), "Ctrl+0 restores native Chrome zoom")
	# Several soft keyboards have no key-up for committed punctuation.
	for unused in 2:
		var before: float = await chromium_eval(chromium, "window.devicePixelRatio")
		var event := InputEventKey.new()
		event.keycode = KEY_UNKNOWN
		event.unicode = 43
		event.ctrl_pressed = true
		event.pressed = true
		root.push_input(event, true)
		await wait(.4)
		expect(float(await chromium_eval(chromium, "window.devicePixelRatio")) > before, "Repeated IME Ctrl+Plus works without key releases")
	await key(KEY_0, true)
	expect(int(terminal(first).get_meta("pane_font_size")) == first_size, "Chrome zoom leaves terminal text unchanged")

func tap_text_size(direction: int) -> void:
	var pill: Button = manager.floating.entries.text_size.button
	await wait(.36)
	var at: Vector2 = pill.get_global_transform_with_canvas() * Vector2(pill.size.x * (.25 if direction < 0 else .75), pill.size.y / 2)
	await touch(0, true, at)
	await touch(0, false, at)
	await wait(.1)

func pane_controls() -> void:
	# This case checks both visible title buttons on overlapping floating
	# panes. Narrow tiled headers intentionally collapse the secondary button.
	if current_tree().get("tiling", false): await toggle_tiling()
	var a: String = host.pane_focus
	var b := await split(a,"h",true)
	if b.is_empty(): return
	# Physics is disabled for deterministic camera assertions; separate the
	# intentionally overlapping spawn so the unfocused pane button is exposed.
	var moved: Rect2 = view.pane_rects[b]
	moved.position += Vector2(100,100)
	view.set_window_rect(b,moved,true)
	await wait()
	var c := await split(a,"v",true)
	if c.is_empty(): return
	expect(Layout.keys(current_tree()).size() == 3, "Right and below splits stay in one tab")
	expect(host.chromiums.is_empty(), "Terminal splits never open a chromium")
	expect(host.pane_focus == c, "Splitting an unfocused pane focuses the new pane")
	terminal(c).send_text("printf 'PANE_%s\\n' INPUT_ONLY\r")
	await until(func(): return "PANE_INPUT_ONLY" in text_in(c), "New pane receives input")
	expect(not "PANE_INPUT_ONLY" in text_in(a) and not "PANE_INPUT_ONLY" in text_in(b), "Input does not leak into other panes")
	for k in [a,b,c]:
		var id := int(k.substr(1))
		var owner: Dictionary = transport.topology.panes.filter(func(pane): return int(pane.id) == id).front()
		expect(terminal(k).remote_mode and int(owner.pid) > 0 and terminal(k).get_shell_pid() == int(owner.pid), "Android pane mirrors the existing owner shell")
		expect(view.panes[k].header.view.last_error().is_empty(), "Pane-header mod and its split icons are packaged")
	host._close_terminal_pane(int(c.substr(1)))
	await until(func(): return not host.sessions.has(int(c.substr(1))), "Close only newly created pane")
	expect(host.sessions.size() == 2, "Other two panes remain alive")

func close_nearest() -> void:
	var far: String = host.pane_focus
	var near := await split(far)
	var closing := await split(near)
	if near.is_empty() or closing.is_empty(): return
	current_tree()["tiling"] = false
	for placement in [[far, Rect2(-1800,100,400,300)],[near,Rect2(600,100,400,300)],[closing,Rect2(1100,100,400,300)]]:
		Layout.find(current_tree(),placement[0]).rect = placement[1]
	host._refresh_workspace_layout()
	host.focus_pane(closing)
	await camera(view.pane_rects[closing].get_center(), .6)
	var typed: float = host.world.fx_last_key
	var typing_events := [0]
	var on_typed := func(): typing_events[0] += 1
	host.world.workspace_typed.connect(on_typed)
	host._close_terminal_pane(int(closing.substr(1)))
	if not await until(func(): return not view.panes.has(closing), "Remote close removes target pane"): return
	expect(host.pane_focus == near, "Remote close chooses nearest survivor")
	for sample in 10:
		await wait(.05)
		expect(absf(view.navigation_zoom-.6)<.001, "Close pans without zoom")
		# Focusing the surviving pane may backdate the effect clock to cancel
		# old animation. A typing event or a newer timestamp would activate it.
		expect(typing_events[0] == 0 and host.world.fx_last_key <= typed, "Close does not trigger typing effects")
	host.world.workspace_typed.disconnect(on_typed)
	expect(view.navigation_center.distance_to(view.pane_rects[near].get_center())<3, "Camera centers nearest survivor")

func fit_restore() -> void:
	var k: String = host.pane_focus
	await camera(view.pane_rects[k].get_center()+Vector2(120,60), .35)
	var original := frame()
	var rects: Dictionary = view.pane_rects.duplicate()
	view.toggle_fit_pane(k)
	expect(same_frame(frame(),original), "Fit starts without snapping")
	await wait(.12)
	expect(not same_frame(frame(),original), "Fit has an intermediate animation frame")
	var canvas_extent: Vector2i = view.canvas.size
	var terminal_extent: Vector2i = host.sessions[int(k.substr(1))].vp.size
	var resized_during_fit := false
	while view._inspect_tween != null and view._inspect_tween.is_running():
		await host.get_tree().process_frame
		resized_during_fit = resized_during_fit or view.canvas.size != canvas_extent \
			or host.sessions[int(k.substr(1))].vp.size != terminal_extent
	expect(not resized_during_fit, "Animated fit reuses canvas and terminal render targets")
	await wait(.4)
	view.toggle_fit_pane(k)
	await wait(.5)
	expect(same_frame(frame(),original), "Fit toggle restores exact pan and zoom")
	view.toggle_fit_pane(k)
	await wait(.1)
	var middle := frame()
	view.toggle_fit_pane(k)
	expect(same_frame(frame(),middle), "Interrupted fit reverses without snapping")
	await wait(.5)
	expect(same_frame(frame(),original), "Interrupted fit returns to saved view")
	view.toggle_fit_pane(k)
	await wait(.1)
	view.pinch_workspace(view.size*.5,view.size*.5+Vector2(30,20),.8)
	var manual := frame()
	await wait(.5)
	expect(same_frame(frame(),manual), "Pinch cancels in-flight fit")
	expect(view.pane_rects == rects, "Fit preserves pane layout and shared grid")
	await menu("View::Fit to Pane")
	await wait(.5)
	expect(Rect2(Vector2.ZERO,view.size).grow(3).encloses(view._pane_screen_rect(view.panes[k])), "Android Fit toolbar reveals complete pane")

func tiling_layout() -> void:
	if not current_tree().get("tiling",false): await toggle_tiling()
	var a: String = host.pane_focus
	var b := await split(a)
	var c := await split(b,"v")
	if b.is_empty() or c.is_empty(): return
	if not current_tree().get("tiling",false): await toggle_tiling()
	view.refresh()
	await wait()
	var keys := Layout.tile_keys(current_tree().get("tiles",{}))
	expect(keys.size()==3,"Nested split contains all three tiles")
	for k in keys:
		expect(view.content_rect().grow(2).encloses(view.pane_rects[k]), "Tile stays in main area")
	for i in keys.size():
		for j in range(i+1,keys.size()): expect(not view.pane_rects[keys[i]].intersects(view.pane_rects[keys[j]]),"Tiled panes never overlap")
	expect(view.pane_rects[a].size.y > view.pane_rects[b].size.y*1.8,"Left tile stays full-height across nested vertical split")
	# Record frame pacing and render-target churn during a repeatable pinch/pan.
	view.show_overview()
	await wait(.5)
	var resize_count := 0
	var samples: Array[float] = []
	var previous_extent: Vector2i = view.canvas.size
	var previous_tick := Time.get_ticks_usec()
	for sample in 90:
		var center: Vector2 = view.size * .5
		view.pinch_workspace(center, center + Vector2(2, 1), 1.006 if sample < 45 else 1.0 / 1.006)
		await get_tree().process_frame
		var tick := Time.get_ticks_usec()
		samples.append((tick - previous_tick) / 1000.0)
		previous_tick = tick
		if view.canvas.size != previous_extent: resize_count += 1
		previous_extent = view.canvas.size
	expect(resize_count == 0, "Touch navigation reuses canvas render targets throughout gesture")
	await wait(.3)
	expect(not view.holding_navigation_render_targets(), "Full resolution refresh resumes after gesture settles")
	samples.sort()
	print("GESTURE_PROFILE ", JSON.stringify({"median_ms": samples[45], "p95_ms": samples[85], "canvas_resizes": resize_count, "frames": samples.size()}))
	# Drive the same title drag using real touch events, including colour preview.
	view.show_overview()
	await wait(.5)
	var title: Label = view.pane_titles[b]
	var from: Vector2 = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	var drop: Vector2 = view.pane_rects[a].get_center()
	var to: Vector2 = view.get_global_transform_with_canvas() * view.view_point(drop)
	await touch(0, true, from)
	for step in 8: await finger(0, from.lerp(to, float(step + 1) / 8))
	expect(not view.preview_plan.is_empty(), "Touch title drag builds shared placement proposal")
	expect(view.layout_preview.visible and view.layout_preview.rectangles.size() >= 2, "Touch shows coloured incoming and neighbouring tile previews")
	await wait(.5)
	var coloured := root.get_texture().get_image()
	coloured.resize(128, 128)
	view.layout_preview.hide()
	await wait(.1)
	var plain := root.get_texture().get_image()
	plain.resize(128, 128)
	var coloured_pixels := 0
	for y in 128:
		for x in 128:
			var difference: Color = coloured.get_pixel(x, y) - plain.get_pixel(x, y)
			if absf(difference.r) + absf(difference.g) + absf(difference.b) > .04: coloured_pixels += 1
	expect(coloured_pixels > 500, "Coloured preview changes rendered screen pixels while origin is outside camera crop")
	view.layout_preview.show()
	await wait(.1)
	await touch(0, false, to)
	expect(not view.layout_preview.visible, "Touch release clears placement preview")
	var before: Array = host.sessions.keys()
	expect(host.menu_entries.all(func(entry): return entry.label != "View::Tiling"), "Tiling has no menu switch")
	await toggle_tiling()
	expect(not current_tree().tiling,"Tiling toggle switches to floating mode")
	await toggle_tiling()
	expect(current_tree().tiling and host.sessions.keys()==before,"Retiling keeps the live sessions")

func per_tab_tiling() -> void:
	var a: int = host.workspace_layout.active
	await split(host.pane_focus)
	var b := await new_tab()
	await select_tab(b)
	# Physics is per-tab; freeze this new tab too before comparing exact rects.
	if view.physics_enabled(): await menu("View::Floating Pane Physics")
	await split(host.pane_focus,"v")
	if current_tree().get("tiling",false): await toggle_tiling()
	var floating: Dictionary = view.pane_rects.duplicate()
	await select_tab(a)
	if not current_tree().get("tiling",false): await toggle_tiling()
	var tiled: Dictionary = view.pane_rects.duplicate()
	for repetition in 3:
		await select_tab(b)
		expect(not current_tree().tiling and view.pane_rects==floating,"Second tab retains floating mode and placement")
		await select_tab(a)
		expect(current_tree().tiling and view.pane_rects==tiled,"First tab retains its independent tile layout")

func tab_reorder() -> void:
	await new_tab()
	await new_tab()
	var tabs: Node = view.tab_bar.tabs
	var ids: Array = tabs.ids.duplicate()
	await select_tab(int(ids[0]))
	var from := point(tabs.buttons[ids[0]])
	var to: Vector2 = point(tabs.buttons[ids[2]]) + Vector2(tabs.buttons[ids[2]].size.x*.4,0)
	await touch(0,true,from)
	for step in 12:
		await finger(0,from.lerp(to,float(step+1)/12))
	await touch(0,false,to)
	await wait(.5)
	expect(tabs.ids == [ids[1],ids[2],ids[0]],"Finger drag reorders tab to the end (from=%s to=%s, order=%s expected=%s)" % [from, to, tabs.ids, [ids[1],ids[2],ids[0]]])
	expect(host.workspace_layout.active == ids[0],"Dragged tab stays selected")
	expect(host.sessions.size()==3 and host.application.hosts.size()==1,"Reorder creates no panes or desktop windows")
	terminal().send_text("printf 'ORDER_%s\\n' SURVIVES\r")
	await until(func(): return "ORDER_SURVIVES" in text_in(),"Reordered tab retains its server terminal")
	# Keep the finger down while a different tab opens, then carry the whole
	# source workspace into its content. This crosses the tab/content boundary.
	from = point(tabs.buttons[ids[0]])
	to = point(tabs.buttons[ids[1]])
	await touch(0,true,from)
	for step in 16:
		await finger(0,from.lerp(to,float(step+1)/16))
	await wait(.8)
	if not expect(host.workspace_layout.active == ids[1], "Holding a dragged tab over another tab opens its content"): return
	expect(not host.application.drag.is_empty(), "Touch drag survives switching to the target tab")
	var drop: Vector2 = view.get_global_transform_with_canvas() * (view.size * Vector2(.5,.45))
	for step in 16:
		await finger(0,to.lerp(drop,float(step+1)/16))
	expect(host.application.drag.get("mode") == host.application.DragMode.MERGE, "Dragging down from the tab bar previews a merge")
	await touch(0,false,drop)
	await until(func(): return host.workspace_layout.tabs.size() == 2, "Releasing the finger merges the source tab")
	expect(Layout.keys(current_tree()).size() == 2 and host.sessions.size() == 3,
		"Merged tab contains both panes and preserves every terminal")
	expect(host.application.drag.is_empty() and not tabs._dragging, "Merge releases the touch capture")

## Where a pane header is on screen; panes are drawn through the workspace canvas.
func header_point(key: String) -> Vector2:
	var handle: Control = view.panes[key].handle
	return view.window_point(handle.get_global_transform() * (handle.size * .5))

## Aim at a header only after tab-switch animations and pane motion stop.
## Slower devices are still flying panes when the selection itself changes.
func settled_header_point(key: String) -> Vector2:
	var last := Vector2.INF
	var stable := 0
	var deadline := Time.get_ticks_msec() + 8000
	while stable < 3 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var at := header_point(key)
		var resting: bool = host.world.tab_fx_t < 0.0 and host.world.fly_dur <= 0.0 and view.panes[key].is_visible_in_tree()
		stable = stable + 1 if resting and at.distance_to(last) < .5 else 0
		last = at
	expect(stable >= 3, "Pane header settles before the drag starts")
	return last

func pane_tab_transfer() -> void:
	var tabs: Node = view.tab_bar.tabs
	var app: Node = host.application
	var source_tab: int = host.workspace_layout.active
	var moved := await split(host.pane_focus)
	if moved.is_empty(): return
	var target_tab := await new_tab()
	var sole_tab := await new_tab()
	if target_tab < 0 or sole_tab < 0: return
	await select_tab(source_tab)
	# Carry a pane over another tab, wait for it to open, then drop into its content.
	var from := await settled_header_point(moved)
	var over := point(tabs.buttons[target_tab])
	await touch(0, true, from)
	for step in 16: await finger(0, from.lerp(over, float(step + 1) / 16))
	await wait(.8)
	if not expect(host.workspace_layout.active == target_tab, "Holding a dragged pane over another tab opens it" + (
			"" if host.workspace_layout.active == target_tab else " (drag %s %s mode %s, active %d, pressed %s, from %s over %s)" % [
			app.drag.get("kind"), app.drag.get("pane"), app.drag.get("mode"), host.workspace_layout.active, view.panes[moved]._pressed, from, over])):
		await touch(0, false, over)
		return
	var drop: Vector2 = view.get_global_transform_with_canvas() * (view.size * Vector2(.5, .6))
	for step in 16: await finger(0, over.lerp(drop, float(step + 1) / 16))
	expect(app.drag.get("mode") == app.DragMode.MERGE, "Dragging into the opened tab previews a move")
	await touch(0, false, drop)
	await until(func(): return host.workspace_layout.containing(moved) == target_tab, "Releasing moves the pane into the other tab")
	await until(func(): return app.drag.is_empty() and not view.panes[moved]._pressed, "Pane transfer releases its drag")
	expect(host.workspace_layout.tabs.size() == 3 and host.sessions.size() == 4, "Moving a pane creates no tab and preserves every terminal")
	# A sole pane dropped on the tab bar would only recreate its own tab.
	await select_tab(sole_tab)
	var sole: String = Layout.keys(current_tree())[0]
	from = await settled_header_point(sole)
	var last: Control = tabs.buttons[tabs.ids.back()]
	var bar_end := point(last) + Vector2(last.size.x * 1.2, 0)
	await touch(0, true, from)
	for step in 16: await finger(0, from.lerp(bar_end, float(step + 1) / 16))
	expect(app.drag.get("mode") != app.DragMode.DOCKED, "A sole pane over the tab bar does not offer a new tab")
	expect(tabs.external_drop_hint < 0, "No new-tab insertion hint is drawn for a sole pane")
	await touch(0, false, bar_end)
	await until(func(): return app.drag.is_empty() and not view.panes[sole]._pressed, "Releasing the redundant move ends the drag")
	expect(host.workspace_layout.tabs.size() == 3 and host.workspace_layout.containing(sole) == sole_tab, "Redundant move leaves the tab and pane unchanged")
	# Tab dragging still works after both pane drags.
	var order: Array = tabs.ids.duplicate()
	from = point(tabs.buttons[order[0]])
	var to: Vector2 = point(tabs.buttons[order[2]]) + Vector2(tabs.buttons[order[2]].size.x * .4, 0)
	await touch(0, true, from)
	for step in 12: await finger(0, from.lerp(to, float(step + 1) / 12))
	await touch(0, false, to)
	await until(func(): return tabs.ids == [order[1], order[2], order[0]], "Tabs still reorder after pane transfers")
	# Android has no second window: a tab dropped onto its own content moves nothing.
	var tab_count: int = host.workspace_layout.tabs.size()
	var active: int = host.workspace_layout.active
	from = point(tabs.buttons[active])
	var own_content: Vector2 = view.get_global_transform_with_canvas() * (view.size * Vector2(.5, .6))
	await touch(0, true, from)
	for step in 16: await finger(0, from.lerp(own_content, float(step + 1) / 16))
	expect(app.drag.get("mode") == app.DragMode.BLOCKED, "A tab over its own content is not a detach target")
	expect(not (is_instance_valid(app.drag_preview) and app.drag_preview.visible), "No new-window preview is shown")
	await touch(0, false, own_content)
	await until(func(): return app.drag.is_empty() and not tabs._dragging, "Releasing the refused detach ends the drag")
	expect(host.workspace_layout.tabs.size() == tab_count and app.hosts.size() == 1 and host.workspace_layout.active == active, "Refused detach creates no tab or window")
	await select_tab(target_tab)
	terminal(moved).send_text("printf 'MOVED_%s\\n' ALIVE\r")
	await until(func(): return "MOVED_ALIVE" in text_in(moved), "Moved pane keeps its server terminal")
	# A tab chosen while another is still being created keeps the selection.
	var count: int = host.workspace_layout.tabs.size()
	host.create_session()
	# Select before the owner can confirm, as a tap racing a slow connection does.
	host.select_workspace(source_tab)
	await until(func(): return host.workspace_layout.tabs.size() == count + 1, "Create remote tab")
	await wait(1.0)
	expect(host.workspace_layout.active == source_tab, "Selecting a tab during creation is not undone by the new tab")

func pane_resize() -> void:
	if current_tree().get("tiling", false): await toggle_tiling()
	var a: String = host.pane_focus
	var b := await split(a)
	if b.is_empty(): return
	var grid_b: Vector2i = terminal(b).get_grid_size()
	var pane: Control = view.panes[a]
	for grid in [Vector2i(55,16),Vector2i(92,30),Vector2i(65,20)]:
		var rect: Rect2 = view.pane_rects[a]
		# The owner defines grid metrics and content insets, independently of DPI.
		var owner_pane: Dictionary = transport.topology.panes.filter(func(p): return int(p.id) == int(a.substr(1)))[0]
		var metrics: Dictionary = owner_pane.font_metrics
		var insets: Array = owner_pane.content_insets
		rect.size = Vector2(grid.x * metrics.width + insets[0] + insets[2], grid.y * metrics.height + insets[1] + insets[3])
		view.set_window_rect(a,rect,true)
		host.session_backend.move_pane(host, a, Vector2.INF)
		await until(func(): return terminal(a).get_grid_size()==grid,"Resize reaches authoritative server grid "+str(grid))
		expect(terminal(b).get_grid_size()==grid_b,"Resize leaves adjacent terminal grid unchanged")
	terminal(a).send_text("printf 'SIZE_%s\\n' RETAINED\r")
	await until(func(): return "SIZE_RETAINED" in text_in(a),"Resized terminal continues accepting input")
	# Exercise the actual screen-touch route, not just the resize RPC. The
	# invisible grip extends into empty canvas without turning into view pan.
	var neighbor: Rect2 = view.pane_rects[b]
	# Floating panes keep part of their header reachable, so a narrow phone
	# clamps a far-right neighbor back over this pane. Below it stays clear.
	view.set_window_rect(b, Rect2(neighbor.position + Vector2(3000, 3000), neighbor.size))
	host.session_backend.move_pane(host, b, Vector2.INF)
	await until(func(): return not host.session_backend.work_pending(), "Neighbor placement is acknowledged before touch resizing")
	await wait(.3)
	# Placement can apply the pane chrome minimum on a narrow phone.
	# Measure isolation against that completed setup, before resizing a.
	grid_b = terminal(b).get_grid_size()
	var base := Rect2(200, 160, 480, 300)
	expect(not view.pane_rects[b].intersects(base.grow(80)), "Neighbor is clear of the resized pane's touch grips: %s" % view.pane_rects[b])
	for zoom in [.7, 1.1]:
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN, Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			view.set_window_rect(a, base, true)
			host.session_backend.move_pane(host, a, Vector2.INF)
			await camera(base.get_center(), zoom)
			var before: Rect2 = view.pane_rects[a]
			var edge: Vector2 = before.position + before.size * (Vector2.ONE + direction) * .5
			# Phones cannot show every edge of this owner-sized pane at once.
			# Navigate to the measured grip before beginning the gesture.
			await camera(edge, zoom)
			var navigation := frame()
			var start: Vector2 = view.window_point(edge) + direction * 26.0
			await touch(0, true, start)
			await finger(0, start + direction * 14.0)
			await wait(.12) # Allow the recognizer's second-finger grace period.
			if not pane._resizing:
				var start_canvas: Vector2 = view.canvas_point_at(view.get_global_transform_with_canvas().affine_inverse() * start)
				print("RESIZE_CAPTURE ", direction, " start=", start, " canvas=", start_canvas, " pane=", view.pane_rects[a], " hovered=", get_viewport().gui_get_hovered_control(), " target=", view.resize_window_at(start_canvas, true), " over=", view.window_at(start_canvas), " visible=", view.viewport_content_rect(), " region=", view.workspace_region().rect())
			expect(pane._resizing, "Touch outside edge/corner captures resize: %s at %.1fx" % [direction, zoom])
			await finger(0, start + direction * 48.0)
			await touch(0, false, start + direction * 48.0)
			await wait(.2)
			var after: Rect2 = view.pane_rects[a]
			expect(after.size.x > before.size.x + 20 if direction.x != 0 else absf(after.size.x - before.size.x) < 2, "Finger resize changes only requested width")
			expect(after.size.y > before.size.y + 20 if direction.y != 0 else absf(after.size.y - before.size.y) < 2, "Finger resize changes only requested height")
			var fixed_before: Vector2 = before.position + before.size * (Vector2.ONE - direction) * .5
			var fixed_after: Vector2 = after.position + after.size * (Vector2.ONE - direction) * .5
			expect(fixed_before.distance_to(fixed_after) < 2, "Opposite edge stays anchored")
			expect(same_frame(navigation, frame()), "An exterior resize never pans or zooms the workspace")
			if pane._resizing or terminal(b).get_grid_size() != grid_b: print("RESIZE_RELEASE resizing=", pane._resizing, " neighbor=", terminal(b).get_grid_size(), " expected=", grid_b)
			expect(not pane._resizing and terminal(b).get_grid_size() == grid_b, "Release ends resizing without changing the neighbor grid")
	# A second finger must abort even when the first began outside the pane.
	var before_cancel: Rect2 = view.pane_rects[a]
	var start: Vector2 = view.window_point(before_cancel.end) + Vector2(26, 26)
	await touch(0, true, start)
	await finger(0, start + Vector2(30, 30))
	await wait(.12)
	expect(pane._resizing, "Exterior resize starts before pinch cancellation")
	var stages := {"dragged": str(view.pane_rects[a])}
	await touch(1, true, start - Vector2(100, 0))
	expect(not pane._resizing, "Second finger cancels exterior resize")
	stages.cancelled = str(view.pane_rects[a])
	await touch(0, false, start + Vector2(30, 30))
	stages.first_lifted = str(view.pane_rects[a])
	await touch(1, false, start - Vector2(100, 0))
	stages.second_lifted = str(view.pane_rects[a])
	if not await until(func(): return view.pane_rects[a].is_equal_approx(before_cancel), "Pinch cancellation restores the original pane rectangle"):
		print("RESIZE_CANCEL ", JSON.stringify({"before": str(before_cancel), "after": str(view.pane_rects[a]), "stages": stages, "start": str(pane._start_rect), "pending": host.session_backend.work_pending(), "zoom": frame()}))
	await resize_across_main_boundary(a, b)
	# Deliberately move both panes back to Main: resizing alone must not rejoin.
	# Shared dividers use the same finger-sized acquisition without detaching.
	for pane_key in [a, b]:
		view.set_window_rect(pane_key, Rect2(view.content_rect().get_center() - Vector2(240, 150), Vector2(480, 300)))
		host.session_backend.move_pane(host, pane_key, Vector2.INF)
		await wait(.3)
	await toggle_tiling()
	await camera(view.content_rect().get_center(), .7)
	var dividers: Array = Layout.tile_dividers(current_tree().tiles, Layout.tiling_area(current_tree(), view.content_rect()), [], host.tiling_config.gap)
	if expect(not dividers.is_empty(), "Both panes return to the tiled layout"):
		var divider: Dictionary = dividers[0]
		var axis := Vector2.RIGHT if divider.axis == "h" else Vector2.DOWN
		var at: Vector2 = view.window_point(divider.rect.get_center()) + axis * 20.0
		var before: Rect2 = view.pane_rects[a]
		await touch(0, true, at)
		await finger(0, at + axis * 14.0)
		await wait(.12)
		expect(not view.tile_resize.is_empty(), "Wide touch zone captures a tiled divider")
		await finger(0, at + axis * 60.0)
		await touch(0, false, at + axis * 60.0)
		await until(func(): return not view.pane_rects[a].is_equal_approx(before), "Touch divider drag resizes the tiled panes")
		expect(current_tree().tiling and not Layout.find(current_tree(), a).get("graph_floating", false), "Touch divider resize never detaches a tile")

func resize_across_main_boundary(a: String, b: String) -> void:
	for tiled_neighbor in [false, true]:
		var area: Rect2 = view.content_rect()
		var before := Rect2(area.position + Vector2(-260, 100), Vector2(480, 300))
		var grip := before.position + Vector2(before.size.x - 2, before.size.y * .5)
		# A phone cannot show this whole pane: navigate to the edge being grabbed.
		await camera(grip, 1.0 if not tiled_neighbor else .8)
		view.set_window_rect(b, Rect2(area.get_center(), Vector2(480, 300)))
		view.set_window_rect(a, before)
		host.session_backend.move_pane(host, a, Vector2.INF)
		if tiled_neighbor: await toggle_tiling()
		host.focus_pane(a)
		await wait(.3)
		expect(Layout.find(current_tree(), a).get("stashed", false), "Pane straddling Main starts outside the managed layout")
		var neighbor: Rect2 = view.pane_rects[b]
		var tiles: Dictionary = current_tree().get("tiles", {}).duplicate(true)
		var navigation := frame()
		# Grab just inside the right edge: the expanded exterior may cover the
		# neighboring tile, whose content correctly wins an outside-only touch.
		var at: Vector2 = view.window_point(grip)
		await touch(0, true, at)
		await finger(0, at + Vector2(14, 0))
		await wait(.12)
		expect(view.panes[a]._resizing, "Boundary-straddling pane captures a finger resize")
		await finger(0, at + Vector2(64, 0))
		var held: Rect2 = view.pane_rects[a]
		expect(held.position.is_equal_approx(before.position) and held.size.x > before.size.x + 40 and is_equal_approx(held.size.y, before.size.y), "Only the grabbed edge changes while outside Main")
		expect(area.has_point(held.get_center()), "Regression crosses the center-based drop-classification boundary")
		await touch(0, false, at + Vector2(64, 0))
		await until(func():
			var shared: Dictionary = transport.topology.get("workspace_state", {}).get("layout", {}).get("tabs", {}).get(str(host.workspace_layout.active), {})
			for item in shared.get("windows", []):
				if item.key != a: continue
				var r: Array = item.rect
				return item.stashed and Rect2(r[0], r[1], r[2], r[3]).is_equal_approx(held)
			return false,
			"Owner commits the resized rectangle without reclassifying the free pane")
		expect(view.pane_rects[a].is_equal_approx(held) and Layout.find(current_tree(), a).get("stashed", false), "Resize release never snaps the free pane back into Main")
		expect(view.pane_rects[b].is_equal_approx(neighbor) and current_tree().get("tiles", {}) == tiles, "Boundary resize preserves neighbors and saved tiling proportions")
		expect(same_frame(navigation, frame()), "Boundary resize preserves camera pan and zoom")
	if current_tree().get("tiling", false): await toggle_tiling()

func reopen_keybar_after_tab_change() -> void:
	if not OS.has_feature("android"): return
	await until(func(): return not manager.keybar.visible and not manager.terminal_ime.opened, "Changing terminals closes the previous IME")
	await tap(manager.floating.get_node("KeyboardButton"))
	await until(func(): return manager.keybar.visible and manager.terminal_ime.opened, "Accessory keys reopen for the selected terminal")

func prefix_shortcuts() -> void:
	# The desktop driver is deliberately unfocusable. macOS application
	# activation notifications can still arrive between synthetic key presses.
	# Isolate the scripted sequence, then restore and exercise the real signal.
	var focus_lost: Callable = host.prefix_commands.focus_lost
	expect(root.focus_exited.is_connected(focus_lost), "Window focus loss is wired to prefix cancellation")
	if not OS.has_feature("android"): root.focus_exited.disconnect(focus_lost)
	expect(host.prefix_commands.settings.key == (KEY_A | KEY_MASK_CTRL), "Android defaults to Ctrl+A")
	await key(KEY_A, true)
	expect(host.prefix_commands.active, "Default Ctrl+A arms prefix on an external keyboard")
	await key(KEY_ESCAPE)
	var previous_bottom: float = host.layout_root.offset_bottom
	if OS.has_feature("android"):
		await tap(manager.floating.get_node("KeyboardButton"))
		await until(func(): return manager.keybar.visible, "Android accessory keys appear above the IME")
	else:
		# Reserve the same accessory area in the desktop touch-controls wrapper.
		host.layout_root.offset_bottom = -manager.keybar.HEIGHT
		manager.keybar.show()
	manager.keybar.update_host()
	await tap(manager.keybar.buttons.ctrl)
	expect(manager.keybar.modifiers.get("ctrl", false), "Touch arms Ctrl for the next IME character")
	await key(KEY_UNKNOWN, false, false, 97)
	expect(host.prefix_commands.active, "On-screen Ctrl and IME A arm the default prefix")
	expect(not manager.keybar.buttons.ctrl.button_pressed, "Prefix trigger consumes the on-screen Ctrl modifier")
	var soft_before: int = host.workspace_layout.tabs.size()
	await key(KEY_UNKNOWN, false, false, 99)
	await until(func(): return host.workspace_layout.tabs.size() == soft_before + 1, "Unmodified IME C creates a remote tab after Ctrl+A")
	expect(not host.prefix_commands.active, "IME command disarms the prefix")
	await reopen_keybar_after_tab_change()
	var original_tab: int = host.workspace_layout.active
	var tab_ids: Array = host.workspace_layout.tabs.map(func(tab): return int(tab.id))
	var next_tab: int = tab_ids[(tab_ids.find(original_tab) + 1) % tab_ids.size()]
	await tap(manager.keybar.buttons.ctrl)
	await key(KEY_UNKNOWN, false, false, 97)
	await key(KEY_UNKNOWN, false, false, 110)
	await until(func(): return host.workspace_layout.active == next_tab, "IME prefix N selects the next tab")
	await reopen_keybar_after_tab_change()
	await tap(manager.keybar.buttons.ctrl)
	await key(KEY_UNKNOWN, false, false, 97)
	await key(KEY_UNKNOWN, false, false, 112)
	await until(func(): return host.workspace_layout.active == original_tab, "IME prefix P returns to the previous tab")
	if OS.has_feature("android"):
		manager.keyboard_insets._hide_keyboard()
		await until(func(): return not manager.keybar.visible, "IME closes after the prefix sequence")
	else:
		manager.keybar.hide()
		host.layout_root.offset_bottom = previous_bottom
	# External keyboards use the same configurable prefix on Android and Mac.
	host.prefix_commands.settings.key = KEY_B | KEY_MASK_CTRL
	host.prefix_commands.settings.bindings[KEY_X] = "NewTab"
	var before: int = host.workspace_layout.tabs.size()
	await key(KEY_B,true)
	expect(host.prefix_commands.active,"Ctrl+B arms configured workspace prefix")
	await key(KEY_X)
	await until(func(): return host.workspace_layout.tabs.size()==before+1,"Prefix creates remote tab")
	expect(not host.prefix_commands.active,"Command disarms prefix")
	await key(KEY_B,true)
	await key(KEY_9, false, false, 57)
	expect(host.command_line_open() and host.command_line.line.text == "9", "A digit opens the command line before Backspace")
	await key(KEY_BACKSPACE)
	expect(host.command_line_open() and host.command_line.line.text.is_empty(),"Backspace edits the number")
	await key(KEY_ESCAPE)
	expect(not host.prefix_commands.active and not host.command_line_open(),"Escape cancels")
	var focused: String = host.pane_focus
	await key(KEY_B,true)
	await key(KEY_9, false, false, 57)
	await key(KEY_9, false, false, 57)
	expect(host.command_line_open() and host.command_line.line.text == "99", "Invalid tab digits stay in the line, not the terminal")
	await key(KEY_ENTER)
	expect(host.pane_focus==focused,"Invalid tab number preserves focus")
	await key(KEY_ESCAPE)
	expect(not host.command_line_open(),"Escape closes the line")
	await key(KEY_B,true)
	expect(host.prefix_commands.active, "Prefix is armed before testing focus loss")
	if not OS.has_feature("android"): root.focus_exited.connect(focus_lost)
	root.focus_exited.emit()
	expect(not host.prefix_commands.active,"Focus loss cancels prefix")
	terminal().send_text("printf 'PREFIX_%s\\n' CLEAN\r")
	if not await until(func(): return "PREFIX_CLEAN" in text_in(),"Consumed prefix keys do not corrupt shell command"): print("PREFIX_DEBUG ", text_in())

func messages_copy() -> void:
	var previous_clipboard := DisplayServer.clipboard_get()
	var diagnostics = preload("res://graffitty/diagnostics.gd")
	diagnostic_guard.allow("Clipboard 한글 test","example.gd",12)
	diagnostics.history.assign([{"message":"Clipboard 한글 test","file":"example.gd","line":12,"warning":false}])
	diagnostics.revision += 1
	host.show_messages()
	await wait()
	var panel: Node = host.diagnostic_panel
	# IME resize may leave focus on the fixed footer, outside the scroll view.
	manager.dialog.show()
	manager.dialog.primary.grab_focus()
	manager.dialog.reveal_focus()
	manager.dialog.hide()
	if OS.has_feature("android"):
		DisplayServer.clipboard_set("BEFORE_NATIVE_COPY")
		var bridge: Object = Engine.get_singleton("JavaClassWrapper")
		var activity: Variant = Engine.get_singleton("AndroidRuntime").getActivity()
		var strings: Variant = bridge.wrap("android.R$string")
		published["native_selection"] = {"select_all": str(activity.getString(strings.selectAll)),
			"copy": str(activity.getString(strings.copy))}
		expect(true, "Native message selection ready")
		await until(func(): return DisplayServer.clipboard_get() == panel.messages.text, "Android contextual Copy preserves complete Unicode message", 60.0)
		await tap(panel.log_button)
		await until(func(): return is_instance_valid(panel.log_viewer) and panel.log_viewer.visible and is_instance_valid(panel.log_text.native_text), "Log viewer text is native selectable", 10.0)
		await until(func(): return FileAccess.file_exists("user://native-log-captured"), "Log viewer evidence captured", 60.0)
		await tap(panel.log_viewer.get_ok_button())
		expect(not is_instance_valid(panel.log_viewer) or not panel.log_viewer.visible, "Log viewer closes")
	else:
		await tap(panel.messages)
		DisplayServer.clipboard_set("BEFORE")
		await key(KEY_C,not OS.has_feature("macos"),false,0,OS.has_feature("macos"))
		expect(DisplayServer.clipboard_get()==panel.messages.text,"Click then Ctrl+C copies complete Unicode diagnostic")

	await tap(panel.dismiss_button)
	DisplayServer.clipboard_set("DISMISSED")
	await key(KEY_C,not OS.has_feature("macos"),false,0,OS.has_feature("macos"))
	expect(DisplayServer.clipboard_get()=="DISMISSED","Dismissed messages do not intercept terminal copy shortcut")
	DisplayServer.clipboard_set(previous_clipboard)

func selection_copy() -> void:
	terminal().send_text("printf '\\033[2J\\033[5;5HSELECT_한글_😀_ONE\\033[6;5HSELECT_TWO\\n'\r")
	if not await until(func(): return "SELECT_TWO" in text_in(),"Unicode selection fixture reaches remote terminal"): return
	var term: Control = terminal()
	var cell: Vector2 = term.get_cell_size()
	var start: Vector2 = view.terminal_origin(host.pane_focus) + Vector2(4,4) + cell * Vector2(4.1,4.5)
	await camera(start,1.0)
	var at: Vector2 = mobile.get_global_rect().get_center()
	await double_start(at)
	await finger(0,at+cell*Vector2(12,1))
	await touch(0,false,at+cell*Vector2(12,1))
	expect(terminal().perform_action("copy"),"Native copy action accepts selection")
	await until(func(): return "SELECT_한글_😀_ONE" in DisplayServer.clipboard_get() and "SELECT_TWO" in DisplayServer.clipboard_get(),"Clipboard retains multiline Korean and emoji selection",3.0)
	expect(terminal().remote_mode,"Selection operates locally on streamed VT without new PTY")

func bracketed_paste() -> void:
	var pixels := PackedByteArray()
	pixels.resize(384 * 256 * 4)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7193
	for i in pixels.size(): pixels[i] = rng.randi() & 255
	var png := Image.create_from_data(384, 256, false, Image.FORMAT_RGBA8, pixels).save_png_to_buffer()
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(png)
	var sha := digest.finish().hex_encode()
	expect(png.size() > 131072, "Image fixture requires multiple upload chunks")
	run_python("""import os,tty,termios,shlex,pathlib,hashlib
old=termios.tcgetattr(0)
try:
 tty.setraw(0)
 os.write(1,b'\\x1b[?2004hPASTE_READY\\r\\n')
 data=b''
 image_done=False
 while True:
  packet=os.read(0,4096)
  if b'\\x03' in packet: break
  data+=packet
  if not image_done and b'\\x1b[201~' in data:
   expected='first 한글\\nsecond 😀'.encode()
   body=data.split(b'\\x1b[200~',1)[-1].split(b'\\x1b[201~',1)[0]
   if body==expected and data==b'\\x1b[200~'+body+b'\\x1b[201~':
    os.write(1,b'PASTE_MATCH\\r\\n')
   else:
    try:
     paths=shlex.split(body.decode())
     ok=len(paths)==1 and hashlib.sha256(pathlib.Path(paths[0]).read_bytes()).hexdigest()=='__SHA__'
     ok=ok and data.startswith(b'\\x1b[200~'+body+b'\\x1b[201~')
     os.write(1,b'FILE_MATCH\\r\\n' if ok else b'PASTE_WRONG\\r\\n')
     image_done=ok
    except Exception: os.write(1,b'PASTE_WRONG\\r\\n')
   data=data.split(b'\\x1b[201~',1)[1]
  if image_done and len(data)>=11:
   os.write(1,b'INPUT_ORDER_MATCH\\r\\n' if data==b'AFTER_IMAGE' else b'PASTE_WRONG\\r\\n')
   data=b''
finally:
 os.write(1,b'\\x1b[?2004l')
 termios.tcsetattr(0,termios.TCSANOW,old)
""".replace("__SHA__", sha))
	if not await until(func(): return "PASTE_READY" in text_in(),"Real server PTY enables bracketed paste"): return
	terminal().paste_text("first 한글\nsecond 😀")
	await until(func(): return "PASTE_MATCH" in text_in(),"Paste delivers exact Unicode/newlines inside bracket markers")
	terminal().paste_image_base64(Marshalls.raw_to_base64(png))
	terminal().send_text("AFTER_IMAGE")
	await until(func(): return "FILE_MATCH" in text_in(), "Image bytes reach the owner; one quoted path reaches the PTY without Enter", 30.0)
	await until(func(): return "INPUT_ORDER_MATCH" in text_in(), "Typing during upload follows the completed image")
	expect(not "PASTE_WRONG" in text_in(),"Paste does not duplicate or execute intermediate lines")
	terminal().send_text("\u0003")

func mouse_reporting() -> void:
	run_python("""import os,tty,termios,re
old=termios.tcgetattr(0)
try:
 tty.setraw(0)
 os.write(1,b'\\x1b[?1003h\\x1b[?1006h\\x1b[2J\\x1b[HMOUSE_READY\\r\\n')
 data=b''
 while True:
  packet=os.read(0,4096)
  if b'\\x03' in packet: break
  data+=packet
  matches=list(re.finditer(rb'\\x1b\\[<(\\d+);\\d+;\\d+([mM])',data))
  for m in matches: os.write(1,b'\\r\\nMOUSE_'+m[1]+b'_'+m[2]+b'\\r\\n')
  if matches: data=data[matches[-1].end():]
finally:
 os.write(1,b'\\x1b[?1003l\\x1b[?1006l')
 termios.tcsetattr(0,termios.TCSANOW,old)
""")
	if not await until(func(): return "MOUSE_READY" in text_in(),"Server application enables SGR mouse capture"): return
	await menu("View::Fit to Pane")
	await wait(.6)
	var at: Vector2 = mobile.get_global_rect().get_center()
	await touch(0,true,at)
	await finger(0,at+Vector2(30,0))
	await touch(0,false,at+Vector2(30,0))
	await wait(.2)
	expect(not "MOUSE_0_M" in text_in() and not "MOUSE_32_M" in text_in(), "Default finger drag sends no selection press or held-button motion")
	await wait(.4)
	await double_start(at)
	await touch(0,false,at)
	await until(func(): return "MOUSE_0_M" in text_in() and "MOUSE_0_m" in text_in(),"Double tap reaches real PTY as click and release")
	await wait(.4)
	await double_start(at)
	await finger(0,at+Vector2(35,0))
	await touch(0,false,at+Vector2(35,0))
	await until(func(): return "MOUSE_32_M" in text_in(),"Double-tap drag reaches PTY as held-button motion")
	await wait(.4)
	await touch(0,true,at)
	await wait(.6)
	await touch(0,false,at)
	await until(func(): return "MOUSE_2_M" in text_in(),"Long press reaches PTY as right click")
	# Real UI taps arm the strip; real pointer events traverse pane forwarding,
	# the remote protocol, terminal encoder, and the server PTY above.
	keyboard_inset(120.0)
	await wait(.3)
	expect(not manager.keybar.buttons.has("meta") and manager.keybar.size.y <= 40, "Compact Android strip omits Cmd")
	await tap(manager.keybar.buttons.ctrl)
	at = view.get_global_transform_with_canvas() * view.control_screen_rect(view.panes[host.pane_focus].texture).get_center()
	var hover := InputEventMouseMotion.new()
	hover.position = at
	hover.global_position = at
	root.push_input(hover, true)
	await wait(.1)
	var press := InputEventMouseButton.new()
	press.position = at
	press.global_position = at
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	mobile._dispatch_pointer(press, mobile.pointer_generation)
	await wait(.1)
	var motion := InputEventMouseMotion.new()
	motion.position = at + Vector2(24, 0)
	motion.global_position = motion.position
	motion.relative = Vector2(24, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	mobile._dispatch_pointer(motion, mobile.pointer_generation)
	await wait(.1)
	press.position = motion.position
	press.global_position = motion.position
	press.pressed = false
	press.button_mask = 0
	mobile._dispatch_pointer(press, mobile.pointer_generation)
	await until(func(): return "MOUSE_16_M" in text_in() and "MOUSE_48_M" in text_in() and "MOUSE_16_m" in text_in(), "One-shot Ctrl survives mouse down, drag and release at real PTY")
	expect(not manager.keybar.modifiers.get("ctrl", false) and manager.keybar.pointer_chords.is_empty(), "Mouse release consumes one-shot chord without stuck state")
	await tap(manager.keybar.buttons.alt)
	await tap(manager.keybar.buttons.alt)
	for click in 2:
		hover.position = press.position
		hover.global_position = press.position
		root.push_input(hover, true)
		await wait(.1)
		press.pressed = true
		press.button_mask = MOUSE_BUTTON_MASK_LEFT
		mobile._dispatch_pointer(press, mobile.pointer_generation)
		await wait(.1)
		press.pressed = false
		press.button_mask = 0
		mobile._dispatch_pointer(press, mobile.pointer_generation)
		await wait(.2)
	await until(func(): return text_in().count("MOUSE_8_M") >= 2 and text_in().count("MOUSE_8_m") >= 2, "Locked Alt applies to repeated complete clicks")
	await tap(manager.keybar.buttons.alt)
	expect(manager.keybar.modifiers.is_empty(), "Third modifier tap releases the lock")
	keyboard_inset(0.0)
	terminal().send_text("\u0003")

func scrollback_search() -> void:
	terminal().send_text("i=0; while [ $i -lt 180 ]; do printf 'SCROLL_%03d 한글\\n' $i; i=$((i+1)); done\r")
	if not await until(func(): return "SCROLL_179" in text_in(),"Long Unicode output advances screen"): return
	var matches: int = terminal().search_scrollback("SCROLL_015",1)
	expect(matches==1,"Native scrollback search finds off-screen row exactly once")
	terminal().perform_action("copy")
	await until(func(): return DisplayServer.clipboard_get()=="SCROLL_015","Search selection copies exact match",3.0)
	terminal().scroll_to_row(0)
	await wait()
	expect("SCROLL_000" in text_in(),"Scrolling to top reveals retained history")
	terminal().perform_action("scroll_bottom")
	await wait()
	expect("SCROLL_179" in text_in(),"Returning to bottom restores latest output")

func tab_titles() -> void:
	var a: String = host.pane_focus
	terminal(a).send_text("\"$GRAFFITTY_BIN\" tab rename 'Android 한글'\r")
	await until(func(): return "Android 한글" in str(host.workspace_layout.tabs),"Server CLI title updates Android tab")
	terminal(a).send_text("printf '\\033]2;PROGRAM_TITLE\\007'\r")
	await wait(.5)
	expect("Android 한글" in str(host.workspace_layout.tabs),"Manual title survives application OSC title")
	await new_tab()
	await select_tab(int(host.workspace_layout.tabs[0].id))
	expect("Android 한글" in str(host.workspace_layout.tabs),"Tab title survives switching")

func working_directory() -> void:
	var a: String = host.pane_focus
	terminal(a).send_text("cd /tmp; printf 'CWD_%s\\n' READY\r")
	if not await until(func(): return "CWD_READY" in text_in(a),"Parent shell changes working directory"): return
	var b := await split(a)
	if b.is_empty(): return
	terminal(b).send_text("printf 'INHERITED=%s\\n' \"$PWD\"\r")
	if not await until(func(): return "INHERITED=/tmp" in text_in(b).replace("\n", "") or "INHERITED=/private/tmp" in text_in(b).replace("\n", ""),"Remote split inherits originating shell cwd"):
		print("CWD_INHERIT_STATE ", terminal(b).get_text(true))
	terminal(b).send_text("cd /; printf 'OTHER_%s\\n' READY\r")
	await until(func(): return "OTHER_READY" in text_in(b),"Second pane changes cwd independently")
	var c := await split(a,"v")
	if c.is_empty(): return
	terminal(c).send_text("printf 'SOURCE=%s\\n' \"$PWD\"\r")
	await until(func(): return "SOURCE=/tmp" in text_in(c).replace("\n", "") or "SOURCE=/private/tmp" in text_in(c).replace("\n", ""),"Splitting an unfocused pane uses its cwd rather than focused pane cwd")
	host.focus_pane(a)
	var tab := await new_tab()
	if tab < 0: return
	await select_tab(tab)
	var d: String = host.pane_focus
	terminal(d).send_text("printf 'TAB_CWD=%s\\n' \"$PWD\"\r")
	await until(func(): return "TAB_CWD=/tmp" in text_in(d).replace("\n", "") or "TAB_CWD=/private/tmp" in text_in(d).replace("\n", ""), "New tabs inherit the active shell cwd on the owner")

## Resolve named ports at their live positions and use the tested Android
## drag arc. Even close neighbors must move beyond touch slop before HOLD_MS.
func connect_graph_ports(source: String, destination: String) -> bool:
	var overlay: Control = view.agent_links
	var graph: Node = host.agent_api.graph
	var ports = preload("res://scenes/GraphPorts.gd")
	if not await until(func(): return overlay.has_socket(source,true) and overlay.has_socket(destination,false), "Both named sockets are available"): return false
	var at: Vector2 = overlay.get_global_transform_with_canvas() * overlay.port_center(source, true)
	await touch(0,true,at)
	await wait(.13)
	if not expect(overlay.dragging == source, "Finger captures node output socket directly"):
		await touch(0,false,at)
		return false
	var target: Vector2 = overlay.get_global_transform_with_canvas() * overlay.port_center(destination, false)
	# Adjacent tiled sockets can be closer than the touch slop. Draw a visible
	# wire arc so a deliberately slow replay is a drag rather than a long press.
	await finger(0, at + Vector2(0, 30))
	for step in 6: await finger(0, at.lerp(target, float(step + 1) / 6.0) + Vector2(0, 30))
	await finger(0, target)
	await touch(0,false,target)
	return await until(func(): return graph.edges.values().any(func(edge): return ports.endpoint(edge,true)==source and ports.endpoint(edge,false)==destination), "Connected named ports: "+source+" → "+destination)

func graph_editing() -> void:
	var a: String = host.pane_focus
	var b := await split(a)
	if b.is_empty(): return
	for k in [a,b]:
		terminal(k).send_text("\"$GRAFFITTY_BIN\" rpc agent.event --params '{\"provider\":\"adapter\",\"event\":\"SessionStart\",\"pid\":123}' && \"$GRAFFITTY_BIN\" rpc agent.register --params '{\"name\":\"Android node\",\"inputs\":[{\"id\":\"in\"}],\"outputs\":[{\"id\":\"out\"}]}'\r")
	var graph: Node = host.agent_api.graph
	if not await until(func(): return graph.nodes.get(a,{}).get("manifest",{}).get("name")=="Android node" and graph.nodes.get(b,{}).get("manifest",{}).get("name")=="Android node","Both live node manifests arrive"): return
	var overlay: Control = view.agent_links
	var ports = preload("res://scenes/GraphPorts.gd")
	var source: String = ports.socket_id(a, "out")
	var destination: String = ports.socket_id(b, "in")
	view.show_overview()
	await wait(.5)
	var original_grid: Vector2i = terminal(a).get_grid_size()
	if not await connect_graph_ports(source,destination): return
	expect(terminal(a).get_grid_size() == original_grid, "Wire drag preserves terminal dimensions")
	await until(func(): return graph.edges.size()==1,"Wire arrives through live graph synchronization")
	var listed: Dictionary = await transport.remote_call(initial_id,"graph.list",{})
	expect(listed.has("result") and listed.result.edges.size()==1,"Server owns the same graph edge")
	var removed: Dictionary = await transport.remote_call(initial_id,"graph.disconnect",{"from":a,"to":b})
	expect(not removed.has("error"),"Graph disconnect is authorized")
	await until(func(): return graph.edges.is_empty(),"Disconnected wire disappears without reconnecting")
	expect(graph.nodes.has(a) and graph.nodes.has(b),"Disconnect preserves both registered nodes")

func view_per_tab() -> void:
	var a: int = host.workspace_layout.active
	await camera(Vector2(240,180),.4)
	var first := frame()
	var b := await new_tab()
	await select_tab(b)
	await camera(Vector2(480,300),.7)
	var second := frame()
	for repeat in 3:
		await select_tab(a)
		expect(same_frame(frame(),first),"First tab remembers its own pan and zoom")
		await select_tab(b)
		expect(same_frame(frame(),second),"Second tab remembers its distinct view")
	expect(host.sessions.size()==2,"View switching creates no duplicate terminals")

func chromium_eval(chromium: Node, expression: String) -> Variant:
	var reply: Dictionary = await chromium.request("cdp",{"method":"Runtime.evaluate","params":{"expression":expression,"returnByValue":true}})
	if reply.has("error"):
		print("CHROMIUM_EVALUATION_ERROR ", JSON.stringify(reply))
	expect(not reply.has("error"),"Chromium evaluation succeeds")
	return reply.get("result",{}).get("result",{}).get("value")

func chromium_hardware_backend() -> void:
	settings["require_hardware_video"] = true
	await chromium_backend()

func chromium_backend() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Client creates a browser on the server"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Browser is ready", 30.0): return
	var chromium: Node = host.chromiums[id]
	var pane: Control = view.panes["%%%d" % id]
	if not await until(func(): return pane.chrome != null and chromium.texture != null and chromium.selected_page_id >= 0, "Remote client receives browser chrome and pixels", 30.0): return
	var hardware_required := bool(settings.get("require_hardware_video", false))
	if hardware_required:
		var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
		if not expect(not codecs.is_empty(), "Physical client exposes hardware video decoders"): return
		if not await until(func(): return chromium.video_codec in codecs and chromium.frame_format == chromium.video_codec and chromium.video_decoder != null and chromium.frames > 0, "Browser stream uses the client's hardware decoder", 15.0): return
	expect(not chromium.can_open_native(), "Remote client cannot present a browser window on the server")
	expect(not pane.chrome.native_button.visible, "Remote client hides the native browser window button")
	print("CHROMIUM_BACKEND_TRANSPORT ", JSON.stringify({"video": chromium.video_codec, "format": chromium.frame_format, "gpu": chromium.gpu_active, "native_window_supported": chromium.native_window_supported}))
	var first: int = chromium.selected_page_id
	await chromium_eval(chromium, "document.title='First native page'; document.body.style.background='rgb(20,80,160)'; location.hash='native-first'; 1")
	if not await until(func(): return pane.chrome.address.text.ends_with("#native-first") and chromium.page_tabs.any(func(t): return str(t.title) == "First native page"), "Native title and URL reach Android", 3.0): return
	var has_color := func(expected: Color) -> bool:
		if chromium.texture == null: return false
		var pixels: Image = chromium.texture.get_image()
		if pixels == null: return false
		var color := pixels.get_pixel(2, 2)
		return color.a > .95 and absf(color.r - expected.r) < .08 and absf(color.g - expected.g) < .08 and absf(color.b - expected.b) < .08
	if not await until(func(): return has_color.call(Color8(20,80,160)), "Android displays the first page's actual pixels"): return
	if hardware_required:
		await chromium_hardware_motion(chromium, pane)
		if not failures.is_empty(): return
		if not await until(func(): return has_color.call(Color8(20,80,160)), "Hardware stream delivers the final static update"): return
	var reply: Dictionary = await chromium.request("tab-new", {"url": "about:blank"})
	expect(not reply.has("error"), "Server accepts a new tab")
	if not await until(func(): return chromium.page_tabs.size() == 2 and chromium.selected_page_id != first, "New tab appears and becomes selected"): return
	var second: int = chromium.selected_page_id
	await chromium_eval(chromium, "document.title='Second native page'; document.body.style.background='rgb(160,80,20)'; 1")
	if not await until(func(): return has_color.call(Color8(160,80,20)), "Android displays the second page's pixels"): return
	await chromium.request("tab-select", {"chromium_id": first})
	if not await until(func(): return chromium.selected_page_id == first and has_color.call(Color8(20,80,160)), "Selecting a tab restores its page and pixels"): return
	expect(await chromium_eval(chromium, "document.title") == "First native page", "Switching tabs preserves the first document")
	await chromium.request("tab-move", {"chromium_id": second, "index": 0})
	await until(func(): return int(chromium.page_tabs[0].id) == second, "Server tab order reaches Android", 3.0)
	var opened: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "window.open('about:blank', '_blank') != null", "returnByValue": true, "userGesture": true}})
	expect(opened.get("result", {}).get("result", {}).get("value", false) == true, "User gesture opens a popup")
	if not await until(func(): return chromium.page_tabs.size() == 3 and chromium.selected_page_id not in [first, second], "Popup becomes a managed tab"): return
	var popup: int = chromium.selected_page_id
	await chromium_eval(chromium, "document.title='Popup native page'; document.body.style.background='rgb(20,160,80)'; 1")
	if not await until(func(): return has_color.call(Color8(20,160,80)), "Android displays the popup's pixels"): return
	await chromium.request("tab-close", {"chromium_id": popup})
	await until(func(): return chromium.page_tabs.size() == 2, "Closing a popup preserves the other tabs")
	await chromium.request("tab-close", {"chromium_id": first})
	if not await until(func(): return chromium.page_tabs.size() == 1 and chromium.selected_page_id == second and has_color.call(Color8(160,80,20)), "Closing the original tab preserves the remaining page"): return
	await chromium.request("tab-new", {"url": "about:blank"})
	await until(func(): return chromium.page_tabs.size() == 2, "Tabs can still be created after the original tab closes")
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "Browser closes cleanly")
	expect(host.sessions.has(initial_id), "Closing the browser preserves the server terminal")

## Several moving browsers share one connection. Measure each stream and the
## client's own frame pacing; the workspace must stay responsive.
func chromium_multi_stream() -> void:
	var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
	if not expect(not codecs.is_empty(), "Physical client exposes hardware video decoders"): return
	var browsers: Array[Node] = []
	for index in int(settings.get("chromium_streams", 3)):
		var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
		if not expect(created.has("result"), "Client creates browser %d" % index): return
		var id := int(str(created.result.chromium).trim_prefix("%"))
		if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Browser %d is ready" % index, 30.0): return
		browsers.append(host.chromiums[id])
	# Readable floating panes stacked down the view: tiles on a phone are
	# slivers, which correctly pause instead of streaming.
	#
	# A phone's title and browser toolbar take about 114 of a pane's height; the
	# panes overlap.
	if current_tree().get("tiling", false): await toggle_tiling()
	var area: Rect2 = view.content_rect()
	for index in browsers.size():
		var key := "%%%d" % int(browsers[index].session_id)
		view.set_window_rect(key, Rect2(area.position + Vector2(4, 4 + index * 170), Vector2(320, 290)))
		host.session_backend.move_pane(host, key, Vector2.INF)
	await camera(area.get_center(), 1.0)
	await wait(1.0)
	if not browsers.all(func(c): return not c.stream_paused):
		for chromium in browsers:
			var pane: Control = view.panes["%%%d" % int(chromium.session_id)]
			var shown: Vector2 = preload("res://scenes/remote/RemoteClient.gd").chromium_display_size(view, pane.texture)
			print("CHROMIUM_PAUSE ", JSON.stringify({"paused": chromium.stream_paused, "size": str(shown), "density": host.get_window().content_scale_factor, "visible": pane.is_visible_in_tree(), "rect": str(view.pane_rects.get(pane.key)), "texture": str(pane.texture.size)}))
	expect(browsers.all(func(c): return not c.stream_paused), "Readable stacked browsers all stream")
	for chromium in browsers:
		if not await until(func(): return chromium.video_codec in codecs and chromium.video_decoder != null and chromium.frames > 0, "Every browser streams through a hardware decoder", 20.0): return
		# Full-page noise defeats inter-frame prediction, like video or fast
		# scrolling: the stream needs real bandwidth, not a flat colour change.
		await chromium_eval(chromium, "document.body.style.margin=0;const c=document.createElement('canvas');c.width=innerWidth;c.height=innerHeight;c.style.display='block';document.body.appendChild(c);const g=c.getContext('2d');const img=g.createImageData(c.width,c.height);const px=new Uint32Array(img.data.buffer);window.__videoTick=0;function videoTick(){++window.__videoTick;for(let i=0;i<px.length;i++)px[i]=0xff000000|(Math.random()*0xffffff);g.putImageData(img,0,0);requestAnimationFrame(videoTick)};videoTick();1")
	await wait(3.0)
	var decoders := browsers.map(func(c): return c.video_decoder)
	var before := browsers.map(func(c): return [c.frames, c.video_sequence, c.video_bytes, c.video_resets, c.video_decoder_drops])
	var link: RefCounted = browsers[0].connection.video_datagrams if "video_datagrams" in browsers[0].connection else null
	var link_before: Dictionary = link.stats() if link != null else {}
	var intervals: Array[float] = []
	var last := Time.get_ticks_usec()
	var started := last
	while Time.get_ticks_usec() - started < 15_000_000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		intervals.append((now - last) / 1000.0)
		last = now
	var elapsed := (last - started) / 1_000_000.0
	intervals.sort()
	var p95: float = intervals[int(intervals.size() * .95)]
	var streams := []
	for index in browsers.size():
		var chromium: Node = browsers[index]
		streams.append({"fps": (chromium.frames - before[index][0]) / elapsed,
			"received_fps": (chromium.video_sequence - before[index][1]) / elapsed,
			"kbps": (chromium.video_bytes - before[index][2]) * 8.0 / elapsed / 1000.0,
			"size": [chromium.texture.get_width(), chromium.texture.get_height()] if chromium.texture != null else [],
			"paused": chromium.stream_paused, "restarted": chromium.video_decoder != decoders[index],
			"state": {"epoch": chromium.video_epoch, "sequence": chromium.video_sequence, "submitted": chromium._video_submitted,
				"acknowledged": chromium._video_acknowledged, "consumed": chromium.video_decoder.consumed() if chromium.video_decoder != null else -1,
				"waiting_key": chromium.video_waiting_key, "format": chromium.frame_format, "status": chromium.status}})
	print(preload("res://graffitty/render_stats.gd").report(get_tree()))
	# One line per stream: Android truncates long log lines.
	for index in browsers.size():
		var chromium: Node = browsers[index]
		print("CHROMIUM_STREAM ", index, " ", JSON.stringify({"resets": chromium.video_resets - before[index][3], "decoder_drops": chromium.video_decoder_drops - before[index][4]}))
	if link != null:
		var link_after: Dictionary = link.stats()
		var delta := {}
		for key in link_after:
			delta[key] = link_after[key] - link_before.get(key, 0) if link_after[key] is int else link_after[key]
		print("CHROMIUM_DATAGRAMS ", JSON.stringify(delta))
	print("CHROMIUM_MULTI_STREAM ", JSON.stringify({"client_fps": intervals.size() / elapsed, "p95_ms": p95, "max_ms": intervals[-1], "streams": streams}))
	expect(streams.all(func(s): return not s.restarted), "Concurrent streams never restart a hardware decoder")
	# A stream may share the device's frame budget, but none may freeze. The
	# phone's own frame rate is a GPU limit measured by the single-stream case.
	var floor := minf(20.0, .6 * intervals.size() / elapsed)
	expect(streams.all(func(s): return not s.paused and s.fps >= floor), "No visible stream freezes: each presents at least %.1f frames per second" % floor)
	expect(intervals[-1] < 250.0, "Concurrent streams never stall the workspace")
	for chromium in browsers: host.close_chromium_session(int(chromium.session_id))
	expect(host.sessions.has(initial_id), "Closing the browsers preserves the server terminal")

func chromium_hardware_motion(chromium: Node, pane: Control) -> void:
	var codec: String = chromium.video_codec
	# Drive the compositor at display cadence, then measure only the steady
	# stream. A few frames over several seconds does not establish usable video.
	await chromium_eval(chromium, "window.__videoTick=0;window.__videoRunning=true;function videoTick(){if(!window.__videoRunning)return;document.body.style.background='hsl('+((++window.__videoTick*7)%360)+' 80% 50%)';requestAnimationFrame(videoTick)};videoTick();1")
	await wait(2.0)
	if view.host.world.has_method("set_video_layers"):
		# Page frames then redraw the world without the workspace canvas.
		expect(pane.video_layer and chromium.present_at_draw, "The world composites the page beneath the workspace canvas")
	var steady_decoder: RefCounted = chromium.video_decoder
	var render_stats := preload("res://graffitty/render_stats.gd")
	print(render_stats.report(get_tree()))
	preload("res://graffitty/frame_profile.gd").take()
	var source_before: Variant = await chromium_eval(chromium, "[window.__videoTick,performance.now()]")
	var before: int = chromium.frames
	var received: int = chromium.video_sequence
	var process_before := Engine.get_process_frames()
	var started := Time.get_ticks_msec()
	await wait(10.0)
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	var delivered: int = chromium.frames - before
	var receive_count: int = chromium.video_sequence - received
	var process_count := Engine.get_process_frames() - process_before
	var source_after: Variant = await chromium_eval(chromium, "[window.__videoTick,performance.now()]")
	var source_fps := float(source_after[0] - source_before[0]) * 1000.0 / float(source_after[1] - source_before[1])
	var fps := delivered / elapsed
	print(render_stats.report(get_tree()))
	print(preload("res://graffitty/frame_profile.gd").take())
	print("CHROMIUM_HARDWARE_MOTION ", JSON.stringify({"codec": codec, "frames": delivered, "received": receive_count, "elapsed_ms": roundi(elapsed * 1000), "fps": fps, "source_fps": source_fps, "client_fps": process_count / elapsed, "size": [chromium.texture.get_width(), chromium.texture.get_height()]}))
	expect(source_fps >= 55.0, "Browser animation sustains display cadence")
	expect(fps >= 30.0, "Remote hardware video sustains at least 30 presented frames per second")
	expect(chromium.video_decoder == steady_decoder, "Steady video does not restart its hardware decoder")
	var original_camera := frame()
	var original_overview: bool = view.overview
	var full_height: int = chromium.texture.get_height()
	var page_size: Variant = await chromium_eval(chromium, "[innerWidth,innerHeight]")
	var shown: float = preload("res://scenes/remote/RemoteClient.gd").chromium_display_height(view, pane.texture)
	await camera(original_camera.center, original_camera.zoom * minf(.15, 200.0 / maxf(shown, 1.0)))
	# Hardware encoders have minimum widths as well as heights; tall pages
	# may need more than 240 rows to retain their aspect ratio at that width.
	await until(func(): return chromium.texture.get_height() < full_height / 2, "GPU video scales down for the overview", 8.0)
	expect(await chromium_eval(chromium, "[innerWidth,innerHeight]") == page_size, "Video scaling preserves the website viewport")
	await camera(original_camera.center, original_camera.zoom)
	view.overview = original_overview
	view._apply_navigation()
	await until(func(): return chromium.texture.get_height() >= full_height, "GPU video restores the full rendition", 8.0)
	expect(chromium.video_codec == codec and chromium.video_decoder != null, "Animation and scaling retain hardware video")
	await chromium_eval(chromium, "window.__videoRunning=false;document.body.style.background='rgb(20,80,160)';1")

func chromium_unicode_input(chromium: Node, label: String) -> bool:
	var viewport: Variant = await chromium_eval(chromium, "document.getElementById('field').value='';document.getElementById('field').blur();[innerWidth,innerHeight]")
	if not expect(viewport is Array and viewport.size() == 2, "Input fixture reports its CSS viewport"): return false
	for pressed in [true,false]:
		var click := InputEventMouseButton.new()
		# remote_input consumes video pixels, not DOM coordinates. Adaptive
		# renditions can put video pixel (30,30) below this 70px-high input.
		click.position = Vector2(30,30) * Vector2(chromium.texture.get_size()) / Vector2(viewport[0], viewport[1])
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		chromium.remote_input(click,Vector2(chromium.texture.get_size()))
	for ch in "한A":
		var input := InputEventKey.new()
		input.unicode = ch.unicode_at(0)
		input.pressed = true
		chromium.remote_input(input,Vector2(chromium.texture.get_size()))
	await wait(.5)
	var input_state: Variant = await chromium_eval(chromium,"({value:document.getElementById('field').value,focus:document.activeElement.id,viewport:[innerWidth,innerHeight],field:document.getElementById('field').getBoundingClientRect().toJSON()})")
	if input_state is Dictionary:
		input_state["pointer"] = str(chromium.last_pointer)
		input_state["video_size"] = str(chromium.texture.get_size())
	print("CHROMIUM_UNICODE_INPUT ", JSON.stringify(input_state))
	return expect(input_state is Dictionary and input_state.get("value") == "한A", label)

func chromium_clipboard_set(text: String) -> void:
	DisplayServer.clipboard_set(text)
	await until(func(): return DisplayServer.clipboard_get() == text, "Client OS clipboard write becomes visible")

## A server on this computer copies and pastes through Chromium itself, which
## reaches selections a getSelection() bridge cannot, such as inside iframes.
func chromium_native_clipboard(chromium: Node) -> void:
	var mac := OS.get_name() == "macOS"
	await chromium_eval(chromium, "document.body.innerHTML='<textarea id=sink></textarea><iframe id=frame srcdoc=\"<p id=t>FRAME_COPY_한글_😀</p>\"></iframe>';true")
	var loaded := false
	for _i in range(100):
		loaded = await chromium_eval(chromium, "!!document.getElementById('frame').contentDocument?.getElementById('t')") == true
		if loaded: break
		await wait(.05)
	if not expect(loaded, "Native clipboard iframe fixture loads"): return
	await chromium_eval(chromium, "const w=document.getElementById('frame').contentWindow;w.focus();const r=w.document.createRange();r.selectNodeContents(w.document.getElementById('t'));w.getSelection().removeAllRanges();w.getSelection().addRange(r);true")
	await chromium_clipboard_set("BEFORE_NATIVE_COPY")
	await key(KEY_C, not mac, false, 0, mac)
	await until(func(): return DisplayServer.clipboard_get() == "FRAME_COPY_한글_😀", "Native copy of an iframe selection reaches the OS clipboard")
	await chromium_eval(chromium, "document.getElementById('sink').focus();true")
	await chromium_clipboard_set("NATIVE_PASTE_한글_😀")
	await key(KEY_V, not mac, false, 0, mac)
	var pasted := false
	for _i in range(100):
		pasted = await chromium_eval(chromium, "document.getElementById('sink').value") == "NATIVE_PASTE_한글_😀"
		if pasted: break
		await wait(.05)
	expect(pasted, "Native paste reads the OS clipboard into the page")

## Find in page through the real UI: Cmd/Ctrl+F opens the box in the page's
## top-right corner, Chromium counts and steps, Escape returns to the page.
func chromium_find() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Client creates a find browser"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready and host.chromiums[id].texture != null, "Find browser reaches client", 30.0): return
	var chromium: Node = host.chromiums[id]
	var pane: Control = view.panes["%%%d" % id]
	host.focus_pane("%%%d" % id)
	await chromium_eval(chromium, "document.body.innerHTML='<p style=\"font:24px sans-serif\">needle one, Needle two, needle three</p>';true")
	pane.texture.focus_mode = Control.FOCUS_ALL
	pane.texture.grab_focus()
	var mac := OS.get_name() == "macOS"
	await key(KEY_F, not mac, false, 0, mac)
	var bar: Control = pane.find_bar
	if not expect(bar != null and bar.visible and bar.field.has_focus(), "Cmd/Ctrl+F opens the find box with the keyboard"): return
	var page: Rect2 = pane.texture.get_global_rect()
	var box: Rect2 = bar.get_global_rect()
	expect(page.encloses(box) and box.position.y - page.position.y < 24 and page.end.x - box.end.x < 40,
		"The find box sits in the page's top-right corner: page %s box %s" % [page, box])
	for character in "needle":
		await key(OS.find_keycode_from_string(character.to_upper()), false, false, character.unicode_at(0))
	expect(bar.field.text == "needle", "Typing goes to the find box, not the page")
	if not await until(func(): return bar.result.text == "1/3", "Chromium's first match and count are shown: %s" % bar.result.text): return
	await wait(.5)
	if not output.is_empty(): root.get_texture().get_image().save_png(output.get_base_dir().path_join("find.png"))
	await key(KEY_ENTER)
	await until(func(): return bar.result.text == "2/3", "Enter goes to the next match")
	await key(KEY_G, not mac, true, 0, mac)
	await until(func(): return bar.result.text == "1/3", "Shift+Cmd/Ctrl+G goes to the previous match")
	await key(KEY_ESCAPE)
	expect(not bar.visible and pane.texture.has_focus(), "Escape closes the box and returns the keyboard to the page")
	await wait(.3)
	expect(JSON.stringify(await chromium_eval(chromium, "(()=>{const s=getSelection();return s.rangeCount?[String(s),s.getRangeAt(0).startOffset]:null})()")) == '["needle",0]',
		"The first match, shown as 1/3, stays selected")
	chromium.close()

func chromium_clipboard() -> void:
	var result: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(result.has("result"), "Client creates clipboard browser"): return
	var id := int(str(result.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready and host.chromiums[id].texture != null, "Clipboard browser reaches client"): return
	var chromium: Node = host.chromiums[id]
	host.focus_pane("%%%d" % id)
	await chromium_eval(chromium, "document.body.innerHTML='<input id=field style=\"width:300px;height:70px\">';true")
	if not await chromium_unicode_input(chromium, "Clipboard fixture receives frontend input"): return
	var surface: Control = view.panes["%%%d" % id].texture
	surface.focus_mode = Control.FOCUS_ALL
	surface.grab_focus()
	expect(surface.has_focus(), "Browser surface owns frontend keyboard focus")
	var original := DisplayServer.clipboard_get()
	if chromium.native_clipboard():
		await chromium_native_clipboard(chromium)
	# The rest covers the viewer bridge used by servers on other computers.
	chromium.clipboard_bridge = true
	await chromium_clipboard_set("CLIENT_PASTE_한글_😀")
	# Ctrl+A is the workspace prefix; select the fixture without arming it.
	await chromium_eval(chromium, "document.getElementById('field').select();true")
	await key(KEY_V, true)
	await wait(1.0)
	var pasted_text: Variant = await chromium_eval(chromium, "document.getElementById('field').value")
	print("CHROMIUM_CLIPBOARD_PASTE ", JSON.stringify({"value": pasted_text, "status": chromium.status, "clipboard": DisplayServer.clipboard_get()}))
	var pasted: bool = pasted_text == "CLIENT_PASTE_한글_😀"
	await chromium_eval(chromium, "document.getElementById('field').value='BROWSER_COPY_한글_😀';document.getElementById('field').select();true")
	await key(KEY_C, true)
	await wait(1.0)
	var copied := DisplayServer.clipboard_get() == "BROWSER_COPY_한글_😀"
	await chromium_eval(chromium, "document.getElementById('field').value='CUT_한글_😀';document.getElementById('field').select();window.clipEvents=0;document.getElementById('field').addEventListener('input',()=>clipEvents++);true")
	await key(KEY_X, true)
	await wait(1.0)
	var cut: bool = DisplayServer.clipboard_get() == "CUT_한글_😀" and await chromium_eval(chromium, "document.getElementById('field').value === '' && clipEvents > 0")
	await chromium_eval(chromium, "document.getElementById('field').type='password';document.getElementById('field').value='PASSWORD_MUST_NOT_COPY';document.getElementById('field').select();true")
	await key(KEY_C, true)
	await wait(.5)
	var password_protected := DisplayServer.clipboard_get() == "CUT_한글_😀"
	await chromium_eval(chromium, "document.body.innerHTML='<textarea id=multi></textarea><div id=editable contenteditable=true></div><input id=readonly readonly value=READ_ONLY>';document.getElementById('multi').focus();true")
	var multiline := "FIRST_한글_😀\nSECOND_é_終"
	await chromium_clipboard_set(multiline)
	await key(KEY_V, true)
	await until(func(): return not chromium._clipboard_busy, "Multiline paste completes")
	var multiline_value: Variant = await chromium_eval(chromium, "[document.getElementById('multi').value,document.activeElement.id]")
	print("CLIPBOARD_MULTILINE ", JSON.stringify({"actual": multiline_value, "expected": multiline, "clipboard": DisplayServer.clipboard_get()}))
	expect(multiline_value[0] == multiline, "Textarea paste preserves newlines and Unicode")
	await chromium_eval(chromium, "document.getElementById('multi').select();true")
	await chromium_clipboard_set("BEFORE_MULTILINE_COPY")
	await key(KEY_C, true)
	await until(func(): return not chromium._clipboard_busy, "Multiline copy completes")
	await until(func(): return DisplayServer.clipboard_get() == multiline, "Multiline copy reaches OS clipboard")
	expect(DisplayServer.clipboard_get() == multiline, "Textarea copy preserves newlines and Unicode")
	await chromium_eval(chromium, "document.getElementById('multi').setSelectionRange(0,0);true")
	await chromium_clipboard_set("EMPTY_SELECTION_GUARD")
	await key(KEY_C, true)
	await until(func(): return not chromium._clipboard_busy, "Empty selection copy completes")
	expect(DisplayServer.clipboard_get() == "EMPTY_SELECTION_GUARD", "Empty selection leaves client clipboard unchanged")
	await chromium_eval(chromium, "document.getElementById('editable').focus();true")
	await chromium_clipboard_set("EDITABLE_한글_😀")
	await key(KEY_V, true)
	await until(func(): return not chromium._clipboard_busy, "Contenteditable paste completes")
	expect(await chromium_eval(chromium, "document.getElementById('editable').textContent") == "EDITABLE_한글_😀", "Contenteditable receives client text after focus switch")
	await chromium_eval(chromium, "let r=document.createRange();r.selectNodeContents(document.getElementById('editable'));getSelection().removeAllRanges();getSelection().addRange(r);true")
	await chromium_clipboard_set("BEFORE_EDITABLE_CUT")
	await key(KEY_X, true)
	await until(func(): return not chromium._clipboard_busy, "Contenteditable cut completes")
	await until(func(): return DisplayServer.clipboard_get() == "EDITABLE_한글_😀", "Contenteditable cut reaches OS clipboard")
	expect(DisplayServer.clipboard_get() == "EDITABLE_한글_😀" and await chromium_eval(chromium, "document.getElementById('editable').textContent === ''"), "Contenteditable cut transfers and removes selected text")
	await chromium_eval(chromium, "document.getElementById('readonly').focus();document.getElementById('readonly').select();true")
	await key(KEY_X, true)
	await until(func(): return not chromium._clipboard_busy, "Read-only cut completes")
	await until(func(): return DisplayServer.clipboard_get() == "READ_ONLY", "Read-only copy reaches OS clipboard")
	expect(DisplayServer.clipboard_get() == "READ_ONLY" and await chromium_eval(chromium, "document.getElementById('readonly').value === 'READ_ONLY'"), "Read-only cut copies without deleting text")
	await chromium_clipboard_set("MUST_NOT_INSERT")
	await key(KEY_V, true)
	await until(func(): return not chromium._clipboard_busy, "Read-only paste completes")
	expect(await chromium_eval(chromium, "document.getElementById('readonly').value === 'READ_ONLY'"), "Read-only field rejects paste")
	await chromium_eval(chromium, "document.getElementById('multi').value='';document.getElementById('multi').focus();true")
	await chromium_clipboard_set("R")
	for _i in range(6): await key(KEY_V, true)
	await until(func(): return not chromium._clipboard_busy, "Rapid paste queue drains")
	expect(await chromium_eval(chromium, "document.getElementById('multi').value === 'RRRRRR'"), "Rapid paste preserves all six operations")
	await chromium_eval(chromium, "document.getElementById('multi').value='SIZE_GUARD';document.getElementById('multi').select();true")
	await chromium_clipboard_set("x".repeat(70000))
	await key(KEY_V, true)
	await until(func(): return not chromium._clipboard_busy, "Oversized paste completes")
	await chromium_eval(chromium, "document.title='Clipboard limit guard';true")
	await until(func(): return chromium.title == "Clipboard limit guard", "Browser state updates after rejected paste")
	await wait(.3)
	var oversized_value: Variant = await chromium_eval(chromium, "document.getElementById('multi').value")
	print("CLIPBOARD_OVERSIZED ", JSON.stringify({"value": oversized_value, "status": chromium.status, "clipboard_bytes": DisplayServer.clipboard_get().to_utf8_buffer().size()}))
	expect("exceeds" in chromium.status and oversized_value == "SIZE_GUARD", "Oversized paste is rejected without modifying the field")
	await chromium_eval(chromium, "document.getElementById('multi').value='x'.repeat(70000);document.getElementById('multi').select();true")
	await chromium_clipboard_set("COPY_SIZE_GUARD")
	await key(KEY_C, true)
	await until(func(): return not chromium._clipboard_busy, "Oversized copy completes")
	expect(DisplayServer.clipboard_get() == "COPY_SIZE_GUARD", "Oversized copy leaves client clipboard unchanged")
	await wait(.3)
	expect(not "exceeds" in chromium.status, "Next clipboard shortcut clears the previous input error")
	await chromium_clipboard_set(original)
	expect(pasted, "Frontend clipboard pastes into remote Chromium")
	expect(copied, "Remote Chromium selection reaches frontend clipboard")
	expect(cut, "Cut transfers text and dispatches browser input")
	expect(password_protected, "Browser passwords do not enter frontend clipboard")
	chromium.close()

func chromium_navigation() -> void:
	var result: Dictionary = await host.session_backend.create_chromium_remote(host,initial_id,"about:blank",true,null)
	if not expect(result.has("result"),"Client creates chromium on authoritative server"): return
	# Federation remaps the canonical chromium target into this client's ID
	# namespace. The result's numeric id still belongs to the server.
	var id := int(str(result.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready,"Chromium reaches ready state"): return
	var chromium: Node = host.chromiums[id]
	await until(func(): return chromium.texture!=null and chromium.selected_page_id>=0,"Chromium frames and native chrome reach client")
	# A small overview pane deliberately uses PNG while video is paused. Fit
	# the browser before requiring hardware streaming on phone/tablet geometry.
	var stream_target: Dictionary = view._inspection_target("%%%d" % id)
	await camera(stream_target.center, stream_target.zoom)
	var video_codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
	print("Chromium hardware codecs: ", video_codecs, "; selected: ", chromium.video_codec)
	if chromium.gpu_active:
		expect(chromium.gpu_frames > 0 and chromium.texture != null, "Local chromium imports live shared GPU frames")
	elif not video_codecs.is_empty():
		# A compatibility preview can arrive before the first negotiated
		# hardware keyframe. Observe the completed negotiation, not that race.
		await until(func(): return chromium.video_codec in video_codecs and chromium.frames > 0 and chromium.video_decoder != null,
			"Chromium uses a negotiated hardware video decoder")
	else:
		expect(chromium.texture != null, "Client without hardware codecs receives compatibility preview")

	await chromium_eval(chromium, "document.body.style.background='rgb(20,80,160)'; 1")
	await until(func():
		if chromium.texture == null: return false
		var pixels: Image = chromium.texture.get_image()
		if pixels == null: return false
		var color := pixels.get_pixel(2,2)
		return absf(color.r - 20.0/255) < .08 and absf(color.g - 80.0/255) < .08 and absf(color.b - 160.0/255) < .08,
		"Decoded chromium pixels preserve page colors")
	await chromium_eval(chromium, "location.hash='before-address'; 1")
	var pane: Control = view.panes["%%%d" % id]
	if not await until(func(): return pane.chrome != null, "Chromium chrome is attached to its workspace pane"): return
	if OS.has_feature("android"):
		expect(not chromium.can_open_native(), "Android cannot present a browser window on the server")
		expect(not pane.chrome.native_button.visible, "Android hides the native browser window button")
	var address: LineEdit = pane.chrome.address
	host.focus_pane(pane.key)
	await wait(.3)
	await camera(address.get_global_rect().get_center(), 1.0)
	await camera(address.get_global_rect().get_center(), 1.0)
	if view.window_at(view.canvas_point_at(view.size * .5)) != pane.key:
		print("CHROMIUM_OBSTRUCTED ", JSON.stringify({"at": str(view.canvas_point_at(view.size * .5)), "hit": view.window_at(view.canvas_point_at(view.size * .5)), "pane": pane.key, "rects": str(view.pane_rects), "dividers": str(view.dividers_at(view.canvas_point_at(view.size * .5), true)), "resize": str(view.resize_window_at(view.canvas_point_at(view.size * .5), true))}))
	expect(view.window_at(view.canvas_point_at(view.size * .5)) == pane.key, "Chromium chrome is unobstructed at cursor")
	expect(address.get_global_rect().has_point(view.canvas_point_at(view.size * .5)), "Cursor aims inside address field")
	var center: Vector2 = point(mobile)
	print("CHROMIUM_ADDRESS_TAP ", JSON.stringify({"touch": str(center), "view_rect": str(view.get_global_rect()), "mobile_rect": str(mobile.get_global_rect()), "address": str(address.get_global_rect()), "canvas": str(view.canvas_point_at(view.size * .5))}))
	# Queue both physical events before waiting for renderer frames. Awaiting
	# frames between them can turn this short tap into a long press on a busy
	# hardware-decoder startup frame.
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.index = 0
		event.pressed = pressed
		event.position = root.get_final_transform() * center
		Input.parse_input_event(event)
	await wait(.3)
	print("CHROMIUM_ADDRESS_FOCUS ", address.has_focus(), "; root=", root.gui_get_focus_owner(), "; canvas=", view.canvas.gui_get_focus_owner())
	expect(address.has_focus(), "Centered touch cursor focuses chromium address")
	await key(KEY_A, not OS.has_feature("macos"), false, 0, OS.has_feature("macos"))
	for ch in "about:blank":
		await key(ch.to_upper().unicode_at(0) as Key, false, false, ch.unicode_at(0))
	expect(address.text == "about:blank", "Focused address accepts keyboard editing: " + address.text)
	await key(KEY_ENTER)
	await wait(.5)
	expect(await chromium_eval(chromium, "location.hash") == "", "Address Enter navigates authoritative chromium")
	if OS.has_feature("android"): manager.keyboard_insets._hide_keyboard()
	address.release_focus()
	await chromium_eval(chromium,"document.body.innerHTML='<input id=field style=\"width:300px;height:70px\">'; location.hash='one'; document.title='Android Chromium'; 1")
	if not await chromium_unicode_input(chromium, "Remote chromium mouse focus and Unicode key input work"): return
	await chromium_eval(chromium,"location.hash='two'; 1")
	await chromium.request("tab-back",{"chromium_id":chromium.selected_page_id})
	await wait(.3)
	expect(await chromium_eval(chromium,"location.hash")=="#one","Chromium Back returns to previous location")
	await chromium.request("tab-forward",{"chromium_id":chromium.selected_page_id})
	await wait(.3)
	expect(await chromium_eval(chromium,"location.hash")=="#two","Chromium Forward restores next location")
	expect(chromium.frames>0 and chromium.texture.get_width()>0,"Server continues sending rendered chromium frames")
	if not chromium.gpu_active and chromium.video_decoder != null:
		var original_camera := frame()
		var original_overview: bool = view.overview
		var full_height: int = chromium.texture.get_height()
		var Remote := preload("res://scenes/remote/RemoteClient.gd")
		var shown: float = Remote.chromium_display_height(view, pane.texture)
		var return_to_full := true
		# A small page that still streams.
		var small := streaming_zoom(pane, Remote.PAUSE_HEIGHT + 16.0)
		if small.rendition >= full_height:
			print("CHROMIUM_RENDITION ", JSON.stringify({"skipped": "pane cannot shrink below its full rendition while readable", "full_height": full_height, "shown": shown, "factor": small.factor}))
			return_to_full = false
		else:
			await camera(original_camera.center, original_camera.zoom * small.factor)
			if not await until(func(): return chromium.texture.get_height() < full_height and chromium.texture.get_height() <= small.rendition, "Input fixture receives a small video rendition", 8.0): return
		if return_to_full:
			if not await chromium_unicode_input(chromium, "Small-rendition pointer focus and Unicode input work"): return
			await camera(original_camera.center, original_camera.zoom)
			view.overview = original_overview
			view._apply_navigation()
			if not await until(func(): return chromium.texture.get_height() >= full_height, "Input fixture restores its full rendition", 8.0): return
	var resource: Node = chromium.resource_monitor
	if await until(func(): return resource.status == "running" and resource.cpu_valid and resource.memory_current > 0,
			"Chromium supplies live CPU and memory measurements", 20.0):
		var sample: Dictionary = resource.snapshot()
		expect(int(sample.root_pid) == chromium.pid and int(sample.process_count) > 1,
			"Chromium monitor identifies the owner browser process tree")
		host.focus_pane(pane.key)
		host.pane_status_visible = true
		view._update_monitor()
		await wait()
		var readout: String = "\n".join(preload("res://scenes/PaneStatusDialog.gd").find(host).texts())
		var view_: Control = preload("res://scenes/PaneStatusDialog.gd").find(host).view
		# A folded sidebar shows the compact readout (pane, CPU, whole MiB) and
		# keeps the full sample, process line included, in its tooltip.
		var compact: bool = "compact" in view_.hit_keys()
		var processes: String = view_.get_tooltip(view_.hit_rect("pane" if compact else "metric-processes").get_center())
		var measured := RegEx.create_from_string("(?m)^\\d+M$").search(readout) != null and "MiB" in processes if compact else "MiB" in readout
		expect(("PID %d" % chromium.pid) in processes and measured,
			"Focused Chromium monitor displays measured owner values")
		host.pane_status_visible = false
		view._update_monitor()
	# Dragging a tab must leave it where it was dropped once the owner confirms
	# the move, not show the previous order until the strip's timeout.
	await chromium.request("tab-new", {"url": "about:blank"})
	if not await until(func(): return chromium.page_tabs.size() == 2, "A second Chromium tab opens", 15.0): return
	await chromium_eval(chromium, "document.title='Second'; 1")
	if not await until(func(): return chromium.page_tabs.any(func(t): return str(t.title) == "Second"), "The second tab is named", 10.0): return
	var strip: Control = pane.chrome.tabs
	# On a phone the docked side panels cover part of the workspace. Bring
	# the tab strip to the middle of what they leave free, so the drag starts
	# and ends on the tabs.
	var free: Rect2 = view.workspace_region().rect()
	await camera(strip.get_global_rect().get_center() - (free.get_center() - view.size * .5), 1.0)
	await wait(.5)
	var before: Array = chromium.page_tabs.map(func(t): return int(t.id))
	var expected: Array = [str(chromium.page_tabs[1].title), str(chromium.page_tabs[0].title)]
	var screen_of := func(control: Control) -> Vector2:
		return view.get_global_transform_with_canvas() * view.control_screen_rect(control).get_center()
	# A phone-width pane shows one tab at a time; the other scrolls out of the
	# strip, and a tab that is not on screen cannot be dragged past another.
	var on_screen: Rect2 = pane.get_global_rect()
	if not before.all(func(tab_id): return on_screen.encloses(strip.buttons[tab_id].get_global_rect())):
		print("CHROMIUM_TAB_REORDER ", JSON.stringify({"skipped": "both tabs do not fit in the pane", "pane": str(on_screen), "tabs": before.map(func(tab_id): return str(strip.buttons[tab_id].get_global_rect()))}))
	else:
		var from: Vector2 = screen_of.call(strip.buttons[before[0]])
		var past: Vector2 = screen_of.call(strip.buttons[before[1]])
		var to: Vector2 = past + Vector2((past - from).x * .6, 0)
		await touch(0, true, from)
		for step in range(1, 9):
			await finger(0, from.lerp(to, step / 8.0))
		await touch(0, false, to)
		var shown := func() -> Array: return strip._visual_order.map(func(tab_id): return str(strip.buttons[tab_id].get_meta("title")))
		var moved := await until(func(): return shown.call() == expected and chromium.page_tabs.map(func(t): return int(t.id)) == [before[1], before[0]],
			"A dragged tab stays where it was dropped", 3.0)
		print("CHROMIUM_TAB_REORDER ", JSON.stringify({"shown": shown.call(), "expected": expected, "owner": chromium.page_tabs.map(func(t): return [t.id, t.title]), "from": str(from), "to": str(to), "free": str(free), "hit": view.window_at(view.canvas_point_at(view.get_global_transform_with_canvas().affine_inverse() * from)), "pane": pane.key}))
		expect(moved, "The tab strip shows the confirmed order right after the drop")
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id),"Explicit close removes only chromium pane")
	expect(host.sessions.has(initial_id),"Closing chromium preserves owner terminal")

func chromium_scroll_stability() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Scroll fixture creates Chromium"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Scroll Chromium is ready"): return
	var chromium: Node = host.chromiums[id]
	if not await until(func(): return chromium.texture != null, "Scroll fixture receives pixels"): return
	var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
	if not chromium.gpu_active and not codecs.is_empty():
		if not await until(func(): return chromium.video_codec in codecs, "Scroll fixture negotiates hardware video"): return
	# A remote browser often starts after its pane is laid out. The website
	# viewport must still follow the pane, not Chromium's default window.
	var pane: Control = view.panes["%%%d" % id]
	var fitted: Vector2i = chromium.viewport_for(pane.texture.size)
	var page_size: Variant = null
	for attempt in 40:
		page_size = await chromium_eval(chromium, "[innerWidth,innerHeight]")
		if page_size is Array and absf(float(page_size[0]) - fitted.x) <= 1 and absf(float(page_size[1]) - fitted.y) <= 1: break
		await wait(.25)
	print("CHROMIUM_VIEWPORT ", JSON.stringify({"page": page_size, "fitted": [fitted.x, fitted.y], "pane": [pane.texture.size.x, pane.texture.size.y]}))
	expect(page_size is Array and absf(float(page_size[0]) - fitted.x) <= 1 and absf(float(page_size[1]) - fitted.y) <= 1,
		"The website viewport follows the pane's size")
	# Camera size changes presentation quality, never the website's CSS viewport.
	if not chromium.gpu_active and not codecs.is_empty():
		await wait(1.0)
		var original_camera := frame()
		var original_overview: bool = view.overview
		var full_height: int = chromium.texture.get_height()
		var shown: float = preload("res://scenes/remote/RemoteClient.gd").chromium_display_height(view, pane.texture)
		# About 200 screen pixels tall, as far as the pane stays readable.
		var zoomed := streaming_zoom(pane, minf(.15 * shown, 200.0))
		var factor: float = zoomed.factor
		var wanted: int = zoomed.rendition
		if wanted >= full_height:
			# No readable size of this pane is small enough for a lower rendition.
			print("CHROMIUM_RENDITION ", JSON.stringify({"skipped": "pane cannot shrink below its full rendition while readable", "full_height": full_height, "shown": shown, "factor": factor}))
		else:
			await camera(original_camera.center, original_camera.zoom * factor)
			# A tall page can be narrower than the encoder's minimum width at
			# its tier; the server then keeps its aspect with more rows.
			var small := func() -> bool:
				var rendition := Vector2i(chromium.texture.get_size())
				return rendition.y < full_height and (rendition.y <= wanted or rendition.x <= 256)
			var became_small: bool = await until(small, "Zoomed-out Chromium switches to a small hardware rendition", 8.0)
			print("CHROMIUM_RENDITION ", JSON.stringify({"full_height": full_height, "shown": shown, "factor": factor, "wanted": wanted, "paused": chromium.stream_paused, "rendition": [chromium.texture.get_width(), chromium.texture.get_height()]}))
			if not became_small: return
		expect(await chromium_eval(chromium, "[innerWidth,innerHeight]") == page_size, "Adaptive resolution preserves website layout")
		await camera(original_camera.center, original_camera.zoom)
		view.overview = original_overview
		view._apply_navigation()
		if not await until(func(): return chromium.texture.get_height() >= full_height, "Zooming back restores Chromium resolution", 8.0): return
		expect(chromium.video_codec in codecs, "Adaptive resolution retains hardware video")
	var html := "<style>html,body{margin:0;background:#f08060}section{height:160px;padding:8px;box-sizing:border-box;font:32px sans-serif;color:white;background:linear-gradient(110deg,#20ffff,#ffcc40)}section:nth-child(even){background:linear-gradient(20deg,#ff80ff,#80ff40)}</style>"
	for row in 80: html += "<section>Scroll row %d: 한글 日本語</section>" % row
	html += "<div id=marker style='position:fixed;left:0;top:0;width:20px;height:20px;background:rgb(20,200,80)'></div><script>window.wheelCount=0;window.lastWheel=null;addEventListener('wheel',e=>{wheelCount++;lastWheel={x:e.clientX,y:e.clientY,dx:e.deltaX,dy:e.deltaY}},{passive:true});addEventListener('scroll',()=>{marker.style.background=scrollY===0?'rgb(20,200,80)':scrollY>=document.documentElement.scrollHeight-innerHeight-1?'rgb(220,60,180)':'rgb(40,80,220)'})</script>"
	await chromium_eval(chromium, "document.open();document.write(%s);document.close();true" % JSON.stringify(html))
	await wait(.5)
	var metrics: Array = []
	for mode in ["wheel", "touchpad"]:
		for cycle in 3:
			for direction in [1, -1]:
				var before: int = chromium.frames
				var received: int = chromium.video_sequence
				var observed := before
				var started := Time.get_ticks_msec()
				var last_frame := started
				var longest_gap := 0
				for step in 80:
					var extent := Vector2(chromium.texture.get_size())
					if mode == "touchpad":
						# A trackpad sequence, in native units, ending with the fingers' lift.
						var native := 0.03 if OS.get_name() == "macOS" else 1.0
						var pan := InputEventPanGesture.new()
						pan.position = extent * .5
						pan.delta = Vector2(.00001 if step % 2 else -.00001, direction * 240.0) * native
						pan.set_meta("scroll_phase", "began" if step == 0 else "changed")
						chromium.remote_input(pan, extent)
						if step == 79:
							var lift := InputEventPanGesture.new()
							lift.position = pan.position
							lift.set_meta("scroll_phase", "ended")
							chromium.remote_input(lift, extent)
					else:
						var wheel := InputEventMouseButton.new()
						wheel.position = extent * .5
						wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if direction > 0 else MOUSE_BUTTON_WHEEL_UP
						wheel.factor = 4
						wheel.pressed = true
						chromium.remote_input(wheel, extent)
					await get_tree().process_frame
					if chromium.frames != observed:
						longest_gap = maxi(longest_gap, Time.get_ticks_msec() - last_frame)
						last_frame = Time.get_ticks_msec()
						observed = chromium.frames
				await wait(.4)
				var position: Variant = await chromium_eval(chromium, "({y:scrollY,max:document.documentElement.scrollHeight-innerHeight,wheels:window.wheelCount,last:window.lastWheel,width:innerWidth,height:innerHeight,visible:document.visibilityState,focused:document.hasFocus()})")
				if not expect(position is Dictionary, "Scroll endpoint remains responsive"): return
				print("CHROMIUM_SCROLL_POSITION ", JSON.stringify({"page":position,"status":chromium.status,"ready":chromium.chromium_ready,"source":str(chromium._input_viewport_size()),"texture":str(chromium.texture.get_size())}))
				expect(absf(float(position.y) - (float(position.max) if direction > 0 else 0.0)) <= 1, "%s cycle %d reaches endpoint %d" % [mode, cycle, direction])
				expect(chromium.failure_reason.is_empty(), "Scroll leaves Chromium connected")
				if not chromium.gpu_active and not codecs.is_empty():
					expect(chromium.video_codec in codecs, "Scroll retains hardware video without image fallback")
				expect(chromium.frames >= before + 2, "Scroll delivers multiple new client frames")
				var expected := Color(220.0/255, 60.0/255, 180.0/255) if direction > 0 else Color(20.0/255, 200.0/255, 80.0/255)
				await until(func():
					var image: Image = chromium.texture.get_image()
					var marker := image.get_pixel(4, 4)
					return absf(marker.r - expected.r) < .12 and absf(marker.g - expected.g) < .12 and absf(marker.b - expected.b) < .12,
					"Presented pixels reach the current scroll endpoint", 1.0)
				var pixels: Image = chromium.texture.get_image()
				for fraction in [.25, .5, .75]:
					var top := pixels.get_pixel(int(pixels.get_width() * fraction), 2)
					expect(maxf(top.r, maxf(top.g, top.b)) > .5, "Settled page top has no black strip")
				# Received packets against presented frames separates link from decoder limits.
				metrics.append({"mode":mode,"cycle":cycle,"direction":direction,"frames":chromium.frames-before,"received":chromium.video_sequence-received,"size":[chromium.texture.get_width(),chromium.texture.get_height()],"elapsed_ms":Time.get_ticks_msec()-started,"observed_interframe_gap_ms":longest_gap,"codec":chromium.video_codec,"gpu_active":chromium.gpu_active})
				print("CHROMIUM_SCROLL_SAMPLE ", JSON.stringify(metrics[-1]))
	print("CHROMIUM_SCROLL_METRICS ", JSON.stringify(metrics))
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "Scroll Chromium closes cleanly")
	expect(host.sessions.has(initial_id), "Closing scroll Chromium preserves the original terminal")

## Like mobile Chrome: one finger carries the page, a tap clicks it.
func chromium_touch() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Touch fixture creates Chromium"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Touch Chromium is ready"): return
	var chromium: Node = host.chromiums[id]
	if not await until(func(): return chromium.texture != null, "Touch fixture receives pixels"): return
	var pane: Control = view.panes["%%%d" % id]
	host.focus_pane(pane.key)
	if pane.chrome != null: pane.chrome.address.release_focus()
	var target: Dictionary = view._inspection_target(pane.key)
	await camera(target.center, target.zoom)
	var html := "<style>html,body{margin:0}section{height:160px;font:32px sans-serif;background:linear-gradient(#20ffff,#ffcc40)}</style>"
	for row in 60: html += "<section>Touch row %d</section>" % row
	html += "<script>window.clicks=[];window.wheel=[0,0];addEventListener('click',e=>clicks.push([e.clientX,e.clientY]));addEventListener('wheel',e=>{wheel[0]+=e.deltaY;wheel[1]++},{passive:true})</script>"
	await chromium_eval(chromium, "document.open();document.write(%s);document.close();scrollTo(0,0);true" % JSON.stringify(html))
	await wait(.5)
	var shown: Rect2 = view.control_screen_rect(pane.texture)
	var to_root: Transform2D = view.get_global_transform_with_canvas()
	var start: Vector2 = to_root * (shown.position + shown.size * Vector2(.5, .75))
	var travel := shown.size.y * .4
	await touch(0, true, start)
	for step in range(1, 11):
		await finger(0, start - to_root.basis_xform(Vector2(0, travel * step / 10.0)))
	# Holding still before lifting leaves no fling, so only the drag counts.
	await wait(.25)
	await touch(0, false, start - to_root.basis_xform(Vector2(0, travel)))
	await wait(.6)
	var page: Variant = await chromium_eval(chromium, "({y:scrollY,wheel:wheel,clicks:clicks.length,selected:getSelection().toString()})")
	if not expect(page is Dictionary, "Touch Chromium answers after the drag"): return
	var expected: float = travel * chromium._input_viewport_size().y / shown.size.y
	print("CHROMIUM_TOUCH_DRAG ", JSON.stringify({"page": page, "expected": expected, "shown": str(shown)}))
	expect(absf(float(page.y) - expected) <= expected * .25, "One finger carries the page as far as it moves")
	expect(int(page.clicks) == 0 and str(page.selected).is_empty(), "Dragging neither clicks nor selects text")
	var at: Vector2 = to_root * shown.get_center()
	# Queue both contacts before waiting so a busy frame cannot turn the tap into a long press.
	for pressed in [true, false]:
		var contact := InputEventScreenTouch.new()
		contact.index = 0
		contact.pressed = pressed
		contact.position = root.get_final_transform() * at
		Input.parse_input_event(contact)
	await wait(.6)
	var clicks: Variant = await chromium_eval(chromium, "clicks")
	print("CHROMIUM_TOUCH_TAP ", JSON.stringify({"clicks": clicks, "viewport": str(chromium._input_viewport_size())}))
	expect(clicks is Array and clicks.size() == 1, "A tap clicks the page once")
	if clicks is Array and clicks.size() == 1:
		var middle: Vector2 = chromium._input_viewport_size() * .5
		expect(Vector2(float(clicks[0][0]), float(clicks[0][1])).distance_to(middle) <= middle.length() * .1, "The click lands where the finger tapped")
	keyboard_inset(120.0)
	await wait(.3)
	expect(manager.keybar.visible and not manager.keybar.buttons.has("meta"), "Chromium gets Android Ctrl/Alt/Shift accessory strip")
	await chromium_eval(chromium, "window.chords=[];for(const type of ['mousedown','mouseup'])addEventListener(type,e=>{chords.push([type,e.ctrlKey,e.altKey,e.shiftKey,e.metaKey]);e.preventDefault()});true")
	for modifier in ["ctrl", "alt", "shift"]:
		await tap(manager.keybar.buttons[modifier])
		at = to_root * view.control_screen_rect(pane.texture).get_center()
		for pressed in [true, false]:
			var mouse := InputEventMouseButton.new()
			mouse.position = at
			mouse.global_position = at
			mouse.button_index = MOUSE_BUTTON_LEFT
			mouse.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			mouse.pressed = pressed
			mobile._dispatch_pointer(mouse, mobile.pointer_generation)
			await wait(.1)
		await wait(.2)
		var received: Variant = await chromium_eval(chromium, "chords.splice(0)")
		var expected_flags := [modifier == "ctrl", modifier == "alt", modifier == "shift", modifier == "meta"]
		expect(received is Array and received.size() == 2 and received[0].slice(1) == expected_flags and received[1].slice(1) == expected_flags,
			"Chromium DOM receives " + modifier + " on both click edges")
		expect(manager.keybar.modifiers.is_empty() and manager.keybar.pointer_chords.is_empty(), modifier + " one-shot clears after browser click")
	keyboard_inset(0.0)
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "Touch Chromium closes cleanly")

## The address bar follows each navigation promptly, on every client.
func chromium_url() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "URL fixture creates Chromium"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "URL Chromium is ready"): return
	var chromium: Node = host.chromiums[id]
	var pane: Control = view.panes["%%%d" % id]
	if not await until(func(): return pane.chrome != null, "URL Chromium shows its address bar"): return
	var address: LineEdit = pane.chrome.address
	var connection: Node = host.session_backend.connection
	var topology_url := func() -> String:
		for item in connection.topology.get("chromiums", []):
			for tab in item.get("state", {}).get("tabs", []):
				if tab.get("selected", false): return str(tab.get("url", ""))
		return ""
	var steps: Array = []
	# A busy terminal shares the connection; its output must not delay the URL.
	terminal().send_text("while :; do seq 1 4000; done\n")
	await wait(1.0)
	for step in 8:
		# Fragments change the URL in place; a real navigation loads a new document.
		var wanted := "#step%d" % step if step % 2 == 0 else "?step%d" % step
		var started := Time.get_ticks_msec()
		var timing := {"step": step, "kind": "hash" if step % 2 == 0 else "load"}
		if step % 2 == 1:
			await chromium.request("tab-navigate", {"chromium_id": chromium.selected_page_id, "text": "about:blank" + wanted})
		else:
			await chromium_eval(chromium, "location.hash=%s;1" % JSON.stringify(wanted))
		timing.request_ms = Time.get_ticks_msec() - started
		var deadline := started + 15000
		while Time.get_ticks_msec() < deadline and not (topology_url.call().ends_with(wanted) and address.text.ends_with(wanted)):
			if not timing.has("topology_ms") and topology_url.call().ends_with(wanted): timing.topology_ms = Time.get_ticks_msec() - started
			await get_tree().process_frame
		if not timing.has("topology_ms") and topology_url.call().ends_with(wanted): timing.topology_ms = Time.get_ticks_msec() - started
		timing.address_ms = Time.get_ticks_msec() - started if address.text.ends_with(wanted) else -1
		steps.append(timing)
		await wait(.5 * step)
	terminal().send_text("\u0003")
	print("CHROMIUM_URL_LATENCY ", JSON.stringify(steps))
	expect(steps.all(func(timing): return timing.address_ms >= 0 and timing.address_ms < 3000), "Every navigation reaches the address bar within 3 seconds")
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "URL Chromium closes cleanly")

var chromium_kills := 0

## The runner backgrounds the real APK beyond the heartbeat deadline. The
## server page must survive and resume video without creating another browser.
func chromium_resume() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Resume fixture creates Chromium"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Resume browser is ready"): return
	var chromium: Node = host.chromiums[id]
	if not await until(func(): return chromium.texture != null and chromium.video_decoder != null, "Resume fixture uses hardware video"): return
	var pid: int = chromium.pid
	var codec: String = chromium.video_codec
	await chromium_eval(chromium, "window.resumeMarker='preserved';window.resumeTicks=0;function tick(){document.body.style.background='hsl('+((++resumeTicks*7)%360)+' 80% 50%)';requestAnimationFrame(tick)};tick();1")
	for cycle in [1, 2]:
		var ticks: Variant = await chromium_eval(chromium, "resumeTicks")
		published["chromium_background"] = cycle
		if not await until(func(): return FileAccess.file_exists("user://chromium-resumed-%d.json" % cycle), "Android returns from the background", 60.0): return
		if not await until(func(): return transport.connected and host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Browser reconnects after Android resumes", 30.0): return
		chromium = host.chromiums[id]
		expect(chromium.pid == pid, "Resume preserves the server browser process")
		expect(await chromium_eval(chromium, "resumeMarker") == "preserved", "Resume preserves the live page document")
		var frames: int = chromium.frames
		if not await until(func(): return chromium.frames >= frames + 10 and chromium.video_codec == codec, "Hardware video resumes with fresh frames", 15.0): return
		expect(int(await chromium_eval(chromium, "resumeTicks")) > int(ticks), "The resumed page keeps animating")
		expect(chromium.failure_reason.is_empty() and chromium.video_error.is_empty(), "Resume leaves no browser or decoder error")
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "Resumed browser closes cleanly")

## The Chromium host runs on the server computer. A desktop client stops its
## processes directly; on Android the runner stops what the scenario publishes.
func kill_chromium(host_pid: int, process: String) -> void:
	if OS.has_feature("android"):
		chromium_kills += 1
		published["chromium_kill"] = {"id": chromium_kills, "host": host_pid, "process": process}
		return
	if process == "host":
		OS.kill(host_pid)
		return
	var output := []
	OS.execute("ps", ["-axo", "pid=,ppid=,command="], output)
	for line in str(output[0]).split("\n"):
		var parts := line.strip_edges().split(" ", false, 2)
		if parts.size() == 3 and int(parts[1]) == host_pid and "--type=renderer" in parts[2] and not "--extension-process" in parts[2]:
			OS.kill(int(parts[0]))

func chromium_crash_recovery() -> void:
	var created: Dictionary = await host.session_backend.create_chromium_remote(host, initial_id, "about:blank", true, null)
	if not expect(created.has("result"), "Crash fixture creates Chromium"): return
	var id := int(str(created.result.chromium).trim_prefix("%"))
	if not await until(func(): return host.chromiums.has(id) and host.chromiums[id].chromium_ready, "Crash fixture Chromium is ready"): return
	var chromium: Node = host.chromiums[id]
	if not await until(func(): return chromium.texture != null and chromium.pid > 0, "Crash fixture receives pixels"): return
	var pid: int = chromium.pid
	var notices: Node = host.application.notifications
	var notified: int = notices.history.size()
	kill_chromium(pid, "host")
	if not await until(func(): return not chromium.failure_reason.is_empty(), "Killed Chromium host is reported to the client", 30.0): return
	var alerts: Array = notices.history.slice(notified).filter(func(entry): return entry.level == "error")
	expect(alerts.size() == 1, "An unexpected stop posts exactly one error notification")
	var pane: Control = view.panes.get("%%%d" % id)
	if not expect(pane != null and pane.chromium_failure.visible and pane.chromium_restart_button.visible,
			"The stopped pane offers Restart instead of a frozen page"): return
	var target: Dictionary = view._inspection_target("%%%d" % id)
	await camera(target.center, target.zoom)
	# The pane draws inside the workspace canvas: aim through its camera.
	await tap(pane.chromium_restart_button)
	if not await until(func(): return chromium.failure_reason.is_empty() and chromium.chromium_ready and chromium.pid > 0 and chromium.pid != pid,
			"Restart relaunches Chromium in the same pane", 45.0): return
	var frames: int = chromium.frames
	await chromium_eval(chromium, "document.body.style.background='rgb(20,80,160)'; 1")
	expect(await until(func(): return chromium.frames > frames, "The relaunched Chromium streams new frames", 20.0), "Relaunch resumes the stream")
	expect(not pane.chromium_failure.visible, "The recovered pane hides the failure message")
	var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
	if not chromium.gpu_active and not codecs.is_empty():
		expect(chromium.video_codec in codecs, "The relaunched Chromium keeps hardware video")
	# A renderer crash leaves the browser running: the page offers a reload.
	var page_notified: int = notices.history.size()
	kill_chromium(chromium.pid, "renderer")
	if not await until(func(): return chromium.page_crashed, "A killed renderer is reported as a crashed page", 30.0): return
	var page_alerts: Array = notices.history.slice(page_notified).filter(func(entry): return entry.level == "error")
	expect(page_alerts.size() == 1 and chromium.failure_reason.is_empty(), "A page crash posts exactly one error notification")
	if not expect(pane.chromium_failure.visible and pane.chromium_reload_button.visible and not pane.chromium_restart_button.visible,
			"The crashed page offers Reload instead of a frozen page"): return
	await wait()
	target = view._inspection_target("%%%d" % id)
	await camera(target.center, target.zoom)
	await tap(pane.chromium_reload_button)
	if not await until(func(): return not chromium.page_crashed, "Reload replaces the crashed renderer", 20.0): return
	var reloaded: int = chromium.frames
	var received: int = chromium.video_sequence
	await chromium_eval(chromium, "document.body.style.background='rgb(160,80,20)'; 1")
	var streamed := await until(func(): return chromium.frames > reloaded, "The reloaded page streams new frames", 20.0)
	# Packets without frames is a decoder stall; neither is a capture stall.
	var diagnostics: Dictionary = await chromium.request("cdp", {"method": "Graffitty.diagnostics", "params": {}})
	var capture: Dictionary = diagnostics.get("result", {})
	print("CHROMIUM_RELOAD_STREAM ", JSON.stringify({"presented": chromium.frames - reloaded, "received": chromium.video_sequence - received,
		"codec": chromium.video_codec, "gpu": chromium.gpu_active, "error": chromium.video_error,
		"capture_frames": capture.get("captureFrames"), "frame_size": capture.get("frameSize"),
		"recaptures": capture.get("recaptures"), "nudges": capture.get("nudges")}))
	expect(streamed, "Reload resumes the stream")
	expect(not pane.chromium_failure.visible, "The reloaded page hides the crash message")
	# A page stuck in script keeps its renderer and ignores Page.reload; the
	# owner's reload loads it again in a new renderer, without a crash.
	await chromium_eval(chromium, "setTimeout(function(){while(true){}},50); 1")
	if not await until(func(): return chromium.page_not_responding, "A page stuck in script is reported as not responding", 30.0): return
	if not expect(pane.chromium_failure.visible and pane.chromium_reload_button.visible and not pane.chromium_restart_button.visible,
			"The stuck pane offers Reload"): return
	await wait()
	target = view._inspection_target("%%%d" % id)
	await camera(target.center, target.zoom)
	var stuck_frames: int = chromium.frames
	await tap(pane.chromium_reload_button)
	if not await until(func(): return not chromium.page_not_responding and not chromium.page_crashed, "Reload recovers the stuck page", 30.0): return
	await chromium_eval(chromium, "document.body.style.background='rgb(40,120,90)'; 1")
	expect(await until(func(): return chromium.frames > stuck_frames, "The recovered page streams new frames", 20.0),
		"Reloading a stuck page restores the stream")
	expect(not pane.chromium_failure.visible, "The recovered pane hides the message")
	host.close_chromium_session(id)
	await until(func(): return not host.chromiums.has(id), "Relaunched Chromium closes cleanly")

func connections_scroll() -> void:
	for index in 7:
		var connection := settings.duplicate()
		connection.url = str(settings.url).trim_suffix("/") + "/list-%d" % index
		connection.name = "Android workspace %d with a deliberately long label" % index
		manager.open_connection(connection)
	await until(func(): return manager.federation.connections.size()==8 and manager.federation.connections.all(func(c): return c.connected and not c.topology.panes.is_empty()),"Eight simultaneous workspaces connect")
	await menu("Sessions::Servers…")
	expect(manager.chooser.visible,"Connections opens with many rows")
	if host.menu_layer != null:
		expect(not host.menu_layer.visible, "Workspace menu stays hidden on server selection")
	# Resize the real scene, not just rows.size: child minimum sizes must not
	# push translated device cards or the footer beyond a folded viewport.
	var localization := get_node("/root/Localization")
	var saved_language: String = localization.choice
	var saved_size := root.content_scale_size
	var saved_mode := root.content_scale_mode
	var saved_aspect := root.content_scale_aspect
	var saved_factor := root.content_scale_factor
	localization.set_language("fr-FR", false)
	expect(TranslationServer.get_locale().begins_with("fr"), "Fold regression exercises French translations")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	root.content_scale_factor = 1.0
	for logical_size in [Vector2i(1000, 750), Vector2i(360, 780), Vector2i(750, 1000), Vector2i(360, 780)]:
		root.content_scale_size = logical_size
		await wait(.5)
		var width := root.get_visible_rect().size.x
		expect(manager.chooser.size.x <= width + 1, "French server page fits viewport after folding to %s" % logical_size)
		expect(manager.rows.size.x <= manager.chooser.available_content_width() + 1,
			"Device list fits after folding to %s" % logical_size)
		for card in manager.cards.values():
			var rect: Rect2 = card.get_global_rect()
			expect(rect.position.x >= -1 and rect.end.x <= width + 1, "Complete server card stays within folded screen")
		for button in [manager.connection_tab, manager.settings_tab]:
			var footer: Rect2 = button.get_global_rect()
			expect(footer.position.x >= -1 and footer.end.x <= width + 1, "Translated navigation stays within folded screen")
	manager._new_connection()
	await wait(.3)
	expect(manager.dialog.size.x <= root.get_visible_rect().size.x + 1, "French server editor also fits folded screen")
	if host.menu_layer != null:
		expect(not host.menu_layer.visible, "Workspace menu stays hidden in server editor")
	manager._cancel_editor()
	localization.set_language(saved_language, false)
	root.content_scale_size = saved_size
	root.content_scale_mode = saved_mode
	root.content_scale_aspect = saved_aspect
	root.content_scale_factor = saved_factor
	await wait(.3)
	expect(root.get_visible_rect().has_point(point(manager.connection_tab)), "Navigation remains visible when the connection list exceeds viewport")
	var scroll: ScrollContainer = manager.chooser.find_children("*","ScrollContainer",true,false)[0]
	expect(scroll.get_v_scroll_bar().max_value>scroll.size.y,"Large list exposes scrolling rather than growing dialog off-screen")
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	await wait(.2)
	var row: Node = manager.rows.get_child(manager.rows.get_child_count()-1)
	await tap(row.more)
	await wait(.2)
	await tap(row.disconnect_button)
	await until(func(): return manager.federation.connections.size()==7,"Visible bottom-row Detach removes only requested connection")
	var main_card: Control = manager.cards[manager._connection_key(settings)]
	scroll.ensure_control_visible(main_card)
	await wait(.2)
	# A card's tap is its connection action; the start control opens the workspace.
	await tap(main_card.select)
	expect(manager.chooser.visible and transport.connected,"Tapping a connected card keeps its connection and the server page")
	manager.chooser.scroll.scroll_vertical = 0
	await wait(.2)
	await tap(manager.touch_start.brand)
	expect(not manager.chooser.visible and transport.connected,"Touch to start opens the connected workspace")
	if host.menu_layer != null:
		expect(host.menu_layer.visible, "Returning to workspace restores its menu")

func auth_recovery() -> void:
	var wrong := settings.duplicate()
	wrong.url = str(settings.url).trim_suffix("/") + "/recovery"
	wrong.token = "intentionally-incorrect"
	manager.open_connection(wrong)
	var key: String = manager._connection_key(wrong)
	if not await until(func(): return manager.states[key].state == "password", "Wrong password produces a recoverable server card"): return
	manager.chooser.scroll.ensure_control_visible(manager.cards[key])
	await wait()
	await tap(manager.cards[key].more)
	await wait(.2)
	await tap(manager.cards[key].action)
	expect(manager.dialog.visible, "Enter current password opens the editor for that server")
	expect(transport.connected and host.sessions.has(initial_id),"Authentication failure does not disconnect existing workspace")
	expect(manager.token.secret and manager.token.text.is_empty(),"Password field is masked and rejected secret is cleared")
	manager.endpoint.text = str(wrong.url).trim_prefix("ws://")
	manager.token.text = str(settings.token)
	manager.remember.button_pressed = false
	await tap(manager.dialog.get_ok_button())
	await until(func(): return manager.federation.connections.any(func(c): return c.url==wrong.url and c.connected and not c.topology.panes.is_empty()),"Corrected credentials connect server and restores its view")
	expect(not manager.dialog.visible,"Successful authentication dismisses credential form")
	expect(manager.entries[key].url == wrong.url, "A bare host and custom port save the canonical server address")
	expect(transport.connected,"Original connection survives credential recovery")
	# Reconnecting from the saved document exercises Godot's float-valued JSON
	# numbers, not just the integer option IDs produced by a fresh editor.
	var authentication := preload("res://scenes/remote/ClientAuthentication.gd")
	var restored: Array = authentication.saved_connections().filter(func(entry): return entry.url == wrong.url)
	expect(restored.size() == 1, "Recovered server persists without a session target")
	if restored.size() != 1: return
	expect(typeof(restored[0].chromium_stream.bitrate_kbps) == TYPE_FLOAT, "Saved Auto quality returns through Godot JSON as a float")
	manager._stop_transport(key)
	manager.save_hint.text = ""
	manager.open_connection(restored[0].merged({"token": settings.token}, true))
	await until(func(): return manager.transports.has(key) and manager.transports[key].connected, "Reloaded connection authenticates again")
	expect(manager.save_hint.text.is_empty(), "Hostname refresh resaves loaded quality without a numeric type error")
	expect(authentication._save(authentication.saved_connections()).is_empty(), "Bulk connection saves accept the same loaded preferences")
	expect(transport.connected, "Saved-settings round trip leaves the original workspace connected")

func dominant_pixels(image: Image, channel: int) -> int:
	image.convert(Image.FORMAT_RGBA8)
	var bytes := image.get_data()
	var count := 0
	for index in range(0, bytes.size(), 4):
		if bytes[index + 3] > 64 and bytes[index + channel] > 80 and bytes[index + channel] > bytes[index + (channel + 1) % 3] * 2 and bytes[index + channel] > bytes[index + (channel + 2) % 3] * 2:
			count += 1
	return count

func usability_regressions() -> void:
	var original_pid: int = terminal().get_shell_pid()
	terminal().send_text("GFT_RECONNECT_TOKEN=kept\r")
	# A compact title deliberately masks the fixed terminal surface. Test
	# glyph rendering below that mask without moving or resizing the grid.
	await menu("View::Fit to Pane")
	await wait(.8)
	if not view.panes[host.pane_focus].compact_header:
		await camera(view.pane_rects[host.pane_focus].get_center(), .3)
		await wait(.4)
	var pane: Control = view.panes[host.pane_focus]
	var mask: float = pane.texture.material.get_shader_parameter("content_clip_top") * pane.body.size.y
	var row := maxi(1, ceili((mask - terminal().position.y) / terminal().get_cell_size().y) + 2)
	var grid: Vector2i = terminal().get_grid_size()
	terminal().send_text("printf '\\033[2J\\033[%d;1H\\033[38;2;0;255;0mVISIBLE_ROW\\033[0m\\n'\r" % row)
	if not await until(func(): return "VISIBLE_ROW" in text_in(), "Visible-row fixture arrives"): return
	await wait(.4)
	expect(dominant_pixels(root.get_texture().get_image(), 1) > 20, "Glyphs below the title mask are visible")
	terminal().send_text("printf '\\033[2J\\033[%d;1H\\033[38;2;255;0;0m한글\\033[0m\\n'\r" % row)
	if not await until(func(): return "한글" in text_in(), "Hangul arrives in terminal state"): return
	await wait(.8)
	# The two double-width glyphs cover four cells. Count their red pixels
	# against that area on screen, so the bar is the same on a 1x and a 2x display.
	var cell_pixels: Vector2 = terminal().get_cell_size() * view.navigation_zoom * (root.get_texture().get_size().x / root.get_visible_rect().size.x)
	var red := dominant_pixels(root.get_texture().get_image(), 0)
	expect(red > .06 * 4.0 * cell_pixels.x * cell_pixels.y, "Hangul paints red glyph pixels, not blank cells (%d red, cell %.1fx%.1f px)" % [red, cell_pixels.x, cell_pixels.y])
	expect(terminal().get_grid_size() == grid, "Title masking preserves the terminal grid")
	await until(func():
		var data: Dictionary = host.resource_monitor_for(initial_id).snapshot()
		return data.get("status") == "running" and data.get("cpu_valid", false) and int(data.get("memory_current", 0)) > 0
	, "Standalone server publishes live CPU and memory", 12.0)
	if OS.has_feature("android"):
		await tap(manager.floating.get_node("KeyboardButton"))
		if await until(func(): return manager.keyboard_insets.keyboard_height() > 0, "Real Android IME opens"):
			await wait(.7)
			var scale_y := root.get_final_transform().get_scale().y
			var bottom: float = root.get_visible_rect().size.y - manager.keyboard_insets.keyboard_height() / scale_y
			expect(host.layout_root.size.y <= bottom + 1, "Workspace ends above the native keyboard")
			var cursor: Vector2 = view.window_point(view.terminal_origin(host.pane_focus) + terminal().position + terminal().get_cursor_anchor_local())
			expect(cursor.y < bottom and cursor.y > view.BAR_HEIGHT, "Typing cursor remains above keyboard and below tabs")
			await until(func(): return terminal().get_grid_size().y < grid.y, "IME reflows the active client's terminal above the keyboard")
			expect(terminal().get_grid_size().x == grid.x, "IME reflow preserves terminal columns")
			var diagnostics = preload("res://graffitty/diagnostics.gd")
			diagnostic_guard.allow("Keyboard inset fixture", "fixture.gd", 1)
			diagnostics.history.assign([{"message": "Keyboard inset fixture", "file": "fixture.gd", "line": 1, "warning": false}])
			diagnostics.revision += 1
			host.show_messages()
			# Compact dock rows expose close through chrome; the Dismiss action
			# belongs to the expanded messages window.
			host.diagnostic_panel.window.float_native()
			await wait(.2)
			var dismiss: Button = host.diagnostic_panel.dismiss_button
			expect(point(dismiss).y < bottom, "Messages Dismiss stays above native keyboard")
			await tap(dismiss)
			expect(not host.diagnostic_panel.panel.visible, "Messages dismiss through actual touch with IME open")
			host.show_info()
			await until(func(): return manager.keyboard_insets.keyboard_height() == 0, "Read-only About dismisses previous terminal IME")
			await wait(.3)
			await tap(host.info_dialog.get_ok_button())
			expect(not host.info_dialog.visible, "About OK is reachable and dismisses dialog")
		manager.keyboard_insets._hide_keyboard()
		await until(func(): return manager.keyboard_insets.keyboard_height() == 0, "IME closes")
		await wait(.5)
	await menu("Sessions::Servers…")
	# Disconnect lives in the card's actions menu.
	var server_card: Control = manager.cards[manager._connection_key(settings)]
	await tap(server_card.more)
	await wait(.2)
	await tap(server_card.disconnect_button)
	await until(func(): return manager.view.host == null, "Last detach releases workspace")
	await wait()
	expect(manager.chooser.visible, "Last disconnect leaves the saved server screen")
	await tap(manager.chooser.add_server)
	await tap(manager.dialog.back)
	expect(manager.chooser.visible and not manager.dialog.visible, "Back from editor restores the saved server screen")
	await tap(manager.chooser.add_server)
	manager.endpoint.text = str(settings.url)
	manager.token.text = str(settings.token)
	if OS.has_feature("android"):
		await tap(manager.endpoint)
		if await until(func(): return manager.keyboard_insets.keyboard_height() > 0, "Connection field opens native IME"):
			await wait(.7)
			var bottom: float = root.get_visible_rect().size.y - manager.keyboard_insets.keyboard_height() / root.get_final_transform().get_scale().y
			expect(manager.dialog.position.y + manager.dialog.size.y <= bottom + 1, "Connect button remains above native IME")
			var scroll: ScrollContainer = manager.dialog.scroll
			var endpoint_center: Vector2 = manager.endpoint.get_global_rect().get_center()
			expect(scroll.get_global_rect().has_point(endpoint_center), "Focused address scrolls into view when the connection dialog shrinks")
			scroll.ensure_control_visible(manager.token)
			await wait(.2)
			expect(point(manager.token).y < bottom, "Password field can scroll into visible space above keyboard")
		manager.keyboard_insets._hide_keyboard()
		await until(func(): return manager.keyboard_insets.keyboard_height() == 0, "Connection IME closes")
		await wait(.5)
	await tap(manager.dialog.get_ok_button())
	if not await until(func(): return manager.view.host != null and not manager.view.host.sessions.is_empty(), "Reconnect from landing succeeds"): return
	# Connecting keeps the server page; the start control opens the workspace.
	expect(manager.chooser.visible and not manager.dialog.visible, "Reconnect returns to the saved server screen")
	await tap(manager.touch_start.brand)
	expect(not manager.chooser.visible, "Touch to start opens the reconnected workspace")
	host = manager.view.host
	view = host.workspace_view
	initial_id = host.active_session_id
	mobile = null
	for child in view.get_children():
		if child.get_script() == preload("res://scenes/input/MobilePointer.gd"): mobile = child
	await until(func(): return terminal().get_shell_pid() == original_pid, "Reconnect preserves original server terminal")
	terminal().send_text("printf 'RECONNECTED_%s\\n' \"$GFT_RECONNECT_TOKEN\"\r")
	await until(func(): return "RECONNECTED_kept" in text_in(), "Reconnected shell retains its variable and accepts input")

func visual_preferences() -> void:
	var original: String = host.pane_focus
	var other := await split(original)
	if other.is_empty(): return
	host.focus_pane(original)
	terminal(original).grab_focus()
	var before: int = terminal(original).get_live_font_size()
	var peer_before: int = terminal(other).get_live_font_size()
	var mac_command := OS.get_name() == "macOS" and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	await key(KEY_EQUAL, not mac_command, false, 61, mac_command)
	await until(func(): return terminal(original).get_live_font_size() > before, "Font shortcut enlarges focused remote pane")
	expect(terminal(other).get_live_font_size() == peer_before, "Font shortcut preserves other pane font")
	await key(KEY_MINUS, not mac_command, false, 45, mac_command)
	await until(func(): return terminal(original).get_live_font_size() == before, "Font decrease restores original size")
	for style in ["smear", "blaze", "lightning", "off"]:
		await menu("View::Cursor Trail::" + style.capitalize())
		expect(host.cursor_trail_style() == style, "Cursor trail selects " + style)
		var checked := 0
		for entry in host.menu_entries:
			if entry.label.begins_with("View::Cursor Trail::") and entry.checked.call(host): checked += 1
		expect(checked == 1, "Exactly one cursor style is checked")
		terminal(original).send_text("printf 'STYLE_" + style + "\\n'\r")
		# A half-width phone pane wraps the longer style names.
		await until(func(): return "STYLE_" + style in text_in(original).replace("\n", ""), "Terminal remains usable with " + style)


func direct_touch() -> void:
	var k: String = host.pane_focus
	var world: Node = host.world
	if OS.has_feature("mobile"):
		expect(host.current_plugin == "flat-2d" and host.world_viewport.disable_3d, "Mobile defaults to Flat 2D with 3D rendering disabled")
	world.fx_enabled = false
	var target: Dictionary = view._inspection_target(k)
	await camera(target.center, target.zoom)
	var pane: Control = view.panes[k]
	expect(not pane.compact_header, "Fitted phone pane shows header actions")
	var action_rect: Rect2 = pane.header.part_rect("split_right")
	var action_size: Vector2 = (view.view_point(pane.header.get_global_transform() * action_rect.end) - view.view_point(pane.header.get_global_transform() * action_rect.position)).abs()
	expect(action_rect.size == Vector2(28, 28) and action_size.x > 0, "Phone header actions use compact desktop spacing")
	await camera(target.center, target.zoom * .45)
	expect(pane.compact_header, "Actions hide below half of this client's fitted scale")
	var compact_title: Label = view.pane_titles[k]
	expect(compact_title.position.x + compact_title.size.x * compact_title.scale.x <= pane.title_handle_rect().end.x + 1, "Compact title leaves the close action's hit region clear")
	await camera(target.center, target.zoom * .7)
	expect(not pane.compact_header, "Actions return above half of this client's fitted scale")
	var title: Label = view.pane_titles[k]
	var title_at: Vector2 = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	await double_start(title_at)
	await touch(0,false,title_at)
	await wait(1.0)
	expect(absf(view.navigation_zoom - target.zoom) < .01, "Double-tapping the title directly fits its pane")
	# Same two-finger geometry as before the direct-touch migration.
	var at: Vector2 = point(mobile)
	var inverse := view.get_global_transform_with_canvas().affine_inverse()
	var fixed: Vector2 = view.canvas_point_at(inverse * (at - Vector2(100,0)))
	var moving: Vector2 = view.canvas_point_at(inverse * (at + Vector2(100,0)))
	await touch(0,true,at-Vector2(100,0))
	await touch(1,true,at+Vector2(100,0))
	await wait(.15) # Initial gesture still reserves time for a third finger.
	await finger(1,at+Vector2(200,0))
	expect(view.view_point(fixed).distance_to(inverse*(at-Vector2(100,0))) < 3, "Pinch keeps stationary finger anchored")
	expect(view.view_point(moving).distance_to(inverse*(at+Vector2(200,0))) < 3, "Pinch follows moving finger")
	await touch(1,false,at+Vector2(200,0))
	await touch(0,false,at-Vector2(100,0))
	await pan_contact_handoff()
	await camera(target.center,target.zoom)
	var before: Rect2 = view.pane_rects[k]
	title_at = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	await wait(.4)
	await touch(0,true,title_at)
	await finger(0,title_at + Vector2(60,40))
	# A tiled pane previews a reorder while held; it can return to its tile on
	# release. Verify that the actual held drag follows the finger first.
	if not await until(func(): return view.pane_rects[k].position.distance_to(before.position) > 20, "Pane drag follows the finger without moving a center pointer", 1.0): return
	await touch(0,false,title_at + Vector2(60,40))
	await wait(.4)
	var cancel_origin: Rect2 = view.pane_rects[k]
	title_at = view.get_global_transform_with_canvas() * view.title_screen_rect(title).get_center()
	await touch(0, true, title_at)
	await finger(0, title_at + Vector2(45, 30))
	# Two short event waits may finish before the intentional pinch grace expires.
	if not await until(func(): return view.moving == k, "Title drag starts before a second finger interrupts", 1.0): return
	await touch(1, true, title_at + Vector2(110, 30))
	expect(view.pane_rects[k].is_equal_approx(cancel_origin), "Second finger restores uncommitted pane placement")
	expect(view.moving.is_empty() and not view.layout_preview.visible, "Pinch clears interrupted drag and preview")
	await touch(1, false, title_at + Vector2(110, 30))
	await touch(0, false, title_at + Vector2(45, 30))
	var scroll_fingers: int = host.application.terminal_touch_scroll_fingers
	for option in [["One Finger", 1], ["Three Fingers", 3]]:
		await menu("View::Terminal Touch Scrolling::" + option[0])
		expect(host.application.terminal_touch_scroll_fingers == option[1], "Terminal scrolling menu selects " + option[0])
		await pinch_selection_guard()
	host.application.set_terminal_touch_scroll_fingers(scroll_fingers)

	terminal().send_text("printf '\\033[6 qBAR_READY\\n'\r")
	if not await until(func(): return int(terminal().remote_snapshot().get("cursor_style", -1)) == 6, "Remote insert-mode cursor is a bar"):
		print("CURSOR_DEBUG ", terminal().remote_snapshot().get("cursor_style"), " ",text_in())
	terminal().send_text("printf '\\033[2 qBLOCK_READY\\n'\r")
	await until(func(): return int(terminal().remote_snapshot().get("cursor_style", -1)) == 2, "Remote command-mode cursor becomes a block")
	world.fx_enabled = true
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", 1.15)
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.drift_px", 0.0)
	if OS.has_feature("android"):
		await tap(manager.floating.get_node("KeyboardButton"))
		await until(func(): return manager.keyboard_insets.keyboard_height() > 0, "Native IME opens for typing zoom")
		await wait(.5)
		expect(manager.keybar.visible, "Accessory keys appear above Android keyboard")
		expect(host.layout_root.get_global_rect().end.y <= manager.keybar.get_global_rect().position.y + 1, "Accessory keys have their own space above IME")
		await tap(manager.keybar.buttons.ctrl)
		expect(manager.keybar.modifiers.get("ctrl", false), "Touch arms Ctrl for the next key")
		var modified := InputEventKey.new()
		modified.pressed = true
		modified.unicode = 117
		manager.keybar.apply_modifiers(modified)
		expect(modified.ctrl_pressed and modified.keycode == KEY_U, "Soft keyboard text receives selected Ctrl")
		expect(not manager.keybar.buttons.ctrl.button_pressed, "Touch modifier clears after next key")
	var saved: Vector2 = view.navigation_center
	var largest := 0.0
	for sample in 20:
		world.fx_last_key = world.fx_time
		await wait(.08)
		largest = maxf(largest, saved.distance_to(view.navigation_center))
	expect(largest < 1.0, "Typing camera never feeds animated pan back into saved navigation")
	var caret: Vector2 = view.view_point(view.terminal_origin(k) + terminal().position + terminal().get_cursor_anchor_local())
	expect(Rect2(Vector2(8,view.BAR_HEIGHT),view.size-Vector2(16,view.BAR_HEIGHT+8)).has_point(caret), "Typing keeps caret inside the usable phone viewport")
	if OS.has_feature("android"):
		manager.keyboard_insets._hide_keyboard()

		await until(func(): return manager.keyboard_insets.keyboard_height()==0, "Native IME closes after typing")
	world.fx_enabled = false
	if not OS.has_feature("android"):
		for sample in [Vector3(0,0,1.2),Vector3(30,20,1.0),Vector3(-20,15,1.1)]:
			var anchor: Vector2 = view.size * .5
			var canvas_anchor: Vector2 = view.canvas_point_at(anchor)
			var gesture := InputEventMagnifyGesture.new()
			gesture.position = anchor
			gesture.factor = sample.z
			gesture.set_meta("pinch_pan",root.get_final_transform().basis_xform(Vector2(sample.x,sample.y)))
			gesture.set_meta("pinch_previous",root.get_final_transform() * (view.get_global_transform_with_canvas() * anchor))
			gesture.set_meta("pinch_center",root.get_final_transform() * (view.get_global_transform_with_canvas() * (anchor + Vector2(sample.x,sample.y))))
			view._forward_pointer(gesture,true)
			await wait(.1)
			expect(view.view_point(canvas_anchor).distance_to(anchor+Vector2(sample.x,sample.y))<3,"Mac zoom and shared finger translation compose at cursor")
	await graph_editing()
	# A desktop topology update must never install the Mac's camera on a phone.
	var camera_before: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).get("navigation",{}).duplicate(true)
	var desktop_state: Dictionary = manager.federation.topology.duplicate(true)
	desktop_state.headless = false
	for tab in desktop_state.tabs:
		tab.headless = false
		tab.canonical_layout.navigation = {"center":[8888,8888],"zoom":4.0,"overview":true}
	manager.view._install_layout(desktop_state,true)
	expect(host.workspace_layout.tab(host.workspace_layout.active).get("navigation",{}) == camera_before, "Desktop topology preserves this client's own camera")

func pan_contact_handoff() -> void:
	var k: String = host.pane_focus
	var rect: Rect2 = view.pane_rects[k]
	var inverse := view.get_global_transform_with_canvas().affine_inverse()
	for survivor in [0, 1]:
		var at: Vector2 = point(mobile)
		var positions := [at - Vector2(80,0), at + Vector2(80,0)]
		await touch(0, true, positions[0])
		await touch(1, true, positions[1])
		await wait(.15)
		for i in 2:
			positions[i] += Vector2(0,20)
			await finger(i, positions[i])
		var zoom: float = view.navigation_zoom
		var center: Vector2 = view.navigation_center
		await touch(1-survivor, false, positions[1-survivor])
		expect(view.navigation_center.distance_to(center) < .1, "Lifting either pan contact does not jump the camera")
		var anchor: Vector2 = view.canvas_point_at(inverse * positions[survivor])
		positions[survivor] += Vector2(24,32)
		await finger(survivor, positions[survivor])
		expect(view.view_point(anchor).distance_to(inverse * positions[survivor]) < 3, "Remaining finger continues panning under its anchor")
		expect(is_equal_approx(view.navigation_zoom, zoom), "One-contact continuation never zooms")
		await wait(.55)
		expect(not mobile.gestures.held and not mobile.gestures.long_pressed and view.moving.is_empty(), "Continued pan cannot become selection, pane drag or long press")
		center = view.navigation_center
		var joined: Vector2 = positions[survivor] + Vector2(120,0)
		await touch(7, true, joined)
		expect(view.navigation_center.distance_to(center) < .1 and is_equal_approx(view.navigation_zoom, zoom), "Replacing a finger does not jump pan or zoom")
		await finger(7, joined + Vector2(30,0))
		expect(absf(view.navigation_zoom / zoom - 1.25) < .02, "Two-finger zoom resumes from the replacement contact distance")
		await touch(7, false, joined + Vector2(30,0))
		await touch(survivor, false, positions[survivor])
		expect(mobile.gestures.fingers.is_empty() and not mobile.gestures.navigating, "Final lift ends the navigation gesture")
	expect(view.pane_rects[k].is_equal_approx(rect), "Finger-count changes preserve pane layout")

func pinch_selection_guard() -> void:
	var clipboard := DisplayServer.clipboard_get()
	terminal().send_text("printf '\\033[2J\\033[5;5HPINCH_SELECTION_GUARD_1234567890\\033[6;5HPINCH_SECOND_LINE\\n'\r")
	if not await until(func(): return "PINCH_SECOND_LINE" in text_in(), "Pinch selection fixture reaches terminal"): return
	var cell: Vector2 = terminal().get_cell_size()
	var origin: Vector2 = view.terminal_origin(host.pane_focus) + Vector2(4, 4) + cell * Vector2(4.1, 4.5)
	for delay in [-1.0, 0.0, .2]:
		await camera(origin, 1.0)
		await wait(.35)
		var at := mobile.get_global_rect().get_center()
		DisplayServer.clipboard_set("PINCH_UNCHANGED")
		if delay < 0:
			# The second finger can arrive in the frame that queued the first
			# click, before MobilePointer's deferred dispatch has run.
			for index in 2:
				var contact := InputEventScreenTouch.new()
				contact.index = index
				contact.pressed = true
				contact.position = root.get_final_transform() * (at + Vector2(180, 70) * index)
				Input.parse_input_event(contact)
				Input.flush_buffered_events()
				if index == 0: mobile.gestures.advance(Time.get_ticks_msec() + mobile.gestures.PINCH_GRACE_MS)
			await wait(.04)
		else:
			await touch(0, true, at)
			if delay > 0: await wait(delay)
			await finger(0, at + cell * Vector2(8, 0))
			if delay > 0:
				terminal().perform_action("copy")
				if host.application.terminal_touch_scroll_fingers == 3:
					await until(func(): return DisplayServer.clipboard_get() != "PINCH_UNCHANGED", "Three-finger scroll mode allows direct text selection", 2.0)
				else:
					expect(DisplayServer.clipboard_get() == "PINCH_UNCHANGED" and not mobile.gestures.held, "Default one-finger drag never selects or copies text")
				DisplayServer.clipboard_set("PINCH_UNCHANGED")
			await touch(1, true, at + Vector2(180, 70))
		await wait(.15)
		await finger(1, at + Vector2(250, 100))
		expect(not is_equal_approx(view.navigation_zoom, 1.0), "Two contacts zoom even after first-finger motion")
		await touch(1, false, at + Vector2(250, 100))
		await finger(0, at + cell * Vector2(10, 1))
		await touch(0, false, at + cell * Vector2(10, 1))
		terminal().perform_action("copy")
		expect(DisplayServer.clipboard_get() == "PINCH_UNCHANGED", "Pinch leaves no accidental selection (second-finger delay %.1f)" % delay)
		await wait(.6)
		terminal().perform_action("copy")
		expect(DisplayServer.clipboard_get() == "PINCH_UNCHANGED", "Canceled selection cannot resume or autoscroll after pinch")
	DisplayServer.clipboard_set(clipboard)

func gestures() -> void:
	await direct_touch()


func client_controls() -> void:
	var labels: Array = host.menu_entries.map(func(entry): return entry.label)
	for expected in ["Shell::New Tab", "Shell::New Chromium", "Shell::New Pane Right", "Shell::New Pane Below", "Shell::Close Pane", "Edit::Copy", "Edit::Paste", "Edit::Find…", "View::Overview", "View::Messages", "View::Fit to Pane"]:
		expect(expected in labels, "Shared menu includes " + expected)
	for entry in host.menu_entries:
		var shortcut: InputEventKey = entry.get("shortcut")
		if shortcut != null: expect(not shortcut.meta_pressed, "Android app shortcut does not require Command: " + entry.label)
		if entry.label == "Edit::Copy":
			expect(shortcut.ctrl_pressed and shortcut.shift_pressed, "Copy uses Ctrl+Shift+C; Ctrl+C stays terminal interrupt")
	expect(not manager.keybar.buttons.has("meta") and manager.keybar.buttons.alt.text == "Alt" and manager.keybar.buttons.has("escape"), "Android key row is Ctrl/Alt with Escape regardless of server OS")
	var pane: Control = view.panes[host.pane_focus]
	var grid: Vector2i = terminal().get_grid_size()
	terminal().send_text("printf '\\033[2J\\033[%d;1H\\033[38;2;0;255;0mBOTTOM_STATUS_VISIBLE\\033[0m\\033[1;1H'\r" % grid.y)
	await until(func(): return "BOTTOM_STATUS_VISIBLE" in text_in(), "Bottom-row status fixture arrives")
	host.world.fx_enabled = false
	var target: Dictionary = view._inspection_target(host.pane_focus)
	for scale in [1.0, .7, .4, .7, 1.0]:
		await camera(target.center, target.zoom * scale)
		expect(is_zero_approx(pane.texture.offset_top) and is_zero_approx(pane.texture.offset_bottom), "Zoom masks terminal top without shifting either edge")
		expect(pane.texture.position.is_equal_approx(Vector2.ZERO) and pane.texture.size.is_equal_approx(pane.body.size), "Terminal surface fills the original body through zoom")
		expect(terminal().get_grid_size() == grid, "Title masking preserves server grid")
		expect(dominant_pixels(root.get_texture().get_image(), 1) > 20, "Bottom status text remains rendered when zooming out")

	await menu("Sessions::Servers…")
	await tap(manager.settings_tab)
	manager._refresh_font_cache(true)
	var cache_stats := preload("res://scenes/remote/ServerFonts.gd").cache_stats()
	var cache_label := tr("Font cache: %.1f MiB · files: %d") % [cache_stats.bytes / 1048576.0, cache_stats.files]
	expect(manager.font_cache_status.text.begins_with(cache_label), "Server chooser reports downloaded font cache size")
	manager.chooser.scroll.ensure_control_visible(manager.font_cache_clear)
	await wait()
	if not manager.font_cache_clear.disabled:
		await tap(manager.font_cache_clear)
		expect(preload("res://scenes/remote/ServerFonts.gd").cache_stats().files == 0, "Touch action clears downloaded font cache")
	await tap(manager.connection_tab)
	await tap(manager.cards[manager._connection_key(settings)].select)
	expect(transport.connected, "Clearing font cache preserves the server connection")
	# A connected card's tap stays on the server page; the start control returns.
	manager.chooser.scroll.scroll_vertical = 0
	await wait(.2)
	await tap(manager.touch_start.brand)
	expect(not manager.chooser.visible, "Touch to start returns to the workspace after clearing the cache")
	var extra := await split(host.pane_focus)
	if not extra.is_empty():
		terminal(extra).send_text("printf 'FONT_%s_%s\\n' CACHE CLEARED_OK\r")
		await until(func(): return "FONT_CACHE_CLEARED_OK" in text_in(extra).replace("\n", ""), "New pane renders using retained fonts after cache clear")
		await menu("Shell::Close Pane")


func pan_clipping() -> void:
	host.world.fx_enabled = false
	var key: String = host.pane_focus
	var pane: Control = view.panes[key]
	var term: Control = terminal()
	var grid: Vector2i = term.get_grid_size()
	var target: Dictionary = view._inspection_target(key)
	await camera(target.center, target.zoom)
	var columns := [1, maxi(7, grid.x / 2 - 2), maxi(13, grid.x - 6)]
	var row := mini(9, grid.y - 2)
	var command := "printf '"
	for index in 3:
		command += "\\033[%d;%dH\\033[48;2;%sm     " % [row + 1, columns[index] + 1, ["255;0;0", "0;255;0", "0;0;255"][index]]
	command += "\\033[0m\\033[1;1HPAN_PATTERN_READY'\r"
	term.send_text(command)
	await until(func(): return "PAN_PATTERN_READY" in text_in(), "Coloured cell-position fixture arrives")
	var original_zoom: float = view.navigation_zoom
	# Cross the clip edge in both directions while retaining a reference cell on
	# narrow portrait screens.
	#
	# Nine leftward steps moved every test cell outside the APK viewport, so that
	# path could no longer test rendered alignment.
	for step in 10:
		var center: Vector2 = view.size * .5
		var direction := -1.0 if step < 5 else 1.0
		view.pinch_workspace(center, center + Vector2(minf(30, view.size.x / 30.0), 8) * direction, 1.0)
		await wait(.04)
		var screenshot := root.get_texture().get_image()
		var sampled := 0
		for index in 3:
			var cell: Vector2 = term.get_cell_size()
			var canvas_point: Vector2 = view.terminal_origin(key) + term.position + Vector2.ONE * float(term.cell_padding) + cell * Vector2(columns[index] + 2, row + .5)
			var local: Vector2 = view.view_point(canvas_point)
			var physical: Vector2 = root.get_final_transform() * (view.get_global_transform_with_canvas() * local)
			if not Rect2(Vector2.ZERO, screenshot.get_size()).grow(-4).has_point(physical): continue
			# A docked sidebar covers the workspace's edge; sample only what shows.
			if not view.viewport_content_rect().grow(-4).has_point(local): continue
			var color := screenshot.get_pixelv(Vector2i(physical))
			var channels := [color.r, color.g, color.b]
			expect(channels[index] > .3 and channels[index] > channels[(index+1)%3] * 2 and channels[index] > channels[(index+2)%3] * 2, "Panned cell %d stays at its projected position on step %d" % [index, step])
			sampled += 1
		expect(sampled > 0, "Pan keeps at least one test cell visible")
		expect(view.navigation_zoom == original_zoom and term.get_grid_size() == grid, "Panning preserves zoom and terminal grid")


func fractional_scroll() -> void:
	var term: Control = terminal()
	var vp: SubViewport = host.sessions[host.active_session_id].vp
	var grid: Vector2i = term.get_grid_size()
	term.send_text("i=0; while [ $i -lt 160 ]; do printf '\\033[48;2;0;255;0m%-40s\\033[0m\\n' ROW_$i; i=$((i+1)); done; printf 'FRACTIONAL_READY\\n'\r")
	await until(func(): return "FRACTIONAL_READY" in text_in(), "Scroll fixture arrives from server")
	await wait(.2)
	term.scroll_to_row(40)
	var event := InputEventPanGesture.new()
	event.position = vp.canvas_transform * (term.position + Vector2(100,100))
	event.delta = Vector2(0, -1.5 * (.03 if OS.get_name() == "macOS" else 1.0))
	vp.push_input(event, true)
	await wait(.06)
	expect(absf(float(term.get_ui_state().scroll_offset) + term.get_scroll_fraction() - 39.9) < .001, "Tiny precision scroll moves immediately between rows")
	event = event.duplicate()
	event.delta *= -.5
	vp.push_input(event, true)
	await wait(.06)
	expect(absf(float(term.get_ui_state().scroll_offset) + term.get_scroll_fraction() - 39.95) < .001, "Reverse direction responds without a dead zone")
	var shot := vp.get_texture().get_image()
	var cell: Vector2 = term.get_cell_size()
	var point := term.position + Vector2(float(term.cell_padding) + cell.x * 20, minf(float(term.cell_padding) + cell.y * (grid.y - .1), term.size.y - 2))
	point = vp.canvas_transform * point
	point *= Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
	var color := shot.get_pixelv(Vector2i(point))
	expect(color.g > .8 and color.r < .1, "Partial bottom row contains rendered terminal cells")
	expect(term.get_grid_size() == grid, "Smooth client scrolling leaves server grid unchanged")
	term.send_text("printf 'FRACTIONAL_RESET\\n'\r")
	await wait(.2)
	expect(term.get_scroll_fraction() == 0, "Typing resets fractional scroll")


func row_continuity() -> void:
	var term: Control = terminal()
	term.send_text("i=0; while [ $i -lt 120 ]; do printf '\\033[38;2;0;255;0m%03d MMMMMMMMMMMMMMMMMMMM\\033[0m\\n' $i; i=$((i+1)); done\r")
	await wait(.8)
	term.scroll_to_row(30)
	await wait(.15)
	var vp: SubViewport = host.sessions[host.active_session_id].vp
	for step in 24:
		var event := InputEventPanGesture.new()
		event.position = vp.canvas_transform * (term.position + Vector2(100,100))
		event.delta = Vector2(0, -(1.5 if step < 12 else -1.5) * (.03 if OS.get_name() == "macOS" else 1.0))
		vp.push_input(event, true)
		await wait(.04)
		var shot := vp.get_texture().get_image()
		var grid: Vector2i = term.get_grid_size()
		var cell: Vector2 = term.get_cell_size()
		var fraction: float = term.get_scroll_fraction()
		for row in range(2, grid.y - 2):
			var a := term.position + Vector2.ONE * float(term.cell_padding) + cell * Vector2(4, row - fraction)
			var b := a + cell * Vector2(18,1)
			a = vp.canvas_transform * a * Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
			b = vp.canvas_transform * b * Vector2(shot.get_size()) / Vector2(vp.size_2d_override)
			var pixels := 0
			for y in range(maxi(0,ceili(a.y)), mini(shot.get_height(), floori(b.y))):
				for x in range(maxi(0,ceili(a.x)), mini(shot.get_width(), floori(b.x))):
					var c := shot.get_pixel(x,y)
					if c.g > c.r * 1.3 and c.g > c.b * 1.3 and c.a > .2: pixels += 1
			if pixels < 50:
				expect(false, "Row %d disappeared at step %d fraction %.3f (%d pixels)" % [row,step,fraction,pixels])
	expect(failures.is_empty(), "All glyph rows remain visible across fractional and integer scroll boundaries")
