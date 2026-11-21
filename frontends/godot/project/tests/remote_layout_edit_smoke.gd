extends "../../../../tests/llm-e2e/replay/replay.gd"
const Layout = preload("res://scenes/WorkspaceLayout.gd")
class Transport extends Node:
	var topology := {"host_os": "macOS"}

func owner_edit(tab: int, layout: Dictionary) -> Dictionary:
	var connection: Node = host.session_backend.connection
	var state: Dictionary = connection.topology.workspace_state
	return await connection.request_action("workspace_edit", {"expected_revision": int(state.revision),
		"edit": {"op": "tab", "tab": tab, "layout": layout}})

func owner_layout(tab: int) -> Dictionary:
	return host.session_backend.connection.topology.workspace_state.layout.tabs[str(tab)].duplicate(true)

func play() -> void:
	var first: int = host.active_session_id
	var key := "%%%d" % first
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = true
	host.create_terminal_window(key, "h")
	await hold(.3)
	var second: int = host.active_session_id
	var second_key := "%%%d" % second
	var term: Control = host.sessions[first].term
	var old_columns: int = term.remote_snapshot().columns
	var focused: String = host.pane_focus
	var active: int = host.workspace_layout.active
	var tab := active
	var layout := owner_layout(tab)
	layout.enabled = false
	var response: Dictionary = await owner_edit(tab, layout)
	await hold(.2)
	check(response.type == "ack" and not host.workspace_layout.tab(tab).tree.tiling, "Client can disable shared owner tiling")
	layout = owner_layout(tab)
	layout.enabled = true
	response = await owner_edit(tab, layout)
	await hold(.2)
	check(response.type == "ack" and host.workspace_layout.tab(tab).tree.tiling, "Client tiling persists in authoritative layout")
	layout = owner_layout(tab)
	layout.tiles.children[0].weight = 2.0
	layout.tiles.children[1].weight = 1.0
	response = await owner_edit(tab, layout)
	await hold(.2)
	check(response.type == "ack" and host.workspace_layout.tab(tab).tree.tiles.children[0].weight == 2.0, "Remote divider resize persists owner proportions")
	check(host.workspace_view.pane_rects[key].size.x > host.workspace_view.pane_rects[second_key].size.x * 1.7, "Godot renders owner divider proportions")
	layout = owner_layout(tab)
	layout.tiles.children[1].pane = "%999999"
	response = await owner_edit(tab, layout)
	check(response.type == "error" and owner_layout(tab).tiles.children[1].pane == second_key, "Stale divider request cannot replace panes")
	var rect: Rect2 = host.workspace_view.pane_rects[second_key]
	rect.position.x = host.workspace_view.content_rect().end.x + 100
	layout = owner_layout(tab)
	for item in layout.windows:
		if item.key == second_key:
			item.rect = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
			item.stashed = true
	layout.tiles = {"pane": key}
	response = await owner_edit(tab, layout)
	await hold(.3)
	check(response.type == "ack", "Owner accepts client pane move")
	check(Layout.find(host.workspace_layout.tab(tab).tree, second_key).stashed, "Moved pane is stashed in owner state")
	check(term.remote_snapshot().columns > old_columns * 1.7, "Remaining terminal grid expands with layout")
	check(host.pane_focus == focused and host.workspace_layout.active == active, "Remote move preserves desktop focus")
	var connection: Node = host.session_backend.connection
	for id in [first, second]:
		response = await connection.remote_call(id, "agent.event", {"provider": "adapter", "event": "SessionStart", "integrated": true})
		check(not response.has("error"), "Adapter starts: " + JSON.stringify(response))
	response = await connection.remote_call(first, "agent.register", {"inputs": [], "outputs": [{"id": "out"}]})
	check(not response.has("error"), "Source advertises its output port: " + JSON.stringify(response))
	response = await connection.remote_call(second, "agent.register", {"inputs": [{"id": "in"}], "outputs": []})
	check(not response.has("error"), "Target advertises its input port: " + JSON.stringify(response))
	var params := {"from": key, "to": second_key, "from_port": "out", "to_port": "in", "send": true}
	response = await connection.remote_call(first, "graph.connect", params)
	check(not response.has("error"), "Client node connection reaches owner graph: " + JSON.stringify(response))
	response = await connection.remote_call(first, "graph.disconnect", params)
	check(not response.has("error"), "Client node disconnection reaches owner graph")
	var pane: Control = host.workspace_view.panes[key]
	pane.header.set_hovered(true)
	pane.set_compact_header(true)
	check(not pane.header.has_part("split_right") and not pane.header.has_part("filetree"), "Hidden icons release title layout space")
	pane.refresh()
	check(not pane.header.has_part("split_right"), "Refresh keeps compact icons hidden")
	pane.set_compact_header(false)
	await process_frame
	check(pane.header.has_part("split_right"), "Icons return when header expands")
	var transport := Transport.new()
	app.add_child(transport)
	var bar = preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.host = host
	bar.connection = transport
	app.add_child(bar)
	bar.show()
	bar.update_host()
	check(not bar.buttons.has("meta") and bar.buttons.alt.text == "Alt" and bar.buttons.has("escape"), "Android keys follow client conventions even for a Mac host")
	bar.buttons.ctrl.button_pressed = true
	var key_event := InputEventKey.new()
	key_event.pressed = true
	key_event.unicode = 99
	bar.apply_modifiers(key_event)
	check(key_event.ctrl_pressed and key_event.keycode == KEY_C, "Accessory Ctrl applies to soft keyboard text")
	check(not bar.buttons.ctrl.button_pressed, "Modifier resets after one key")
	var repeat := InputEventKey.new()
	repeat.pressed = true
	repeat.echo = true
	repeat.keycode = KEY_C
	bar.apply_modifiers(repeat)
	check(repeat.ctrl_pressed, "One-shot modifier survives key repeat")
	var release := InputEventKey.new()
	release.keycode = KEY_C
	bar.apply_modifiers(release)
	check(release.ctrl_pressed and bar.pressed_keys.is_empty(), "Key release retains modifier and clears held state")
	var next_key := InputEventKey.new()
	next_key.keycode = KEY_C
	next_key.pressed = true
	bar.apply_modifiers(next_key)
	check(not next_key.ctrl_pressed, "Following key does not inherit one-shot Ctrl")
	bar.buttons.ctrl.button_pressed = true
	var ime_press := InputEventKey.new()
	ime_press.pressed = true
	ime_press.unicode = 120
	bar.apply_modifiers(ime_press)
	var ime_next := InputEventKey.new()
	ime_next.pressed = true
	ime_next.unicode = 120
	bar.apply_modifiers(ime_next)
	check(not ime_next.ctrl_pressed, "IME without key-up cannot leave Ctrl stuck on repeated text")
	for platform in ["windows", "linux"]:
		transport.topology.host_os = platform
		bar.update_host()
		check(not bar.buttons.has("meta") and bar.buttons.alt.text == "Alt" and bar.buttons.alt.icon == null, platform + " host uses the same Android keys")
	bar.queue_free()
	transport.queue_free()
