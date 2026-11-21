extends "res://tests/terminal_space_smoke.gd"
var host: Node
var connection: Node

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	super._initialize()

func settled() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while host.session_backend.work_pending() and Time.get_ticks_msec() < deadline: await process_frame
	await create_timer(.2).timeout

func add_tab() -> int:
	var reply: Dictionary = await connection.request_action("create", {"kind": "tab"})
	var id := int(reply.get("created", -1))
	var deadline := Time.get_ticks_msec() + 10000
	while host.workspace_layout.tab(id).is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	check(id > 0 and not host.workspace_layout.tab(id).is_empty(), "New tab reaches the presentation")
	await settled()
	return id

func command_w() -> void:
	host.active_terminal().grab_focus()
	await key(KEY_W, true)

func key(code: Key, meta := false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.meta_pressed = meta
		event.pressed = down
		root.push_input(event)
		await process_frame

func click(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	root.push_input(motion, true)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = at
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame

func check_tab_menu(first: int, second: int) -> void:
	host.select_workspace(second, true)
	await settled()
	var strip: Control = host.workspace_view.tab_bar
	var menu: Control = strip.navigation.menu
	var windows := DisplayServer.get_window_list()
	var focus_losses := [0]
	var on_focus_lost := func(): focus_losses[0] += 1
	root.focus_exited.connect(on_focus_lost)
	# Test native popup ownership before enabling replay pointer hit-testing below.
	strip.navigation.all_tabs.pressed.emit()
	await process_frame
	await process_frame
	check(menu.visible and menu.search.has_focus(), "All-tabs menu opens with its search field focused")
	check(menu.get_window() == root and DisplayServer.get_window_list() == windows,
		"Dropdown stays in the owning native window, preserving its traffic lights")
	check(focus_losses[0] == 0, "Opening the dropdown does not deactivate its window")
	check(root.get_visible_rect().encloses(menu.get_global_rect()), "Dropdown fits inside the viewport at native display scale")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_TEST_EVIDENCE").path_join("tab-menu.png"))
	await key(KEY_UP)
	await key(KEY_ENTER)
	await settled()
	check(not menu.visible and host.workspace_layout.active == first, "Arrow and Enter select a tab and dismiss the dropdown")
	# Godot ignores injected pointer events when the real cursor is outside a
	# native window. As in the replay harness, embedded mode allows testing hit
	# areas without moving the user's real cursor.
	#
	# The dropdown has already been checked in native mode.
	root.gui_embed_subwindows = true
	await click(strip.navigation.all_tabs.get_global_rect().get_center())
	await key(KEY_ESCAPE)
	check(not menu.visible and not strip.navigation.all_tabs.button_pressed and not menu.search.has_focus(),
		"Escape dismisses the dropdown, resets its button and releases keyboard focus")
	await click(strip.navigation.all_tabs.get_global_rect().get_center())
	await click(root.get_visible_rect().size - Vector2(10, 10))
	check(not menu.visible and host.workspace_layout.active == first, "Clicking outside dismisses the dropdown without selecting a tab")
	await click(strip.navigation.all_tabs.get_global_rect().get_center())
	await key(KEY_W, true)
	check(menu.visible and host.workspace_layout.tabs.size() == 3, "Menu input does not trigger terminal close shortcuts")
	var item: Rect2 = menu.list.get_item_rect(1)
	await click(menu.list.get_global_transform_with_canvas() * item.get_center())
	await settled()
	check(not menu.visible and host.workspace_layout.active == second, "Clicking a dropdown row selects its stable tab ID")
	await click(strip.tabs.buttons[second].get_global_rect().get_center())
	check(host.prefix_commands.active, "Clicking the selected tab arms prefix")
	await click(strip.tabs.buttons[second].get_global_rect().get_center())
	check(not host.prefix_commands.active, "Clicking the selected tab again cancels prefix")
	await click(strip.tabs.buttons[first].get_global_rect().get_center())
	await settled()
	check(host.workspace_layout.active == first and not host.prefix_commands.active,
		"Clicking a different tab selects it without arming prefix")
	root.gui_embed_subwindows = false
	root.focus_exited.disconnect(on_focus_lost)

func close_and_expect(id: int, expected: int) -> void:
	host.select_workspace(id, true)
	await settled()
	await command_w()
	var deadline := Time.get_ticks_msec() + 10000
	while not host.workspace_layout.tab(id).is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	check(host.workspace_layout.tab(id).is_empty(), "Cmd+W closes the selected tab's last pane")
	await settled()
	await connection.request_action("sync")
	await settled()
	check(host.workspace_layout.active == expected, "Closing %d selects adjacent tab %d" % [id, expected])
	check(int(connection.topology.workspace_state.active) == expected, "Owner and presentation agree after synchronization")
	check(host.active_session_id == expected, "Keyboard input follows the selected tab")

func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null: check(false, "Startup host"); quit(1); return
	host = wrapper.host
	connection = wrapper.connection
	await settled()
	var first: int = host.workspace_layout.active
	var second := await add_tab()
	var third := await add_tab()
	await check_tab_menu(first, second)
	await close_and_expect(third, second)
	var fourth := await add_tab()
	# Visual order now differs from creation/ID order: [fourth, first, second].
	host.workspace_layout.reorder(fourth, 0)
	host.session_backend.commit_workspace(host)
	await settled()
	await close_and_expect(second, first)
	await close_and_expect(fourth, first)
	check(error_watch.errors.is_empty(), "No engine or script errors: " + str(error_watch.errors))
	if not failures.is_empty(): quit(1); return
	root.tree_exiting.connect(func(): print("TAB_CLOSE_SELECTION_PASS"), CONNECT_ONE_SHOT)
	await command_w()
	await create_timer(5).timeout
	check(false, "Closing the final pane quits normally")
	quit(1)
