extends "res://tests/client_scenarios/scenario.gd"
var client: Node
var interruptions: Array[String] = []
var target := -1
var observer: Node
var capture_path := ""
var capture_viewport: SubViewport
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()


func _ready() -> void:
	diagnostic_guard.install(get_tree())
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			capture_path = arg.trim_prefix("--capture=")
		if arg.begins_with("--result="):
			output = arg.trim_prefix("--result=")
	if not capture_path.is_empty():
		root.hide()
	run.call_deferred()


func expect(value: bool, message: String) -> void:
	checks.append(message)
	print("[remote client] %s %s" % ["PASS" if value else "FAIL", message])
	if not value:
		failures.append(message)


func until(condition: Callable, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await create_timer(.025).timeout
	return condition.call()


func text_in(frame: Dictionary) -> String:
	var text := ""
	for row in frame.get("lines", []):
		for cell in row:
			text += str(cell[2])
		text += "\n"
	return text


func canonical_rect(connection: Node, tab: int, key: String) -> Rect2:
	var layout: Dictionary = connection.topology.get("workspace_state", {}).get("layout", {}).get("tabs", {}).get(str(tab), {})
	for window in layout.get("windows", []):
		if str(window.key) == key:
			var rect: Array = window.rect
			return Rect2(rect[0], rect[1], rect[2], rect[3])
	return Rect2()

func output_command(text: String) -> String:
	if OS.get_name() == "Windows":
		return "Write-Host -NoNewline ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))\r" % Marshalls.utf8_to_base64(text)
	# Sending literal ESC through a shell line editor executes editing commands.
	# Decode only after the shell has accepted the line, like the Windows path.
	return "python3 -c 'import base64,sys;sys.stdout.buffer.write(base64.b64decode(\"%s\"))'\r" % Marshalls.utf8_to_base64(text)


func run() -> void:
	if not OS.has_feature("android"):
		root.unfocusable = true
		if DisplayServer.get_name() != "headless" and not preload("../../../../../tests/llm-e2e/replay/background.gd").enabled():
			root.always_on_top = true
	if not OS.has_feature("android"): root.size = Vector2i(1200, 800)
	client = load("res://scenes/remote_client.tscn").instantiate()
	client.settings = settings
	client.connection.state_changed.connect(func(message):
		print("[remote client] ", message)
		if message.begins_with("Offline"): interruptions.append(message))
	if capture_path.is_empty():
		root.add_child(client)
	else:
		capture_viewport = SubViewport.new()
		capture_viewport.size = Vector2i(1200, 800)
		capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(capture_viewport)
		capture_viewport.add_child(client)
	expect(
		await until(
			func():
				return (
					client.connection.connected and client.host != null
					and client.host.workspace_layout.tabs.size() == 2
				),
			FIRST_CONNECTION_SECONDS,
		),
		"Authenticate and discover both server tabs",
	)
	if client.host == null or client.host.workspace_layout.tabs.size() < 2:
		finish()
		return
	expect(
		client.host.get_tabs()[0].title == "DESKTOP"
		and client.host.get_tabs()[1].title == "REMOTE",
		"Client uses server tab titles",
	)
	client.host.select_workspace(int(client.host.workspace_layout.tabs[1].id), true)
	var graph: Node = client.host.agent_api.graph
	expect(await until(func(): return graph.edges.size() == 1), "Desktop graph connections arrive on client")
	var source := "%%%d" % int(client.host.workspace_layout.tabs[0].id)
	expect(graph.nodes.has(source) and graph.nodes[source].has("manifest"), "Remote node socket manifests arrive")
	expect(graph.remote_owners.get(source) == client.connection, "Remote graph belongs to its connection")
	var destination: String = graph.edges.values()[0].to
	var overlay: Control = client.host.workspace_view.agent_links
	overlay.graph = graph
	overlay.sync({source: Rect2(20, 20, 300, 200), destination: Rect2(500, 20, 300, 200)}, graph.edges.values(), func(point): return point)
	expect(overlay.links.size() == 1, "Remote connection produces drawable wire geometry")
	client.host.workspace_view._sync_chromium_links()
	target = client.host.active_session_id
	expect(
		await until(
			func():
				return client.connection.frames.has(target),
		),
		"Initial state arrives for independently selected tab",
	)
	var terminal: Node = client.host.sessions[target].term
	var mobile_count := 0
	for child in client.host.workspace_view.get_children():
		if child.get_script() == preload("res://scenes/input/MobilePointer.gd"):
			mobile_count += 1
	var touch_controls := preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	expect(mobile_count == (1 if touch_controls else 0), "touch controls are opt-in; desktop retains native mouse input")
	expect(root.gui_embed_subwindows == touch_controls, "Android dialogs stay inside the app after host registration; desktop dialogs stay native")
	var monitor: Node = client.host.resource_monitor_for(target)
	expect(monitor.remote and monitor._poll_timer == null, "Remote pane never samples client-side processes")
	expect(await until(func(): return monitor.snapshot().get("memory_current", 0) > 0), "Server resource samples reach the client")
	var strip: Dictionary = client.host.workspace_view._compact_resources("%%%d" % target)
	expect(strip.memory != "—", "The pane strip displays server memory")
	expect(await until(func(): return graph.nodes.get(source, {}).get("status") == "busy"), "Node status updates reach the client after connection")
	var owner: Dictionary = client.connection.topology.panes.filter(func(pane): return int(pane.id) == target).front()
	expect(terminal.remote_mode and int(owner.pid) > 0 and terminal.get_shell_pid() == int(owner.pid),
		"Native client mirrors the existing owner PTY identity")
	var initial: Dictionary = client.connection.frames[target]
	expect(
		terminal.get_live_font_size() == int(owner.font_size) and terminal.get_cell_size().x > 0 and terminal.get_cell_size().y > 0,
		"Client renders the shared font size with actual native font metrics",
	)
	expect(
		terminal.get_grid_size() == Vector2i(int(initial.columns), int(initial.rows)),
		"Client window size does not change the shared grid",
	)
	var packet := output_command("\u001b[31mREMOTE_\u001b[0mOK 한글 é 😀\n")
	if OS.get_name() == "Windows":
		terminal.send_text("Write-Output ('REMOTE_' + 'READY')\r")
		expect(await until(func(): return "REMOTE_READY" in str(terminal.get_text(false))),
			"Remote PowerShell finishes loading its profile before input")
	client.host.sessions[target].term.send_text(packet)
	expect(
		await until(
			func():
				return "REMOTE_OK 한글 é 😀" in str(
					client.host.sessions[target].term.get_text(false).get("text", "")
				),
		),
		"Remote input and Unicode output round trip: " + str(terminal.get_text(false).get("text", "")),
	)
	var styled := false
	var rendered: Dictionary = terminal.remote_snapshot()
	expect(interruptions.is_empty(), "Switching tabs with pending image assets keeps the connection alive")
	for row in rendered.get("lines", []):
		for cell in row:
			if cell[2] == "R" and cell[3] != rendered.foreground:
				styled = true
	expect(styled, "ANSI colors survive cell streaming")
	terminal.send_text("Write-Output '" if OS.get_name() == "Windows" else "printf '%s\\n' '")
	terminal.set_preedit("입력확인", Vector2i(0, 4))
	await create_timer(.1).timeout
	terminal.set_preedit("", Vector2i.ZERO)
	for character in "입력확인":
		var committed := InputEventKey.new()
		committed.unicode = character.unicode_at(0)
		committed.pressed = true
		client.host.sessions[target].vp.push_input(committed, true)
	terminal.send_text("'\r")
	expect(
		await until(
			func():
				return "입력확인" in str(terminal.get_text(false).get("text", "")),
		),
		"Korean IME committed keys travel through native input and render on return",
	)
	var wide := false
	var combining := false
	var emoji := false
	for row in terminal.remote_snapshot().lines:
		for cell in row:
			if cell[2] == "한" and int(cell[1]) == 2:
				wide = true
			if cell[2] == "😀" and int(cell[1]) == 2:
				emoji = true
			if cell[2] == "é" and int(cell[1]) == 1:
				combining = true
	expect(wide and emoji and combining, "Hangul and emoji use two cells and combining text uses one")
	if capture_viewport != null:
		# Capture the settled shared renderer, not a typing/fit transition.
		await create_timer(6.0).timeout
		await RenderingServer.frame_post_draw
		capture_viewport.get_texture().get_image().save_png(capture_path)
	# Wait for execution, not an arbitrary delay after queued line-editor input.
	# The encoded marker cannot be mistaken for the echoed PowerShell command.
	var sleeping := output_command("REMOTE_INTERRUPT_READY\n").trim_suffix("\r")
	if OS.get_name() != "Windows": sleeping = "printf 'REMOTE_%s\\n' 'INTERRUPT_READY'"
	sleeping += "; Start-Sleep 30\r" if OS.get_name() == "Windows" else "; sleep 30\r"
	client.host.sessions[target].term.send_text(sleeping)
	expect(await until(func(): return "REMOTE_INTERRUPT_READY" in str(terminal.get_text(false).get("text", ""))),
		"Foreground command starts before the interrupt probe")
	var event := InputEventKey.new()
	event.keycode = KEY_C
	event.ctrl_pressed = true
	event.pressed = true
	client.host.sessions[target].vp.push_input(event)
	event = event.duplicate()
	event.pressed = false
	client.host.sessions[target].vp.push_input(event)
	await create_timer(.4).timeout
	client.host.sessions[target].term.send_text(output_command("KEY_ENCODING_OK\n"))
	expect(
		await until(
			func():
				return "KEY_ENCODING_OK" in str(
					client.host.sessions[target].term.get_text(false).get("text", "")
				),
		),
		"Server keyboard encoder handles control keys: " + str(terminal.get_text(false).get("text", "")),
	)
	var key := "%%%d" % target
	var tab: int = client.host.workspace_layout.containing(key)
	# Free edge resizing is available in floating mode. A tiled pane uses the
	# divider gesture instead; a raw VT resize does not change canonical pixels.
	if client.host.workspace_layout.tab(tab).tree.get("tiling", false):
		client.host.workspace_view.toggle_tiling()
	expect(await until(func(): return not client.host.session_backend.work_pending()),
		"Floating layout choice is acknowledged before edge resizing")
	var pane: Control = client.host.workspace_view.panes[key]
	var rect: Rect2 = client.host.workspace_view.pane_rects[key]
	rect.size = terminal.grid_pixel_size(65, 18).ceil() + pane.size - terminal.size
	client.host.workspace_view.set_window_rect(key, rect, true)
	# Complete the same transaction as the real edge-resize mouse release.
	client.host.workspace_view.finish_window_move(key)
	expect(await until(func(): return not client.host.session_backend.work_pending() \
		and canonical_rect(client.connection, tab, key).is_equal_approx(rect)),
		"Completed pane resize persists the requested canonical pixel rectangle")
	expect(
		await until(
			func():
				return (
					client.connection.frames.get(target, { }).get("columns") == 65
					and client.connection.frames[target].rows == 18
				),
		),
		"Normal pane resize updates server grid",
	)
	observer = load("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(observer)
	observer.connect_remote(client.connection.url, client.connection.token)
	# Selecting the session clears subscriptions; subscribe to its panes after.
	expect(await until(func(): return observer.connected and observer.workspace == client.connection.workspace \
		and observer.topology.panes.any(func(pane): return int(pane.id) == target)),
		"Second client attaches to the same session")
	observer.subscribe([target])
	expect(
		await until(
			func():
				return observer.frames.get(target, { }).get("columns") == 65 \
					and observer.frames[target].rows == 18 \
					and canonical_rect(observer, tab, key).is_equal_approx(rect),
		),
		"Second client sees shared terminal dimensions and canonical pane pixels",
	)
	var old_epoch: String = client.connection.epoch
	client.connection.socket.close(1000, "Reconnect test")
	expect(
		await until(
			func():
				return not client.connection.connected,
		),
		"Detach closes client connection",
	)
	observer.send_action("text", target, { "text": output_command("WHILE_DETACHED\n") })
	expect(
		await until(
			func():
				return (
					client.connection.connected
					and "WHILE_DETACHED"
					in str(client.host.sessions[target].term.get_text(false).get("text", ""))
				),
			12,
		),
		"Reconnect gets output produced while detached",
	)
	expect(
		client.connection.epoch == old_epoch
		and client.host.workspace_layout.active == int(client.host.workspace_layout.tabs[1].id),
		"Reconnect preserves client tab selection and session identity",
	)
	expect(canonical_rect(client.connection, tab, key).is_equal_approx(rect)
		and terminal.get_grid_size() == Vector2i(65, 18),
		"Reconnect preserves the acknowledged pane rectangle and terminal grid")
	# Coming back to the session on screen (as after the app returns from the
	# background) rebinds the view; it must not play the session switch effect.
	expect(client.connection.session_reattached, "Reconnect returns to the shown session rather than switching")
	expect(not client.host.session_switch_in_progress and not client.host.world.session_transition_active,
		"Reconnecting to the shown session plays no session transition")
	await create_timer(.5).timeout
	var idle_packets: int = client.connection.stats.packets
	await create_timer(.75).timeout
	expect(
		client.connection.stats.packets == idle_packets,
		"Idle terminals transmit no frame packets, including cursor blink",
	)
	var latencies: Array[float] = []
	var bytes_before: int = client.connection.stats.bytes
	for sample in 8:
		var started := Time.get_ticks_usec()
		terminal.send_text(output_command("LAT_%02d\n" % sample))
		var arrived := await until(
			func():
				return ("LAT_%02d" % sample) in str(terminal.get_text(false).get("text", "")),
		)
		if arrived:
			latencies.append((Time.get_ticks_usec() - started) / 1000.0)
	expect(latencies.size() == 8, "Every latency probe round-trips without dropped input")
	latencies.sort()
	if not latencies.is_empty():
		print(
			"REMOTE_PERF p50_ms=%.1f p95_ms=%.1f bytes=%d"
			% [
				latencies[latencies.size() / 2],
				latencies[-1],
				client.connection.stats.bytes - bytes_before,
			]
		)
	var before_ids: Array = client.host.sessions.keys()
	client.host.create_session()
	expect(
		await until(
			func():
				return client.host.sessions.size() == before_ids.size() + 1,
		),
		"Normal New Tab creates a server session",
	)
	var added := -1
	for id in client.host.sessions:
		if id not in before_ids:
			added = id
	if added >= 0:
		client.host._close_terminal_pane(added)
		expect(
			await until(
				func():
					return not client.host.sessions.has(added),
			),
			"Normal Close Pane removes the shared session (client=%s server=%s removed=%d)"
			% [
				client.host.sessions.keys(),
				client.connection.topology.panes.map(
					func(p):
						return int(p.id),
				),
				added,
			],
		)
	client.host.focus_pane("%%%d" % target)
	var bad = load("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(bad)
	bad.connect_remote(client.connection.url, "wrong-token")
	expect(
		await until(
			func():
				return not bad.enabled,
		),
		"Invalid credentials are rejected",
	)
	expect(
		bad.frames.is_empty() and bad.topology.tabs.is_empty(),
		"Unauthenticated client receives no terminal state",
	)
	bad.queue_free()
	finish()


func finish() -> void:
	failures.append_array(diagnostic_guard.failures)
	result = {"failures": failures, "target": target}
	if observer != null: observer.disconnect_remote()
	client.connection.disconnect_remote()
	quit(0 if failures.is_empty() else 1)
