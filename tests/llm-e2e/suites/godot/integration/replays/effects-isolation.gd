extends "effects-pixels.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var original_id: int = host.active_session_id
	var original_key: String = host.pane_focus
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Isolation raw reader starts"): return
	host.create_terminal_window()
	var deadline := Time.get_ticks_msec() + 10000
	while host.sessions.size() < 2 and Time.get_ticks_msec() < deadline: await process_frame
	if not check(host.sessions.size() == 2, "Independent second pane opens"): return
	var second: String = host.pane_focus
	host.focus_pane(original_key)
	await camera_at_rest()
	await configure("lightning", "none")
	var renderer: Node = host.world.terminal_effects
	if not await command("\u001b[2J\u001b[2 q\u001b[5;5H", Vector2i(4,4)): return
	await hold(.7)
	if not await command("\u001b[11;31H", Vector2i(30,10)): return
	deadline = Time.get_ticks_msec() + 1000
	while not renderer.trail.active and Time.get_ticks_msec() < deadline: await process_frame
	check(renderer.trail.active, "Original pane has live trail before switch")
	host.focus_pane(second)
	await process_frame
	check(renderer.terminal == host.active_terminal() and not renderer.trail.active, "Pane focus clears old trail instead of joining unrelated cursors")
	if not await command("\u001b[16;21H", Vector2i(20,15)): return
	await hold(.1)
	check(not renderer.trail.active, "Output in unfocused pane cannot move focused pane trail")
	await host.create_native_window()
	var other: Node
	for candidate in app.hosts:
		if candidate != host: other = candidate
	if not check(other != null, "Independent native window opens on private desktop"): return
	await hold(1.2)
	host.focus_pane(original_key)
	await process_frame
	if not await command("\u001b[6;6H", Vector2i(5,5)): return
	await hold(.7)
	if not await command("\u001b[11;31H", Vector2i(30,10)): return
	deadline = Time.get_ticks_msec() + 1000
	while not renderer.trail.active and Time.get_ticks_msec() < deadline: await process_frame
	check(renderer.trail.active and not other.world.terminal_effects.trail.active, "Live trail remains confined to its native window")
	check(renderer.terminal != other.world.terminal_effects.terminal, "Windows bind independent terminal renderers")
	overlay.hide()
	RenderingServer.force_draw(false)
	other.get_window().get_texture().get_image().save_png(directory.path_join("unrelated-window.png"))
	check(host.sessions[original_id].term.get_shell_pid() == pid, "Focus and window creation retain original shell")
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	check(await wait_file(directory.path_join("receipt.json")), "Original raw reader exits normally")
