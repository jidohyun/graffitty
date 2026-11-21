extends RefCounted
## Only foreground identity changes produce app events, never polling/status updates.
var rules: Array = []
var _context: Dictionary = {}
var _active: Dictionary = {}


func update(host: Node, pane: String, app: Dictionary) -> void:
	var next := {
		"pane": pane, "app": str(app.get("id", "")),
		"pid": int(app.get("pid", -1)), "started": str(app.get("started", "")),
	}
	var previous := _context
	# Commit before callbacks, which may change focus or open another world.
	_context = next
	_sync_scopes(host, next)
	if next != _context or next == previous: return
	if previous.get("pane", "") != pane:
		emit_event(host, "focus_changed", next)
	if next != _context: return
	emit_event(host, "app_changed", next)


func emit_event(host: Node, event: String, context: Dictionary) -> void:
	for rule in rules.duplicate():
		if context != _context: return
		if not rule.scoped and rule.matches(event, context):
			rule.action.call(host)


func _sync_scopes(host: Node, context: Dictionary) -> void:
	for rule in _active.keys():
		if context != _context: return
		if rule not in rules or not rule.matches("", context):
			var release: Callable = _active[rule]
			_active.erase(rule)
			if release.is_valid(): release.call()
	for rule in rules.duplicate():
		if context != _context: return
		if rule.scoped and not _active.has(rule) and rule.matches("", context):
			_active[rule] = Callable() # Guard callbacks that synchronously change focus.
			var release = rule.action.call(host)
			if not release is Callable or not release.is_valid():
				push_error("Scoped rule action must return a release Callable")
				continue
			if _active.has(rule):
				_active[rule] = release
			else:
				release.call()


func clear() -> void:
	rules = []
	var releases := _active.values()
	_active.clear()
	_context.clear()
	for release in releases:
		if release.is_valid(): release.call()
