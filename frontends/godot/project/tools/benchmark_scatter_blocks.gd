extends SceneTree
const Pieces := preload("res://scenes/CellShatter.gd")

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("scatter-benchmark-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated)
	for grid in [Vector2i(80, 40), Vector2i(160, 80)]:
		var cells: Array = []
		for y in grid.y:
			for x in grid.x: cells.append(Vector3i(x, y, 1))
		for mode in ["short_runs", "bounded"]:
			var samples: Array[float] = []
			var count := 0
			for repeat in 40:
				var start := Time.get_ticks_usec()
				var runs: Dictionary = Pieces.cell_runs(cells, 3) if mode == "short_runs" else Pieces.cell_runs(Pieces.limit_layers([cells], 96)[0], 3)
				# Include the instance writes that grouping is intended to reduce.
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_custom_data = true
				mm.mesh = QuadMesh.new()
				count = runs.positions.size()
				mm.instance_count = count
				for i in count:
					var at: Vector2i = runs.positions[i]
					mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3(runs.widths[i], runs.heights[i], 1)), Vector3(at.x, at.y, 0)))
					mm.set_instance_custom_data(i, Color(at.x, at.y, runs.widths[i], runs.heights[i]))
				if repeat >= 10: samples.append((Time.get_ticks_usec() - start) / 1000.0)
			samples.sort()
			print("SCATTER_BENCH ", JSON.stringify({"grid": str(grid), "mode": mode, "pieces": count, "median_setup_ms": samples[samples.size() / 2], "p95_setup_ms": samples[int(samples.size() * 0.95)]}))
	quit()
