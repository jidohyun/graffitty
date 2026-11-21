extends "../../../../replay/replay.gd"
## Exercise real GUI input and native terminal history; never emit value_changed manually.

func settle_scroll(bar: VScrollBar, expected: float) -> void:
	var deadline := Time.get_ticks_msec() + 3000
	while absf(bar.value - expected) > 1.0 and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

func middle(bar: VScrollBar) -> void:
	host.session_model(host.active_session_id).scroll_to((bar.max_value - bar.page) * .5)
	await settle_scroll(bar, (bar.max_value - bar.page) * .5)

func scrollbar_world() -> String:
	return "flat-2d"

## This case checks where the menu pill sits by default.
func keeps_floating_menu() -> bool:
	return true


func play() -> void:
	check(host.switch_world(scrollbar_world()), "Open scrollbar test world")
	await camera_at_rest()
	await wait(1.0)
	if OS.get_name() in ["Windows", "Linux"]:
		var tabs: Rect2 = host.workspace_view.tab_bar.get_global_rect()
		var menu: Rect2 = host.window_menu.get_global_rect()
		check(is_zero_approx(tabs.position.y), "Desktop tabs start at the top of the client area")
		check(tabs.size.y <= 44.0, "Desktop caption occupies one compact tab row")
		# The desktop menu floats over the workspace; it is not a menu-bar row.
		check(is_equal_approx(menu.position.y, tabs.end.y + 8.0), "Desktop menu floats just below the tabs")
		check(is_equal_approx(host.workspace_view._foreground_rect().position.y, tabs.end.y), "Workspace content starts directly below the tab row")
		check(is_equal_approx(host.workspace_view.viewport_content_rect().position.y + host.workspace_view.global_position.y, tabs.end.y), "The floating menu reserves no row in the pane layout")
	await type("1..2000 | ForEach-Object { $_ }{enter}" if OS.get_name() == "Windows" else "seq 1 2000{enter}")
	var bar: VScrollBar = host.workspace_view.get_node("WorldScrollBar")
	check(bar.get_viewport() == host.workspace_view.get_viewport(), "Scrollbar is in the interactive host viewport")
	var deadline := Time.get_ticks_msec() + 10000
	while (not bar.visible or bar.max_value < bar.page * 5) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(bar.visible and bar.max_value >= bar.page * 5, "Real shell output creates scrollback")
	if not bar.visible: return
	await camera_at_rest()
	var view: Control = host.workspace_view
	var terminal_presses := []
	host.sessions[host.active_session_id].term.gui_input.connect(func(event):
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed: terminal_presses.append(event))
	var original_pan: Vector2 = view.navigation_center
	var original_zoom: float = view.navigation_zoom
	var bounds := bar.get_global_rect()
	var center := bounds.get_center()
	var above := Vector2(center.x, bounds.position.y + bounds.size.y * .12)
	var below := Vector2(center.x, bounds.position.y + bounds.size.y * .88)

	await say("Drag the scrollbar thumb in both directions")
	await middle(bar)
	var before := bar.value
	await drag(center, center - Vector2(0, bounds.size.y * .2))
	check(bar.value < before - 10, "Dragging the thumb upward reveals older history")
	check(absf(host.session_model(host.active_session_id).scroll_offset - bar.value) < 1.0, "Thumb drag changes the terminal's actual scroll position")
	await middle(bar)
	before = bar.value
	await drag(center, center + Vector2(0, bounds.size.y * .2))
	check(bar.value > before + 10, "Dragging the thumb downward reveals newer history")

	await say("Click empty track above and below the thumb")
	for target in [above, below]:
		await middle(bar)
		before = bar.value
		await click(target)
		check(bar.value < before if target == above else bar.value > before, "Track click moves toward the pointer")

	await say("Hold the empty track, then release outside the scrollbar")
	for target in [above, below]:
		await middle(bar)
		await point_at(target)
		await press()
		var first_step := bar.value
		# Real time is required: replay pacing deliberately skips waits in test mode.
		await create_timer(.85).timeout
		check(bar.value < first_step if target == above else bar.value > first_step, "Holding the track repeats scrolling in the requested direction")
		await point_at(target - Vector2(80, 0))
		await release()
		var released := bar.value
		await create_timer(.35).timeout
		check(is_equal_approx(bar.value, released), "Release outside the track stops repeated scrolling")
	check(view.navigation_center.is_equal_approx(original_pan) and is_equal_approx(view.navigation_zoom, original_zoom), "Scrollbar interaction never pans or zooms the world")

	check(terminal_presses.is_empty(), "Scrollbar presses never reach terminal selection input")
