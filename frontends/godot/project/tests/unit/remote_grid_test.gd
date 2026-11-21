extends "res://tests/unit/test_case.gd"

class Transport extends Node:
	signal acknowledged(message: Dictionary)
	signal state_changed(message: String)
	signal changed
	var topology := {"authoritative_layout": true}
	var workspace := "$1"
	var sent: Array = []
	func session_close_stops_server(_target: String) -> Variant: return null
	func send_action(action: String, id: int, options: Dictionary) -> int:
		sent.append({"action": action, "id": id, "options": options})
		return sent.size()

class TerminalStub extends Control:
	var cell_padding := 4.0
	var cell := Vector2(11, 25)
	func get_cell_size() -> Vector2: return cell

class Pane extends Control:
	var body := Control.new()
	func terminal_content_padding(configured: Vector4) -> Vector4: return configured

class Host extends Node:
	func is_terminal_pane(key: String) -> bool:
		return preload("res://scenes/PaneTargets.gd").valid(key) and sessions.has(int(key.substr(1)))
	var layout_transaction := false
	var sessions := {}
	var world := {"terminal_window": {"padding": Vector4(8, 8, 8, 8)}}
	var workspace_view := {"panes": {}, "pane_rects": {}, "size": Vector2(1280, 800), "navigation_zoom": 1.0}

func test_owner_grid_uses_logical_pane_and_font_not_client_camera() -> void:
	var transport := Transport.new()
	var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
	var host := Host.new()
	var terminal := TerminalStub.new()
	var pane := Pane.new()
	pane.size = Vector2(1264, 750)
	pane.body.size = Vector2(1264, 720)
	host.sessions[7] = {"term": terminal}
	host.workspace_view.panes["%7"] = pane
	host.workspace_view.pane_rects["%7"] = Rect2(8, 42, 1264, 750)
	backend.sync_pane_grid(host, "%7")
	expect(transport.sent.size() == 1 and transport.sent[0].options == {"width":1240.0,"height":700.0}, "Initial owner grid fills the canonical logical body minus both padding layers")
	host.workspace_view.size = Vector2(400, 900)
	host.workspace_view.navigation_zoom = 0.3
	backend.sync_pane_grid(host, "%7")
	expect(transport.sent.size() == 1, "A remote client resize or navigation change neither reflows the owner nor sends redundant resizes")
	terminal.cell = Vector2(14, 30)
	backend.sync_pane_grid(host, "%7")
	expect(transport.sent.size() == 1, "Client font metrics cannot redefine server wrapping")
	pane.size = Vector2(640, 750)
	pane.body.size = Vector2(640, 720)
	host.workspace_view.pane_rects["%7"] = Rect2(8, 42, 640, 750)
	backend.sync_pane_grid(host, "%7")
	expect(transport.sent.size() == 2 and transport.sent[1].options.width == 616.0, "A canonical pane resize updates the owner grid")



func test_terminal_metadata_does_not_reinstall_authoritative_layout() -> void:
	var client := preload("res://scenes/remote/RemoteClient.gd")
	var original := {"authoritative_layout": true, "workspace_state": {"revision": 1, "layout": {"rect": [8,42,1264,750]}},
		"tabs": [{"id": 1}], "panes": [{"id": 7,"tab": 1,"columns":80,"rows":24,"font_size":18,"pid":100,"title":"before"}], "chromiums": []}
	var changed := original.duplicate(true)
	changed.workspace_state.revision = 2
	changed.panes[0].columns = 113
	changed.panes[0].rows = 28
	changed.panes[0].font_size = 22
	changed.panes[0].pid = 101
	changed.panes[0].title = "after"
	expect(client.workspace_layout_signature(original) == client.workspace_layout_signature(changed), "Owner grid, font, process and title updates retain in-progress local layout")
	expect(client.terminal_definitions(changed)[0].label == "after", "Title metadata still updates without reinstalling geometry")
	changed.workspace_state.layout.rect = [8,42,640,750]
	expect(client.workspace_layout_signature(original) != client.workspace_layout_signature(changed), "An actual canonical geometry edit is installed")
	changed = original.duplicate(true)
	changed.panes.append({"id":8,"tab":1,"title":"new"})
	expect(client.workspace_layout_signature(original) != client.workspace_layout_signature(changed), "Presentation membership changes install their new layout")


func test_federated_metadata_does_not_reinstall_owner_layouts() -> void:
	var client := preload("res://scenes/remote/RemoteClient.gd")
	var original := {"tabs": [{"id": 1, "title": "before", "canonical_layout": {"windows": [{"key": "%7", "rect": [0,0,640,480]}]}}],
		"panes": [{"id": 7, "tab": 1, "title": "before", "columns": 80, "app": {"name": "claude"}}], "chromiums": []}
	var changed := original.duplicate(true)
	changed.tabs[0].title = "after"
	changed.panes[0].title = "after"
	changed.panes[0].columns = 100
	changed.panes[0].app.name = "codex"
	expect(client.workspace_layout_signature(original) == client.workspace_layout_signature(changed), "Federated title, grid and process updates do not reinstall geometry")
	changed.tabs[0].canonical_layout.windows[0].rect[2] = 800
	expect(client.workspace_layout_signature(original) != client.workspace_layout_signature(changed), "Federated owner geometry changes still install")
	changed = original.duplicate(true)
	changed.panes.append({"id": 8, "tab": 1})
	expect(client.workspace_layout_signature(original) != client.workspace_layout_signature(changed), "Federated pane creation still installs")


func test_local_divider_changes_do_not_mutate_owner_compare_and_swap_base() -> void:
	var owner := {"enabled":true,"tiles":{"axis":"h","children":[
		{"pane":"%1","weight":1.0},{"pane":"%2","weight":1.0}]},
		"windows":[{"key":"%1"},{"key":"%2"}]}
	var original := owner.duplicate(true)
	var local := preload("res://scenes/session/ServerWorkspace.gd").decode_tab(1,owner)
	local.tree.tiles.children[0].weight = 1.4
	local.tree.tiles.children[1].weight = 0.6
	expect(owner == original, "A local resize leaves the authoritative merge base immutable")
	var edit := preload("res://scenes/session/ServerWorkspace.gd").encode_tab(local)
	expect(edit.tiles != owner.tiles, "Changed divider weights remain visible to the owner commit comparison")


func test_older_ack_preserves_newer_layout_intent_without_reviving_closed_panes() -> void:
	var transport := Transport.new()
	var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(transport)
	var canonical := {"windows":[{"key":"%7"},{"key":"%8"}],
		"tiles":{"axis":"h","children":[{"pane":"%7"},{"pane":"%8"}]}}
	var in_flight := canonical.duplicate(true)
	in_flight.tiles.children[0].weight = 1.2
	var later := canonical.duplicate(true)
	later.tiles.children[0].weight = 1.6
	backend.pending_edit = 42
	backend.pending_tab_edit = {"tab":1,"layout":in_flight}
	backend.queued_edits["tab:1"] = {"layout":later}
	expect(backend.presentation_layout(1, canonical) == later, "An older owner snapshot cannot replace a newer queued divider gesture")
	var closed := {"windows":[{"key":"%7"}],"tiles":{"pane":"%7"}}
	expect(backend.presentation_layout(1, closed) == closed, "Owner membership wins when a pane is closed while a layout is pending")
	backend._workspace_ack({"type":"error","request":42,"message":"conflicting layout"})
	expect(backend.presentation_layout(1, canonical) == canonical, "A rejected gesture restores the authoritative layout instead of retaining stale preview geometry")


func test_federated_main_area_change_invalidates_geometry_without_moving_panes() -> void:
	var client := preload("res://scenes/remote/RemoteClient.gd")
	var original := {"tabs": [{"id": 1, "canonical_layout": {}, "canonical_area": [0,44,1200,640]}], "panes": [], "chromiums": []}
	var changed := original.duplicate(true)
	changed.tabs[0].canonical_area = [0,44,752,1057]
	expect(client.workspace_layout_signature(original) != client.workspace_layout_signature(changed), "A different owner's main area updates letterboxing even when floating pane rectangles are unchanged")


class Federation extends Transport:
	var owners := {}
	var labels := {}
	var selected: Node


func test_a_close_confirmation_names_the_largest_thing_it_ends() -> void:
	var Dialogs := preload("res://scenes/session/KillSessionDialog.gd")
	var dialog := ConfirmationDialog.new()
	dialog.title = "Close tab?"
	dialog.ok_button_text = "Close Tab"
	Dialogs.name_largest_close(dialog, {})
	expect(dialog.title == "Close tab?" and dialog.ok_button_text == "Close Tab", "A tab that leaves its session open is still a tab")
	Dialogs.name_largest_close(dialog, {"session": "Mac / main", "stops_server": false})
	expect(dialog.title == "Close session?" and dialog.ok_button_text == "Close Session", "Closing a session's last panes is named as closing the session")
	dialog.title = "Close tab?"
	Dialogs.name_largest_close(dialog, {"session": "Mac / main", "stops_server": null})
	expect(dialog.title == "Close session?", "An unknown server outcome still names the session")
	Dialogs.name_largest_close(dialog, {"session": "Mac / main", "stops_server": true})
	expect(dialog.title == "Stop server?" and dialog.ok_button_text == "Stop Server", "Closing the server's last session is named as stopping the server")
	dialog.free()


func test_only_closing_a_sessions_last_pane_ends_it() -> void:
	var windows := Transport.new()
	var mac := Transport.new()
	windows.topology = {"panes": [{"id": 7}], "chromiums": [{"id": 9, "owner": 7}]}
	mac.topology = {"panes": [{"id": 20}, {"id": 21}], "chromiums": []}
	var federation := Federation.new()
	federation.owners = {7: windows, 9: windows, 20: mac, 21: mac}
	federation.labels = {windows: "Office / main", mac: "Mac / main"}
	var backend := preload("res://scenes/session/RemoteSessionBackend.gd").new(federation)
	expect(backend.session_close_impact([7]).get("session") == "Office / main", "Closing the only terminal, with its attached chromium, ends that server's session")
	expect(backend.session_close_impact([9]).is_empty(), "Closing a chromium beside a terminal keeps the session")
	expect(backend.session_close_impact([20]).is_empty(), "Another pane keeps the session alive")
	expect(backend.session_close_impact([20, 21]).get("session") == "Mac / main", "Closing a tab holding every pane ends the session")
	expect(backend.session_close_impact([]).is_empty(), "Nothing to close ends nothing")
	windows.free(); mac.free(); federation.free()
