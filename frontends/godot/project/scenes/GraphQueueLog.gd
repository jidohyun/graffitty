extends RefCounted
## Rendering facade. Shared Rust owns journal reception, indexing and counters.
signal changed(edge: String)
var entries: Dictionary = {}
var _core: RefCounted = ClassDB.instantiate("GraphClientCore")

func import_snapshot(owner: Node, snapshot: Dictionary) -> void:
	var update: Dictionary = _core.import_journal(owner.get_instance_id() if owner != null else 0, snapshot)
	if update.has("error"):
		push_error(str(update.error))
		return
	entries = update.entries
	for edge in update.changed: changed.emit(edge)

func snapshot(edge := "") -> Dictionary:
	return _core.journal_snapshot(edge)
