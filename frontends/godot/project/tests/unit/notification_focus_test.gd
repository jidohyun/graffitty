extends "res://tests/unit/test_case.gd"
const Service := preload("res://scenes/SystemNotifications.gd")
class API extends Node:
	var available: Array[int] = [1, 2, 3]
	var visited: Array[int] = []
	func inspect_terminal(id: int) -> Dictionary:
		visited.append(id)
		return {"result":{}} if id in available else {"error":"closed"}
class App extends Node:
	var agent_api: Node

class UnsupportedService extends Service:
	var spawned := false
	func native_supported() -> bool: return false
	func _spawn_helper() -> Dictionary:
		spawned = true
		return {}
class TerminalStub extends Control:
	var replies: Array[String] = []
	func send_text(text: String) -> void: replies.append(text)

func test_unsupported_platform_does_not_spawn_desktop_helper() -> void:
	var service := UnsupportedService.new()
	var terminal := TerminalStub.new()
	service.bind_notification(3, "done", {}, "this_pane")
	service._show(3, terminal, {"id":"done", "close_report":true})
	expect(not service.spawned and service.pending.is_empty(), "Unsupported native notifications start no desktop process")
	expect(service.focus_bindings.is_empty(), "Unsupported notifications release their focus bindings")
	expect(terminal.replies == [Service.Protocol.reply("done", "close")], "Close reporting does not leave the sender waiting")
	terminal.free()
	service.free()

func test_original_sender_and_closed_pane_fallbacks() -> void:
	var service := Service.new()
	var app := App.new()
	var api := API.new()
	app.agent_api = api
	service.application = app
	var event := {"source":"%2", "origin":{"source":"%1"}, "payload":{"pane_uid":999}}
	var targets: Array = service.bind_notification(3, "event", event, "original_sender").focus_targets
	expect(targets == ["%1", "%2", "%3"], "Stored origin precedes relay and receiver; payload UID cannot override provenance")
	var job := {"id":3, "request":{"focus_targets":targets}}
	for expected in [1, 2, 3]:
		api.visited.clear()
		service._focus_notification(job)
		expect(api.visited[-1] == expected, "Closed sources fall back to the next available pane")
		api.available.erase(expected)
	expect(service.bind_notification(3, "previous", event, "previous_sender").focus_targets == ["%2", "%3"], "Previous sender skips origin")
	expect(service.bind_notification(3, "self", event, "this_pane").focus_targets == ["%3"], "Receiver remains selectable")
	expect(service.bind_notification(3, "missing", {}, "original_sender").focus_targets == ["%3"], "Missing provenance falls back to receiver")
	service.free()
	api.free()
	app.free()
