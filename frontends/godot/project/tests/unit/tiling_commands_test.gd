extends "res://tests/unit/test_case.gd"
const Commands := preload("res://scenes/TilingCommands.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func test_directional_focus_ignores_diagonal_panes() -> void:
	var rects := {
		"left": Rect2(0, 0, 400, 800),
		"top": Rect2(408, 0, 400, 396),
		"bottom": Rect2(408, 404, 400, 396),
	}
	expect(Commands.neighbor(rects, "bottom", "up") == "top", "Up reaches the pane above")
	expect(Commands.neighbor(rects, "top", "left") == "left", "Left reaches the spanning neighbor")
	expect(
		Commands.neighbor(rects, "top", "up").is_empty(),
		"A left-hand pane cannot act as an upper neighbor",
	)
	expect(
		Commands.neighbor(rects, "left", "left").is_empty(),
		"Focus does not wrap beyond an edge",
	)


func test_join_with_preserves_the_outer_container() -> void:
	var node := { "axis": "h", "children": [{ "pane": "a" }, { "pane": "c" }] }
	var joined := Commands.join(node, "c", "b", "v", true)
	expect(joined.axis == "h" and joined.children.size() == 2, "Root siblings stay horizontal")
	expect(joined.children[1].axis == "v", "Join right creates the opposite vertical orientation")
	expect(Layout.tile_keys(joined) == ["a", "b", "c"], "No pane is lost or duplicated")
