extends "res://tests/terminal_space_smoke.gd"
## Real workspace and camera integration; no GPU or native focus required.

class ObservedHost extends TestHost:
	func _configure_terminal_space(presenter: Node) -> void:
		presenter.terminal_space_scene = preload("res://tests/fixtures/ObservedTerminalSpace.tscn")
		super._configure_terminal_space(presenter)

func settle_layout() -> void:
	for i in 5: await process_frame

func run() -> void:
	var host := ObservedHost.new()
	root.add_child(host)
	await create_timer(0.5).timeout
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	host.session_model(host.active_session_id).pin_title("Stationary workspace")
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["physics"] = false
	host.world.fx_enabled = false
	host.world._settle_camera_at_rest()
	host.world._apply_camera_fx()
	await settle_layout()
	check(not view.is_processing(), "Workspace has no idle presentation polling loop")
	var before: Array = view.counters()
	for i in 20:
		host.world._apply_camera_fx()
		await process_frame
	check(view.link_updates == before[1] and view.raster_updates == before[2], "Stationary camera never reprojects links or reconciles the raster")
	# Resource samples may legitimately update the status text. Freeze just that
	# external source to isolate unchanged chrome from periodic telemetry.
	for source in view._status_sources.values():
		source.snapshot_changed.disconnect(view._resource_status_changed.bind(key))
	view._status_sources.clear()
	await settle_layout()
	before = view.counters()
	for i in 10: await process_frame
	check(view.counters() == before, "Unchanged workspace performs zero header/link/raster reconciliation")
	host.session_model(host.active_session_id).pin_title("Changed while the camera is still")
	await settle_layout()
	check(view.pane_titles[key].text == "Changed while the camera is still", "Session title event refreshes the projected title at rest")
	check(view.link_updates == before[1], "Title changes do not rebuild graph or chromium links")
	before = view.counters()
	view.overview = true
	view.navigation_center = view.size * 0.5
	view.navigation_zoom = 0.55
	view._apply_navigation()
	await settle_layout()
	check(view.link_updates > before[1] and view.status_strips.has(key), "Navigation updates projected links and compact resource strips")
	var decoration := Control.new()
	view.canvas_root.add_child(decoration)
	view.canvas_root.move_child(decoration, 0)
	var status_before: int = view.status_layout_updates
	view._invalidate_headers()
	await settle_layout()
	check(view.status_layout_updates == status_before, "Decorative siblings do not reflow status strips")
	view.raise_window(key)
	view._invalidate_headers()
	await settle_layout()
	check(view.status_layout_updates == status_before, "Raising the only pane past decoration does not reflow status strips")
	decoration.queue_free()
	before = view.counters()
	for i in 20: host.world.workspace_projection_changed.emit()
	await settle_layout()
	check(view.link_updates == before[1] + 1 and view.raster_updates == before[2] + 1, "Projection notifications in one frame coalesce into one reconciliation")
	before = view.counters()
	view.invalidate_during_header_update = true
	view._invalidate_headers()
	await settle_layout()
	check(view.link_updates == before[1] + 1 and not view._raster_dirty and not view._links_dirty, "Projection invalidation during a header pass is drained, not lost")
	var raster_before: Vector2i = view.canvas.size
	view.begin_navigation_render()
	view.navigation_zoom = 0.35
	view._apply_navigation()
	await settle_layout()
	check(view.canvas.size == raster_before, "Navigation holds its existing GPU allocation during the gesture")
	await create_timer(0.2).timeout
	check(view.canvas.size != raster_before and not view.holding_navigation_render_targets(), "Navigation expiry updates resolution once without continued camera motion")
	# Direct graph notifications must create provider sockets without a frame sync.
	var graph: Node = host.agent_api.graph
	graph.nodes[key] = {"node": key}
	graph.nodes[key]["manifest"] = preload("res://scenes/GraphPorts.gd").validate({"inputs": [{"id": "task"}], "outputs": [{"id": "result"}]}).manifest
	graph.changed.emit()
	check(view.agent_links.has_socket(key + "/task", false), "Graph changes immediately create advertised input sockets")
	var position: Vector2 = view.agent_links.port_center(key + "/task", false)
	view.navigation_center += Vector2(80, 35)
	view._apply_navigation()
	await settle_layout()
	check(not view.agent_links.port_center(key + "/task", false).is_equal_approx(position), "Camera movement reprojects existing graph sockets")
	position = view.agent_links.port_center(key + "/task", false)
	group.tree["tiling"] = false
	Layout.find(group.tree, key)["rect"] = Rect2(120, 180, 640, 400)
	view.refresh()
	await settle_layout()
	check(not view.agent_links.port_center(key + "/task", false).is_equal_approx(position), "Pane layout changes reproject graph sockets at rest")
	host.world.workspace_typed.emit()
	check(view.physics_typing and not view._typing_timer.is_stopped(), "Typing event pins its pane and starts an explicit expiry timer")
	await create_timer(0.5).timeout
	host.world.workspace_typed.emit()
	await create_timer(0.5).timeout
	check(view.physics_typing, "Later typing extends the pane hold")
	await create_timer(0.4).timeout
	check(not view.physics_typing and view._typing_timer.is_stopped(), "Typing expiry releases the pane without workspace frame polling")
	var old_world: Node = host.world
	check(host.switch_world("flat-2d"), "Flat 2D installs with the same observed workspace")
	await create_timer(0.3).timeout
	check(view._projection_world == host.world and not is_instance_valid(old_world), "World replacement rebinds projection notifications")
	host.world.fx_enabled = false
	host.world._settle_camera_at_rest()
	host.world._apply_camera_fx()
	await settle_layout()
	before = view.counters()
	for i in 20:
		host.world._apply_camera_fx()
		await process_frame
	check(view.link_updates == before[1] and view.raster_updates == before[2], "Flat 2D also leaves stationary link/raster state asleep")
	position = view.agent_links.port_center(key + "/task", false)
	view.navigation_center += Vector2(90, 20)
	view._apply_navigation()
	await settle_layout()
	check(not view.agent_links.port_center(key + "/task", false).is_equal_approx(position), "Flat 2D camera changes update projected sockets")
	# A cancelled cross-tab transfer does not trigger a layout pass after it
	# clears moving. The tile must immediately release its temporary pane glass.
	view.show_main()
	view.toggle_tiling()
	var pane: Control = view.panes[key]
	var style: StyleBoxFlat = pane.get_theme_stylebox("panel")
	check(is_equal_approx(style.bg_color.a, host.world.terminal_config.background.alpha) and style.border_width_top == 0, "Flat main-area tile keeps configured glass and hides its outer frame")
	var before_transfer: Rect2 = pane.layout_rect()
	view.moving = key
	# _drag_to restores the original tiled rectangle before starting a transfer.
	view.set_window_rect(key, before_transfer)
	pane._pressed = true
	pane._dragging = true
	pane._transfer = true
	host.application.begin_pane_drag(host, pane, key)
	check(is_equal_approx(style.bg_color.a, host.world.terminal_config.background.alpha) and style.border_width_top == 1, "Moving tile gets its own glass and frame")
	host.application.cancel_drag()
	check(view.moving.is_empty() and not pane._dragging and is_equal_approx(style.bg_color.a, host.world.terminal_config.background.alpha) and style.border_width_top == 0, "Cancelling a transfer restores the tiled frame immediately without changing its glass")
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
	print("WORKSPACE_UPDATES_PASS" if failures.is_empty() else "WORKSPACE_UPDATES_FAIL")
	quit(0 if failures.is_empty() else 1)
