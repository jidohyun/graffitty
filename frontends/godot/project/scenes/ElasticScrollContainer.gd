extends ScrollContainer
## A ScrollContainer that moves like a terminal.
##
## Trackpad pans and finger drags scroll by the distance travelled. A flick
## glides on. Past either end the content stretches with the terminal's
## rubber band and springs back. Wheels keep their steps and never stretch.
##
## Rust (`ElasticScroller`) owns the motion; this adapter feeds it events and
## draws its offset and pull.

## Drag distance before a finger scrolls instead of pressing what it is on.
const DRAG_SLOP := 12.0
var elastic: RefCounted = ClassDB.instantiate("ElasticScroller")
## The content shift drawn for the rubber band, in pixels along the axis.
var stretch := 0.0
var _finger := -1
var _finger_origin := Vector2.ZERO
var _finger_dragging := false
## Finger handling is off for containers whose owner routes touches itself.
var handles_touch := true
## A control with another drag action can keep a gesture it already owns.
var begin_touch_drag: Callable
var _bar_skin: Control


# Subclasses replace _ready without calling it; set up here instead.
func _init() -> void:
	sort_children.connect(_apply_stretch)
	visibility_changed.connect(func():
		if not is_visible_in_tree() and elastic.is_active(): stop_scrolling())


## A strip that only scrolls sideways stretches sideways.
func _bar() -> ScrollBar:
	elastic.horizontal = vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED and horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED
	return get_h_scroll_bar() if elastic.horizontal else get_v_scroll_bar()


func scroll_offset() -> float:
	return _bar().value


func _range() -> Vector2:
	var bar := _bar()
	return Vector2(maxf(bar.max_value - bar.page, 0.0), bar.page if bar.page > 0.0 else (size.x if elastic.horizontal else size.y))


func _set_offset(offset: float) -> void:
	var bar := _bar()
	if not is_equal_approx(bar.value, offset): bar.value = offset
	var pull: float = elastic.get_stretch()
	if not is_equal_approx(pull, stretch):
		stretch = pull
		queue_sort()
		# The scrollbar thumb shortens against the pulled end.
		if _bar_skin == null or _bar_skin.bar != bar:
			_bar_skin = preload("res://scenes/ElasticBarSkin.gd").attach(bar, elastic)
		_bar_skin.set_stretch(pull)
	if elastic.is_active(): _animate(true)


func _apply_stretch() -> void:
	if stretch == 0.0: return
	for child in get_children():
		if child is Control and not child is ScrollBar:
			if elastic.horizontal: child.position.x -= stretch
			else: child.position.y -= stretch


## A sideways strip also scrolls with vertical swipes.
var folds_axes := false


## Scroll by a trackpad or touch pan. Returns whether it applied here.
func elastic_pan(event: InputEventPanGesture) -> bool:
	_bar()
	var along: float = event.delta.x if elastic.horizontal else event.delta.y
	var across: float = event.delta.y if elastic.horizontal else event.delta.x
	if folds_axes:
		along += across
	# A mostly perpendicular pan belongs to whatever scrolls that way.
	elif absf(across) > absf(along) and not elastic.is_active(): return false
	var limits := _range()
	_set_offset(elastic.pan(event, along, scroll_offset(), limits.x, limits.y))
	return true


func elastic_touch_begin() -> void:
	elastic.touch_begin()
	_animate(true)


## `relative` is the finger's movement in this container's pixels.
func elastic_touch_move(relative: Vector2) -> void:
	var limits := _range()
	_set_offset(elastic.touch_move(relative, scroll_offset(), limits.x, limits.y))


## Without `fling` the content stops where the drag ended, as for a mouse.
func elastic_touch_end(fling := true) -> void:
	var limits := _range()
	elastic.touch_end(scroll_offset(), limits.x, limits.y, fling)
	_animate(true)


## Whether a lifted finger's glide is still moving the content.
func gliding() -> bool:
	return elastic.is_flinging()


func stop_scrolling() -> void:
	elastic.stop()
	_finger = -1
	_finger_dragging = false
	_set_offset(scroll_offset())
	_animate(false)


## Frames run from the tree, not `_process`, which subclasses own.
func _animate(on: bool) -> void:
	if not is_inside_tree(): return
	var frame := get_tree().process_frame
	if on and not frame.is_connected(_advance): frame.connect(_advance)
	elif not on and frame.is_connected(_advance): frame.disconnect(_advance)


func _advance() -> void:
	var limits := _range()
	_set_offset(elastic.advance(scroll_offset(), limits.x, limits.y))
	if not elastic.is_active(): _animate(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE: _animate(false)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if elastic_pan(event): accept_event()
		return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		# A wheel ends any glide or pull; the native step scrolls.
		if elastic.is_active(): stop_scrolling()
		return
	# Godot emulates a mouse for each finger. Fingers scroll through `_input`;
	# the native drag must not scroll a second time.
	if handles_touch and event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		accept_event()


## Fingers are followed here rather than in `_gui_input`, so a drag that
## starts on a button still scrolls; the button's press is then cancelled.
func _input(event: InputEvent) -> void:
	if not handles_touch: return
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1 and _owns_point(event.position):
			_finger = event.index
			_finger_origin = event.position
			_finger_dragging = false
			# A finger that lands on a glide stops it and may then drag.
			elastic_touch_begin()
		elif event.pressed and _finger != -1:
			# A second finger (a pinch, say) ends the drag without a glide.
			_finger = -1
			_finger_dragging = false
			elastic_touch_end(false)
		elif not event.pressed and event.index == _finger:
			# Others still see the lift; the drag already cancelled any press.
			_finger = -1
			_finger_dragging = false
			elastic_touch_end(not event.canceled)
		return
	if _finger == -1: return
	if event is InputEventScreenDrag and event.index == _finger:
		var relative: Vector2 = event.relative
		if not _finger_dragging:
			var travel: Vector2 = event.position - _finger_origin
			var slop := maxf(DRAG_SLOP, scroll_deadzone)
			if travel.length() <= slop: return
			if begin_touch_drag.is_valid() and not begin_touch_drag.call(travel): return
			_finger_dragging = true
			# Start from the slop edge so crossing it does not jump.
			relative = travel - travel.normalized() * slop
			propagate_notification(Control.NOTIFICATION_SCROLL_BEGIN)
			var focus := get_viewport().gui_get_focus_owner()
			if focus != null and is_ancestor_of(focus): focus.release_focus()
		elastic_touch_move(get_global_transform_with_canvas().affine_inverse().basis_xform(relative))
		get_viewport().set_input_as_handled()
	elif _finger_dragging and event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()


## A finger at `point` (viewport pixels) lands on this list, not on
## something drawn over it.
func _owns_point(point: Vector2) -> bool:
	if not is_visible_in_tree() or not Rect2(Vector2.ZERO, size).has_point(get_global_transform_with_canvas().affine_inverse() * point): return false
	# Godot hovers the control under a finger through its emulated mouse,
	# which arrives first; without one (no emulation), trust the rect.
	var hovered := get_viewport().gui_get_hovered_control()
	return hovered == null or hovered == self or is_ancestor_of(hovered)
