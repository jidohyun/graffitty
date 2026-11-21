extends "main-area-tiling.gd"
const Application := preload("res://scenes/TerminalApplication.gd")
var expected := {}
var pids := {}

func _initialize() -> void:
	OS.set_environment("XDG_STATE_HOME", OS.get_environment("XDG_STATE_HOME").path_join("graffitty-font-replay-%d" % OS.get_process_id()))
	super._initialize()

func terminal(key: String) -> Node:
	return host.sessions[int(key.substr(1))].term

func remember(key: String, size: int) -> void:
	expected[key] = size
	pids[key] = terminal(key).get_shell_pid()

func verify() -> void:
	host.workspace_view.refresh()
	for key in expected:
		check(terminal(key).get_live_font_size() == expected[key], "%s retains its own font size %d (actual %d)" % [key, expected[key], terminal(key).get_live_font_size()])
		check(terminal(key).get_shell_pid() == pids[key], "Changing fonts preserves " + key + " shell")

func change(key: String, shortcut: String) -> void:
	host.focus_pane(key)
	await camera_at_rest()
	terminal(key).grab_focus()
	var before: int = terminal(key).get_live_font_size()
	if shortcut == "cmd+=":
		await _key(KEY_EQUAL, 61, {"cmd": OS.get_name() == "macOS", "ctrl": OS.get_name() != "macOS"}, "⌘+")
	elif shortcut == "cmd+-":
		await _key(KEY_MINUS, 45, {"cmd": OS.get_name() == "macOS", "ctrl": OS.get_name() != "macOS"}, "⌘−")
	else:
		await keys(shortcut if OS.get_name() == "macOS" else shortcut.replace("cmd+", "ctrl+"))
	await hold(0.2)
	if shortcut == "cmd+=": check(terminal(key).get_live_font_size() > before, "Increase shortcut enlarges the focused pane")
	if shortcut == "cmd+-": check(terminal(key).get_live_font_size() < before, "Decrease shortcut shrinks the focused pane")

func play() -> void:
	await camera_at_rest()
	var a: String = host.pane_focus
	var initial: int = terminal(a).get_live_font_size()
	var b := await add_window(a)
	if b.is_empty(): return
	remember(a, initial)
	remember(b, initial)
	var grid_b: Vector2i = terminal(b).get_grid_size()
	await say("Independent existing panes: only the focused font changes")
	await change(a, "cmd+=")
	await change(a, "cmd+=")
	expected[a] = terminal(a).get_live_font_size()
	verify()
	check(terminal(b).get_grid_size() == grid_b, "Unfocused pane grid does not change")
	await change(b, "cmd+-")
	expected[b] = terminal(b).get_live_font_size()
	verify()
	await say("New panes use the latest chosen size, not the focused pane size")
	host.focus_pane(a)
	await camera_at_rest()
	var c := await add_window(a, "v")
	if c.is_empty(): return
	remember(c, expected[b])
	verify()
	await change(c, "cmd+=")
	expected[c] = terminal(c).get_live_font_size()
	await open_tabs(2)
	await camera_at_rest()
	var d: String = host.pane_focus
	remember(d, expected[c])
	verify()
	await select_tab(0)
	await camera_at_rest()
	verify()
	await toggle_tiling()
	verify()
	await say("Reset is local and updates the recent preference")
	await change(a, "cmd+0")
	expected[a] = int(host.world.term_font_size_default)
	verify()
	check(app.new_pane_font_size(30) == expected[a], "Explicit reset updates recent preference")
	await change(b, "cmd+-")
	expected[b] = terminal(b).get_live_font_size()
	verify()
	var reader := Application.new()
	check(reader.new_pane_font_size(30) == expected[b], "Fresh application state reader loads the saved recent size")
	reader.free()
	var snapshot: Dictionary = await app.checkpoints.capture()
	check(snapshot.has("result"), "Session snapshot captures pane sizes")
	if snapshot.has("result"):
		for window in snapshot.result.windows:
			for pane in window.panes:
				check(int(pane.font_size) == expected["%%%d" % int(pane.id)], "Saved pane retains its individual font size")
		var saved: Dictionary = snapshot.result.windows[0]
		terminal(a).set_meta("pane_font_size", 30)
		terminal(a).set_live_font_size(30)
		app.checkpoints.finish_host(host, saved)
		await camera_at_rest()
		verify()
		check(app.new_pane_font_size(30) == expected[b], "Restoring older pane sizes does not replace the recent preference")
	await say("A new desktop window also follows the recent preference")
	host.create_native_window()
	await hold(0.6)
	var others: Array = app.hosts.filter(func(value): return value != host)
	check(others.size() == 1, "New Window creates a separate host")
	if not others.is_empty():
		var peer: Node = others[0]
		var term: Node = peer.sessions[peer.active_session_id].term
		check(term.get_live_font_size() == expected[b], "New desktop window inherits the latest chosen size")
	verify()
