@tool
extends "res://scenes/TerminalSurface3D.gd"
## A ready-made terminal destination, including its editable camera pose.
## Optional approach path uses world geometry; the shared rig owns animation.
@export_node_path("Path3D") var approach_path: NodePath


func camera_route_from(eye_position: Vector3) -> PackedVector3Array:
	var points := PackedVector3Array()
	if approach_path.is_empty(): return points
	var path := get_node_or_null(approach_path) as Path3D
	if path == null or path.curve == null or path.curve.point_count < 2: return points
	var start := path.curve.get_closest_offset(path.to_local(eye_position))
	var length := path.curve.get_baked_length()
	var steps := clampi(ceili((length - start) / 1.0), 1, 64)
	for i in range(steps + 1):
		points.append(path.to_global(path.curve.sample_baked(lerpf(start, length, float(i) / steps))))
	return points
