extends "res://tests/unit/test_case.gd"
const Client := preload("res://scenes/remote/RemoteClient.gd")
const Connection := preload("res://scenes/remote/RemoteConnection.gd")

class Peer extends RefCounted:
	var sent: Array = []
	func send_text(text: String) -> int:
		sent.append(JSON.parse_string(text))
		return OK

func test_adaptive_resolution_settles_each_pane_and_restores_detail() -> void:
	var small := {}
	var large := {}
	expect(Client.chromium_stream_height(small, 100, 0) == 144, "Tiny panes use the smallest rendition")
	expect(Client.chromium_stream_height(large, 1000, 0) == 1080, "Large panes retain detail")
	expect(Client.chromium_stream_height(large, 200, 100) == 1080, "Downscale waits for camera settling")
	Client.chromium_stream_height(small, 350, 300)
	expect(Client.chromium_stream_height(large, 200, 600) == 240, "Another moving pane does not postpone this pane")
	expect(Client.chromium_stream_height(large, 1000, 601) == 1080, "Zoom-in restores detail immediately")

func test_adaptive_resolution_avoids_bucket_boundary_oscillation() -> void:
	var state := {}
	Client.chromium_stream_height(state, 550, 0)
	Client.chromium_stream_height(state, 535, 100)
	expect(Client.chromium_stream_height(state, 535, 1000) == 720, "Near-boundary motion retains the current bucket")
	Client.chromium_stream_height(state, 480, 1100)
	expect(Client.chromium_stream_height(state, 480, 1600) == 540, "Stable substantial reduction releases resolution")

func test_off_screen_and_tiny_panes_pause() -> void:
	var view := Rect2(0, 0, 1600, 1000)
	expect(Client.visible_height(Rect2(100, 100, 800, 500), view) == 500, "Visible panes report their projected height")
	expect(Client.visible_height(Rect2(1200, -300, 800, 2000), view) == 2000, "Partly visible magnified panes keep full detail")
	expect(Client.visible_height(Rect2(1700, 100, 800, 500), view) == 0, "Panes beside the view are off-screen")
	expect(Client.visible_height(Rect2(100, -900, 800, 500), view) == 0, "Panes above the view are off-screen")
	expect(Client.chromium_readable_extent(Vector2(186, 1440), 3.0) == 62.0, "A tall sliver on a 3x phone is judged by its width in density-independent pixels")
	expect(Client.chromium_stream_paused({}, Client.chromium_readable_extent(Vector2(186, 1440), 3.0), 0), "A tiled phone sliver pauses")
	expect(not Client.chromium_stream_paused({}, Client.chromium_readable_extent(Vector2(960, 600), 3.0), 0), "A readable phone pane streams")
	expect(Client.chromium_readable_extent(Vector2(800, 500), 0.0) == 500.0, "A missing density counts as one")
	expect(not Client.chromium_stream_paused({}, Client.chromium_pause_extent(40.0, 0), 0), "A tiny visible pane streams until it has a first picture to keep")
	expect(Client.chromium_stream_paused({}, Client.chromium_pause_extent(40.0, 1), 0), "A tiny pane that has its picture pauses")
	expect(Client.chromium_stream_paused({}, Client.chromium_pause_extent(0.0, 0), 0), "An off-screen pane pauses even without a picture")
	expect(Client.chromium_stream_paused({}, 0, 0), "A pane first reported off-screen pauses at once")
	expect(Client.chromium_stream_paused({}, 60, 0), "A pane first reported unreadably small pauses at once")
	var state := {}
	expect(not Client.chromium_stream_paused(state, 1000, 0), "A readable pane streams")
	expect(not Client.chromium_stream_paused(state, 0, 100), "Leaving the view waits for the camera to settle")
	expect(not Client.chromium_stream_paused(state, 500, 300), "Returning within the settling time never paused")
	Client.chromium_stream_paused(state, 0, 400)
	expect(Client.chromium_stream_paused(state, 0, 900), "A settled off-screen pane pauses")
	expect(Client.chromium_stream_paused(state, 110, 1000), "Hysteresis keeps a pane near the threshold paused")
	expect(not Client.chromium_stream_paused(state, 130, 1001), "A readable pane resumes immediately")
	Client.chromium_stream_paused(state, 80, 1100)
	expect(Client.chromium_stream_paused(state, 80, 1600), "Shrinking below the readable size pauses after settling")
	var resumed := Peer.new()
	var connection := Connection.new()
	connection.socket = resumed
	connection.connected = true
	connection.subscribe([7])
	connection.set_chromium_viewports({7: 0})
	expect(int(resumed.sent.back().viewports.get("7", -1)) == 0, "A paused pane reports height zero to its owner")
	connection.free()

func test_resubscribe_restores_unchanged_chromium_demand() -> void:
	var connection := Connection.new()
	var peer := Peer.new()
	connection.socket = peer
	connection.connected = true
	connection.subscribe([7])
	connection.set_chromium_viewports({7: 240})
	connection.subscribe([])
	connection.subscribe([7])
	var last: Dictionary = peer.sent.back()
	expect(last.type == "chromium_stream" and int(last.viewports.get("7", 0)) == 240,
		"Returning to a pane restores its demand even though its height did not change")
	connection.free()
