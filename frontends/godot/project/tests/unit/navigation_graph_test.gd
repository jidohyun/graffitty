extends "res://tests/unit/test_case.gd"

func test_graph_owns_snapshot_and_replaces_old_edges() -> void:
	var graph: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
	var adjacency: Array = [[[1, 1]], [[2, 1]], []]
	graph.replace(adjacency)
	adjacency[0].clear()
	expect(graph.route(0, 2) == PackedInt32Array([0, 1, 2]), "Graph owns its data after loading")
	graph.replace([[], [], []])
	expect(graph.route(0, 2).is_empty(), "Replacement discards old connections")
	graph.clear()
	expect(graph.route(0, 0).is_empty(), "Clear discards old nodes")
	expect(graph.route(-1, 0).is_empty(), "Negative node IDs are rejected")

func test_reweight_and_independent_worlds() -> void:
	var graph: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
	var other: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
	graph.replace([[[1, 1.0], [2, 3.0]], [[2, 1.0]], []])
	other.replace([[[2, 1.0]], [], []])
	expect(graph.route(0, 2) == PackedInt32Array([0, 1, 2]), "Initial weights choose the intermediate node")
	expect(not graph.reweight(PackedVector3Array([Vector3.ZERO])), "Mismatched positions are rejected")
	expect(graph.route(0, 2) == PackedInt32Array([0, 1, 2]), "Rejected update keeps previous weights")
	expect(graph.reweight(PackedVector3Array([Vector3.ZERO, Vector3(1,10,0), Vector3(2,0,0)])), "World positions update edge distances")
	expect(graph.route(0, 2) == PackedInt32Array([0, 2]), "Updated distances change the route")
	graph.clear()
	expect(other.route(0, 2) == PackedInt32Array([0, 2]), "Each world owns an independent graph")
