extends "../../tabs-and-panes/replays/main-area-tiling.gd"
var owner_config := ""
var connection: Node
var group: Array[String] = []
var terminal_pids := {}
var chromium_pids := {}
var chromium_urls := {}
var owner: int
var source_tab: int
var target_tab: int
var unrelated: String
var resident: String
var topology_edges: Array = []

func _initialize() -> void:
	owner_config = OS.get_environment("XDG_CONFIG_HOME")
	super._initialize()

func rpc(id: int, method: String, params: Dictionary = {}) -> Dictionary:
	var reply: Dictionary = await connection.remote_call(id, method, params)
	check(not reply.has("error"), method + " succeeds: " + str(reply.get("error", "")))
	return reply.get("result", {}) if reply.get("result") is Dictionary else {}

func chromium_state(key: String) -> Dictionary:
	var request := await rpc(owner, "chromium.command", {"chromium": key, "action": "chrome-state", "args": {}})
	if not request.has("ticket"): return {}
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var reply: Dictionary = await connection.remote_call(owner, "chromium.result", {"chromium": key, "ticket": int(request.ticket)})
		if reply.has("error"):
			check(false, "Chromium command failed: " + str(reply.error))
			return {}
		if reply.get("result") is Dictionary: return reply.result.get("result", {})
		await process_frame
	check(false, "Chromium responds without restarting: " + key)
	return {}

func tab_index_for(id: int) -> int:
	for i in host.get_tabs().size():
		if int(host.get_tabs()[i].id) == id: return i
	return -1

func invariant(label: String) -> void:
	await connection.request_action("sync", {})
	await owner_at_rest()
	for edge: Dictionary in app.pane_transfer_connections(host):
		var from: int = host.workspace_layout.containing(edge.from)
		var to: int = host.workspace_layout.containing(edge.to)
		check(from >= 0 and from == to, label + ": every connection is tab-local " + str(edge))
	var current: Array = app.pane_transfer_connections(host)
	check(current.size() == topology_edges.size(), label + ": no connection lost")
	for edge: Dictionary in topology_edges:
		check(current.any(func(value): return value.from == edge.from and value.to == edge.to and value.get("kind", "graph") == edge.get("kind", "graph")), label + ": ownership endpoints unchanged")
	for key in terminal_pids:
		check(host.sessions[int(key.substr(1))].term.get_shell_pid() == terminal_pids[key], label + ": terminal/editor PID survives " + key)
	for key in chromium_pids:
		var state := await chromium_state(key)
		check(state.get("pid") == chromium_pids[key], label + ": chromium PID survives " + key)
		var urls: Array = state.get("tabs", []).map(func(tab): return tab.get("url", ""))
		for url in chromium_urls[key]: check(url in urls, label + ": chromium page survives " + str(url))
	check(host.workspace_layout.containing(unrelated) == source_tab and host.workspace_layout.containing(resident) == target_tab, label + ": unrelated panes stay behind")

func move_member(key: String, destination: int, label: String, cancel := false) -> void:
	await say(label)
	host.focus_pane(key)
	await camera_at_rest()
	# Frame the complete component before taking the pointer-down baseline;
	# equivalent to zooming/panning until every connected header is reachable.
	var view: Control = host.workspace_view
	var bounds: Rect2 = view.pane_rects[group[0]]
	for member in group: bounds = bounds.merge(view.pane_rects[member])
	view._begin_navigation()
	view.navigation_center = bounds.get_center()
	view.navigation_zoom = minf(0.4, minf(view.size.x / bounds.size.x, view.size.y / bounds.size.y) * 0.7)
	view._apply_navigation()
	view.save_navigation()
	await hold(0.2)
	var before: Dictionary = host.workspace_view.pane_rects.duplicate(true)
	var previous: int = host.workspace_layout.containing(key)
	await point_at(on(host.workspace_view.panes[key].handle))
	await press()
	await point_at(overlay.pointer + Vector2(20, 10), 0.3)
	await point_at(on(tab_button(tab_index_for(destination))), 0.8)
	await hold(1.0)
	await point_at(content(Vector2(0.52, 0.42)), 0.7)
	await hold(0.3)
	var plan: Dictionary = host.workspace_view.preview_plan
	check(plan.get("incoming", []).size() == group.size(), label + ": every connected surface is previewed")
	check(host.workspace_view.layout_preview.connections.size() == topology_edges.size(), label + ": every ownership and graph wire is previewed")
	if not plan.get("rectangles", {}).has(key):
		await release()
		return
	var expected: Dictionary = plan.rectangles.duplicate(true)
	var delta: Vector2 = expected[key].position - before[key].position
	for member in group:
		check(expected.has(member), label + ": preview includes " + member)
		if not expected.has(member): continue
		check((expected[member].position - before[member].position).is_equal_approx(delta) and expected[member].size.is_equal_approx(before[member].size), label + ": pre-drag geometry preserved " + member)
	await hold(0.6)
	if cancel: await keys("escape")
	await release()
	await owner_at_rest()
	if cancel: await select_tab(tab_index_for(previous))
	await hold(0.4)
	for member in group:
		check(host.workspace_layout.containing(member) == (previous if cancel else destination), label + ": whole group remains together " + member)
		check(host.workspace_view.pane_rects.get(member, Rect2()).is_equal_approx(before[member] if cancel else expected.get(member, Rect2())), label + ": final rectangle matches " + member)
	await invariant(label)

func play() -> void:
	await say("Prepare real connected surfaces")
	connection = host.session_backend.connection
	owner = host.active_session_id
	source_tab = host.workspace_layout.active
	var key := "%%%d" % owner
	# Real Neovim with its built-in explorer: the adapter's custom [filetree] command
	# uses this isolated NVIM_APPNAME, with no personal config or downloads.
	var config := owner_config.path_join("nvim-e2e-filetree")
	DirAccess.make_dir_recursive_absolute(config)
	var init := FileAccess.open(config.path_join("init.lua"), FileAccess.WRITE)
	init.store_string("vim.opt.swapfile=false\nvim.cmd('Explore')\n")
	init.close()
	var file := OS.get_environment("XDG_STATE_HOME").path_join("connected-surfaces.txt")
	var text := FileAccess.open(file, FileAccess.WRITE)
	text.store_string("Connected editor keeps this buffer and process.\n")
	text.close()
	var html := file + ".html"
	text = FileAccess.open(html, FileAccess.WRITE)
	text.store_string("<!doctype html><title>Connected preview</title><p>Live preview</p>")
	text.close()
	var tree := await rpc(owner, "filetree.toggle", {})
	if not tree.has("pane"): return
	var tree_id := int(str(tree.pane).substr(1))
	var editor := await rpc(tree_id, "filetree.open_file", {"path": file})
	var preview := await rpc(tree_id, "filetree.open_file", {"path": html})
	var chromium := await rpc(owner, "chromium.create", {"url": "about:blank"})
	if not editor.has("pane") or not preview.has("pane") or not chromium.has("pane"): return
	var peer: Dictionary = await connection.request_action("create", {"kind": "pane", "session": owner})
	var spare: Dictionary = await connection.request_action("create", {"kind": "pane", "session": owner})
	unrelated = "%%%d" % int(spare.created)
	var destination: Dictionary = await connection.request_action("create", {"kind": "tab"})
	target_tab = int(destination.created)
	resident = "%%%d" % target_tab
	group.assign([key, tree.pane, editor.pane, preview.pane, chromium.pane, "%%%d" % int(peer.created)])
	await owner_at_rest()
	for member in [editor.pane, group[-1]]:
		var id := int(str(member).substr(1))
		await rpc(id, "agent.event", {"provider": "adapter", "event": "SessionStart"})
		await rpc(id, "agent.register", {"inputs": [{"id": "in"}], "outputs": [{"id": "out"}]})
	await rpc(owner, "graph.connect", {"from": group[-1], "to": editor.pane, "from_port": "out", "to_port": "in", "muted": true})
	await connection.request_action("sync", {})
	await owner_at_rest()
	topology_edges = app.pane_transfer_connections(host).duplicate(true)
	check(topology_edges.size() == 5, "Fixture has chromium, filetree, editor and paused graph connections")
	for member in group:
		if member in [chromium.pane, preview.pane]:
			var state := await chromium_state(member)
			chromium_pids[member] = state.get("pid", -1)
			chromium_urls[member] = state.get("tabs", []).map(func(tab): return tab.get("url", ""))
			check(chromium_pids[member] != -1, "Real chromium process is running")
			check(await host.set_pane_title(member, "Named Chromium " + member), "Chromium rename is acknowledged by its owner")
			await connection.request_action("sync", {})
			await owner_at_rest()
			check(host.chromiums[int(member.substr(1))].title == "Named Chromium " + member, "Chromium name survives owner topology refresh")
		else: terminal_pids[member] = host.sessions[int(member.substr(1))].term.get_shell_pid()
	for tab in [source_tab, target_tab]:
		await select_tab(tab_index_for(tab))
		var layout: Dictionary = host.workspace_layout.tab(tab).tree
		layout.tiling = false
		layout.physics = false
		if tab == source_tab:
			for i in group.size(): Layout.find(layout, group[i]).rect = Rect2(30 + (i % 3) * 410, 80 + floori(float(i) / 3.0) * 310, 340 + i * 5, 230 + i * 4)
		host.workspace_view.refresh()
		host.session_backend.commit_workspace(host)
		await owner_at_rest()
		await pinch_overview()
	await select_tab(tab_index_for(source_tab))
	await invariant("Before drag")
	await move_member(chromium.pane, target_tab, "Move from the chromium")
	await move_member(tree.pane, source_tab, "Move from the filetree")
	await move_member(editor.pane, target_tab, "Move from the opened Neovim")
	await move_member(preview.pane, source_tab, "Move from the preview chromium")
	await move_member(key, target_tab, "Move from the owner")
	await move_member(group[-1], source_tab, "Cancel a mixed group move", true)
	var reused := await rpc(tree_id, "filetree.open_file", {"path": file})
	check(reused.get("pane") == editor.pane and reused.get("created") == false, "Filetree still reuses its original live editor after transfers")
	var reused_chromium := await rpc(tree_id, "filetree.open_file", {"path": html})
	check(reused_chromium.get("pane") == preview.pane, "Filetree still reuses its original chromium after transfers")
	var denied: Dictionary = await connection.remote_call(owner, "graph.connect", {"from": group[-1], "to": unrelated, "from_port": "out", "to_port": "in"})
	check(denied.has("error"), "Cross-tab graph request is rejected after mixed transfers")
	await invariant("After reuse and rejection")
