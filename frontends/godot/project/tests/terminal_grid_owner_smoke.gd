extends "../../../../tests/llm-e2e/replay/replay.gd"
## Actual shared PTY geometry must follow canonical panes, not client projection.

func expected_grid(terminal) -> Vector2i:
	var usable: Vector2 = terminal.size - Vector2.ONE * float(terminal.cell_padding) * 2.0
	var cell: Vector2 = terminal.get_cell_size()
	return Vector2i(clampi(int(usable.x / cell.x), 20, 500), clampi(int(usable.y / cell.y), 5, 300))

func synchronized(terminal, expected: Vector2i) -> bool:
	var connection = host.get_parent().connection
	var id: int = host.active_session_id
	for pane in connection.topology.panes:
		if int(pane.id) == id:
			return terminal.get_grid_size() == expected and Vector2i(pane.columns, pane.rows) == expected
	return false

func await_grid(terminal) -> Vector2i:
	await process_frame
	var expected := expected_grid(terminal)
	var deadline := Time.get_ticks_msec() + 5000
	while not synchronized(terminal, expected) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(synchronized(terminal, expected), "Renderer and owner agree on canonical pane grid %s" % expected)
	return expected

func play() -> void:
	var terminal = host.sessions[host.active_session_id].term
	var initial := await await_grid(terminal)
	var original_font: int = terminal.get_live_font_size()
	var original_cell: Vector2 = terminal.get_cell_size()
	terminal.set_live_font_size(original_font + 10)
	terminal.set_live_font_config(PackedStringArray(["/missing/client-only-font.ttf"]), "Missing client font", PackedStringArray())
	terminal.set_live_cell_metrics(32.0, 2.0, 2.0)
	check(terminal.get_live_font_size() == original_font and terminal.get_cell_size() == original_cell, "Client font configuration cannot override owner fonts or metrics")
	var connection = host.get_parent().connection
	var faces: Array = connection.fonts_for(host.active_session_id).faces
	var manifest: Array = connection.topology.terminal_font.faces
	for index in faces.size():
		var path: String = faces[index].path
		var hash: String = str(manifest[index].sha256)
		var matches: bool = connection.fonts_for(host.active_session_id).native_assets.bundled_path(hash) == path if path.begins_with("bundled://") else FileAccess.get_sha256(path) == hash
		check(matches, "Resolved font face %d matches the owner's exact bytes" % index)
	terminal.send_text("printf 'GRID_PROBE_%s_END\\n' \"$(stty size)\"\n")
	var marker := "GRID_PROBE_%d %d_END" % [initial.y, initial.x]
	var deadline := Time.get_ticks_msec() + 5000
	while marker not in str(terminal.get_text(false).get("text", "")) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(marker in str(terminal.get_text(false).get("text", "")), "The actual PTY reports the same rows and columns through stty")
	var canonical: Rect2 = host.workspace_view.content_rect()
	# A following client letterboxes; a fitting one would claim the new shape.
	app.set_fit_main_view(false)
	root.size = Vector2i(700, 1100)
	root.content_scale_size = Vector2i(700, 1100)
	await hold(0.3)
	check(host.workspace_view.content_rect() == canonical and synchronized(terminal, initial), "Following client aspect ratio preserves canonical bounds and owner grid")
	host.workspace_view.pinch_workspace(Vector2(350, 550), Vector2(400, 520), 1.4)
	await hold(0.3)
	check(synchronized(terminal, initial), "Pan, zoom and changed raster density preserve the shared PTY grid")
	var font: int = terminal.get_live_font_size()
	host.world._set_terminal_font_size(font + 4)
	await hold(0.3)
	var larger := await await_grid(terminal)
	check(larger.x < initial.x and larger.y < initial.y, "A larger font changes actual owner wrapping")
	host.world._set_terminal_font_size(font)
	await hold(0.3)
	check(await await_grid(terminal) == initial, "Restoring the font restores the original canonical grid")
	# Fitting the main view to this window claims the shared area, so the
	# owner re-tiles at this window's shape and the PTY wraps to it.
	app.set_fit_main_view(true)
	await hold(0.5)
	var fitted: Rect2 = host.workspace_view.content_rect()
	check(fitted != canonical and fitted.is_equal_approx(host.workspace_view.window_fit_rect()), "Fitting this window claims its own main area")
	check(await await_grid(terminal) != initial, "The owner PTY wraps to the claimed shape")
	var saved := ConfigFile.new()
	check(saved.load(app.presentation_path()) == OK and saved.get_value("main_view", "fit_to_window", false) == true, "The main view size choice persists for this device")
