extends Control
## Direct Android touch routed through the shared pane and graph hit testing.
## Every contact has one owner while it is down: the workspace recognizer or
## the surface it landed on.
##
## Surfaces declare themselves by group. `touch_chrome` never joins a
## workspace gesture; `touch_yield` owns its touches too, but gives a resting
## one up when the other finger of a pinch is on the workspace.
const Navigation := preload("res://scenes/input/TouchNavigation.gd")
signal remote_swipe(progress: float, finished: bool, commit: bool)
var remote_swipe_enabled := false
var view: Control
var gestures := Navigation.new()
var buttons := 0
var panning := false
var last_touch := -1000
# Releases the window saw since the last touch reached `_input`. A control
# earlier in input order may handle its own contact's release.
var _lifted := {}
var pointer_generation := 0
var scroll_sequence := 0
var scroll_target := ""
# Recordings inject their frame clock: slow encoding must not turn a short
# touch into a long press. Interactive clients keep the monotonic real clock.
var clock_msec: Callable = Time.get_ticks_msec


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 100
	gestures.pointer.connect(_pointer)
	gestures.pinch.connect(_pinch)
	gestures.scroll.connect(_scroll)
	gestures.remote_swipe.connect(func(progress, finished, commit): remote_swipe.emit(progress, finished, commit))
	gestures.canceled.connect(_cancel_drag)
	gestures.yielded.connect(_yielded)
	get_window().window_input.connect(_window_input)



func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("MobilePointer", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	gestures.advance(clock_msec.call())


func _notification(what: int) -> void:
	if what in [
		NOTIFICATION_APPLICATION_FOCUS_OUT,
		NOTIFICATION_WM_WINDOW_FOCUS_OUT,
		NOTIFICATION_PREDELETE,
	]:
		gestures.cancel()
		_lifted.clear()


func _accept_start(position: Vector2) -> bool:
	if not is_visible_in_tree() or view.host == null:
		return false
	var local := view.get_global_transform_with_canvas().affine_inverse() * position
	if not view.viewport_content_rect().has_point(local):
		return false
	for window: Node in get_tree().root.find_children("*", "Window", true, false):
		# Tooltips are mouse-passthrough windows, not modal touch barriers. Nor
		# are unfocusable ones: FloatingButtons keeps one always shown over each
		# button, and that button is already excluded as touch chrome below.
		if window != get_window() and window.visible and not window.get_flag(Window.FLAG_MOUSE_PASSTHROUGH) and not window.unfocusable:
			# A floating tool panel is non-modal, like its docked form: it owns
			# only the touches on its own frame, not the whole workspace.
			if window.is_in_group(&"workspace_tool_windows") and not _over_floating_panel(window, position):
				continue
			return false
	# Fixed chrome stays directly tappable, including native menus/dialogs.
	for control: Control in [view.tab_bar, view.toolbar]:
		if control != null and control.is_visible_in_tree() and control.get_global_rect().has_point(
				position
			):
			return false
	# So do overlays that opt in, such as floating buttons and the dictation bar.
	if _over_touch_chrome(position):
		return false
	return (
		get_viewport().gui_get_focus_owner() == null
		or not get_viewport().gui_get_focus_owner() is LineEdit
	)


## Whether `position` lands on an embedded floating panel, its title included.
func _over_floating_panel(window: Window, position: Vector2) -> bool:
	if not window.is_embedded() or window.get_parent().get_viewport() != get_viewport(): return true
	var frame := Rect2(Vector2(window.position), Vector2(window.size))
	return frame.has_point(position)


func _over_touch_chrome(position: Vector2) -> bool:
	return _surface_at(&"touch_chrome", position) != null


## The visible control of `group` under `position`, ignoring ancestors of `inside`.
func _surface_at(group: StringName, position: Vector2, inside: Control = null) -> Control:
	for control in get_tree().get_nodes_in_group(group):
		if control is Control and control.get_viewport() == get_viewport() and control.is_visible_in_tree():
			if inside != null and control.is_ancestor_of(inside): continue
			var local: Vector2 = control.get_global_transform_with_canvas().affine_inverse() * position
			if Rect2(Vector2.ZERO, control.size).has_point(local):
				return control
	return null


## Whether `position` is on a surface that yields to a pinch.
##
## Chrome beside or above it keeps its own touches, as does a window floating
## over it; chrome that merely contains the surface does not count.
func _yields_at(position: Vector2) -> bool:
	var surface := _surface_at(&"touch_yield", position)
	if surface == null or _surface_at(&"touch_chrome", position, surface) != null:
		return false
	for window in get_window().get_embedded_subwindows():
		if window.visible and Rect2(Vector2(window.position), Vector2(window.size)).has_point(position):
			return false
	return true


func _zone(position: Vector2) -> Navigation.Zone:
	var idle: bool = gestures.fingers.is_empty()
	if idle and _accept_start(position):
		return Navigation.Zone.WORKSPACE
	if _yields_at(position):
		return Navigation.Zone.YIELDING
	# A later finger joins the gesture anywhere but on chrome.
	return Navigation.Zone.EXCLUSIVE if idle or _over_touch_chrome(position) else Navigation.Zone.WORKSPACE


func _window_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and (not event.pressed or event.canceled):
		_lifted[event.index] = true


func _input(event: InputEvent) -> void:
	# Cancellations this router sends to a surface are not new input.
	if event.has_meta(&"touch_route"):
		return
	var touch := event is InputEventScreenTouch or event is InputEventScreenDrag
	if touch:
		for index: int in _lifted: gestures.forget(index)
		_lifted.clear()
	# Captured touches stop momentum inside the recognizer, where the braking
	# tap can be consumed. An emulated mouse press must not erase that state.
	if (event is InputEventKey or (event is InputEventMouseButton and event.device != -1)) and event.pressed:
		gestures.stop_scroll()
	if (
		event is InputEventMouse and event.device == -1
		and (not gestures.fingers.is_empty() or (_accept_start(event.position)
			and (clock_msec.call() - last_touch < 100
				or (event is InputEventMouseButton and event.pressed))))
	):
		get_viewport().set_input_as_handled()
		return
	if not touch:
		return
	# A surface's own contact was canceled: nothing in the workspace ends with it.
	if event is InputEventScreenTouch and event.canceled and not gestures.fingers.has(event.index):
		gestures.forget(event.index)
		return
	var zone := Navigation.Zone.WORKSPACE
	if event is InputEventScreenTouch and event.pressed:
		zone = _zone(event.position)
		if zone == Navigation.Zone.WORKSPACE and gestures.fingers.is_empty():
			gestures.set_remote_swipe_width(size.x if remote_swipe_enabled else 0.0)
			var target := _scroll_target(event.position)
			if target.is_empty() or target != scroll_target:
				gestures.stop_scroll()
			scroll_target = target
			gestures.set_drag_scroll(_drag_scrolls(event.position))
	if gestures.handle(event, clock_msec.call(), zone):
		last_touch = clock_msec.call()
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and event.pressed and gestures.fingers.is_empty():
		gestures.stop_scroll()


## A surface's contact became half of a pinch. Release it there without a click;
## the rest of that contact, and of its emulated mouse, stays with the workspace.
func _yielded(index: int, position: Vector2, mouse: bool) -> void:
	if mouse:
		var release := InputEventMouseButton.new()
		release.device = InputEvent.DEVICE_ID_EMULATION
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = position
		release.global_position = position
		release.canceled = true
		release.set_meta(&"touch_route", true)
		get_viewport().push_input(release, true)
	var cancel := InputEventScreenTouch.new()
	cancel.index = index
	cancel.position = position
	cancel.canceled = true
	cancel.set_meta(&"touch_route", true)
	get_viewport().push_input(cancel, true)


## Momentum can build only within the same pane, never across content targets.
func _scroll_target(position: Vector2) -> String:
	var local: Vector2 = view.get_global_transform_with_canvas().affine_inverse() * position
	var point: Vector2 = view.canvas_point_at(local)
	if not view.resize_window_at(point, true).is_empty() or not view.dividers_at(point, true).is_empty():
		return ""
	return view.window_at(point)


## One finger drags content like a phone: Chromium pages always, terminals
## unless the user prefers selecting text with one finger.
func _drag_scrolls(position: Vector2) -> bool:
	var local: Vector2 = view.get_global_transform_with_canvas().affine_inverse() * position
	var point: Vector2 = view.canvas_point_at(local)
	if not view._compact_header_at(local).is_empty() or not view.dividers_at(point, true).is_empty() or not view.resize_window_at(point, true).is_empty():
		return false
	for port in view.agent_links.sockets(true).values():
		if port.visible and port.get_global_rect().has_point(position):
			return false
	var key: String = view.window_at(point)
	if not view.panes.has(key):
		return false
	if not view.host.is_chromium_pane(key) and not (view.host.is_terminal_pane(key) and view.host.application.terminal_touch_scroll_fingers == 1):
		return false
	# Shift on the key strip makes the next terminal drag a Shift+drag, which
	# selects text even in an application that captures the mouse.
	var keybar = view.host.get("touch_keybar")
	if view.host.is_terminal_pane(key) and is_instance_valid(keybar) and keybar.shift_drag_selects():
		return false
	var pane: Control = view.panes[key]
	var content_point: Vector2 = pane.texture.get_global_transform().affine_inverse() * (view.canvas_root.get_global_transform() * point)
	return Rect2(Vector2.ZERO, pane.texture.size).has_point(content_point)


func _cancel_drag() -> void:
	pointer_generation += 1
	if not is_inside_tree() or not is_instance_valid(view) or not view.is_inside_tree() or view.host == null: return
	if is_instance_valid(view.agent_links): view.agent_links.dragging = ""
	view.cancel_tile_resize()
	for pane in view.panes.values():
		if is_instance_valid(pane): pane.abort_drag()
	panning = false

func _pointer(event: InputEventMouse) -> void:
	if not is_instance_valid(view) or not view.is_inside_tree(): return
	var local: Vector2 = view.get_global_transform_with_canvas().affine_inverse() * event.position
	if event is InputEventMouseButton:
		buttons = event.button_mask
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var point: Vector2 = view.canvas_point_at(local)
			panning = view.window_at(point).is_empty() and view._compact_header_at(local).is_empty() \
				and view.resize_window_at(point, true).is_empty() and view.dividers_at(point, true).is_empty()
			for port in view.agent_links.sockets(true).values():
				if port.visible and port.get_global_rect().has_point(event.position): panning = false
		elif not event.pressed:
			panning = false
	if event is InputEventMouseMotion and panning:
		view.begin_navigation_render()
		view._cancel_main_magnet()
		view._begin_navigation()
		view.navigation_center += view.canvas_point_at(local - event.relative) - view.canvas_point_at(local)
		view._apply_navigation()
		return
	_dispatch_pointer.call_deferred(event, pointer_generation)

func _dispatch_pointer(event: InputEvent, generation: int) -> void:
	if not is_instance_valid(view) or not view.is_inside_tree(): return
	# A second contact may arrive before deferred pointer events are delivered.
	# Drop the old press/motion, while always releasing any existing GUI capture
	# and any rubber band a scroll left pulled.
	var releases: bool = (event is InputEventMouseButton and not event.pressed) or str(event.get_meta("scroll_phase", "")) == "ended"
	if generation != pointer_generation and not releases: return
	if event is InputEventMouse: event.global_position = event.position
	event.set_meta("direct_touch", true)
	if event is InputEventMouseButton and not event.canceled:
		var motion := InputEventMouseMotion.new()
		motion.position = event.position
		motion.global_position = event.position
		motion.button_mask = event.button_mask
		motion.set_meta("direct_touch", true)
		get_viewport().push_input(motion, true)
	get_viewport().push_input(event, true)
	# As in Chromium, a fling update that scrolled nothing has run into an end:
	# the fling stops there, so the next tap is a tap rather than a brake on
	# content that no longer moves. Surfaces that cannot tell keep it going.
	# As in Chromium, a fling update that scrolled nothing has run into an end:
	# the fling stops there, so the next tap is a tap rather than a brake on
	# content that no longer moves. Surfaces that cannot tell keep it going.
	if event is InputEventPanGesture and event.has_meta("momentum_phase"):
		var sequence: int = event.get_meta("touch_scroll_sequence", -1)
		if sequence == scroll_sequence and _fling_scrolled(sequence) == false:
			gestures.stop_scroll()

## Whether the surface under a fling scrolled its update `sequence`: `false`
## at an end, `null` when the surface cannot tell (Chromium pages and others).
func _fling_scrolled(sequence: int) -> Variant:
	if not is_instance_valid(view) or view.host == null or not view.host.is_terminal_pane(scroll_target): return null
	var term = view.host.sessions.get(int(scroll_target.substr(1)), {}).get("term")
	return term.touch_scrolled(sequence) if is_instance_valid(term) else null

func _scroll(anchor: Vector2, delta: Vector2, stage: String) -> void:
	# Content follows the fingers. Match native pan units on the Mac simulator.
	var event := InputEventPanGesture.new()
	event.position = anchor
	event.delta = -delta * (0.03 if OS.get_name() == "macOS" else 1.0)
	scroll_sequence += 1
	event.set_meta("touch_scroll_sequence", scroll_sequence)
	# Chromium moves its page exactly as far as the finger travelled.
	event.set_meta("touch_travel", delta)
	# Chromium's rubber band reads its release velocity from event spacing,
	# not from when each event happens to arrive at the host.
	event.set_meta("event_time", Time.get_ticks_usec() / 1000000.0)
	# Terminals pull past an edge under the fingers, bounce on momentum and
	# release at the end, as Chromium does for a touchscreen.
	if stage == "momentum":
		event.set_meta("momentum_phase", "changed")
	else:
		event.set_meta("scroll_phase", stage)
	_dispatch_pointer.call_deferred(event, pointer_generation)

func _pinch(previous_center: Vector2, center: Vector2, factor: float) -> void:
	if not is_instance_valid(view) or not view.is_inside_tree(): return
	var local: Transform2D = view.get_global_transform_with_canvas().affine_inverse()
	view.pinch_workspace(local * previous_center, local * center, factor)
