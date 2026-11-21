extends Control
## Redraws a ScrollBar while its content is pulled past an end: the thumb
## shortens against that end, as on a Mac (Rust `scroll_thumb`). At rest the
## bar draws itself, untouched.

var bar: ScrollBar
var scroller: RefCounted
## The pull in the bar's own units (its value/page units).
var stretch := 0.0


static func attach(to: ScrollBar, elastic: RefCounted) -> Control:
	var skin := new()
	skin.bar = to
	skin.scroller = elastic
	skin.name = "ElasticBarSkin"
	skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	to.add_child(skin, false, Node.INTERNAL_MODE_BACK)
	skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	skin.hide()
	return skin


func set_stretch(value: float) -> void:
	if value == stretch: return
	stretch = value
	var pulled := value != 0.0
	visible = pulled
	# The bar's own drawing hides while this one stands in for it.
	bar.self_modulate.a = 0.0 if pulled else 1.0
	queue_redraw()


func _draw() -> void:
	var vertical := bar is VScrollBar
	var track_style := bar.get_theme_stylebox("scroll")
	var grabber := bar.get_theme_stylebox("grabber")
	draw_style_box(track_style, Rect2(Vector2.ZERO, size))
	var start_margin := track_style.get_margin(SIDE_TOP if vertical else SIDE_LEFT)
	var extent := size.y if vertical else size.x
	var track := extent - (track_style.get_minimum_size().y if vertical else track_style.get_minimum_size().x)
	var minimum := grabber.get_minimum_size().y if vertical else grabber.get_minimum_size().x
	var span: Vector2 = scroller.thumb(track, bar.value - bar.min_value, bar.max_value - bar.min_value - bar.page, bar.page, stretch, minimum)
	var rect := Rect2(0, start_margin + span.x, size.x, span.y) if vertical else Rect2(start_margin + span.x, 0, span.y, size.y)
	draw_style_box(grabber, rect)
