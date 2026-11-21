extends RefCounted
## Presentation only: IDs refer to application-owned live sessions.
var tabs: Array[Dictionary] = []
var active := -1
# The scene root releases the helper before native classes are unregistered.
# Engine metadata outlives scene teardown and can retain an extension object
# until after its native destructor is no longer available.
static func _core() -> RefCounted:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_layout_core"):
		owner.set_meta("graffitty_layout_core", ClassDB.instantiate("WorkspaceLayoutCore"))
	return owner.get_meta("graffitty_layout_core")


static func leaf(key: String, shown := true) -> Dictionary:
	return { "pane": key, "shown": shown }


static func windows(tree: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if tree.has("pane"):
		result.append(tree)
	else:
		for item in tree.get("windows", []):
			result.append(item)
	return result


static func keys(tree: Dictionary, visible_only := false) -> Array[String]:
	var result: Array[String] = []
	for item in windows(tree):
		if not visible_only or item.get("shown", true):
			result.append(item.pane)
	return result


## Main panes lead every address list. Only tiled panes follow spatial order;
## the remaining panes retain their stored relative order, including hidden ones.
static func numbered_keys(tree: Dictionary, focused := "") -> Array[String]:
	return _core().numbered_keys(tree, focused)


static func main_keys(tree: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for item in windows(tree):
		if item.get("shown", true) and not item.get("stashed", false) and not item.get("graph_floating", false):
			result.append(item.pane)
	return result


func tab(id: int) -> Dictionary:
	for item in tabs:
		if item.id == id:
			return item
	return { }


func containing(key: String) -> int:
	for item in tabs:
		if key in keys(item.tree):
			return item.id
	return -1


func add(id: int, tree: Dictionary) -> void:
	tabs.append({ "id": id, "tree": tree, "focused": keys(tree)[0] })
	if active < 0:
		active = id


func ensure_terminal(id: int, tiling_default := true) -> void:
	var key := "%%%d" % id
	if containing(key) < 0:
		var tree := leaf(key)
		tree["tiling"] = tiling_default
		add(id, tree)


func take(id: int) -> Dictionary:
	var item := tab(id)
	if item.is_empty():
		return { }
	var previous_order := tabs.map(func(group): return int(group.id))
	tabs.erase(item)
	active = surviving_active(previous_order, active, tabs.map(func(group): return int(group.id)))
	return item


static func surviving_active(previous_order: Array, active_id: int, current_order: Array) -> int:
	if active_id in current_order:
		return active_id
	var index := previous_order.find(active_id)
	if index >= 0:
		for i in range(index - 1, -1, -1):
			if previous_order[i] in current_order: return int(previous_order[i])
		for i in range(index + 1, previous_order.size()):
			if previous_order[i] in current_order: return int(previous_order[i])
	return int(current_order[0]) if not current_order.is_empty() else -1


## A tab's own name, shown instead of its focused window's title; empty returns
## it to that. It moves with the tab; a tab merged into another loses it.
func set_title(id: int, title: String) -> void:
	var item := tab(id)
	if item.is_empty():
		return
	if title.is_empty():
		item.erase("title")
	else:
		item.title = title


func reorder(id: int, index: int) -> void:
	var item := tab(id)
	if item.is_empty():
		return
	tabs.erase(item)
	tabs.insert(clampi(index, 0, tabs.size()), item)


static func remove(tree: Dictionary, key: String) -> Dictionary:
	var remaining: Array[Dictionary] = []
	for item in windows(tree):
		if item.pane != key:
			remaining.append(item)
	if remaining.is_empty():
		return { }
	var result := tree.duplicate(false)
	result.erase("pane")
	result["windows"] = remaining
	result["tiles"] = prune_tiles(tree.get("tiles", { }), keys(result))
	return result


func take_pane(key: String) -> Dictionary:
	var id := containing(key)
	var item := tab(id)
	if item.is_empty():
		return { }
	var found := find(item.tree, key).duplicate(true)
	item.tree = remove(item.tree, key)
	if item.tree.is_empty():
		take(id)
	elif item.focused == key:
		item.focused = keys(item.tree)[0]
	return found


static func find(tree: Dictionary, key: String) -> Dictionary:
	for item in windows(tree):
		if item.pane == key:
			return item
	return { }


static func insert(
	tree: Dictionary,
	_target: String,
	incoming: Dictionary,
	_edge: String,
) -> Dictionary:
	var result := tree.duplicate(false)
	result.erase("pane")
	result["windows"] = windows(tree) + windows(incoming)
	return result


func merge(id: int, incoming: Dictionary, target := "", edge := "right") -> void:
	var item := tab(id)
	if item.is_empty():
		return
	var occupied: Array = []
	for window in windows(item.tree):
		if window.has("rect"):
			occupied.append(window.rect)
	for window in windows(incoming):
		if not window.has("rect"):
			continue
		while window.rect in occupied:
			window.rect.position += Vector2(32, 32)
		occupied.append(window.rect)
	item.tree = insert(item.tree, target, incoming, edge)


static func clamp_window_position(rect: Rect2) -> Rect2:
	return _core().clamp_window_position(rect)


static func rectangles(tree: Dictionary, area: Rect2, result: Dictionary) -> void:
	result.merge(_core().rectangles(tree, area), true)


## The tiling tree is independent of the live window list. Stashed and hidden
## windows retain their rectangles and sessions, but never occupy a tile.
static func prune_tiles(node: Dictionary, eligible: Array[String]) -> Dictionary:
	return _core().prune_tiles(node, eligible)


static func tile_keys(node: Dictionary) -> Array[String]:
	return _core().tile_keys(node)


static func split_tile(
	node: Dictionary,
	target: String,
	key: String,
	axis: String,
	before := false,
) -> Dictionary:
	return _core().split_tile(node, target, key, axis, before)


## Weights belong to children, so nested splits retain the outer allocation.
static func tile_children(node: Dictionary, area: Rect2, gap_size := 8.0) -> Array[Rect2]:
	return _core().tile_children(node, area, gap_size)


static func tile_rectangles(node: Dictionary, area: Rect2, result: Dictionary, gap_size := 8.0) -> void:
	result.merge(_core().tile_rectangles(node, area, gap_size), true)


static func tile_dividers(node: Dictionary, area: Rect2, path: Array = [], gap_size := 8.0) -> Array[Dictionary]:
	return _core().tile_dividers(node, area, path, gap_size)


static func tile_minimum(node: Dictionary, gap_size := 8.0) -> Vector2:
	return _core().tile_minimum(node, gap_size)


## Resize only the adjacent branches. The caller supplies a pre-drag snapshot.
static func resize_tiles(node: Dictionary, divider: Dictionary, delta: float) -> void:
	var updated: Dictionary = _core().resize_tiles(node, divider, delta)
	node.clear()
	node.merge(updated)


static func balance_tiles(node: Dictionary) -> void:
	var updated: Dictionary = _core().balance_tiles(node)
	node.clear()
	node.merge(updated)


static func resize_to_fit_main(tree: Dictionary, key: String, area: Rect2, focused := "") -> bool:
	return _core().resize_to_fit_main(tree, key, area, focused)


## Main-area bounds stay unchanged for stash/drop classification.
static func tiling_area(tree: Dictionary, area: Rect2) -> Rect2:
	return _core().tiling_area(tree, area)


## Resolve pending membership without mutating the stored tree during a query.
static func normalized_tiles(tree: Dictionary, focused := "") -> Dictionary:
	return _core().normalized_tiles(tree, focused)


static func arrange(
	tree: Dictionary,
	area: Rect2,
	result: Dictionary,
	focused := "",
	moving := "",
) -> void:
	result.merge(_core().arrange(tree, area, focused, moving), true)


static func place(
	tree: Dictionary,
	key: String,
	rect: Rect2,
	area: Rect2,
	target := "",
	edge := "right",
	drop_point := Vector2.INF,
) -> void:
	_core().place(tree, key, rect, area, target, edge, rect.get_center() if drop_point == Vector2.INF else drop_point)


## A transaction proposal. Both hover and release use this exact tree; the
## original layout and sessions remain untouched until release commits it.
static func preview_placement(
	tree: Dictionary,
	incoming: Dictionary,
	rect: Rect2,
	area: Rect2,
	point: Vector2,
	placements: Dictionary = {},
) -> Dictionary:
	var proposal: Dictionary = _core().preview_placement(tree, incoming, rect, area, point, placements)
	proposal["label"] = "Stash" if not area.has_point(point) else (String(TranslationServer.translate("Tile %s")) % String(TranslationServer.translate(proposal.edge)) if tree.get("tiling", false) else "Move here")
	return proposal


static func adjacent_spawn_rect(source: Rect2, axis: String, before := false) -> Rect2:
	# Shallow contact on one axis makes physics push away from the pinned source.
	var offset := Vector2(maxf(40, source.size.x - 40), 0) if axis == "h" else Vector2(0, maxf(40, source.size.y - 40))
	return Rect2(source.position + (-offset if before else offset), source.size)
