extends Button
## One compact touch target: the centered logo and its speech bubble.
const DesktopText := preload("res://scenes/DesktopText.gd")
var brand: TextureRect
var bubble := Label.new()
var bubble_rect := Rect2()
var available := false:
	set(value):
		available = value
		disabled = not value
		bubble.visible = value
		mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
		if is_node_ready(): _layout()

func _ready() -> void:
	custom_minimum_size.y = 88
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	brand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brand.custom_minimum_size = Vector2.ZERO
	add_child(brand)
	bubble.text = "Touch to start"
	bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bubble.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	bubble.add_theme_font_size_override("font_size", DesktopText.size(14))
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bubble)
	bubble.minimum_size_changed.connect(_layout)
	resized.connect(_layout)
	get_node("/root/Localization").changed.connect(_layout)
	available = available
	_layout()

func _layout() -> void:
	var logo_width := 96.0 if available and size.x < 480 else 144.0
	brand.size = Vector2(logo_width, logo_width * 58.0 / 144.0)
	brand.position.x = (size.x - brand.size.x) * .5
	var left := brand.get_rect().end.x + 16
	var width := minf(200, maxf(48, size.x - left - 8))
	bubble.size.x = width - 20
	var height := maxf(48, bubble.get_minimum_size().y + 10)
	custom_minimum_size.y = maxf(88, height + 8)
	brand.position.y = (custom_minimum_size.y - brand.size.y) * .5
	bubble_rect = Rect2(Vector2(left, (custom_minimum_size.y - height) * .5), Vector2(width, height))
	bubble.position = bubble_rect.position + Vector2(10, 5)
	bubble.size = bubble_rect.size - Vector2(20, 10)
	accessibility_name = "Graffitty · " + tr("Touch to start") if available else "Graffitty"
	queue_redraw()

func _has_point(point: Vector2) -> bool:
	return available and (brand.get_rect().grow(6).has_point(point) or bubble_rect.grow(8).has_point(point))

func _draw() -> void:
	if not available: return
	var style := StyleBoxFlat.new()
	style.bg_color = Color("34465a") if is_hovered() else Color("293847")
	if is_pressed(): style.bg_color = style.bg_color.darkened(.15)
	style.border_color = preload("res://scenes/UIAccent.gd").ACCENT if has_focus() else Color("58697d")
	style.set_border_width_all(1)
	style.set_corner_radius_all(14)
	draw_style_box(style, bubble_rect)
	var tail := PackedVector2Array([
		bubble_rect.position + Vector2(1, bubble_rect.size.y * .5 - 9),
		bubble_rect.position + Vector2(-12, bubble_rect.size.y * .5),
		bubble_rect.position + Vector2(1, bubble_rect.size.y * .5 + 9),
	])
	draw_colored_polygon(tail, style.bg_color)
	draw_polyline(tail, style.border_color, 1, true)
