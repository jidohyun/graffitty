extends SceneTree
## Pixel regression: both compositor paths fill every edge without 3D geometry.
var failures := 0

func check(ok: bool, message: String) -> void:
	if not ok: failures += 1
	print("PASS " if ok else "FAIL ", message)

func _initialize() -> void:
	run.call_deferred()

func snapshot(vp: SubViewport) -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()

func close_color(a: Color, b: Color) -> bool:
	return maxf(maxf(absf(a.r-b.r), absf(a.g-b.g)), maxf(absf(a.b-b.b), absf(a.a-b.a))) < 0.012

func run() -> void:
	var clear := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	clear.fill(Color(0, 0, 0, 0))
	var empty := ImageTexture.create_from_image(clear)
	var wallpaper := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 128:
			wallpaper.set_pixel(x, y, Color.RED if x < 32 else (Color.BLUE if x >= 96 else Color.GREEN))
	for shader in [preload("res://scenes/scenery_composite.gdshader"), preload("res://scenes/terminal_ink_composite.gdshader")]:
		var vp := SubViewport.new()
		vp.size = Vector2i(128, 64)
		vp.transparent_bg = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(vp)
		var rect := TextureRect.new()
		rect.texture = empty
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		vp.add_child(rect)
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("scenery_texture", empty)
		rect.material = mat
		var label: String = shader.resource_path.get_file()
		for dimensions in [Vector2i(128, 64), Vector2i(64, 128)]:
			vp.size = dimensions
			for opacity in [0.0, 0.35, 1.0]:
				var fill := Color(0.3, 0.5, 0.8, opacity)
				mat.set_shader_parameter("world_background", fill)
				var expected: Color = (fill.srgb_to_linear() * opacity).linear_to_srgb()
				expected.a = opacity
				var image := await snapshot(vp)
				var matches := true
				for y in image.get_height():
					for x in image.get_width():
						matches = matches and close_color(image.get_pixel(x, y), expected)
				check(matches, "%s %s opacity=%s covers every pixel with exact color/alpha (actual=%s expected=%s)" % [label, dimensions, opacity, image.get_pixel(0, 0), expected])
			mat.set_shader_parameter("world_background", Color.WHITE)
			mat.set_shader_parameter("wallpaper_enabled", true)
			mat.set_shader_parameter("wallpaper_texture", ImageTexture.create_from_image(wallpaper))
			var image := await snapshot(vp)
			var tall: bool = dimensions.y > dimensions.x
			check(close_color(image.get_pixel(0, 0), Color.GREEN if tall else Color.RED), label + " wallpaper covers top-left after resize")
			check(close_color(image.get_pixel(dimensions.x-1, dimensions.y-1), Color.GREEN if tall else Color.BLUE), label + " wallpaper covers bottom-right after resize")
			check(close_color(image.get_pixel(dimensions.x/2, dimensions.y/2), Color.GREEN), label + " wallpaper preserves centered cover crop")
			mat.set_shader_parameter("wallpaper_enabled", false)
		# Straight-alpha image pixels must be multiplied by configured opacity once.
		clear.fill(Color(1, 1, 1, 0.5))
		mat.set_shader_parameter("wallpaper_texture", ImageTexture.create_from_image(clear))
		mat.set_shader_parameter("wallpaper_enabled", true)
		mat.set_shader_parameter("world_background", Color(1, 1, 1, 0.4))
		var translucent := await snapshot(vp)
		check(absf(translucent.get_pixel(0, 0).a - 0.2) < 0.01, label + " wallpaper alpha multiplies window opacity once")
		vp.queue_free()
		await process_frame
	print("WORLD_BACKGROUND_PASS" if failures == 0 else "WORLD_BACKGROUND_FAIL")
	quit(failures)
