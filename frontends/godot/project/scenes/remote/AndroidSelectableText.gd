extends Node
## Android owns selection handles, the contextual toolbar, and clipboard copying.
##
## It shows a SelectableText's text in a native TextView over the Godot view,
## in surface pixels (com.graffitty.ui.NativeSelectableText). The native view
## never scrolls itself: vertical drags come back here and go through the
## shared rubber band, so the text moves like every other list (Apple style,
## not Android's stretch).
var source: Control
var bridge: JavaObject
var last_state: Array = []
## Surface pixels per source pixel.
var _scale := 1.0
var _scrolled := Vector2.INF


func _ready() -> void:
	var runtime = Engine.get_singleton("AndroidRuntime")
	var accent := preload("res://scenes/UIAccent.gd").ACCENT
	bridge = Engine.get_singleton("JavaClassWrapper").wrap("com.graffitty.ui.NativeSelectableText") \
		.NativeSelectableText(runtime.getActivity(), get_instance_id(), _argb(accent))
	source.view.modulate.a = 0


func _process(_delta: float) -> void:
	var transform := surface_transform(source)
	var rect := Rect2i(transform * Rect2(Vector2.ZERO, source.size))
	_scale = maxf(transform.get_scale().y, 0.001)
	var state := [source.is_visible_in_tree(), rect, source.text, float(source.font_size()) * _scale, source.font_color()]
	if state == last_state: return
	last_state = state
	# The text stays clear of the overlay scrollbar Godot draws under it.
	bridge.update(rect.position.x, rect.position.y, rect.size.x, rect.size.y, int(ceilf(source.bar_gutter() * _scale)), state[2], state[3], _argb(state[4]), state[0])
	_scrolled = Vector2.INF


## Draw the text at `offset`, pulled by `stretch`, both in source pixels.
func scroll(offset: float, stretch: float) -> void:
	var at := Vector2(offset, stretch) * _scale
	if at == _scrolled: return
	_scrolled = at
	bridge.scroll(at.x, at.y)


func _native_touch(kind: String, dy: float) -> void:
	source.native_touch(kind, dy / _scale)


func _native_content_height(height: int) -> void:
	source.native_content_height = height / _scale


## From `control`'s pixels to the rendering surface's, through every embedded
## window it sits in and the root's content scale. `get_screen_transform()`
## omits that scale for embedded dialogs, which misplaces the native view.
static func surface_transform(control: Control) -> Transform2D:
	var transform := control.get_global_transform_with_canvas()
	var viewport := control.get_viewport()
	while viewport is Window and (viewport as Window).is_embedded():
		var window := viewport as Window
		transform = Transform2D(0.0, Vector2(window.position)) * window.get_final_transform() * transform
		viewport = window.get_parent().get_viewport()
	return viewport.get_final_transform() * transform


## Java's signed ARGB int.
static func _argb(color: Color) -> int:
	var value := int(color.to_argb32())
	return value - 0x100000000 if value > 0x7fffffff else value


func _exit_tree() -> void:
	if bridge != null: bridge.dispose()
