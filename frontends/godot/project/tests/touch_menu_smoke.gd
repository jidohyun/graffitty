extends SceneTree
const Popups := preload("res://scenes/PopupChrome.gd")
var failures: Array[String] = []
var actions: Array[int] = []
var errors := preload("res://tests/run.gd").ErrorCapture.new()

func _initialize() -> void:
	OS.add_logger(errors)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures.append(label)

func wait() -> void:
	await create_timer(.08).timeout

func touch(down: bool, at: Vector2, index := 0, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = down
	event.canceled = canceled
	event.position = root.get_final_transform() * at
	Input.parse_input_event(event)
	await wait()

func drag(at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = root.get_final_transform() * at
	Input.parse_input_event(event)
	await wait()

func press_key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		Input.parse_input_event(event)
		await wait()

func at(menu: Window, row: Control) -> Vector2:
	return Vector2(menu.position) + row.get_global_rect().get_center()

func run() -> void:
	preload("res://scenes/UIAccent.gd").install()
	Input.emulate_mouse_from_touch = true
	root.gui_embed_subwindows = true
	root.unfocusable = true
	root.size = Vector2i(600, 900)
	root.content_scale_factor = 1.5
	await create_timer(.6).timeout
	var model := PopupMenu.new()
	root.add_child(model)
	for index in 30: model.add_item("Menu action %d with a long translated label" % index, index)
	model.set_item_disabled(0, true)
	model.id_pressed.connect(func(id: int): actions.append(id))
	model.position = Vector2i(20, 60)
	Popups.open(model)
	await wait()
	var menu := Popups.presentation(model)
	check(menu != model and menu.visible and not model.visible, "Touch has one presenter, not a competing native popup")
	check(menu.size.y <= 360 and menu.size.x <= 320, "Long menu stays compact")
	check(Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(Rect2(menu.position, menu.size)), "Menu fits scaled viewport")
	var start := at(menu, menu.buttons[5])
	await touch(true, start)
	for step in range(1, 9):
		menu.set_bottom_inset(menu.bottom_inset)
		menu._fit()
		await drag(start - Vector2(0, step * 18))
	check(menu.scroll.scroll_vertical > 100, "Dragging rows scrolls at non-integer UI scale")
	check(menu.buttons.all(func(row): return not row.button_pressed), "Scrolling clears all row highlights")
	await touch(false, start - Vector2(0, 144))
	check(actions.is_empty() and menu.visible, "Scroll release never activates or dismisses")
	# A slow drag released after a rest does not glide; a flick does.
	check(not menu.scroll.gliding(), "A drag that rested before release stops where it is")
	menu.scroll.scroll_vertical = 0
	await wait()
	await touch(true, start)
	# Frame-paced samples: a flick is judged on its last tenth of a second.
	for step in range(1, 7):
		var moved := InputEventScreenDrag.new()
		moved.index = 0
		moved.position = root.get_final_transform() * (start - Vector2(0, step * 15))
		Input.parse_input_event(moved)
		await process_frame
	var lifted: int = menu.scroll.scroll_vertical
	var lift := InputEventScreenTouch.new()
	lift.index = 0
	lift.position = root.get_final_transform() * (start - Vector2(0, 90))
	Input.parse_input_event(lift)
	await process_frame
	await process_frame
	check(menu.scroll.gliding(), "A flick keeps the menu gliding after the finger lifts")
	await create_timer(.3).timeout
	check(menu.scroll.scroll_vertical > lifted, "The glide carries the list past the release point")
	# Wherever the glide went, the middle of the list is a row on screen.
	var braked := at(menu, menu.scroll)
	await touch(true, braked)
	await touch(false, braked)
	check(actions.is_empty() and menu.visible and not menu.scroll.gliding(), "A touch brakes the glide without activating a row")
	menu.scroll.scroll_vertical = 0
	await wait()
	var disabled_target := at(menu, menu.buttons[0])
	await touch(true, disabled_target)
	await touch(false, disabled_target)
	check(actions.is_empty() and menu.visible, "Disabled row never activates")
	var target := at(menu, menu.buttons[2])
	await touch(true, target)
	await touch(false, target, 0, true)
	check(actions.is_empty(), "Canceled touch never activates")
	await touch(true, target)
	await touch(true, target + Vector2(20, 0), 1)
	await touch(false, target)
	await touch(false, target + Vector2(20, 0), 1)
	check(actions.is_empty(), "Extra finger cancels the whole gesture")
	await touch(true, target)
	await touch(false, target)
	check(actions == [2] and not menu.visible, "Clean tap recovers and invokes exactly one command")
	Popups.open(model)
	await wait()
	menu.set_bottom_inset(320)
	await wait()
	check(menu.position.y + menu.size.y <= root.get_visible_rect().size.y - 320, "Keyboard-safe bounds apply to existing menu")
	Popups.close(model)
	menu.set_bottom_inset(0)
	model.clear()
	var submenu := PopupMenu.new()
	submenu.name = "Nested"
	model.add_child(submenu)
	submenu.add_check_item("Checked action", 50)
	submenu.set_item_checked(0, true)
	submenu.id_pressed.connect(func(id: int): actions.append(id))
	model.add_submenu_node_item("Nested commands", submenu)
	model.position = Vector2i(20, 40)
	Popups.open(model)
	await wait()
	await touch(true, at(menu, menu.buttons[0]))
	await touch(false, at(menu, menu.buttons[0]))
	check(menu.model == submenu and menu.visible, "Submenu uses the same scroll owner")
	if menu.model != submenu:
		quit(1)
		return
	await touch(true, at(menu, menu.buttons[0]))
	await touch(false, at(menu, menu.buttons[0]))
	check(menu.model == model, "Back returns to parent menu")
	await touch(true, at(menu, menu.buttons[0]))
	await touch(false, at(menu, menu.buttons[0]))
	await touch(true, at(menu, menu.buttons[1]))
	await touch(false, at(menu, menu.buttons[1]))
	check(actions == [2, 50] and not menu.visible, "Nested checked action retains command identity")
	Popups.open(model)
	await wait()
	await press_key(KEY_DOWN)
	await press_key(KEY_RIGHT)
	await press_key(KEY_DOWN)
	await press_key(KEY_DOWN)
	await press_key(KEY_ENTER)
	check(actions == [2, 50, 50] and not menu.visible, "Keyboard submenu navigation activates exactly once")
	Popups.open(model)
	await wait()
	check(preload("res://scenes/input/WorkspaceMenus.gd").dismiss(root) and not menu.visible, "Workspace dismissal closes touch presentation")
	Popups.open(model)
	Popups.close(model)
	await wait()
	check(not menu.visible and not menu.pending, "Dismissal cancels a deferred opening")
	model.queue_free()
	await wait()
	# A menu opened from a control whose theme pads Labels must still keep its
	# shortcut hint flush right, clear of the item text.
	var owner := Control.new()
	owner.theme = Theme.new()
	var padded := StyleBoxFlat.new()
	padded.content_margin_left = 60
	padded.content_margin_right = 60
	owner.theme.set_stylebox("normal", "Label", padded)
	root.add_child(owner)
	var themed := PopupMenu.new()
	owner.add_child(themed)
	themed.add_item("Fit to pane", 1, KEY_ENTER | KEY_MASK_CTRL | KEY_MASK_SHIFT)
	themed.position = Vector2i(20, 40)
	Popups.open(themed)
	await wait()
	var themed_menu = Popups.presentation(themed)
	var row: Control = themed_menu.buttons[0]
	var hint: Label = null
	for child in row.get_children():
		if child is Label: hint = child
	check(hint != null, "Shortcut hint is shown")
	if hint != null:
		var font := hint.get_theme_font("font")
		var text_width := font.get_string_size(hint.text, HORIZONTAL_ALIGNMENT_LEFT, -1, hint.get_theme_font_size("font_size")).x
		check(hint.size.x <= ceilf(text_width) + 1, "Inherited Label padding does not widen the shortcut hint")
		var row_end := row.get_global_rect().end.x
		var text_end := row_end - row.get_theme_stylebox("normal").content_margin_right
		check(absf(hint.get_global_rect().end.x - (row_end - 8)) <= 1, "Shortcut hint stays pinned right")
		check(hint.get_global_rect().position.x >= text_end, "Shortcut hint stays clear of the item text")
	Popups.close(themed)
	themed.queue_free()
	owner.queue_free()
	await wait()
	var toggles := PopupMenu.new()
	root.add_child(toggles)
	toggles.hide_on_checkable_item_selection = false
	toggles.add_check_item("Unchecked option", 0)
	toggles.add_check_item("Checked option", 1)
	toggles.set_item_checked(1, true)
	toggles.add_radio_check_item("Unselected radio", 2)
	toggles.add_radio_check_item("Selected radio", 3)
	toggles.set_item_checked(3, true)
	toggles.add_check_item("Disabled option", 4)
	toggles.set_item_disabled(4, true)
	toggles.add_item("Ordinary command", 5)
	var command_icon := ThemeDB.get_default_theme().get_icon("checked", "CheckBox")
	toggles.set_item_icon(0, command_icon)
	toggles.id_pressed.connect(func(id: int): toggles.set_item_checked(id, not toggles.is_item_checked(id)))
	toggles.position = Vector2i(20, 40)
	Popups.open(toggles)
	await wait()
	var toggle_menu = Popups.presentation(toggles)
	for index in 5:
		var indicator: TextureRect = toggle_menu.buttons[index].get_node_or_null("CheckIndicator")
		check(indicator != null and indicator.texture != null and indicator.is_visible_in_tree(), "Check/radio state has a visible indicator: %d" % index)
	check(not toggle_menu.buttons[5].has_node("CheckIndicator"), "Ordinary commands have no checkbox")
	var unchecked: Texture2D = toggle_menu.buttons[0].get_node("CheckIndicator").texture
	check(unchecked != toggle_menu.buttons[1].get_node("CheckIndicator").texture, "Checked and unchecked states are distinct")
	check(unchecked != toggle_menu.buttons[2].get_node("CheckIndicator").texture, "Checkbox and radio indicators are distinct")
	check(unchecked != toggle_menu.buttons[4].get_node("CheckIndicator").texture, "Disabled state has its own indicator")
	check(toggle_menu.buttons[0].icon == command_icon, "State indicator preserves the command icon")
	var before_margin: float = toggle_menu.buttons[0].get_theme_stylebox("normal").content_margin_left
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot=") and DisplayServer.get_name() != "headless":
			await create_timer(.2).timeout
			RenderingServer.force_draw()
			root.get_texture().get_image().save_png(arg.trim_prefix("--screenshot="))
	await touch(true, at(toggle_menu, toggle_menu.buttons[0]))
	await touch(false, at(toggle_menu, toggle_menu.buttons[0]))
	check(toggles.is_item_checked(0) and toggle_menu.visible, "Toggling updates a menu that stays open")
	check(toggle_menu.buttons[0].get_node("CheckIndicator").texture != unchecked, "Toggle refreshes the displayed indicator")
	check(toggle_menu.buttons[0].text == "Unchecked option" and toggle_menu.buttons[0].get_theme_stylebox("normal").content_margin_left == before_margin, "Toggling preserves label text and alignment")
	Popups.close(toggles)
	toggles.queue_free()
	await wait()
	failures.append_array(errors.take())
	OS.remove_logger(errors)
	print("TOUCH_MENU_PASS" if failures.is_empty() else "TOUCH_MENU_FAIL " + str(failures))
	quit(0 if failures.is_empty() else 1)
