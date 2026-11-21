extends SceneTree
var graph: Node
var overlay: Control
var failures: Array[String] = []
func check(ok: bool, text: String) -> void:
	if not ok: failures.append(text)
	print(("PASS " if ok else "FAIL ") + text)
func _initialize() -> void:
	# The application autoload must not retain a developer's startup config.
	var isolated := OS.get_cache_dir().path_join("queue-inspector-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(1000, 740)
	# The desktop app shows popups as their own OS windows (TerminalApplication).
	root.gui_embed_subwindows = not "--native-popups" in OS.get_cmdline_user_args()
	graph = preload("res://tests/support/ServerGraph.gd").new()
	graph.nodes = {"%1":{"provider":"adapter", "title":"Scheduled Trigger"}, "%2":{"provider":"adapter", "title":"Receiver"}}
	graph.register_ports("%1", {"inputs":[], "outputs":[{"id":"out","name":"Trigger"}]})
	graph.register_ports("%2", {"inputs":[{"id":"in","name":"Input"}], "outputs":[]})
	graph.connect_nodes({"from":"%1", "from_port":"out", "to":"%2", "to_port":"in"})
	overlay = preload("res://scenes/AgentGraphOverlay.gd").new()
	overlay.size = Vector2(1000,740)
	root.add_child(overlay)
	overlay.graph = graph
	overlay.sync({"%1":Rect2(80,100,250,180), "%2":Rect2(680,100,250,180)}, graph.edges.values(), func(p): return p, true)
	var sent: Dictionary = graph.enqueue("%1", "%2", "private payload", "message", "", "", "out", "in")
	await process_frame
	var queue: Dictionary = overlay.waiting.values()[0]
	var point: Vector2 = overlay.queue_indicator_position(queue)
	check(overlay.queue_hit(point) == queue.key, "Queue dot hit-testing uses its painted position")
	overlay.update_edge_hover(point)
	check(overlay.hover_edge == queue.key and overlay.edge_tooltip(queue.key).contains("1 pending"), "Hover queue dot describes only its connection")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = point
	overlay.tools._input(click)
	await process_frame
	await process_frame
	check(is_instance_valid(overlay.queue_inspector) and overlay.queue_inspector.visible, "Clicking the queue dot opens properties")
	var inspector = overlay.queue_inspector
	check(inspector.rows.size() == 1 and graph.queues["%2"].size() == 1, "Inspector observes without consuming the event")
	graph.ack("%2", sent.result.event_id, "delivered")
	await create_timer(0.4).timeout
	check(inspector.events.get_root().get_first_child().get_text(0).begins_with("[x]"), "Visible row updates to sent automatically")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/queue-inspector.png")
	check(inspector.size.y >= 400 and inspector.size.y <= mini(720, root.size.y), "Dialog stays within a usable height")
	check(inspector.run_budget.get_global_rect().end.y < inspector.size.y and inspector.stop_editor.get_global_rect().end.y < inspector.size.y, "Run budget and stop-time controls remain inside the dialog")
	inspector.hide()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.position = (overlay.links[0].points[0] + overlay.links[0].points[-1]) * 0.5
	overlay.tools._input(click)
	await process_frame
	var menu: PopupMenu = overlay.tools.wire_menu
	check(is_instance_valid(menu) and preload("res://scenes/PopupChrome.gd").is_open(menu) and not inspector.visible, "Right-click (touch hold) on a wire opens its context menu")
	check(menu.get_item_text(menu.get_item_index(overlay.tools.WireAction.PAUSE)) == "Pause connection", "Wire menu offers Pause for an active connection")
	var remove_index := menu.get_item_index(overlay.tools.WireAction.REMOVE)
	var danger: Color = preload("res://scenes/UIAccent.gd").DANGER
	check(menu.get_item_icon(remove_index) != null and menu.get_item_icon_modulate(remove_index) == danger, "Remove connection has a red trash icon")
	for i in 4: await process_frame
	var drawn = preload("res://scenes/PopupChrome.gd").presentation(menu)
	check(drawn != null and drawn.visible, "Wire menu is app-drawn so one item can be red (touch and desktop)")
	if drawn != null:
		var red_rows: Array = drawn.buttons.filter(func(row): return row.get_theme_color("font_color") == danger)
		check(red_rows.size() == 1 and red_rows[0].text == menu.tr("Remove connection") and red_rows[0].icon != null, "Menu draws only Remove connection in red, with its red icon")
		if preload("res://scenes/input/PointerPopup.gd").embedder_of(drawn) == null:
			var host_rect := Rect2i(root.position, root.size)
			check(host_rect.encloses(Rect2i(drawn.position, drawn.size)) and is_equal_approx(drawn.content_scale_factor, root.content_scale_factor), "Desktop menu window opens inside the app window at its HiDPI scale")
		var widest_text := 0.0
		for row in drawn.buttons: widest_text = maxf(widest_text, row.get_theme_font("font").get_string_size(row.text, HORIZONTAL_ALIGNMENT_LEFT, -1, row.get_theme_font_size("font_size")).x)
		check(drawn.buttons.all(func(row): return row.size.x >= widest_text), "Menu rows are wide enough for their labels")
		check(drawn.size.x > 0 and drawn.size.y > 0 and drawn.get_visible_rect().size.y >= drawn.rows.get_combined_minimum_size().y, "Menu window fits all of its rows")
	menu.id_pressed.emit(overlay.tools.WireAction.INSPECT)
	preload("res://scenes/PopupChrome.gd").close(menu)
	await process_frame
	check(inspector.visible, "Wire menu reopens history after queue empties")
	inspector.hide()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	overlay.tools._input(click)
	click.pressed = false
	overlay.tools._input(click)
	await create_timer(0.6).timeout
	check(inspector.visible, "Single-click empty wire opens delivery history")
	inspector.hide()
	click.pressed = true
	overlay.tools._input(click)
	click.pressed = false
	overlay.tools._input(click)
	await create_timer(0.1).timeout
	click.pressed = true
	click.double_click = true
	overlay.tools._input(click)
	click.pressed = false
	overlay.tools._input(click)
	await create_timer(0.6).timeout
	check(not inspector.visible and overlay.tools.visual().reroutes.size() == 1, "Double-click adds reroute without opening the inspector")
	var key: String = graph.edges.keys()[0]
	# The double-click above put a reroute at the midpoint; its own menu wins there.
	var wire_points: PackedVector2Array = overlay.links[0].points
	var wire_at: Vector2 = wire_points[wire_points.size() / 4]
	for expect_muted in [true, false]:
		click.button_index = MOUSE_BUTTON_RIGHT
		click.double_click = false
		click.pressed = true
		click.position = wire_at
		overlay.tools._input(click)
		await process_frame
		check(preload("res://scenes/PopupChrome.gd").is_open(menu), "Touch hold on %s wire opens its menu" % ("an active" if expect_muted else "a paused"))
		var undo_depth: int = overlay.tools.undo_stack.size()
		menu.id_pressed.emit(overlay.tools.WireAction.PAUSE)
		preload("res://scenes/PopupChrome.gd").close(menu)
		await process_frame
		check(graph.edges[key].get("muted", false) == expect_muted, "Wire menu %s the connection" % ("pauses" if expect_muted else "resumes"))
		check(overlay.tools.undo_stack.size() == undo_depth + 1, "Wire menu pause/resume is one undo step")
		if expect_muted:
			overlay.tools._input(click)
			await process_frame
			check(menu.get_item_text(menu.get_item_index(overlay.tools.WireAction.PAUSE)) == "Resume connection", "Paused wire's menu offers Resume")
			preload("res://scenes/PopupChrome.gd").close(menu)
	click.position = wire_at + Vector2(0, 18)
	overlay.tools._input(click)
	await process_frame
	check(not preload("res://scenes/PopupChrome.gd").is_open(menu), "A mouse right-click 18 px off the wire does not open its menu")
	click.set_meta("direct_touch", true)
	overlay.tools._input(click)
	await process_frame
	check(preload("res://scenes/PopupChrome.gd").is_open(menu), "A touch hold 18 px off the wire still opens its menu")
	# Activate Remove the way a user does: press and release on its drawn row.
	for i in 4: await process_frame
	var shown = preload("res://scenes/PopupChrome.gd").presentation(menu)
	var remove_row: Button = shown.buttons.filter(func(row): return row.text == menu.tr("Remove connection"))[0]
	var at: Vector2 = remove_row.get_global_rect().get_center() - shown.surface.position
	for pressed in [true, false]:
		var tap := InputEventMouseButton.new()
		tap.button_index = MOUSE_BUTTON_LEFT
		tap.pressed = pressed
		tap.position = at
		shown._pointer(tap)
	for i in 2: await process_frame
	check(graph.edges.is_empty(), "Clicking the red Remove connection row removes the connection")
	var journal: RefCounted = graph.queue_log
	overlay.free()
	check(journal.changed.get_connections().is_empty() and graph.changed.get_connections().is_empty(), "Closing the overlay disconnects inspector and graph subscriptions")
	graph.free()
	quit(0 if failures.is_empty() else 1)
