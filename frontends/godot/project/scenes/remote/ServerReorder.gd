extends Node
## Drag a saved-server card to reorder its list. The card itself lifts and
## follows the pointer while its neighbours slide apart where it will land.
##
## Mouse drags immediately; touch holds for 350 ms so a swipe still scrolls.
##
## The pointer is followed from _input, not GUI drag and drop: the touch scroll
## page raises a hover shield after every press, which hides drop targets.
const Profile := preload("res://scenes/input/InteractionProfile.gd")
const Authentication := preload("res://scenes/remote/ClientAuthentication.gd")
const Accent := preload("res://scenes/UIAccent.gd")
## Card metadata naming the saved server a neighbour stands for.
const URL := &"server_order_url"
const HOLD := 0.35
const MOUSE_SLOP := 8.0
const TOUCH_SLOP := 12.0
## Distance from a scroll edge where a held card starts scrolling the list.
const EDGE := 64.0
const SCROLL_SPEED := 900.0
const LIFT_SCALE := 1.03
enum { IDLE, ARMED, DRAGGING, SETTLING }
var target: Control
var block: Control
var endpoint := ""
var failure: Callable
var hold := Timer.new()
var state := IDLE
## Touch index that owns the gesture; -1 for the mouse.
var contact := -1
var touches := {}
var origin := Vector2.ZERO
var pointer := Vector2.ZERO
var grab := Vector2.ZERO
var home := Vector2.ZERO
var list: Container
var scroll: ScrollContainer
var placeholder: Control
var from_index := -1
var from_slot := -1
## Laid-out position of each neighbour, and how far it is still drawn from it.
var rest := {}
var offsets := {}
var _scroll_carry := 0.0
var _resting_style: StyleBox
var _motion: Tween

static func install(control: Control, url: String, error: Callable, area: Control = null) -> Node:
	var adapter := new()
	adapter.target = control
	adapter.block = area if area != null else control
	adapter.endpoint = url
	adapter.failure = error
	control.add_child(adapter)
	return adapter

func _ready() -> void:
	block.set_meta(URL, endpoint)
	target.gui_input.connect(_press)
	hold.one_shot = true
	hold.wait_time = HOLD
	hold.timeout.connect(func():
		if state == ARMED and target.is_visible_in_tree(): _lift())
	add_child(hold)
	set_process(false)

## Only a press that reaches the card itself can start a drag.
func _press(event: InputEvent) -> void:
	if state != IDLE: return
	if Profile.touch_controls():
		if event is InputEventScreenTouch and event.pressed and not event.canceled and touches.size() <= 1:
			_arm(event.position, event.index)
			hold.start()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_arm(event.position, -1)

func _arm(local: Vector2, index: int) -> void:
	state = ARMED
	contact = index
	origin = target.get_global_transform() * local
	pointer = origin

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled: touches[event.index] = true
		else: touches.erase(event.index)
	if state == IDLE or state == SETTLING: return
	if event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
	elif contact >= 0:
		if event is InputEventScreenTouch:
			if event.index == contact and not event.pressed:
				if event.canceled: _cancel()
				else: _release()
			elif event.pressed: _cancel() # A second finger is a different gesture.
		elif event is InputEventScreenDrag and event.index == contact:
			_moved(event.position)
		elif event is InputEventMouseMotion and state == DRAGGING:
			# The touch's emulated mouse must not scroll the list underneath.
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_release()
	elif event is InputEventMouseMotion:
		_moved(event.position)

func _moved(at: Vector2) -> void:
	pointer = at
	if state == ARMED:
		if contact >= 0:
			if at.distance_to(origin) > TOUCH_SLOP: _disarm() # A swipe scrolls.
		elif at.distance_to(origin) > MOUSE_SLOP: _lift()
	if state != DRAGGING: return
	get_viewport().set_input_as_handled()
	_follow()

## The release itself stays unhandled so the list and button end their press.
func _release() -> void:
	if state == DRAGGING: _settle(true)
	else: _disarm()

func _disarm() -> void:
	state = IDLE
	contact = -1
	hold.stop()

func _cancel() -> void:
	if state != DRAGGING:
		_disarm()
		return
	_place(from_slot)
	_settle(false)

func _lift() -> void:
	list = block.get_parent() as Container
	if list == null or not block.is_visible_in_tree():
		_disarm()
		return
	state = DRAGGING
	hold.stop()
	# Withdraw the button press: releasing after a drag must not open the server.
	target.notification(NOTIFICATION_DRAG_BEGIN)
	if target.has_focus(): target.release_focus()
	scroll = null
	var ancestor := list.get_parent()
	while ancestor != null and scroll == null:
		scroll = ancestor as ScrollContainer
		ancestor = ancestor.get_parent()
	var rect := block.get_global_rect()
	home = rect.position
	grab = pointer - rect.position
	from_index = block.get_index()
	# The gap the card leaves, which then travels to wherever it will land.
	placeholder = Control.new()
	placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	placeholder.custom_minimum_size.y = rect.size.y
	placeholder.size_flags_horizontal = block.size_flags_horizontal
	list.add_child(placeholder)
	list.move_child(placeholder, from_index)
	# Top-level controls leave the container's layout and the scroll clip.
	block.top_level = true
	block.position = rect.position
	block.size = rect.size
	block.z_index = 100
	block.pivot_offset = grab
	_resting_style = block.get_theme_stylebox(&"panel") if block.has_theme_stylebox_override(&"panel") else null
	if _resting_style is StyleBoxFlat:
		var raised: StyleBoxFlat = _resting_style.duplicate()
		raised.bg_color = raised.bg_color.lightened(0.06)
		raised.border_color = Accent.ACCENT
		raised.set_border_width_all(1)
		raised.shadow_color = Color(0, 0, 0, 0.5)
		raised.shadow_size = 18
		raised.shadow_offset = Vector2(0, 6)
		block.add_theme_stylebox_override(&"panel", raised)
	_tween().tween_property(block, "scale", Vector2.ONE * LIFT_SCALE, 0.12)
	rest.clear()
	offsets.clear()
	_scroll_carry = 0.0
	if not list.sort_children.is_connected(_sorted): list.sort_children.connect(_sorted)
	_sort_now()
	from_slot = _slot_index()
	set_process(true)
	Input.set_default_cursor_shape(Input.CURSOR_DRAG)
	if OS.has_feature("mobile"): Input.vibrate_handheld(25)
	_follow()

func _tween() -> Tween:
	if _motion != null: _motion.kill()
	_motion = create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	return _motion

func _follow() -> void:
	var at := pointer - grab
	# Mostly a vertical move; a little sideways give keeps it under the finger.
	at.x = home.x + (at.x - home.x) * 0.25
	block.position = at
	_retarget()

## Neighbours that take part in the layout, in order.
func _slots() -> Array:
	return list.get_children().filter(func(child):
		return child is Control and child != block and child != placeholder and child.visible and not child.top_level)

func _slot_index() -> int:
	var at := placeholder.get_index()
	return _slots().filter(func(child): return child.get_index() < at).size()

func _retarget() -> void:
	var centre := block.position.y + block.size.y * 0.5
	var index := 0
	for slot in _slots():
		var laid: Vector2 = rest.get(slot, slot.position)
		if centre > list.global_position.y + laid.y + slot.size.y * 0.5: index += 1
	if index != _slot_index(): _place(index)

func _place(index: int) -> void:
	var slots := _slots()
	if index >= slots.size():
		list.move_child(placeholder, -1)
	else:
		var to: int = slots[index].get_index()
		if placeholder.get_index() < to: to -= 1
		list.move_child(placeholder, to)
	_sort_now()

func _sort_now() -> void:
	list.notification(Container.NOTIFICATION_SORT_CHILDREN)
	_sorted()

## After every layout pass, keep each neighbour drawn where it was and let
## _process glide it to its new place.
func _sorted() -> void:
	for slot in _slots():
		var laid: Vector2 = slot.position
		if rest.has(slot) and not rest[slot].is_equal_approx(laid):
			offsets[slot] = offsets.get(slot, Vector2.ZERO) + rest[slot] - laid
		rest[slot] = laid
		slot.position = laid + offsets.get(slot, Vector2.ZERO)

func _process(delta: float) -> void:
	if state == DRAGGING:
		if not target.is_visible_in_tree():
			_cancel()
		else:
			_autoscroll(delta)
			_retarget()
	for slot in offsets.keys():
		if not is_instance_valid(slot) or slot.get_parent() != list:
			offsets.erase(slot)
			continue
		var offset: Vector2 = offsets[slot] * exp(-delta * 16.0)
		if offset.length() < 0.5:
			offsets.erase(slot)
			offset = Vector2.ZERO
		else:
			offsets[slot] = offset
		slot.position = rest.get(slot, slot.position) + offset
	if state == IDLE and offsets.is_empty():
		if is_instance_valid(list) and list.sort_children.is_connected(_sorted): list.sort_children.disconnect(_sorted)
		set_process(false)

func _autoscroll(delta: float) -> void:
	if scroll == null: return
	var view := scroll.get_global_rect()
	var push := 0.0
	if pointer.y < view.position.y + EDGE: push = pointer.y - (view.position.y + EDGE)
	elif pointer.y > view.end.y - EDGE: push = pointer.y - (view.end.y - EDGE)
	if push == 0.0:
		_scroll_carry = 0.0
		return
	_scroll_carry += clampf(push / EDGE, -1.0, 1.0) * SCROLL_SPEED * delta
	var whole := int(_scroll_carry)
	_scroll_carry -= whole
	scroll.scroll_vertical += whole

func _settle(commit: bool) -> void:
	state = SETTLING
	contact = -1
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	var tween := _tween()
	tween.tween_property(block, "position", placeholder.get_global_rect().position, 0.18)
	tween.tween_property(block, "scale", Vector2.ONE, 0.18)
	tween.chain().tween_callback(_land.bind(commit))

func _land(commit: bool) -> void:
	_motion = null
	var slot := _slot_index()
	list.remove_child(placeholder)
	placeholder.queue_free()
	placeholder = null
	block.top_level = false
	block.z_index = 0
	block.scale = Vector2.ONE
	block.pivot_offset = Vector2.ZERO
	if _resting_style != null: block.add_theme_stylebox_override(&"panel", _resting_style)
	_resting_style = null
	_move_block(slot)
	state = IDLE
	if commit and block.get_index() != from_index: _commit()

func _move_block(slot: int) -> void:
	var slots := _slots()
	if slot >= slots.size():
		list.move_child(block, -1)
	else:
		var to: int = slots[slot].get_index()
		if block.get_index() < to: to -= 1
		list.move_child(block, to)
	_sort_now()

## Saved order is expressed against the nearest neighbouring saved server.
func _commit() -> void:
	var children := list.get_children()
	var at := block.get_index()
	var neighbour := ""
	var before := true
	for i in range(at + 1, children.size()):
		neighbour = _other(children[i])
		if not neighbour.is_empty(): break
	if neighbour.is_empty():
		before = false
		for i in range(at - 1, -1, -1):
			neighbour = _other(children[i])
			if not neighbour.is_empty(): break
	if neighbour.is_empty(): return
	var error := Authentication.reorder_servers(endpoint, neighbour, before)
	if error.is_empty(): return
	list.move_child(block, from_index)
	if failure.is_valid(): failure.call(error)

func _other(child: Node) -> String:
	var url := str(child.get_meta(URL, ""))
	return "" if url == endpoint else url

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		if state == ARMED or state == DRAGGING: _cancel()
	elif what == NOTIFICATION_EXIT_TREE and state in [DRAGGING, SETTLING]:
		# The list is being rebuilt mid-drag: leave nothing floating behind.
		if _motion != null: _motion.kill()
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		if is_instance_valid(placeholder): placeholder.queue_free()
		if is_instance_valid(block): block.top_level = false
		state = IDLE
