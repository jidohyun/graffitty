# Regenerate from the actual Godot implementation, never from the Rust port:
# godot --headless --path frontends/godot/project --script <absolute path to this file>
extends SceneTree
const Geometry = preload("res://scenes/GraphLinkGeometry.gd")
func pack(points) -> Array:
	var result: Array = []
	for point in points: result.append([point.x, point.y])
	return result
func _initialize() -> void:
	var fixtures: Array = []
	var pairs := [[Vector2(100, 200), Vector2(620, 340)], [Vector2(90, 500), Vector2(510, 80)], [Vector2(120, 100), Vector2(700, 100)], [Vector2(200, 50), Vector2(200, 550)], [Vector2(600, 90), Vector2(60, 120)], [Vector2(100, 100), Vector2(110, 120)], [Vector2.ZERO, Vector2.ZERO], [Vector2(-450, -800), Vector2(40, 500)]]
	for pair in pairs:
		var a: Vector2 = pair[0]
		var b: Vector2 = pair[1]
		for mode in ["plain", "arrival", "directed", "feedback"]:
			var control: PackedVector2Array = Geometry.controls(a, b)
			if mode == "arrival": control = Geometry.arrival_controls(a, b)
			if mode == "directed": control = Geometry.directed_controls(a, b, Vector2(0.6, 0.8), Vector2(-0.8, 0.6))
			var points: PackedVector2Array = Geometry.sample_controls(control)
			var return_y := maxf(a.y, b.y) + 130.0
			if mode == "feedback": points = Geometry.feedback_curve(a, b, return_y, 58.0, true).points
			var lengths := Geometry.distances(points)
			fixtures.append({"mode":mode,"a":pack([a])[0],"b":pack([b])[0],"return_y":return_y,"control":pack(control),"points":pack(points),"lengths":Array(lengths),"arrow":pack(Geometry.path_arrow(points)),"sample":pack([Geometry.at_distance(points,lengths,lengths[-1]*0.371)])})
	var output := FileAccess.open(get_script().resource_path.get_base_dir().path_join("graph-geometry-godot.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify({"source":"GraphLinkGeometry.gd", "fixtures":fixtures}, "\t") + "\n")
	quit()
