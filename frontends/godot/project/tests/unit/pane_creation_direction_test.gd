extends "res://tests/unit/test_case.gd"

class World extends RefCounted:
	var terminal_config = preload("res://graffitty/terminal_config.gd").new()
	var term_font_size_default := 18

class Preferences extends RefCounted:
	var local_spawn_defaults := {}
	func new_pane_font_size(_default: int) -> int: return 22

class SourceTerminal extends RefCounted:
	func get_live_font_size() -> int: return 18

class View extends RefCounted:
	var pane_rects := {}

class Transport extends Node:
	var tiling_config := {"gap": 8.0}
	var workspace_layout = preload("res://scenes/WorkspaceLayout.gd").new()
	var workspace_view := View.new()
	var url := "ws://remote-owner"
	var world := World.new()
	var application := Preferences.new()
	var sessions := {}
	func terminal_start_directory(_configured: String, _origin = null, _explicit := false) -> String: return "/tmp"
	signal acknowledged(message: Dictionary)
	var topology := {}
	var active_session_id := 7
	var sent := {}
	func send_action(action: String, id: int, options: Dictionary) -> int:
		sent = {"action": action, "id": id, "options": options}
		return 42

func test_remote_split_keeps_direction_for_gui_and_headless_servers() -> void:
	for headless in [false, true]:
		for axis in ["h", "v"]:
			for before in [false, true]:
				var transport := Transport.new()
				transport.sessions[7] = {"term": SourceTerminal.new()}
				transport.topology = {"headless": headless}
				var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
				backend.create_pane(transport, "%7", axis, before)
				expect(transport.sent.id == 7 and transport.sent.options.kind == "pane" and transport.sent.options.axis == axis and transport.sent.options.before == before, "Remote creation forwards the source and exact side")
				expect(not transport.sent.options.spawn.has("cwd"), "The owner resolves the source shell cwd")
				if headless:
					transport.acknowledged.emit({"request":42,"created":9})
					expect(backend.pending_operations.is_empty(), "Acknowledgement completes creation; placement remains server-owned")
				transport.free()

func test_remote_new_tab_inherits_source_and_empty_workspace_uses_owner_default() -> void:
	var transport := Transport.new()
	var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
	transport.sessions[7] = {"term": SourceTerminal.new()}
	backend.create_tab(transport)
	expect(transport.sent.id == 7 and not transport.sent.options.spawn.has("cwd"), "A new remote tab inherits its source cwd on the owner")
	transport.sessions.clear()
	transport.active_session_id = -1
	backend.create_tab(transport)
	expect(not transport.sent.options.spawn.has("cwd"), "An empty remote workspace does not use the client filesystem")
	transport.url = "shared://local"
	backend.create_tab(transport)
	expect(transport.sent.options.spawn.cwd == "/tmp", "The shared local workspace retains the initial local directory")
	transport.free()

func test_headless_neighbor_retains_existing_floating_rectangles() -> void:
	var transport := Transport.new()
	transport.sessions[7] = {"term": SourceTerminal.new()}
	transport.topology = {"headless": true}
	var narrow := Rect2(0, 1600, 380, 740)
	var wide := Rect2(560, 1600, 1120, 740)
	transport.workspace_layout.add(7, {"tiling": true, "windows": [
		{"pane": "%6", "rect": narrow, "stashed": true},
		{"pane": "%7", "rect": wide, "stashed": true}]})
	transport.workspace_view.pane_rects = {"%6": narrow, "%7": wide}
	var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
	backend.create_pane(transport, "%7", "h")
	transport.acknowledged.emit({"request": 42, "created": 9})
	expect(transport.workspace_view.pane_rects == {"%6": narrow, "%7": wide}, "Acknowledgement preserves existing geometry until the owner sends its layout")
	expect(transport.sent.id == 7 and transport.sent.options.axis == "h", "Owner receives the clicked neighbor and direction")
	transport.free()
