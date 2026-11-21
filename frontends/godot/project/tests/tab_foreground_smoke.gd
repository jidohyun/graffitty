extends "res://tests/terminal_space_smoke.gd"

var clicks := 0

func tap(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion, true)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame

func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(.5).timeout
	var view: Control = host.workspace_view
	var probe := Button.new()
	probe.size = Vector2(100, 20)
	probe.position = Vector2(1000, 5)
	probe.pressed.connect(func(): clicks += 1)
	view.foreground_root.add_child(probe)
	await process_frame
	check(view.foreground_root.global_position.is_equal_approx(view.global_position), "Foreground preserves full-window coordinates")
	check(view.foreground_clip.clip_contents, "Foreground clipping applies to drawing and input")
	await tap(view.global_position + probe.position + probe.size * .5)
	check(clicks == 0, "Workspace control behind tab row does not receive clicks")
	probe.position.y = 60
	await tap(view.global_position + probe.position + probe.size * .5)
	check(clicks == 1, "Workspace control below tabs receives clicks in original coordinates")
	view.tab_bar.offset_bottom = 100
	for i in 3: await process_frame
	check(view.foreground_clip.position.y == 100, "Taller tab strip updates foreground clip by signal")
	check(view.foreground_root.global_position.is_equal_approx(view.global_position), "Taller tabs preserve global overlay coordinates")
	await tap(view.global_position + probe.position + probe.size * .5)
	check(clicks == 1, "Taller tabs suppress input to newly covered workspace controls")
	view.overview = true
	view.navigation_zoom = .3
	view.navigation_center = view.size * .5
	view._apply_navigation()
	for i in 5: await process_frame
	check(not view.status_strips.is_empty(), "Overview creates real status strips")
	for strip in view.status_strips.values():
		var rect: Rect2 = view._status_navigation_transform() * view.control_canvas_rect(strip)
		check(strip.get_parent() == view.canvas_root and (not strip.visible or rect.position.y >= 100), "Status strip is baked below tabs on the clipped workspace sheet")
	view.tab_bar.hide()
	for i in 3: await process_frame
	check(view.foreground_clip.position.y == 0 and view.foreground_clip.size == view.size, "Hidden tabs restore full foreground area")
	probe.position.y = 5
	await tap(view.global_position + probe.position + probe.size * .5)
	check(clicks == 2, "Hidden tabs restore input at the top of the workspace")
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
	print("TAB_FOREGROUND_PASS" if failures.is_empty() else "TAB_FOREGROUND_FAIL")
	quit(0 if failures.is_empty() else 1)
