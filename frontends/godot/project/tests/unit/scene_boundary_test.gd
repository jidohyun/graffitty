extends "res://tests/unit/test_case.gd"

func test_camera_snapshots_cannot_mutate_native_state() -> void:
	var motion := CameraMotion.new()
	var start := CameraMotion.pose(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, Vector4(-.5,-.5,1,1))
	motion.reset(start)
	var snapshot := motion.frame
	snapshot.rect = Vector4.ZERO
	expect(motion.frame.rect == start.rect, "Returned frame cannot desynchronize displayed and native camera state")
	var destination := CameraMotion.pose(Vector3(10,0,0), Vector3.FORWARD, Vector3.UP, start.rect)
	motion.retarget(destination, 1.0)
	var target := motion._target
	target.transform = Transform3D.IDENTITY
	motion.advance(1.0)
	expect(motion.frame.transform == destination.transform, "Returned target cannot corrupt the final landing")
	var landed := motion.advance(0.0)
	landed.rect = Vector4.ZERO
	expect(motion.frame.rect == start.rect, "Advance returns a detached snapshot too")

func test_remote_mapping_accepts_nested_typed_collections() -> void:
	var core: RefCounted = ClassDB.instantiate("RemoteClientCore")
	core.bind_id(7, 70)
	var node: Dictionary[String, String] = {"pane": "%7"}
	var rows: Array[Dictionary] = [node]
	var graph: Dictionary[String, Array] = {"nodes": rows}
	var mapped: Dictionary = core.map_graph(graph, true, "", Callable())
	expect(mapped.nodes[0].pane == "%70", "Nested typed dictionaries cross the native boundary without conversion errors")
	expect(node.pane == "%7", "Mapping leaves the caller's typed graph intact")

func test_remote_mapping_accepts_string_name_keys_and_values() -> void:
	var core: RefCounted = ClassDB.instantiate("RemoteClientCore")
	core.bind_id(7, 70)
	var node: Dictionary[StringName, StringName] = {&"pane": &"%7", &"title": &"Named pane"}
	var graph := {"nodes": [node]}
	graph.focus = &"%7"
	var mapped: Variant = core.map_graph(graph, true, "", Callable())
	if not expect(mapped is Dictionary, "StringName keys and values cross the native JSON boundary"):
		return
	expect(mapped.nodes[0].pane == "%70" and mapped.focus == "%70", "Typed and dot-assigned keys preserve identifier translation")
	expect(mapped.nodes[0].title == "Named pane" and typeof(mapped.nodes[0].keys()[0]) == TYPE_STRING, "StringName values and keys become ordinary JSON strings")
	expect(node.pane == &"%7", "Conversion does not modify the original dictionary")

func test_remote_mapping_rejects_non_string_keys() -> void:
	var core: RefCounted = ClassDB.instantiate("RemoteClientCore")
	expected_errors.append("Expected string dictionary key")
	expect(core.map_graph({"nested": {7: "invalid"}}, false, "", Callable()) == null, "Non-string keys remain invalid at the JSON boundary")

func test_fuzzy_candidate_replacement_and_independent_models() -> void:
	var first := preload("res://scenes/CommandLineModel.gd").new()
	var second := preload("res://scenes/CommandLineModel.gd").new()
	expect(first.rank("alpha", PackedStringArray(["alpha", "beta"]), false)[0].index == 0, "First candidate set is loaded")
	expect(second.rank("alpha", PackedStringArray(["beta", "alpha"]), false)[0].index == 1, "Each model owns its candidate set")
	expect(first.rank("beta", PackedStringArray(["alpha", "beta"]), false)[0].index == 1, "Query changes reuse the candidate set")
	expect(first.rank("beta", PackedStringArray(["beta", "alpha"]), false)[0].index == 0, "Reordering replaces cached candidate indices")
	expect(first.rank("beta", PackedStringArray(), false).is_empty(), "Removing all candidates clears native state")
