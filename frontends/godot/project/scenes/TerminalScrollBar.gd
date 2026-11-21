extends VScrollBar
## Native thumb/track interaction plus repeat while an empty track is held.
## The native styles are empty boxes that only size the bar; one shader quad
## paints it (terminal_scroll_bar.gdshader).
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
const INITIAL_DELAY := .35
const REPEAT_DELAY := .08
## Godot's default bar width; the thumb fills it, as the native grabber did.
const WIDTH := 8.0
const MIN_THUMB := 20.0
const HOVER_FADE := .15
var _direction := 0
var _pointer := Vector2.ZERO
var _remaining := 0.0
var _hover := false
var _dragging := false
var _hover_amount := 0.0
var _fade: Tween
var _skin := Control.new()
var _material := ShaderMaterial.new()
## The terminal whose rubber band shortens the thumb against the pulled end,
## as a Mac's does; its binding keeps this current.
var terminal: Node:
	set(value):
		terminal = value
		_follow_stretch()
## Thumb geometry (Rust `scroll_thumb`), shared with every other scrollbar.
var _thumbs: RefCounted = ClassDB.instantiate("ElasticScroller")
## The pull, in rows (this bar's units).
var _stretch := 0.0

func _init() -> void:
	var track := StyleBoxEmpty.new()
	track.content_margin_left = WIDTH * .5
	track.content_margin_right = WIDTH * .5
	var grabber := StyleBoxEmpty.new()
	grabber.content_margin_top = MIN_THUMB * .5
	grabber.content_margin_bottom = MIN_THUMB * .5
	for style in ["scroll", "scroll_focus"]: add_theme_stylebox_override(style, track)
	# Godot's scroll bar minimum ignores its style widths; reserve the painted width.
	custom_minimum_size.x = WIDTH
	for style in ["grabber", "grabber_highlight", "grabber_pressed"]: add_theme_stylebox_override(style, grabber)
	_material.shader = preload("res://scenes/terminal_scroll_bar.gdshader")
	_skin.name = "Skin"
	_skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skin.material = _material
	_skin.draw.connect(func(): _skin.draw_rect(Rect2(Vector2.ZERO, _skin.size), Color.WHITE))
	add_child(_skin)
	_skin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _ready() -> void:
	set_process(false)
	set_process_input(false)
	visibility_changed.connect(func():
		_follow_stretch()
		if not is_visible_in_tree(): _stop_repeat())
	changed.connect(_sync_skin)
	resized.connect(_sync_skin)
	value_changed.connect(_sync_skin.unbind(1))
	mouse_exited.connect(func():
		_hover = false
		_sync_skin())
	_sync_skin()

## Follow the terminal's pull every frame while this bar shows; the scroll
## position alone only updates when rows change.
func _follow_stretch() -> void:
	if not is_inside_tree(): return
	var frame := get_tree().process_frame
	var follow := is_instance_valid(terminal) and terminal.has_method("get_scroll_stretch") and is_visible_in_tree()
	if follow and not frame.is_connected(_read_stretch): frame.connect(_read_stretch)
	elif not follow and frame.is_connected(_read_stretch): frame.disconnect(_read_stretch)
	if not follow: _set_stretch(0.0)


func _read_stretch() -> void:
	if not is_instance_valid(terminal):
		_follow_stretch()
		return
	var height: float = terminal.size.y
	_set_stretch(float(terminal.get_scroll_stretch()) / height * page if height > 0.0 else 0.0)


func _set_stretch(rows: float) -> void:
	if is_equal_approx(rows, _stretch): return
	_stretch = rows
	_sync_skin()


## Thumb start and length along the bar, as scene/gui/scroll_bar.cpp lays it out.
func _thumb_span() -> Vector2:
	var decrement := float(get_theme_icon("decrement").get_height())
	var increment := float(get_theme_icon("increment").get_height())
	var style := get_theme_stylebox("scroll")
	var minimum := get_theme_stylebox("grabber").get_minimum_size().y
	var track := maxf(0.0, size.y - style.get_minimum_size().y - decrement - increment)
	var range := max_value - min_value
	if range <= 0.0: return Vector2(decrement, size.y - decrement - increment)
	# At rest this is Godot's own layout, so the drawn thumb is the one grabbed.
	var span: Vector2 = _thumbs.thumb(track, value - min_value, range - page, page, _stretch, minimum)
	return Vector2(decrement + style.get_margin(SIDE_TOP) + span.x, span.y)

func _sync_skin() -> void:
	var span := _thumb_span()
	RenderUpdates.uniform(_material, &"extent", size)
	RenderUpdates.uniform(_material, &"thumb", span)
	RenderUpdates.uniform(_material, &"pressed", 1.0 if _dragging else 0.0)
	# The thumb widens and the track fades in, as macOS overlay scrollers do.
	var target := 1.0 if _hover or _dragging else 0.0
	if not is_equal_approx(target, _hover_amount) and (_fade == null or not _fade.is_running() or _fade.get_meta("target", -1.0) != target):
		if _fade != null: _fade.kill()
		if is_inside_tree():
			_fade = create_tween()
			_fade.set_meta("target", target)
			_fade.tween_method(_set_hover_amount, _hover_amount, target, HOVER_FADE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		else:
			_set_hover_amount(target)
	_skin.queue_redraw()

func _set_hover_amount(amount: float) -> void:
	_hover_amount = amount
	RenderUpdates.uniform(_material, &"hover", amount)
	_skin.queue_redraw()

func _stop_repeat() -> void:
	_direction = 0
	set_process(false)
	set_process_input(false)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_stop_repeat()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_stop_repeat()
	elif what == NOTIFICATION_ENTER_TREE:
		_follow_stretch.call_deferred()
	elif what == NOTIFICATION_EXIT_TREE and get_tree().process_frame.is_connected(_read_stretch):
		get_tree().process_frame.disconnect(_read_stretch)

func _track_direction(point: Vector2) -> int:
	if not Rect2(Vector2.ZERO, size).has_point(point) or max_value <= min_value + page:
		return 0
	var decrement := float(get_theme_icon("decrement").get_height())
	var increment := float(get_theme_icon("increment").get_height())
	if point.y < decrement or point.y >= size.y - increment: return 0
	var span := _thumb_span()
	return -1 if point.y < span.x else (1 if point.y >= span.x + span.y else 0)

func _on_thumb(point: Vector2) -> bool:
	var span := _thumb_span()
	return Rect2(0.0, span.x, size.x, span.y).has_point(point)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pointer = event.position
		var hover := _on_thumb(_pointer)
		if hover != _hover:
			_hover = hover
			_sync_skin()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_stop_repeat()
		var dragging: bool = event.pressed and _on_thumb(event.position)
		if dragging != _dragging:
			_dragging = dragging
			_sync_skin()
		if event.pressed:
			_pointer = event.position
			_direction = _track_direction(_pointer)
			_remaining = INITIAL_DELAY
			set_process(_direction != 0)
			set_process_input(_direction != 0)

func _process(delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(delta)
	preload("res://graffitty/frame_profile.gd").add("TerminalScrollBar", Time.get_ticks_usec() - profiled_started)


func _process_body(delta: float) -> void:
	_remaining -= delta
	if _remaining > 0.0: return
	_remaining = REPEAT_DELAY
	# Stop paging once the thumb reaches the pointer; never reverse direction.
	if _track_direction(_pointer) != _direction: return
	value += _direction * (page if page > 0.0 else (max_value - min_value) / 16.0)
	scrolling.emit()

func mount_workspace(view: Control, world: Node) -> void:
	name = "WorldScrollBar"
	z_index = 20
	add_to_group(&"touch_chrome")
	view.add_child(self)
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var layout := _layout_workspace.bind(view)
	view.tab_bar.item_rect_changed.connect(layout)
	view.get_window().titlebar_changed.connect(layout)
	view.tab_bar.visibility_changed.connect(layout)
	view.resized.connect(layout)
	minimum_size_changed.connect(layout)
	# Chrome lives outside the world viewport but shares the world's lifetime.
	# Object.free must be an explicit Callable in exported bytecode.
	#
	# Free now so a replacement world can reuse the scrollbar's name in the same
	# frame.
	world.tree_exiting.connect(Callable(self, "free"))
	layout.call()

func _layout_workspace(view: Control) -> void:
	# Linux's client-side resize strip receives input above workspace controls.
	# Keep the thumb and track inside it so they remain clickable.
	var window := get_window()
	var frame: Node = window.get_meta(&"graffitty_window_frame") if window.has_meta(&"graffitty_window_frame") else null
	var border: float = frame.resize_border() if frame != null else 0.0
	offset_left = -get_combined_minimum_size().x - border
	offset_right = -border
	offset_top = view._foreground_rect().position.y
	offset_bottom = -border
