extends "res://tests/unit/test_case.gd"

const Connection := preload("res://scenes/remote/RemoteConnection.gd")

class Peer extends RefCounted:
	var sent: Array = []
	func send_text(text: String) -> int:
		sent.append(JSON.parse_string(text))
		return OK

class Decoder extends RefCounted:
	var packets: Array = [{"session": 7, "columns": 80}]
	var pending_jobs := 0
	func poll() -> Array:
		return [] if packets.is_empty() else [packets.pop_front()]
	func idle() -> bool:
		return packets.is_empty() and pending_jobs == 0

func test_scene_credit_returns_after_delivery_without_an_extra_frame() -> void:
	var connection := Connection.new()
	var peer := Peer.new()
	var decoder := Decoder.new()
	connection.socket = peer
	connection.connected = true
	connection.subscriptions = [7]
	connection.scene_decoder = decoder
	connection.scene_flow = 8
	var delivered := []
	connection.terminal_received.connect(func(id, _frame, _bytes):
		expect(peer.sent.is_empty(), "Credit is not returned before the consumer receives the scene")
		delivered.append(id))
	connection._process(0.0)
	expect(delivered == [7], "Prepared scene reaches its subscribed terminal")
	expect(peer.sent.size() == 1 and peer.sent[0].type == "scene_ack" and int(peer.sent[0].sequence) == 8,
		"The same frame returns consumed credit instead of stalling the owner for another frame")
	expect(connection.scene_flow == 0, "Acknowledged credit is cleared")
	connection._process(0.0)
	expect(peer.sent.size() == 1, "Idle frames do not acknowledge the same credit twice")
	connection.free()

func test_scene_credit_waits_for_pending_preparation_and_delivery() -> void:
	for queued_output in [false, true]:
		var connection := Connection.new()
		var peer := Peer.new()
		var decoder := Decoder.new()
		if queued_output:
			decoder.packets.append({"session": 7, "columns": 80})
		else:
			decoder.pending_jobs = 1
		connection.socket = peer
		connection.connected = true
		connection.subscriptions = [7]
		connection.scene_decoder = decoder
		connection.scene_flow = 8
		connection._process(0.0)
		expect(peer.sent.is_empty() and connection.scene_flow == 8, "Undelivered or unprepared work retains credit")
		decoder.pending_jobs = 0
		connection._process(0.0)
		expect(peer.sent.size() == 1, "Credit returns when all preparation and delivery finish")
		connection.free()
