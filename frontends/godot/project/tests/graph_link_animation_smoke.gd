extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0

func check(value: bool, label: String) -> void:
	print("PASS " if value else "FAIL ", label)
	if not value: failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1100, 700)
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	# Advertised ports exercise the same server authority as the application.
	graph.nodes = {"%0": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}, "%1": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}, "%2": {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}}
	var canvas := Control.new()
	root.add_child(canvas)
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var rectangles := {"%0": Rect2(80, 280, 200, 150), "%1": Rect2(760, 110, 220, 150), "%2": Rect2(760, 430, 220, 150)}
	for key in rectangles:
		var panel := Panel.new()
		canvas.add_child(panel)
		panel.position = rectangles[key].position
		panel.size = rectangles[key].size
		var label := Label.new()
		panel.add_child(label)
		label.position = Vector2(16, 16)
		label.text = key
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.graph = graph
	for pair in [["%0", "%1"], ["%1", "%0"], ["%2", "%0"]]:
		graph.connect_nodes({"from": pair[0], "to": pair[1], "send": true})
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	check(not overlay.is_processing(), "Idle links do not schedule animation frames")
	var geometry_before: int = overlay.geometry_rebuilds
	var sent: Dictionary = graph.enqueue("%0", "%1", "test", "message")
	check(overlay.waiting.size() == 1 and overlay.pulses.is_empty(), "Queued message blinks without flowing")
	check(overlay.geometry_rebuilds == geometry_before, "Queue changes do not rebuild unchanged wire geometry")
	overlay.hide()
	check(overlay.waiting.is_empty() and not overlay.is_processing(), "Hidden queued links stop scheduling animation frames")
	overlay.show()
	check(overlay.waiting.size() == 1 and overlay.is_processing(), "Showing queued links restores their markers from the visibility event")
	await create_timer(0.2).timeout
	check(overlay.blink_time > 0 and overlay.pulses.is_empty(), "Queue blink advances while its dot stays stationary")
	graph.progress("%1", {"event_id": sent.result.event_id, "message": "Waiting for another branch"})
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	check(overlay.waiting.size() == 1 and overlay.waiting.values()[0].received, "Received-but-pending marker moves to the receiver")
	check(overlay.geometry_rebuilds == geometry_before, "Delivery progress changes marker state without rebuilding wire geometry")
	check(overlay.pulses.is_empty() and graph.queues["%1"].size() == 1, "Progress retains the queued event without a final delivery pulse")
	check("pending" in overlay.edge_tooltip("%0/out>%1/in") and "Waiting for another branch" in overlay.edge_tooltip("%0/out>%1/in"), "Pending edge explains which work it is waiting for")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-queued.png")
	graph.ack("%1", sent.result.event_id, "delivered")
	check(overlay.waiting.is_empty(), "Delivery clears the queued indicator")
	check(overlay.pulses.size() == 1, "Accepted graph delivery starts one pulse")
	var reverse: Dictionary = graph.enqueue("%1", "%0", "reply", "message")
	graph.ack("%0", reverse.result.event_id, "delivered")
	check(not overlay._route("%1", "%0", "%1/out>%0/in").reverse and overlay._route("%1", "%0", "%1/out>%0/in").link.source == "%1", "Reply travels along its own directed return wire")
	var backward: Dictionary = graph.enqueue("%2", "%0", "backward link", "message")
	graph.ack("%0", backward.result.event_id, "delivered")
	await create_timer(0.75).timeout
	check(overlay.pulses.size() == 3 and overlay.pulses[0].distance > 120, "Live processing advances all message pulses")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-animation.png")
	graph.disconnect_nodes("%0", "%1")
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	await process_frame
	await process_frame
	check(overlay.pulses.size() == 2, "Disconnect removes only that direction's pulse")
	var rejected: Dictionary = graph.enqueue("%1", "%0", "rejected", "message")
	graph.ack("%0", rejected.result.event_id, "failed: test")
	check(overlay.pulses.size() == 3 and overlay.pulses[-1].get("failed", false), "Failed delivery starts a red cross instead of a success dot")
	var cancelled: Dictionary = graph.enqueue("%2", "%0", "cancel me", "message")
	graph.disconnect_nodes("%2", "%0")
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	await create_timer(0.6).timeout
	var crosses := overlay.pulses.filter(func(pulse): return pulse.get("failed", false))
	check(crosses.size() == 2, "Both failure and disconnect cancellation produce crosses")
	check(crosses[1].event_id == cancelled.result.event_id and crosses[1].distance > 100, "Cancellation cross keeps moving after its edge is removed")
	check(overlay.waiting.is_empty(), "Cancelled queues stop blinking")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-graph-failed.png")
	await create_timer(7.0).timeout
	check(overlay.pulses.is_empty() and not overlay.is_processing(), "Completed animations release frame processing")
	# A tiny gap previously finished before a person could notice it.
	graph.disconnect_nodes("%1", "%0")
	graph.connect_nodes({"from": "%0", "to": "%1", "send": true})
	rectangles["%1"] = Rect2(312, 280, 220, 150)
	overlay.sync(rectangles, graph.edges.values(), func(point): return point, true)
	var short_send: Dictionary = graph.enqueue("%0", "%1", "short link", "message")
	graph.ack("%1", short_send.result.event_id, "delivered")
	await create_timer(0.6).timeout
	check(overlay.pulses.size() == 1 and overlay.pulses[0].distance > 0, "Short link send remains visible for at least 1.2 seconds")
	await create_timer(0.9).timeout
	check(overlay.pulses.is_empty() and not overlay.is_processing(), "One traversal returns the wire to normal without looping")
	# A duplicate receipt must not restart a completed animation.
	graph.ack("%1", short_send.result.event_id, "delivered")
	check(overlay.pulses.is_empty(), "Duplicate acknowledgment does not replay the send")
	# Theme/font minimums can resize a newly added socket after initial sync.
	# Its visible center and the established wire must move in the same layout.
	var socket: Button = overlay.sockets(true)["%0/out"]
	var before_height := socket.size.y
	socket.custom_minimum_size.y = before_height + 32
	socket.add_theme_font_size_override("font_size", 40)
	for i in 3: await process_frame
	check(socket.size.y >= before_height + 32, "A theme change resizes the socket to its new minimum")
	var resized_link: Dictionary = overlay._route("%0", "%1", "%0/out>%1/in").link
	check(resized_link.points[0].is_equal_approx(overlay.port_center("%0/out", true)),
		"Resized socket keeps its wire endpoint on the visible center")
	canvas.free()
	graph.free()
	quit(1 if failures else 0)
