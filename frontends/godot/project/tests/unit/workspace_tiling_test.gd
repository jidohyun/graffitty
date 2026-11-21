extends "res://tests/unit/test_case.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")

func test_dragging_across_three_columns_never_reverses_order() -> void:
	var area := Rect2(0, 80, 1200, 720)
	var tree := {"windows": [Layout.leaf("a"), Layout.leaf("b"), Layout.leaf("c")], "tiling": true, "tiling_gap": 8.0}
	var rectangles := {}
	Layout.arrange(tree, area, rectangles)
	var before := tree.duplicate(true)
	var rect: Rect2 = rectangles.a
	var initial := Layout.preview_placement(tree, Layout.leaf("a"), rect, area, rect.position + Vector2(20, 10))
	expect(initial.tree.tiles == tree.tiles, "Picking up the header preserves the original tile")
	var previous := 0
	for x in range(0, 1200, 4):
		var plan := Layout.preview_placement(tree, Layout.leaf("a"), rect, area, Vector2(x, area.get_center().y))
		var index := Layout.tile_keys(plan.tree.tiles).find("a")
		expect(index >= previous, "Moving right cannot move the pane back left, including gaps (x=%d)" % x)
		expect(is_equal_approx(plan.rectangles.a.size.y, rect.size.y), "Horizontal drag stays in columns")
		previous = index
	expect(previous == 2, "The right edge places the dragged pane last")
	expect(tree == before, "Preview leaves the live layout unchanged")


func test_short_keyboard_area_spends_height_on_content_before_gutters() -> void:
	var tree := {"tiling_gap": 8.0}
	expect(Layout.tiling_area(tree, Rect2(0, 0, 862, 73)) == Rect2(8, 0, 846, 73), "One-row landscape retains the full terminal height")
	expect(Layout.tiling_area(tree, Rect2(0, 0, 862, 110)) == Rect2(8, 5, 846, 100), "Outer margins shrink before the ordinary minimum leaf height")
	expect(Layout.tiling_area(tree, Rect2(0, 45, 862, 283)) == Rect2(8, 53, 846, 267), "Ordinary viewports keep configured gutters")


func test_stacked_panes_accept_side_drops_inside_the_destination() -> void:
	var area := Rect2(40, 80, 850, 1060)
	var tree := {"windows": [Layout.leaf("a"), Layout.leaf("b")], "tiling": true,
		"tiling_gap": 8.0, "tiles": {"axis": "v", "children": [{"pane": "a"}, {"pane": "b"}]}}
	var rectangles := {}
	Layout.arrange(tree, area, rectangles)
	var before := tree.duplicate(true)
	var preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
	for pair in [["a", "b"], ["b", "a"], ["incoming", "a"]]:
		var target: Rect2 = rectangles[pair[1]]
		for x in [0.2, 0.8]:
			for y in [0.02, 0.5, 0.98]:
				var point := target.position + target.size * Vector2(x, y)
				var plan := Layout.preview_placement(tree, Layout.leaf(pair[0]), Rect2(point, Vector2(320, 200)), area, point)
				expect(plan.edge == ("left" if x < 0.5 else "right"), "Interior side quarters work near both corners")
				preview.present(plan, area, point)
				expect(preview.visible and preview.rectangles.has(pair[0]), "The side split is highlighted before release")
				var moved: Rect2 = plan.rectangles[pair[0]]
				var other: Rect2 = plan.rectangles[pair[1]]
				expect(is_equal_approx(moved.position.y, other.position.y) and is_equal_approx(moved.size.y, other.size.y), "Side drops produce columns")
				expect(moved.end.x <= other.position.x if x < 0.5 else other.end.x <= moved.position.x, "Preview puts the incoming pane on the requested side")
				var committed := {}
				Layout.arrange(plan.tree, area, committed)
				expect(committed == preview.rectangles, "Release geometry matches the visible preview")
				expect(tree == before, "Hover preserves the original layout")
	preview.free()


func test_dragged_pane_does_not_block_side_targets_in_its_old_slot() -> void:
	var area := Rect2(40, 80, 850, 1060)
	var tree := {"windows": [Layout.leaf("a"), Layout.leaf("b")], "tiling": true,
		"tiling_gap": 8.0, "tiles": {"axis": "v", "children": [{"pane": "a"}, {"pane": "b"}]}}
	var rectangles := {}
	Layout.arrange(tree, area, rectangles)
	var before := tree.duplicate(true)
	var preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
	for source in ["a", "b"]:
		var other := "b" if source == "a" else "a"
		for x in [0.2, 0.8]:
			var expected := {}
			for y in [0.02, 0.25, 0.49, 0.5, 0.51, 0.75, 0.98]:
				var point := area.position + area.size * Vector2(x, y)
				var rect: Rect2 = rectangles[source]
				rect.position = point - Vector2(rect.size.x * 0.5, 20)
				var plan := Layout.preview_placement(tree, Layout.leaf(source), rect, area, point)
				preview.present(plan, area, point)
				expect(plan.edge == ("left" if x < 0.5 else "right"), "The old source slot also selects left/right")
				var moved: Rect2 = preview.rectangles[source]
				var neighbor: Rect2 = preview.rectangles[other]
				expect(is_equal_approx(moved.position.y, neighbor.position.y) and is_equal_approx(moved.size.y, neighbor.size.y), "The preview shows columns in both halves of the workspace")
				expect((moved.position.x < neighbor.position.x) == (x < 0.5), "The dragged pane appears on the requested side")
				if expected.is_empty(): expected = preview.rectangles.duplicate()
				expect(preview.rectangles == expected, "Crossing the old divider keeps the same side preview")
				var committed := {}
				Layout.arrange(plan.tree, area, committed)
				expect(committed == expected and tree == before, "Commit matches the preview and hover leaves the original intact")
	preview.free()


func test_drop_highlight_only_covers_main_area_tiles() -> void:
	var area := Rect2(0, 80, 1200, 720)
	var tree := {
		"windows": [Layout.leaf("a"), Layout.leaf("b"),
			{"pane": "stash", "stashed": true, "rect": Rect2(1400, 100, 400, 300)},
			{"pane": "floating", "graph_floating": true, "rect": Rect2(100, 100, 400, 300)}],
		"tiling": true,
	}
	var preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
	var point := Vector2(100, 200)
	var plan := Layout.preview_placement(tree, Layout.leaf("b"), Rect2(point, Vector2(320, 200)), area, point)
	preview.present(plan, area, point)
	expect(preview.visible and preview.rectangles.has("a"), "Main-area tile split has a preview")
	for rect in preview.rectangles.values():
		expect(preview.get_rect().encloses(rect), "Preview has render culling bounds around every highlighted tile")
	expect(not preview.rectangles.has("stash") and not preview.rectangles.has("floating"), "Untiled panes are never highlighted")
	point = Vector2(1450, 200)
	plan = Layout.preview_placement(tree, Layout.leaf("b"), Rect2(point, Vector2(320, 200)), area, point)
	preview.present(plan, area, point)
	expect(not preview.visible and preview.rectangles.is_empty(), "Leaving main area clears the highlight")
	expect(Layout.find(plan.tree, "b").stashed, "Outside drop still commits as a stash")
	tree.tiling = false
	point = Vector2(100, 200)
	plan = Layout.preview_placement(tree, Layout.leaf("b"), Rect2(point, Vector2(320, 200)), area, point)
	preview.present(plan, area, point)
	expect(not preview.visible, "Free layout never highlights a tiling target")
	preview.free()


func test_nested_splits_resize_without_moving_stashes() -> void:
	var stash := Rect2(1800, -240, 400, 300)
	var tree := {
		"windows": [
			Layout.leaf("a"),
			Layout.leaf("b"),
			Layout.leaf("c"),
			{ "pane": "stash", "stashed": true, "rect": stash },
		],
		"tiling": true,
	}
	tree.tiles = Layout.split_tile({ }, "", "a", "h")
	tree.tiles = Layout.split_tile(tree.tiles, "a", "b", "h")
	tree.tiles = Layout.split_tile(tree.tiles, "b", "c", "v")
	for size in [Vector2(1280, 720), Vector2(900, 1200), Vector2(1800, 900)]:
		var area := Rect2(Vector2(6, 80), size)
		var rects := { }
		Layout.arrange(tree, area, rects)
		expect(rects.stash == stash, "Resizing never relocates a stash")
		expect(rects.a.size.y == size.y, "Left branch spans the main area")
		expect(rects.b.end.y < rects.c.position.y, "Right branch is split vertically")
		for key in ["a", "b", "c"]:
			expect(area.encloses(rects[key]), "Tiles stay inside the current main area")
		for pair in [["a", "b"], ["a", "c"], ["b", "c"]]:
			expect(not rects[pair[0]].intersects(rects[pair[1]]), "Tiles never overlap")


func test_stash_rejoin_hide_and_remove_normalize_tree() -> void:
	var area := Rect2(0, 80, 1280, 640)
	var tree := {
		"windows": [Layout.leaf("a"), Layout.leaf("b"), Layout.leaf("c")],
		"tiling": true,
	}
	var rects := { }
	Layout.arrange(tree, area, rects)
	Layout.place(tree, "b", Rect2(-800, 100, 500, 400), area)
	Layout.arrange(tree, area, rects)
	expect("b" not in Layout.tile_keys(tree.tiles), "Stash leaves the tiling tree")
	expect(Layout.keys(tree).size() == 3, "Stash stays in the same tab")
	Layout.place(tree, "b", Rect2(200, 100, 500, 400), area, "a", "bottom")
	Layout.arrange(tree, area, rects)
	expect("b" in Layout.tile_keys(tree.tiles), "Restoring a stash joins the tiling tree")
	expect(rects.a.end.y < rects.b.position.y, "Drop below a pane creates a vertical split")
	Layout.find(tree, "b")["shown"] = false
	Layout.arrange(tree, area, rects)
	expect("b" not in Layout.tile_keys(tree.tiles), "Hidden panes do not reserve a tile")
	tree = Layout.remove(tree, "a")
	expect(tree.tiles == { "pane": "c" }, "Single-child containers collapse after removal")
	expect(tree.tiling, "Removing a window preserves the tab's tiling setting")


func test_same_direction_additions_share_equal_sibling_tiles() -> void:
	var tiles := Layout.split_tile({ }, "", "a", "h")
	tiles = Layout.split_tile(tiles, "a", "b", "h")
	tiles = Layout.split_tile(tiles, "b", "c", "h")
	var rects := { }
	Layout.tile_rectangles(tiles, Rect2(0, 0, 1200, 800), rects)
	expect(tiles.children.size() == 3, "Same-direction additions share one container")
	expect(
		is_equal_approx(rects.a.size.x, rects.b.size.x)
		and is_equal_approx(rects.b.size.x, rects.c.size.x),
		"Three horizontal siblings get equal space",
	)


func test_preview_is_pure_and_matches_commit() -> void:
	var area := Rect2(0, 80, 1200, 720)
	var tree := {
		"windows": [Layout.leaf("a"), Layout.leaf("b"), Layout.leaf("c")],
		"tiling": true,
	}
	var rects := { }
	Layout.arrange(tree, area, rects)
	var before := tree.duplicate(true)
	for edge in ["left", "right", "top", "bottom"]:
		var target: Rect2 = rects.b
		var point := target.get_center()
		match edge:
			"left":
				point.x = target.position.x + 4
			"right":
				point.x = target.end.x - 4
			"top":
				point.y = target.position.y + 4
			"bottom":
				point.y = target.end.y - 4
		var proposal := Layout.preview_placement(
			tree,
			Layout.leaf("c"),
			Rect2(point - Vector2(100, 80), Vector2(200, 160)),
			area,
			point,
		)
		expect(tree == before, "Hover never mutates the original tree")
		expect(proposal.edge == edge, "Preview follows the nearest pointer edge")
		var committed := { }
		Layout.arrange(proposal.tree, area, committed)
		expect(committed == proposal.rectangles, "Commit uses exactly the previewed geometry")
		for pair in [["a", "b"], ["a", "c"], ["b", "c"]]:
			expect(
				not committed[pair[0]].intersects(committed[pair[1]]),
				"Previewed tiles do not overlap",
			)
	var incoming := { "windows": [Layout.leaf("new"), Layout.leaf("chromium")] }
	var merged := Layout.preview_placement(
		tree,
		incoming,
		Rect2(500, 200, 320, 200),
		area,
		Vector2(510, 220),
	)
	expect(
		Layout.keys(merged.tree).size() == 5,
		"Merge preview includes the incoming terminal and attached chromium",
	)
	expect(Layout.keys(tree).size() == 3, "Merge hover leaves destination membership untouched")


func test_weighted_dividers_preserve_nested_layout_and_stashes() -> void:
	var area := Rect2(0, 80, 1200, 720)
	var tree := {
		"windows": [
			Layout.leaf("a"),
			Layout.leaf("b"),
			Layout.leaf("c"),
			{ "pane": "stash", "stashed": true, "rect": Rect2(-700, 0, 400, 300) },
		],
		"tiling": true,
		"tiles": {
			"axis": "h",
			"children": [
				{ "pane": "a" },
				{ "axis": "v", "children": [{ "pane": "b" }, { "pane": "c" }] },
			],
		},
	}
	var dividers := Layout.tile_dividers(tree.tiles, area)
	Layout.resize_tiles(tree.tiles, dividers[0], 160)
	var rects := { }
	Layout.arrange(tree, area, rects)
	expect(
		is_equal_approx(rects.a.size.x, 756),
		"Horizontal divider moves by the requested distance",
	)
	expect(
		is_equal_approx(rects.b.size.x, 436),
		"The neighboring branch shrinks by the same distance",
	)
	expect(rects.b.size == rects.c.size, "Nested children keep their relative sizes")
	dividers = Layout.tile_dividers(tree.tiles, area)
	Layout.resize_tiles(tree.tiles, dividers[1], 10000)
	Layout.arrange(tree, area, rects)
	expect(is_equal_approx(rects.c.size.y, 100), "Dragging beyond the edge clamps at the minimum")
	expect(is_equal_approx(rects.a.size.x, 756), "Nested divider does not resize the outer sibling")
	var ratio: float = rects.a.size.x / rects.b.size.x
	Layout.arrange(tree, Rect2(0, 80, 900, 1000), rects)
	expect(
		is_equal_approx(rects.a.size.x / rects.b.size.x, ratio),
		"Window resizing preserves proportions",
	)
	expect(rects.stash == Rect2(-700, 0, 400, 300), "Resizing leaves stash placement untouched")
	tree.tiles = Layout.split_tile(tree.tiles, "a", "new", "v")
	var resized := { }
	Layout.tile_rectangles(tree.tiles, Rect2(0, 80, 900, 1000), resized)
	expect(
		is_equal_approx(resized.a.size.x, rects.a.size.x),
		"Nested insertion preserves the parent's resized allocation",
	)
	var kept := Layout.tile_keys(tree.tiles)
	kept.erase("new")
	tree.tiles = Layout.prune_tiles(tree.tiles, kept)
	Layout.tile_rectangles(tree.tiles, Rect2(0, 80, 900, 1000), resized)
	expect(
		is_equal_approx(resized.a.size.x, rects.a.size.x),
		"Collapsing a branch preserves its outer weight",
	)
	Layout.balance_tiles(tree.tiles)
	Layout.arrange(tree, area, rects)
	expect(is_equal_approx(rects.a.size.x, rects.b.size.x), "Balance restores equal outer siblings")
	expect(
		is_equal_approx(rects.b.size.y, rects.c.size.y),
		"Balance restores equal nested siblings",
	)


func test_small_weighted_tiles_fit_without_overlapping() -> void:
	var node := {
		"axis": "h",
		"children": [
			{ "pane": "a", "weight": 2.0 },
			{ "pane": "b", "weight": 1.0 },
			{ "pane": "c", "weight": 3.0 },
		],
	}
	var rects := { }
	var area := Rect2(0, 0, 10, 10)
	Layout.tile_rectangles(node, area, rects)
	for rect in rects.values():
		expect(area.grow(0.001).encloses(rect), "Tiny viewports keep tiles in bounds")
	expect(
		not rects.a.intersects(rects.b) and not rects.b.intersects(rects.c),
		"Tiny tiles never overlap",
	)


func test_floating_resize_preserves_saved_tiling_weights() -> void:
	var area := Rect2(0, 80, 1200, 720)
	var tree := {
		"windows": [Layout.leaf("a"), Layout.leaf("b")],
		"tiling": false,
		"tiles": {
			"axis": "h",
			"children": [{ "pane": "a", "weight": 0.7 }, { "pane": "b", "weight": 0.3 }],
		},
	}
	var saved: Dictionary = tree.tiles.duplicate(true)
	Layout.place(tree, "a", Rect2(0, 80, 900, 500), area)
	expect(tree.tiles == saved, "Free resizing retains the last tiled split and weights")
	tree.tiling = true
	var rects := { }
	Layout.arrange(tree, area, rects)
	expect(
		is_equal_approx(rects.a.size.x / rects.b.size.x, 7.0 / 3.0),
		"Re-enabling tiling restores saved proportions",
	)


func test_configured_gap_applies_inside_and_outside_and_resizes() -> void:
	var tree := { "windows": [Layout.leaf("a"), Layout.leaf("b")], "tiling": true }
	var area := Rect2(0, 40, 1200, 800)
	for gap in [0.0, 8.0, 24.0, 128.0]:
		tree["tiling_gap"] = gap
		var rects := {}
		Layout.arrange(tree, area, rects)
		expect(is_equal_approx(rects.a.position.x, gap), "Left outer gap matches config")
		expect(is_equal_approx(rects.a.position.y, area.position.y + gap), "Top outer gap matches config")
		expect(is_equal_approx(rects.b.end.x, area.end.x - gap), "Right outer gap matches config")
		expect(is_equal_approx(rects.b.end.y, area.end.y - gap), "Bottom outer gap matches config")
		expect(is_equal_approx(rects.b.position.x - rects.a.end.x, gap), "Inner gap matches config")
		var dividers := Layout.tile_dividers(tree.tiles, Layout.tiling_area(tree, area), [], gap)
		Layout.resize_tiles(tree.tiles, dividers[0], 20)
		Layout.arrange(tree, area, rects)
		expect(is_equal_approx(rects.b.position.x - rects.a.end.x, gap), "Resize preserves configured gap")
		var tiny := Layout.tiling_area(tree, Rect2(0, 0, 10, 10))
		expect(tiny.size.x > 0 and tiny.size.y > 0, "Tiny windows retain a positive tiling area")


func test_new_tab_default_never_overwrites_existing_choices() -> void:
	var layout := Layout.new()
	layout.ensure_terminal(0, true)
	layout.ensure_terminal(1, false)
	layout.ensure_terminal(0, false)
	layout.ensure_terminal(1, true)
	expect(layout.tab(0).tree.tiling, "Revisiting an existing tab preserves tiling")
	expect(not layout.tab(1).tree.tiling, "Revisiting an existing tab preserves floating")
	layout.tab(0).tree.tiling = false
	layout.ensure_terminal(2, true)
	expect(not layout.tab(0).tree.tiling, "A new tab never changes the old one")
	expect(layout.tab(2).tree.tiling, "A local toggle never changes a new tab's default")


func test_tiling_startup_default_round_trip() -> void:
	var Loader := preload("res://config/UserConfig.gd")
	var disabled := PackedStringArray([client_toml("tiling", "[tiling]\nenabled = false\n")])
	expect(not Loader.tiling_config(disabled).enabled, "client.toml sets the startup default")
	expect(Loader.tiling_config(PackedStringArray()).enabled, "New tabs tile by default")
