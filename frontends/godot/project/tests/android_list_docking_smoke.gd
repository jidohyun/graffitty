extends SceneTree
## Touch injection through the viewport in a real window; not a device E2E pass.
const Fixture := preload("res://tests/list_docking_smoke.gd")
const Base := Fixture.Base
class View extends Node:
	var host: Node
class Manager extends Control:
	var chooser := Control.new()
	var dialog := Control.new()
	var view := View.new()
	func _ready() -> void:
		add_child(chooser)
		add_child(dialog)
		add_child(view)
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func touch_drag(from: Vector2, to: Vector2, canceled := false) -> void:
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
	var space: Control = root.get_meta(&"list_dock_space")
	check(space.pointer().distance_to(to) < 1.0, "Dock tracker uses logical finger coordinates, including during embedded chrome capture")
	event.position = root.get_final_transform() * to
	event.pressed = false
	event.canceled = canceled
	Input.parse_input_event(event)
	await create_timer(.2).timeout
func run() -> void:
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.5 if "--scaled" in OS.get_cmdline_user_args() else 1.0
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(Vector2(390, 780) * root.content_scale_factor)
	root.gui_embed_subwindows = true
	Input.emulate_mouse_from_touch = true
	var host := Fixture.Host.new()
	root.add_child(host)
	var space := Fixture.Space.new()
	space.state_path = ""
	root.add_child(space)
	space.test_hosts = [host]
	root.set_meta(&"list_dock_space", space)
	var a := Base.new()
	a.title = "Agents"
	root.add_child(a)
	a.present()
	await create_timer(.3).timeout
	check(a.is_embedded() and not a.force_native and is_instance_valid(a._desktop), "Android uses an embedded resizable window with shared docking")
	a.size = Vector2i(260, 320)
	await create_timer(.1).timeout
	var expanded_size := a.size
	var title_at := Vector2(a.position) + Vector2(100, 12)
	await touch_drag(title_at, title_at)
	check(a.folded and not a._body.visible and a.size.y < expanded_size.y, "Touching the real embedded title folds the floating panel")
	await touch_drag(title_at, title_at)
	check(not a.folded and a.size == expanded_size, "Touching the folded title restores the floating panel size")
	var before := a.size
	check(a._floating_title.size.y == 24 and a._floating_title.get_child(0).get_theme_font_size("font_size") == 11, "Embedded title chrome is compact")
	var corner := Vector2(a.position + a.size) + Vector2(3, 3)
	await touch_drag(corner, corner + Vector2(30, 40))
	check(a.size.x > before.x and a.size.y > before.y, "Touching the real window corner resizes both dimensions naturally")
	check(not a._resize_grip.visible and a.unresizable and a.borderless, "Mobile hides the grip and disables stock all-edge resizing")
	check(a._frame.get_theme_stylebox("panel").border_width_left == 0, "Mobile floating chrome has no painted resize border")
	for edge in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 1)]:
		a.position = Vector2i(60, 120)
		a.size = Vector2i(240, 300)
		await create_timer(.1).timeout
		var point := Vector2(a.position) + Vector2(0 if edge.x < 0 else (240 if edge.x > 0 else 120), 300 if edge.y > 0 else 150)
		await touch_drag(point, point + Vector2(edge.x * 20, edge.y * 20))
		check(a.size == Vector2i(240 + (20 if edge.x != 0 else 0), 300 + (20 if edge.y != 0 else 0)), "Invisible side/bottom edge resizes only its intended dimensions")
		check(a._desktop.side.is_empty(), "Resizing never starts docking")
	a.position = Vector2i(60, 120)
	a.size = Vector2i(240, 300)
	await create_timer(.1).timeout
	var resize_start := Rect2i(a.position, a.size)
	var bottom_corner := Vector2(a.position + a.size)
	await touch_drag(bottom_corner, bottom_corner + Vector2(20, 20), true)
	check(Rect2i(a.position, a.size) == resize_start, "Canceled mobile resize restores its original rectangle")
	for x in [2, 120, 238]:
		a.position = Vector2i(60, 120)
		a.size = Vector2i(240, 300)
		await create_timer(.1).timeout
		var top := Vector2(a.position) + Vector2(x, 12)
		await touch_drag(top, top + Vector2(10, 20))
		check(a.size == Vector2i(240, 300), "Top/title corners never resize the mobile dialog")
	a.position = Vector2i(60, 120)
	a.size = Vector2i(240, 300)
	await create_timer(.2).timeout
	var start := a.position
	var from := Vector2(a.position) + Vector2(80, 12)
	await touch_drag(from, from + Vector2(40, 20))
	check((Vector2(a.position - start) - Vector2(40, 20)).length() <= 2, "Embedded title follows the finger one-to-one at the current UI scale")
	from = Vector2(a.position) + Vector2(80, 12)
	await touch_drag(from, Vector2(4, 220))
	check(a._desktop.side == "left" and not a.visible, "Touch-dragging the real embedded title docks on a narrow phone")
	# Continue checking layout/navigation even when the platform drops injected input.
	if a._desktop.side.is_empty(): space.commit(a._desktop, space.plan(a._desktop, Vector2(1, 220)))
	check(host.workspace_view.insets.x > 0 and host.workspace_view.insets.x <= space.bounds().size.x - 120, "Phone docking leaves usable main content")
	var b := Base.new()
	b.title = "Sessions"
	root.add_child(b)
	b.present()
	space.commit(b._desktop, space.plan(b._desktop, Vector2(1, 100)))
	await create_timer(.1).timeout
	var panel: Control = b._desktop
	check(panel._edge.size.x == space.gap() + 32 and panel._divider.size.y == space.gap() + 16 and panel._edge.color.a == 0 and panel._divider.color.a == 0, "Mobile keeps generous invisible resize hitboxes")
	check(panel._edge.get_child_count() == 0 and panel._divider.get_child_count() == 0, "Mobile resize targets have no painted lines")
	check(panel._divider.size.y == space.gap() + 16, "Mobile stack resize target spans the whole gap without stealing the next title")
	var height := panel.size.y
	from = panel._divider.get_global_rect().get_center()
	await touch_drag(from, from + Vector2(0, 60))
	check(panel.size.y > height, "Touch divider changes stack proportions")
	var width := panel.size.x
	# Start just inside the adjacent terminal, across the full tiling gap.
	from = Vector2(panel.get_global_rect().end.x + space.gap() + 4, panel.get_global_rect().get_center().y)
	await touch_drag(from, from - Vector2(45, 0))
	check(panel.size.x < width, "Touch edge resizes sidebar width")
	from = a._desktop.position + Vector2(30, 10)
	await touch_drag(from, Vector2(space.bounds().size.x - 65, 400))
	check(a.visible and a._desktop.side.is_empty() and a.title_reachable(), "Touch title undocks into a reachable floating window")
	# A phone has no room to keep every window fully on screen: a floating
	# window may hang off the side, as long as a finger's width of title stays.
	var bounds := a._available()
	var title := Vector2(a.position) + Vector2(a.size.x * .5, a.floating_title_height() * .5)
	await touch_drag(title, Vector2(bounds.end.x + a.size.x * .3, title.y))
	check(a.position.x + a.size.x > bounds.end.x + a.size.x * .5, "A floating window may be pushed mostly off the right edge")
	check(a.title_reachable() and a.position.x <= bounds.end.x - 44 * root.content_scale_factor, "At least a finger's width of its title stays on screen")
	title = Vector2(a.position) + Vector2(44 * root.content_scale_factor * .5, a.floating_title_height() * .5)
	await touch_drag(title, Vector2(title.x, bounds.end.y + 200))
	check(a.position.y + int(a.floating_title_height()) <= bounds.end.y and a.position.y + a.size.y > bounds.end.y, "Pushed down, the body may leave the screen but the title row stays inside")
	await touch_drag(Vector2(a.position) + Vector2(20, a.floating_title_height() * .5), Vector2(bounds.get_center()))
	check(bounds.encloses(Rect2i(a.position, a.size)), "Dragging back brings the whole window on screen again")
	space.commit(a._desktop, space.plan(a._desktop, Vector2(1, 500)))
	b.float_native()
	space.reflow()
	var manager := Manager.new()
	root.add_child(manager)
	manager.view.host = host
	var navigation := preload("res://scenes/remote/RemoteNavigation.gd").new()
	navigation.manager = manager
	navigation.enter(navigation.Space.WORKSPACE)
	var saved_width: float = space.widths.left
	navigation.enter(navigation.Space.MANAGER)
	check(manager.chooser.visible and not manager.dialog.visible and not host.layout_root.visible, "Manager and workspace are mutually exclusive")
	check(not a._desktop.visible and not b.visible and not space.visible and host.workspace_view.insets == Vector4.ZERO, "Manager hides both docked and floating panels and releases insets")
	navigation.enter(navigation.Space.EDITOR)
	check(manager.dialog.visible and not manager.chooser.visible and not b.visible, "Editor is a separate space without workspace overlays")
	navigation.enter(navigation.Space.WORKSPACE)
	check(not manager.chooser.visible and not manager.dialog.visible and a._desktop.visible and b.visible, "Returning restores only workspace panels")
	check(space.widths.left == saved_width, "Navigation preserves layout")
	var close_point: Vector2 = Vector2(b.position) + b._floating_close.get_global_rect().get_center()
	await touch_drag(close_point, close_point)
	check(not is_instance_valid(b), "Touching the application close button closes the floating panel")
	a.queue_free()
	if is_instance_valid(b): b.queue_free()
	await process_frame
	await process_frame
	space.queue_free(); host.queue_free(); manager.queue_free()
	await process_frame
	print("ANDROID_LIST_DOCKING_PASS" if failures.is_empty() else "ANDROID_LIST_DOCKING_FAIL")
	quit(0 if failures.is_empty() else 1)
