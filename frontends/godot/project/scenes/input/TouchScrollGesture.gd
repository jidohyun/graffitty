extends Node
## A touch belongs to the scroll page until release, even without overflow.
## Native click focus and ScrollContainer still handle clicks/scroll inertia;
## only hover hit-testing and press cancellation are owned here.
var page: Control
var scroll: ScrollContainer
var capture := preload("res://scenes/input/PointerHoverCapture.gd").new()
var pointer := -1
var start := Vector2.ZERO
var dragging := false
var generation := 0

func _init(owner_page: Control, owner_scroll: ScrollContainer) -> void:
	page = owner_page
	scroll = owner_scroll
	add_child(capture)

func _ready() -> void:
	# The list owns gestures, including over buttons and dynamically rebuilt rows.
	_allow_scroll_tree(scroll)
	get_tree().node_added.connect(_allow_scroll_gestures)
	page.visibility_changed.connect(func():
		if not page.is_visible_in_tree(): cancel())

func _allow_scroll_tree(node: Node) -> void:
	_allow_scroll_gestures(node)
	for child in node.get_children(): _allow_scroll_tree(child)

func _allow_scroll_gestures(node: Node) -> void:
	if capture.is_ancestor_of(node): return
	if node is Control and scroll.is_ancestor_of(node) and not node is ScrollBar:
		if node.mouse_filter == Control.MOUSE_FILTER_STOP:
			node.mouse_filter = Control.MOUSE_FILTER_PASS

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and pointer == -1 and page.is_visible_in_tree() and scroll.get_global_rect().has_point(event.position):
			pointer = event.index
			start = event.position
			dragging = false
			generation += 1
			# Let the initial GUI press establish native click focus first.
			_capture_after_press.call_deferred(generation)
		elif not event.pressed and event.index == pointer:
			cancel()
	elif pointer != -1:
		if event is InputEventScreenDrag and event.index == pointer:
			_move(event.position)
		elif event is InputEventMouseMotion and event.device == -1:
			_move(event.position)
	# Do not consume these events: native scrolling still needs them.

func _capture_after_press(token: int) -> void:
	if pointer != -1 and token == generation and page.is_visible_in_tree():
		capture.show()

func _move(point: Vector2) -> void:
	if dragging or point.distance_to(start) <= scroll.scroll_deadzone: return
	dragging = true
	# Cancel button activation as soon as the touch becomes a drag, independent
	# of native scrolling, overflow, or the platform's mouse emulation.
	scroll.propagate_notification(Control.NOTIFICATION_SCROLL_BEGIN)
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and scroll.is_ancestor_of(focus): focus.release_focus()

func cancel() -> void:
	pointer = -1
	dragging = false
	generation += 1
	capture.hide()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT]: cancel()
