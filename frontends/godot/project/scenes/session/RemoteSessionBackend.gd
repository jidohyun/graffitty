extends "res://scenes/session/SessionBackend.gd"
## Network session ownership; the same host/world still renders and handles input.
var connection: Node
var pending_operations: Dictionary = {}
var pending_edit := -1
var pending_tab_edit: Dictionary = {}
var tab_edit_retries := 0
var queued_edits: Dictionary = {}
## Membership transfers can take several requests before one final layout.
var layout_batch_depth := 0
var editing_host: WeakRef
var requested_grids: Dictionary = {}
## "Fit main view to this client" (true) or "Follow server" (false).
##
## A fitting client sizes the shared main area while it holds a tab's claim,
## and its latest activity (attaching, resizing or rotating, input) takes the
## claim.
##
## A client without the claim letterboxes the area the server keeps.
var fit_main_view := true
## Claims this client sent, by tab: window rect, the topology generation
## current at its acknowledgement (-1 until then), whether it was sent, and
## when it was made.
var claiming: Dictionary = {}
var observed_fit := Rect2()
var attach_claim := true
## This client held the claim, so it takes back a claim its disconnection vacated.
var held_claim := false
## A manager combines independent servers, whose revisions and request IDs
## cannot be merged. Reuse the claim state machine on each owning connection.
var area_backends: Dictionary = {}
var area_claims_only := false
var layouts_only := false
var next_layout_barrier := 0
const CLAIM_TIMEOUT_MSEC := 10000
signal workspace_rejected
const ServerWorkspace := preload("res://scenes/session/ServerWorkspace.gd")


func _init(transport: Node) -> void:
	connection = transport
	is_remote = true
	connection.acknowledged.connect(_workspace_ack)
	if connection.has_signal("session_switched"):
		connection.session_switched.connect(_session_switched)


func _session_switched() -> void:
	# A late reply from the previous session must not rebase its queued layout
	# edits against the newly attached session (revisions are session scoped).
	pending_edit = -1
	pending_tab_edit.clear()
	pending_operations.clear()
	queued_edits.clear()
	requested_grids.clear()
	claiming.clear()
	area_backends.clear()
	tab_edit_retries = 0
	attach_claim = true
	held_claim = false


func configure_terminal(terminal: Node) -> void:
	terminal.remote_mode = true
	# Local desktop sessions also use this backend. Only their file paths
	# belong to this device; network and federated clients open web URLs.
	terminal.web_only_hyperlinks = not ("url" in connection and connection.url == "shared://local")
	terminal.set_meta("server_font_owned", true)
	terminal.font_paths = PackedStringArray()
	terminal.font_family = ""
	terminal.font_fallbacks = PackedStringArray()
	terminal.font_size = 16


func create_tab(host: Node) -> void:
	commit_workspace(host)
	var request: int = connection.send_action("create", host.active_session_id, { "kind": "tab", "spawn": _spawn_options(host, host.active_session_id) })
	# The created pane is focused only if the user stays on this tab meanwhile.
	if request >= 0: pending_operations[request] = {"new_tab_host": weakref(host), "gap": host.tiling_config.gap, "active": host.workspace_layout.active}


func apply_new_tab_gap(owner: WeakRef, id: int, gap: float) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	var host: Node = owner.get_ref()
	while is_instance_valid(host) and host.is_inside_tree() and connection.connected:
		var group: Dictionary = host.workspace_layout.tab(id)
		if not group.is_empty():
			group.tree.tiling_gap = gap
			commit_workspace(host)
			host.workspace_view.refresh()
			return
		if Time.get_ticks_msec() >= deadline: return
		await host.get_tree().process_frame
		host = owner.get_ref()


func create_pane(host: Node, beside: String, axis: String, before := false) -> void:
	var id: int = host.active_session_id if beside.is_empty() else int(beside.substr(1))
	var transport: Node = connection.owners.get(id, connection.selected) if "owners" in connection else connection
	var request: int = transport.send_action("create", id, { "kind": "pane", "axis": axis, "before": before, "spawn": _spawn_options(host, id) })
	if request >= 0: pending_operations[request] = {"active": host.workspace_layout.active}


func _new_pane_font_size(host: Node, source: int) -> int:
	# An attached owner may have a different configured size than this renderer.
	# Until an explicit user font choice, inherit the source's actual live size.
	var fallback: int = host.world.term_font_size_default
	if host.sessions.has(source):
		fallback = host.sessions[source].term.get_live_font_size()
	return host.application.new_pane_font_size(fallback)


func close_pane(_host: Node, id: int) -> void:
	var request: int = connection.send_action("close", id)
	if request >= 0: pending_operations[request] = true


func session_scope(tab: int) -> int:
	if not "owners" in connection: return 0
	var transport: Node = connection.owners.get(tab)
	return transport.get_instance_id() if transport != null else 0


func session_close_impact(ids: Array) -> Dictionary:
	if ids.is_empty(): return {}
	var transport: Node = connection.owners.get(int(ids[0])) if "owners" in connection else connection
	if transport == null: return {}
	var panes: Array = transport.topology.get("panes", [])
	var chromiums: Array = transport.topology.get("chromiums", [])
	if panes.is_empty() and chromiums.is_empty(): return {}
	var closing := {}
	for id in ids: closing[int(id)] = true
	for pane in panes:
		if not closing.has(int(pane.id)): return {}
	# A chromium attached to a closing terminal closes with it.
	for chromium in chromiums:
		if not closing.has(int(chromium.id)) and not closing.has(int(chromium.get("owner", -1))): return {}
	var label := str(transport.workspace)
	if "labels" in connection:
		label = str(connection.labels.get(transport, label))
	elif not str(transport.display_name).is_empty():
		label = str(transport.display_name) + " / " + label
	return {"session": label, "stops_server": transport.session_close_stops_server(transport.workspace)}


func close_tab(_host: Node, id: int) -> void:
	connection.send_action("close_group", id, { "tab": id })


func content_rect(host: Node, fallback: Rect2) -> Rect2:
	if drives_area(host.workspace_layout.active): return fit_rect(host, fallback)
	var id: int = host.workspace_layout.active
	var transport: Node = connection.owners.get(id) if "owners" in connection else connection
	if transport == null: return fallback
	var area: Array = transport.topology.get("workspace_state", {}).get("tabs", {}).get(str(id), {}).get("area", [])
	return Rect2(area[0], area[1], area[2], area[3]) if area.size() == 4 else fallback


func _area_backends() -> Array:
	if not "connections" in connection: return []
	for transport in area_backends.keys():
		# Detach frees the transport before the next layout pass. Typed arrays
		# reject freed Objects even for membership checks.
		if not is_instance_valid(transport) or transport not in connection.connections:
			area_backends.erase(transport)
	for transport in connection.connections:
		if not area_backends.has(transport):
			var backend: RefCounted = get_script().new(transport)
			backend.area_claims_only = true
			backend.layouts_only = true
			var parent: WeakRef = weakref(self)
			backend.workspace_rejected.connect(func():
				var owner: RefCounted = parent.get_ref()
				if owner != null: owner.workspace_rejected.emit())
			area_backends[transport] = backend
		area_backends[transport].fit_main_view = fit_main_view
	return area_backends.values()


## "self", "other" or "none": which client last claimed this tab's main area.
func size_owner(tab: int) -> String:
	for item in connection.topology.get("tabs", []):
		if int(item.id) == tab:
			return str(item.get("size_owner", "none"))
	return "none"


## Whether this window's own size currently defines the tab's main area.
func drives_area(tab: int) -> bool:
	if "connections" in connection:
		for backend in _area_backends():
			if backend.connection == connection.owners.get(tab): return backend.drives_area(tab)
		return false
	# Metadata-only topology may not refresh layout. Settle before using a
	# provisional claim, or unrelated UI changes can overwrite a newer owner.
	_settle_claims()
	return fit_main_view and authoritative() and (claiming.has(tab) or size_owner(tab) == "self")


## This window's usable main area, including Android keyboard insets.
func fit_rect(host: Node, fallback: Rect2) -> Rect2:
	var view: Variant = host.workspace_view
	if is_instance_valid(view) and view.has_method("window_fit_rect"):
		return view.window_fit_rect()
	return fallback


func sync_window_area(host: Node) -> void:
	if "connections" in connection:
		for backend in _area_backends(): backend.sync_window_area(host)
		return
	if not authoritative() or host.layout_transaction or not connection.connected:
		return
	var view: Control = host.workspace_view
	if not is_instance_valid(view) or view.size.x < 32 or view.size.y < 72: return
	var rect := fit_rect(host, view.viewport_content_rect())
	var resized := observed_fit.has_area() and not _same_rect(rect, observed_fit)
	observed_fit = rect
	_settle_claims()
	if not fit_main_view: return
	var tabs := _presented_tabs(host)
	if tabs.is_empty(): return
	var roles: Array = tabs.map(size_owner)
	if "self" in roles: held_claim = true
	elif "other" in roles: held_claim = false
	if attach_claim or resized:
		# Attaching, resizing or rotating this window is the latest activity.
		claim_area(host)
		return
	if not claiming.is_empty() or not ("self" in roles or (held_claim and not "other" in roles)):
		return
	# The claimant also fits tabs created or moved here, and takes back a claim
	# that only its own disconnection vacated. A newer claim elsewhere stays.
	var stale := tabs.filter(func(id): return size_owner(id) != "other" and not _same_area(_presented_area(id), rect))
	if not stale.is_empty(): claim_area(host, stale)


## The latest input on a fitting client takes the main area back.
func note_activity(host: Node) -> void:
	if "connections" in connection:
		for backend in _area_backends(): backend.note_activity(host)
		return
	if not fit_main_view or not claiming.is_empty() or not authoritative() or not connection.connected:
		return
	for id in _presented_tabs(host):
		if size_owner(id) != "self":
			claim_area(host)
			return


func transition_layout_ready(host: Node) -> bool:
	var tab: int = host.workspace_layout.active
	if "connections" in connection:
		for backend in _area_backends():
			if backend.connection == connection.owners.get(tab): return backend.transition_layout_ready(host)
		return false
	_settle_claims()
	if host.layout_transaction or layout_batch_depth > 0 or claiming.has(tab): return false
	if int(pending_tab_edit.get("tab", -1)) == tab or queued_edits.has("tab:%d" % tab): return false
	for pane in connection.topology.get("panes", []):
		var id := int(pane.id)
		if int(pane.tab) != tab or not host.sessions.has(id): continue
		var key := "%%%d" % id
		if not host.workspace_view.panes.has(key) or not host.workspace_view.panes[key].visible: continue
		for operation in pending_operations.values():
			if operation is Dictionary and int(operation.get("resize", -1)) == id: return false
		if host.sessions[id].term.get_grid_size() != Vector2i(int(pane.columns), int(pane.rows)): return false
	return true


## Claims these (by default all presented) tabs' main area for this window's
## size. Later activity on another fitting client takes it back.
func claim_area(host: Node, tabs: Array = []) -> void:
	if "connections" in connection:
		for backend in _area_backends():
			var owned: Array = backend._presented_tabs(host)
			if not tabs.is_empty(): owned = owned.filter(func(id): return id in tabs)
			if not owned.is_empty(): backend.claim_area(host, owned)
		return
	if not fit_main_view or not authoritative() or not connection.connected or host.layout_transaction or host.application.checkpoints.importing:
		return
	var view: Control = host.workspace_view
	if not is_instance_valid(view) or view.size.x < 32 or view.size.y < 72: return
	attach_claim = false
	held_claim = true
	var rect := fit_rect(host, view.viewport_content_rect())
	for id in (tabs if not tabs.is_empty() else _presented_tabs(host)):
		claiming[int(id)] = {"rect": rect, "revision": -1, "sent": false, "at": Time.get_ticks_msec()}
	commit_workspace(host)


func set_fit_main_view(host: Node, enabled: bool) -> void:
	fit_main_view = enabled
	claiming.clear()
	for backend in _area_backends(): backend.set_fit_main_view(host, enabled)
	if enabled and not "connections" in connection: claim_area(host)
	if host.has_method("_refresh_workspace_layout"): host._refresh_workspace_layout()


## A claim needs both its acknowledgement and a full topology at that revision.
## Shared clients can receive topology before the batched acknowledgement; that
## already-confirmed geometry must not wait for another update or the timeout.
func _settle_claims() -> void:
	for id in claiming.keys():
		var claim: Dictionary = claiming[id]
		var settled: bool = int(claim.revision) >= 0 and connection.topology_received_revision >= int(claim.revision)
		if settled or Time.get_ticks_msec() - int(claim.at) > CLAIM_TIMEOUT_MSEC:
			claiming.erase(id)


func _presented_tabs(host: Node) -> Array:
	var settings: Dictionary = connection.topology.get("workspace_state", {}).get("tabs", {})
	return host.workspace_layout.tabs.map(func(group): return int(group.id)).filter(func(id): return settings.has(str(id)))


## The tab's area as this client last asked for it, otherwise the server's.
func _presented_area(id: int) -> Array:
	var presented: Dictionary = queued_edits.get("tab:%d" % id, {})
	if presented.is_empty() and int(pending_tab_edit.get("tab", -1)) == id:
		presented = pending_tab_edit
	var settings: Dictionary = connection.topology.get("workspace_state", {}).get("tabs", {}).get(str(id), {})
	return presented.get("settings", settings).get("area", [])


static func _same_area(area: Array, rect: Rect2) -> bool:
	return area.size() == 4 and _same_rect(Rect2(area[0], area[1], area[2], area[3]), rect)


## The server stores single-precision areas; compare whole logical pixels.
static func _same_rect(a: Rect2, b: Rect2) -> bool:
	var offset := (a.position - b.position).abs()
	var extent := (a.size - b.size).abs()
	return maxf(maxf(offset.x, offset.y), maxf(extent.x, extent.y)) < 0.5


func resize_pane(host: Node, key: String, rect: Rect2) -> void:
	if not host.is_terminal_pane(key) or not host.workspace_view.panes.has(key):
		return
	var id := int(key.substr(1))
	var terminal: Control = host.sessions[id].term
	var insets: Array = terminal.get_meta("server_content_insets", [12.0, 38.0, 12.0, 12.0])
	var wanted: Vector2 = (rect.size - Vector2(insets[0] + insets[2], insets[1] + insets[3])).max(Vector2.ONE)
	if requested_grids.get(id) == wanted:
		return
	var request: int = connection.send_action("resize_pixels", id, {"width": wanted.x, "height": wanted.y})
	if request >= 0:
		requested_grids[id] = wanted
		pending_operations[request] = {"resize": id}



func sync_pane_grid(host: Node, key: String) -> void:
	# Shared layouts own logical pane dimensions. Local window size, camera zoom
	# and raster density must never change the owner's terminal wrapping.
	if host.layout_transaction:
		return
	var view = host.workspace_view
	if not view.pane_rects.has(key) or not view.panes.has(key):
		return
	var pane = view.panes[key]
	var rect: Rect2 = view.pane_rects[key]
	if not pane.size.is_equal_approx(rect.size) or pane.body.size.x < 32 or pane.body.size.y < 32:
		return
	resize_pane(host, key, rect)


func create_chromium_remote(
	host: Node,
	owner: int,
	url: String,
	reveal: bool,
	profile: Variant,
) -> Dictionary:
	var params := { "url": url if not url.is_empty() else "about:blank" }
	if profile is String: params.profile = profile
	var result: Dictionary = await connection.remote_call(owner, "chromium.create", params)
	if result.has("error"):
		push_error(str(result.error.get("message", "Remote chromium failed")))
		return result
	var key := str(result.result.chromium)
	var id := int(key.substr(1))
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(host) and not host.chromiums.has(id) and Time.get_ticks_msec() < deadline:
		await host.get_tree().process_frame
	if is_instance_valid(host) and host.chromiums.has(id) and reveal:
		host.focus_pane(key)
	return result


func move_pane(host: Node, _key: String, _point: Vector2) -> void:
	commit_workspace(host)


func set_tiling(host: Node, _enabled: bool) -> void:
	commit_workspace(host)


func resize_tiles(host: Node) -> void:
	commit_workspace(host)


func _authoritative_tab(tab: int) -> bool:
	if not "owners" in connection: return authoritative()
	var owner: Node = connection.owners.get(tab)
	return owner != null and owner.topology.get("authoritative_layout", false)

func authoritative() -> bool:
	return connection.topology.get("authoritative_layout", false)


func _layout_settings(snapshot: Dictionary, id: int) -> Dictionary:
	# Send only shared layout metadata; presentation preferences stay local.
	return {"area": snapshot.get("tabs", {}).get(str(id), {}).get("area", [0, 34, 1280, 766]).duplicate()}


func commit_workspace(host: Node) -> void:
	if "connections" in connection:
		for backend in _area_backends():
			backend.area_claims_only = false
			backend.commit_workspace(host)
			backend.area_claims_only = true
		return
	if layout_batch_depth > 0 or not authoritative() or host.layout_transaction or not connection.connected or host.application.checkpoints.importing:
		return
	editing_host = weakref(host)
	var snapshot: Dictionary = connection.topology.get("workspace_state", {})
	var canonical: Dictionary = snapshot.get("layout", {}).get("tabs", {})
	for group in host.workspace_layout.tabs:
		var id := int(group.id)
		if not canonical.has(str(id)): continue
		if area_claims_only and not claiming.has(id): continue
		var layout: Dictionary = canonical[str(id)].duplicate(true) if area_claims_only else ServerWorkspace.encode_tab(group)
		# Unrelated metadata/area updates must never publish a drag preview.
		if "workspace_view" in host and is_instance_valid(host.workspace_view):
			var view: Node = host.workspace_view
			if ("moving" in view and not view.moving.is_empty()) or ("tile_resize" in view and not view.tile_resize.is_empty()) \
					or (view.has_method("resizing_window") and view.resizing_window()):
				layout = canonical[str(id)].duplicate(true)
		var tools: Node = host.workspace_view.agent_links.tools if "workspace_view" in host and is_instance_valid(host.workspace_view) and "agent_links" in host.workspace_view and is_instance_valid(host.workspace_view.agent_links) else null
		if tools != null and tools.tab_id == id and not tools.before.is_empty():
			layout.graph_visual = ServerWorkspace.encode_graph(tools.before.visual)
		var settings := _layout_settings(snapshot, id)
		if drives_area(id):
			var rect: Rect2 = claiming[id].rect if claiming.has(id) else fit_rect(host, host.workspace_view.viewport_content_rect())
			settings.area = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
		# A claim is sent even when the area already matches, to take ownership.
		var claim: bool = claiming.has(id) and not claiming[id].sent
		var key := "tab:%d" % id
		var before_settings := _layout_settings(snapshot, id)
		var before_layout: Dictionary = canonical[str(id)].duplicate(true)
		if group.has("_graph_base"):
			before_layout.graph_visual = ServerWorkspace.encode_graph(group._graph_base)
		var changed_layout: bool = layout != presentation_layout(id, canonical[str(id)])
		# Reversing a gesture while it is in flight is an edit even when the desired
		# result matches an older server snapshot.
		#
		# Keep the in-flight result as its base, or the original base of a queued
		# edit.
		if queued_edits.has(key):
			before_settings = queued_edits[key].before.settings.duplicate(true)
			before_layout = queued_edits[key].before.layout.duplicate(true)
		elif int(pending_tab_edit.get("tab", -1)) == id:
			before_settings = pending_tab_edit.settings.duplicate(true)
			before_layout = pending_tab_edit.layout.duplicate(true)
		if claim or layout != canonical[str(id)] or settings != _layout_settings(snapshot, id) or changed_layout:
			queued_edits[key] = {"op": "tab", "tab": id, "layout": layout, "settings": settings, "claim": claim,
				"before": {"layout": before_layout, "settings": before_settings}}
	if area_claims_only or layouts_only:
		_send_workspace_edit()
		return
	var visible_order: Array = host.workspace_layout.tabs.map(func(tab): return int(tab.id))
	var order: Array = snapshot.get("order", []).duplicate()
	var next := 0
	for index in order.size():
		if int(order[index]) in visible_order:
			order[index] = visible_order[next]
			next += 1
	if order != snapshot.get("order", []): queued_edits["order"] = {"op": "reorder", "tabs": order, "before": snapshot.get("order", []).duplicate()}
	if host.workspace_layout.active != int(snapshot.get("active", -1)):
		queued_edits["active"] = {"op": "activate", "tab": host.workspace_layout.active, "before": snapshot.get("active", -1)}
	_send_workspace_edit()


func _send_workspace_edit() -> void:
	if pending_edit >= 0 or queued_edits.is_empty() or not connection.connected: return
	var key: String = queued_edits.keys()[0]
	var edit: Dictionary = queued_edits[key]
	queued_edits.erase(key)
	if edit.op == "barrier":
		edit.completion.passed = true
		_send_workspace_edit()
		return
	var before: Variant = edit.get("before")
	edit.erase("before")
	var claim: bool = edit.get("claim", false)
	edit.erase("claim")
	var snapshot: Dictionary = connection.topology.get("workspace_state", {})
	pending_tab_edit = {}
	if edit.op == "tab":
		var id := str(int(edit.tab))
		var current: Dictionary = snapshot.get("layout", {}).get("tabs", {}).get(id, {})
		if current.is_empty():
			claiming.erase(int(edit.tab))
			tab_edit_retries = 0
			_send_workspace_edit()
			return
		if claim:
			# The latest activity takes the area, whatever another client set meanwhile.
			before = {"layout": before.layout, "settings": _layout_settings(snapshot, int(edit.tab))}
		var bridge: RefCounted = ClassDB.instantiate("SessionClient")
		var merged: Dictionary = JSON.parse_string(bridge.rebase_workspace_tab(JSON.stringify({
			"before": before, "after": {"layout": edit.layout, "settings": edit.settings},
			"current": {"layout": current, "settings": snapshot.get("tabs", {}).get(id, {})}})))
		if merged.has("error"):
			# This tab's edit cannot be placed on the owner's layout: its panes
			# changed there, or another client edited the same thing. Drop it
			# alone. Edits waiting for other tabs stand on their own bases; a
			# group just moved into a new tab must not lose its placement
			# because the tab it left still had an edit queued.
			tab_edit_retries = 0
			claiming.erase(int(edit.tab))
			connection.state_changed.emit(str(merged.error))
			workspace_rejected.emit()
			connection.changed.emit()
			_send_workspace_edit()
			return
		edit.layout = ServerWorkspace.map_value(merged.layout, connection.wire_id)
		edit.settings = merged.settings
		pending_tab_edit = {"tab": int(edit.tab), "layout": merged.layout.duplicate(true), "settings": edit.settings.duplicate(true), "claim": claim}
		pending_tab_edit.before = {"layout": current.duplicate(true), "settings": _layout_settings(snapshot, int(edit.tab))}
		edit.tab = connection.wire_id(int(edit.tab))
	elif edit.op == "defaults":
		var current: bool = snapshot.layout.default_enabled
		if current != before and current != edit.enabled:
			queued_edits.clear()
			claiming.clear()
			workspace_rejected.emit()
			connection.changed.emit()
			return
	elif edit.op == "reorder":
		if snapshot.get("order", []) != before and snapshot.get("order", []) != edit.tabs:
			queued_edits.clear()
			claiming.clear()
			workspace_rejected.emit()
			connection.changed.emit()
			return
		edit.tabs = edit.tabs.map(connection.wire_id)
	elif edit.op == "activate":
		if snapshot.get("active", -1) != before and snapshot.get("active", -1) != edit.tab:
			queued_edits.clear()
			claiming.clear()
			workspace_rejected.emit()
			connection.changed.emit()
			return
		edit.tab = connection.wire_id(int(edit.tab))
	var payload := {"expected_revision": int(connection.topology.get("workspace_revision", 0)), "edit": edit}
	if claim:
		payload.claim = true
		if claiming.has(int(pending_tab_edit.tab)): claiming[int(pending_tab_edit.tab)].sent = true
	pending_edit = connection.send_action("workspace_edit", -1, payload)


func _workspace_ack(message: Dictionary) -> void:
	var operation: Variant = pending_operations.get(int(message.get("request", -1)))
	pending_operations.erase(int(message.get("request", -1)))
	if operation is Dictionary and operation.has("new_tab_host") and message.has("created"):
		apply_new_tab_gap.call_deferred(operation.new_tab_host, int(message.created), float(operation.gap))
	if operation is Dictionary and operation.has("font_size") and message.has("created"):
		var request: int = connection.send_action("font_size", int(message.created), {"size": int(operation.font_size)})
		if request >= 0: pending_operations[request] = true
	if int(message.get("request", -1)) != pending_edit: return
	pending_edit = -1
	var attempted := pending_tab_edit
	pending_tab_edit = {}
	if message.get("type") == "error":
		# Regrouping or a focus change can advance the owner between our snapshot
		# and this edit. Retain the placement intent and three-way rebase it;
		# _send_workspace_edit still rejects overlapping edits and lost membership.
		if message.get("workspace_state") is Dictionary and str(message.get("message", "")).begins_with("Workspace revision conflict:") and tab_edit_retries < 3:
			if not attempted.is_empty():
				tab_edit_retries += 1
				var key := "tab:%d" % int(attempted.tab)
				var retry: Dictionary = queued_edits.get(key, attempted).duplicate(true)
				retry.op = "tab"
				retry.before = attempted.before
				queued_edits[key] = retry
			# A rejected intermediate activation/reorder must not discard a queued
			# drop. Each queued operation validates its own base against the owner.
			_send_workspace_edit()
			return
		tab_edit_retries = 0
		# A competing frontend won the revision. Install its returned state and
		# require a new user action instead of overwriting it with a stale snapshot.
		queued_edits.clear()
		claiming.clear()
		connection.state_changed.emit(str(message.get("message", "Workspace edit failed")))
		workspace_rejected.emit()
		connection.changed.emit()
		return
	tab_edit_retries = 0
	if attempted.get("claim", false) and claiming.has(int(attempted.tab)):
		claiming[int(attempted.tab)].revision = int(message.workspace_state.revision)
	_send_workspace_edit()


func presentation_layout(tab: int, canonical: Dictionary) -> Dictionary:
	if "connections" in connection:
		for backend in _area_backends():
			if backend.connection == connection.owners.get(tab): return backend.presentation_layout(tab, canonical)
		return canonical
	# An older acknowledgement must not erase a newer local gesture while its
	# compare-and-swap edit waits in the queue. Membership remains owner-only.
	var pending: Dictionary = queued_edits.get("tab:%d" % tab, {})
	if pending.is_empty() and int(pending_tab_edit.get("tab", -1)) == tab:
		pending = pending_tab_edit
	if pending.is_empty() or not pending.has("layout"):
		return canonical
	var wanted: Dictionary = pending.layout
	var before_keys: Array = canonical.get("windows", []).map(func(item): return str(item.key))
	var wanted_keys: Array = wanted.get("windows", []).map(func(item): return str(item.key))
	before_keys.sort()
	wanted_keys.sort()
	return wanted if before_keys == wanted_keys else canonical


func set_default_tiling(host: Node, enabled: bool) -> void:
	host.application.tiling_default = enabled
	if not authoritative(): return
	queued_edits["defaults"] = {"op": "defaults", "enabled": enabled,
		"before": connection.topology.workspace_state.layout.default_enabled}
	_send_workspace_edit()


func work_pending() -> bool:
	if layout_batch_depth > 0: return true
	for backend in _area_backends():
		if backend.work_pending(): return true
	return pending_edit >= 0 or not queued_edits.is_empty() or not pending_operations.is_empty()


## Wait only for layout edits preceding this action on its owning connection.
## Global work_pending also includes unrelated pane operations, other servers,
## and new physics updates; none of those should starve an open-filetree action.
func flush_workspace(host: Node, owner: int) -> bool:
	if "connections" in connection:
		var transport: Node = connection.owners.get(owner)
		for backend in _area_backends():
			if backend.connection == transport: return await backend.flush_workspace(host, owner)
		return false
	if not connection.connected: return false
	commit_workspace(host)
	next_layout_barrier += 1
	var key := "barrier:%d" % next_layout_barrier
	var completion := {"passed": false}
	queued_edits[key] = {"op": "barrier", "completion": completion}
	_send_workspace_edit()
	var deadline := Time.get_ticks_msec() + 10000
	while not completion.passed:
		if not connection.connected or not queued_edits.has(key) or Time.get_ticks_msec() >= deadline:
			queued_edits.erase(key)
			return false
		await host.get_tree().process_frame
		if not is_instance_valid(host):
			queued_edits.erase(key)
			return false
	return true


func _spawn_options(host: Node, origin := -1) -> Dictionary:
	var options := preload("res://scenes/session/SpawnPreferences.gd").options(OS.get_cmdline_user_args())
	var owner: Node = connection.owners.get(origin, connection.selected) if "owners" in connection else connection
	if owner != null and "url" in owner and owner.url == "shared://local":
		options.merge(host.application.local_spawn_defaults, true)
	if origin >= 0 and host.sessions.has(origin):
		# Only the owner can inspect a remote shell's current directory. Never
		# replace it with a path resolved against the frontend's filesystem.
		options.erase("cwd")
		return options
	var transport: Node = connection.selected if "selected" in connection else connection
	var shared_local: bool = transport != null and "url" in transport and transport.url == "shared://local"
	if not shared_local:
		# An empty remote workspace starts in the owner's default directory.
		# Explicit paths are still passed through as server-side preferences.
		var explicit_cwd := false
		for arg in OS.get_cmdline_user_args():
			explicit_cwd = explicit_cwd or arg == "--cwd" or arg.begins_with("--cwd=") or arg.begins_with("--working-directory=")
		if not explicit_cwd: options.erase("cwd")
		return options
	var terminal: Node = host.sessions.get(origin, {}).get("term") if origin >= 0 else null
	var cwd: String = host.terminal_start_directory("", terminal, origin >= 0)
	if not cwd.is_empty(): options.cwd = cwd
	return options
