extends "../../../../tests/llm-e2e/replay/replay.gd"
## Real terminal output, projected right-clicks, and Chromium creation.
## Run with a desktop renderer; the headless driver reports a minimized window.
const LinkMenu := preload("res://scenes/HyperlinkContextMenu.gd")
var opened: Array[String] = []


func prepare_menu(node: Node) -> void:
	if node.get_script() != LinkMenu: return
	# Native macOS popup tracking blocks scripted input. Exercise the same
	# actions in an embedded popup while keeping the real renderer and owner.
	node.ready.connect(func():
		node.prefer_native_menu = false
		node.force_native = false, CONNECT_ONE_SHOT)


func _motion(at: Vector2, relative: Vector2) -> void:
	# Hover is rechecked between events when layout changes. Keep Input's
	# pointer in step with the replay's window-local pointer for those checks.
	var motion := InputEventMouseMotion.new()
	motion.device = REPLAY_POINTER_DEVICE
	motion.position = _to_window(at)
	motion.global_position = motion.position
	motion.relative = relative
	motion.button_mask = _held
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	super._motion(at, relative)

func link_cell(term: Control, target: String) -> Vector2i:
	var grid: Vector2i = term.get_grid_size()
	for row in grid.y:
		for col in grid.x:
			var uri: String = term.get_hyperlink_at(Vector2i(col, row))
			if uri == target:
				return Vector2i(col, row)
	return Vector2i(-1, -1)

func link_point(term: Control, cell: Vector2i) -> Vector2:
	var view: Control = host.workspace_view
	var at: Vector2 = view.terminal_origin(host.pane_focus) + term.position \
		+ Vector2.ONE * float(term.cell_padding) + term.get_cell_size() * (Vector2(cell) + Vector2(.5, .5))
	return view.window_point(at)

## File links, explicit (OSC 8, as `ls --hyperlink` writes them) and detected
## by a hyperlink pattern, open the same menu with Copy available.
func file_links(term: Control, requests: Array[String]) -> void:
	var file_uri := "file://%s/graffitty-link-menu.txt" % OS.get_environment("HOME")
	term.send_text("printf '\\033[2J\\033[H\\033]8;;%s\\033\\\\file link\\033]8;;\\033\\\\\\n'\n" % file_uri)
	await hold(.5)
	var cell := link_cell(term, file_uri)
	check(cell.x >= 0, "OSC 8 file link arrives through the real session stream")
	if cell.x < 0: return
	for attempt in [file_uri]:
		var before := requests.size()
		await point_at(link_point(term, cell))
		await press(MOUSE_BUTTON_RIGHT)
		await release(MOUSE_BUTTON_RIGHT)
		await hold(.1)
		var menu: PopupMenu = host.workspace_view.panes[host.pane_focus].hyperlink_context_menu
		check(requests.size() == before + 1 and requests.back() == attempt, "Right-click on an OSC 8 file link requests the link menu: %s" % [requests])
		check(is_instance_valid(menu) and menu.visible and menu.target == attempt, "The file link menu opens with its URI")
		if is_instance_valid(menu) and menu.visible:
			check(not menu.is_item_disabled(menu.get_item_index(menu.Action.COPY)), "Copy Link Address is available for a file link")
			menu.id_pressed.emit(menu.Action.COPY)
			check(DisplayServer.clipboard_get() == attempt, "Copy Link Address copies the file URI")
	# Full-screen apps (agent TUIs, editors) turn on mouse reporting. A right-click
	# on a link still opens the link menu; elsewhere it reaches the app as before.
	var menu_now: PopupMenu = host.workspace_view.panes[host.pane_focus].hyperlink_context_menu
	if is_instance_valid(menu_now): menu_now.hide()
	term.send_text("printf '\\033[?1000h\\033[?1006h\\033[2J\\033[H\\033]8;;%s\\033\\\\file link\\033]8;;\\033\\\\\\n'; sleep 3; printf '\\033[?1006l\\033[?1000l'\n" % file_uri)
	await hold(.5)
	var tracked := link_cell(term, file_uri)
	check(tracked.x >= 0, "File link is shown while the app reports the mouse")
	if tracked.x >= 0:
		var before := requests.size()
		await point_at(link_point(term, tracked))
		await press(MOUSE_BUTTON_RIGHT)
		await release(MOUSE_BUTTON_RIGHT)
		await hold(.1)
		check(requests.size() == before + 1 and requests.back() == file_uri, "Right-click on a link opens its menu even with app mouse reporting on: %s" % [requests])
	await hold(3.0)
	var menu: PopupMenu = host.workspace_view.panes[host.pane_focus].hyperlink_context_menu
	if is_instance_valid(menu): menu.hide()
	requests.clear()


func play() -> void:
	await camera_at_rest()
	host.child_entered_tree.connect(prepare_menu)
	var term: Control = host.active_terminal()
	var requests: Array[String] = []
	term.hyperlink_context_menu_requested.connect(func(url: String, _openable: bool, _web: bool): requests.append(url))
	term.hyperlink_activated.connect(func(url: String): opened.append(url))
	var uri := "http://127.0.0.1:9/graffitty-link-menu"
	var view: Control = host.workspace_view
	var source: String = host.pane_focus
	var chromium_count: int = host.chromiums.size()
	term.open_hyperlinks = false
	term.send_text("printf '\\033[2J\\033[H\\033]8;;%s\\033\\\\web link\\033]8;;\\033\\\\\\n'\n" % uri)
	await hold(.5)
	var cell := link_cell(term, uri)
	check(cell.x >= 0, "Web link arrives through the real session stream")
	if cell.x < 0: return
	var before := opened.size()
	await click(link_point(term, cell))
	await hold(.1)
	check(opened.size() == before + 1 and opened.back() == uri and host.chromiums.size() == chromium_count, "Ordinary web click follows client activation without creating Chromium")
	await point_at(link_point(term, cell))
	await press(MOUSE_BUTTON_RIGHT)
	await release(MOUSE_BUTTON_RIGHT)
	await hold(.1)
	var menu: PopupMenu = view.panes[source].hyperlink_context_menu
	check(is_instance_valid(menu) and menu.visible, "Projected right-click opens the link menu in the host window")
	if not is_instance_valid(menu): return
	check(menu.get_parent() == host and menu.target == uri, "Menu belongs to the client window and retains the clicked URL")
	check(menu.open_in_browser_requested.is_connected(OS.shell_open), "Browser menu action is connected to the client OS opener")
	# Observe routing without launching the developer's browser during the test.
	menu.open_in_browser_requested.disconnect(OS.shell_open)
	var browser: Array[String] = []
	menu.open_in_browser_requested.connect(func(url: String): browser.append(url))
	menu.id_pressed.emit(menu.Action.BROWSER)
	check(browser == [uri] and host.chromiums.size() == chromium_count, "Browser action stays entirely on the client")
	await point_at(link_point(term, cell))
	await pan_pixels(Vector2(16, 0))
	await hold(.1)
	check(not menu.visible, "Right-drag over a link pans without opening a menu")
	await camera_at_rest()
	await point_at(link_point(term, cell))
	check(term.tooltip_text == uri, "Pointer returns to the web link after workspace panning")
	await press(MOUSE_BUTTON_RIGHT)
	await release(MOUSE_BUTTON_RIGHT)
	await hold(.1)
	check(menu.visible and requests == [uri, uri], "A later right-click can reopen the same link menu")
	if not menu.visible: return
	menu.id_pressed.emit(menu.Action.CHROMIUM)
	var deadline := Time.get_ticks_msec() + 15000
	while host.chromiums.size() == chromium_count and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.chromiums.size() == chromium_count + 1, "Show in Graffitty Chromium creates a real embedded browser")
	for chromium in host.chromiums.values():
		if chromium.owner_id == int(source.substr(1)):
			while chromium.page_tabs.is_empty() and Time.get_ticks_msec() < deadline:
				await process_frame
			check(not chromium.page_tabs.is_empty() and chromium.page_tabs[0].url == uri, "Embedded browser navigates to the clicked terminal URL")
	var link_menu: PopupMenu = view.panes[source].hyperlink_context_menu
	if is_instance_valid(link_menu): link_menu.hide()
	# Showing in Chromium focused the new browser pane; aim at the terminal again.
	for key in host.chromiums.keys(): host.close_chromium_session(key)
	await hold(.5)
	host.focus_pane(source)
	await camera_at_rest()
	await file_links(term, requests)
