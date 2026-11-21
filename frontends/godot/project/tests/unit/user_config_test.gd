extends "res://tests/unit/test_case.gd"
const Loader := preload("res://config/UserConfig.gd")
const Settings := preload("res://graffitty/config.gd")


func test_native_dictionary_arrays_preserve_configured_entries() -> void:
	const Config = preload("res://graffitty/terminal_config.gd")
	var config := Config.new()
	config.symbol_maps = [Config.SymbolMap.new(0x2600, 0x26ff, "Segoe UI Symbol")]
	config.mouse_bindings = [Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON1, "send_text:BACK")]
	config.key_sequences = [Config.KeySequence.new([KEY_G, KEY_G], "send_text:SEQ")]
	var table := Config.KeyTable.new()
	table.bindings = [Config.KeyBinding.new(KEY_R, "send_text:TABLE")]
	config.key_tables["once"] = table
	var compiled: Dictionary = config.compiled_advanced()
	for entries: Array in [compiled.symbol_maps, compiled.mouse_bindings, compiled.key_sequences, compiled.key_tables.once.bindings]:
		expect(entries.get_typed_builtin() == TYPE_DICTIONARY,
			"Native Array[Dictionary] conversion must not silently discard these options")
		expect(entries.size() == 1, "The configured entry survives compilation")
	expect(compiled.symbol_maps[0].family == "Segoe UI Symbol", "Symbol font family survives compilation")


func _args(name: String, source: String) -> PackedStringArray:
	return PackedStringArray([client_toml(name, source)])


func test_terminal_window_and_client_sections_apply() -> void:
	var args := _args("sections", """
language = "ko"

[world]
path = "~/bistro.pck"

[window]
decorations = "system"
ui_scale = 1.5
max_fps = 120
inactive_max_fps = 20
macos.blur_radius = 32
windows.blur_material = "mica"

[tiling]
enabled = false
gap = 4

[power]
enabled = true
battery_world = "flat-2d"

[terminal]
font_size = 18
font_regular_path = "fonts/Mono.ttf"
foreground = "#eeeeee"
selection_foreground = "none"
palette_overrides = { "17" = "#123456" }
iskeyword = ["@", "-"]
symbol_maps = [{ first = 0xE000, last = 0xF8FF, family = "Symbols Nerd Font" }]

[terminal.background]
color = "#101010"
alpha = 0.5

[terminal.effects.cursor_trail]
style = "smear"
decay = [0.2, 0.6]
blaze = { color = "#ff0000" }

[terminal.effects.typing_particles]
preset = "flames"
""")
	var terminal = Loader.terminal_config(args)
	expect(terminal.font_size == 18 and terminal.foreground == Color("#eeeeee"), "Terminal scalars and colors apply")
	expect(terminal.selection_foreground == Color.TRANSPARENT, "\"none\" is a transparent color")
	expect(terminal.font_regular_path.is_absolute_path() and terminal.font_regular_path.ends_with("fonts/Mono.ttf"), "Font paths resolve beside the file")
	expect(terminal.palette_overrides[17] == Color("#123456"), "Palette overrides use numeric indices")
	expect(terminal.iskeyword == ["@", "-"] and terminal.symbol_maps[0].family == "Symbols Nerd Font", "Arrays and tables apply")
	expect(terminal.background.color == Color("#101010") and terminal.background.alpha == 0.5, "Background applies")
	expect(terminal.effects.cursor_trail.style == "smear" and terminal.effects.cursor_trail.decay == Vector2(0.2, 0.6), "Trail settings apply")
	expect(terminal.effects.cursor_trail.blaze.color == Color("#ff0000") and terminal.effects.cursor_trail.blaze.duration == 0.5, "Trail style options merge with defaults")
	expect(terminal.effects.typing_particles.preset == "flames", "Particles apply")
	var window = Loader.window_config(args)
	expect(window.max_fps == 120 and window.inactive_max_fps == 20 and window.macos.blur_radius == 32 and window.windows.blur_material == "mica", "Window settings apply")
	expect(window.decorations == "system", "The Linux frame override reaches window settings")
	expect(window.ui_scale == 1.5, "The desktop scale override reaches window settings")
	var tiling = Loader.tiling_config(args)
	expect(not tiling.enabled and tiling.gap == 4.0, "Tiling applies")
	var power = Loader.power_config(args)
	expect(power.enabled and power.battery_world == "flat-2d" and power.external_world == "flat-3d", "Power applies with defaults")
	expect(Loader.world_path(args) == Loader.expand_home("~/bistro.pck"), "World paths expand the home directory")
	expect(Loader.language(args) == "ko" and Loader.language(PackedStringArray()) == "auto", "Language applies")


func test_stdpath_placeholders_expand_in_paths() -> void:
	var args := _args("stdpaths", "[world]\npath = '%(data)/worlds/bistro/bistro.pck'\n[power]\nexternal_world = 'bistro'\n")
	expect(Loader.world_path(args) == Loader.stdpath("data").path_join("worlds/bistro/bistro.pck"), "%(data) is the app data directory")
	expect(Loader.power_config(args).external_world == "bistro", "A world id is kept as an id")
	var invalid := Loader.resolved(_args("stdpath-unknown", "[world]\npath = '%(temp)/w.pck'\n"))
	expect(str(invalid.get("error", "")).contains("unknown placeholder %(temp)"), "Unknown placeholders are configuration errors")


func test_overlays_apply_in_order() -> void:
	var args := PackedStringArray([
		client_toml("first", "[terminal]\nfont_size = 18\nligatures = false\n[bindings]\nNewTab = \"Alt+T\"\n"),
		client_toml("second", "[terminal]\nfont_size = 20\n"),
	])
	var terminal = Loader.terminal_config(args)
	expect(terminal.font_size == 20 and not terminal.ligatures, "Later files override only the keys they set")
	expect(Loader.bindings(args).direct_action(KEY_T | KEY_MASK_ALT) == "NewTab", "Earlier bindings survive later files")


func test_invalid_configuration_uses_defaults_and_reports_errors() -> void:
	for source in [
		"[terminal]\nfont_size = \"big\"\n",
		"[terminal]\nkey_bindings = []\n",
		"[bindings]\nnew_tab = \"Ctrl+T\"\n",
		"[[menu.items]]\nlabel = \"Shell::X\"\naction = \"NewTab\"\nshortcut = \"Ctrl+T\"\n",
		"not toml = = 1\n",
	]:
		var args := _args("invalid", source)
		var errors := Loader.validate_startup(args)
		expect(errors.size() == 1 and errors[0].contains("graffitty-client-"), "Invalid file is reported with its path: " + source)
		expect(Loader.terminal_config(args).font_size == preload("res://graffitty/terminal_config.gd").new().font_size, "Defaults apply: " + source)
	var range := _args("range", "[terminal]\nfont_size = 900\n")
	expect(not Loader.validate_startup(range).is_empty(), "Value ranges are validated at startup")
	var font := _args("font", "[terminal]\nfont_regular_path = \"missing.ttf\"\n")
	expect(Loader.validate_startup(font)[0].contains("font file does not exist"), "Missing font files are reported")
	expect(Loader.validate_startup(_args("valid", "[terminal]\nfont_size = 17\n")).is_empty(), "A valid file passes")


func test_menu_entries_are_platform_filtered_and_named_by_action() -> void:
	var platform := Settings.Bindings.platform()
	var other := "windows" if platform != "windows" else "linux"
	var args := _args("menu", """
[[menu.items]]
label = "Custom::Here"
action = "NewTab"
os = ["%s"]

[[menu.items]]
label = "Custom::Elsewhere"
action = "NewTab"
os = ["%s"]

[[menu.items]]
label = "Custom::Work Browser"
action = "NewChromium"
profile = "work"

[[menu.items]]
label = "View::World::Bistro"
action = "SwitchWorld"
path = "~/bistro.pck"
""" % [platform, other])
	var entries := Loader.menu_entries(args)
	var labels := entries.map(func(entry): return entry.label)
	expect(labels == ["Custom::Here", "Custom::Work Browser", "View::World::Bistro"], "Entries for other platforms are omitted")
	expect(entries[1].profile == "work" and entries[2].path == Loader.expand_home("~/bistro.pck"), "Menu parameters survive")
	expect(not entries[0].has("shortcut"), "Menus reference actions; shortcuts come from bindings")


func test_bindings_resolve_ctrl_a_prefix_and_per_os_values() -> void:
	var platform := Settings.Bindings.platform()
	var mac := platform == "macos"
	var defaults := Loader.bindings(PackedStringArray())
	expect(defaults.prefix == (KEY_A | KEY_MASK_CTRL), "The default prefix is Ctrl+A on every platform")
	expect(defaults.prefix_bindings()[KEY_C] == "NewTab" and defaults.direct_key("NewTab") == (KEY_T | (KEY_MASK_META if mac else KEY_MASK_CTRL | KEY_MASK_SHIFT)), "NewTab has a direct shortcut and a prefix sequence")
	var args := _args("bindings", """
[prefix]
key = { %s = "Ctrl+Alt+B" }

[bindings]
NewTab = { %s = ["Alt+N", "Prefix+X"] }
FocusLeft = []
Copy = "CmdOrCtrlShift+C"
""" % [platform, platform])
	var resolved := Loader.bindings(args)
	# Ctrl+Shift+B is ToggleSidePanels outside Apple platforms; a prefix may not take a bound key.
	expect(resolved.prefix == (KEY_B | KEY_MASK_CTRL | KEY_MASK_ALT), "Per-OS prefix key applies")
	expect(resolved.direct_key("Copy") == (KEY_C | (KEY_MASK_META if platform in ["macos", "ios"] else KEY_MASK_CTRL | KEY_MASK_SHIFT)), "CmdOrCtrlShift resolves through the Rust configuration bridge")
	expect(resolved.direct_action(KEY_N | KEY_MASK_ALT) == "NewTab" and resolved.prefix_bindings()[KEY_X] == "NewTab", "Per-OS arrays bind both forms")
	expect(not resolved.prefix_bindings().has(KEY_C), "A configured action replaces its defaults")
	expect(resolved.prefix_key("FocusLeft") == KEY_NONE and not resolved.prefix_bindings().has(KEY_H), "An empty array unbinds")
	var prefix = Loader.prefix_config(args)
	expect(prefix.key == resolved.prefix and prefix.bindings == resolved.prefix_bindings(), "Prefix settings come from the same bindings")


func test_no_config_skips_the_automatic_file() -> void:
	DirAccess.make_dir_recursive_absolute(Loader.config_path().get_base_dir())
	FileAccess.open(Loader.config_path(), FileAccess.WRITE).store_string("[terminal]\nfont_size = 31\n")
	expect(Loader.terminal_config(PackedStringArray()).font_size == 31, "client.toml loads automatically")
	expect(Loader.terminal_config(PackedStringArray(["--no-config"])).font_size != 31, "--no-config skips it")
	var explicit := client_toml("explicit", "[terminal]\nfont_size = 33\n")
	expect(Loader.terminal_config(PackedStringArray(["--no-config", explicit])).font_size == 33, "Explicit overlays still apply")
	expect(Loader.override_paths(PackedStringArray(["--config=extra.toml"])) == [Loader.config_path(), "extra.toml"], "Every --config file is a TOML overlay after the automatic file")
	DirAccess.remove_absolute(Loader.config_path())


func test_send_text_and_ignore_route_through_the_terminal_key_table() -> void:
	var platform := Settings.Bindings.platform()
	var args := _args("send-text", """
[bindings]
SendText = { %s = [{ key = "Shift+Enter", text = "\\u001b\\r" }, { key = "F6", text = "λ" }] }
Ignore = "F7"
""" % platform)
	var native := Loader.terminal_key_bindings(args)
	expect(native[KEY_ENTER | KEY_MASK_SHIFT] == "send_text:\u001b\r", "SendText writes its entry's own text")
	expect(native[KEY_F6] == "send_text:λ", "Each SendText entry keeps its text")
	expect(native[KEY_F7] == "ignore", "Ignore swallows its key in the terminal")
	var bindings := Loader.bindings(args)
	expect(bindings.direct_action(KEY_F6) == "SendText", "SendText keys resolve to the shared action")
	var invalid := _args("send-text-invalid", "[bindings]\nSendText = \"F6\"\n")
	expect(not Loader.validate_startup(invalid).is_empty(), "SendText requires { key, text } entries")
	var menu := _args("send-text-menu", "[[menu.items]]\nlabel = \"Edit::Line Start\"\naction = \"SendText\"\ntext = \"\\u0001\"\n")
	expect(Loader.menu_entries(menu)[0].text == "\u0001", "A SendText menu entry carries its text")


func test_prompt_jumps_are_conditional_by_default() -> void:
	var defaults := _isolated("when-defaults", "")
	var conditions := Loader.terminal_key_conditions(defaults)
	expect(conditions.get(KEY_UP | KEY_MASK_SHIFT) == "prompt", "Shift+Up jumps prompts only at a shell prompt")
	expect(conditions.get(KEY_DOWN | KEY_MASK_SHIFT) == "prompt", "Shift+Down jumps prompts only at a shell prompt")
	expect(Loader.terminal_key_bindings(defaults)[KEY_UP | KEY_MASK_SHIFT] == "previous_prompt", "The key still maps to the prompt jump")
	var platform := Settings.Bindings.platform()
	var custom := _isolated("when-custom", """
[bindings]
PreviousPrompt = "Shift+Up"
Ignore = { %s = { key = "F8", when = "!alt_screen" } }
""" % platform)
	conditions = Loader.terminal_key_conditions(custom)
	expect(not conditions.has(KEY_UP | KEY_MASK_SHIFT), "A plain entry makes the shortcut unconditional")
	expect(conditions.get(KEY_DOWN | KEY_MASK_SHIFT) == "prompt", "Untouched actions keep their default condition")
	expect(conditions.get(KEY_F8) == "!alt_screen", "Configured conditions reach the terminal")
	var invalid := _isolated("when-invalid", "[bindings]\nNewTab = { key = \"F9\", when = \"prompt\" }\n")
	expect(not Loader.validate_startup(invalid).is_empty(), "when is only for terminal actions")


## Ignores the developer's own client.toml so defaults are the shipped ones.
func _isolated(name: String, source: String) -> PackedStringArray:
	return PackedStringArray(["--no-config", client_toml(name, source)])
