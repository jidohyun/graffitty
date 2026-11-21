extends "input-routing.gd"
const Settings = preload("res://scenes/TerminalInputSettings.gd")


## Unbind the default terminal search shortcut before the application starts.
func _initialize() -> void:
	super._initialize()
	var path := preload("res://config/UserConfig.gd").config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string("[bindings]\nFind = []\n")

func open_settings() -> Node:
	for entry in host.menu_entries:
		if entry.label == "Edit::Input Settings…":
			host._run_menu_action(entry)
			await hold(.2)
			for child in host.get_children():
				if child is Settings:
					return child
	return null

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw reader starts"):
		return
	var dialog := await open_settings()
	if not check(dialog != null and dialog.visible, "Input Settings opens from the actual Edit menu"):
		return
	dialog.speed.text = "not a number"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check("must be a number" in dialog.status.text, "Invalid typed scroll speed is rejected")
	check(host.world.terminal_config.scroll_multiplier == 1.0, "Invalid speed preserves the working value")
	dialog.canceled.emit()
	await process_frame
	# client.toml unbinds Find, so its default key reaches the PTY.
	var removed := InputEventKey.new()
	removed.keycode = KEY_F
	removed.ctrl_pressed = true
	removed.shift_pressed = true
	for down in [true, false]:
		removed.pressed = down
		root.push_input(removed, true)
		await process_frame
	check(terminal.get_ui_state().modal == "", "An unbound action's default key no longer opens search")
	var tiled: bool = host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false)
	host.prefix_commands.settings.key = KEY_F10
	host.prefix_commands.settings.bindings[KEY_K] = "ToggleTiling"
	for code in [KEY_F10, KEY_K]:
		var prefix_key := InputEventKey.new()
		prefix_key.keycode = code
		for down in [true, false]:
			prefix_key.pressed = down
			root.push_input(prefix_key, true)
			await process_frame
	check(host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false) != tiled and not host.prefix_commands.active, "Configured workspace prefix runs its action once")
	dialog = await open_settings()
	dialog.speed.text = "2"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Input settings applied.", "Valid speed changes apply: %s" % dialog.status.text)
	check(host.world.terminal_config.scroll_multiplier == 2.0, "Applied speed reaches the current window")
	overlay.hide()
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("input-settings.png"))
	dialog.speed.text = "4"
	dialog.canceled.emit()
	await process_frame
	check(host.world.terminal_config.scroll_multiplier == 2.0, "Cancel discards unapplied changes")
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw program records input after dialog closure"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "\u001b[102;6u", "The unbound key and consumed workspace prefix deliver exact bytes: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Settings preserve the original shell")
