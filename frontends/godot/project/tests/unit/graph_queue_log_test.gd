extends "res://tests/unit/test_case.gd"
const Journal := preload("res://scenes/GraphQueueLog.gd")
const Graph := preload("res://tests/support/ServerGraph.gd")

class ObservedInspector extends "res://scenes/GraphQueueInspector.gd":
	var refresh_count := 0
	func refresh(force := false) -> void:
		refresh_count += 1
		super.refresh(force)

func test_inspector_coalesces_changes_and_does_not_poll_hidden_or_unrelated_queues() -> void:
	var graph := Graph.new()
	var inspector := ObservedInspector.new()
	inspector._ready()
	inspector._bind_graph(graph)
	inspector.edge_key = "%1>%2"
	inspector.visible = true
	inspector.refresh()
	var count := inspector.refresh_count
	record(graph.queue_log, event("a"), "queued", true)
	record(graph.queue_log, event("a"), "sent", false)
	expect(inspector.refresh_count == count, "Queue bursts do not rebuild the tree synchronously")
	inspector._flush_refresh()
	expect(inspector.refresh_count == count + 1 and inspector.rows[0].status == "sent", "A coalesced refresh shows the latest delivery state")
	count = inspector.refresh_count
	var other := event("b")
	other.target = "%3"
	record(graph.queue_log, other, "queued", true)
	graph.changed.emit()
	inspector._flush_refresh()
	expect(inspector.refresh_count == count, "Unrelated queues and graph metadata do not snapshot the journal")
	inspector.visible = false
	record(graph.queue_log, event("c"), "queued", true)
	inspector._flush_refresh()
	expect(inspector.refresh_count == count, "Hidden inspectors perform no journal refresh")
	inspector.visible = true
	# Unit windows are outside a SceneTree, which normally sends this event.
	inspector.visibility_changed.emit()
	inspector._flush_refresh()
	expect(inspector.rows.size() == 2, "Reopening catches changes made while hidden")
	inspector._disconnect_graph()
	expect(not graph.queue_log.changed.is_connected(inspector._journal_changed), "Inspector releases its journal subscription")
	inspector.free()
	graph.free()

func event(id: String) -> Dictionary:
	return {"event_id":id, "source":"%1", "target":"%2", "kind":"test", "created":1.0, "text":"private", "payload":{"secret":"private"}, "sessions":[{"path":"/private"}]}

func test_connection_inspector_updates_in_place_and_excludes_other_wires() -> void:
	var g := Graph.new()
	g.nodes = {"%1":{"provider":"claude"}, "%2":{"provider":"codex"}, "%3":{"provider":"codex"}}
	g.connect_nodes({"from":"%1", "to":"%2", "send":true})
	g.connect_nodes({"from":"%1", "to":"%3", "send":true})
	var sent: Dictionary = g.enqueue("%1", "%2", "private", "message")
	g.enqueue("%1", "%3", "other private", "message")
	var key := g.event_edge(g.queues["%2"][0])
	var inspector := preload("res://scenes/GraphQueueInspector.gd").new()
	inspector._ready()
	inspector.graph = g
	inspector.edge_key = key
	inspector.refresh(true)
	expect(inspector.rows.size() == 1 and inspector.summary.text.contains("pane %1"), "Wire inspector shows only its connection with public pane names")
	expect(inspector.events.get_root().get_first_child().get_text(0).begins_with("[ ]"), "Pending delivery starts unchecked")
	expect(g.queues["%2"].size() == 1, "Opening the inspector does not consume input")
	var item_id := inspector.events.get_root().get_first_child().get_instance_id()
	g.ack("%2", sent.result.event_id, "delivered")
	inspector.refresh()
	expect(inspector.events.get_root().get_first_child().get_instance_id() == item_id, "Delivery status updates preserve the existing TreeItem")
	expect(inspector.rows.size() == 1 and inspector.events.get_root().get_first_child().get_text(0).begins_with("[x]"), "The same row becomes sent")
	expect(inspector.selected == sent.result.event_id and inspector.details.text.contains("queued in Graffitty") and inspector.details.text.contains("sent to receiver"), "Selection and full transition history survive updates")
	expect(not inspector.details.text.contains("private"), "Inspection does not expose message contents")
	inspector.pending_only.button_pressed = true
	expect(inspector.rows.is_empty(), "Pending-only filter hides completed rows")
	inspector.free()
	g.free()

func record(log: RefCounted, event: Dictionary, status: String, pending: bool) -> void:
	var id := str(event.event_id)
	var rows: Dictionary = log.entries.duplicate(true)
	rows[id] = {"event_id":id,"source":event.source,"target":event.target,"edge":event.source+">"+event.target,"kind":"test","queued_at":1.0,"updated_at":2.0,"status":status,"pending":pending,"transitions":[],"run_id":""}
	var counts := {}
	var pending_count := 0
	for row in rows.values():
		if not counts.has(row.edge): counts[row.edge] = {"total":0,"pending":0}
		counts[row.edge].total += 1
		if row.pending:
			counts[row.edge].pending += 1
			pending_count += 1
	log.import_snapshot(null, {"events":rows.values(),"pending":pending_count,"omitted":0,"by_edge":counts})
