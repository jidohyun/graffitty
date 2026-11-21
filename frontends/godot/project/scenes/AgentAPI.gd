extends Node
## v1 local API: routing and authorization use the workspace capability, not focus.
const Targets := preload("res://scenes/PaneTargets.gd")
var application: Node
var socket: RefCounted
var socket_path := ""
var runtime_directory := ""
var session_token := ""
var capabilities: Dictionary = { }
var tab_tokens: Dictionary = { }
var inflight := 0
var dom_source := ""
var virtual_input = preload("res://scenes/VirtualTerminalInput.gd").new()
var graph = preload("res://scenes/AgentGraph.gd").new()


func _ready() -> void:
	add_child(graph)
	dom_source = FileAccess.get_file_as_string("res://scenes/chromium_automation.js")
	# Mobile clients run no local processes: every terminal lives on a server,
	# whose requests arrive through RemoteConnection, so nothing could connect.
	if OS.has_feature("mobile"):
		return
	if not ClassDB.class_exists("AgentSocket"):
		push_warning("Agent API unavailable: rebuild graffitty with AgentSocket")
		return
	socket = ClassDB.instantiate("AgentSocket")
	var temporary := OS.get_cache_dir() if OS.has_feature("mobile") else (OS.get_environment("TEMP") if OS.get_name() == "Windows" else "/tmp")
	var directory := temporary.path_join("graffitty-%d-%s") % [
		OS.get_process_id(),
		Crypto.new().generate_random_bytes(8).hex_encode(),
	]
	if not socket.start(directory):
		socket = null
		push_error("Cannot start private agent socket")
		return
	socket_path = socket.endpoint()
	runtime_directory = directory
	session_token = Crypto.new().generate_random_bytes(32).hex_encode()
	capabilities[session_token] = -1
	var descriptor := FileAccess.open(directory.path_join("session.json"), FileAccess.WRITE)
	if descriptor != null:
		if OS.get_name() != "Windows": FileAccess.set_unix_permissions(directory.path_join("session.json"), 384)
		descriptor.store_string(JSON.stringify({ "socket": socket_path, "token": session_token }))
		descriptor.close()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--launch-descriptor="):
			var path := argument.trim_prefix("--launch-descriptor=")
			# Create privately before copying the capability into it.
			var launch_file := FileAccess.open(path, FileAccess.WRITE)
			if launch_file != null:
				FileAccess.set_unix_permissions(path, 384)
				launch_file.store_string(JSON.stringify({"socket": socket_path, "token": session_token}))


func environment_for(tab_id: int) -> Dictionary:
	if socket == null:
		return { }
	if not tab_tokens.has(tab_id):
		var token := Crypto.new().generate_random_bytes(32).hex_encode()
		tab_tokens[tab_id] = token
		capabilities[token] = tab_id
	return {
		"GRAFFITTY_SOCKET": socket_path,
		"GRAFFITTY_RUNTIME_DIR": runtime_directory,
		"GRAFFITTY_TOKEN": tab_tokens[tab_id],
		"GRAFFITTY_TAB_ID": str(tab_id),
		"GRAFFITTY_SURFACE_ID": "%%%d" % tab_id,
		"GRAFFITTY_PANE": "%%%d" % tab_id,
		# A GUI launched from an agent must not pass that agent's identity to new shells.
		"CODEX_THREAD_ID": "",
		"CODEX_SESSION_ID": "",
		"GRAFFITTY_BIN": preload("res://graffitty/executables.gd").cli(),
	}


func revoke(tab_id: int) -> void:
	for attachment in get_tree().get_nodes_in_group("playwright_attachments"):
		if attachment.chromium.tab_id == tab_id:
			attachment.release()
	capabilities.erase(tab_tokens.get(tab_id, ""))
	tab_tokens.erase(tab_id)


func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("AgentAPI", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	if socket == null:
		return
	for packet in socket.poll():
		_handle(packet.peer, packet.json)


func error(code: String, message: String) -> Dictionary:
	return { "error": { "code": code, "message": message } }


func _handle(peer: int, json: String) -> void:
	var request = JSON.parse_string(json)
	if not request is Dictionary:
		socket.respond(peer, JSON.stringify(error("invalid_request", "Expected JSON object")))
		return
	var token := str(request.get("token", ""))
	var response: Dictionary
	if request.get("version") != 1:
		response = error("unsupported_version", "API version 1 required")
	elif not capabilities.has(token):
		response = error("unauthorized", "Valid workspace capability required")
	elif inflight >= 32:
		response = error("busy", "Too many pending requests")
	elif not request.get("params") is Dictionary:
		response = error("invalid_params", "Expected object params")
	elif not request.get("method") is String or request.method.is_empty():
		response = error("invalid_request", "Expected method")
	else:
		inflight += 1
		response = await dispatch(
			int(capabilities[token]),
			request.method,
			request.params,
		)
		inflight -= 1
	response["id"] = request.get("id")
	response["version"] = 1
	socket.respond(peer, JSON.stringify(response))


func chromium_info(chromium: Node) -> Dictionary:
	return {
		"chromium": "%%%d" % chromium.session_id,
		"surface": "%%%d" % chromium.session_id,
		"pane": "%%%d" % chromium.session_id,
		"tab_id": chromium.tab_id,
		"native_visible": chromium.native_visible,
		"profile": chromium.profile_directory,
		"temporary_profile": not chromium.persistent_profile,
		"exited": chromium.pid <= 0,
	}


func dispatch(tab_id: int, method: String, params: Dictionary) -> Dictionary:
	if method == "application.launch_info":
		if tab_id >= 0: return error("forbidden", "Application capability required")
		return {"result": {"fresh_sessions": true, "script_reload": application.has_node("DevScriptReload")}}
	if method == "application.open_window":
		if tab_id >= 0:
			return error("forbidden", "Application capability required")
		if not application.opens_windows():
			return error("unsupported", "This client presents a single window")
		if params.get("fresh_session", false):
			application.open_local_session(PackedStringArray(params.get("args", [])), str(params.get("cwd", "")))
			return {"result": {"opened": true}}
		for host in application.hosts:
			if is_instance_valid(host) and host.world != null and host.close_dialog == null:
				host.create_native_window()
				return {"result": {"opened": true}}
		return error("busy", "No window is ready to open a workspace")
	if method == "session.capture" and params.get("layout", false):
		return await application.checkpoints.capture()
	if tab_id < 0:
		return error("forbidden", "Application capability cannot control individual panes")
	var owner: Node = application.host_for_workspace(tab_id)
	if owner == null or not owner.workspaces.has(tab_id):
		return error("workspace_closed", "Workspace no longer exists")
	if params.has("tab_id") and str(params.tab_id) != str(tab_id):
		return error("forbidden", "Cross-workspace access denied")
	if method == "session.capture":
		return await owner.session_backend.connection.remote_call(tab_id, method, params)
	params = params.duplicate(true)
	# Resolve aliases before dispatch; the original operation still authorizes access.
	for field in ["from", "to", "node", "chromium"]:
		if params.has(field) and (str(params[field]).begins_with("%") or str(params[field]).begins_with(":") or str(params[field]).begins_with("@")):
			var resolved := Targets.resolve(application, owner, str(params[field]))
			if resolved.is_empty():
				return error("invalid_target", "Unknown pane target: " + str(params[field]) + Targets.hint(str(params[field])))
			params[field] = resolved
	if owner.session_backend.is_remote and method in ["window.set_title", "chromium.set_title", "tab.set_title"]:
		if method == "tab.set_title" and (params.has("position") or params.has("target") or params.has("id")):
			# Visible positions and public IDs belong to the calling window. The
			# persistent owner receives only the resolved wire ID after reordering.
			var target: int = int(params.get("id", -1))
			if params.has("position"):
				target = Targets.resolve_tab(owner, ":%d" % int(params.position))
			elif params.has("target"):
				target = Targets.resolve_tab(owner, str(params.target))
			if target < 0:
				return error("no_tab", "Unknown tab target")
			params.erase("position")
			params.erase("target")
			params.id = owner.session_backend.connection.wire_id(target)
		var response: Dictionary = await owner.session_backend.connection.remote_call(tab_id, method, params)
		# Apply the acknowledged title immediately; topology supplies every other view.
		if not response.has("error") and method == "window.set_title" and owner.sessions.has(tab_id):
			owner.sessions[tab_id].model.pin_title(str(params.get("title", "")))
		return response
	if method == "pane.list":
		return {"result": {"panes": Targets.list_panes(owner)}}
	if method == "pane.inspect":
		var key := Targets.resolve(application, owner, str(params.get("target", "")))
		if not Targets.valid(key):
			return error("invalid_target", "Choose a terminal pane")
		return inspect_terminal(int(key.substr(1)))
	if method == "notification.bind":
		return await owner.session_backend.connection.remote_call(tab_id, method, params)
	if method == "terminal.pid":
		if owner.session_backend.is_remote:
			params.erase("tab_id")
			return await owner.session_backend.connection.remote_call(tab_id, method, params)
		return terminal_pids(owner, params)
	if (method.begins_with("terminal.") or method == "window.set_title") and params.has("target"):
		var key := Targets.resolve(application, owner, str(params.target))
		if key.is_empty():
			return error("invalid_target", "Unknown pane target" + Targets.hint(str(params.target)))
		if key != "%%%d" % tab_id:
			return error("forbidden", "Terminal access is scoped to the calling terminal")
		params.erase("target")
	if owner.session_backend.is_remote and method in ["terminal.get_text", "terminal.type", "terminal.press"]:
		# The owner encodes against live VT modes and never needs a focused view.
		params.erase("tab_id")
		return await owner.session_backend.connection.remote_call(tab_id, method, params)
	if method.begins_with("graph.") or method.begins_with("agent."):
		return await graph.dispatch(tab_id, method, params)
	if method == "tab.list":
		var tabs: Array = []
		var position := 0
		for tab in owner.get_tabs():
			position += 1
			var model: Node = owner.session_model(int(tab.id))
			var pid: int = (
				owner.sessions[int(tab.id)].term.get_shell_pid()
				if (
					owner.sessions.has(int(tab.id))
					and owner.sessions[int(tab.id)].term.has_method("get_shell_pid")
				)
				else -1
			)
			tabs.append(
				{
					"position": position,
					"id": tab.id,
					"tab": Targets.tab_id(int(tab.id)),
					"title": tab.title,
					"pinned": tab.pinned,
					"active": tab.active,
					"windows": owner.workspace_layout.keys(owner.workspace_layout.tab(int(tab.id)).tree).size(),
					"pid": pid,
					"self": int(tab.id) == owner.workspace_layout.containing("%%%d" % tab_id),
				}
			)
		return { "result": { "tabs": tabs } }
	if method == "tab.set_title" or method == "window.set_title":
		var title := str(params.get("title", ""))
		if title.length() > 200:
			return error("invalid_title", "A title is at most 200 characters")
		if method == "window.set_title":
			var model: Node = owner.session_model(tab_id)
			if model == null:
				return error("no_terminal", "This workspace has no terminal")
			model.pin_title(title)
			return { "result": { "window": "%%%d" % tab_id, "title": model.title } }
		# Titles are the one thing a workspace may set on another tab: a name
		# grants no access to what runs there.
		var target_host := owner
		var target: int = owner.workspace_layout.containing("%%%d" % tab_id)
		if target < 0:
			target = tab_id
		if params.has("target"):
			target = Targets.resolve_tab(owner, str(params.target))
			if target < 0:
				return error("no_tab", "Unknown tab target")
		elif params.has("position"):
			var tabs: Array = owner.get_tabs()
			var index := int(params.position) - 1
			if index < 0 or index >= tabs.size():
				return error("no_tab", "This window has %d tabs" % tabs.size())
			target = int(tabs[index].id)
		elif params.has("id"):
			target = int(params.id)
			target_host = application.host_for_workspace(target)
			if target_host == null or target_host.workspace_layout.tab(target).is_empty():
				return error("no_tab", "No tab %d" % target)
		target_host.workspace_layout.set_title(target, title)
		target_host.ui_changed.emit()
		for tab in target_host.get_tabs():
			if int(tab.id) == target:
				return { "result": { "tab": target, "title": tab.title, "pinned": tab.pinned } }
		return { "result": { "tab": target } }
	if method == "navigator.focus":
		var direction = params.get("direction", "")
		if params.has("direction") and direction not in ["left", "down", "up", "right"]:
			return error("invalid_params", "Expected left, down, up or right")
		if owner.workspace_view == null:
			return error("unsupported_layout", "This world has not opted into TerminalSpace")
		var source := "%%%d" % tab_id
		if params.has("target"):
			if not params.target is String:
				return error("invalid_params", "Expected a pane target string")
			source = Targets.resolve(application, owner, params.target)
			if source.is_empty():
				return error("invalid_target", "Unknown pane target" + Targets.hint(params.target))
			if owner.workspace_layout.containing(source) < 0:
				return error("forbidden", "Select a pane in the calling window")
		elif not direction.is_empty():
			# Untargeted navigation comes from a keypress; discard stale requests.
			if owner.workspace_layout.containing(source) != owner.workspace_layout.active:
				return error("inactive_tab", "Select the calling tab first")
			if owner.pane_focus != source:
				return {"result": {"outcome": "canceled", "pane": owner.pane_focus}}
		var previous: String = owner.pane_focus
		if direction.is_empty():
			owner.reveal_pane(source)
			owner.workspace_view.reveal_navigation_target(source)
		else:
			await owner.navigator.focus_direction(direction, source)
		return {"result": {"outcome": "edge" if owner.pane_focus == previous else "moved", "pane": owner.pane_focus}}
	if method.begins_with("tiling."):
		return preload("res://scenes/TilingCommands.gd").dispatch(owner, tab_id, method, params)
	if method.begins_with("terminal."):
		return await virtual_input.dispatch(owner, tab_id, method, params)
	if method == "identify":
		return {
			"result": { "tab_id": tab_id, "terminal": "%%%d" % tab_id, "pane": "%%%d" % tab_id, "tab": Targets.tab_id(owner.workspace_layout.containing("%%%d" % tab_id)), "api_version": 1 }
		}
	if method in ["surface.list", "chromium.list"]:
		var items: Array = []
		for surface in owner.workspace_surfaces(tab_id):
			surface.erase("texture")
			surface["pane"] = surface.id
			if method == "surface.list" or surface.kind == "chromium":
				items.append(surface)
		return { "result": { "tab_id": tab_id, "surfaces": items } }
	if method == "workspace.layout":
		return error(
			"unsupported_layout",
			"Windows are freely positioned and resized by the user; split ratios are no longer supported",
		)
	if method == "chromium.create":
		if owner.workspaces[tab_id].chromiums.size() >= 8:
			return error("limit", "Maximum 8 chromiums per workspace")
		var url := str(params.get("url", "about:blank"))
		if not valid_url(url):
			return error("invalid_url", "Use http(s) or about:blank")
		var profile = params.get("profile")
		if profile != null and not profile is String:
			return error("invalid_profile", "profile must be a directory path")
		if owner.session_backend.is_remote:
			return await owner.session_backend.create_chromium_remote(owner, tab_id, url, true, profile)
		var chromium: Node = await owner.create_chromium_session(url, tab_id, true, profile)
		if chromium == null or chromium.pid <= 0:
			var message: String = chromium.status if chromium != null else "Chromium host failed to launch"
			if chromium != null:
				owner.close_chromium_session(chromium.session_id)
			return error("launch_failed", message)
		return { "result": chromium_info(chromium) }
	var ref := str(params.get("chromium", ""))
	if not Targets.valid(ref):
		return error("invalid_target", "Explicit %N required")
	var id := int(ref.substr(1))
	var chromium_owner: Node = application.chromium_host(id)
	var chromium: Node = chromium_owner.chromiums.get(id) if chromium_owner != null else null
	if chromium == null:
		return error("not_found", "Chromium no longer exists")
	if chromium.tab_id != tab_id:
		return error("forbidden", "Chromium belongs to another workspace")
	if method == "chromium.close":
		chromium_owner.close_chromium_session(id)
		return { "result": { "closed": ref } }
	if method == "chromium.restart":
		return await chromium.restart()
	if method == "chromium.select":
		chromium_owner.select_chromium_surface(id)
		return { "result": chromium_info(chromium) }
	if method == "chromium.present":
		if params.get("mode") not in ["native", "embedded"]:
			return error("invalid_params", "mode must be native or embedded")
		return await chromium.request("chrome-native" if params.mode == "native" else "chrome-world")
	var until := Time.get_ticks_msec() + 15000
	while (
		is_instance_valid(chromium) and chromium.primary_page_id < 0
		and chromium.pid > 0 and Time.get_ticks_msec() < until
	):
		await get_tree().process_frame
	if not is_instance_valid(chromium) or chromium.primary_page_id < 0:
		return error("not_ready", "Chromium not ready")
	if method == "chromium.attach":
		if chromium.playwright == null:
			chromium.playwright = preload("res://scenes/ChromiumPlaywright.gd").new()
			chromium.playwright.chromium = chromium
			chromium.add_child(chromium.playwright)
			chromium.playwright.add_to_group("playwright_attachments")
		return await chromium.playwright.attach()
	if method == "chromium.detach":
		if chromium.playwright != null and chromium.playwright.lease == str(params.get("lease", "")):
			chromium.playwright.release()
		return {"result": {"detached": true}}
	if method == "chromium.navigate":
		var url := str(params.get("url", ""))
		if not valid_url(url):
			return error("invalid_url", "Use http(s) or about:blank")
		return await cdp(chromium, "Page.navigate", { "url": url })
	if method == "chromium.eval":
		return await evaluate(chromium, str(params.get("expression", "")))
	if method == "chromium.snapshot":
		return await dom(chromium, "snapshot", { })
	if method == "chromium.fill":
		return await dom(chromium, "fill", params)
	if method == "chromium.scroll":
		return await dom(chromium, "scroll", params)
	if method == "chromium.click":
		var position := await dom(chromium, "locate", params)
		if position.has("error"):
			return position
		var point: Dictionary = position.result
		for type in ["mousePressed", "mouseReleased"]:
			var response := await cdp(
				chromium,
				"Input.dispatchMouseEvent",
				{ "type": type, "x": point.x, "y": point.y, "button": "left", "clickCount": 1 },
			)
			if response.has("error"):
				return response
		return { "result": { "clicked": true } }
	if method == "chromium.press":
		var key := str(params.get("key", ""))
		var keys := {
			"Enter": 13,
			"Tab": 9,
			"Escape": 27,
			"Backspace": 8,
			"Delete": 46,
			"ArrowLeft": 37,
			"ArrowUp": 38,
			"ArrowRight": 39,
			"ArrowDown": 40,
			"Space": 32,
		}
		if not keys.has(key):
			return error("invalid_key", "Unsupported key")
		for type in ["keyDown", "keyUp"]:
			var args := {
				"type": type,
				"key": " " if key == "Space" else key,
				"windowsVirtualKeyCode": keys[key],
			}
			if type == "keyDown" and key in ["Enter", "Space"]:
				args["text"] = "\r" if key == "Enter" else " "
			var response := await cdp(chromium, "Input.dispatchKeyEvent", args)
			if response.has("error"):
				return response
		return { "result": { "pressed": key } }
	if method == "chromium.wait":
		if not (params.get("timeout_ms", 10000) is int or params.get("timeout_ms", 10000) is float):
			return error("invalid_params", "timeout_ms must be a number")
		var deadline := Time.get_ticks_msec() + clampi(
			int(params.get("timeout_ms", 10000)),
			1,
			30000,
		)
		while Time.get_ticks_msec() < deadline:
			if not is_instance_valid(chromium):
				return error("not_found", "Chromium closed")
			var response := await dom(chromium, "wait", params)
			if response.has("error") or response.get("result", { }).get("ready", false):
				return response
			await get_tree().create_timer(0.1).timeout
		return error("timeout", "Page condition not reached")
	return error("method_not_found", "Unknown method: " + method)


func terminal_pids(owner: Node, params: Dictionary) -> Dictionary:
	if not params.get("details", false) is bool:
		return error("invalid_params", "details must be a boolean")
	var panes := Targets.list_panes(owner)
	if params.has("target"):
		var target := str(params.target)
		if (target.begins_with("@") or target.begins_with(":")) and not "." in target:
			var tab := Targets.resolve_tab(owner, target)
			if tab < 0:
				return error("no_tab", "Unknown tab target")
			panes = panes.filter(func(p): return p.tab == Targets.tab_id(tab))
		else:
			var key := Targets.resolve(application, owner, target)
			panes = panes.filter(func(p): return p.id == key)
			if panes.is_empty():
				return error("invalid_target", "No matching pane in this window" + Targets.hint(target))
			if panes[0].type != "terminal":
				return error("no_terminal", "PID lookup requires a terminal pane")
	var terminals: Array = []
	for pane in panes:
		if pane.type != "terminal":
			continue
		var id := int(str(pane.id).substr(1))
		if not owner.sessions.has(id):
			continue
		var term: Node = owner.sessions[id].term
		var pid: int = term.get_shell_pid() if term.has_method("get_shell_pid") else -1
		pane["root_pid"] = pid if pid > 0 else null
		if params.get("details", false):
			var monitor: Node = owner.resource_monitor_for(id)
			var snapshot: Dictionary = monitor.snapshot() if monitor != null else {}
			# Explicit allowlist: never expose argv, environments or provider secrets.
			for field in ["status", "sample_age_seconds", "coverage_gap", "backend"]:
				pane[field] = snapshot.get(field)
			if monitor == null:
				pane.status = "unavailable"
			pane["processes"] = []
			for process in snapshot.get("processes", []):
				var row := {}
				for field in ["pid", "parent_pid", "start_identity", "name", "memory_current"]:
					row[field] = process.get(field)
				pane.processes.append(row)
		terminals.append(pane)
	return {"result": {"terminals": terminals}}


func valid_url(url: String) -> bool:
	return url == "about:blank" or url.begins_with("http://") or url.begins_with("https://")


func cdp(chromium: Node, method: String, params: Dictionary) -> Dictionary:
	if not is_instance_valid(chromium):
		return error("not_found", "Chromium closed")
	return await chromium.request(
		"cdp",
		{ "method": method, "params": params, "chromium_id": chromium.primary_page_id },
	)


func evaluate(chromium: Node, expression: String) -> Dictionary:
	var response := await cdp(
		chromium,
		"Runtime.evaluate",
		{ "expression": expression, "returnByValue": true, "awaitPromise": true, "timeout": 10000 },
	)
	if response.has("error"):
		return response
	var result: Dictionary = response.get("result", { })
	if result.has("exceptionDetails"):
		return error(
			"javascript_error",
			str(result.exceptionDetails.get("text", "JavaScript failed")),
		)
	var value = result.get("result", { }).get("value")
	if value is Dictionary and value.has("error"):
		return value
	return { "result": value }


func dom(chromium: Node, action: String, params: Dictionary) -> Dictionary:
	params = params.duplicate()
	if action == "snapshot":
		params["generation"] = Crypto.new().generate_random_bytes(12).hex_encode()
	return await evaluate(
		chromium,
		"(%s)(%s)" % [dom_source, JSON.stringify({ "action": action, "params": params })],
	)


func _exit_tree() -> void:
	if not socket_path.is_empty():
		var directory := runtime_directory
		DirAccess.remove_absolute(directory.path_join("session.json"))
		for file in DirAccess.get_files_at(directory):
			if file.begins_with("codex-") and file.ends_with(".json"):
				DirAccess.remove_absolute(directory.path_join(file))


func inspect_terminal(id: int) -> Dictionary:
	var key := "%%%d" % id
	var target: Node = application.host_for_workspace(id)
	if target == null or target.workspace_layout.containing(key) < 0:
		return error("invalid_target", "Notification source pane has closed")
	# Select immediately so a tab flight cannot overwrite inspection framing.
	var instant: bool = target.instant_workspace_switch
	target.instant_workspace_switch = true
	target.focus_pane(key)
	target.instant_workspace_switch = instant
	var window := target.get_window()
	if window.mode == Window.MODE_MINIMIZED: window.mode = Window.MODE_WINDOWED
	window.show()
	window.grab_focus()
	target.workspace_view.inspect_pane(key)
	return {"result": {"pane": key, "fitted": true}}
