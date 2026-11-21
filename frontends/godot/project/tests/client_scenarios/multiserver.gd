extends "res://tests/client_scenarios/scenario.gd"
var manager: Node


func _ready() -> void:
	run.call_deferred()


func expect(value: bool, message: String) -> void:
	checks.append(message)
	print("[headless client] %s %s" % ["PASS" if value else "FAIL", message])
	if not value:
		failures.append(message)


func until(condition: Callable, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await create_timer(.025).timeout
	return condition.call()


func terminal(id: int) -> Node:
	return manager.view.host.sessions[id].term


## Terminal text without line breaks: a phone pane can be only a few columns
## wide, and soft wraps split the markers these checks look for.
func text(id: int, scrollback := false) -> String:
	return str(terminal(id).get_text(scrollback).get("text", "")).replace("\n", "")


func select(transport: Node) -> void:
	manager.view.host.select_workspace(int(transport.topology.tabs[0].id), true)


func remote_swipe(fraction: float, release_delay := 0.0) -> void:
	var area: Rect2 = manager.view.host.layout_root.get_global_rect()
	var workspace: Control = manager.view.host.workspace_view
	var center: Vector2 = workspace.get_global_transform_with_canvas() * workspace.workspace_region().rect().get_center()
	for finger in range(3):
		var down := InputEventScreenTouch.new()
		down.index = finger
		down.pressed = true
		down.position = root.get_final_transform() * (center + Vector2(0, (finger - 1) * 28))
		Input.parse_input_event(down)
		await create_timer(.02).timeout
	for step in range(1, 9):
		for finger in range(3):
			var drag := InputEventScreenDrag.new()
			drag.index = finger
			drag.position = root.get_final_transform() * (center + Vector2(area.size.x * fraction * step / 8.0, (finger - 1) * 28))
			Input.parse_input_event(drag)
		await create_timer(.025).timeout
	if release_delay > 0: await create_timer(release_delay).timeout
	for finger in range(3):
		var up := InputEventScreenTouch.new()
		up.index = finger
		up.position = root.get_final_transform() * (center + Vector2(area.size.x * fraction, (finger - 1) * 28))
		Input.parse_input_event(up)
	await create_timer(.35).timeout

func check_remote_swipes(a: Node, b: Node, c: Node) -> void:
	select(a)
	await create_timer(.2).timeout
	await remote_swipe(-.35)
	expect(manager.federation.owners.get(manager.view.host.workspace_layout.active) == b, "Three-finger left swipe selects the next connected remote")
	await remote_swipe(.35)
	expect(manager.federation.owners.get(manager.view.host.workspace_layout.active) == a, "Three-finger right swipe returns to the previous remote")
	await remote_swipe(-.04, .2)
	expect(manager.federation.owners.get(manager.view.host.workspace_layout.active) == a, "Short swipe restores the original remote")
	select(c)
	await create_timer(.2).timeout
	await remote_swipe(-.35)
	expect(manager.federation.owners.get(manager.view.host.workspace_layout.active) == c, "Last remote resists without wrapping")
	expect(manager.view.host.layout_root.position == Vector2.ZERO, "Settling removes the desktop translation")

func check_sessions_dialog(a: Node, b: Node, c: Node) -> void:
	var host: Node = manager.view.host
	preload("res://scenes/HostActions.gd").run(host, "AllSessions")
	await get_tree().process_frame
	var dialog: Window = preload("res://scenes/session/SessionsDialog.gd").find(host)
	host.application.mods._publish_sessions()
	var live: Array = host.application.mods.get_meta(&"session_groups", []).filter(func(group): return group.connected)
	expect(live.size() == 3, "Sessions groups attached sessions by their three server addresses")
	for peer in [b, c, a]:
		var group: Dictionary = live.filter(func(item): return item.id == peer.url)[0]
		var row: Dictionary = group.sessions.filter(func(item): return item.id == peer.workspace)[0]
		host.application.mods.run(host, "SelectSession", {"server": group.id, "session": row.id}, dialog)
		await get_tree().process_frame
		expect(manager.federation.owners.get(host.workspace_layout.active) == peer, "Session selection focuses its owning remote")
		expect(dialog._desktop.is_visible_in_tree(), "Sessions stays open after selecting a remote")
	dialog._close_panel()
	await get_tree().process_frame

func run() -> void:
	manager = load("res://scenes/remote_manager.tscn").instantiate()
	root.add_child(manager)
	# A multi-server fixture is a list of connection requests, not the single
	# saved connection document consumed by the ordinary startup path.
	for connection in settings.get("connections", []): manager.open_connection(connection)
	expect(
		await until(
			func():
				return (
					manager.federation.connections.size() == 3
					and manager.federation
					.connections
					.all(
						func(v):
							return v.connected and v.server_fonts.ready and not v.topology.panes.is_empty(),
					)
					and manager.view.host != null
				),
			FIRST_CONNECTION_SECONDS,
		),
		"Three simultaneous connections in one native workspace",
	)
	if manager.view.host == null:
		finish()
		return
	manager._return_to_workspace()
	var host: Node = manager.view.host
	var a: Node = manager.federation.connections[0]
	var b: Node = manager.federation.connections[1]
	var c: Node = manager.federation.connections[2]
	var ids: Array = manager.federation.connections.map(
		func(v):
			return int(v.topology.panes[0].id),
	)
	expect(
		ids[0] != ids[1] and ids[0] != ids[2] and ids[1] != ids[2],
		"Colliding wire IDs have distinct application identities",
	)
	expect(host.workspace_layout.tabs.size() == 3, "All server tabs share the ordinary tab bar")
	await check_sessions_dialog(a, b, c)
	for index in range(ids.size()):
		var id: int = ids[index]
		var owner_pane: Dictionary = manager.federation.connections[index].topology.panes[0]
		var owner_pid := int(owner_pane.pid)
		# Inactive tabs defer loading their font resources. Activate each real
		# workspace before verifying its server-specific rendering geometry.
		select(manager.federation.connections[index])
		var fonts_ready := func(): return terminal(id).get_live_font_size() == int(owner_pane.font_size) and terminal(id).get_cell_size() == Vector2(owner_pane.font_metrics.width, owner_pane.font_metrics.height)
		expect(await until(fonts_ready),
			"Federated pane uses its own server's font and cell metrics")
		expect(
			terminal(id).remote_mode and owner_pid > 0 and terminal(id).get_shell_pid() == owner_pid,
			"Client mirrors the existing server shell identity without spawning a local shell",
		)
	if host.workspace_view.mobile_pointer != null and DisplayServer.get_name() != "headless":
		await check_remote_swipes(a, b, c)
	select(a)
	expect(
		await until(
			func():
				return terminal(ids[0]).image_placements().any(
					func(p):
						return p.image_id == 9001,
				),
		),
		"First attachment fetches pre-existing image pixels and placement",
	)
	for i in range(3):
		select(manager.federation.connections[i])
		terminal(ids[i]).send_text("printf 'CLIENT_%d_한글\\n'\r" % i)
		expect(
			await until(
				func():
					return "CLIENT_%d_한글" % i in text(ids[i]),
			),
			"Native Unicode renderer and input on computer %d" % i,
		)
	expect(not "CLIENT_1_한글" in text(ids[0]), "Input and output remain isolated")
	select(a)
	host.create_session()
	expect(
		await until(
			func():
				return a.topology.tabs.size() == 2 and host.workspace_layout.tabs.size() == 4,
		),
		"Shared UI creates a tab on the selected server",
	)
	expect(
		b.topology.tabs.size() == 1 and c.topology.tabs.size() == 1,
		"Other server workspaces remain unchanged",
	)
	var opened: int = host.active_session_id
	host._close_terminal_pane(opened)
	expect(
		await until(
			func():
				return a.topology.tabs.size() == 1 and host.workspace_layout.tabs.size() == 3,
		),
		"Shared UI closes only the requested server tab",
	)
	select(a)
	# Selecting the surviving tab claims its main-area size asynchronously.
	# Finish that owner edit before testing a subsequent explicit grid resize.
	await get_tree().process_frame
	expect(await host.session_backend.flush_workspace(host, ids[0]), "Tab selection finishes its owner layout claim before resize")
	var other_grid: Vector2i = terminal(ids[1]).get_grid_size()
	a.send_action("resize", ids[0], { "columns": 70, "rows": 20 })
	expect(
		await until(
			func():
				return terminal(ids[0]).get_grid_size() == Vector2i(70, 20),
		),
		"Shared authoritative grid resize",
	)
	expect(
		terminal(ids[1]).get_grid_size() == other_grid,
		"Resize does not affect another workspace",
	)
	terminal(ids[0]).send_text(
		"printf '\\033_Ga=T,f=32,s=2,v=1,i=9002,p=1,c=4,r=2,q=2;/wAA/wD/AP8=\\033\\\\'\r"
	)
	expect(
		await until(
			func():
				return terminal(ids[0]).image_placements().any(
					func(p):
						return p.image_id == 9002,
				),
		),
		"Live image uses the native renderer",
	)
	terminal(ids[0]).send_text(
		r"""python3 -c 'import base64,tempfile; p=tempfile.mkstemp(prefix="tty-graphics-protocol-")[1]; open(p,"wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")); print("\x1b_Ga=T,t=t,f=100,i=9003,p=1,c=4,r=2,q=2;"+base64.b64encode(p.encode()).decode()+"\x1b\\",end="",flush=True)'"""
		+ "\r"
	)
	expect(
		await until(
			func():
				return terminal(ids[0]).image_placements().any(
					func(p):
						return p.image_id == 9003,
				),
		),
		"Live server file is resolved to pixels without client filesystem access",
	)
	a.disconnect_remote()
	terminal(ids[0]).remote_feed_stream(PackedByteArray(), 70, 20, true, false)
	expect(
		await until(func(): return terminal(ids[0]).image_placements().is_empty()),
		"Discarded client state contains no cached image",
	)
	select(b)
	terminal(ids[1]).send_text("printf 'STILL_CONNECTED\\n'\r")
	expect(
		await until(
			func():
				return "STILL_CONNECTED" in text(ids[1]),
		),
		"Disconnecting one computer does not interrupt another",
	)
	a.connect_remote(a.url, a.token)
	expect(
		await until(
			func():
				return a.connected,
		),
		"Independent reconnect",
	)
	select(a)
	expect(
		await until(
			func():
				return "CLIENT_0_한글" in text(ids[0]),
		),
		"Reconnect preserves the server shell",
	)
	expect(
		await until(
			func():
				return terminal(ids[0]).image_placements().any(
					func(p):
						return p.image_id == 9002,
				),
		),
		"Reconnect restores image after discarding client state",
	)
	terminal(ids[0]).send_text("printf '\\033_Ga=d,d=I,i=9002,q=2\\033\\\\'\r")
	expect(
		await until(
			func():
				return not terminal(ids[0]).image_placements().any(
					func(p):
						return p.image_id == 9002,
				),
		),
		"Image deletion after reconnect uses the original ID",
	)
	# Scrollback is restored into the same native VT used for local selection.
	terminal(ids[0]).send_text(
		"i=0; while [ $i -lt 180 ]; do printf 'HISTORY_%03d 한글\\n' $i; i=$((i+1)); done\r"
	)
	expect(
		await until(
			func():
				return "HISTORY_179" in text(ids[0]),
		),
		"Live VT stream advances through real scrollback",
	)
	expect(
		"HISTORY_000" in text(ids[0], true),
		"Client retains selectable history beyond the visible screen",
	)
	# Use the real CLI inside the authoritative PTY, with its pane capability.
	terminal(ids[0]).send_text(
		"\"$GRAFFITTY_BIN\" rpc agent.event --params '{\"provider\":\"adapter\",\"event\":\"SessionStart\",\"pid\":123}' && \"$GRAFFITTY_BIN\" rpc agent.register --params '{\"name\":\"Remote test node\",\"inputs\":[{\"id\":\"in\"}],\"outputs\":[{\"id\":\"out\"}]}'\r"
	)
	var current_tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var leaf := preload("res://scenes/WorkspaceLayout.gd").find(
		current_tab.tree,
		"%%%d" % ids[0],
	)
	var placed: Rect2 = leaf.rect
	placed.position = Vector2(430, 180)
	leaf.rect = placed
	host.session_backend.move_pane(host, "%%%d" % ids[0], Vector2.INF)
	a.send_action("resize", ids[0], { "columns": 72, "rows": 20 })
	expect(
		await until(
			func():
				return terminal(ids[0]).get_grid_size() == Vector2i(72, 20),
		),
		"Server topology updates the shared grid",
	)
	var retained := preload("res://scenes/WorkspaceLayout.gd").find(
		host.workspace_layout.tab(host.workspace_layout.active).tree,
		"%%%d" % ids[0],
	)
	expect(
		(retained.rect as Rect2).position == placed.position,
		"Topology updates preserve client pane placement",
	)
	var graph: Node = host.application.agent_api.graph
	var key := "%%%d" % ids[0]
	expect(
		await until(
			func():
				return graph.nodes.get(key, { }).get("manifest", { }).get("name") == "Remote test node",
		),
		"Headless pane CLI registers ports in the shared graph UI",
	)
	var result: Dictionary = await a.remote_call(ids[0], "graph.list", { })
	expect(
		result.has("result") and result.result.nodes.size() == 1,
		"Graph RPC is scoped to its server workspace",
	)
	var denied: Dictionary = await a.remote_call(
		ids[0],
		"graph.connect",
		{ "from": key, "to": "%%%d" % ids[1], "from_port": "out", "to_port": "in" },
	)
	expect(denied.has("error"), "Graph connections cannot cross workspace authority")
	if OS.get_environment("GRAFFITTY_TEST_NO_CHROMIUM") != "1":
		var opened_chromium: Dictionary = await host.session_backend.create_chromium_remote(
			host,
			ids[0],
			"about:blank",
			true,
			null,
		)
		expect(opened_chromium.has("result"), "Server launches headless Chromium")
		var chromium_id := int(
			str(opened_chromium.get("result", { }).get("chromium", "%-1")).substr(1)
		)
		if host.chromiums.has(chromium_id):
			var chromium: Node = host.chromiums[chromium_id]
			expect(
				await until(
					func():
						return chromium.chromium_ready,
				),
				"Remote Chromium uses the ordinary chromium chrome",
			)
			var evaluated: Dictionary = await chromium.request(
				"cdp",
				{
					"method": "Runtime.evaluate",
					"params": {
						"expression": "document.body.innerHTML='<h1>Remote 한글</h1><input id=field>'; window.remoteState=42; 42",
						"returnByValue": true,
					},
				},
			)
			expect(
				evaluated.get("result", { }).get("result", { }).get("value") == 42,
				"Chromium automation runs on the server: " + JSON.stringify(evaluated),
			)
			expect(
				await until(
					func():
						return chromium.texture != null and chromium.frames > 0,
				),
				"Server chromium preview reaches the same native pane",
			)
		select(a)
		terminal(ids[0]).send_text(
			"\"$GRAFFITTY_BIN\" chromium eval --target %%%d --expression 'window.remoteState=43; 43' && printf 'CHROMIUM_%%s_OK\\n' CLI\r"
			% a.wire_id(chromium_id)
		)
		expect(
			await until(
				func():
					return "CHROMIUM_CLI_OK" in text(ids[0]),
			),
			"Chromium CLI executes through the headless pane capability",
		)

	var settings := { "url": a.url, "token": a.token, "workspace": a.workspace, "name": "Restored" }
	manager.federation.remove(a)
	manager.federation.connections.erase(a)
	await get_tree().process_frame
	expect(host.workspace_layout.tabs.size() == 2, "Detaching removes only that connection's tabs")
	var restored: Node = manager.open_connection(settings)
	expect(
		await until(
			func():
				return restored.connected and not restored.topology.panes.is_empty(),
		),
		"Detached workspace can be attached again",
	)
	select(restored)
	var restored_id := int(restored.topology.panes[0].id)
	expect(
		await until(
			func():
				return "HISTORY_000" in text(restored_id, true),
		),
		"Detach preserves server terminal contents",
	)
	var restored_chromium_id := -1
	# Chromium IDs are independently namespaced after reattachment.
	if not restored.topology.get("chromiums", []).is_empty():
		restored_chromium_id = int(restored.topology.chromiums[0].id)
		var chromium: Node = host.chromiums[restored_chromium_id]
		expect(
			await until(
				func():
					return chromium.chromium_ready,
			),
			"Chromium survives client detach",
		)
		var value: Dictionary = await chromium.request(
			"cdp",
			{
				"method": "Runtime.evaluate",
				"params": { "expression": "window.remoteState", "returnByValue": true },
			},
		)
		expect(
			value.get("result", { }).get("result", { }).get("value") == 43,
			"Chromium JavaScript state remains on server across clients: " + JSON.stringify(value),
		)
		host.close_chromium_session(restored_chromium_id)
		expect(
			await until(
				func():
					return not host.chromiums.has(restored_chromium_id),
			),
			"Explicit chromium close terminates the server chromium",
		)
	finish()


func finish() -> void:
	print(
		"HEADLESS REMOTE PASS" if failures.is_empty() else "HEADLESS REMOTE FAIL: " + str(failures)
	)
	# Keep the Android result visible for the recorder and final screenshot.
	if not OS.has_feature("android"): manager.queue_free()
	await get_tree().process_frame
	quit(0 if failures.is_empty() else 1)
