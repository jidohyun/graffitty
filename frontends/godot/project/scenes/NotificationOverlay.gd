extends CanvasLayer
## Screen-space notices: independent of pane zoom, world cameras and diagnostics.
const Card := preload("res://scenes/NotificationCard.gd")
var host: Node
var service: Node
var queue: Array[Dictionary] = []
var cards: Array[Card] = []
## The history lives in a dockable window while it is open, and here otherwise.
var history_panel := PanelContainer.new()
var history_list := VBoxContainer.new()
var history_scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
var history_window: Window

func _ready() -> void:
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.NOTIFICATION
	service = host.application.notifications
	service.posted.connect(_posted)
	service.cleared.connect(_clear)
	get_viewport().size_changed.connect(_resize)
	history_panel.hide()
	history_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxEmpty.new()
	style.set_content_margin_all(8)
	history_panel.add_theme_stylebox_override("panel", style)
	add_child(history_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	history_panel.add_child(column)
	var heading := HBoxContainer.new()
	heading.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(heading)
	var clear := Button.new()
	clear.text = "Clear"
	clear.focus_mode = Control.FOCUS_NONE
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls(): clear.custom_minimum_size.y = 44
	clear.pressed.connect(service.clear_history)
	heading.add_child(clear)
	history_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	history_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(history_scroll)
	history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	history_list.add_theme_constant_override("separation", 12)
	history_scroll.add_child(history_list)
	_resize()
	set_process(false)

func history_open() -> bool:
	return is_instance_valid(history_window)

func _posted(entry: Dictionary) -> void:
	if history_open(): _refresh_history()
	if int(entry.owner) != host.get_instance_id(): return
	queue.append(entry)
	if queue.size() > 100: queue.pop_front()
	_fill()

func _fill() -> void:
	var limit := clampi(int((get_viewport().get_visible_rect().size.y - 40) / 200), 1, 3)
	while cards.size() < limit and not queue.is_empty():
		var card := Card.new()
		card.configure(queue.pop_front())
		add_child(card)
		cards.append(card)
		card.minimum_size_changed.connect(func(): _arrange.call_deferred(false))
		card.dismissed.connect(_dismiss.bind(card))
		card.modulate.a = 0
		_arrange(false)
		var target := card.position
		card.position.x += 32
		card.animation = create_tween().set_parallel(true)
		card.animation.tween_property(card, "modulate:a", 1.0, 0.22)
		card.animation.tween_property(card, "position", target, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	set_process(not cards.is_empty())

func _arrange(animate := true) -> void:
	var viewport := get_viewport().get_visible_rect().size
	var width := minf(440, viewport.x - 32)
	var y := 24.0
	for card in cards:
		card.size = Vector2(width, 0)
		var target := Vector2(viewport.x - width - 16, y)
		y += maxf(card.size.y, card.get_combined_minimum_size().y) + 12
		if card.leaving: continue
		if card.motion != null: card.motion.kill()
		if animate:
			card.motion = create_tween()
			card.motion.tween_property(card, "position", target, 0.24).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		else: card.position = target

func _process(delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(delta)
	preload("res://graffitty/frame_profile.gd").add("NotificationOverlay", Time.get_ticks_usec() - profiled_started)


func _process_body(delta: float) -> void:
	for card in cards.duplicate():
		if card.leaving: continue
		if card.get_global_rect().has_point(get_viewport().get_mouse_position()): continue
		card.remaining -= delta
		if card.remaining <= 0: _dismiss(card)

func _dismiss(card: Card) -> void:
	if card.leaving: return
	card.leaving = true
	if card.animation != null: card.animation.kill()
	if card.motion != null: card.motion.kill()
	card.animation = create_tween().set_parallel(true)
	card.animation.tween_property(card, "modulate:a", 0.0, 0.2)
	card.animation.tween_property(card, "position:x", card.position.x + 36, 0.2).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	card.animation.chain().tween_callback(func():
		cards.erase(card)
		card.queue_free()
		_arrange()
		_fill())

func _resize() -> void:
	# A deferred resize can arrive after the owning window has been removed.
	if not is_inside_tree(): return
	var viewport := get_viewport().get_visible_rect().size
	var limit := clampi(int((viewport.y - 40) / 200), 1, 3)
	while cards.size() > limit:
		var card: Card = cards.pop_back()
		if not card.leaving: queue.push_front(card.entry)
		if card.animation != null: card.animation.kill()
		if card.motion != null: card.motion.kill()
		card.queue_free()
	_arrange(false)
	_fill()

## Opens the history in its dockable window, or raises it. Toasts keep
## appearing, and the keyboard stays with the terminal.
func open_history() -> void:
	if history_open():
		history_window.raise_panel()
		return
	history_window = preload("res://scenes/NotificationsWindow.gd").new()
	history_window.controller = self
	host.get_window().add_child(history_window)
	history_panel.reparent(history_window.slot)
	history_panel.show()
	_refresh_history()
	history_window.present()

func close_history() -> void:
	history_panel.hide()
	if not history_open(): return
	var closing: Window = history_window
	history_window = null
	if history_panel.get_parent() != self: history_panel.reparent(self)
	closing.release()

func toggle_history() -> void:
	if history_open(): close_history()
	else: open_history()

func _exit_tree() -> void:
	if is_instance_valid(history_window): history_window.queue_free()
	history_window = null

func _refresh_history() -> void:
	for child in history_list.get_children():
		history_list.remove_child(child)
		child.queue_free()
	if service.history.is_empty():
		var empty := Label.new()
		empty.text = "No notifications yet."
		history_list.add_child(empty)
	else:
		for index in range(service.history.size() - 1, -1, -1):
			var card := Card.new()
			card.configure(service.history[index], true)
			history_list.add_child(card)

func _clear() -> void:
	queue.clear()
	for card in cards.duplicate(): _dismiss(card)
	if history_open(): _refresh_history()
