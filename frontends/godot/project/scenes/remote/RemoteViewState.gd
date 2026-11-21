extends RefCounted
## Device-local navigation, keyed by server/session and owner IDs rather than
## the presentation IDs allocated again whenever a transport is replaced.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const VERSION := 1
var path: String
var entries: Dictionary = {}
## Last session used per server, so reopening a saved server returns to it.
var sessions: Dictionary = {}
## Saved connection identity only; never credentials or a transient invite.
var last_connection := ""

func _init(location := "", persistent := true) -> void:
	if not persistent: return
	path = location if not location.is_empty() else preload("res://graffitty/paths.gd").stdpath("state").path_join("remote-views.json")
	if not FileAccess.file_exists(path): return
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if document is Dictionary and document.get("version") == VERSION and document.get("connections") is Dictionary:
		entries = document.connections
		if document.get("sessions") is Dictionary: sessions = document.sessions
		if document.get("last_connection", "") is String:
			last_connection = document.get("last_connection", "")

static func _key(transport: Node) -> String:
	return JSON.stringify([transport.url.strip_edges().trim_suffix("/"), transport.workspace]).sha256_text()

static func _server(address: String) -> String:
	return address.strip_edges().trim_suffix("/").sha256_text()

func session(address: String) -> String:
	var value: Variant = sessions.get(_server(address))
	return value if value is String else ""

func remember_connection(key: String) -> void:
	if last_connection == key: return
	last_connection = key
	_save()

func remember_session(transport: Node) -> void:
	var key := _server(transport.url)
	if sessions.get(key) == transport.workspace: return
	sessions[key] = transport.workspace
	_save()

func _entry(transport: Node) -> Dictionary:
	var value: Variant = entries.get(_key(transport))
	if value is Dictionary and value.get("epoch") == transport.epoch and value.get("tabs") is Dictionary:
		return value
	return {}

func capture(host: Node, transports: Array) -> void:
	if not is_instance_valid(host): return
	if is_instance_valid(host.workspace_view): host.workspace_view.save_navigation()
	var changed := false
	for transport in transports:
		if transport.epoch.is_empty(): continue
		# The switch event arrives before its topology. A pending autosave must
		# not store departing tabs under the arriving session's identity.
		if transport.topology.get("workspace", transport.workspace) != transport.workspace: continue
		var previous := _entry(transport)
		var previous_active: Variant = previous.get("active", -1)
		var active := int(previous_active) if _id(previous_active) else -1
		var tabs := {}
		for tab in transport.topology.tabs:
			var id := int(tab.id)
			var group: Dictionary = host.workspace_layout.tab(id)
			if group.is_empty(): continue
			var wire: int = transport.wire_id(id)
			var focused := str(group.get("focused", ""))
			var saved := {"focused": transport.wire_id(int(focused.substr(1))) if focused.begins_with("%") else -1}
			if group.has("navigation"): saved.navigation = group.navigation.duplicate(true)
			tabs[str(wire)] = saved
			if host.workspace_layout.active == id: active = wire
		if tabs.is_empty(): continue
		var value := {"epoch": transport.epoch, "active": active, "tabs": tabs}
		if value != previous:
			entries[_key(transport)] = value
			changed = true
	if changed: _save()

func active_tab(transport: Node) -> int:
	var active: Variant = _entry(transport).get("active", -1)
	if not _id(active): return -1
	for tab in transport.topology.tabs:
		if transport.wire_id(int(tab.id)) == int(active): return int(tab.id)
	return -1

func restore_tab(transport: Node, group: Dictionary) -> void:
	var value: Variant = _entry(transport).get("tabs", {}).get(str(transport.wire_id(int(group.id))))
	if not value is Dictionary: return
	var navigation: Variant = value.get("navigation")
	if _navigation(navigation): group.navigation = navigation.duplicate(true)
	var focused: Variant = value.get("focused", -1)
	if not _id(focused): return
	# Closed or hidden panes cannot regain focus through a saved preference.
	for key in Layout.keys(group.tree, true):
		if key.begins_with("%") and transport.wire_id(int(key.substr(1))) == int(focused):
			group.focused = key
			break

static func _id(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(value) and value >= 0 and value == floor(value)

static func _navigation(value: Variant) -> bool:
	if not value is Dictionary or not value.get("overview") is bool: return false
	var center: Variant = value.get("center")
	var zoom: Variant = value.get("zoom")
	if not center is Array or center.size() != 2: return false
	for coordinate in center:
		if not (coordinate is float or coordinate is int) or not is_finite(coordinate): return false
	return (zoom is float or zoom is int) and is_finite(zoom) and zoom > 0

func _save() -> void:
	if path.is_empty(): return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		push_warning("Cannot save remote view: " + error_string(FileAccess.get_open_error()))
		return
	file.store_string(JSON.stringify({"version": VERSION, "connections": entries, "sessions": sessions, "last_connection": last_connection}))
	file.close()
	var error := DirAccess.rename_absolute(path + ".tmp", path)
	if error != OK: push_warning("Cannot save remote view: " + error_string(error))
