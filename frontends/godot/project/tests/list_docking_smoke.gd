extends SceneTree
## A plain dockable window with a list body stands in for any panel.
class Base extends "res://scenes/DockableWindow.gd":
	var _list := VBoxContainer.new()
	func _create_content() -> Control: return _list
## Inject the display-server observations while exercising the real title handlers.
class MousePanel extends Base:
	var driver := "macOS"
	var pointer := Vector2.ZERO
	var down := true
	var windows_preview := ""
	func _screen_pointer() -> Vector2: return pointer
	func _left_mouse_down() -> bool: return down
	func _start_desktop_mouse_move(_driver := DisplayServer.get_name()) -> bool:
		return super(driver)
	func _system_window_move() -> void:
		notification(NOTIFICATION_WM_POSITION_CHANGED)
		windows_preview = _native_candidate.get("side", "")
		pointer = _desktop.space.local_to_screen(Vector2(1278, 200))
		down = false
## A band panel, such as the status line or Graffitty messages.
class Band extends Base:
	var default_side := ""
	var default_row := "inner"
	func dock_sides() -> Array[String]: return ["top", "bottom", "left", "right"]
	func default_dock_side() -> String: return default_side
	func default_dock_row() -> String: return default_row
class View extends Control:
	var tab_bar := Control.new()
	var toolbar: Control
	var insets := Vector4.ZERO
	func _ready() -> void:
		add_child(tab_bar)
		tab_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		tab_bar.offset_bottom = 34
	func set_dock_insets(value: Vector4) -> void: insets = value
class Host extends Node:
	var tiling_config := {"gap": 8.0}
	var layout_root := Control.new()
	var workspace_view := View.new()
	func _ready() -> void:
		add_child(layout_root)
		layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layout_root.add_child(workspace_view)
		workspace_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
class Space extends "res://scenes/ListDockSpace.gd":
	var test_hosts: Array = []
	func _window_hosts() -> Array: return test_hosts

var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)
func check_boundary_resize(panel: Control) -> void:
	await process_frame
	var point := panel.get_global_rect().get_center()
	point.x = panel.get_global_rect().end.x + panel.space.gap() + 2 if panel.side == "left" else panel.position.x - panel.space.gap() - 2
	check(panel._edge.get_global_rect().has_point(point), "Resize target spans the configured gap into the adjacent terminal on " + panel.side)
	var hover := InputEventMouseMotion.new()
	hover.position = point
	hover.global_position = point
	root.push_input(hover, true)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.position = point
	press.global_position = point
	press.pressed = true
	root.push_input(press, true)
	check(panel._sizing == "width", "Pressing the terminal-side edge starts sidebar resizing on " + panel.side)
	var before: float = panel.size.x
	hover.relative = Vector2(12 if panel.side == "left" else -12, 0)
	hover.position += hover.relative
	hover.global_position = hover.position
	hover.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(hover, true)
	check(panel.size.x > before, "Dragging the shared boundary resizes the sidebar on " + panel.side)
	panel.finish(true)
	press.pressed = false
	root.push_input(press, true)

func check_desktop_mouse_drag(space: Space) -> void:
	var panel := MousePanel.new()
	root.add_child(panel)
	panel.present()
	var origin := panel.position
	var grab := Vector2(40, 12)
	var title_point := Vector2(origin) + grab
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	panel._title_event(press, title_point)
	panel._title_event(motion, title_point + Vector2(7, 0))
	check(panel.transient and not panel._native_drag, "Seven pixels of title motion keeps the dialog attached")
	panel._title_event(release, title_point + Vector2(7, 0))
	check(panel.folded, "A sub-threshold title release folds the panel")
	panel.toggle_fold()
	panel._title_event(press, title_point)
	panel._title_event(motion, title_point + Vector2(8, 0))
	panel._title_event(motion, title_point + Vector2(80, 0))
	check(not panel.transient and panel.position == origin, "Threshold detaches the Mac dialog and motion events never place it")
	panel.pointer = space.local_to_screen(Vector2(1, 200))
	await process_frame
	await process_frame
	check(panel.position == Vector2i(panel.pointer - grab) and panel.visible and panel._native_candidate.get("side") == "left", "Mac frame follows the global pointer and previews the left dock")
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.keycode = KEY_ESCAPE
	panel._title_event(esc, Vector2.ZERO)
	check(panel.transient and panel.position == origin and not space.preview.visible, "Escape reattaches the Mac dialog at its original position")
	panel._title_event(press, title_point)
	panel._title_event(motion, title_point + Vector2(8, 0))
	panel.pointer = space.local_to_screen(Vector2(1278, 200))
	panel.down = false
	panel._title_event(release, Vector2.ZERO)
	panel.pointer = space.local_to_screen(Vector2(640, 300))
	await process_frame
	await process_frame
	check(panel.transient and panel._desktop.side == "right" and not space.preview.visible, "Release between frames commits the sampled right dock and reattaches")
	panel.float_native()
	panel.down = true
	title_point = Vector2(panel.position) + grab
	panel._title_event(press, title_point)
	panel._title_event(motion, title_point + Vector2(8, 0))
	panel.down = false
	await process_frame
	await process_frame
	check(panel.transient and not panel._title_pressed and panel.position == Vector2i(panel.pointer - grab), "Physical release without mouse-up finishes a floating Mac drop")
	panel.driver = "Windows"
	panel.down = true
	panel.pointer = space.local_to_screen(Vector2(1, 200))
	title_point = Vector2(panel.position) + grab
	panel._title_event(press, title_point)
	panel._title_event(motion, title_point + Vector2(8, 0))
	check(panel.windows_preview == "left" and panel._desktop.side == "right", "Windows move notification previews and move-loop exit commits the final pointer")
	panel.queue_free()
	await process_frame
	await process_frame

func _initialize() -> void: run.call_deferred()
func run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_factor = 1
	root.size = Vector2i(1280, 800)
	root.gui_embed_subwindows = false
	var host := Host.new()
	root.add_child(host)
	host.layout_root.offset_top = 30
	var space := Space.new()
	space.state_path = OS.get_cache_dir().path_join("gft-dock-test-%d.json" % OS.get_process_id())
	DirAccess.remove_absolute(space.state_path)
	root.add_child(space)
	space.test_hosts = [host]
	root.set_meta(&"list_dock_space", space)
	await check_desktop_mouse_drag(space)
	var a := Base.new()
	a.title = "Agents"
	a.persistence_key = "agents"
	root.add_child(a)
	a.present()
	var b := Base.new()
	b.title = "Sessions"
	b.persistence_key = "sessions"
	root.add_child(b)
	b.present()
	await process_frame
	check(a.visible and not a.is_embedded() and not a.unresizable, "Floating list is a native, resizable Window")
	check(a.is_ancestor_of(a._list), "Native window owns live content")
	var other_window := Window.new()
	other_window.gui_embed_subwindows = true
	root.add_child(other_window)
	other_window.show()
	var other_panel := Base.new()
	other_window.add_child(other_panel)
	other_panel.present()
	var floating_rects := [Rect2i(a.position, a.size), Rect2i(b.position, b.size)]
	space.toggle_panels()
	check(not a.visible and not b.visible, "Toggle Side Panels hides floating tool windows")
	check(other_panel.visible, "Another window keeps its panels visible")
	var hidden_new := Base.new()
	root.add_child(hidden_new)
	hidden_new.present()
	check(not hidden_new.visible, "A panel opened while hidden stays hidden")
	a.raise_panel()
	check(not a.visible, "Raising a panel does not bypass the shared visibility toggle")
	space.toggle_panels()
	check(a.visible and b.visible and hidden_new.visible, "Toggle restores existing and newly opened panels")
	check([Rect2i(a.position, a.size), Rect2i(b.position, b.size)] == floating_rects, "Floating geometry survives hiding")
	other_window.queue_free()
	hidden_new._close_panel()
	await process_frame
	await process_frame
	check(a._resize_grip.text.is_empty() and not a._resize_grip.visible, "Native window has no triangle grip")
	var normal := Rect2i(a.position, a.size)
	if DisplayServer.get_name() != "headless":
		a.toggle_fit()
		await create_timer(.15).timeout
		check(a.mode == Window.MODE_MAXIMIZED, "Native zoom fits the screen without fullscreen")
		a.toggle_fit()
		await create_timer(.15).timeout
		check(a.mode == Window.MODE_WINDOWED and Rect2i(a.position, a.size) == normal, "Native zoom restores original size and position")
	var first: Control = a._desktop
	var second: Control = b._desktop
	for control in [first._edge, first._divider, first._header.get_child(0), first._header.get_child(1), a._resize_grip]:
		check(control.tooltip_text.is_empty() and not control.accessibility_name.is_empty(), "Obvious chrome has no tooltip but retains its accessible name")
	for panel in [first, second]:
		var close: Button = panel._header.get_child(1)
		check(close.get_theme_stylebox("hover").bg_color == Color("c42b1c"), "Shared dock close button has red hover background")
		check(close.get_theme_color("font_hover_color") == Color.WHITE, "Close glyph stays legible on red hover")
		check(close.get_theme_stylebox("normal").bg_color == Color.TRANSPARENT, "Close button returns to transparent outside hover")
	for window in [a, b]:
		for edge in ["left", "right"]:
			var original_width: float = space.widths[edge]
			for width in [44.0, 240.0, 120.0, 44.0]:
				space.widths[edge] = width
				var preview_plan: Dictionary = space.plan(window._desktop, Vector2(1, 200), edge)
				space.show_preview(preview_plan)
				window._native_drag = true
				window.geometry_changed()
				await process_frame
				await process_frame
				check(window.compact == (width < space.COMPACT_WIDTH) and not window.compact_row and window._desktop._header.visible == (width >= space.COMPACT_WIDTH), window.title + " preview retains destination rail layout through drag updates")
				check(space.preview.get_rect().is_equal_approx(preview_plan.rect), window.title + " preview matches narrow/wide target bounds")
			window._native_drag = false
			space.show_preview({})
			check(window.visible and not window.compact and window.is_ancestor_of(window._body), window.title + " cancellation restores floating content and layout")
			space.widths[edge] = original_width
			space.reflow()
	var tab_width := host.workspace_view.tab_bar.size.x
	var plan: Dictionary = space.plan(first, Vector2(1, 200))
	var live_label := Label.new()
	live_label.text = "Working"
	live_label.clip_text = true
	a._list.add_child(live_label)
	var live_body: Control = a._body
	space.show_preview(plan)
	check(space.preview.visible, "Exact destination preview is shown")
	check(not a.visible and not first.visible, "Preview hides the source window and original dock")
	check(space._preview_content == live_body and space.preview.is_ancestor_of(a._list), "Preview owns the actual live controls, not a copy")
	await process_frame
	check(space.preview.is_ancestor_of(first._header) and first._header.visible, "Live preview includes the actual panel title header")
	check(first._header.size.y == 20 and first._header.get_child(0).get_child(0).get_theme_font_size("font_size") == 11, "Panel title uses compact 20-pixel chrome and 11-pixel text")
	live_label.text = "Done"
	check(space.preview.is_ancestor_of(live_label) and live_label.text == "Done", "Status updates remain live inside the preview")
	space.show_preview({})
	check(a.visible and a.is_ancestor_of(live_body), "Leaving the target restores the same native content")
	check(first._header.get_parent() == first.slot.get_parent(), "Cancel restores header ownership without duplication")
	space.show_preview(plan)
	a._native_drag = true
	a._drag_origin = normal
	a.cancel_native_drag()
	check(a.visible and not space.preview.visible and a.is_ancestor_of(live_body), "Canceling a hidden native drag restores its content")
	space.show_preview(plan)
	a.set_workspace_active(false)
	check(not a.visible and not space.preview.visible, "Leaving the workspace clears the hidden-window preview")
	a.set_workspace_active(true)
	check(a.visible and a.is_ancestor_of(live_body), "Returning restores a window hidden by preview")
	space.show_preview(plan)
	space.commit(first, plan)
	check(first.position == plan.rect.position and first.size.is_equal_approx(plan.rect.size), "Dock commit matches preview rectangle")
	check(not a.visible and first.is_ancestor_of(a._list), "Dock transfers existing content and hides native window")
	var pointer := preload("res://scenes/input/MobilePointer.gd").new()
	root.add_child(pointer)
	pointer.set_process(false)
	pointer.set_process_input(false)
	pointer.gestures = preload("res://scenes/input/TouchNavigation.gd").new()
	var panel_point: Vector2 = first.get_global_transform_with_canvas() * (first.size * .5)
	check(pointer._over_touch_chrome(panel_point), "Entire dock body blocks workspace touch acquisition")
	check(first._edge.is_in_group(&"touch_chrome") and first._divider.is_in_group(&"touch_chrome"), "Resize targets also block workspace gestures")
	# The committed rectangle reaches the panel's children on the next layout pass.
	await process_frame
	await process_frame
	var body_point: Vector2 = first.slot.get_global_rect().get_center()
	var edge_point: Vector2 = first._edge.get_global_rect().get_center()
	var title_point: Vector2 = first._header.get_global_rect().get_center()
	check(pointer._yields_at(body_point) and not pointer._yields_at(edge_point) and not pointer._yields_at(title_point), "Only the dock content yields a resting finger to a pinch; its title and resize targets keep theirs")
	var contact := InputEventScreenTouch.new()
	contact.pressed = true
	contact.position = Vector2(500, 300)
	pointer.gestures.handle(contact, 0)
	var motion := InputEventScreenDrag.new()
	motion.position = Vector2(560, 300)
	pointer.gestures.handle(motion, 10)
	contact.index = 1
	contact.position = body_point
	pointer._input(contact)
	check(pointer.gestures.fingers.size() == 1, "Dock touch cannot join a workspace drag under way")
	motion.index = 1
	motion.position = Vector2(500, 300)
	pointer._input(motion)
	contact.pressed = false
	contact.position = motion.position
	pointer._input(contact)
	check(pointer.gestures.fingers.size() == 1, "Dock contact stays isolated through dragging outside and release")
	pointer.gestures.cancel()
	contact.index = 0
	contact.pressed = true
	contact.position = Vector2(500, 300)
	pointer.gestures.handle(contact, 0)
	contact.index = 1
	contact.position = edge_point
	pointer._input(contact)
	check(pointer.gestures.fingers.size() == 1, "A resize target never joins, even beside a resting workspace finger")
	contact.pressed = false
	pointer._input(contact)
	contact.pressed = true
	contact.position = body_point
	pointer._input(contact)
	check(pointer.gestures.fingers.size() == 2, "A finger on the dock content joins a resting workspace finger as a pinch")
	pointer.gestures.cancel()
	pointer.free()
	check(first.is_ancestor_of(first._header), "Drop keeps the same header with the docked content")
	check(first.position.y >= host.workspace_view.tab_bar.get_global_rect().end.y, "Dock starts below the tab bar")
	check(first._edge.color.a == 0 and first._edge.get_child_count() == 0 and first._edge.size.x > 1, "Sidebar resize target is invisible with no vertical line")
	check(host.layout_root.offset_left == 0 and host.workspace_view.tab_bar.size.x == tab_width and host.workspace_view.insets.x > 0, "Dock narrows content, never the tab area")
	plan = space.plan(second, Vector2(1, 100))
	check(plan.rect.size.y < space.bounds().size.y, "Second-panel preview shows its actual divided destination")
	var unsplit := first.size.y
	space.show_preview(plan)
	check(first.size.y < unsplit and not Rect2(first.position, first.size).intersects(plan.rect), "Preview immediately lays out neighbors, not a blue overlay")
	space.show_preview({})
	check(is_equal_approx(first.size.y, unsplit), "Canceled preview restores the original layout")
	check(b.visible and b.is_ancestor_of(b._list), "Cancel restores the floating window without duplicate content")
	space.commit(second, plan)
	check(second.size.is_equal_approx(plan.rect.size), "Stacked drop occupies the exact preview")
	check(second._divider.color.a == 0 and second._divider.get_child_count() == 0, "Stack divider has no painted bar")
	check(second._divider.size.y == space.gap() + 5, "Stack divider spans the gap and desktop edge target")
	for configured_gap in [0.0, 8.0, 24.0]:
		host.tiling_config.gap = configured_gap
		space.reflow()
		var stacked: Array = space.column("left")
		check(is_equal_approx(stacked[0].position.x, configured_gap) and is_equal_approx(stacked[0].position.y, space.bounds().position.y + configured_gap), "Sidebar outer margins follow tiling gap")
		check(is_equal_approx(stacked[1].position.y - stacked[0].get_rect().end.y, configured_gap), "Stacked panels share the configured tiling gap, including zero")
		var divider: Rect2 = stacked[0]._divider.get_global_rect()
		check(is_equal_approx(divider.position.y, stacked[0].get_global_rect().end.y - 5) and is_equal_approx(divider.end.y, stacked[1].global_position.y), "Invisible divider covers the entire gap without stealing the next title")
		check(is_equal_approx(stacked[1].get_rect().end.y, space.bounds().end.y - configured_gap), "Bottom margin uses the same gap")
		check(is_equal_approx(host.workspace_view.insets.x, stacked[0].size.x + configured_gap), "Main content reservation includes the outside gap exactly once")
		await check_boundary_resize(stacked[0])
	host.tiling_config.gap = 8.0
	space.reflow()
	check(space.column("left")[0] == second, "Dropping above another panel changes stack order")
	if DisplayServer.get_name() != "headless":
		root.grab_focus()
		await create_timer(.1).timeout
		var hover := InputEventMouseMotion.new()
		hover.position = second._divider.get_global_rect().get_center()
		hover.global_position = hover.position
		root.notify_mouse_entered()
		root.push_input(hover, true)
		await process_frame
		check(DisplayServer.cursor_get_shape() == DisplayServer.CURSOR_VSIZE, "Hovering the actual divider shows the vertical resize cursor")
	var height := second.size.y
	second.begin_resize(second.position + Vector2(20, height), "height")
	second.resize_to(second.position + Vector2(20, height + 70))
	second.finish()
	check(second.size.y > height and not Rect2(first.position, first.size).intersects(Rect2(second.position, second.size)), "Stack divider changes proportions without overlap")
	var ratio: float = second.weight / first.weight
	var original_size := root.size
	var preferred_width: float = space.widths.left
	root.size = Vector2i(220, 180)
	await process_frame
	space.reflow()
	check(first.side == "left" and second.side == "left" and not a.visible and not b.visible, "Shrinking the app never detaches existing sidebar panels")
	check(space.widths.left == preferred_width and is_equal_approx(second.weight / first.weight, ratio), "Temporary size constraints preserve preferred width and stack proportions")
	root.size = original_size
	await process_frame
	space.reflow()
	check(first.side == "left" and first.size.x >= 40, "Expanding restores the same dock ownership")
	root.size.y += 100
	await process_frame
	space.reflow()
	check(is_equal_approx(second.weight / first.weight, ratio), "Stack proportions survive window resizing")
	first.begin_resize(first.position + Vector2(first.size.x, 20), "width")
	first.resize_to(first.position + Vector2(first.size.x + 55, 20))
	first.finish()
	check(first.size.x > 300 and is_equal_approx(first.size.x + space.gap(), host.workspace_view.insets.x), "Sidebar width plus configured outside margin reserves content")
	var expanded: float = space.widths.left
	space.toggle_fold("left")
	check(first.size.x == 44 and a.compact and b.compact and not first._header.visible, "Folded sidebar is a narrow strip without an expand button")
	first.begin_resize(first._edge.get_global_rect().get_center(), "width")
	first.resize_to(first._edge.get_global_rect().get_center() - Vector2(100, 0))
	first.finish()
	await process_frame
	check(first.size.x == 40 and a._body.size.x <= 40, "Sidebar and its content shrink to herdr's 40-pixel minimum")
	space.widths.left = 44
	space.reflow()
	space.save_layout()
	check(second._divider.z_index > 0 and second._divider.mouse_default_cursor_shape == Control.CURSOR_VSIZE, "Divider retains hit priority and resize cursor")
	var saved := Space.new()
	saved.state_path = space.state_path
	root.add_child(saved)
	saved.load_layout()
	check(saved.widths.left == 44 and saved._saved.sessions.side == "left" and saved._saved.sessions.open, "Fold, placement and open state persist")
	check(is_equal_approx(saved._saved.sessions.weight / saved._saved.agents.weight, ratio), "Saved layout retains stack proportions")
	saved.free()
	space.toggle_fold("left")
	check(is_equal_approx(first.size.x, expanded) and not a.compact, "Rail restores the previous expanded width")
	plan = space.plan(first, Vector2(1278, 200))
	space.show_preview(plan)
	check(not first.visible and space.preview.is_ancestor_of(a._list), "Moving a dock hides its old location during live preview")
	space.commit(first, plan)
	check(first.side == "right" and host.workspace_view.insets.y > 0, "Dock can move to the other side")
	for configured_gap in [0.0, 8.0, 24.0]:
		host.tiling_config.gap = configured_gap
		space.reflow()
		await check_boundary_resize(first)
	host.tiling_config.gap = 8.0
	space.reflow()
	first.begin_drag(first.position + Vector2(30, 15))
	first.drag_to(Vector2(650, 350))
	first.finish()
	check(first.side.is_empty() and a.visible and a.is_ancestor_of(a._list), "Drag away returns the same content to its native window")
	var screen_pointer: Vector2 = space.local_to_screen(Vector2(650, 350))
	check(screen_pointer.y >= a.position.y and screen_pointer.y < a.position.y + a.floating_title_height(), "Undocking anchors the pointer inside title chrome, not content")
	check(screen_pointer.x >= a.position.x and screen_pointer.x < a.position.x + a.size.x, "Undocking preserves a horizontal title-bar grab")
	check(host.workspace_view.insets.y == 0, "Undocking releases its content inset")
	b._close_panel()
	await process_frame
	check(not space._saved.sessions.open and space._saved.sessions.side == "left", "Closing remembers its position but not open state")
	b = Base.new()
	b.persistence_key = "sessions"
	root.add_child(b)
	b.present()
	check(b._desktop.side == "left" and not b.visible, "Reopening restores the last dock without dragging")
	var status := Band.new()
	status.persistence_key = "status_line"
	status.set_meta(&"preferred_size", Vector2i(420, 32))
	root.add_child(status)
	status.present()
	check(status.visible and status._desktop.side.is_empty(), "A band panel without a default side floats")
	check(space.dock_default(status._desktop, "bottom") and status._desktop.side == "bottom" and status._desktop.row == 0 and not status.visible, "Programmatic docking adds a bottom row")
	await process_frame
	var status_inset: float = host.workspace_view.insets.w
	var status_height: float = status._desktop.size.y
	var messages := Band.new()
	messages.persistence_key = "messages"
	messages.default_side = "bottom"
	messages.default_row = "outer"
	messages.set_meta(&"preferred_size", Vector2i(420, 180))
	root.add_child(messages)
	messages.present()
	await process_frame
	check(not messages.visible and messages._desktop.side == "bottom", "A default bottom side docks on first open instead of floating")
	check(messages._desktop.row == 1 and status._desktop.row == 0, "An outer-row default goes to the window edge; the status line keeps the terminal-facing row")
	check(status._desktop.position.y + status._desktop.size.y <= messages._desktop.position.y, "Messages sit below the status line without overlap")
	var inner := Band.new()
	inner.persistence_key = "inner_band"
	inner.default_side = "bottom"
	inner.set_meta(&"preferred_size", Vector2i(420, 32))
	root.add_child(inner)
	inner.present()
	await process_frame
	check(inner._desktop.row == 0 and status._desktop.row == 1 and messages._desktop.row == 2, "An inner-row default still takes the terminal-facing row and pushes the others outward")
	inner._close_panel()
	await process_frame
	await process_frame
	check(status._desktop.row == 0 and messages._desktop.row == 1, "Closing the inner row renumbers the remaining rows")
	check(is_equal_approx(messages._desktop.size.y, 180) and is_equal_approx(status._desktop.size.y, status_height), "Each row keeps its own height")
	check(messages._desktop.position.x >= b._desktop.position.x + b._desktop.size.x, "Band rows stay clear of the left dock")
	check(host.workspace_view.insets.w > status_inset + 100, "The messages row shrinks the terminal area")
	messages._close_panel()
	await process_frame
	await process_frame
	check(status._desktop.row == 0 and is_equal_approx(status._desktop.size.y, status_height), "Closing the outer row leaves the status line in place with its height")
	check(is_equal_approx(host.workspace_view.insets.w, status_inset), "Closing the row returns the terminal area")
	# A layout saved before messages moved outward still restores them below the status line.
	space._saved.messages = {"side": "bottom", "row": 0, "own_row": true, "height": 180.0, "weight": 1.0, "order": 0, "open": true, "folded": false, "scale": 1.0}
	var reopened := Band.new()
	reopened.persistence_key = "messages"
	reopened.default_side = "bottom"
	reopened.default_row = "outer"
	reopened.set_meta(&"preferred_size", Vector2i(420, 180))
	root.add_child(reopened)
	reopened.present()
	await process_frame
	await process_frame
	check(reopened._desktop.row == 1 and status._desktop.row == 0 and status._desktop.position.y + status._desktop.size.y <= reopened._desktop.position.y, "An old inner-row save still restores messages below the status line")
	reopened._close_panel()
	await process_frame
	await process_frame
	var dock_insets := host.workspace_view.insets
	var saved_layout := FileAccess.get_file_as_string(space.state_path)
	var status_rect := Rect2(status._desktop.position, status._desktop.size)
	space.set_panels_hidden(true)
	await process_frame
	check(not status._desktop.is_visible_in_tree() and not space.visible, "Side panels and status bar hide together")
	check(host.workspace_view.insets == Vector4.ZERO, "Hidden panels release all workspace space")
	check(FileAccess.get_file_as_string(space.state_path) == saved_layout, "Hiding does not overwrite the saved layout")
	space.set_workspace_active(false)
	space.set_workspace_active(true)
	for panel in [a, b, status]: panel.set_workspace_active(true)
	check(not status._desktop.is_visible_in_tree() and host.workspace_view.insets == Vector4.ZERO, "Returning from the server chooser does not reveal hidden panels")
	space.set_panels_hidden(false)
	await process_frame
	check(status._desktop.is_visible_in_tree(), "Status bar returns after showing panels")
	check(host.workspace_view.insets.is_equal_approx(dock_insets), "Showing panels restores workspace insets")
	check(Rect2(status._desktop.position, status._desktop.size).is_equal_approx(status_rect), "Status bar placement survives hiding")
	status.queue_free()
	await process_frame
	space.show_preview(space.plan(first, Vector2(1278, 200)))
	a.queue_free(); b.queue_free()
	await process_frame
	await process_frame
	check(space.panels.is_empty() and host.workspace_view.insets == Vector4.ZERO, "Closing releases all docks and insets")
	root.remove_meta(&"list_dock_space")
	DirAccess.remove_absolute(space.state_path)
	space.queue_free(); host.queue_free()
	root.gui_embed_subwindows = true
	var mobile := Base.new()
	root.add_child(mobile)
	mobile.present()
	check(mobile.visible and not is_instance_valid(mobile._desktop), "Mobile keeps its embedded non-modal dialog")
	mobile.queue_free()
	await process_frame
	print("LIST_DOCKING_PASS" if failures.is_empty() else "LIST_DOCKING_FAIL")
	quit(0 if failures.is_empty() else 1)
