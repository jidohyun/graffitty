extends SceneTree
const MobileMenu := preload("res://scenes/input/MobileMenu.gd")
var failures: Array[String] = []
var errors := preload("res://tests/run.gd").ErrorCapture.new()
var output := ""

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-mobile-menu-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	OS.add_logger(errors)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	run.call_deferred()

func expect(value: bool, message: String) -> void:
	if not value: failures.append(message)
	print(("PASS " if value else "FAIL ") + message)

func snapshot(label: String) -> void:
	if output.is_empty() or DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(output)
	root.get_texture().get_image().save_png(output.path_join(label + ".png"))

func down(button: Button) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = true
	event.position = button.size / 2
	button.gui_input.emit(event)

func up(menu: Control) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = false
	menu.mover._input(event)

func click_mouse(button: Control) -> void:
	var point := button.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		root.push_input(event)
		await process_frame
	await create_timer(.25).timeout

func click_touch(button: Control) -> void:
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.index = 0
		event.pressed = pressed
		event.position = button.get_global_rect().get_center()
		Input.parse_input_event(event)
		await process_frame
	await create_timer(.25).timeout

func run() -> void:
	Input.emulate_mouse_from_touch = true
	root.min_size = Vector2i.ZERO
	root.size = Vector2i(390, 360)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.gui_embed_subwindows = true
	var menu := MobileMenu.new()
	root.add_child(menu)
	for label in ["Shell", "Edit", "View", "Sessions", "Help"]:
		var button := MenuButton.new()
		menu.add_menu(button, label)
		button.get_popup().add_item("Example action")
		preload("res://scenes/PopupChrome.gd").apply(button.get_popup())
	await create_timer(.1).timeout
	expect(menu.size == Vector2(60, 44) and menu.expand_button.visible and not menu.row.visible, "Collapsed pill only shows ellipsis")
	expect(menu.expand_button.icon_alignment == HORIZONTAL_ALIGNMENT_CENTER, "Ellipsis is centered inside its button, not left-aligned")
	expect(menu.expand_button.get_global_rect().get_center().distance_to(menu.get_global_rect().get_center()) < .5, "Ellipsis button is centered inside the collapsed pill")
	var closed_alpha := menu.surface.bg_color.a
	await snapshot("collapsed")
	down(menu.expand_button)
	expect(not menu.expanded, "Press waits for release before expanding")
	up(menu)
	await create_timer(.06).timeout
	expect(menu.progress > 0 and menu.progress < 1 and menu.size.x > 60, "Expansion has visible intermediate frames")
	await create_timer(.3).timeout
	expect(menu.expanded and is_equal_approx(menu.progress, 1) and not menu.expand_button.visible, "Expansion animation finishes")
	expect(is_equal_approx(closed_alpha, .10) and is_equal_approx(menu.surface.bg_color.a, .30), "Expanded surface is more opaque but still translucent")
	for button in menu.buttons.get_children():
		expect(button.icon != null and button.text.is_empty() and not button.tooltip_text.is_empty(), "Menu has an SVG and accessible label: " + button.name)
	expect(menu.get_global_rect().encloses(menu.collapse_button.get_global_rect()), "Collapse chevron is inside the expanded pill")
	await snapshot("expanded")
	var first: MenuButton = menu.buttons.get_child(0)
	var second: MenuButton = menu.buttons.get_child(1)
	for icon: MenuButton in menu.buttons.get_children():
		down(icon)
		expect(not icon.get_popup().visible, "Icon waits for release: " + icon.name)
		await create_timer(.4).timeout
		expect(menu.mover._gesture.get("dragging", false), "Icon hold starts toolbar drag: " + icon.name)
		menu.mover._move(Vector2(25, 70) + menu.mover._gesture.grab)
		up(menu)
		await create_timer(.4).timeout
		expect(not icon.get_popup().visible and menu.expanded, "Icon drag never opens a menu: " + icon.name)
	await click_mouse(first)
	expect(first.get_popup().visible, "Clicking an icon opens its menu")
	await click_mouse(first)
	expect(not first.get_popup().visible, "Clicking the same icon closes instead of reopening")
	await click_mouse(first)
	await click_mouse(second)
	expect(second.get_popup().visible and not first.get_popup().visible, "Clicking another icon switches menus")
	second.get_popup().hide()
	await process_frame
	await click_touch(first)
	expect(first.get_popup().visible, "Touch opens a menu")
	await click_touch(first)
	expect(not first.get_popup().visible, "Touching the opener again closes the menu")
	root.size = Vector2i(280, 360)
	await create_timer(.1).timeout
	expect(menu.size.x <= root.get_visible_rect().size.x - 24 and menu.position.x >= 0, "Toolbar fits a narrow folded viewport")
	expect(menu.get_global_rect().encloses(menu.collapse_button.get_global_rect()), "Chevron stays reachable while icons scroll")
	await check_horizontal_scroll(menu, first)
	await snapshot("narrow")
	var popup: PopupMenu = menu.buttons.get_child(0).get_popup()
	popup.position = Vector2i(20, 90)
	popup.popup()
	await process_frame
	await create_timer(.04).timeout
	var popup_position := popup.position
	var panel := popup.get_theme_stylebox("panel") as StyleBoxFlat
	expect(panel.corner_radius_top_left == 10 and panel.border_width_left == 1, "Popup uses rounded bordered mobile chrome")
	expect(panel.bg_color.a > 0 and panel.bg_color.a < .96, "Popup opening fades through intermediate frames")
	await create_timer(.25).timeout
	expect(is_equal_approx(panel.bg_color.a, .96) and popup.position == popup_position, "Popup animation settles at its original position (%s -> %s)" % [popup_position, popup.position])
	await snapshot("popup")
	popup.hide()
	await create_timer(.1).timeout
	popup.popup()
	expect(is_zero_approx(panel.bg_color.a), "Reopening restarts the fade")
	await create_timer(.3).timeout
	expect(is_equal_approx(panel.bg_color.a, .96), "Reopening settles at the same opacity (%s, visible=%s)" % [panel.bg_color.a, popup.visible])
	down(menu.collapse_button)
	expect(menu.expanded, "Chevron does not fold on press")
	up(menu)
	await create_timer(.3).timeout
	expect(not popup.visible and not menu.row.visible and menu.expand_button.visible, "Collapse closes popups and restores ellipsis")
	menu.set_expanded(true)
	await create_timer(.05).timeout
	menu.set_expanded(false)
	await create_timer(.3).timeout
	expect(is_zero_approx(menu.progress) and is_equal_approx(menu.size.x, 60), "Reversing animation settles without a stale tween")
	# Holding either handle moves the same surface without invoking its tap.
	for open in [false, true]:
		menu.set_expanded(open, false)
		down(menu.collapse_button if open else menu.expand_button)
		await create_timer(.4).timeout
		expect(menu.mover._gesture.get("dragging", false), "Hold unlocks drag, expanded=%s" % open)
		menu.mover._move(Vector2(50, 180) + menu.mover._gesture.grab)
		up(menu)
		await create_timer(.4).timeout
		expect(menu.expanded == open and menu.position.y > 100, "Drag persists position without toggling, expanded=%s" % open)
	for corner in [Vector2(8, 8), Vector2(212, 8), Vector2(8, 308), Vector2(212, 308)]:
		menu.set_expanded(false, false)
		menu.mover._save_position("menu", corner)
		menu.reflow()
		menu.set_expanded(true)
		var inside := true
		for frame in 14:
			await create_timer(.025).timeout
			inside = inside and menu.mover.area().encloses(menu.get_rect())
		expect(inside, "Every expansion frame stays in bounds at %s" % corner)
	var peers := preload("res://scenes/input/FloatingButtons.gd").new()
	root.add_child(peers)
	# The keyboard-layout owner publishes IME + accessory strip together.
	call_group(&"floating_controls", &"set_bottom_inset", 148.0)
	for open in [false, true]:
		menu.set_expanded(open, false)
		await process_frame
		expect(menu.mover.bottom_inset == peers.bottom_inset and menu.mover.bottom_inset == 148.0, "Menu and peer controls share keyboard plus key-strip inset")
		expect(menu.get_rect().end.y <= root.get_visible_rect().size.y - 148.0, "Menu stays above the key strip, expanded=%s" % open)
	call_group(&"floating_controls", &"set_bottom_inset", 0.0)
	peers.queue_free()
	menu.queue_free()
	await process_frame
	failures.append_array(errors.take())
	OS.remove_logger(errors)
	print("MOBILE_MENU_SMOKE_PASS" if failures.is_empty() else "MOBILE_MENU_SMOKE_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)

func check_horizontal_scroll(menu: Control, icon: MenuButton) -> void:
	var scroll = menu.buttons.get_parent()
	var point := icon.get_global_rect().get_center()
	scroll.elastic.fixed_time = 1.0
	for phase in ["began", "changed", "ended"]:
		var pan := InputEventPanGesture.new()
		pan.position = point
		pan.delta = Vector2.ZERO if phase == "ended" else Vector2(-60, 0)
		pan.set_meta("scroll_phase", phase)
		pan.set_meta("touch_travel", Vector2.RIGHT)
		root.push_input(pan, true)
	expect(scroll.stretch < 0, "A sideways trackpad pan over an icon pulls the menu past its left edge")
	scroll.elastic.fixed_time = 4.0
	scroll._advance()
	expect(scroll.stretch == 0, "The mobile menu springs back after a pan")
	var finger := InputEventScreenTouch.new()
	finger.position = point
	finger.pressed = true
	root.push_input(finger, true)
	for step in range(1, 6):
		var drag := InputEventScreenDrag.new()
		drag.position = point + Vector2(15 * step, 0)
		drag.relative = Vector2(15, 0)
		root.push_input(drag, true)
	expect(scroll.stretch < 0, "A sideways finger drag over an icon pulls the menu")
	finger.pressed = false
	finger.position += Vector2(75, 0)
	root.push_input(finger, true)
	scroll.elastic.fixed_time = 7.0
	scroll._advance()
	expect(scroll.stretch == 0 and not icon.get_popup().visible, "Lifting the finger settles the strip without opening the menu")
	scroll.elastic.fixed_time = -1.0
