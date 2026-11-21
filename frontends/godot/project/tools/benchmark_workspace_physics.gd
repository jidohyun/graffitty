extends SceneTree
## Solver microbenchmark: local drag in sparse workspaces, then a dense cluster.
## godot --headless --path . --script tools/benchmark_workspace_physics.gd
const Physics := preload("res://scenes/WorkspacePhysics.gd")


func _initialize() -> void:
	for topology in ["sparse", "dense"]:
		for count in [4, 12, 24, 64, 128, 512]:
			if topology == "dense" and count > 128:
				continue
			var rects := {}
			var movable := {}
			for i in count:
				var key := str(i)
				rects[key] = Rect2((i % 8) * 230, (i / 8) * 150, 320, 200) if topology == "dense" else Rect2(i * 1000, 0, 320, 200)
				if i != 0:
					movable[key] = false
			if topology == "sparse":
				rects["1"] = Rect2(280, 0, 320, 200)
			var area := Rect2(-1000, -1000, count * 1000 + 2000, 4000) if topology == "sparse" else Rect2(0, 0, 1920, 1080)
			var solver := Physics.new()
			rects = solver.step(rects, movable, area, 1.0 / 60)
			var samples: Array[float] = []
			var checks := 0.0
			for batch in 10:
				var start := Time.get_ticks_usec()
				for tick in 100:
					rects["0"].position.x += 0.1
					rects = solver.step(rects, movable, area, 1.0 / 60)
					checks += solver.pair_checks
				samples.append(float(Time.get_ticks_usec() - start) / 100)
			samples.sort()
			print(JSON.stringify({"panes": count, "topology": topology, "median_us": samples[5], "max_batch_us": samples[-1], "mean_pair_checks": checks / 1000, "one_core_percent_at_60hz": samples[5] * 60 / 10000}))
	quit()
