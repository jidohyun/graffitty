extends PanelContainer
## Native 2D card inspired by nvim-notify's colored border/title hierarchy.
const DesktopText := preload("res://scenes/DesktopText.gd")
signal dismissed
const COLORS := {"info": Color("7aa2f7"), "success": Color("9ece6a"), "warning": Color("e0af68"), "error": Color("f7768e")}
var entry: Dictionary
var remaining := 0.0
var leaving := false
var animation: Tween
var motion: Tween
## History text selects like a terminal; a toast's text is not selectable.
var body: Control
var title := Label.new()
var is_history := false

class Mark extends Control:
	var tint := Color.WHITE
	var level := "info"
	func _draw() -> void:
		var center := size * 0.5
		draw_arc(center, 8, 0, TAU, 32, tint, 1.7, true)
		if level == "success":
			draw_polyline(PackedVector2Array([center + Vector2(-4, 0), center + Vector2(-1, 3), center + Vector2(4, -3)]), tint, 1.7, true)
		else:
			draw_line(center + Vector2(0, -1), center + Vector2(0, 4), tint, 1.7, true)
			draw_circle(center + Vector2(0, -4), 1, tint)

func configure(value: Dictionary, history := false) -> void:
	entry = value
	is_history = history
	remaining = float(value.timeout)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var accent: Color = COLORS.get(value.level, COLORS.info)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("1a1e29")
	style.border_color = Color(accent, 0.55)
	style.set_border_width_all(1)
	style.border_width_left = 3
	style.set_corner_radius_all(9)
	style.set_content_margin_all(14)
	style.shadow_color = Color(0, 0, 0, 0.22)
	style.shadow_size = 10
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	add_child(column)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 10)
	column.add_child(heading)
	var icon := Mark.new()
	icon.tint = accent
	icon.level = value.level
	icon.custom_minimum_size = Vector2(22, 22)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	heading.add_child(icon)
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.add_theme_color_override("font_color", accent)
	title.add_theme_font_size_override("font_size", DesktopText.size(17))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	heading.add_child(title)
	if history:
		var stamp := Label.new()
		stamp.text = str(value.time).substr(11)
		stamp.add_theme_color_override("font_color", Color("9aa5bd"))
		stamp.add_theme_font_size_override("font_size", DesktopText.size(12))
		heading.add_child(stamp)
	else:
		var close := Button.new()
		close.text = "×"
		close.accessibility_name = tr("Dismiss")
		close.flat = true
		close.focus_mode = Control.FOCUS_NONE
		close.custom_minimum_size = Vector2(44, 44) if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else Vector2(30, 30)
		close.pressed.connect(func(): dismissed.emit())
		heading.add_child(close)
	if history:
		# The history list scrolls; the text grows to fit inside it.
		body = preload("res://scenes/SelectableText.gd").new()
		body.fit_content = true
		body.set_font_color(Color("cdd6ed"))
		body.view.add_theme_font_size_override("font_size", DesktopText.size(15))
	else:
		var label := RichTextLabel.new()
		label.bbcode_enabled = false
		label.fit_content = true
		label.scroll_active = false
		label.add_theme_color_override("default_color", Color("cdd6ed"))
		label.add_theme_font_size_override("normal_font_size", DesktopText.size(15))
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		body = label
	body.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	column.add_child(body)
	_refresh_text()

func _refresh_text() -> void:
	var sources: Dictionary = entry.get("localization", {})
	title.text = tr(str(sources.title)) if sources.has("title") else str(entry.title)
	var content := str(entry.body)
	if sources.has("body"):
		content = tr(str(sources.body))
		var args: Array = sources.get("args", [])
		if not args.is_empty(): content = content % args
	body.text = content if is_history or content.length() <= 500 else content.left(500) + "…"

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and not entry.is_empty(): _refresh_text()
