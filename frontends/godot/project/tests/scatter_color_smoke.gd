extends "scatter_visibility_smoke.gd"
## Compare the shipping live sheet and animation at the assembled pose. Include
## coloured, dim and antialiased ink: opaque white alone hides a colour-space bug.
class CellGrid extends Node:
	var cell_padding := 0
	func get_grid_size() -> Vector2i: return Vector2i(16, 16)
	func get_cell_size() -> Vector2: return Vector2(16, 16)

func snapshot(view: SubViewport, label: String) -> Image:
	for _frame in range(3): await process_frame
	await RenderingServer.frame_post_draw
	var shot := view.get_texture().get_image()
	var folder := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not folder.is_empty(): shot.save_png(folder.path_join(label + ".png"))
	return shot

func compare(live: Image, animated: Image, label: String) -> void:
	var maximum := 0.0
	var total := 0.0
	var count := 0
	for y in live.get_height():
		for x in live.get_width():
			var a := live.get_pixel(x, y)
			var b := animated.get_pixel(x, y)
			if maxf(a.a, b.a) < 0.01: continue
			var error := maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))
			maximum = maxf(maximum, error)
			total += error
			count += 1
	check(count > 1000 and maximum < 0.012 and total / maxf(count, 1) < 0.002,
		"%s preserves coloured and dim ink: %d pixels, max %.6f, mean %.6f" % [label, count, maximum, total / maxf(count, 1)])

func run() -> void:
	var source := viewport(false)
	source.use_hdr_2d = true
	for row in 4:
		var label := Label.new()
		label.text = "Host"
		label.position = Vector2(16, row * 60)
		label.add_theme_font_size_override("font_size", 48)
		label.add_theme_color_override("font_color", [Color("80b9ad"), Color("ffd47a"), Color("86a8ff"), Color("d8dade")][row])
		label.modulate.a = 0.45 if row % 2 else 1.0
		label.visibility_layer = 1 << 18
		source.add_child(label)
	var view := viewport(true)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 5.0
	view.add_child(camera)
	var live := MeshInstance3D.new()
	live.mesh = QuadMesh.new()
	live.mesh.size = Vector2(2, 2)
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/terminal_sheet.gdshader")
	material.set_shader_parameter("terminal_tex", source.get_texture())
	material.set_shader_parameter("tex_size", Vector2(source.size))
	material.set_shader_parameter("wall_shade", 0.0)
	live.material_override = material
	view.add_child(live)
	var reference := await snapshot(view, "3d-live")
	live.hide()
	var piece := Pieces.new()
	view.add_child(piece)
	var whole := Rect2(0, 0, 256, 256)
	var cells: Array = []
	for y in 16:
		for x in 16: cells.append(Vector3i(x, y, 1))
	var blocks: Array = Pieces.limit_layers([cells], 12)[0]
	var grid := CellGrid.new()
	piece.build_cells(grid, source, whole, Vector3(-1, 1, 0), Vector3(2, 0, 0), Vector3(0, -2, 0), blocks, Vector2.ZERO, Vector2.ZERO)
	grid.free()
	check(piece.multimesh.instance_count <= 12 and blocks.any(func(block): return block.w > 1), "Dense text uses bounded multiline pieces")
	Pieces.assign_release_ranks([piece])
	for i in blocks.size():
		check(1 + floori(piece.multimesh.get_instance_custom_data(i).a) == blocks[i].w, "Release timing preserves the block's row span")
	piece.enable_flight_volume()
	piece.set_progress(1.0)
	piece.set_appearance(1.0, 1.0)
	piece.set_thickness(0.16)
	piece._material().set_shader_parameter("grouped_flight", true)
	piece._material().set_shader_parameter("chunked_flight", true)
	compare(reference, await snapshot(view, "3d-departure"), "3D departure")
	piece._material().set_shader_parameter("arrival_flight", true)
	compare(reference, await snapshot(view, "3d-arrival"), "3D arrival handoff")
	var flat := viewport(false)
	flat.use_hdr_2d = true
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture = source.get_texture()
	sprite.material = ShaderMaterial.new()
	sprite.material.shader = preload("res://scenes/terminal_composite.gdshader")
	flat.add_child(sprite)
	var flat_reference := await snapshot(flat, "2d-live")
	sprite.hide()
	var transition := Transition2D.new()
	flat.add_child(transition)
	transition.panel(transition.capture(source, 1 << 18), whole, transition)
	transition.set_progress(0.0)
	compare(flat_reference, await snapshot(flat, "2d-arrival"), "2D arrival handoff")
	# A zoomed live terminal rasterizes only a crop. Its full-sheet capture must
	# retain the same density on the very first rendered transition frame.
	source.canvas_transform = Transform2D(Vector2(2, 0), Vector2(0, 2), Vector2(-64, -48))
	var zoomed := Pieces.capture(source, 1 << 18)
	# An existing transition intentionally keeps its own immutable state.
	var next_transition := Transition2D.new()
	flat.add_child(next_transition)
	var zoomed_2d := next_transition.capture(source, 1 << 18)
	var native := viewport(false)
	native.use_hdr_2d = true
	native.size = Vector2i(512, 512)
	native.size_2d_override = source.size
	native.size_2d_override_stretch = true
	# Independent controls redraw at this density. Reusing the source World2D
	# would merely enlarge its already-rasterized glyph commands.
	for child in source.get_children(): native.add_child(child.duplicate(0))
	native.canvas_cull_mask = 1 | (1 << 18)
	await RenderingServer.frame_post_draw
	check(zoomed.size == native.size and zoomed_2d.get_size() == Vector2(native.size), "Zoomed capture preserves the live crop's texel density in both views")
	var native_image := native.get_texture().get_image()
	if zoomed.size == native.size:
		compare(native_image, zoomed.get_texture().get_image(), "First zoomed 3D capture frame")
	if zoomed_2d.get_size() == Vector2(native.size):
		compare(native_image, zoomed_2d.get_image(), "First zoomed 2D capture frame")
	print("SCATTER_COLOR_PASS" if failures.is_empty() else "SCATTER_COLOR_FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
