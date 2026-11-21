extends "../../../../tests/llm-e2e/replay/replay.gd"
## Native Windows protocol/UI acceptance against the production session owner.
class TestAPI extends "res://scenes/AgentAPI.gd":
	var terminal_host: Node
	var live_graph: Node
	func dispatch(tab_id: int, method: String, params: Dictionary) -> Dictionary:
		var terminal: Control = terminal_host.sessions[tab_id].term
		if method == "test.quit":
			get_tree().call_deferred("quit")
			return {"result": {"ok": true}}
		if method == "test.terminal.start":
			var key := "%%%d" % tab_id
			terminal_host.focus_pane(key)
			if terminal_host.workspace_layout.tab(terminal_host.workspace_layout.active).tree.get("tiling", false):
				terminal_host.workspace_view.toggle_tiling()
				var layout_deadline := Time.get_ticks_msec() + 5000
				while terminal_host.session_backend.work_pending() and Time.get_ticks_msec() < layout_deadline:
					await get_tree().process_frame
			var grid: Vector2 = terminal.grid_pixel_size(120, 38)
			var insets: Array = terminal.get_meta("server_content_insets", [12.0, 38.0, 12.0, 12.0])
			var size := grid + Vector2(insets[0] + insets[2], insets[1] + insets[3])
			terminal_host.workspace_view.set_window_rect(key, Rect2(Vector2(40, 100), size), true)
			var deadline := Time.get_ticks_msec() + 5000
			while int(terminal.get_ui_state().get("columns", 0)) < 80 and Time.get_ticks_msec() < deadline:
				await get_tree().process_frame
			terminal.grab_focus()
			terminal.send_text("prompt GFT_READY$G\r")
			return {"result": {"ok": true}}
		if method == "test.terminal.text":
			return {"result": terminal.get_text(false)}
		if method == "test.terminal.write":
			terminal.send_text(str(params.get("text", "")))
			return {"result": {"ok": true}}
		if method == "test.terminal.enter":
			terminal.grab_focus()
			var event := InputEventKey.new()
			event.keycode = KEY_ENTER
			event.physical_keycode = KEY_ENTER
			event.pressed = true
			event.shift_pressed = bool(params.get("shift", false))
			event.ctrl_pressed = bool(params.get("ctrl", false))
			Input.parse_input_event(event)
			event = event.duplicate()
			event.pressed = false
			Input.parse_input_event(event)
			return {"result": {"ok": true}}
		if method == "test.terminal.press":
			terminal_host.focus_pane("%%%d" % tab_id)
			terminal.grab_focus()
			var parts := str(params.key).split("+")
			var event := InputEventKey.new()
			event.keycode = OS.find_keycode_from_string(parts[-1])
			event.physical_keycode = event.keycode
			event.ctrl_pressed = "Ctrl" in parts
			event.shift_pressed = "Shift" in parts
			event.alt_pressed = "Alt" in parts
			event.pressed = true
			Input.parse_input_event(event)
			await get_tree().process_frame
			event = event.duplicate()
			event.pressed = false
			Input.parse_input_event(event)
			return {"result": {"ok": true}}
		return await live_graph.dispatch(tab_id, method, params)

func play() -> void:
	for count in range(2, 10):
		host.create_terminal_window("%%%d" % (count - 1))
		var deadline := Time.get_ticks_msec() + 10000
		while host.sessions.size() < count and Time.get_ticks_msec() < deadline:
			await process_frame
		if not check(host.sessions.size() == count, "Owner creates native test terminal %d" % count): return
	var api := TestAPI.new()
	api.terminal_host = host
	api.live_graph = app.agent_api.graph
	root.add_child(api)
	if api.socket == null:
		check(false, "Native test API starts")
		return
	for id in range(1, 10):
		api.capabilities[str(id)] = id
		var started: Dictionary = await api.live_graph.dispatch(id, "agent.event", {"kind":"custom", "event":"SessionStart", "integrated":true})
		if not check(not started.has("error"), "Owner registers custom node %d" % id): return
		var registered: Dictionary = await api.live_graph.dispatch(id, "agent.register", {"name":"Worker %d" % id, "inputs":[{"id":"in"}], "outputs":[]})
		if not check(not registered.has("error"), "Owner advertises node %d ports" % id): return
	var ready := FileAccess.open(OS.get_environment("JEV_TEST_DIRECTORY").path_join("ready.json"), FileAccess.WRITE)
	ready.store_string(JSON.stringify({"socket":api.socket_path, "runtime":api.runtime_directory}))
	ready.close()
	while true: await process_frame
