extends "res://tests/unit/test_case.gd"
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Backend := preload("res://scenes/session/RemoteSessionBackend.gd")

func test_switch_discards_pending_layout_and_ignores_previous_session_snapshot() -> void:
	var connection := Connection.new()
	connection.connected = true
	connection.workspace = "old"
	var backend := Backend.new(connection)
	backend.pending_edit = 7
	backend.pending_tab_edit = {"tab": 1}
	backend.queued_edits = {"tab:1": {"op": "tab", "tab": 1}}
	backend.claiming = {1: {"revision": 0}}
	connection._receive({"type": "session_switched", "workspace": "new"})
	expect(connection.workspace == "new", "Switch changes the attached session")
	expect(backend.pending_edit == -1, "Old pending edit is forgotten")
	expect(backend.queued_edits.is_empty(), "Old layout intents are discarded")
	expect(backend.claiming.is_empty(), "Old size claims are discarded")
	connection.topology = {"tabs": [], "panes": [], "workspace_state": {"revision": 2}}
	connection._receive({"type": "ack", "request": 7, "workspace": "old", "workspace_state": {"revision": 99}})
	expect(connection.topology.workspace_state.revision == 2, "Old acknowledgement cannot replace new session state")
	expect(backend.pending_edit == -1, "Old acknowledgement cannot start another edit")
	connection.free()
