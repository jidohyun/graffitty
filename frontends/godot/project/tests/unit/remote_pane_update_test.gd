extends "res://tests/unit/test_case.gd"

const Connection := preload("res://scenes/remote/RemoteConnection.gd")

func _topology() -> Dictionary:
	return {
		"tabs": [{"id": 10, "title": "first", "sessions": [1]}, {"id": 11, "title": "second", "sessions": [2]}],
		"panes": [
			{"id": 1, "tab": 10, "title": "first", "automatic_title": "first", "title_is_fallback": false, "app": {"id": "shell"}, "rect": [0, 0, 10, 10]},
			{"id": 2, "tab": 11, "title": "second", "automatic_title": "second", "title_is_fallback": false, "app": {}, "rect": [0, 0, 10, 10]},
		],
		"chromiums": [{"id": 3, "owner": 1, "tab": 10, "title": "page", "state": {"url": "a"}}],
		"edges": [],
	}

func test_pane_update_patches_listed_fields_without_touching_structure() -> void:
	var connection := Connection.new()
	connection.connected = true
	connection.topology = _topology()
	var generation: int = connection.topology_generation
	var updated: Array = []
	connection.panes_updated.connect(func(ids): updated.append(ids))
	connection._receive({"type": "pane_update",
		"panes": [{"id": 1, "title": "⠹ busy", "automatic_title": "⠹ busy", "app": {"id": "claude"}}, {"id": 99, "title": "ghost"}],
		"tabs": [{"id": 10, "title": "⠹ busy"}],
		"chromiums": [{"id": 3, "state": {"url": "b"}}]})
	expect(connection.topology.panes[0].title == "⠹ busy", "Pane title follows the delta")
	expect(connection.topology.panes[0].app.id == "claude", "Foreground app follows the delta")
	expect(connection.topology.panes[0].rect == [0, 0, 10, 10], "Fields outside the delta are untouched")
	expect(connection.topology.panes[1].title == "second", "Other panes are untouched")
	expect(connection.topology.panes.size() == 2, "Unknown ids never create panes")
	expect(connection.topology.tabs[0].title == "⠹ busy", "Tab titles follow the delta")
	expect(connection.topology.chromiums[0].state.url == "b", "Chromium state follows the delta")
	expect(connection.topology_generation == generation, "A delta is not a topology generation: pending claims keep waiting for structure")
	expect(updated == [[1, 3]], "Listeners learn exactly which panes changed: %s" % [updated])
	connection.free()

func test_empty_pane_update_is_silent() -> void:
	var connection := Connection.new()
	connection.connected = true
	connection.topology = _topology()
	var emitted: Array = []
	connection.panes_updated.connect(func(ids): emitted.append(ids))
	connection._receive({"type": "pane_update", "panes": [{"id": 42, "title": "x"}], "tabs": [], "chromiums": []})
	expect(emitted.is_empty(), "Deltas for unknown panes emit nothing")
	connection.free()
