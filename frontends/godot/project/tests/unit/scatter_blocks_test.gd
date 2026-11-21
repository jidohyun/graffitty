extends "res://tests/unit/test_case.gd"
const Blocks := preload("res://scenes/ScatterBlocks.gd")
const Pieces := preload("res://scenes/CellShatter.gd")

func test_dense_multiline_blocks_cover_each_wide_glyph_once() -> void:
	var cells: Array = []
	for y in 47:
		var x := y % 5
		while x < 97:
			var width := 2 if (x + y) % 3 == 0 else 1
			cells.append(Vector3i(x, y, width))
			x += width + (1 if x % 7 == 0 else 0)
	# Semantic batches need not arrive in grid order.
	cells.reverse()
	for budget in [1, 12, 48, 96]:
		var blocks := Blocks.build(cells, budget)
		expect(blocks.size() <= budget, "Piece count respects budget %d" % budget)
		expect(blocks.any(func(block): return block.w > 1), "Dense content uses multiline blocks")
		for i in blocks.size():
			var block: Vector4i = blocks[i]
			var rect := Rect2i(block.x, block.y, block.z, block.w)
			for j in range(i + 1, blocks.size()):
				var other: Vector4i = blocks[j]
				expect(not rect.intersects(Rect2i(other.x, other.y, other.z, other.w)), "Blocks never duplicate texture pixels")
		for cell in cells:
			var owners := 0
			for block: Vector4i in blocks:
				if Rect2i(block.x, block.y, block.z, block.w).encloses(Rect2i(cell.x, cell.y, cell.z, 1)): owners += 1
			expect(owners == 1, "Each glyph, including wide glyphs, belongs whole to exactly one block")

func test_sparse_layers_keep_the_existing_short_runs() -> void:
	var layers := [[Vector3i(0, 0, 1), Vector3i(1, 0, 1)], [Vector3i(2, 0, 2)]]
	expect(Pieces.limit_layers(layers, 96) == layers, "Sparse styled/CJK layers keep their existing choreography")
	expect(Blocks.build([], 96).is_empty(), "An empty terminal has no blocks")

func test_combined_layers_obey_one_budget_and_keep_block_heights() -> void:
	var layers: Array = [[], [], [], [], []]
	for y in 40:
		for x in 80: layers[(x + y) % 5].append(Vector3i(x, y, 1))
	var bounded := Pieces.limit_layers(layers, 96)
	var runs := Pieces.cell_runs(bounded[0], 3)
	expect(runs.positions.size() <= 96, "Five semantic layers share one budget")
	expect(bounded.slice(1).all(func(layer): return layer.is_empty()), "Mixed blocks are captured only once")
	expect(Array(runs.heights).any(func(height): return height > 1), "Cell emission retains multiline heights")

func test_default_preserves_fine_scatter_on_dense_text() -> void:
	var effects = preload("res://scenes/Effects.gd").new()
	expect(effects.scene.session_switch.max_blocks == 0, "Large blocks are opt-in")
	var cells: Array = []
	for y in 40:
		for x in 80: cells.append(Vector3i(x, y, 1))
	var layers: Array = [cells, [Vector3i(0, 41, 2)]]
	expect(Pieces.limit_layers(layers, 0) == layers, "Disabled budget preserves dense cells and semantic layers")
