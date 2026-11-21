extends "../../../../replay/replay.gd"
## Real ConPTY receipts for configured local key routing; no OS clipboard use.
const Config = preload("res://graffitty/terminal_config.gd")


## Key routing comes from client.toml before the application starts.
func _initialize() -> void:
	super._initialize()
	var path := preload("res://config/UserConfig.gd").config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string(
		"[bindings]\nSendText = [{ key = \"F6\", text = \"λ123\" }]\nIgnore = \"F7\"\nFind = \"F8\"\n")

func press_key(code: int, unicode := 0) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = unicode
	for down in [true, false]:
		event.pressed = down
		host.sessions[host.active_session_id].vp.push_input(event, true)
		await process_frame

func wait_file(path: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not FileAccess.file_exists(path) and Time.get_ticks_msec() < deadline:
		await process_frame
	return FileAccess.file_exists(path)

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw reader starts inside the actual shell"):
		return
	var config := Config.new()
	config.leader = KEY_SPACE
	config.key_sequences = [Config.KeySequence.new([KEY_G, KEY_G], "send_text:SEQ"), Config.KeySequence.new([Config.LEADER, KEY_F], "send_text:LEAD")]
	var table := Config.KeyTable.new()
	table.bindings = [Config.KeyBinding.new(KEY_R, "send_text:TABLE")]
	table.timeout_ms = 200
	config.key_tables["once"] = table
	config.modal_key_bindings.search.append(Config.KeyBinding.new(KEY_F9, "cancel"))
	check(config.validate().is_empty(), "Configured key routes validate")
	config.apply_live(terminal)
	# Key tables have no client.toml form; add the activation beside the configured keys.
	check(terminal.key_bindings.get(KEY_F6) == "send_text:λ123" and terminal.key_bindings.get(KEY_F7) == "ignore", "client.toml SendText and Ignore reach the terminal")
	terminal.key_bindings = terminal.key_bindings.merged({KEY_T: "activate_key_table:once"})
	await press_key(KEY_F6)
	await press_key(KEY_F7)
	await press_key(KEY_G, 103)
	await press_key(KEY_G, 103)
	await press_key(KEY_SPACE, 32)
	await press_key(KEY_F, 102)
	await press_key(KEY_T, 116)
	await press_key(KEY_R, 114)
	await press_key(KEY_R, 114)
	await press_key(KEY_T, 116)
	await hold(.35)
	await press_key(KEY_R, 114)
	await press_key(KEY_F8)
	check(terminal.get_ui_state().modal == "search", "Configured key opens real terminal search")
	for character in "needle":
		await press_key(character.to_upper().unicode_at(0), character.unicode_at(0))
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("configured-search.png"))
	await press_key(KEY_F9)
	check(terminal.get_ui_state().modal == "", "Remapped modal key cancels search")
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw program records accumulated input"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "λ123SEQLEADTABLErr", "Bindings, ignored keys, leader, sequences, one-shot/expired tables and modal keys produce exact PTY bytes: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Config changes retain the original shell")
