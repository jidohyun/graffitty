extends Node
## Finger-driven desktop slide. One outgoing snapshot; incoming panes stay live.
## No blur, 3D scene, or continuously copied framebuffer.
var manager: Control
var _root: Control
var _snapshot: TextureRect
var _snapshot_layer: CanvasLayer
var _layers: Node
var _origin := Vector2.ZERO
var _origin_tab := -1
var _origin_connection: Node
var _target: Node
var _direction := 0.0
var _progress := 0.0
var _active := false
var _tween: Tween

func _ready() -> void:
	manager.get_viewport().size_changed.connect(cancel)

func handle(progress: float, finished: bool, commit: bool) -> void:
	if _tween != null and _tween.is_running(): return
	if not _active:
		if finished or is_zero_approx(progress): return
		if not _begin(progress): return
	_apply(progress)
	if finished:
		var accept: bool = commit and is_instance_valid(_target) and _target.connected and progress * _direction < 0
		_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_method(_apply, _progress, -_direction if accept else 0.0, .24)
		_tween.tween_callback(_finish.bind(accept))

func _begin(progress: float) -> bool:
	if manager.chooser.visible or manager.dialog.visible or not is_instance_valid(manager.view.host): return false
	_root = manager.view.host.layout_root
	_layers = preload("res://scenes/WorkspaceLayers.gd").for_window(_root.get_window())
	if not _root.is_visible_in_tree(): return false
	var connections: Array = []
	for connection in manager.federation.connections:
		if connection.connected and not connection.topology.tabs.is_empty(): connections.append(connection)
	_origin_tab = manager.view.host.workspace_layout.active
	_origin_connection = manager.federation.owners.get(_origin_tab)
	var index := connections.find(_origin_connection)
	if index < 0: return false
	_direction = 1.0 if progress < 0 else -1.0
	var next := index + int(_direction)
	_target = connections[next] if next >= 0 and next < connections.size() else null
	_origin = _root.position
	_active = true
	if _target != null:
		# Capture before changing tabs. The snapshot exists only for this gesture.
		var viewport := _root.get_viewport()
		var image := viewport.get_texture().get_image()
		if image == null or image.is_empty():
			_active = false
			return false
		var rect := _root.get_global_rect()
		var scale := Vector2(image.get_size()) / viewport.get_visible_rect().size
		var crop := Rect2i(rect.position * scale, rect.size * scale).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		_snapshot = TextureRect.new()
		_snapshot.texture = ImageTexture.create_from_image(image.get_region(crop))
		_snapshot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_snapshot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_snapshot.position = _origin
		_snapshot.size = _root.size
		_snapshot_layer = _layers.create_layer(preload("res://scenes/WorkspaceLayers.gd").Order.TRANSITION)
		_snapshot_layer.add_child(_snapshot)
		manager._remember_view()
		for key in manager.transports:
			if manager.transports[key] == _target:
				manager._open_workspace(key, false)
				break
	return true

func _apply(progress: float) -> void:
	if not _active or not is_instance_valid(_root): return
	_progress = clampf(progress, -1.0, 0.0) if _direction > 0 else clampf(progress, 0.0, 1.0)
	var distance := _progress * _root.size.x
	if is_instance_valid(_snapshot):
		_snapshot.position.x = _origin.x + distance
		_layers.slide(_root, _origin, distance + _direction * _root.size.x)
	else:
		# Finite ends: resisted motion, never wrap around to an unrelated remote.
		_layers.slide(_root, _origin, signf(distance) * 40.0 * (1.0 - exp(-absf(distance) / 160.0)))

func _finish(commit: bool) -> void:
	if not _active: return
	if not commit and is_instance_valid(_origin_connection) and _origin_connection.connected:
		manager.federation.selected = _origin_connection
		if not manager.view.host.workspace_layout.tab(_origin_tab).is_empty():
			manager.view.host.select_workspace(_origin_tab, true)
	if is_instance_valid(_root): _layers.slide(_root, _origin, 0.0)
	if is_instance_valid(_snapshot):
		_snapshot.get_parent().remove_child(_snapshot)
		_snapshot.queue_free()
	_snapshot = null
	if is_instance_valid(_snapshot_layer): _snapshot_layer.queue_free()
	_snapshot_layer = null
	_active = false
	_target = null
	manager._remember_view()

func cancel() -> void:
	if _tween != null: _tween.kill()
	_finish(false)

func _process(_delta: float) -> void:
	if _active and _target != null and (not is_instance_valid(_target) or not _target.connected): cancel()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]: cancel()
