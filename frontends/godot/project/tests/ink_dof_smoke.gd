extends SceneTree
## Render thin strokes against transparency; blur must spread coverage in both
## axes without the sharp silhouettes or square holes of depth-edge rejection.
var failures := 0
func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()
func frame(view: SubViewport) -> Image:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()
func coverage(image: Image) -> float:
	var total := 0.0
	for y in image.get_height():
		for x in image.get_width(): total += image.get_pixel(x, y).a
	return total
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1
func run() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(256, 256)
	view.transparent_bg = true
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var display := TextureRect.new()
	display.texture = view.get_texture()
	root.add_child(display)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4
	camera.environment = Environment.new()
	camera.environment.background_mode = Environment.BG_CLEAR_COLOR
	camera.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	view.add_child(camera)
	var texture := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	texture.fill(Color.TRANSPARENT)
	texture.fill_rect(Rect2i(124, 100, 8, 56), Color.WHITE)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(4, 4)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always; uniform sampler2D source; void fragment() { vec4 c=texture(source,UV); if(c.a<.001)discard; ALBEDO=c.rgb; ALPHA=c.a; }"
	material.set_shader_parameter("source", ImageTexture.create_from_image(texture))
	quad.material_override = material
	quad.position.z = -2
	view.add_child(quad)
	var sharp := await frame(view)
	var lens := preload("res://scenes/InkDepthOfField.gd").new()
	camera.compositor = Compositor.new()
	camera.compositor.compositor_effects = [lens]
	lens.set_lens(1, 12, .5, 24)
	var blurred := await frame(view)
	check(sharp.get_pixel(120, 128).a < .001 and blurred.get_pixel(120, 128).a > .02, "Defocus spreads stroke coverage into transparent horizontal pixels")
	check(sharp.get_pixel(128, 96).a < .001 and blurred.get_pixel(128, 96).a > .01, "Defocus spreads stroke coverage into transparent vertical pixels")
	check(blurred.get_pixel(120, 96).a > .001, "Vertical blur carries horizontal coverage into rounded corners")
	check(blurred.get_pixel(124, 128).a < .8, "The original stroke edge is softened, not retained as a sharp silhouette")
	var ratio := coverage(blurred) / coverage(sharp)
	check(absf(ratio - 1.0) < .03, "Normalized blur preserves thin-stroke coverage: %.4f" % ratio)
	lens.set_lens(2, 12, .5, 24)
	var focused := await frame(view)
	check(absf(coverage(focused) / coverage(sharp) - 1.0) < .01 and focused.get_pixel(120, 128).a < .001, "In-focus strokes retain their original footprint")
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if not evidence.is_empty():
		sharp.save_png(evidence.path_join("sharp.png"))
		blurred.save_png(evidence.path_join("blurred.png"))
	# A focused stroke overlapping a defocused one must not collapse the vertical
	# footprint at its center into a cross-shaped streak.
	#
	# At (127,96), a normalized radius-12 2D convolution of the six unoccluded
	# columns gives alpha 0.09995; the focused line contributes zero.
	var narrow := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	narrow.fill(Color.TRANSPARENT)
	narrow.fill_rect(Rect2i(127, 100, 2, 56), Color.WHITE)
	var foreground := MeshInstance3D.new()
	foreground.mesh = quad.mesh
	foreground.material_override = material.duplicate()
	foreground.material_override.set_shader_parameter("source", ImageTexture.create_from_image(narrow))
	foreground.position.z = -1
	view.add_child(foreground)
	lens.set_lens(1, 12, .5, 24)
	var mixed := await frame(view)
	if not evidence.is_empty(): mixed.save_png(evidence.path_join("mixed.png"))
	check(absf(mixed.get_pixel(127, 96).a - .09995) < .01, "Mixed depths retain the expected two-dimensional blur coverage")
	# Adjacent release cohorts are only a few percent apart in depth while
	# still reading as a sheet. Their visible blur should agree at that point.
	foreground.visible = false
	quad.position.x = -.5
	var cohort := MeshInstance3D.new()
	cohort.mesh = quad.mesh
	cohort.material_override = material
	cohort.position = Vector3(.5, 0, -1.94)
	view.add_child(cohort)
	var transition := preload("res://scenes/TransitionInk.gd")
	check(transition.departure_lens(.0263, 8, 0).is_equal_approx(Vector2(.0263, 0)), "Departure starts with the exact captured lens")
	var optics := transition.departure_lens(.0263, 8, .08)
	lens.set_lens(2, 8, optics.x, 24, optics.y)
	var cohorts := await frame(view)
	var difference := 0.0
	for y in range(85, 171):
		for x in range(80, 112):
			difference = maxf(difference, absf(cohorts.get_pixel(x, y).a - cohorts.get_pixel(x + 64, y).a))
	check(difference < .015, "Nearby departure cohorts have coherent blur: %.4f" % difference)
	if not evidence.is_empty(): cohorts.save_png(evidence.path_join("cohorts.png"))
	await check_composition()
	view.queue_free()
	for i in 3: await process_frame
	quit(1 if failures else 0)

func solid(color: Color) -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func check_composition() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(16, 16)
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var display := TextureRect.new()
	display.texture = view.get_texture()
	root.add_child(display)
	var ink := TextureRect.new()
	ink.texture = solid(Color.BLUE)
	ink.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ink.size = Vector2(16, 16)
	ink.material = ShaderMaterial.new()
	ink.material.shader = preload("res://scenes/terminal_ink_composite.gdshader")
	ink.material.set_shader_parameter("scenery_texture", solid(Color.BLACK))
	ink.material.set_shader_parameter("transition_0", solid(Color.RED))
	ink.material.set_shader_parameter("transition_count", 1)
	view.add_child(ink)
	var behind := await frame(view)
	check(behind.get_pixel(8, 8).b > .95, "Arriving retained layer stays behind the live pane")
	ink.material.set_shader_parameter("transition_1", solid(Color.GREEN))
	ink.material.set_shader_parameter("transition_count", 2)
	ink.material.set_shader_parameter("transition_foreground_mask", 2)
	var front := await frame(view)
	check(front.get_pixel(8, 8).g > .95 and front.get_pixel(8, 8).b < .01, "Isolated departing fragments remain in front of the arriving/live pane")
	view.queue_free()
	display.queue_free()
