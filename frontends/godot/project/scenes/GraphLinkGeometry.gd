# SPDX-FileCopyrightText: 2005 Blender Authors
# SPDX-FileCopyrightText: 2018-2023 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
extends RefCounted
## Godot adapter for shared geometry based on Blender a5d2d415d03098df760257ee3931001223dfd32a:
## source/blender/editors/space_node/drawnode.cc: calculate_inner_link_bezier_points
## source/blender/gpu/shaders/gpu_shader_nodelink.bsl.hh: point/tangent evaluation
## See docs/developers/automation-and-extensions/blender-node-links.md for provenance and adaptation boundaries.
const DEFAULT_CURVING := 4
const LINK_RESOLUTION := 24

static func _core() -> RefCounted:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_scene_geometry"):
		owner.set_meta("graffitty_scene_geometry", ClassDB.instantiate("SceneGeometry"))
	return owner.get_meta("graffitty_scene_geometry")

static func return_lanes(outputs: PackedVector2Array, keys: PackedStringArray, target: Vector2) -> PackedInt32Array:
	return _core().return_lanes(outputs, keys, target)

static func port_row_pitch(canvas_height: float, screen_height: float, count: int, hit_pitch: float) -> float:
	return _core().port_row_pitch(canvas_height, screen_height, count, hit_pitch)

static func dashed_segments(points: PackedVector2Array, dash := 10.0, gap := 6.0) -> PackedVector2Array:
	return _core().dashed_segments(points, dash, gap)

static func controls(a: Vector2, b: Vector2, curving := DEFAULT_CURVING) -> PackedVector2Array:
	return _core().controls(a, b, curving)

static func evaluate(control: PackedVector2Array, t: float) -> Vector2:
	return _core().evaluate(control, t)

static func tangent(control: PackedVector2Array, t: float) -> Vector2:
	return _core().tangent(control, t)

static func curve(a: Vector2, b: Vector2, curving := DEFAULT_CURVING) -> PackedVector2Array:
	return _core().curve(a, b, curving)

static func sample_controls(control: PackedVector2Array) -> PackedVector2Array:
	return _core().sample_controls(control)

static func distances(points: PackedVector2Array) -> PackedFloat32Array:
	return _core().distances(points)

static func at_distance(points: PackedVector2Array, lengths: PackedFloat32Array, distance: float) -> Vector2:
	return _core().at_distance(points, lengths, distance)

static func parameter_at_distance(lengths: PackedFloat32Array, distance: float) -> float:
	return _core().parameter_at_distance(lengths, distance)

static func arrow(control: PackedVector2Array, reverse := false) -> PackedVector2Array:
	return _core().arrow(control, reverse)

static func deform_endpoints(route: Dictionary, source_delta: Vector2, target_delta: Vector2) -> Dictionary:
	return _core().deform_endpoints(route, source_delta, target_delta)

static func interaction_curve(a: Vector2, b: Vector2) -> PackedVector2Array:
	return _core().interaction_curve(a, b)

static func feedback_curve(a: Vector2, b: Vector2, return_y: float = NAN, clearance := 40.0, natural_end := false) -> Dictionary:
	return _core().feedback_curve(a, b, return_y, clearance, natural_end)

static func smooth_step_same_side(a: Vector2, b: Vector2, side: float, clearance := 40.0) -> PackedVector2Array:
	return _core().smooth_step_same_side(a, b, side, clearance)

static func rounded_steps(vertices: PackedVector2Array, radius: float) -> PackedVector2Array:
	return _core().rounded_steps(vertices, radius)

static func directed_controls(a: Vector2, b: Vector2, outgoing: Vector2, incoming: Vector2) -> PackedVector2Array:
	return _core().directed_controls(a, b, outgoing, incoming)

static func path_arrow(points: PackedVector2Array, fraction := 0.5) -> PackedVector2Array:
	return _core().path_arrow(points, fraction)

static func arrival_direction(a: Vector2, b: Vector2) -> Vector2:
	return _core().arrival_direction(a, b)

static func arrival_controls(a: Vector2, b: Vector2) -> PackedVector2Array:
	return _core().arrival_controls(a, b)
