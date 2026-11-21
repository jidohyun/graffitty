extends "../../../../tests/llm-e2e/replay/replay.gd"
## Real eza output through the session owner and projected workspace/pane input.
var opened: Array[String] = []
var painted := 0

func visible_link_labels(node: Node, uri: String) -> Array[Label]:
	var labels: Array[Label] = []
	if node is Label and node.text == uri and node.is_visible_in_tree():
		labels.append(node)
	for child in node.get_children(true):
		labels.append_array(visible_link_labels(child, uri))
	return labels

func _motion(at: Vector2, relative: Vector2) -> void:
	# Hover is rechecked between events when layout changes. Keep Input's
	# pointer in step with the replay's window-local pointer for those checks.
	var motion := InputEventMouseMotion.new()
	motion.device = REPLAY_POINTER_DEVICE
	motion.position = _to_window(at)
	motion.global_position = motion.position
	motion.relative = relative
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	super._motion(at, relative)

func link_cell(term: Control) -> Vector2i:
	var grid: Vector2i = term.get_grid_size()
	for row in grid.y:
		for col in grid.x:
			var uri: String = term.get_hyperlink_at(Vector2i(col, row))
			if uri.begins_with("file:") and "graffitty-hyperlink-e2e-" in uri:
				return Vector2i(col, row)
	return Vector2i(-1, -1)

func link_point(term: Control, cell: Vector2i) -> Vector2:
	var view: Control = host.workspace_view
	var at: Vector2 = view.terminal_origin(host.pane_focus) + term.position \
		+ Vector2.ONE * float(term.cell_padding) + term.get_cell_size() * (Vector2(cell) + Vector2(.5, .5))
	return view.window_point(at)

func play() -> void:
	await camera_at_rest()
	var term: Control = host.active_terminal()
	var view: Control = host.workspace_view
	var path := "/tmp/graffitty-hyperlink-e2e-%d.txt" % OS.get_process_id()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("hyperlink click fixture\n")
	file.close()
	# Opt in to the OS opener when checking focus loss/return in a desktop run.
	var open_files := OS.get_environment("HYPERLINK_SMOKE_OPEN") == "1"
	term.open_hyperlinks = open_files
	term.hyperlink_activated.connect(func(uri: String): opened.append(uri))
	term.frame_changed.connect(func(): painted += 1)
	term.send_text("printf '\\033[2J\\033[H'; eza --icons=always --hyperlink=always --color=always -d '%s'\n" % path)
	await hold(.8)
	var cell := link_cell(term)
	check(cell.x >= 0, "Real eza output contains its OSC 8 file target")
	if cell.x < 0:
		DirAccess.remove_absolute(path)
		return
	var uri: String = term.get_hyperlink_at(cell)
	var before := painted
	await point_at(link_point(term, cell))
	await hold(.15)
	check(term.tooltip_text == uri, "Workspace hover reaches the native link")
	check(painted > before, "Workspace hover repaints the underline without new PTY output")
	check(view.pointer.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "Projected workspace pointer shows the hand cursor")
	check(term.get_tooltip().is_empty() and view.panes[host.pane_focus].texture.get_tooltip().is_empty(), "Projected terminal and pane do not create duplicate tooltips")
	check(view.pointer.get_tooltip() == uri, "Window pointer owns the link tooltip")
	check(view.panes[host.pane_focus].handle.tooltip_text.is_empty(), "Pane title has no drag instruction tooltip")
	await hold(1.0)
	var tips := visible_link_labels(root, uri)
	check(tips.size() == 1, "Holding over a link creates exactly one visible tooltip")
	if tips.size() == 1:
		check(tips[0].get_theme_font_size("font_size") == 14 and tips[0].size.x <= 560, "Tooltip keeps a readable window-scale font and bounded width")
	var screenshot := OS.get_environment("HYPERLINK_SMOKE_SCREENSHOT")
	if not screenshot.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(screenshot)
	for attempt in 4:
		await click(link_point(term, cell))
		if open_files:
			await hold(.8)
			root.grab_focus()
		await hold(.15)
		check(opened.size() == attempt + 1, "Click %d opens the same eza link without rerunning the command" % (attempt + 1))
		check(term.get_hyperlink_at(cell) == uri, "Click %d preserves OSC 8 metadata" % (attempt + 1))
		var previous_grid: Vector2i = term.get_grid_size()
		var width_change := -120 if attempt % 2 == 0 else 120
		root.size.x += width_change
		if root.content_scale_size != Vector2i.ZERO:
			root.content_scale_size.x += width_change
		await hold(.4)
		check(term.get_grid_size() != previous_grid, "Window resize changes the PTY grid")
		check(term.get_hyperlink_at(cell) == uri, "Viewport resync retains the eza link before the next click")
		await point_at(link_point(term, cell))
		await hold(.1)
		check(term.tooltip_text == uri and view.pointer.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "Hover survives the terminal state rebuild")
	await point_at(Vector2(400, 10))
	await hold(.1)
	check(term.tooltip_text.is_empty(), "Leaving the workspace clears the terminal hover")
	DirAccess.remove_absolute(path)
