extends CanvasLayer
## Touch buttons that float above the workspace. Recording can slide to cancel
## without changing the saved anchor. Double-tap, hold, then drag repositions
## any control; keyboard and text size also support hold-to-drag.
##
## A button's spot is saved against a reference canvas. Bounds changes
## translate nearby controls together without compressing their spacing or
## rewriting saved preferences.

## Overlay controls in this group stay directly tappable; MobilePointer does
## not turn touches on them into terminal input.
const Layout := preload("res://scenes/input/FloatingButtonLayout.gd")
const CHROME := &"touch_chrome"
const SIZE := Vector2(52, 52)
const MARGIN := 8.0
## A hold must stay within this distance until dragging unlocks.
const SLOP := 16.0
const HOLD_MS := 350
const DOUBLE_TAP_MS := 400

var preferences_path := ""
const Profiles := preload("res://scenes/input/FloatingLayoutProfile.gd")
var display_size_provider := Callable()
var _profile_path := ""
## Height covered by the soft keyboard and its key bar.
var bottom_inset := 0.0
var top_inset := 0.0
var entries: Dictionary = {}
var _gesture: Dictionary = {}
var _returns: Dictionary = {}
var _last_tap: Dictionary = {}
var movement_allowed := Callable()
var reference_size := Vector2.ZERO
var targets := {}
var animate_layout := true
var _pointer_capture := preload("res://scenes/input/PointerHoverCapture.gd").new()
## Per button: an invisible, unfocusable, always-on-top embedded window over
## it.
##
## Godot gives a press inside an embedded window (a floating panel, a dialog)
## to that window and focuses it, whatever the canvas layers.
##
## An unfocusable window on top takes that press instead and clears panel
## focus without taking it, so the touch reaches the button and typing stays
## where it was.
var _catchers := {}


func _init() -> void:
	name = "FloatingButtons"
	# The transcript may cover much of a narrow screen; Stop stays tappable.
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.FLOATING_CONTROLS
	add_child(_pointer_capture)
	preferences_path = preload("res://graffitty/paths.gd").stdpath("config").path_join("touch-buttons.conf")


func _ready() -> void:
	# Every floating surface consumes the keyboard layout owner's usable bounds.
	add_to_group(&"floating_controls")
	get_viewport().size_changed.connect(layout)
	# Hiding the whole layer (another screen) hides the catchers with it.
	visibility_changed.connect(func(): set_process(true))
	for id in entries: _add_catcher(id)
	set_process(true)
	layout()


## Adopts `button`. `press` runs when a touch lands on it, `release` when the
## touch lifts without dragging, and `cancel` if the system interrupts it.
## Only controls without a hold action opt into `hold_to_move`.
func add(id: String, button: Button, anchor: Vector2, press := Callable(), release := Callable(), hold_to_move := false, cancel := Callable(), drag := Callable()) -> void:
	_stop_return(id)
	if button.get_parent() != null: button.get_parent().remove_child(button)
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = button.custom_minimum_size.max(SIZE)
	button.size = button.custom_minimum_size
	button.pivot_offset = button.size / 2
	button.add_to_group(CHROME)
	_style(button)
	button.gui_input.connect(_button_input.bind(id))
	add_child(button)
	_register(id, button, anchor, press, release, hold_to_move, cancel, drag)


## Share hold timing, touch ownership, haptics and saved positioning with an
## externally owned surface. Its handles can have distinct release actions.
func add_surface(id: String, surface: Control, anchor: Vector2, handles: Dictionary) -> void:
	for handle in handles:
		handle.gui_input.connect(_surface_input.bind(id, handle, handles[handle]))
	_register(id, surface, anchor, Callable(), Callable(), true, Callable(), Callable())
	# Wide surfaces must stay within bounds even while held at an edge.
	entries[id]["scale_feedback"] = false


func _surface_input(event: InputEvent, id: String, handle: Control, release: Callable) -> void:
	_button_input(event, id, handle)
	if _gesture.get("id") == id and not _gesture.has("release"):
		_gesture["release"] = release


func _register(id: String, button: Control, anchor: Vector2, press: Callable, release: Callable, hold_to_move: bool, cancel: Callable, drag: Callable) -> void:
	button.visibility_changed.connect(layout)
	_sync_profile()
	var default_anchor := anchor
	var saved := ConfigFile.new()
	if reference_size == Vector2.ZERO and is_inside_tree():
		reference_size = get_viewport().get_visible_rect().size
	if saved.load(_profile_path) == OK:
		reference_size = saved.get_value("layout", "reference_size", reference_size)
		var stored: Variant = saved.get_value("anchors", id, anchor)
		if stored is Vector2: anchor = stored.clamp(Vector2.ZERO, Vector2.ONE)
	entries[id] = {"button": button, "anchor": anchor, "default_anchor": default_anchor, "press": press, "release": release, "hold_to_move": hold_to_move, "cancel": cancel, "drag": drag}
	_add_catcher(id)
	_save(id, anchor)
	layout()
	button.position = destination(id)


func _add_catcher(id: String) -> void:
	if _catchers.has(id) or not is_inside_tree() or not get_viewport().gui_embed_subwindows: return
	var catcher := Window.new()
	catcher.name = "FloatingCatcher_" + id
	catcher.borderless = true
	catcher.transparent = true
	catcher.transparent_bg = true
	catcher.always_on_top = true
	catcher.unfocusable = true
	catcher.wrap_controls = false
	catcher.min_size = Vector2i.ONE
	catcher.visible = false
	# Real mouse input lands here too (desktop touch mode); hand it to the button.
	var area := Control.new()
	area.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	area.gui_input.connect(_catcher_input.bind(id, catcher))
	catcher.add_child(area)
	add_child(catcher)
	_catchers[id] = catcher
	_sync_catcher(id)


func _catcher_input(event: InputEvent, id: String, catcher: Window) -> void:
	# Touches never reach unfocusable windows; Android's emulated mouse events
	# are ignored by the button anyway. Only a real pointer needs forwarding.
	if not (event is InputEventMouse) or event.device == -1 or not entries.has(id): return
	var button: Control = entries[id].button
	var forwarded: InputEventMouse = event.duplicate()
	forwarded.position = button.get_global_transform().affine_inverse() * (Vector2(catcher.position) + event.position)
	_button_input(forwarded, id)


## Keep each catcher exactly over its visible button, following animation.
func _sync_catcher(id: String) -> void:
	var catcher: Window = _catchers.get(id)
	if catcher == null: return
	var entry: Dictionary = entries.get(id, {})
	var button: Control = entry.get("button")
	var shown: bool = visible and is_instance_valid(button) and button.is_visible_in_tree()
	if not shown:
		if catcher.visible: catcher.hide()
		return
	var rect := button.get_global_rect()
	var position := Vector2i(rect.position.floor())
	var extent := Vector2i((rect.end.ceil() - rect.position.floor())).max(Vector2i.ONE)
	if catcher.position != position: catcher.position = position
	if catcher.size != extent: catcher.size = extent
	if not catcher.visible: catcher.show()


func can_reposition() -> bool:
	return not movement_allowed.is_valid() or movement_allowed.call()


func is_repositioning() -> bool:
	return _gesture.get("dragging", false)


func cancel_gesture() -> void:
	_last_tap = {}
	_finish(true)


func set_bottom_inset(value: float) -> void:
	if is_equal_approx(value, bottom_inset): return
	bottom_inset = value
	layout()


## The free area: the window above the keyboard, inside a small margin.
func area() -> Rect2:
	var view := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2.ZERO
	return Rect2(Vector2(MARGIN, MARGIN + top_inset), (view - Vector2(2 * MARGIN, 2 * MARGIN + bottom_inset + top_inset)).max(Vector2.ZERO))


func _homes(include_hidden := false) -> Dictionary:
	var homes := {}
	for id in entries:
		var entry: Dictionary = entries[id]
		if not is_instance_valid(entry.button) or (not include_hidden and not entry.button.visible): continue
		homes[id] = Rect2(Vector2.ONE * MARGIN + (reference_size - Vector2.ONE * (2 * MARGIN) - entry.button.size).max(Vector2.ZERO) * entry.anchor, entry.button.size)
	return homes


func _save_position(id: String, position: Vector2) -> void:
	# Rebase deliberate moves to the current full canvas, not the obstructed
	# bounds. This also permits moving between edges after a window expansion.
	var canvas := get_viewport().get_visible_rect().size
	var positions := Layout.solve(_homes(true), reference_size, canvas, Rect2(Vector2.ONE * MARGIN, canvas - Vector2.ONE * (2 * MARGIN)))
	positions[id] = position
	reference_size = canvas
	for key in positions:
		var span: Vector2 = (canvas - Vector2.ONE * (2 * MARGIN) - entries[key].button.size).max(Vector2.ONE)
		entries[key].anchor = ((positions[key] - Vector2.ONE * MARGIN) / span).clamp(Vector2.ZERO, Vector2.ONE)
		_save(key, entries[key].anchor)


func destination(id: String) -> Vector2:
	return targets.get(id, entries[id].button.position)


func layout() -> void:
	if not is_inside_tree(): return
	var changed_profile := _sync_profile()
	set_process(true)
	var canvas := get_viewport().get_visible_rect().size
	if reference_size == Vector2.ZERO: reference_size = canvas
	targets = Layout.solve(_homes(), reference_size, canvas, area())
	var current := {}
	for id in targets:
		current[id] = entries[id].button.get_rect()
	# Correct newly obstructed groups together before easing toward preferences.
	# Independently clamping buttons here would briefly collapse their spacing.
	var safe := Layout.solve(current, canvas, canvas, area())
	for id in targets:
		if _gesture.get("id") == id: continue
		_stop_return(id)
		var button: Control = entries[id].button
		button.scale = Vector2.ONE
		button.position = safe[id] if animate_layout and not changed_profile else targets[id]


func _stop_return(id: String) -> void:
	if not _returns.has(id): return
	_returns[id].tween.kill()
	_returns.erase(id)


func _settle(id: String) -> void:
	_stop_return(id)
	var button: Control = entries[id].button
	var destination := destination(id)
	# One small overshoot, clamped so a button at a screen edge stays visible.
	var travel := destination - button.position
	var free := area()
	var overshoot := (destination + (travel * .12).limit_length(8)).clamp(free.position, (free.end - button.size).max(free.position))
	var tween := create_tween()
	_returns[id] = {"tween": tween, "target": destination}
	tween.tween_property(button, "position", overshoot, .20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(button, "scale", Vector2.ONE, .20).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(button, "position", destination, .14).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.finished.connect(func(): _returns.erase(id))


func _button_input(event: InputEvent, id: String, handle: Control = null) -> void:
	var entry: Dictionary = entries[id]
	var button: Control = entry.button if handle == null else handle
	# Handle real touches directly and ignore their emulated mouse events.
	# The owning finger keeps the gesture even outside the button.
	if event is InputEventScreenTouch:
		button.accept_event()
		if event.pressed:
			_begin(id, button.get_global_transform() * event.position, event.index)
		elif _gesture.get("pointer", -1) == event.index:
			_finish(event.canceled)
		return
	if event is InputEventScreenDrag:
		button.accept_event()
		return
	if event is InputEventMouse and event.device == -1:
		button.accept_event()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		button.accept_event()
		var point: Vector2 = button.get_global_transform() * event.position
		if event.pressed:
			_begin(id, point)
		elif not event.pressed and _gesture.get("id") == id:
			_finish()
	elif event is InputEventMouseMotion and _gesture.get("id") == id:
		button.accept_event()
		_move(button.get_global_transform() * event.position)
	elif event is InputEventMouse:
		button.accept_event()


func _begin(id: String, point: Vector2, pointer := -1) -> void:
	if not _gesture.is_empty(): return
	var entry: Dictionary = entries[id]
	_stop_return(id)
	# Keep the current animated position under the finger.
	_gesture = {"id": id, "pointer": pointer, "start": point, "grab": point - entry.button.position,
		"dragging": false, "moved": false, "at": Time.get_ticks_msec(), "can_move": can_reposition(),
		"double_hold": _last_tap.get("id") == id and _last_tap.get("can_move", false)
			and Time.get_ticks_msec() - _last_tap.get("at", 0) <= DOUBLE_TAP_MS}
	_last_tap = {}
	_pointer_capture.show()
	if entry.get("scale_feedback", true): entry.button.scale = Vector2.ONE * .92
	set_process(true)
	if entry.press.is_valid(): entry.press.call()


func _input(event: InputEvent) -> void:
	if not _last_tap.is_empty() and (event is InputEventScreenTouch or event is InputEventMouseButton) and event.pressed:
		var previous: Control = entries[_last_tap.id].button
		if not is_instance_valid(previous) or not previous.get_global_rect().has_point(event.position): _last_tap = {}
	if _gesture.is_empty(): return
	if event is InputEventScreenTouch and event.index == _gesture.pointer and not event.pressed:
		_finish(event.canceled)
	elif event is InputEventScreenDrag and event.index == _gesture.pointer:
		_move(event.position)
	elif event is InputEventMouseButton and event.device != -1 and _gesture.pointer == -1 and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish()
	elif event is InputEventMouseMotion and event.device != -1 and _gesture.pointer == -1:
		_move(event.position)
	else: return
	get_viewport().set_input_as_handled()


func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("FloatingButtons", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	for id in _catchers.keys():
		# A button freed with its owner still has its entry until the loop below.
		if not entries.has(id) or not is_instance_valid(entries[id].button):
			_catchers[id].queue_free()
			_catchers.erase(id)
		else:
			_sync_catcher(id)
	if not _gesture.is_empty() and not entries[_gesture.id].button.is_visible_in_tree():
		_finish(true)
	var moving := false
	for id in targets.keys():
		if not entries.has(id) or not is_instance_valid(entries[id].button):
			targets.erase(id)
			entries.erase(id)
			_stop_return(id)
			continue
		if _gesture.get("id") == id or _returns.has(id): continue
		var button: Control = entries[id].button
		if animate_layout and button.position.distance_to(targets[id]) > .1:
			button.position = button.position.lerp(targets[id], 1.0 - exp(-18.0 * _dt))
			moving = true
		else:
			button.position = targets[id]
	if _gesture.is_empty():
		set_process(moving)
		return
	if _gesture.dragging or _gesture.moved: return
	var entry: Dictionary = entries[_gesture.id]
	if Time.get_ticks_msec() - _gesture.at < HOLD_MS: return
	if _gesture.double_hold or (entry.hold_to_move and _gesture.can_move):
		# The first mic tap starts immediately. Once the second hold declares a
		# move, discard that recording before any pointer release can send it.
		if entry.cancel.is_valid(): entry.cancel.call()
		if not can_reposition():
			_finish(true)
			return
		_gesture.dragging = true
		if entry.get("scale_feedback", true): entry.button.scale = Vector2(1.12, 1.12)
		if OS.has_feature("mobile"): Input.vibrate_handheld(25)


func _move(point: Vector2) -> void:
	if _gesture.is_empty(): return
	var button: Control = entries[_gesture.id].button
	if _gesture.dragging:
		var free := area()
		button.position = (point - _gesture.grab).clamp(free.position, (free.end - button.size).max(free.position))
	else:
		if point.distance_to(_gesture.start) > SLOP: _gesture.moved = true
		if entries[_gesture.id].get("drag", Callable()).is_valid():
			if entries[_gesture.id].drag.call(point - _gesture.start): _finish(true)


func _finish(canceled := false) -> void:
	if _gesture.is_empty(): return
	var gesture := _gesture
	_gesture = {}
	_pointer_capture.hide()
	var entry: Dictionary = entries[gesture.id]
	if canceled:
		if not gesture.dragging and entry.cancel.is_valid(): entry.cancel.call()
	elif gesture.dragging:
		_save_position(gesture.id, entry.button.position)
	elif entry.hold_to_move and gesture.moved:
		if entry.cancel.is_valid(): entry.cancel.call()
	elif gesture.get("release", entry.release).is_valid():
		gesture.get("release", entry.release).call()
		if not gesture.moved and not gesture.double_hold and Time.get_ticks_msec() - gesture.at < HOLD_MS:
			_last_tap = {"id": gesture.id, "at": Time.get_ticks_msec(), "can_move": gesture.can_move}
	layout()
	_settle(gesture.id)


func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("FloatingButtons._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		cancel_gesture()


func _display_size() -> Vector2i:
	if display_size_provider.is_valid(): return Vector2i(display_size_provider.call())
	return DisplayServer.screen_get_size() if OS.has_feature("mobile") else Vector2i.ZERO


func _sync_profile() -> bool:
	var size := _display_size()
	var next := Profiles.path(preferences_path, size)
	if next == _profile_path: return false
	_profile_path = next
	# A release after folding must not save the old screen's drag in the new profile.
	var interrupted := _gesture
	_gesture = {}
	_last_tap = {}
	_pointer_capture.hide()
	for id in _returns.keys(): _stop_return(id)
	var saved := Profiles.load_profile(preferences_path, size)
	var canvas := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2.ZERO
	reference_size = saved.get_value("layout", "reference_size", canvas)
	for id in entries:
		var entry: Dictionary = entries[id]
		var anchor: Variant = saved.get_value("anchors", id, entry.default_anchor)
		entry.anchor = anchor.clamp(Vector2.ZERO, Vector2.ONE) if anchor is Vector2 else entry.default_anchor
	if not interrupted.is_empty() and not interrupted.dragging:
		var cancel: Callable = entries[interrupted.id].cancel
		if cancel.is_valid(): cancel.call()
	return true


func _save(id: String, anchor: Vector2) -> void:
	var config := ConfigFile.new()
	config.load(_profile_path)
	config.set_value("layout", "reference_size", reference_size)
	config.set_value("anchors", id, anchor)
	DirAccess.make_dir_recursive_absolute(_profile_path.get_base_dir())
	config.save(_profile_path)


static func _style(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.07, 0.09, 0.12, 0.72)
		if state == "pressed": style.bg_color = Color(preload("res://scenes/UIAccent.gd").ACTIVE, .85)
		style.border_color = Color(1, 1, 1, 0.16)
		style.set_border_width_all(1)
		style.set_corner_radius_all(int(SIZE.x / 2))
		style.shadow_color = Color(0, 0, 0, 0.3)
		style.shadow_size = 6
		# A true circle outline; StyleBoxFlat's own round border looked dashed.
		button.add_theme_stylebox_override(state, preload("res://scenes/input/RoundOutlineStyle.gd").new(style))
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
