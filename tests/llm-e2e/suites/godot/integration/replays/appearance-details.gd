extends "effects-pixels.gd"
const Appearance = preload("res://scenes/TerminalAppearanceSettings.gd")

func open_appearance() -> Node:
	for entry in host.menu_entries:
		if entry.label == "View::Appearance…":
			host._run_menu_action(entry)
			await hold(.1)
			for child in host.get_children():
				if child is Appearance: return child
	return null

func apply_appearance(dialog: Node) -> void:
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Appearance applied to this window.", "Appearance applies through actual controls")
	dialog.canceled.emit()
	await process_frame
	terminal.grab_focus()
	terminal.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	await hold(.1)

func cell_point(cell: Vector2) -> Vector2:
	var view: Control = host.workspace_view
	var local: Vector2 = terminal.position + Vector2.ONE * float(terminal.cell_padding) + cell * terminal.get_cell_size()
	return view.window_point(view.terminal_origin(host.pane_focus) + local * view.terminal_scale(host.pane_focus))

func snap(name: String) -> void:
	capture(name)
	host.sessions[host.active_session_id].vp.get_texture().get_image().save_png(directory.path_join(name + "-terminal.png"))

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Appearance raw reader starts"): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	var config = host.world.terminal_config.copy()
	config.copy_on_select = "none"
	config.apply_live(terminal)
	host.world.terminal_config.copy_on_select = "none"
	var dialog := await open_appearance()
	if not check(dialog != null, "Appearance opens through actual Edit menu"): return
	dialog.numbers.opacity.text = "2"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check("between" in dialog.status.text and host.world.terminal_config.background.alpha != 2, "Invalid opacity preserves live appearance")
	dialog.numbers.opacity.text = "1"
	dialog.colors.background.color = Color.BLACK
	dialog.colors.foreground.color = Color.WHITE
	dialog.colors.selection_background.color = Color.BLUE
	dialog.colors.selection_foreground.color = Color.GREEN
	dialog.colors.cursor_color.color = Color.RED
	dialog.blink.select(Appearance.BLINK.find("off"))
	dialog.outline.button_pressed = false
	await apply_appearance(dialog)
	if not await command("\u001b[2J\u001b[2;3HMMM->MMM\u001b[5;5H\u001b[?25l", Vector2i(-1,-1)): return
	overlay.hide()
	await hold(.1)
	snap("appearance-details-before")
	await drag(cell_point(Vector2(2.1,1.5)), cell_point(Vector2(9.9,1.5)), .1)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get() == "MMM->MMM", "Projected selection copies exact shaped text on private clipboard")
	snap("appearance-details-selected")
	dialog = await open_appearance()
	dialog.colors.selection_foreground.color = Color.RED
	await apply_appearance(dialog)
	snap("appearance-details-selection-red")
	await click(cell_point(Vector2(12.5,3.5)))
	dialog = await open_appearance()
	dialog.outline.button_pressed = true
	dialog.numbers.text_outline_width.text = "1"
	dialog.colors.text_outline_color.color = Color.RED
	await apply_appearance(dialog)
	snap("appearance-details-outline")
	dialog = await open_appearance()
	dialog.outline.button_pressed = false
	dialog.shape.select(Appearance.SHAPES.find("hollow"))
	await apply_appearance(dialog)
	if not await command("\u001b[?25h\u001b[6 q\u001b[8;12H", Vector2i(11,7)): return
	await process_frame
	snap("appearance-details-hollow")
	if not await command("\u001b[?25l", Vector2i(-1,-1)): return
	snap("appearance-details-hidden")
	dialog = await open_appearance()
	dialog.shape.select(0)
	await apply_appearance(dialog)
	if not await command("\u001b[?25h\u001b[2 q\u001b[8;12H", Vector2i(11,7)): return
	snap("appearance-details-application-block")
	terminal.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	await process_frame
	snap("appearance-details-unfocused")
	terminal.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	dialog = await open_appearance()
	dialog.blink.select(Appearance.BLINK.find("on"))
	dialog.numbers.cursor_blink_interval_ms.text = "180"
	await apply_appearance(dialog)
	await capture_blink("appearance-details-blink")
	# A real scrollback row shifts the live cursor in the viewport.
	var rows: int = terminal.get_grid_size().y
	if not await command("\u001b[%d;1H\n\u001b[8;12H" % rows, Vector2i(11,7)): return
	await hold(.15)
	var state: Dictionary = terminal.get_ui_state()
	terminal.scroll_to_row(int(state.scroll_offset) - 1)
	await process_frame
	await capture_blink("appearance-details-scrolled-blink")
	terminal.scroll_to_row(terminal.get_ui_state().scroll_total)
	dialog = await open_appearance()
	dialog.blink.select(Appearance.BLINK.find("off"))
	await apply_appearance(dialog)
	snap("appearance-details-steady-a")
	await hold(.3)
	snap("appearance-details-steady-b")
	dialog = await open_appearance()
	capture("appearance-details-dialog")
	var scroll: ScrollContainer = dialog.grid.get_parent()
	scroll.scroll_vertical = int(dialog.grid.size.y)
	await process_frame
	capture("appearance-details-dialog-bottom")
	dialog.numbers.opacity.text = ".1"
	dialog.canceled.emit()
	await process_frame
	check(host.world.terminal_config.background.alpha == 1, "Cancel discards unapplied appearance edits")
	FileAccess.open(directory.path_join("appearance-metrics.json"), FileAccess.WRITE).store_string(JSON.stringify({"cell": [terminal.get_cell_size().x,terminal.get_cell_size().y],"padding":terminal.cell_padding}, "  "))
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Appearance raw reader finishes"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "", "Appearance controls and selection leak no PTY input")
	check(terminal.get_shell_pid() == pid, "Appearance preserves original shell")
	release.call()

func capture_blink(prefix: String) -> void:
	# Record distinct raster phases, not merely a preference flag.
	await hold(.04)
	snap(prefix + "-a")
	await hold(.19)
	snap(prefix + "-b")
