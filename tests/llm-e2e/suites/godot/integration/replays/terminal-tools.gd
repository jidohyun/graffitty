extends "appearance-details.gd"

func letters(value: String) -> void:
	for c in value: await press_key(c.to_upper().unicode_at(0), c.unicode_at(0))

func menu(action: String) -> void:
	for entry in host.menu_entries:
		if entry.label == action:
			host._run_menu_action(entry)
			await process_frame
			return
	check(false, "Menu action exists: " + action)

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Tools private reader starts"): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var history := "\u001b[2J\u001b[Hneedle oldest\r\nneedle recent\r\n"
	for i in 65: history += "history %d\r\n" % i
	if not await command(history + "\u001b[10;1HTOOLS_READY\u001b[12;1Hhttps://example.test/tools\u001b[10;1H", Vector2i(0,9)): return
	await menu("Edit::Find…")
	await letters("needle")
	await press_key(KEY_ENTER)
	await process_frame
	check(terminal.get_ui_state().modal == "copy_mode" and int(terminal.get_ui_state().scroll_offset) < int(terminal.get_ui_state().scroll_total), "Search reveals a historical row")
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get() == "needle", "Search copies exact match")
	snap("terminal-search")
	await letters("N")
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get() == "needle", "Previous search result copies exact match")
	await press_key(KEY_ESCAPE)
	terminal.scroll_to_row(terminal.get_ui_state().scroll_total)
	await menu("Edit::Copy Mode")
	await letters("vllll")
	snap("terminal-copy-mode")
	await press_key(KEY_ENTER)
	check(DisplayServer.clipboard_get() == "TOOLS" and terminal.get_ui_state().modal == "", "Accepting keyboard selection copies only TOOLS and exits")
	terminal.perform_action("quick_select")
	await process_frame
	var quick: Dictionary = terminal.get_quick_select_state()
	var label := ""
	for item in quick.matches:
		if item.text == "https://example.test/tools": label = item.label
	if not check(not label.is_empty(), "Quick Select labels the visible URL"): return
	snap("terminal-quick-select")
	await letters(label)
	check(DisplayServer.clipboard_get() == "https://example.test/tools", "Lowercase label copies exact URL")
	terminal.perform_action("quick_select")
	await process_frame
	await letters(label.to_upper())
	check(terminal.get_ui_state().modal == "", "Uppercase label pastes and exits")
	if not await command("\u001b[2J\u001b[H\u001b]133;A\u0007$ \u001b]133;B\u0007command\r\n\u001b]133;C\u0007ONLY_MARKED_OUTPUT\r\n\u001b]133;D;0\u0007\u001b]133;A\u0007$ \u001b]133;B\u0007\u001b[6;3H", Vector2i(2,5)): return
	check(terminal.copy_last_output(), "Semantic last output is available")
	await process_frame
	check(DisplayServer.clipboard_get().strip_edges() == "ONLY_MARKED_OUTPUT", "Semantic copy excludes prompt and command")
	snap("terminal-last-output")
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Tools reader completes"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "https://example.test/tools", "Only deliberate uppercase paste reaches PTY; modal keys and releases consumed: " + receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Tools preserve original shell PID")
	release.call()
