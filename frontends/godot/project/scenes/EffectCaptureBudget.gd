extends RefCounted
## All transient effect targets share a pixel allowance across worlds/windows.
## Weak references ensure the budget never extends a capture's lifetime.
static var _targets: Array[WeakRef] = []

static func limit() -> int:
	return 16_000_000 if OS.has_feature("android") or OS.has_feature("ios") else 64_000_000

static func fit(viewport: SubViewport) -> void:
	_targets = _targets.filter(func(reference): return is_instance_valid(reference.get_ref()) and not reference.get_ref().is_queued_for_deletion())
	var frame := Engine.get_process_frames()
	viewport.set_meta("capture_budget_frame", frame)
	viewport.set_meta("capture_requested_size", viewport.size)
	var found := false
	for reference in _targets:
		if reference.get_ref() == viewport: found = true
	if not found: _targets.append(weakref(viewport))
	var used := 0
	var requested := 0
	var pending: Array[SubViewport] = []
	for reference in _targets:
		var target: SubViewport = reference.get_ref()
		if target.get_meta("capture_budget_frame") == frame:
			pending.append(target)
			var extent: Vector2i = target.get_meta("capture_requested_size")
			requested += extent.x * extent.y
		else:
			used += target.size.x * target.size.y
	# Allocate the complete frame together before its first draw. Greedy
	# allocation let pane backings consume everything before glyphs arrived.
	# Reserve room for two retiring snapshots and the next arriving frame.
	var available := maxi(4 * pending.size(), mini(limit() / 3, limit() - used))
	var scale := minf(1.0, sqrt(float(available) / maxf(requested, 1.0)))
	for target in pending:
		var extent: Vector2 = Vector2(target.get_meta("capture_requested_size"))
		target.size = Vector2i((extent * scale).floor()).max(Vector2i(2, 2))
