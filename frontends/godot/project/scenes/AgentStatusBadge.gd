extends BoxContainer
const DesktopText := preload("res://scenes/DesktopText.gd")
const SPIN_PERIOD_SECONDS := 2.0

## A shared monotonic phase survives row replacement and layout changes.
static func spinner_angle(seconds: float) -> float:
	return fmod(seconds, SPIN_PERIOD_SECONDS) * TAU / SPIN_PERIOD_SECONDS
## Provider identity plus status. Asset sources: assets/icons/SOURCES.md and lucide/SOURCES.md.
## The application owns cached textures, as it does for pane icons.
static func _textures() -> Dictionary:
	var cache: Dictionary = preload("res://scenes/PaneIcons.gd")._cache()
	var key := "agentstatusbadge_textures"
	if not cache.has(key): cache[key] = {}
	return cache[key]

var logo := TextureRect.new()
var _offline_material := ShaderMaterial.new()
var provider_label := Label.new()
var node_symbol := Label.new()
var status_icon := TextureRect.new()
var status_slot := Control.new()
var spinning := false
var status_name := ""
## Server-recorded status changes; the last entry starts the current status.
var status_history: Array = []:
	set(value):
		status_history = value
		_update_duration()
## How long the agent has been in its status, as herdr-app's agents mod shows it
## (defaults/mods/agents/main.js, Apache-2.0): whole minutes, refreshed every 30 s.
var duration_label := Label.new()
var _since := -1.0
var _clock := Timer.new()
const DURATION_REFRESH := 30.0

static func icon(file: String) -> Texture2D:
	var textures := _textures()
	if not textures.has(file):
		var path := "res://assets/icons/" + ("" if file in ["codex.png", "claude-code.svg", "opencode.svg", "pi.svg", "python.svg", "chromium.svg"] else "lucide/") + file
		# Standard exports ship imported textures rather than raw SVG sources.
		if ResourceLoader.exists(path, "Texture2D"):
			textures[file] = load(path) as Texture2D
		else:
			# Custom runtime packs also support unimported source assets.
			var bytes := FileAccess.get_file_as_bytes(path)
			textures[file] = null
			if not bytes.is_empty():
				var image := Image.new()
				var error := image.load_png_from_buffer(bytes) if file.ends_with(".png") else image.load_svg_from_buffer(bytes)
				if error == OK and not image.is_empty():
					textures[file] = ImageTexture.create_from_image(image)
	return textures[file]

func _init() -> void:
	_offline_material.shader = preload("res://scenes/offline_icon.gdshader")
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 6)
	for item in [logo, status_icon]:
		item.custom_minimum_size = Vector2(20, 20)
		item.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		item.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		item.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	provider_label.add_theme_font_size_override("font_size", DesktopText.size(12))
	provider_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(logo)
	add_child(node_symbol)
	node_symbol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(provider_label)
	# Containers reset transforms on their direct children during layout. Keep
	# the rotating texture inside a stable slot so status refreshes cannot snap it.
	status_slot.custom_minimum_size = Vector2(20, 20)
	status_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_slot)
	status_slot.add_child(status_icon)
	status_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	status_icon.resized.connect(func(): status_icon.pivot_offset = status_icon.size * .5)
	duration_label.add_theme_font_size_override("font_size", DesktopText.size(11))
	duration_label.add_theme_color_override("font_color", Color("8b93a1"))
	duration_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	duration_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	duration_label.hide()
	add_child(duration_label)
	_clock.wait_time = DURATION_REFRESH
	_clock.autostart = true
	_clock.timeout.connect(_refresh_duration)
	add_child(_clock)
	set_process(false)

func set_agent(provider: String, status: String, manifest: Dictionary = {}) -> void:
	visible = not manifest.is_empty() or (not provider.is_empty() and provider != "shell")
	if not visible:
		spinning = false
		status_name = ""
		set_process(false)
		return
	logo.visible = provider.to_lower() in ["codex", "claude", "opencode", "pi"]
	if logo.visible:
		logo.texture = icon({"claude":"claude-code.svg", "codex":"codex.png", "opencode":"opencode.svg", "pi":"pi.svg"}[provider.to_lower()])
	provider_label.visible = not logo.visible
	provider_label.text = provider.capitalize() if not provider.is_empty() else tr("Node")
	var display_name: String = manifest.get("name", "")
	if not logo.visible and not display_name.is_empty():
		provider_label.text = display_name
		provider_label.visible = true
	var spec: Dictionary = preload("res://scenes/NodeIcon.gd").validate(manifest.get("icon", {})).get("icon", {})
	node_symbol.text = spec.get("text", "")
	node_symbol.visible = not node_symbol.text.is_empty()
	node_symbol.add_theme_font_override("font", preload("res://scenes/NodeIcon.gd").font(spec))
	if spec.has("svg"):
		logo.texture = preload("res://scenes/NodeIcon.gd").texture(spec)
		logo.visible = logo.texture != null
	logo.material = _offline_material if status == "offline" else null
	node_symbol.material = _offline_material if status == "offline" else null
	provider_label.modulate.a = 0.55 if status == "offline" else 1.0
	tooltip_text = "%s · %s" % [provider_label.text, status_label(status)]
	var changed := status != status_name
	status_name = status
	_update_duration()
	if not changed:
		set_process(spinning)
		return
	spinning = status in ["running", "busy"]
	var file := "circle-question-mark.svg"
	var tint := Color("aab3c2")
	match status:
		"running", "busy": file = "loader-circle.svg"; tint = Color("8ab4f8")
		"idle": file = "circle-check.svg"; tint = Color("89ddbd")
		"waiting", "blocked": file = "circle-pause.svg"; tint = Color("ffd078")
		"offline": file = "circle-x.svg"; tint = Color("a0a0a0")
		"error", "failed": file = "circle-alert.svg"; tint = Color("ff8080")
	status_icon.texture = icon(file)
	status_icon.modulate = tint
	status_icon.rotation = spinner_angle(Time.get_ticks_usec() / 1_000_000.0) if spinning else 0
	set_process(spinning)

func _process(_delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_delta)
	preload("res://graffitty/frame_profile.gd").add("AgentStatusBadge", Time.get_ticks_usec() - profiled_started)


func _process_body(_delta: float) -> void:
	if is_visible_in_tree():
		status_icon.pivot_offset = status_icon.size * 0.5
		status_icon.rotation = spinner_angle(Time.get_ticks_usec() / 1_000_000.0)


## Unix seconds for a server RFC 3339 timestamp, or -1 when it is not one.
static func unix_time(timestamp: String) -> float:
	# Godot's ISO parser ignores timezone offsets. Normalize to UTC here.
	var pattern := RegEx.new()
	pattern.compile("^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(\\.\\d+)?(Z|([+-])(\\d{2}):(\\d{2}))$")
	var found := pattern.search(timestamp)
	if found == null: return -1.0
	var source_minutes := (int(found.get_string(5)) * 60 + int(found.get_string(6))) * (-1 if found.get_string(4) == "-" else 1)
	var fraction := float("0" + found.get_string(2)) if not found.get_string(2).is_empty() else 0.0
	return Time.get_unix_time_from_datetime_string(found.get_string(1)) - source_minutes * 60 + fraction


static func local_timestamp(timestamp: String, offset_minutes: int) -> String:
	var utc := unix_time(timestamp)
	if utc < 0.0: return ""
	return Time.get_datetime_string_from_unix_time(int(utc) + offset_minutes * 60, true)


## herdr's duration(): whole minutes, then hours, then days.
static func elapsed(seconds: float) -> String:
	# A remote server's clock can run ahead of this client's; never show negative.
	var minutes := floori(maxf(seconds, 0.0) / 60.0)
	if minutes < 1: return "<1m"
	if minutes < 60: return "%dm" % minutes
	var hours := minutes / 60
	if hours < 24: return "%dh" % hours
	# Beyond herdr's days: checkpoints can be weeks, months or years old.
	var days := hours / 24
	if days < 14: return "%dd" % days
	if days < 61: return "%dw" % (days / 7)
	if days < 365: return "%dmo" % (days / 30)
	return "%dy" % (days / 365)


## When the current status began: the last history entry, if it is that status.
## Anything else means history does not describe the current status; show nothing.
static func status_since(history: Array, status: String) -> float:
	if history.is_empty() or status.is_empty(): return -1.0
	var last = history[history.size() - 1]
	if not last is Dictionary or str(last.get("status", "")) != status: return -1.0
	return unix_time(str(last.get("at", "")))


func _update_duration() -> void:
	_since = status_since(status_history, status_name)
	_refresh_duration()


func _refresh_duration() -> void:
	duration_label.visible = _since >= 0.0
	if duration_label.visible:
		duration_label.text = elapsed(Time.get_unix_time_from_system() - _since)


static func status_label(status: String) -> String:
	match status:
		"busy", "running": return TranslationServer.translate("Running")
		"idle": return TranslationServer.translate("Done")
		_: return TranslationServer.translate(status.capitalize())


func _get_tooltip(_at_position: Vector2) -> String:
	if not visible: return ""
	return history_tooltip(tooltip_text, status_history)


## The hover text: identity and status, then the server's recent status
## changes newest first, in the client's local time.
static func history_tooltip(title: String, history: Array) -> String:
	if history.is_empty(): return title
	var offset := int(Time.get_time_zone_from_system().bias)
	var zone := "UTC%s%02d:%02d" % ["+" if offset >= 0 else "-", absi(offset) / 60, absi(offset) % 60]
	var lines := PackedStringArray([title, TranslationServer.translate("Recent status changes · Local time (%s)") % zone])
	for index in range(history.size() - 1, -1, -1):
		var entry: Dictionary = history[index]
		var timestamp := local_timestamp(str(entry.get("at", "")), offset)
		if timestamp.is_empty(): continue
		var identity := str(entry.get("provider", "")).capitalize()
		lines.append("%s · %s%s" % [timestamp, status_label(str(entry.get("status", "unknown"))), " (%s)" % identity if not identity.is_empty() else ""])
	return "\n".join(lines)
