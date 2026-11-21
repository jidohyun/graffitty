extends "res://tests/unit/test_case.gd"
const Client := preload("res://scenes/remote/RemoteClient.gd")

class TerminalStub extends Control:
	signal keystroke(cell: Vector2i, unicode: int)
	var bells := 0
	var strokes := 0
	func _init() -> void:
		keystroke.connect(func(_cell, _unicode): strokes += 1)
	func remote_bell() -> void: bells += 1

class Notifications extends Node:
	var shown: Array = []
	var commands: Array = []
	var bindings: Array = []
	func notify(_terminal: Control, title: String, body: String) -> void:
		shown.append([title, body])
	func command(_terminal: Control, packet: String) -> void:
		commands.append(packet)
	func bind_notification(id: int, notification_id: String, event: Dictionary, focus: String) -> void:
		bindings.append([id, notification_id, event, focus])

class Host extends Node:
	var sessions := {}
	var application := {}
	var presentation_active := true
	var active_session_id := 7

func test_observed_typing_only_animates_the_visible_presentation() -> void:
	var client := Client.new()
	var host := Host.new()
	var terminal := TerminalStub.new()
	var viewport := SubViewport.new()
	var updates := preload("res://scenes/TerminalViewportUpdates.gd")
	updates.configure(viewport, terminal)
	host.sessions[7] = {"term": terminal, "vp": viewport}
	client.host = host
	var keys := [{"cell": [0, 0], "unicode": 97}]
	client._input_activity(7, keys)
	expect(terminal.strokes == 1, "Visible owner input creates a typing effect")
	host.presentation_active = false
	client._input_activity(7, keys)
	host.presentation_active = true
	updates.set_visible(viewport, false)
	client._input_activity(7, keys)
	expect(terminal.strokes == 1, "Hidden sessions and panes cannot start observed effects")

func test_bell_events_never_create_empty_desktop_notifications() -> void:
	var client := Client.new()
	var host := Host.new()
	var terminal := TerminalStub.new()
	var notifications := Notifications.new()
	host.sessions[7] = {"term": terminal}
	host.application.system_notifications = notifications
	host.application.notifications = notifications
	client.host = host
	client._remote_notification(7, {"bell": true})
	expect(terminal.bells == 1, "Completion/shell bell goes through terminal bell settings")
	expect(notifications.shown.is_empty(), "A textless bell cannot create a blank banner")
	client._remote_notification(99, {"bell": true})
	expect(terminal.bells == 1, "Events for closed panes are ignored")
	client._remote_notification(7, {"title": "Codex", "body": "Task completed"})
	expect(notifications.shown == [["Codex", "Task completed"]], "Message-bearing notifications retain their content")
	client._remote_notification(7, {"packet": "i=done;Ready"})
	expect(notifications.commands == ["i=done;Ready"], "OSC 99 remains routed to its assembler")
	client._remote_notification(7, {"binding": {"notification_id": "done", "event": {}, "focus_target": "this_pane"}})
	expect(notifications.bindings.size() == 1, "Notification focus bindings remain intact")
