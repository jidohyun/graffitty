extends "res://tests/mods_fixture.gd"
## The status line: a bottom/top-only band showing the window's session and
## agents, with an adaptive zoom effect switch that runs an action.

func run() -> void:
	setup("--android" in OS.get_cmdline_user_args())
	app.agents.rows = [{"id": "a", "key": "%1", "title": "One", "provider": "pi", "status": "blocked", "section": "Needs you", "at": 0, "focused": false, "pinned": false, "remote": "", "session": ""}]
	app.agents.changed.emit()
	var dialog: Window = PanelWindow.open(host, "status-line")
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Status line mod loads: " + dialog.view.last_error())
	check(dialog.dock_sides() == ["top", "bottom"], "Status line docks only at the top or bottom")
	var dock: Control = dialog._desktop
	check(space.plan(dock, Vector2(640, 400), "left").is_empty(), "Left docking is refused")
	var shown := texts(dialog)
	check(not "12%" in shown and not "1M" in shown, "No resource readout; that is the Resource Monitor's: %s" % [shown])
	check(("1 agent" in shown and "· 1 needs you" in shown) or ("1" in shown and "· 1" in shown), "Agent count and who needs you, including the phone-width form")
	check(dock.side == "bottom" and dock.size.y == 28, "The status line defaults to a 28-pixel bottom band: %s" % [dock.size])
	check(dialog.dock_only() and not dock._header.visible and not dialog.visible and dialog._body.visible and dialog.view.size.y >= 20, "The bar shows its content without a title, close button or floating window")
	dialog.set_folded(true)
	dialog.float_native()
	await settle()
	check(not dialog.folded and dock.side == "bottom" and not dialog.visible, "The bar refuses folding and floating")
	var body_point := dock.get_global_rect().get_center()
	await click_at(body_point, true)
	check(not dialog.folded and dock.side == "bottom" and not dialog.visible, "Double-clicking the bar leaves its content docked")
	await drag_between(body_point, space.bounds().get_center())
	check(dock.side == "bottom" and not dialog.visible and not space.preview.visible, "Dropping away from an edge leaves the bar in its original dock")
	app.mods.host.publish("session@%d" % host.get_instance_id(), JSON.stringify({"id": "$3", "name": "api", "server": "shared://local", "local": true, "connected": true}))
	await settle()
	shown = texts(dialog)
	check("api" in shown and "$3" in shown and "session" in dialog.view.hit_keys(), "The window's session shows as name and id: %s" % [shown])
	var saved_agents: Array = app.agents.rows.duplicate(true)
	app.agents.rows = []
	app.agents.changed.emit()
	await settle()
	check(not "agents" in dialog.view.hit_keys() and not "0 agents" in texts(dialog), "Zero agents hides the entire status chip")
	app.agents.rows = saved_agents
	app.agents.changed.emit()
	await settle()
	var keys: PackedStringArray = dialog.view.hit_keys()
	check("camera.zoom" in keys and not "camera.tilt" in keys and not "pane_zoom" in keys, "Only the adaptive zoom effect has a switch: %s" % [keys])
	check(not "Adaptive zoom effect" in shown, "The effect switch uses an icon at full width: %s" % [shown])
	check(dialog.view.get_tooltip(dialog.view.hit_rect("camera.zoom").get_center()) == "Adaptive zoom effect", "The tooltip names the effect")
	dialog.view.click("camera.zoom")
	pump()
	check(host.effect_switches.keys() == ["camera.zoom"], "A switch runs ToggleEffect for its effect only: %s" % [host.effect_switches.keys()])
	await settle()
	check(dialog.view.last_error().is_empty() and "camera.zoom" in dialog.view.hit_keys(), "The switch re-renders from the published state and stays clickable")
	check(dialog.view.get_tooltip(dialog.view.hit_rect("camera.zoom").get_center()) == "Adaptive zoom effect", "Disabling the effect keeps its tooltip concise")
	dialog.view.click("camera.zoom")
	pump()
	check(host.effect_switches.is_empty(), "Clicking again switches the effect back on")
	check(host.profile_set.is_empty(), "The switches never change the effects profile")
	# A phone-width bar: informational labels shrink, while the effect icons
	# remain reachable without overlapping each other or leaving the bar.
	app.mods.host.publish("session@%d" % host.get_instance_id(), JSON.stringify({"id": "$1", "name": "godot-ghostty", "server": "shared://local", "local": true, "connected": true}))
	var full_size: Vector2 = dialog.view.size
	dialog.view.size = Vector2(360, full_size.y)
	await settle()
	dialog.view.render_now()
	var order := ["session", "agents", "prefix", "camera.zoom"]
	var previous_end := 0.0
	var overlaps := []
	for id in order:
		var rect: Rect2 = dialog.view.hit_rect(id)
		if not rect.has_area(): continue
		if rect.position.x < previous_end - .5 or rect.end.x > 360.5: overlaps.append("%s %s" % [id, rect])
		previous_end = maxf(previous_end, rect.end.x)
	check(overlaps.is_empty() and dialog.view.hit_rect("agents").has_area() and dialog.view.hit_rect("camera.zoom").has_area(), "At 360 px every part fits without overlapping: %s" % [overlaps])
	var narrow := texts(dialog)
	check(not "Adaptive zoom effect" in narrow and not Array(narrow).any(func(t): return str(t).begins_with("Prefix")), "Narrow: switches show icons, not labels: %s" % [narrow])
	check(dialog.view.get_tooltip(dialog.view.hit_rect("camera.zoom").get_center()).begins_with("Adaptive zoom effect"), "An icon switch still names itself in its tooltip")
	dialog.view.size = full_size
	await settle()
	check(not "Adaptive zoom effect" in texts(dialog), "Wide again: the effect switch remains an icon")
	# The prefix switch: always the key's compact keycap, named in its tooltip;
	# arms the prefix on a tap, cancels on the next.
	shown = texts(dialog)
	check("prefix" in dialog.view.hit_keys() and not Array(shown).any(func(t): return str(t).begins_with("Prefix")), "Wide: the prefix stays a keycap, not a label: %s" % [shown])
	check(dialog.view.get_tooltip(dialog.view.hit_rect("prefix").get_center()).begins_with("Prefix "), "The prefix keycap names the prefix key in its tooltip")
	dialog.view.click("prefix")
	pump()
	check(host.prefix_commands.active, "Tapping the prefix switch arms the prefix")
	await settle()
	check(dialog.view.last_error().is_empty() and "prefix" in dialog.view.hit_keys(), "The armed state re-renders from the published prefix state")
	dialog.view.click("prefix")
	pump()
	check(not host.prefix_commands.active, "Tapping again cancels the prefix")
	check(host.effect_switches.is_empty(), "The prefix switch touches no effect")
	# Dock at the bottom: one row by default, with a usable height resize edge.
	var plan: Dictionary = space.plan(dock, Vector2(root.size.x * .5, space.bounds().end.y - 4))
	check(plan.get("side") == "bottom" and plan.rect.size.y == 28, "Bottom edge offers a one-row band")
	space.commit(dock, plan)
	await settle()
	check(dock.side == "bottom" and host.workspace_view.insets.w == dock.size.y + space.gap(), "Docked status line reserves exactly its height")
	check(dialog.compact and dialog.compact_row, "A 28-pixel bar uses its row layout")
	# A bar is exactly as tall as its content: its row has no height to drag.
	check(not dock._edge.visible, "The bar's row offers no height resize edge")
	var edge_point := Vector2(dock.get_global_rect().get_center().x, dock.get_global_rect().position.y - 2)
	await drag_between(edge_point, edge_point - Vector2(0, 90))
	await settle()
	check(dock.size.y == 28 and host.workspace_view.insets.w == dock.size.y + space.gap(), "Dragging above the bar does not make it taller: %s" % dock.size.y)
	check(not dock._header.visible and "camera.zoom" in dialog.view.hit_keys(), "The bar shows content and controls without title chrome")
	await drag_between(dock.get_global_rect().get_center(), Vector2(root.size.x * .5, space.bounds().position.y + 4))
	check(dock.side == "top" and dock.size.y == 28 and not dialog.visible and not dock._header.visible, "Dragging to the top moves the bar at its own height without a window")
	await drag_between(dock.get_global_rect().get_center(), Vector2(root.size.x * .5, space.bounds().end.y - 4))
	check(dock.side == "bottom" and dock.size.y == 28, "The bar can move back to the bottom")
	space.save_layout()
	var saved := Space.new()
	saved.state_path = space.state_path
	root.add_child(saved)
	saved.load_layout()
	check(saved._saved.status_line.side == "bottom" and saved.band_rows.bottom == space.band_rows.bottom, "Placement and row height persist in the v1 dock document")
	saved.free()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="):
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(arg.trim_prefix("--capture="))
	PanelWindow.toggle(host, "status-line")
	await settle()
	check(PanelWindow.find(host, "status-line") == null and not space._saved.status_line.open, "The View menu toggle closes the bar and remembers it is off")
	PanelWindow.toggle(host, "status-line")
	await settle()
	dialog = PanelWindow.find(host, "status-line")
	check(dialog != null and dialog._desktop.side == "bottom" and dialog._desktop.size.y == 28, "The menu toggle restores the bar at its own height")
	dialog.queue_free()
	await settle()
	# Saved placement is subject to the bar's current capabilities. A folded
	# status strip must reveal its content; a floating placement is inadmissible.
	space._saved.status_line.folded = true
	space._saved.status_line.side = "top"
	dialog = PanelWindow.open(host, "status-line")
	await settle()
	check(dialog._desktop.side == "top" and not dialog.folded and dialog.view.is_visible_in_tree() and not dialog._desktop._header.visible, "Restoring folded placement keeps the valid edge and shows status content")
	dialog.queue_free()
	await settle()
	space._saved.status_line.side = ""
	dialog = PanelWindow.open(host, "status-line")
	await settle()
	check(dialog._desktop.side == "bottom" and not dialog.visible and not dialog.folded, "A disallowed saved floating placement uses the bar's default dock")
	dialog.queue_free()
	await settle()
	finish("STATUS_LINE")


func click_at(point: Vector2, double := false) -> void:
	if "--android" in OS.get_cmdline_user_args():
		for i in (2 if double else 1):
			var touch := InputEventScreenTouch.new()
			touch.index = 0
			touch.position = point
			touch.pressed = true
			root.push_input(touch, true)
			touch.pressed = false
			root.push_input(touch, true)
		await settle()
		return
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = point
	event.global_position = point
	event.double_click = double
	event.pressed = true
	root.push_input(event, true)
	event.pressed = false
	root.push_input(event, true)
	await settle()


func drag_between(start: Vector2, end: Vector2) -> void:
	if "--android" in OS.get_cmdline_user_args():
		var press := InputEventScreenTouch.new()
		press.index = 0
		press.position = start
		press.pressed = true
		root.push_input(press, true)
		var motion := InputEventScreenDrag.new()
		motion.index = 0
		motion.position = end
		motion.relative = end - start
		root.push_input(motion, true)
		press.position = end
		press.pressed = false
		root.push_input(press, true)
	else:
		var hover := InputEventMouseMotion.new()
		hover.position = start
		hover.global_position = start
		root.push_input(hover, true)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.position = start
		press.global_position = start
		press.pressed = true
		root.push_input(press, true)
		hover.position = end
		hover.global_position = end
		hover.relative = end - start
		hover.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(hover, true)
		press.position = end
		press.global_position = end
		press.pressed = false
		root.push_input(press, true)
	await settle()
