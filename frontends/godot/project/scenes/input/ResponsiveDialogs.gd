extends Node
## Keep every embedded dialog inside the usable phone viewport, including IME
## and rotation changes. Text wraps before scaling unusually large custom forms.
var dialogs: Array[AcceptDialog] = []
var bottom_inset := 0.0
var _pending := false

func _ready() -> void:
	add_to_group(&"keyboard_safe_windows")
	bottom_inset = get_tree().root.get_meta(&"keyboard_bottom_inset", 0.0)
	get_tree().root.size_changed.connect(queue_fit)

func set_bottom_inset(value: float) -> void:
	if bottom_inset == value: return
	bottom_inset = value
	queue_fit()

func queue_fit() -> void:
	if _pending: return
	_pending = true
	_fit_visible.call_deferred()


func watch(dialog: AcceptDialog) -> void:
	if dialog in dialogs: return
	dialog.dialog_autowrap = true
	dialogs.append(dialog)
	dialog.about_to_popup.connect(queue_fit)
	dialog.size_changed.connect(queue_fit)
	_watch_content(dialog)
	queue_fit()

func _watch_content(node: Node) -> void:
	if node is Control and not node.minimum_size_changed.is_connected(queue_fit):
		node.minimum_size_changed.connect(queue_fit)
	if not node.child_entered_tree.is_connected(_watch_content): node.child_entered_tree.connect(_watch_content)
	for child in node.get_children(): _watch_content(child)

func _fit_visible() -> void:
	_pending = false
	for index in range(dialogs.size() - 1, -1, -1):
		if not is_instance_valid(dialogs[index]):
			dialogs.remove_at(index)
		elif dialogs[index].visible:
			fit(dialogs[index])

func fit(dialog: AcceptDialog) -> void:
	if not is_instance_valid(dialog) or not dialog.visible or not dialog.is_embedded(): return
	var viewport := dialog.get_parent().get_viewport()
	var room := viewport.get_visible_rect().size
	room.y -= bottom_inset
	fit_in_rect(dialog, Rect2(Vector2(12, 32), (room - Vector2(24, 44)).max(Vector2(1, 1))))

static func fit_in_rect(dialog: AcceptDialog, area: Rect2) -> void:
	preload("res://scenes/DialogActionLayout.gd").apply(dialog)
	dialog.dialog_autowrap = true
	var minimum := dialog.get_contents_minimum_size().max(Vector2.ONE)
	var factor := minf(1.0, minf(area.size.x / minimum.x, area.size.y / minimum.y))
	dialog.content_scale_factor = factor
	dialog.min_size = Vector2i.ZERO
	dialog.max_size = Vector2i(area.size)
	dialog.size = Vector2i(Vector2(dialog.size).min(area.size).max(minimum * factor))
	dialog.position = Vector2i(area.position + (area.size - Vector2(dialog.size)) * 0.5)
