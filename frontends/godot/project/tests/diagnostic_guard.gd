extends RefCounted
## Observe actual panel presentations, including dialogs dismissed in the same frame.
## Expectations match a specific fixture, never all errors during a test.
var expected: Array[Dictionary] = []
var failures: Array[String] = []


func install(tree: SceneTree) -> void:
	tree.node_added.connect(_watch)
	_watch_subtree(tree.root)


func allow(message: String, file: String, line: int, warning := false) -> void:
	expected.append({"message": message, "file": file, "line": line, "warning": warning})


func _watch_subtree(node: Node) -> void:
	_watch(node)
	for child in node.get_children():
		_watch_subtree(child)


func _watch(node: Node) -> void:
	if node.has_signal("diagnostics_shown") and not node.is_connected("diagnostics_shown", observe):
		node.connect("diagnostics_shown", observe)
		if node.is_node_ready() and node.panel.is_visible_in_tree():
			observe(preload("res://graffitty/diagnostics.gd").history)


func observe(entries: Array) -> void:
	for entry: Dictionary in entries:
		var identity := {"message": entry.get("message", ""), "file": entry.get("file", ""),
			"line": entry.get("line", 0), "warning": entry.get("warning", false)}
		if identity in expected:
			continue
		var failure := "Unexpected diagnostic dialog: %s (%s:%s)" % [identity.message, identity.file, identity.line]
		if failure not in failures:
			failures.append(failure)
			print("[diagnostic guard] FAIL ", failure)
