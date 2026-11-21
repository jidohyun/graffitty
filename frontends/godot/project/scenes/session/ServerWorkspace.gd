extends RefCounted
## Canonical server layout conversion. Rect2 and pane keys are presentation
## types; the wire representation is shared with every other frontend.
const Layout := preload("res://scenes/WorkspaceLayout.gd")

static func decode_tab(id: int, value: Dictionary) -> Dictionary:
	var windows: Array[Dictionary] = []
	for item in value.get("windows", []):
		var rect: Array = item.get("rect", [24, 60, 800, 500])
		windows.append({"pane": str(item.key), "shown": bool(item.get("shown", true)),
			"stashed": bool(item.get("stashed", false)), "graph_floating": bool(item.get("graph_floating", false)),
			"rect": Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))})
	var tree := {"windows": windows, "tiling": bool(value.get("enabled", true)),
		"physics": bool(value.get("physics", true)), "tiling_axis": str(value.get("axis", "h")),
		# Local gestures must not mutate the owner snapshot used as the CAS base.
		"tiles": value.tiles.duplicate(true) if value.get("tiles") is Dictionary else {}}
	if value.get("gap") != null: tree.tiling_gap = float(value.gap)
	if value.get("physics_anchor") != null: tree.physics_anchor = str(value.physics_anchor)
	return {"id": id, "focused": str(value.get("focused", "")), "tree": tree, "graph_visual": decode_graph(value.get("graph_visual", {}))}

static func encode_tab(group: Dictionary) -> Dictionary:
	var tree: Dictionary = group.get("tree", {})
	var windows: Array[Dictionary] = []
	for item in Layout.windows(tree):
		var rect: Rect2 = item.get("rect", Rect2(24, 60, 800, 500))
		windows.append({"key": str(item.pane), "shown": bool(item.get("shown", true)),
			"stashed": bool(item.get("stashed", false)), "graph_floating": bool(item.get("graph_floating", false)),
			"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]})
	var tiles: Dictionary = tree.get("tiles", {})
	return {"enabled": bool(tree.get("tiling", false)), "physics": bool(tree.get("physics", true)),
		"physics_anchor": tree.get("physics_anchor"), "axis": str(tree.get("tiling_axis", "h")),
		"gap": tree.get("tiling_gap"), "focused": str(group.get("focused", "")),
		"windows": windows, "tiles": tiles if not tiles.is_empty() else null,
		"graph_visual": encode_graph(group.get("graph_visual", {}))}

static func encode_graph(visual: Dictionary) -> Dictionary:
	var points := {}
	for id in visual.get("reroutes", {}):
		var point: Vector2 = visual.reroutes[id].position
		points[id] = {"position": [point.x, point.y]}
	return {"routes": visual.get("routes", {}).duplicate(true), "reroutes": points}

static func decode_graph(value: Dictionary) -> Dictionary:
	var points := {}
	for id in value.get("reroutes", {}):
		var point: Array = value.reroutes[id].position
		points[id] = {"position": Vector2(point[0], point[1])}
	return {"routes": value.get("routes", {}).duplicate(true), "reroutes": points}

static func map_route(key: String, map_id: Callable) -> String:
	var ends := key.split(">")
	if ends.size() != 2: return key
	for i in ends.size():
		var slash := ends[i].find("/")
		if slash > 0:
			ends[i] = str(map_value(ends[i].substr(0, slash), map_id)) + ends[i].substr(slash)
	return ">".join(ends)

static func map_value(value: Variant, map_id: Callable) -> Variant:
	if value is String and preload("res://scenes/PaneTargets.gd").valid(value):
		return "%%%d" % int(map_id.call(int(value.substr(1))))
	if value is Dictionary:
		var output := {}
		for key in value:
			output[map_route(str(key), map_id)] = map_value(value[key], map_id)
		return output
	if value is Array: return value.map(func(item): return map_value(item, map_id))
	return value

static func map_snapshot(value: Dictionary, map_id: Callable) -> Dictionary:
	var result: Dictionary = value.duplicate(true)
	var tabs := {}
	for key in value.get("layout", {}).get("tabs", {}):
		tabs[str(int(map_id.call(int(key))))] = map_value(value.layout.tabs[key], map_id)
	result.layout.tabs = tabs
	var settings := {}
	for key in value.get("tabs", {}): settings[str(int(map_id.call(int(key))))] = value.tabs[key]
	result.tabs = settings
	result.order = value.get("order", []).map(func(id): return int(map_id.call(int(id))))
	if value.get("active") != null: result.active = int(map_id.call(int(value.active)))
	return result
