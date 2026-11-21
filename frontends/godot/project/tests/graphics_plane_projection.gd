extends SceneTree
## Run with a graphical renderer: godot --path . --script tests/graphics_plane_projection.gd
## A mid-tone image must retain its color after perspective projection; sampling
## both the original and projected UV multiplies colors and creates ghost images.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var pixels := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var colors := [Color(0.8, 0.4, 0.2), Color(0.2, 0.6, 0.8)]
	for y in 64:
		for x in 64:
			pixels.set_pixel(x, y, colors[(x / 16 + y / 16) % 2])
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = ImageTexture.create_from_image(pixels)
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/graphics_plane.gdshader")
	var projection := Basis(Vector3(1.4, 0, 0.006), Vector3(0, 1.4, 0), Vector3(16, 16, 1))
	material.set_shader_parameter("plane_projection", projection)
	sprite.material = material
	viewport.add_child(sprite)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var rendered := viewport.get_texture().get_image()
	var failures := 0
	for y in [8, 24, 40, 56]:
		for x in [8, 24, 40, 56]:
			var projected := projection * Vector3(x, y, 1)
			var at := Vector2i(Vector2(projected.x, projected.y) / projected.z)
			var actual := rendered.get_pixelv(at)
			var expected := pixels.get_pixel(x, y)
			if Vector3(actual.r, actual.g, actual.b).distance_to(Vector3(expected.r, expected.g, expected.b)) > 0.04:
				failures += 1
				push_error("Projected image color changed at %s: %s expected %s" % [at, actual, expected])
	print("GRAPHICS_PLANE_PROJECTION_PASS" if failures == 0 else "GRAPHICS_PLANE_PROJECTION_FAIL")
	quit(0 if failures == 0 else 1)
