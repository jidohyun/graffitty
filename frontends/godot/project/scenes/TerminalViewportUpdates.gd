extends RefCounted
## Session state stays on the owner; only visible replicas prepare visual work.
## Shared across windows/hosts, not multiplied by the number of saved tabs.
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
const MAX_SIDE := 8192.0
static var _viewports: Array[WeakRef] = []

static func pixel_budget() -> int:
	return 8_000_000 if OS.has_feature("android") or OS.has_feature("ios") else 32_000_000

static func target_pixel_limit() -> int:
	return 4_000_000 if OS.has_feature("android") or OS.has_feature("ios") else 20_000_000

static func bounded_scale(extent: Vector2, density: float, pixels: int) -> float:
	var side_limit := MAX_SIDE / maxf(extent.x, extent.y)
	var area_limit := sqrt(float(pixels) / maxf(extent.x * extent.y, 1.0))
	return minf(density, minf(side_limit, area_limit))

static func image_budget() -> int:
	return 64 * 1024 * 1024 if OS.has_feature("android") or OS.has_feature("ios") else 256 * 1024 * 1024

static func _rebalance() -> void:
	_viewports = _viewports.filter(func(reference): return is_instance_valid(reference.get_ref()))
	var active: Array[SubViewport] = []
	for reference in _viewports:
		var viewport: SubViewport = reference.get_ref()
		if viewport.is_inside_tree() and is_active(viewport) and not viewport.is_queued_for_deletion(): active.append(viewport)
	for viewport in active:
		var pixels := mini(target_pixel_limit(), maxi(1, pixel_budget() / active.size()))
		var bytes := image_budget() / active.size()
		if viewport.get_meta("terminal_pixel_budget", 0) == pixels and viewport.get_meta("terminal_image_budget", 0) == bytes: continue
		viewport.set_meta("terminal_pixel_budget", pixels)
		viewport.set_meta("terminal_image_budget", bytes)
		var terminal: Node = viewport.get_meta("terminal_render_node").get_ref()
		if is_instance_valid(terminal) and terminal.has_method("set_render_image_budget"):
			terminal.set_render_image_budget(bytes)
		viewport.emit_signal("render_budget_changed")


static func configure(viewport: SubViewport, terminal: Node) -> void:
	_viewports.append(weakref(viewport))
	viewport.add_user_signal("render_budget_changed")
	viewport.tree_exiting.connect(_rebalance.call_deferred)
	viewport.tree_entered.connect(_rebalance.call_deferred)
	viewport.set_meta("terminal_frame_events", terminal.has_signal("frame_changed"))
	viewport.set_meta("terminal_render_visible", true)
	viewport.set_meta("terminal_render_node", weakref(terminal))
	if terminal.has_signal("frame_changed"):
		terminal.connect("frame_changed", request.bind(viewport, true))
		# The Control's own background can change independently of its cell RIDs.
		terminal.connect("draw", request.bind(viewport, false))
		viewport.size_changed.connect(request.bind(viewport, true))
	if terminal.has_signal("output"):
		terminal.connect("output", _wake_activity)
	_rebalance()
	request(viewport, false)

static func request(viewport: SubViewport, wake := true) -> void:
	if not is_instance_valid(viewport) or not is_active(viewport): return
	if wake: RenderUpdates.activity()
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if viewport.get_meta("terminal_frame_events", false) else SubViewport.UPDATE_ALWAYS


static func _wake_activity(_bytes: int) -> void:
	RenderUpdates.activity()

static func set_visible(viewport: SubViewport, visible: bool) -> void:
	var was_active := is_active(viewport)
	viewport.set_meta("terminal_render_visible", visible)
	_sync(viewport, was_active)


## A hidden/suspended host gates every pane without losing tab/crop visibility.
static func set_enabled(viewport: SubViewport, enabled: bool) -> void:
	var was_active := is_active(viewport)
	viewport.set_meta("terminal_presentation_enabled", enabled)
	_sync(viewport, was_active)


static func is_active(viewport: SubViewport) -> bool:
	return (viewport.get_meta("terminal_render_visible", true) or viewport.get_meta("terminal_capture_active", false) or int(viewport.get_meta("terminal_live_users", 0)) > 0) and viewport.get_meta("terminal_presentation_enabled", true)


## Moving whole panes still consume output after their tab loses focus. Each
## layer owns its hold independently of destination preparation and retirement.
static func retain_live(viewport: SubViewport) -> void:
	var was_active := is_active(viewport)
	viewport.set_meta("terminal_live_users", int(viewport.get_meta("terminal_live_users", 0)) + 1)
	_sync(viewport, was_active)
	viewport.emit_signal("render_budget_changed")


static func release_live(viewport: SubViewport) -> void:
	var was_active := is_active(viewport)
	var users := int(viewport.get_meta("terminal_live_users", 0)) - 1
	assert(users >= 0)
	if users == 0: viewport.remove_meta("terminal_live_users")
	else: viewport.set_meta("terminal_live_users", users)
	_sync(viewport, was_active)
	viewport.emit_signal("render_budget_changed")


static func is_transition_live(viewport: SubViewport) -> bool:
	return viewport.get_meta("terminal_transition_live", false) or int(viewport.get_meta("terminal_live_users", 0)) > 0


## A destination capture also needs panes outside the live camera's current crop.
static func set_capture_active(viewport: SubViewport, active: bool) -> void:
	var was_active := is_active(viewport)
	viewport.set_meta("terminal_capture_active", active)
	_sync(viewport, was_active)


static func _sync(viewport: SubViewport, was_active: bool) -> void:
	var active := is_active(viewport)
	var reference: WeakRef = viewport.get_meta("terminal_render_node") if viewport.has_meta("terminal_render_node") else null
	var terminal: Node = reference.get_ref() if reference != null else null
	if is_instance_valid(terminal) and terminal.has_method("set_render_active"):
		terminal.set_render_active(active)
	if not active:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if was_active:
			# A transition may have requested a single frozen capture this frame.
			# Preserve its source until that draw, then discard the live resources.
			_release_after_capture(weakref(viewport))
	elif not was_active or not viewport.get_meta("terminal_frame_events", false):
		if viewport.has_meta("terminal_saved_size"):
			viewport.size = viewport.get_meta("terminal_saved_size")
			viewport.remove_meta("terminal_saved_size")
		request(viewport)
	if active != was_active: _rebalance()

static func _release_after_capture(reference: WeakRef) -> void:
	var pending: SubViewport = reference.get_ref()
	if not pending.is_inside_tree():
		_release_resources(pending)
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	# Headless runs do not emit frame_post_draw. Two process frames also allow
	# deferred transition capture construction to finish before releasing RIDs.
	await tree.process_frame
	await tree.process_frame
	var viewport: SubViewport = reference.get_ref()
	if not is_instance_valid(viewport) or is_active(viewport): return
	_release_resources(viewport)

static func _release_resources(viewport: SubViewport) -> void:
	if not viewport.has_meta("terminal_saved_size"):
		viewport.set_meta("terminal_saved_size", viewport.size)
	viewport.size = Vector2i.ONE
	var reference: WeakRef = viewport.get_meta("terminal_render_node") if viewport.has_meta("terminal_render_node") else null
	var terminal: Node = reference.get_ref() if reference != null else null
	if is_instance_valid(terminal) and terminal.has_method("release_render_resources"):
		terminal.release_render_resources()
