extends SceneTree
## Exercise the real close flow and request waiter without starting a server.
const Client := preload("res://scenes/remote/RemoteClient.gd")
const Connection := preload("res://scenes/remote/RemoteConnection.gd")
var failures: Array[String] = []

class World extends RefCounted:
	func set_video_layers(_layers: Array) -> void: pass

class Host extends Node:
	var current_plugin := ""
	var chromiums := {}
	var world := World.new()
	var close_dialog: ConfirmationDialog
	var moving_window := false
	var tabs := [{"id": 1}]
	func get_tabs() -> Array: return tabs

class TestClient extends Client:
	func _ready() -> void:
		for child in [connection, host, remember, dialog, endpoint, secret, status]:
			add_child(child)
		get_window().close_requested.connect(request_close_window)
	func _process(_dt: float) -> void: pass
	func _refresh() -> void: pass
	# View persistence needs a real workspace view; it is not under test here.
	func _save_view() -> void: pass

class TestConnection extends Connection:
	var timeout_on := ""
	func request_action(kind: String, values: Dictionary = {}, timeout_msec: int = 10000) -> Dictionary:
		return await super.request_action(kind, values, 0 if kind == timeout_on else timeout_msec)

class Peer extends RefCounted:
	var connection: Node
	var requests: Array = []
	var disconnect_on := ""
	var ignore_on := ""
	var reject_on := ""
	var confirmation_required := false
	var send_fails := false
	func close(_code := 1000, _reason := "") -> void: pass
	func send_text(text: String) -> int:
		var message: Dictionary = JSON.parse_string(text)
		requests.append(message)
		if send_fails: return ERR_CONNECTION_ERROR
		if message.type != ignore_on: _reply.call_deferred(message)
		return OK
	func _reply(message: Dictionary) -> void:
		if message.type == disconnect_on:
			connection._network_failed("Server killed")
		elif message.type == reject_on:
			connection.acknowledged.emit({"type": "error", "request": message.request, "message": "Close rejected by owner"})
		else:
			connection.acknowledged.emit({"type": "ack", "request": message.request, "confirmation_required": confirmation_required})

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-close-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)
	print("PASS " if ok else "FAIL ", message)

func fixture() -> Dictionary:
	var client := TestClient.new()
	client.managed = true
	client.connection.free()
	client.connection = TestConnection.new()
	client.connection.connected = true
	client.connection.topology = {"tabs": [{"id": 1}], "panes": [{"id": 1, "tab": 1}], "chromiums": []}
	var peer := Peer.new()
	peer.connection = client.connection
	client.connection.socket = peer
	client.host = Host.new()
	var detached := []
	client.detached.connect(func(): detached.append(true))
	root.add_child(client)
	return {"client": client, "peer": peer, "detached": detached}

func check_detached(f: Dictionary, label: String) -> void:
	check(f.detached.size() == 1 and f.client.host == null, label + ": client closes")
	var transports: Array = Array(f.client.connection.connections) if f.client.federated else [f.client.connection]
	check(transports.all(func(transport): return not transport.connected and not transport.enabled), label + ": retries stop")
	check(f.client.connection.acknowledged.get_connections().is_empty(), label + ": request waiter is removed")
	check(not f.client.get_children().any(func(child): return child is AcceptDialog and child.visible), label + ": no blocking dialog")

func buttons(prompt: ConfirmationDialog) -> Array:
	return prompt.get_ok_button().get_parent().get_children().filter(func(button): return button is Button and button.visible).map(func(button): return button.text)

func run() -> void:
	auto_accept_quit = false
	var f := fixture()
	f.client.connection._network_failed("Server killed")
	root.close_requested.emit()
	check_detached(f, "Already offline")
	check(f.peer.requests.is_empty(), "Offline close does not contact the owner")
	f.client.free()

	# × never ends a session: it offers Detach or Cancel, nothing destructive.
	f = fixture()
	f.client.request_close_window()
	var prompt: ConfirmationDialog = f.client.host.close_dialog
	check(prompt != null and prompt.visible and f.detached.is_empty(), "Connected close asks before detaching")
	check(buttons(prompt) == ["Detach", "Cancel"], "Remote close offers only Detach and Cancel: " + str(buttons(prompt)))
	check(prompt.get_cancel_button().has_focus(), "Cancel starts focused")
	prompt.get_cancel_button().pressed.emit()
	await process_frame
	check(f.detached.is_empty() and f.client.host.close_dialog == null and f.client.connection.connected, "Cancel keeps the window attached")
	f.client.request_close_window()
	f.client.host.close_dialog.get_ok_button().pressed.emit()
	await process_frame
	await process_frame
	check_detached(f, "Detach")
	check(f.peer.requests.is_empty(), "Detach sends no close request to the owner")
	f.client.free()

	# With another window open, closing one only detaches it: no question.
	f = fixture()
	var application: Node = root.get_node("TerminalApplication")
	var other := Node.new()
	root.add_child(other)
	application.hosts.append(other)
	f.client.request_close_window()
	await process_frame
	check(f.client.host == null or f.client.host.close_dialog == null, "Another open window closes this one without asking")
	check_detached(f, "Close with another window open")
	application.hosts.erase(other)
	other.free()
	f.client.free()

	# The owner can disappear while the choice is open; Detach still releases.
	f = fixture()
	f.client.request_close_window()
	f.client.connection._network_failed("Server killed while confirming")
	f.client.host.close_dialog.get_ok_button().pressed.emit()
	await process_frame
	await process_frame
	check_detached(f, "Disconnect while confirming")
	f.client.free()

	# A window showing several servers detaches from all of them.
	f = fixture()
	var first: Node = f.client.connection
	var second := TestConnection.new()
	var second_peer := Peer.new()
	second_peer.connection = second
	second.socket = second_peer
	second.connected = true
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	f.client.remove_child(first)
	federation.add_child(first)
	federation.add_child(second)
	federation.connections.assign([first, second])
	federation.owners = {1: first, 2: first, 3: second}
	f.client.connection = federation
	f.client.add_child(federation)
	f.client.federated = true
	f.client.host.tabs = [{"id": 1}, {"id": 2}, {"id": 3}]
	f.client.request_close_window()
	check(buttons(f.client.host.close_dialog) == ["Detach", "Cancel"], "Federated close never offers server shutdown")
	f.client.host.close_dialog.get_ok_button().pressed.emit()
	await process_frame
	await process_frame
	check_detached(f, "Mixed owners")
	check(f.peer.requests.is_empty() and second_peer.requests.is_empty(), "Detaching mixed owners ends no session")
	f.client.free()

	print("REMOTE_WINDOW_CLOSE_PASS" if failures.is_empty() else "REMOTE_WINDOW_CLOSE_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
