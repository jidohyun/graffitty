extends "res://tests/unit/test_case.gd"
const Layer := preload("res://scenes/GraphWireLayer.gd")

class Painter extends Node2D:
	var batches: Array[PackedVector2Array] = []
	func polyline(_points: PackedVector2Array, _color: Color, _width: float, _antialiased: bool) -> void:
		pass
	func multiline(points: PackedVector2Array, _color: Color, _width: float, _antialiased: bool) -> void:
		batches.append(points)

func test_collapsed_dashed_wire_does_not_submit_empty_multiline() -> void:
	var overlay := preload("res://scenes/AgentGraphOverlay.gd").new()
	var painter := Painter.new()
	var start := Vector2(100, 200)
	overlay.draw_wire(painter, PackedVector2Array([start, start]), Color.WHITE, 3.0, true)
	expect(painter.batches.is_empty(), "Coincident drag endpoints do not reach draw_multiline")
	overlay.draw_wire(painter, PackedVector2Array([start, start + Vector2(40, 0)]), Color.WHITE, 3.0, true)
	expect(painter.batches.size() == 1 and painter.batches[0].size() >= 2
		and painter.batches[0].size() % 2 == 0, "Dragging away from the port draws complete dash pairs")
	painter.free()
	overlay.free()

func test_retained_multiline_rejects_incomplete_endpoint_pairs() -> void:
	var layer := Layer.new()
	layer.frozen = true
	layer.multiline(PackedVector2Array(), Color.WHITE)
	layer.multiline(PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2(2, 2)]), Color.WHITE)
	expect(layer.commands.is_empty(), "Invalid batches cannot be retained for a later draw")
	layer.multiline(PackedVector2Array([Vector2.ZERO, Vector2.ONE]), Color.WHITE)
	expect(layer.commands.size() == 1, "A valid endpoint pair is retained")
	layer.free()

func test_zoom_width_changes_reuse_the_ribbon_style_texture() -> void:
	var layer := Layer.new()
	layer.frozen = true
	var path := PackedVector2Array([Vector2.ZERO, Vector2(100, 0)])
	var styles := [[Color.RED, "solid"], [Color.BLUE, "dashed"]]
	layer.patterned_ribbon(path, styles, 8.0, 1.0)
	var texture: Texture2D = layer.commands[0][1][3]
	layer.commands.clear()
	layer.patterned_ribbon(path, styles, 40.0, 5.0)
	expect(layer.commands[0][1][3] == texture, "Zooming changes geometry without uploading the color/pattern texture again")
	styles[1][1] = "dotted"
	layer.commands.clear()
	layer.patterned_ribbon(path, styles, 40.0, 5.0)
	expect(layer.commands[0][1][3] != texture, "Changing delivery style refreshes the texture")
	layer.free()

func test_distant_pulse_uses_local_geometry_without_moving_its_center() -> void:
	var layer := Layer.new()
	layer.frozen = true
	var center := Vector2(100000,500000)
	layer.circle(center,1.55,Color.WHITE)
	expect(layer.commands.size()==3,"A visible pulse records a transform, polygon, and reset")
	if layer.commands.size()==3:
		var origin: Vector2 = layer.commands[0][1][0]
		var vertices: PackedVector2Array = layer.commands[1][1][0]
		expect(vertices[0]==Vector2.ZERO,"Triangulation starts at a local origin")
		expect(origin.distance_to(center+Vector2(1.55,0))<.02,"The local transform preserves the pulse position")
		expect(not Geometry2D.triangulate_polygon(vertices).is_empty(),"The distant small pulse is triangulatable")
		expect(layer.commands[2][1][0]==Vector2.ZERO,"The next wire inherits no drawing offset")
	layer.free()

func test_collapsed_projection_does_not_submit_an_invalid_polygon() -> void:
	var layer := Layer.new()
	layer.frozen = true
	layer.unproject = func(_point): return Vector2(12,34)
	layer.circle(Vector2(300,400),3.2,Color.WHITE)
	expect(layer.commands.is_empty(),"A collapsed offscreen pulse cannot open a rendering diagnostic")
	layer.free()
