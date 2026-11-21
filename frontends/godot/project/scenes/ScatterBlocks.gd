extends RefCounted
## Fixed spatial bins over the existing glyph list: no sorting, word parsing,
## texture readback, or per-frame work. Drop cuts that would bisect wide glyphs.
static func build(cells: Array, maximum: int) -> Array:
	if cells.is_empty(): return []
	maximum = maxi(maximum, 1)
	var left := 2147483647
	var top := 2147483647
	var right := 0
	var bottom := 0
	for cell in cells:
		left = mini(left, cell.x)
		top = mini(top, cell.y)
		right = maxi(right, cell.x + cell.z)
		bottom = maxi(bottom, cell.y + 1)
	var width := right - left
	var height := bottom - top
	# Terminal cells are roughly twice as tall as they are wide.
	var columns := clampi(ceili(sqrt(float(maximum * width) / (height * 2))), 1, mini(width, maximum))
	var rows := mini(height, maxi(1, maximum / columns))
	var cuts := PackedByteArray()
	cuts.resize(width)
	for i in range(1, columns): cuts[width * i / columns] = 1
	for cell in cells:
		for x in range(cell.x + 1, cell.x + cell.z): cuts[x - left] = 0
	var edges: Array[int] = [left]
	for x in width:
		if cuts[x]: edges.append(left + x)
	edges.append(right)
	var blocks: Array = []
	for y in rows:
		var y0 := top + height * y / rows
		var y1 := top + height * (y + 1) / rows
		for x in edges.size() - 1:
			blocks.append(Vector4i(edges[x], y0, edges[x + 1] - edges[x], y1 - y0))
	return blocks
