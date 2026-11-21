extends "res://tests/mods_fixture.gd"

func click_title(panel: Control, touch := false, canceled := false) -> void:
	var title: Control = panel._header.get_child(0)
	var press: InputEvent = InputEventScreenTouch.new() if touch else InputEventMouseButton.new()
	if not touch: press.button_index = MOUSE_BUTTON_LEFT
	press.position = title.size / 2
	press.pressed = true
	title.gui_input.emit(press)
	var release: InputEvent = press.duplicate()
	release.pressed = false
	if touch: release.canceled = canceled
	panel._input(release)
	await settle()

func floating_event(panel: Window, point: Vector2, pressed: bool, motion := false, touch := false, canceled := false, index := 0) -> void:
	var event: InputEvent
	if touch:
		event = InputEventScreenDrag.new() if motion else InputEventScreenTouch.new()
		event.index = index
	else:
		event = InputEventMouseMotion.new() if motion else InputEventMouseButton.new()
		if not motion: event.button_index = MOUSE_BUTTON_LEFT
	if not motion:
		event.pressed = pressed
		event.canceled = canceled
	if panel.force_native:
		event.window_id = panel.get_window_id()
		event.position = (point - Vector2(panel.position)) / panel.content_scale_factor
		if event is InputEventMouse: event.global_position = event.position
		panel.push_input(event, true)
	else:
		event.position = point
		space._input(event)

func run() -> void:
	var mobile := "--mobile" in OS.get_cmdline_user_args()
	setup(mobile)
	root.content_scale_factor = 1.5 if "--scaled" in OS.get_cmdline_user_args() else 1.0
	var panel := PanelWindow.open(host, "agents")
	var other := PanelWindow.open(host, "sessions")
	await settle()
	var expanded: float = panel._desktop.size.y
	var neighbor: float = other._desktop.size.y
	await click_title(panel._desktop, mobile)
	check(panel.folded and not panel._body.visible and panel._desktop._header.visible, "A title click folds a docked panel and retains its title")
	check(panel._desktop.size.y == space.MIN_BAND_HEIGHT and other._desktop.size.y > neighbor, "Folding releases stack space to the adjacent panel")
	await click_title(panel._desktop, mobile)
	check(not panel.folded and panel._body.visible and is_equal_approx(panel._desktop.size.y, expanded), "A second title click restores stack proportions")
	await click_title(panel._desktop, true, true)
	check(not panel.folded, "Canceled title touches never fold")
	panel._desktop.begin_drag(panel._desktop.position + Vector2(50, 10))
	panel._desktop._fold_on_click = true
	panel._desktop.drag_to(panel._desktop.position + Vector2(80, 10))
	panel._desktop.finish(true)
	check(not panel.folded, "A canceled title drag never folds")
	other._close_panel()
	await settle()
	panel.float_native()
	await settle()
	var size_before := panel.size
	var position_before := panel.position
	var title: Vector2 = panel._title_rect().get_center()
	floating_event(panel, title, true, false, mobile)
	floating_event(panel, title, false, false, mobile)
	await settle()
	check(panel.folded and not panel._body.visible and panel.size.y < size_before.y, "A floating title click rolls up the body")
	check(panel.position == position_before, "Folding retains the floating title position")
	floating_event(panel, title, true)
	floating_event(panel, title, false)
	await settle()
	check(not panel.folded and panel.size == size_before, "Unfolding restores the floating size")
	floating_event(panel, title, true)
	floating_event(panel, title + Vector2(20, 0), true, true)
	floating_event(panel, title, false)
	check(not panel.folded, "A title drag returning to its origin does not count as a click")
	if mobile:
		var cover := Window.new()
		cover.visible = false
		cover.borderless = true
		root.add_child(cover)
		cover.position = panel.position - Vector2i(0, 30)
		cover.size = panel.size
		cover.show()
		cover.grab_focus()
		await settle()
		floating_event(panel, title, true, false, true)
		floating_event(panel, title, false, false, true)
		check(not panel.folded, "A window covering a floating title blocks taps on that title")
		cover.queue_free()
		await settle()
	floating_event(panel, title, true, false, true)
	floating_event(panel, title, false, false, true, true)
	check(not panel.folded, "Canceled floating title contact never folds")
	floating_event(panel, title, true)
	floating_event(panel, title, false, false, false, true)
	check(not panel.folded, "Canceled mouse release never folds")
	floating_event(panel, title, true)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	if panel.force_native: panel.push_input(escape, true)
	else: space._input(escape)
	floating_event(panel, title, false)
	check(not panel.folded, "Escape cancels floating title folding")
	floating_event(panel, title, true, false, true)
	floating_event(panel, title + Vector2(10, 0), true, false, true, false, 1)
	floating_event(panel, title, false, false, true)
	check(not panel.folded, "A second contact cancels floating title folding")
	floating_event(panel, title, true)
	panel.focus_exited.emit()
	floating_event(panel, title, false)
	check(not panel.folded, "Focus loss cancels floating title folding")
	var target: Vector2 = space.local_to_screen(Vector2(1, 200)) if panel.force_native else Vector2(1, 200)
	floating_event(panel, title, true)
	floating_event(panel, target, true, true)
	check(space.preview.visible and space.preview.is_ancestor_of(panel._body), "A title motion moves live content into the dock preview")
	if panel.force_native:
		check(panel.visible and not panel._frame.visible, "Native preview keeps an invisible mapped window for the original input stream")
	floating_event(panel, title, true, true)
	check(not space.preview.visible and panel.visible and panel._body.get_parent() == panel, "Moving out of the preview restores the floating panel immediately")
	check(panel._body.offset_top == panel.TITLE_HEIGHT, "Restored content stays below the application title")
	floating_event(panel, title, false)
	check(not panel.folded and not panel._native_drag, "Release after leaving preview ends movement without folding")
	floating_event(panel, title, true)
	floating_event(panel, target, true, true)
	floating_event(panel, target, false)
	check(panel._desktop.side == "left" and not panel.visible and not space.preview.visible, "Release over preview commits docking through input events")
	panel.float_native()
	panel.set_folded(true)
	panel._close_panel()
	await settle()
	space.load_layout()
	check(space._saved.agents.folded, "Folded state reloads from the current saved-layout schema")
	panel = PanelWindow.open(host, "agents")
	await settle()
	check(panel.folded and panel._desktop.side.is_empty() and not panel._body.visible, "Reopening preserves a floating panel's folded state")
	space.dock_default(panel._desktop, "left")
	await settle()
	check(panel.folded and not panel._body.visible and panel._desktop._header.visible, "A folded floating panel can dock without reopening its body")
	panel.float_native()
	await settle()
	panel.set_folded(false)
	check(panel.min_size.y > 1, "Restoring a folded floating panel retains the expanded minimum")
	var monitor := PanelWindow.open(host, "resource-monitor")
	await settle()
	var band_height: float = monitor._desktop.size.y
	await click_title(monitor._desktop, mobile)
	check(monitor.folded and monitor._desktop.size.y == space.MIN_BAND_HEIGHT, "A band's title folds its row")
	await click_title(monitor._desktop, mobile)
	check(not monitor.folded and is_equal_approx(monitor._desktop.size.y, band_height), "Unfolding restores the band's height")
	if not mobile:
		# Viewport injection does not move the OS pointer into this native window.
		panel._floating_close.notification(Control.NOTIFICATION_MOUSE_ENTER)
		var close_point: Vector2 = Vector2(panel.position) + panel._floating_close.get_global_rect().get_center() * panel.content_scale_factor
		floating_event(panel, close_point, false, true)
		floating_event(panel, close_point, true)
		floating_event(panel, close_point, false)
		check(panel.is_queued_for_deletion() and not panel.folded, "The floating close button closes without folding")
	finish("PANEL_FOLDING")
