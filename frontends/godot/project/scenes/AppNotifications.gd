extends Node
## In-app notices only. Engine diagnostics and desktop OSC notifications keep
## their existing routes. History is shared by all windows for this app session.
signal posted(entry: Dictionary)
signal cleared
const MAX_HISTORY := 1000
var history: Array[Dictionary] = []
var serial := 0
var _seen: Dictionary = {}

func post(title: String, body: String, owner: Node, level := "info", timeout := 8.0, event_id := "", localization: Dictionary = {}) -> Dictionary:
	if not event_id.is_empty() and _seen.has(event_id): return _seen[event_id]
	serial += 1
	var entry := {"id": serial, "title": title.left(200), "body": body.left(16384),
		"level": level if level in ["info", "success", "warning", "error"] else "info",
		"time": Time.get_datetime_string_from_system(false, true),
		"owner": owner.get_instance_id() if is_instance_valid(owner) else 0,
		"timeout": clampf(timeout, 1.0, 60.0), "event_id": event_id, "localization": localization.duplicate(true)}
	history.append(entry)
	if not event_id.is_empty(): _seen[event_id] = entry
	if history.size() > MAX_HISTORY: _seen.erase(history.pop_front().event_id)
	posted.emit(entry)
	return entry

func clear_history() -> void:
	history.clear()
	_seen.clear()
	cleared.emit()
