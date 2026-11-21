extends SceneTree
## Exercise native mouse dispatch on the same VT stream used by local/remote sessions.
var failures := 0
var opened: Array[String] = []
var menus: Array[String] = []
var menu_flags: Array = []
var frames := 0
var terminal: Control
var viewport: SubViewport
const URI := "file:///tmp/graffitty-hyperlink-test.txt"

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-hyperlink-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")

func settle() -> void:
	await create_timer(0.06).timeout

func point(col: float, row := 0.0) -> Vector2:
	return Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * Vector2(col + 0.5, row + 0.5)

func motion(at: Vector2, held := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	viewport.push_input(event, true)

func button(at: Vector2, pressed: bool, modifiers := 0, index := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = index
	event.pressed = pressed
	event.ctrl_pressed = bool(modifiers & KEY_MASK_CTRL)
	event.meta_pressed = bool(modifiers & KEY_MASK_META)
	event.shift_pressed = bool(modifiers & KEY_MASK_SHIFT)
	viewport.push_input(event, true)

func click(at: Vector2, modifiers := 0, index := MOUSE_BUTTON_LEFT) -> void:
	button(at, true, modifiers, index)
	button(at, false, modifiers, index)
	await settle()

func feed(text: String, reset := false) -> void:
	terminal.remote_feed_stream(text.to_utf8_buffer(), 40, 8, reset, false)
	await settle()

func run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(640, 240)
	viewport.handle_input_locally = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 240)
	var config := preload("res://graffitty/terminal_config.gd").new()
	config.apply_to(terminal)
	terminal.open_hyperlinks = false # Observe activation without opening an external app.
	terminal.hyperlink_activated.connect(func(uri: String): opened.append(uri))
	terminal.hyperlink_context_menu_requested.connect(func(uri: String, openable: bool, web: bool):
		menus.append(uri)
		menu_flags.append([openable, web]))
	terminal.frame_changed.connect(func(): frames += 1)
	viewport.add_child(terminal)
	viewport.notify_mouse_entered()
	await settle()
	await feed("\u001b[?25l\u001b]8;;" + URI + "\u001b\\\u001b[38;2;30;220;110mhello 한\u001b[0m\u001b]8;;\u001b\\ plain", true)
	check(terminal.get_hyperlink_at(Vector2i(0, 0)) == URI, "OSC 8 target survives the session stream")
	var before := frames
	motion(point(1))
	await settle()
	check(terminal.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "Hover uses a pointing hand")
	check(terminal.tooltip_text == URI and frames > before, "Hover exposes the URI and redraws its underline")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png("/tmp/graffitty-hyperlink-hover.png")
	await click(point(1))
	check(opened == [URI], "Plain click activates the OSC 8 hyperlink")
	await click(point(1), 0, MOUSE_BUTTON_RIGHT)
	check(menus == [URI] and menu_flags == [[true, false]] and opened.size() == 1, "File links show an openable, non-web link menu without opening")
	terminal.web_only_hyperlinks = true
	await click(point(1), 0, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 2 and menu_flags.back() == [false, false], "Remote clients still show file links but cannot open them locally")
	terminal.web_only_hyperlinks = false
	menus.clear()
	menu_flags.clear()
	await click(point(1), KEY_MASK_META)
	await click(point(1), KEY_MASK_CTRL)
	check(opened.size() == 3, "Cmd-click and Ctrl-click still activate links")
	await click(point(1), KEY_MASK_SHIFT)
	check(opened.size() == 3, "Shift-click keeps selection instead of opening")
	button(point(1), true)
	motion(point(4), true)
	motion(point(1), true)
	button(point(1), false)
	await settle()
	check(opened.size() == 3, "Dragging out and back never opens a link")
	await feed("\u001b[?1000h\u001b[?1006h")
	terminal.remote_take_input()
	await click(point(1))
	check(opened.size() == 3 and not terminal.remote_take_input().is_empty(), "Mouse-reporting applications retain plain clicks")
	await feed("\u001b[?1000l\u001b[?1006l")
	motion(point(1))
	await settle()
	before = frames
	motion(point(12))
	await settle()
	check(terminal.tooltip_text.is_empty() and frames > before, "Leaving a link clears its hover decoration")
	motion(point(1))
	await feed("\u001b[H\u001b[2Kreplacement")
	check(terminal.tooltip_text.is_empty(), "Output clears a stale link under a stationary pointer")
	await click(point(1))
	check(opened.size() == 3, "Overwritten link cells no longer activate")
	await feed("\u001b[Hhttps://example.test")
	await click(point(3))
	check(opened.back() == "https://example.test", "Detected plain URLs use the same click handling")
	var opened_before := opened.size()
	await click(point(3), 0, MOUSE_BUTTON_RIGHT)
	check(menus == ["https://example.test"] and menu_flags == [[true, true]] and opened.size() == opened_before, "Right-click requests a web link menu without opening the URL")
	await click(point(30), 0, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 1, "Non-link cells do not show a link menu")
	await feed("\u001b[H\u001b[2K\u001b]8;;HTTP://example.test/CaseSensitive\u001b\\web label\u001b]8;;\u001b\\")
	await click(point(3), 0, MOUSE_BUTTON_RIGHT)
	check(menus.back() == "HTTP://example.test/CaseSensitive", "OSC 8 web labels retain their exact target for the menu")
	await feed("\u001b[?1000h\u001b[?1006h")
	terminal.remote_take_input()
	await click(point(3), 0, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 3 and terminal.remote_take_input().is_empty(), "A right-click on a link opens its menu even under mouse reporting, and the app sees neither press nor release")
	await click(point(30), 0, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 3 and not terminal.remote_take_input().is_empty(), "Mouse-reporting applications still receive right-clicks off links")
	await click(point(3), KEY_MASK_SHIFT, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 4 and terminal.remote_take_input().is_empty(), "Shift-right-click on a link still shows the link menu")
	await feed("\u001b[?1000l\u001b[?1006l")
	config.mouse_bindings.append(config.MouseBinding.new(MOUSE_BUTTON_RIGHT, "select"))
	config.apply_to(terminal)
	terminal.open_hyperlinks = false
	await click(point(3), 0, MOUSE_BUTTON_RIGHT)
	check(menus.size() == 4, "Explicit right-button bindings take precedence over the link menu")
	viewport.free()
	await process_frame
	print("TERMINAL_HYPERLINK_PASS" if failures == 0 else "TERMINAL_HYPERLINK_FAIL")
	quit(failures)
