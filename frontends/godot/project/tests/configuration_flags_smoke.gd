extends SceneTree
const Loader = preload("res://config/UserConfig.gd")
const Settings = preload("res://graffitty/config.gd")

func _initialize() -> void:
	run.call_deferred()

func write(path: String, text: String) -> void:
	FileAccess.open(path, FileAccess.WRITE).store_string(text)

func run() -> void:
	var evidence := OS.get_environment("GRAFFITTY_CONFIG_EVIDENCE")
	if evidence.is_empty():
		printerr("A private GRAFFITTY_CONFIG_EVIDENCE directory is required")
		quit(1)
		return
	OS.set_environment("XDG_CONFIG_HOME", evidence.path_join("config"))
	DirAccess.make_dir_recursive_absolute(Loader.stdpath("config"))
	write(Loader.config_path(), "[window]\nmax_fps = 73\n[terminal]\nfont_size = 17\n")
	var first := evidence.path_join("first.toml")
	var second := evidence.path_join("second.toml")
	write(first, "[window]\ninactive_max_fps = 19\n[terminal]\nfont_size = 21\n")
	write(second, "[terminal]\nfont_size = 23\n")
	var args := PackedStringArray(["--config=" + first, "--config=" + second])
	assert(Loader.window_config(args).max_fps == 73)
	assert(Loader.window_config(args).inactive_max_fps == 19)
	assert(Loader.terminal_config(args).font_size == 23)
	var hashes := {}
	for path in [Loader.config_path(), first, second]: hashes[path] = FileAccess.get_sha256(path)
	args.append("--no-config")
	assert(Loader.override_paths(args) == [first, second])
	assert(Loader.window_config(args).max_fps == Settings.WindowSettings.new().max_fps)
	assert(Loader.window_config(args).inactive_max_fps == 19)
	assert(Loader.terminal_config(args).font_size == 23)
	for path in hashes: assert(FileAccess.get_sha256(path) == hashes[path])
	write(evidence.path_join("report.json"), JSON.stringify({"status":"PASS", "checks":["Automatic file precedes explicit overlays", "Later overlay wins and unrelated settings survive", "--no-config omits the automatic client.toml", "Explicit overlays retain order under --no-config", "All input configuration hashes remain unchanged"], "hashes":hashes}, "  "))
	print("CONFIGURATION_FLAGS_SMOKE_PASS")
	quit(0)
