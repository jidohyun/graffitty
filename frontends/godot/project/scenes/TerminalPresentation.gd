extends RefCounted
## Native grid coordinates -> logical terminal texture pixels. The world then
## maps these pixels through the representation it is actually displaying.
static func grid_point(terminal: Control, uv: Vector2) -> Vector2:
	var area: Dictionary = terminal.get_visible_area()
	var grid: Vector2i = terminal.get_grid_size()
	var cell: Vector2 = terminal.get_cell_size()
	var origin: Vector2 = area.get("grid_origin", Vector2.ONE * float(terminal.cell_padding))
	return terminal.position + origin + uv * Vector2(grid) * cell
