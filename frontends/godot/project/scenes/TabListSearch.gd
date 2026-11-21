extends RefCounted
## Group title matches by workspace, using the command line's Rust ranker.
var _ranker: RefCounted = ClassDB.instantiate("FuzzyRanker")
var _labels := PackedStringArray()
var preferred := ""


static func identity(item: Dictionary) -> String:
	return "pane:" + str(item.pane_key) if item.get("kind", "tab") == "pane" else "tab:%d" % int(item.id)


func filter(items: Array, query: String) -> Array[Dictionary]:
	var tabs: Array[Dictionary] = []
	var candidates: Array[Dictionary] = []
	var labels := PackedStringArray()
	for i in items.size():
		var tab: Dictionary = items[i].duplicate()
		tab.merge({"kind": "tab", "ordinal": i + 1}, true)
		tabs.append(tab)
		candidates.append({"tab": i, "item": tab})
		labels.append(str(tab.title))
		for pane in tab.get("panes", []):
			var child := {"kind": "pane", "id": tab.id, "ordinal": i + 1,
				"pane_key": pane.key, "pane_ordinal": pane.ordinal, "title": pane.title}
			candidates.append({"tab": i, "item": child})
			labels.append(str(pane.title))
	preferred = ""
	query = query.strip_edges()
	if query.is_empty(): return tabs
	if labels != _labels:
		_labels = labels
		_ranker.set_items(labels)
	var order: Array[int] = []
	var panes := {}
	# Allow typos; highlight the ranker's actual matches so partial matches
	# remain understandable even when not every query character is present.
	for found in _ranker.rank(query, true):
		var candidate: Dictionary = candidates[int(found.index)]
		candidate.item["match_indices"] = found.indices
		var index: int = candidate.tab
		if preferred.is_empty(): preferred = identity(candidate.item)
		if not panes.has(index):
			order.append(index)
			panes[index] = []
		if candidate.item.kind == "pane": panes[index].append(candidate.item)
	var result: Array[Dictionary] = []
	for index in order:
		result.append(tabs[index])
		result.append_array(panes[index])
	return result
