extends Node
## Version-1 checkpoint import/export translates presentations into owner actions.
## The Checkpoints menu lists saved history directly, like tmux-restore-agents.
signal history_changed
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Badge := preload("res://scenes/AgentStatusBadge.gd")
const HISTORY_REFRESH_SECONDS := 60.0
var application: Node
## Saved checkpoints per tag, newest first: {path, saved_at, windows, tabs, panes}.
var history: Dictionary = {"manual": [], "auto": []}
var _history_worker: Thread
var _history_labels := ""
var _history_clock := Timer.new()
var document: Dictionary = { }
var importing := false
var restored_ids: Dictionary = {}
var restored_tabs: Dictionary = {}
var startup_loaded := false
var worker: Thread
var busy := false
var capturing := false
## The last reason an import step failed, for the restore receipt.
var failure := ""


static func encode(value: Variant) -> Variant:
	if value is Vector2:
		return { "vec2": [value.x, value.y] }
	if value is Rect2:
		return { "rect2": [value.position.x, value.position.y, value.size.x, value.size.y] }
	if value is Dictionary:
		var result := { }
		for key in value:
			result[key] = encode(value[key])
		return result
	if value is Array:
		return value.map(encode)
	return value


static func saved_pane_key(value: String) -> String:
	var endpoints := value.split(">")
	for index in endpoints.size():
		var parts := endpoints[index].split("/")
		for prefix in ["terminal:", "chromium:"]:
			if parts[0].begins_with(prefix):
				var canonical: String = "%" + parts[0].substr(prefix.length())
				if preload("res://scenes/PaneTargets.gd").valid(canonical): parts[0] = canonical
		endpoints[index] = "/".join(parts)
	return ">".join(endpoints)


static func decode(value: Variant) -> Variant:
	if value is Dictionary:
		if value.has("vec2"):
			return Vector2(float(value.vec2[0]), float(value.vec2[1]))
		if value.has("rect2"):
			var r: Array = value.rect2
			return Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
		var result := { }
		for key in value:
			var item: Variant = value[key]
			# Upgrade old saved layouts only; live pane and graph APIs use %N.
			if key in ["pane", "focused", "physics_anchor"] and item is String:
				item = saved_pane_key(item)
			elif key == "routes" and item is Dictionary:
				var routes := {}
				for edge in item: routes[saved_pane_key(edge)] = item[edge]
				item = routes
			result[key] = decode(item)
		return result
	if value is Array:
		return value.map(decode)
	return value


func capture() -> Dictionary:
	if busy or capturing:
		return { "error": { "message": "Checkpoint action already in progress" } }
	capturing = true
	var response := await _capture_windows()
	capturing = false
	return response


func _capture_windows() -> Dictionary:
	var windows: Array = []
	for host in application.hosts.duplicate():
		if not is_instance_valid(host):
			return {"error": {"message": "Window closed while saving the checkpoint"}}
		var panes: Array = []
		# Unvisited terminal replicas need not contain an OSC 7 checkpoint yet.
		# Obtain process state from the owner, then add this frontend's presentation.
		var owned := {}
		var browsers := {}
		for definition in host.get_terminal_tabs():
			var id := int(definition.id)
			if not owned.has(id):
				# A native window can present tabs from several session owners.
				var checkpoint := await _ask_owner(host, id, owned, browsers)
				if checkpoint.has("error"):
					return checkpoint
			if not owned.has(id):
				return {"error": {"message": "Pane closed while saving the checkpoint"}}
			panes.append(owned[id].duplicate(true))
		# Only self-owned chromiums outlive every terminal of a window, and
		# restore reopens chromiums through one, so such a window is not saved.
		if panes.is_empty():
			continue
		# A chromium is saved as its pages and profile, not its page state.
		var chromiums: Array = []
		var terminals := {}
		for pane in panes:
			if not pane.has("filetree"):
				terminals[int(pane.id)] = true
		for tab in host.workspace_layout.tabs:
			for key in Layout.keys(tab.tree):
				var id := int(key.substr(1))
				if not host.chromiums.has(id):
					continue
				if not browsers.has(id):
					return {"error": {"message": "Pane closed while saving the checkpoint"}}
				var chromium: Dictionary = browsers[id].duplicate(true)
				# It reopens through its owner only when that terminal is saved here too.
				if chromium.get("owner") != null and not terminals.has(int(chromium.owner)):
					chromium.owner = null
				chromiums.append(chromium)
		var window: Window = host.get_window()
		windows.append(
			{
				"tabs": encode(host.workspace_layout.tabs),
				"panes": panes,
				"active": host.workspace_layout.active,
				"plugin": host.current_plugin,
				"position": [window.position.x, window.position.y],
				"size": [window.size.x, window.size.y],
				"mode": window.mode,
				"graph": graph_checkpoint(host.session_backend.connection.topology.get("graph", {}), panes),
				"chromiums": chromiums,
			}
		)
	if windows.is_empty():
		return { "error": { "message": "No terminal layout to save" } }
	return { "result": { "version": 1, "windows": windows } }


## A connection can be freed while a call waits on it, when its window closes
## or its session is killed.
##
## Godot then silently drops that call and every caller awaiting it, which
## would leave a save or restore waiting forever.
##
## So this long-lived node runs the call apart and stops waiting on a freed
## connection, answering `closed` instead.
func _guarded(connection: Node, call: Callable, closed: Dictionary) -> Dictionary:
	var state := {"done": false, "value": closed}
	var run := func():
		state.value = await call.call()
		state.done = true
	run.call()
	while not state.done:
		if not is_instance_valid(connection):
			return closed
		await get_tree().process_frame
	return state.value


func _remote(connection: Node, id: int, method: String, params: Dictionary) -> Dictionary:
	return await _guarded(connection, func(): return await connection.remote_call(id, method, params),
		{"error": {"code": "remote_error", "message": "Session connection closed"}})


## An owner checkpoint lists every pane and chromium of its session.
func _ask_owner(host: Node, id: int, owned: Dictionary, browsers: Dictionary) -> Dictionary:
	var checkpoint: Dictionary = await _remote(host.session_backend.connection,
		id, "session.capture", {"layout": true})
	if checkpoint.has("error"):
		return checkpoint
	if not is_instance_valid(host):
		return {"error": {"message": "Window closed while saving the checkpoint"}}
	for window in checkpoint.result.windows:
		for pane in window.panes:
			owned[int(pane.id)] = pane
		for chromium in window.chromiums:
			browsers[int(chromium.id)] = chromium
	return checkpoint


static func graph_checkpoint(graph: Dictionary, panes: Array) -> Dictionary:
	var keys: Array = panes.map(func(pane): return "%%%d" % int(pane.id))
	var nodes: Array = []
	for node in graph.get("nodes", []):
		if node.get("node") in keys:
			nodes.append({"node": node.node, "manifest": node.get("manifest", {"inputs": [], "outputs": []}).duplicate(true)})
	var edges: Array = graph.get("edges", []).filter(func(edge): return edge.from in keys and edge.to in keys).duplicate(true)
	for edge in edges: edge.erase("revision")
	# A stopped provider can lose its advertised ports while retaining its links.
	for node in nodes:
		for edge in edges:
			if edge.to == node.node and not node.manifest.inputs.any(func(port): return port.id == edge.to_port):
				node.manifest.inputs.append({"id": edge.to_port})
			if edge.from == node.node and not node.manifest.outputs.any(func(port): return port.id == edge.from_port):
				var mode := "turn_completed" if edge.get("turn_completed", false) else ("send" if edge.get("send", false) else "read")
				node.manifest.outputs.append({"id": edge.from_port, "mode": mode})
	return {"nodes": nodes, "edges": edges, "run_messages": int(graph.get("limits", {}).get("run_messages", 10000))}


func prepare_startup(host: Node) -> void:
	if startup_loaded:
		return
	startup_loaded = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--restore-checkpoint="):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--restore-checkpoint=")))
			if (
				not parsed is Dictionary or parsed.get("version") != 1
				or not parsed.get("windows") is Array or parsed.windows.is_empty()
				or not parsed.windows.all(func(window): return window is Dictionary and window.get("chromiums") is Array)
			):
				if parsed is Dictionary and parsed.get("receipt") is String:
					document = {"receipt": parsed.receipt}
				_abort_import("Invalid checkpoint")
				return
			document = parsed
			importing = true
			_import_shared.call_deferred(host)
			return


static func spawn_options(pane: Dictionary) -> Dictionary:
	var options := {}
	if not str(pane.get("cwd", "")).is_empty(): options.cwd = str(pane.cwd)
	if pane.has("restore_shell"):
		options.shell = str(pane.restore_shell)
		# Windows panes run PowerShell on their prepared script.
		if pane.get("restore_args") is Array:
			options.args = pane.restore_args.map(func(arg): return str(arg))
		options.login = false
		options.shell_integration = false
	return options

## The saved tab of every pane placed in one, by pane ID.
static func saved_tabs(saved_document: Dictionary) -> Dictionary:
	var tabs := {}
	for saved in saved_document.windows:
		for original in decode(saved.tabs):
			for key in Layout.keys(original.tree):
				tabs[int(str(key).substr(1))] = int(original.id)
	return tabs


## What a restored pane asks the server for so that `%N` still names it: its
## saved ID and, when it opens its tab, the tab's.
##
## The server keeps each one that nothing live has, and gives the others new
## IDs after `through`, the largest saved one.
##
## A checkpoint from outside the local history is only a layout, so its panes
## take new IDs.
static func saved_identity(saved_document: Dictionary, pane: Dictionary, opens_tab: bool) -> Dictionary:
	if not saved_document.get("keep_ids", false): return {}
	var identity := {"id": int(pane.id), "through": 0}
	for saved in saved_document.windows:
		for entry in saved.panes + saved.chromiums + saved.tabs:
			identity.through = maxi(identity.through, int(entry.id))
	var tab: Variant = saved_tabs(saved_document).get(int(pane.id))
	if opens_tab and tab != null: identity.tab = int(tab)
	return identity


func _tab_of(connection: Node, pane: int) -> int:
	for info in connection.topology.panes:
		if int(info.id) == pane: return int(info.tab)
	return -1


func _checked(connection: Node, kind: String, values: Dictionary) -> Dictionary:
	var response: Dictionary = await _guarded(connection, func(): return await connection.request_action(kind, values),
		{"type": "error", "message": "Session connection closed"})
	if response.get("type") == "error":
		failure = str(response.get("message", "Owner operation failed"))
		push_error("Checkpoint import: " + failure)
	return response


## A failed import reports its reason at once, instead of leaving the CLI
## waiting for a receipt that never arrives.
func _abort_import(message := "") -> void:
	if not message.is_empty():
		failure = message
		push_error("Checkpoint import: " + message)
	importing = false
	_receipt({"ok": false, "error": failure if not failure.is_empty() else "Checkpoint import failed"})
	document.clear()


func _receipt(result: Dictionary) -> void:
	if not document.has("receipt"):
		return
	var file := FileAccess.open(str(document.receipt), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(result))
		file.close()

func _import_shared(first: Node) -> void:
	var connection: Node = first.session_backend.connection
	var seed: int = first.active_session_id
	var initial := true
	var homes := saved_tabs(document)
	# The first restored pane of each saved tab; later ones open beside it.
	var openers := {}
	for saved in document.windows:
		for pane in saved.panes:
			if pane.has("filetree"): continue
			var id: int
			var home: Variant = homes.get(int(pane.id))
			if initial and first.get_parent().settings.get("restore_seed", false):
				id = seed
				if home != null: restored_tabs[home] = _tab_of(connection, seed)
			else:
				# Each pane opens in its own tab at once, under its saved IDs:
				# gathering single-pane tabs afterwards could not keep a tab's ID.
				var joins: bool = home != null and openers.has(home)
				var request := {"kind": "pane" if joins else "tab", "spawn": spawn_options(pane)}
				if joins: request.session = openers[home]
				request.merge(saved_identity(document, pane, not joins))
				var created := await _checked(connection, "create", request)
				if created.get("type") == "error": _abort_import(); return
				id = int(created.created)
				if not joins and home != null: restored_tabs[home] = int(created.tab)
			if home != null and not openers.has(home): openers[home] = id
			initial = false
			restored_ids[int(pane.id)] = id
			await _remote(connection, id, "window.set_title", {"title": str(pane.get("title", ""))})
			if pane.has("font_size"):
				await _checked(connection, "font_size", {"session": id, "size": int(pane.font_size), "remember": false})
	# Filetrees are fresh connected Neovim panes, opened only after their owners.
	for saved in document.windows:
		for pane in saved.panes:
			if not pane.has("filetree"): continue
			var owner := int(restored_ids[int(pane.filetree.owner)])
			var toggle := {"root": str(pane.filetree.root)}
			if document.get("keep_ids", false): toggle.pane_id = int(pane.id)
			var reply: Dictionary = await _remote(connection, owner, "filetree.toggle", toggle)
			if reply.has("error"):
				_abort_import(str(reply.error.get("message", "Filetree failed to open")))
				return
			var id := int(str(reply.result.pane).substr(1))
			restored_ids[int(pane.id)] = id
			await _remote(connection, id, "window.set_title", {"title": str(pane.get("title", ""))})
			if pane.has("font_size"):
				await _checked(connection, "font_size", {"session": id, "size": int(pane.font_size), "remember": false})
	await _checked(connection, "sync", {})
	# A chromium joins its owner's session, and a tab moves to another window
	# only together with its chromiums' owners.
	#
	# Chromiums therefore open once the windows have split; a window holding them
	# completes its tabs then.
	for saved in document.windows:
		for original in decode(saved.tabs):
			var keys: Array = Layout.keys(original.tree).filter(func(key): return restored_ids.has(int(key.substr(1))))
			if keys.is_empty(): continue
			var first_id := int(restored_ids[int(str(keys[0]).substr(1))])
			var id := _tab_of(connection, first_id)
			restored_tabs[int(original.id)] = id
			for key in keys.slice(1):
				var target := int(restored_ids[int(str(key).substr(1))])
				if _tab_of(connection, target) == id: continue
				var reply := await _checked(connection, "regroup", {"surface": "%%%d" % target, "tab": id})
				if reply.get("type") == "error": _abort_import(); return
			await _checked(connection, "sync", {})
			if saved.chromiums.is_empty() and not await _complete_tab(connection, first_id, saved, original):
				_abort_import(); return
	await _checked(connection, "sync", {})
	var order: Array = []
	for saved in document.windows:
		for tab in saved.tabs:
			if restored_tabs.has(int(tab.id)): order.append(int(restored_tabs[int(tab.id)]))
	var reordered := await _checked(connection, "workspace_edit", {"expected_revision": int(connection.topology.workspace_revision),
		"edit": {"op": "reorder", "tabs": order}})
	if reordered.get("type") == "error": _abort_import(); return
	await _checked(connection, "sync", {})
	var windows: Array = [first]
	for saved in document.windows.slice(1):
		var tabs: Array = []
		for tab in saved.tabs:
			if restored_tabs.has(int(tab.id)): tabs.append(int(restored_tabs[int(tab.id)]))
		var target: Node = await application.detach_workspace(first, tabs[0], Vector2i(int(saved.position[0]), int(saved.position[1])))
		if target == null: _abort_import("could not open a saved window"); return
		var deadline := Time.get_ticks_msec() + 10000
		while not target.session_backend.connection.connected and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		if not target.session_backend.connection.connected:
			_abort_import("detached window did not attach to the session owner")
			return
		for id in tabs.slice(1):
			if not await application.move_workspace(first, target, id):
				_abort_import("could not restore tab to its window")
				return
		windows.append(target)
	for i in windows.size():
		if not await _open_chromiums(windows[i].session_backend.connection, document.windows[i]):
			_abort_import(); return
	var ids := {}
	for old in restored_ids: ids["%%%d" % int(old)] = "%%%d" % int(restored_ids[old])
	for i in windows.size():
		var target: Node = windows[i]
		var saved: Dictionary = document.windows[i]
		var spawned: Array = []
		for pane in saved.panes:
			if pane.get("spawned_by") != null and restored_ids.has(int(pane.id)) and restored_ids.has(int(pane.spawned_by)):
				spawned.append({"pane": int(pane.id), "spawned_by": int(pane.spawned_by), "dies_with_parent": bool(pane.get("dies_with_parent", false))})
		if saved.has("graph") or not spawned.is_empty():
			var graph: Variant = saved.graph.duplicate(true) if saved.has("graph") else null
			if graph is Dictionary and graph.has("run_messages"): graph.run_messages = int(graph.run_messages)
			var reply := await _checked(target.session_backend.connection, "restore_graph", {"graph": graph, "ids": ids, "spawned": spawned})
			if reply.get("type") == "error": _abort_import(); return
		target.switch_world(str(saved.get("plugin", "")))
		# Navigation belongs to this frontend, not the owner's tiling schema.
		for tab in saved.tabs:
			if tab.has("navigation"):
				target.workspace_layout.tab(int(restored_tabs[int(tab.id)]))["navigation"] = tab.navigation.duplicate(true)
		target.select_workspace(int(restored_tabs[int(saved.active)]), true)
		var window: Window = target.get_window()
		preload("res://scenes/NativeWindowFrame.gd").resize_window(window, Vector2i(int(saved.size[0]), int(saved.size[1])))
		preload("res://scenes/NativeWindowFrame.gd").move_window(window, Vector2i(int(saved.position[0]), int(saved.position[1])))
		window.mode = int(saved.get("mode", Window.MODE_WINDOWED))
		target._refresh_workspace_layout()
		target.workspace_view.restore_navigation(int(restored_tabs[int(saved.active)]))
		target.workspace_view._apply_navigation()
	importing = false
	# Claim the shared main area after the restored windows finish layout.
	# Import suppresses resize claims. An existing client may also have
	# used its initial attach claim before the restore began.
	for target in windows:
		target.session_backend.claim_area(target)
	_receipt({"ok": true, "panes": restored_ids, "tabs": restored_tabs})
	document.clear()

## Lay out a saved tab and set its title once all of its panes exist.
## The caller is any terminal of the tab's session.
func _complete_tab(connection: Node, caller: int, saved: Dictionary, original: Dictionary) -> bool:
	var id := int(restored_tabs[int(original.id)])
	var group: Dictionary = preload("res://scenes/session/ServerWorkspace.gd").map_value(original, func(old): return restored_ids[int(old)])
	group.id = id
	var layout := preload("res://scenes/session/ServerWorkspace.gd").encode_tab(group)
	var settings := {"area": original.get("area", [0, 34, int(saved.size[0]), maxi(1, int(saved.size[1]) - 34)])}
	var reply := await _checked(connection, "workspace_edit", {"expected_revision": int(connection.topology.workspace_revision),
		"edit": {"op": "tab", "tab": id, "layout": layout, "settings": settings}})
	if reply.get("type") == "error": return false
	if not str(original.get("title", "")).is_empty():
		await _remote(connection, caller, "tab.set_title", {"id": id, "title": str(original.title)})
	return true


## A window's chromiums open on its own connection, through their owner or
## the window's first terminal, then take their places in its saved tabs.
func _open_chromiums(connection: Node, saved: Dictionary) -> bool:
	if saved.chromiums.is_empty(): return true
	var creator := -1
	for pane in saved.panes:
		if creator < 0 and not pane.has("filetree"): creator = int(restored_ids[int(pane.id)])
	# Template copies go first: a template can be a profile that another
	# saved chromium reopens and locks.
	var chromiums: Array = saved.chromiums.filter(func(chromium): return chromium.get("profile_template") != null)
	chromiums.append_array(saved.chromiums.filter(func(chromium): return chromium.get("profile_template") == null))
	var opened := {}
	for chromium in chromiums:
		var owner := creator if chromium.get("owner") == null else int(restored_ids[int(chromium.owner)])
		var id := await _open_chromium(connection, owner, chromium)
		if id < 0: return false
		restored_ids[int(chromium.id)] = id
		opened["%%%d" % int(chromium.id)] = true
	await _checked(connection, "sync", {})
	var tabs: Array = decode(saved.tabs)
	for original in tabs:
		# A browser-only move leaves the owner in place. A tab of only
		# chromiums is new: its first chromium's move creates it.
		var tab: Variant = restored_tabs.get(int(original.id))
		for key in Layout.keys(original.tree).filter(func(key): return opened.has(key)):
			var move := {"surface": "%%%d" % int(restored_ids[int(key.substr(1))]), "tab": tab, "browser_only": true}
			if tab == null and document.get("keep_ids", false): move.new_tab = int(original.id)
			var reply := await _checked(connection, "regroup", move)
			if reply.get("type") == "error": return false
			tab = int(reply.tab)
		restored_tabs[int(original.id)] = tab
	# Opening a chromium in its owner's tab disturbed that layout too.
	for original in tabs:
		await _checked(connection, "sync", {})
		if not await _complete_tab(connection, creator, saved, original): return false
	await _checked(connection, "sync", {})
	var reply := await _checked(connection, "workspace_edit", {"expected_revision": int(connection.topology.workspace_revision),
		"edit": {"op": "reorder", "tabs": saved.tabs.map(func(tab): return int(restored_tabs[int(tab.id)]))}})
	return reply.get("type") != "error"


## Reopen the saved Chromium pages with fresh page state.
## Use temporary storage if the saved profile is missing or held by
## a live Chromium instance.
func _open_chromium(connection: Node, owner: int, saved: Dictionary) -> int:
	var urls: Array = saved.urls
	var params := {"url": str(urls[0])}
	if document.get("keep_ids", false): params.id = int(saved.id)
	for field in ["profile", "profile_template"]:
		if saved.get(field) != null: params[field] = str(saved[field])
	var reply: Dictionary = await _remote(connection, owner, "chromium.create", params)
	if reply.has("error") and (params.has("profile_template") or not str(params.get("profile", "")).is_empty()):
		push_warning("Checkpoint import: %s; reopening the chromium with a temporary profile" % str(reply.error.get("message", "")))
		params.erase("profile_template")
		params.profile = ""
		reply = await _remote(connection, owner, "chromium.create", params)
	if reply.has("error"):
		failure = str(reply.error.get("message", "Chromium failed to open"))
		push_error("Checkpoint import: " + failure)
		return -1
	var key := str(reply.result.chromium)
	# Commands queue until the browser is ready, as for a restart. A new tab
	# becomes selected, so the first page, the saved selection, is reselected.
	for url in urls.slice(1):
		await _remote(connection, owner, "chromium.command", {"chromium": key, "action": "tab-new", "args": {"url": str(url)}})
	if urls.size() > 1:
		await _remote(connection, owner, "chromium.command", {"chromium": key, "action": "tab-select", "args": {"chromium_id": 1}})
	if not str(saved.get("title", "")).is_empty():
		await _remote(connection, owner, "chromium.set_title", {"chromium": key, "title": str(saved.title)})
	return int(key.substr(1))


func finish_host(host: Node, saved: Dictionary) -> void:
	# Reapply saved presentation through the owner, retaining the live session.
	host.switch_world(str(saved.get("plugin", "")))
	for pane in saved.panes:
		var id := int(pane.id)
		if pane.has("font_size"):
			host.session_backend.connection.send_action("font_size", id, {"size": int(pane.font_size), "remember": false})
	for group in decode(saved.tabs):
		var current: Dictionary = host.workspace_layout.tab(int(group.id))
		if not current.is_empty():
			current.tree = group.tree
			current.focused = group.focused
	host.select_workspace(int(saved.active), true)
	host.session_backend.commit_workspace(host)


## Checkpoint commands use the bundled desktop CLI, which mobile does not ship.
func _ready() -> void:
	if OS.has_feature("mobile"): return
	_history_clock.wait_time = HISTORY_REFRESH_SECONDS
	_history_clock.autostart = true
	_history_clock.timeout.connect(refresh_history)
	add_child(_history_clock)
	refresh_history()


## Directly under Sessions: Save checkpoint, Save checkpoint and quit, then
## one submenu per tag listing every saved checkpoint as "<age> ago, N
## sessions, N tabs, N panes".
##
## Choosing one restores it into new windows; no dialog.
func menu_entries() -> Array[Dictionary]:
	if OS.has_feature("mobile"):
		return []
	var entries: Array[Dictionary] = [
		{ "label": "Sessions::Save checkpoint", "action": "SaveCheckpoint" },
		{ "label": "Sessions::Save checkpoint and quit", "action": "SaveCheckpointAndQuit" },
	]
	var now := Time.get_unix_time_from_system()
	for item in [["manual", "Resume manual checkpoint"], ["auto", "Resume auto checkpoint"]]:
		var tag: String = item[0]
		var prefix: String = "Sessions::" + item[1] + "::"
		var saved: Array = history.get(tag, [])
		if saved.is_empty():
			entries.append({ "label": prefix + "No checkpoints", "command_line": false, "action": Callable(), "enabled": func(_h): return false })
			continue
		for checkpoint in saved:
			var path := str(checkpoint.path)
			entries.append({
				"label": prefix + describe_checkpoint(checkpoint, now),
				"literal_label": true,
				"command_line": false,
				"action": func(h): h.restore_checkpoint(tag, path),
			})
	return entries


## Saved checkpoints newest first across `tag` ("manual", "auto", or "" for both).
func ordered_history(tag := "") -> Array[Dictionary]:
	var tags: Array = [tag] if tag in ["manual", "auto"] else ["manual", "auto"]
	var items: Array[Dictionary] = []
	for current in tags:
		for item in history.get(current, []):
			if item is Dictionary and item.has("path"):
				var copy: Dictionary = item.duplicate()
				copy["tag"] = current
				items.append(copy)
	if tags.size() > 1:
		items.sort_custom(func(a, b):
			var ta := float(a.get("saved_at", 0.0))
			var tb := float(b.get("saved_at", 0.0))
			if ta != tb:
				return ta > tb
			return str(a.get("tag", "")) == "manual" and str(b.get("tag", "")) != "manual")
	return items


## "52d ago, 4 sessions, 20 tabs, 20 panes": a Graffitty window is a session.
func describe_checkpoint(checkpoint: Dictionary, now: float) -> String:
	# A checkpoint file written by hand can have no save time.
	var saved_at: Variant = checkpoint.get("saved_at")
	return tr("%s ago, %d sessions, %d tabs, %d panes") % [
		Badge.elapsed(now - float(saved_at if saved_at != null else now)),
		int(checkpoint.get("windows", 0)), int(checkpoint.get("tabs", 0)), int(checkpoint.get("panes", 0)),
	]


## Re-read both histories off the main thread; rebuild menus only when the
## visible labels change (a minute passing, a save, or a trimmed history).
func refresh_history() -> void:
	if OS.has_feature("mobile") or _history_worker != null: return
	_history_worker = Thread.new()
	_history_worker.start(func():
		var found := {}
		for tag in ["manual", "auto"]:
			var result: Dictionary = preload("res://graffitty/executables.gd").run_cli(PackedStringArray(["checkpoint", "list", "--tag", tag]))
			var parsed: Variant = JSON.parse_string(str(result.output)) if int(result.code) == 0 else null
			found[tag] = parsed if parsed is Array else []
		_history_loaded.call_deferred(found))


func _history_loaded(found: Dictionary) -> void:
	_history_worker.wait_to_finish()
	_history_worker = null
	for tag in found:
		history[tag] = found[tag].filter(func(item): return item is Dictionary and item.has("path"))
	var now := Time.get_unix_time_from_system()
	var labels := ""
	for tag in ["manual", "auto"]:
		for checkpoint in history[tag]:
			labels += tag + ":" + str(checkpoint.path) + ":" + describe_checkpoint(checkpoint, now) + "\n"
	if labels == _history_labels: return
	_history_labels = labels
	history_changed.emit()


func menu_action(host: Node, entry: Dictionary) -> void:
	if busy or capturing:
		return
	var args := PackedStringArray(["checkpoint"])
	var input := ""
	if entry.action in ["SaveCheckpoint", "SaveCheckpointAndQuit"]:
		var response := await capture()
		if response.has("error"):
			show_result(host, str(response.error.message))
			return
		input = OS.get_cache_dir().path_join(
			"graffitty-layout-%s.json" % Crypto.new().generate_random_bytes(12).hex_encode()
		)
		var file := FileAccess.open(input, FileAccess.WRITE)
		if file == null:
			show_result(host, "Cannot write the checkpoint file")
			return
		FileAccess.set_unix_permissions(input, 384) # 0600
		file.store_string(JSON.stringify(response.result))
		file.close()
		args.append_array(["save", "--input", input])
	else:
		args.append_array(["restore", "--checkpoint", str(entry.get("checkpoint", "0"))])
	args.append_array(["--tag", str(entry.get("tag", "manual"))])
	busy = true
	worker = Thread.new()
	worker.start(
		func():
			var result: Dictionary = preload("res://graffitty/executables.gd").run_cli(args)
			_complete.call_deferred(host, entry, input, int(result.code), str(result.output), str(result.errors)),
	)


func _complete(host: Node, entry: Dictionary, input: String, code: int, output: String, errors: String) -> void:
	worker.wait_to_finish()
	worker = null
	busy = false
	var saved: Variant = null
	if not input.is_empty():
		saved = JSON.parse_string(FileAccess.get_file_as_string(input))
		DirAccess.remove_absolute(input)
	if code == 0 and entry.action == "SaveCheckpointAndQuit":
		var current := await capture()
		if (
			saved is Dictionary and current.has("result")
			and layout_signature(saved) == layout_signature(current.result)
		):
			application.get_tree().quit()
		elif is_instance_valid(host):
			show_result(
				host,
				"Checkpoint saved, but the layout changed during save. Save again before quitting.",
			)
	elif is_instance_valid(host):
		show_result(
			host,
			("Checkpoint saved" if entry.action == "SaveCheckpoint" else "Restore launched") if code == 0 else (errors if not errors.strip_edges().is_empty() else output),
		)
	if code == 0 and entry.action in ["SaveCheckpoint", "SaveCheckpointAndQuit"]:
		refresh_history()


func show_result(host: Node, message: String, args: Array = []) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Checkpoints"
	host.localization.text(dialog, message, args, "dialog_text")
	host.add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _exit_tree() -> void:
	if worker != null:
		worker.wait_to_finish()
	if _history_worker != null:
		_history_worker.wait_to_finish()


static func layout_signature(checkpoint: Dictionary) -> String:
	var windows: Array = []
	for window in checkpoint.windows:
		var panes: Array = []
		for pane in window.panes:
			panes.append({ "id": pane.id, "pid": pane.pid, "filetree": pane.get("filetree") })
		windows.append(
			{
				"tabs": window.tabs,
				"active": window.active,
				"panes": panes,
				# Pages can change while saving; the layout cannot.
				"chromiums": window.chromiums.map(func(chromium): return chromium.id),
				"position": window.position,
				"size": window.size,
				"graph": window.get("graph", {}),
			}
		)
	return JSON.stringify(windows)
