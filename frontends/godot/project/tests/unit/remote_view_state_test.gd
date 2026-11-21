extends "res://tests/unit/test_case.gd"
const Views := preload("res://scenes/remote/RemoteViewState.gd")
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")

class Host extends Node:
	var workspace_layout := Layout.new()
	var workspace_view: Control

func transport(offset := 0) -> Node:
	var result := Connection.new()
	result.url = "ws://example.test:7183"
	result.workspace = "main"
	result.epoch = "live-owner"
	result.namespace_ids = true
	result.local_ids = {0: 10 + offset, 1: 11 + offset, 2: 12 + offset}
	result.topology = {"tabs": [{"id": 10 + offset}, {"id": 11 + offset}], "panes": []}
	return result

func group(id: int, pane: int) -> Dictionary:
	return {"id": id, "focused": "%%%d" % pane, "tree": {"windows": [{"pane": "%%%d" % pane, "shown": true}]}}

func store() -> RefCounted:
	return Views.new(cache_directory().path_join("views-%d.json" % Time.get_ticks_usec()))

func test_last_connection_survives_restart_and_explicit_clear() -> void:
	var views := store()
	var key := JSON.stringify(["ws://example.test:7183", "main"])
	views.remember_connection(key)
	expect(Views.new(views.path).last_connection == key, "Last connection survives process recreation")
	views.remember_connection("")
	expect(Views.new(views.path).last_connection.is_empty(), "Explicit disconnect is persisted")
	DirAccess.remove_absolute(views.path)

func test_restart_restores_owner_ids_camera_and_pane_without_sharing_geometry() -> void:
	var views := store()
	var connection := transport()
	var host := Host.new()
	host.workspace_layout.tabs.assign([group(10, 10), group(11, 12)])
	host.workspace_layout.active = 11
	var navigation := {"overview": true, "center": [-320.0, 980.0], "zoom": 0.65}
	host.workspace_layout.tab(11).navigation = navigation.duplicate(true)
	views.capture(host, [connection])
	var reopened := Views.new(views.path)
	var replacement := transport(100)
	var restored := group(111, 112)
	var geometry: Dictionary = restored.tree.duplicate(true)
	restored.focused = ""
	reopened.restore_tab(replacement, restored)
	expect(reopened.active_tab(replacement) == 111, "Restart selects the same server tab despite new frontend IDs")
	expect(restored.get("navigation") == navigation and restored.focused == "%112", "Pan, zoom and focused pane survive a disk round trip")
	expect(restored.tree == geometry, "Saved navigation cannot overwrite the server's layout")
	navigation.zoom = 2.0
	expect(restored.navigation.zoom == 0.65, "Saved camera state does not alias the live layout")
	DirAccess.remove_absolute(views.path)
	host.free()
	connection.free()
	replacement.free()

func test_server_session_and_epoch_isolate_views_and_removed_targets_fall_back() -> void:
	var views := store()
	var connection := transport()
	var host := Host.new()
	host.workspace_layout.tabs.assign([group(10, 10), group(11, 12)])
	host.workspace_layout.active = 11
	host.workspace_layout.tab(11).navigation = {"overview": false, "center": [0, 0], "zoom": 1.0}
	views.capture(host, [connection])
	for property in ["url", "workspace", "epoch"]:
		var original: String = connection.get(property)
		connection.set(property, "different")
		var untouched := group(11, 12)
		views.restore_tab(connection, untouched)
		expect(views.active_tab(connection) == -1 and not untouched.has("navigation"), "A different %s cannot inherit the view" % property)
		connection.set(property, original)
	connection.topology.tabs = [{"id": 10}]
	expect(views.active_tab(connection) == -1, "A closed tab is never selected")
	var surviving := group(11, 10)
	views.restore_tab(connection, surviving)
	expect(surviving.focused == "%10", "A closed focused pane leaves the current valid focus intact")
	expect(surviving.navigation.overview == false, "Main View remains fitted instead of becoming an overview")
	DirAccess.remove_absolute(views.path)
	host.free()
	connection.free()

func test_malformed_navigation_and_obsolete_documents_are_ignored() -> void:
	var views := store()
	var connection := transport()
	for navigation in [{"overview": true, "center": [0], "zoom": 1}, {"overview": true, "center": [0, 0], "zoom": 0}, {"overview": true, "center": [NAN, 0], "zoom": 1}, {"overview": true, "center": [0, 0], "zoom": "large"}]:
		views.entries[Views._key(connection)] = {"epoch": connection.epoch, "active": "invalid", "tabs": {"1": {"navigation": navigation, "focused": []}}}
		var restored := group(11, 12)
		views.restore_tab(connection, restored)
		expect(not restored.has("navigation") and restored.focused == "%12" and views.active_tab(connection) == -1, "Invalid preference cannot corrupt navigation or focus")
	var file := FileAccess.open(views.path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": 0, "connections": views.entries}))
	file.close()
	expect(Views.new(views.path).entries.is_empty(), "There is only one supported view-state document version")
	DirAccess.remove_absolute(views.path)
	connection.free()

func test_last_session_per_server_survives_restart() -> void:
	var views := store()
	expect(views.session("ws://example.test:7183").is_empty(), "A new server has no remembered session")
	var connection := transport()
	connection.workspace = "work"
	views.remember_session(connection)
	var reopened := Views.new(views.path)
	expect(reopened.session("ws://example.test:7183/") == "work", "The last session survives an app restart")
	expect(reopened.session("ws://other.test:7183").is_empty(), "Servers keep separate sessions")
	connection.free()

func test_window_views_are_private_and_switch_autosave_cannot_relabel_old_tabs() -> void:
	var views := Views.new("", false)
	var other_window := Views.new("", false)
	var connection := transport()
	connection.topology.workspace = connection.workspace
	var host := Host.new()
	host.workspace_layout.tabs.assign([group(10, 10)])
	host.workspace_layout.active = 10
	host.workspace_layout.tab(10).navigation = {"overview": true, "center": [70, -20], "zoom": 0.7}
	views.capture(host, [connection])
	expect(views.active_tab(connection) == 10, "The departing window captures its tab")
	expect(other_window.active_tab(connection) == -1, "Another window has an independent view")
	connection.workspace = "arriving"
	views.capture(host, [connection])
	expect(views.active_tab(connection) == -1, "Autosave between switch and topology cannot relabel departing tabs")
	connection.workspace = "main"
	var restored := group(10, 10)
	views.restore_tab(connection, restored)
	expect(restored.navigation.zoom == 0.7, "The original viewport remains available")
	expect(views.path.is_empty(), "Desktop window navigation does not share a persisted device store")
	host.free()
	connection.free()
