extends ConfirmationDialog
## Future local sessions only; existing panes retain their owner-side state.
var host: Node
var shell := LineEdit.new()
var directory := LineEdit.new()
var arguments := TextEdit.new()
var environment := TextEdit.new()
var login := CheckBox.new()
var status := Label.new()
var limits: Dictionary = {}
var integration := OptionButton.new()

func _ready() -> void:
	title = "Session Defaults"
	ok_button_text = "Apply"
	dialog_hide_on_ok = false
	exclusive = true
	var outer := VBoxContainer.new()
	add_child(outer)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(status)
	var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
	scroll.custom_minimum_size = Vector2(560,minf(520,get_tree().root.size.y-180))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	outer.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	content.add_theme_constant_override("separation", 8)
	var preferences: Dictionary = host.application.local_spawn_defaults
	for pair in [["New local sessions only. Existing panes and remote hosts keep their settings.", null],
		["Shell executable (empty uses server default)",shell],
		["Arguments (one literal argument per line)",arguments],
		["Initial directory (new tabs and splits inherit the source pane's live directory)",directory],
		["Environment (NAME=value, one per line; values are literal)",environment]]:
		var label := Label.new()
		label.text = pair[0]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(label)
		if pair[1] != null: content.add_child(pair[1])
	for field in [arguments, environment]:
		field.custom_minimum_size.y = 85
		field.size_flags_vertical = Control.SIZE_FILL
	shell.text = preferences.get("shell", "")
	directory.text = preferences.get("cwd", "")
	arguments.text = "\n".join(preferences.get("args", []))
	var entries: PackedStringArray = []
	for key in preferences.get("env", {}): entries.append(key + "=" + preferences.env[key])
	environment.text = "\n".join(entries)
	for spec in [["scrollback_bytes","Scrollback byte budget (0–134217728)",0,134217728],
		["kitty_image_storage_mb","Kitty image storage (0–2048 MB)",0,2048],
		["kitty_image_transmission_mib","Kitty upload limit (1–512 MiB)",1,512]]:
		var label := Label.new()
		label.text = spec[1]
		content.add_child(label)
		var edit := LineEdit.new()
		edit.placeholder_text = "Server default"
		edit.text = str(preferences[spec[0]]) if preferences.has(spec[0]) else ""
		limits[spec[0]] = {"edit":edit,"minimum":spec[2],"maximum":spec[3],"caption":spec[1]}
		content.add_child(edit)
	var hint := Label.new()
	hint.text = "Blank uses server defaults. Scrollback bytes are rounded to engine pages; 0 keeps no scrollback. Zero image storage rejects images. Existing panes keep their resolved limits."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)
	for item in ["Shell integration: server default","Shell integration: enabled","Shell integration: disabled"]: integration.add_item(item)
	integration.select((1 if preferences.shell_integration else 2) if preferences.has("shell_integration") else 0)
	content.add_child(integration)
	login.text = "Login shell"
	login.button_pressed = preferences.get("login", false)
	# PowerShell's login switch is unavailable on Windows.
	content.add_child(login)
	login.visible = OS.get_name() != "Windows"
	confirmed.connect(apply_changes)
	canceled.connect(queue_free)
	popup_centered.call_deferred()

static func executable(value: String, path: String) -> String:
	if value.is_absolute_path() or "/" in value or "\\" in value:
		return value if FileAccess.file_exists(value) else ""
	var filename := value
	if OS.get_name()=="Windows" and filename.get_extension().is_empty(): filename += ".exe"
	for folder in path.split(";" if OS.get_name()=="Windows" else ":"):
		var candidate := folder.path_join(filename)
		if FileAccess.file_exists(candidate): return candidate
	return ""

func apply_changes() -> void:
	var candidate := {"login":login.button_pressed,"args":[],"env":{}}
	for name in limits:
		var item: Dictionary = limits[name]
		var text: String = item.edit.text.strip_edges()
		if text.is_empty(): continue
		if not text.is_valid_int() or int(text)<int(item.minimum) or int(text)>int(item.maximum):
			status.text = tr("%s must be a whole number from %d to %d.") % [tr(item.caption),item.minimum,item.maximum]
			return
		candidate[name] = int(text)
	if integration.selected != 0: candidate.shell_integration = integration.selected == 1
	var total := 0
	for line in environment.text.split("\n",false):
		var separator := line.find("=")
		var key := line.left(separator) if separator>0 else ""
		if RegEx.create_from_string("^[a-zA-Z_][a-zA-Z_0-9]*$").search(key)==null or key.length()>128:
			status.text = "Enter environment variables as NAME=value."
			return
		var upper := key.to_upper()
		if upper.begins_with("GRAFFITTY_") or upper.begins_with("CODEX_") or upper=="GODOT_AGENT_SOCKET":
			status.text = tr("%s is managed by the session server.") % key
			return
		var value := line.substr(separator+1)
		total += line.to_utf8_buffer().size()
		if candidate.env.has(key) or value.to_utf8_buffer().size()>65536 or value.to_utf8_buffer().has(0):
			status.text = "Environment names must be unique and values must fit in 64 KiB without NUL."
			return
		candidate.env[key] = value
	if candidate.env.size()>128 or total>262144:
		status.text = "Use at most 128 environment entries, within 256 KiB."
		return
	if arguments.text.to_utf8_buffer().size()>262144 or arguments.text.to_utf8_buffer().has(0):
		status.text = "Arguments must fit in 256 KiB without NUL."
		return
	candidate.args = Array(arguments.text.split("\n",false))
	if candidate.args.size()>128:
		status.text = "Use at most 128 arguments."
		return
	var program := shell.text.strip_edges()
	if not program.is_empty():
		var resolved := executable(program, candidate.env.get("PATH",OS.get_environment("PATH")))
		if resolved.is_empty():
			status.text = tr("Shell executable does not exist: %s") % program
			return
		candidate.shell = resolved
	var cwd := directory.text.strip_edges()
	if not cwd.is_empty():
		if not cwd.is_absolute_path() or not DirAccess.dir_exists_absolute(cwd):
			status.text = "Initial directory must be an existing absolute directory."
			return
		candidate.cwd = cwd
	host.application.local_spawn_defaults = candidate
	status.text = "Defaults applied to future local sessions."
