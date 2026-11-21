extends "res://tests/unit/test_case.gd"
const Connection := preload("res://scenes/remote/RemoteConnection.gd")

class Link extends RefCounted:
	var confirmed := false
	func stats() -> Dictionary:
		return {"confirmed": confirmed, "round_trip_ms": 12.0, "frames": 40, "recovered": 3, "nacked": 1, "abandoned": 0}
	func stop() -> void:
		pass

func connection() -> Node:
	var value := Connection.new()
	value.connected = true
	value.url = "ws://192.0.2.1:7183"
	value.topology = {"chromiums": [{"id": 7}], "panes": [], "tabs": []}
	value.subscriptions = [7]
	return value

func test_video_transport_reports_why_video_uses_the_websocket() -> void:
	var value := connection()
	var video: Dictionary = value.video_transport()
	expect(video.transport == "websocket" and video.reason == "unoffered" and video.streaming, "Without an offer video uses the WebSocket")
	value._video_offer = {"host": "192.0.2.1", "port": 7183}
	expect(value.video_transport().reason == "unavailable", "An offer without a local socket")
	var link := Link.new()
	value.video_datagrams = link
	video = value.video_transport()
	expect(video.reason == "no_reply" and video.address == "192.0.2.1:7183", "An unanswered path names its address")
	link.confirmed = true
	video = value.video_transport()
	expect(video.transport == "datagram" and not video.has("reason") and video.recovered == 3, "A confirmed path carries video")
	link.confirmed = false
	expect(value.video_transport().reason == "stopped", "Replies that stop are told apart from none at all")
	value._video_offer = {"host": "2001:db8::1", "port": 7183}
	expect(value.video_transport().address == "[2001:db8::1]:7183", "IPv6 addresses are bracketed")
	value.subscriptions = []
	expect(not value.video_transport().streaming, "No browser pane, nothing to warn about")
	value.url = "shared://local"
	expect(value.video_transport().is_empty(), "Local sessions share GPU textures")
	value.free()
