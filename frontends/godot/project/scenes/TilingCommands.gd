extends RefCounted
## Scoped commands for the calling terminal's tab; no implicit world opt-in.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const MODES := ["tiles", "tiling", "floating", "horizontal", "vertical", "h_tiles", "v_tiles"]
const DIRECTIONS := {
	"left": Vector2.LEFT,
	"right": Vector2.RIGHT,
	"up": Vector2.UP,
	"down": Vector2.DOWN,
}


static func error(code: String, message: String) -> Dictionary:
	return { "error": { "code": code, "message": message } }


static func neighbor(rects: Dictionary, key: String, direction: String) -> String:
	if not DIRECTIONS.has(direction): return ""
	return preload("res://scenes/PaneNeighbors.gd").find(rects, key, direction)


static func join(
	node: Dictionary,
	target: String,
	key: String,
	axis: String,
	before: bool,
) -> Dictionary:
	if node.get("pane", "") == target:
		var previous := node.duplicate(false)
		previous.erase("weight")
		var children := [{ "pane": key }, previous] if before else [previous, { "pane": key }]
		var container := { "axis": axis, "children": children }
		if node.has("weight"):
			container["weight"] = node.weight
		return container
	for i in node.get("children", []).size():
		if target in Layout.tile_keys(node.children[i]):
			node.children[i] = join(node.children[i], target, key, axis, before)
			break
	return node


static func dispatch(
	host: Node,
	terminal_id: int,
	method: String,
	params: Dictionary,
) -> Dictionary:
	if host.workspace_view == null:
		return error("unsupported_layout", "This world has not opted into TerminalSpace")
	var id: int = host.workspace_layout.containing("%%%d" % terminal_id)
	var group: Dictionary = host.workspace_layout.tab(id)
	if group.is_empty():
		return error("no_tab", "The calling terminal has no tab")
	var view: Control = host.workspace_view
	var verb := method.trim_prefix("tiling.")
	if verb != "status" and host.workspace_layout.active != id:
		return error("inactive_tab", "Select the calling tab before changing its layout")
	if (
		verb != "status"
		and (
			not view.moving.is_empty() or not view.tile_resize.is_empty()
			or not host.application.drag.is_empty()
		)
	):
		return error("busy", "Finish the current drag first")
	var tree: Dictionary = group.tree
	var key: String = group.focused
	if verb == "layout":
		var modes = params.get("layouts", [])
		if not modes is Array or modes.is_empty():
			return error("invalid_params", "Expected a nonempty layouts array")
		for mode in modes:
			if not mode in MODES:
				return error("invalid_params", "Unsupported layout: %s" % str(mode))
		var tiled: bool = tree.get("tiling", false)
		var axis: String = tree.get("tiles", { }).get("axis", tree.get("split", "h"))
		for mode in modes:
			var matches: bool = (
				tiled
				if mode in ["tiles", "tiling"]
				else (
					not tiled
					if mode == "floating"
					else (
						axis == "h"
						if mode == "horizontal"
						else (
							axis == "v"
							if mode == "vertical"
							else (tiled and axis == ("h" if mode == "h_tiles" else "v"))
						)
					)
				)
			)
			if matches:
				continue
			if mode == "floating":
				for pane in view.pane_rects:
					Layout.find(tree, pane)["rect"] = view.pane_rects[pane]
				tree["tiling"] = false
			elif mode in ["tiles", "tiling", "h_tiles", "v_tiles"]:
				tree["tiling"] = true
			if mode in ["horizontal", "vertical", "h_tiles", "v_tiles"]:
				var orientation := "h" if mode in ["horizontal", "h_tiles"] else "v"
				tree["split"] = orientation
				if tree.get("tiles", { }).has("children"):
					tree.tiles.axis = orientation
			break
	elif verb == "split":
		var orientation = params.get("orientation", "")
		if not orientation in ["horizontal", "vertical", "opposite"]:
			return error("invalid_params", "Expected horizontal, vertical or opposite")
		tree["split"] = (
			("v" if tree.get("split", "h") == "h" else "h")
			if orientation == "opposite"
			else ("h" if orientation == "horizontal" else "v")
		)
	elif verb in ["focus", "move", "join-with"]:
		var direction = params.get("direction", "")
		if not direction is String or not DIRECTIONS.has(direction):
			return error("invalid_params", "Expected left, right, up or down")
		if not tree.get("tiling", false):
			return error("not_tiled", "Use tiling layout tiles first")
		var rects := { }
		Layout.tile_rectangles(tree.get("tiles", { }), view.content_rect(), rects)
		var target := neighbor(rects, key, direction)
		if target.is_empty():
			return error("no_neighbor", "No tiled pane in that direction")
		if verb == "focus":
			host.focus_pane(target)
		else:
			var eligible := Layout.tile_keys(tree.tiles)
			eligible.erase(key)
			tree.tiles = Layout.prune_tiles(tree.tiles, eligible)
			var horizontal: bool = direction in ["left", "right"]
			if verb == "join-with":
				tree.tiles = join(
					tree.tiles,
					target,
					key,
					"v" if horizontal else "h",
					direction in ["right", "down"],
				)
			else:
				tree.tiles = Layout.split_tile(
					tree.tiles,
					target,
					key,
					"h" if horizontal else "v",
					direction in ["left", "up"],
				)
	elif verb == "view":
		var mode = params.get("mode", "")
		if not mode in ["main", "overview"]:
			return error("invalid_params", "Expected main or overview")
		if mode == "main":
			view.show_main()
		else:
			view.show_overview()
	elif verb == "new-window":
		host.create_terminal_window(key, tree.get("split", "h"))
	elif verb == "balance-sizes":
		Layout.balance_tiles(tree.get("tiles", { }))
	elif verb != "status":
		return error("unknown_method", "Unknown tiling command")
	if verb != "status":
		view.refresh()
		host.ui_changed.emit()
	tree = group.tree
	var rectangles := { }
	Layout.arrange(tree.duplicate(true), view.content_rect(), rectangles)
	var panes: Array = []
	for item in Layout.windows(tree):
		var rect: Rect2 = rectangles.get(item.pane, Rect2())
		panes.append(
			{
				"id": item.pane,
				"pane": "%%%s" % str(item.pane).substr(1),
				"stashed": item.get("stashed", false),
				"shown": item.get("shown", true),
				"rect": {
					"x": rect.position.x,
					"y": rect.position.y,
					"width": rect.size.x,
					"height": rect.size.y,
				},
			}
		)
	return {
		"result": {
			"tab": id,
			"tab_target": "@%d" % id,
			"focused": group.focused,
			"tiling": tree.get("tiling", false),
			"split": "horizontal" if tree.get("split", "h") == "h" else "vertical",
			"view": "overview" if view.is_overview() else "main",
			"tiles": tree.get("tiles", { }).duplicate(true),
			"panes": panes,
		}
	}
