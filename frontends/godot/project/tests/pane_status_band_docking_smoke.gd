extends "res://tests/mods_fixture.gd"
## Top/bottom bands: the Pane Status and the status line dock there,
## beside each other or in rows above one another, each row with its own
## height. Same lifecycle/geometry assertions for both edges.
class SidePanel extends "res://scenes/DockableWindow.gd":
	var _list := VBoxContainer.new()
	func _create_content() -> Control: return _list

func run() -> void:
	var mobile := "--android" in OS.get_cmdline_user_args()
	var edge := "bottom" if "--bottom" in OS.get_cmdline_user_args() else "top"
	var axis := 3 if edge == "bottom" else 2
	var drag_delta := Vector2(0, -30 if edge == "bottom" else 30)
	setup(mobile)
	var left := SidePanel.new()
	left.persistence_key = "agents"
	root.add_child(left)
	left.present()
	var right := SidePanel.new()
	right.persistence_key = "sessions"
	root.add_child(right)
	right.present()
	space.widths = {"left": 80.0 if mobile else 240.0, "right": 80.0 if mobile else 240.0}
	space.commit(left._desktop, space.plan(left._desktop, Vector2.ZERO, "left"))
	space.commit(right._desktop, space.plan(right._desktop, Vector2.ZERO, "right"))
	var dialog: Window = PanelWindow.open(host, "pane-status")
	await settle()
	var dock: Control = dialog._desktop
	check(dock.side == "left" and not dialog.visible, "Pane Status docks into the left sidebar by default")
	# Band docking is tested from a floating window, as a title double-click leaves it.
	dialog.float_native()
	await settle()
	var target := Vector2(root.size.x * .5, space.bounds().end.y - 4 if edge == "bottom" else space.bounds().position.y + 4)
	check(space.plan(left._desktop, target, edge).is_empty() and space.plan(right._desktop, target, edge).is_empty(), "Left/right-only panels refuse " + edge + " docking")
	var plan: Dictionary = space.plan(dock, target)
	check(plan.get("side") == edge, "Main-area edge offers " + edge + " docking")
	if plan.is_empty(): quit(1); return
	# Preview must use the destination mode before drop, even though committed
	# side remains floating (or another dock). Exercise native-drag frame updates.
	for height in [space.MIN_BAND_HEIGHT, 160.0, space.MIN_BAND_HEIGHT]:
		space.band_rows[edge] = [height]
		dialog.set_meta(&"preferred_size", Vector2i(420, int(height)))
		var preview_plan: Dictionary = space.plan(dock, target)
		space.show_preview(preview_plan)
		dialog._native_drag = true
		dialog.geometry_changed()
		await settle(2)
		var expected_compact: bool = height < 100
		check(dialog.compact == expected_compact and dialog.compact_row == expected_compact, "Preview uses destination compact row through drag frames at height " + str(height))
		check(not dialog.visible and space.preview.is_ancestor_of(dialog._body), "Preview keeps the original live content and hides the floating source")
		check(space.preview.get_rect().is_equal_approx(preview_plan.rect), "Compact/expanded preview keeps the planned bounds")
	dialog._native_drag = false
	space.show_preview({})
	check(not dialog.compact and not dialog.compact_row and dialog.visible, "Cancel restores floating expanded presentation")
	dialog.set_meta(&"preferred_size", Vector2i(420, 160))
	space.band_rows[edge] = []
	var left_rect: Rect2 = left._desktop.get_rect()
	var right_rect: Rect2 = right._desktop.get_rect()
	plan = space.plan(dock, target)
	space.show_preview(plan)
	check(space.preview.get_rect().is_equal_approx(plan.rect) and space.preview.is_ancestor_of(dialog.view), "Preview owns the live view at its destination")
	check(host.workspace_view.insets[axis] > 0, "Preview reserves terminal height")
	space.show_preview({})
	check(host.workspace_view.insets[axis] == 0 and dialog.visible, "Cancel releases height and restores floating content")
	space.commit(dock, space.plan(dock, target))
	await settle(2)
	check(dock.side == edge and dock.get_rect().is_equal_approx(plan.rect), "Committed placement matches preview")
	check(is_equal_approx(dock.get_rect().end.y, space.bounds().end.y - space.gap()) if edge == "bottom" else dock.position.y == space.bounds().position.y + space.gap(), "Monitor aligns to its edge with configured gap")
	check(dock.position.x >= left_rect.end.x + space.gap() and dock.get_rect().end.x <= right_rect.position.x - space.gap(), "Monitor spans only main content, not either sidebar")
	check(left._desktop.get_rect() == left_rect and right._desktop.get_rect() == right_rect, "Sidebars retain their full height and geometry")
	check(host.workspace_view.insets[axis] == dock.size.y + space.gap(), "Terminal region excludes the complete band")
	check(dock._edge.mouse_default_cursor_shape == Control.CURSOR_VSIZE and dock._edge.is_in_group(&"touch_chrome"), "Inner edge resizes vertically and blocks workspace gestures")
	var old_height: float = dock.size.y
	var point: Vector2 = dock._edge.get_global_rect().get_center()
	if mobile:
		await touch_drag(point, point + drag_delta)
	else:
		var hover := InputEventMouseMotion.new()
		hover.position = point
		hover.global_position = point
		root.push_input(hover, true)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.position = point
		press.pressed = true
		root.push_input(press, true)
		hover.position += drag_delta
		hover.global_position = hover.position
		hover.relative = drag_delta
		hover.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(hover, true)
		press.pressed = false
		press.position = hover.position
		root.push_input(press, true)
	check(dock.size.y > old_height and host.workspace_view.insets[axis] == dock.size.y + space.gap(), "Dragging inward grows the band and updates terminal reservation")
	space.widths.left += 12
	space.reflow()
	check(dock.position.x == left._desktop.get_rect().end.x + space.gap(), "Band follows sidebar width changes")
	left.float_native()
	space.reflow()
	check(dock.position.x == space.gap() and dock.get_rect().end.x <= right._desktop.position.x - space.gap(), "Band expands only into the released left sidebar")
	right.float_native()
	space.reflow()
	check(dock.position.x == space.gap() and dock.size.x == space.bounds().size.x - 2 * space.gap(), "Without sidebars the band uses the main area's full width")
	space.commit(left._desktop, space.plan(left._desktop, Vector2.ZERO, "left"))
	space.commit(right._desktop, space.plan(right._desktop, Vector2.ZERO, "right"))
	dialog.set_workspace_active(false)
	space.set_workspace_active(false)
	check(not dock.is_visible_in_tree() and host.workspace_view.insets == Vector4.ZERO, "Manager hides dock and releases every reservation")
	space.set_workspace_active(true)
	dialog.set_workspace_active(true)
	check(dock.is_visible_in_tree() and host.workspace_view.insets[axis] > 0, "Returning restores the band reservation")
	host.sample.cpu = 65
	app.mods.publish_resources(host)
	await settle()
	check(has_text(dialog, "65.0%"), "Docked readout remains live")
	var full_height: float = space.band_rows[edge][0]
	space.band_rows[edge] = [0.0]
	space.reflow()
	await settle(2)
	check(dock.size.y == space.MIN_BAND_HEIGHT and host.workspace_view.insets[axis] == dock.size.y + space.gap(), "Band shrinks to one row and reserves only that height")
	check(dialog.compact and dialog.compact_row and not dock._header.visible, "Shrunk band switches to the compact status-strip row")
	var shown := texts(dialog)
	check("65%" in shown and "%1" in shown and "1M" in shown, "Compact row shows pane and live metrics: %s" % [shown])
	var pane_rect: Rect2 = dialog.view.hit_rect("pane")
	check(pane_rect.size.x > 0 and dialog.view.hit_rect("readout").size.x == 0, "Row layout replaces the readout")
	if not mobile:
		var body: Control = dialog._body
		var grab: Vector2 = body.get_global_rect().get_center()
		var down := InputEventMouseButton.new()
		down.button_index = MOUSE_BUTTON_LEFT
		down.pressed = true
		down.position = grab
		down.global_position = grab
		root.push_input(down, true)
		check(dock.dragging, "Compact band body is the move/undock drag target")
		dock.finish(true)
	space.band_rows[edge] = [full_height]
	space.reflow()
	await settle()
	check(not dialog.compact and not dialog.compact_row and dock._header.visible, "Growing the band restores the full readout")
	# A second band panel: beside the monitor, then in its own row above/below it.
	var status: Window = PanelWindow.open(host, "status-line")
	await settle()
	var status_dock: Control = status._desktop
	var beside: Dictionary = space.plan(status_dock, Vector2(dock.get_rect().end.x - 20, dock.get_rect().get_center().y))
	check(beside.get("side") == edge and beside.get("row") == 0 and beside.rows[0].size() == 2 and beside.rows[0][1] == status_dock, "Dropping on a band panel's right half plans a side-by-side cell after it")
	check(beside.rect.size.y == dock.size.y and beside.rect.position.x > dock.position.x, "The new cell shares the row's height and sits to the right")
	space.commit(status_dock, beside)
	await settle(2)
	check(status_dock.side == edge and status_dock.row == 0 and status_dock.position.y == dock.position.y and status_dock.position.x >= dock.get_rect().end.x + space.gap(), "Committed cell sits right of the monitor in the same row")
	check(dock._divider.visible and dock._divider.mouse_default_cursor_shape == Control.CURSOR_HSIZE, "Side-by-side panels share a horizontal-resize divider")
	var monitor_width: float = dock.size.x
	dock.begin_resize(dock._divider.get_global_rect().get_center(), "band_weight")
	dock.resize_to(dock._divider.get_global_rect().get_center() + Vector2(60, 0))
	dock.finish()
	check(dock.size.x > monitor_width and dock.get_rect().end.x + space.gap() <= status_dock.position.x + 1, "Dragging the divider changes the row's proportions without overlap")
	var outer_y := dock.position.y - 4 if edge == "top" else dock.get_rect().end.y + 4
	var stacked: Dictionary = space.plan(status_dock, Vector2(dock.get_rect().get_center().x, outer_y))
	check(stacked.get("side") == edge and stacked.rows.size() == 2 and stacked.get("row") == (0 if edge == "top" else 1), "Dropping at the band's outer edge plans a new row " + ("above" if edge == "top" else "below") + " the monitor")
	space.commit(status_dock, stacked)
	await settle(2)
	var above := status_dock.get_rect().end.y <= dock.position.y if edge == "top" else status_dock.position.y >= dock.get_rect().end.y
	check(above and status_dock.size.x == dock.size.x, "The new row spans the band width " + ("above" if edge == "top" else "below") + " the monitor")
	check(host.workspace_view.insets[axis] == dock.size.y + status_dock.size.y + 2 * space.gap(), "The reservation covers both rows and the gap between them")
	var status_height: float = status_dock.size.y
	status_dock.begin_resize(status_dock._edge.get_global_rect().get_center(), "band_height")
	status_dock.resize_to(status_dock._edge.get_global_rect().get_center() + drag_delta)
	status_dock.finish()
	check(status_dock.size.y > status_height and dock.size.y == full_height, "Each row resizes independently")
	space.save_layout()
	var saved := Space.new()
	saved.state_path = space.state_path
	root.add_child(saved)
	saved.load_layout()
	check(saved.band_rows[edge].size() == 2 and saved._saved.status_line.row != saved._saved.pane_status.row and saved._saved.pane_status.side == edge, "Current v1 state restores rows, placement and heights")
	saved.free()
	status._close_panel()
	await settle(2)
	check(host.workspace_view.insets[axis] == dock.size.y + space.gap(), "Closing a row releases only its height")
	dialog._close_panel()
	await settle(2)
	check(host.workspace_view.insets[axis] == 0 and host.workspace_view.insets.x > 0 and host.workspace_view.insets.y > 0, "Closing monitor releases only its height")
	dialog = PanelWindow.open(host, "pane-status")
	await settle()
	check(dialog._desktop.side == edge, "Reopening restores placement")
	dialog.float_native()
	await settle(2)
	check(host.workspace_view.insets[axis] == 0 and dialog.visible, "Undocking restores floating monitor without band reservation")
	var opposite := "top" if edge == "bottom" else "bottom"
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2.ZERO, opposite))
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2.ZERO, edge))
	check(host.workspace_view.insets[5 - axis] == 0 and host.workspace_view.insets[axis] > 0, "Switching between top and bottom releases the previous reservation")
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2.ZERO, "left"))
	check(dialog._desktop.side == "left" and host.workspace_view.insets[axis] == 0, "Monitor can move back into a sidebar")
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2.ZERO, edge))
	root.size.y = 180
	await settle(2)
	space.reflow()
	check(dialog._desktop.side == edge and not dialog.visible and host.workspace_view.insets[axis] > 0, "Insufficient height retains monitor docking without creating a floating window")
	dialog.queue_free(); left.queue_free(); right.queue_free()
	await settle(2)
	check(host.workspace_view.insets == Vector4.ZERO, "Closing all panels releases all reservations")
	finish("PANE_STATUS_BAND_DOCK_" + edge.to_upper())

func touch_drag(from: Vector2, to: Vector2) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = root.get_final_transform() * from
	event.pressed = true
	Input.parse_input_event(event)
	await create_timer(.1).timeout
	for i in range(1, 9):
		var motion := InputEventScreenDrag.new()
		motion.index = 0
		motion.position = root.get_final_transform() * from.lerp(to, float(i) / 8)
		motion.relative = (to - from) * root.content_scale_factor / 8
		Input.parse_input_event(motion)
		await create_timer(.04).timeout
	event.position = root.get_final_transform() * to
	event.pressed = false
	Input.parse_input_event(event)
	await create_timer(.2).timeout
