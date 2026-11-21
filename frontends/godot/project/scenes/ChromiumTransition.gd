extends RefCounted


## A single page quad and small toolbar tiles. Only the toolbar may scatter.
static func mesh(size: Vector2, chrome_fraction: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var rects: Array[Rect2] = [Rect2(0, chrome_fraction, 1, 1 - chrome_fraction)]
	for y in 2:
		for x in 12:
			rects.append(
				Rect2(float(x) / 12, float(y) * chrome_fraction / 2, 1.0 / 12, chrome_fraction / 2)
			)
	for i in rects.size():
		var rect := rects[i]
		var center := rect.get_center()
		for corner in [
			Vector2(0, 0),
			Vector2(1, 0),
			Vector2(0, 1),
			Vector2(1, 0),
			Vector2(1, 1),
			Vector2(0, 1),
		]:
			var uv: Vector2 = rect.position + corner * rect.size
			vertices.append(Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0))
			uvs.append(uv)
			colors.append(Color(center.x, center.y / chrome_fraction, 0, 0 if i == 0 else 1))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
