extends SceneTree
const Graphics = preload('res://scenes/GraphicsPlane.gd')
const Camera = preload('res://scenes/TerminalCameraController.gd')
var failures: Array[String] = []


func check(ok: bool, message: String) -> void:
	print('[layers] ', 'PASS ' if ok else 'FAIL ', message)
	if not ok:
		failures.append(message)


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var size := Vector2(600, 400)
	var origin := Vector3(-3, 2, 0)
	var u := Vector3(.01, 0, 0)
	var v := Vector3(0, -.01, 0)
	var eye := Vector3(0, 0, 12)
	var resting := Graphics.projection(origin, u, v, size, eye, Vector2.ZERO, .04, 1.0)
	var zoomed := Graphics.projection(origin, u, v, size, eye, Vector2.ZERO, .08, 1.15, 2.0)
	check(
		not zoomed.is_equal_approx(resting),
		'Zoom alone lifts the image layer without camera lean',
	)
	var leaning := Graphics.projection(origin, u, v, size, eye, Vector2(.12, .08), .04, 1.0)
	var image_rect := Rect2(40, 60, 200, 120)
	check(
		Graphics.bounds(resting, image_rect).is_equal_approx(image_rect),
		'Images align exactly with text at rest',
	)
	check(
		Graphics.bounds(leaning, image_rect).size.x > image_rect.size.x,
		'Camera lean lifts the image layer toward the eye',
	)
	check(
		Graphics.point(leaning, size * .5).distance_to(size * .5) < .001,
		'Lift preserves the centred image anchor',
	)
	var camera := Camera.new()
	camera.follow_threshold = Vector2(.7, .7)
	var sheet := Vector2(1400, 900)
	camera.follow_rect = Rect2(40, 80, 640, 460)
	var left: Vector2 = camera._follow_target(Vector2(100, 300), sheet, 2, false)
	camera.follow_rect = Rect2(760, 80, 640, 460)
	var right: Vector2 = camera._follow_target(Vector2(820, 300), sheet, 2, false)
	check(
		absf(right.x - left.x - 720) < .001,
		'Identical cursor positions follow their own terminal instead of the whole space',
	)
	check(
		camera._follow_target(Vector2(820, 300), sheet, 1, false) == sheet * .5,
		'Resting camera still frames the whole workspace',
	)
	camera.free()

	OS.set_environment(
		'XDG_CONFIG_HOME',
		OS.get_cache_dir().path_join('graffitty-layers-%d' % OS.get_process_id()),
	)
	root.size = Vector2i(1200, 800)
	var host: Node = load('res://scenes/TerminalHost.gd').new()
	root.add_child(host)
	await create_timer(.6).timeout
	host.application.set_process(false)
	var world: Node = host.world
	world.set_process(false)
	var terminal: Node = host.active_terminal()
	check(
		terminal.has_method('set_image_plane_material'),
		'Native retained image layers accept an independent material',
	)
	if not terminal.has_method('set_image_plane_material'):
		quit(1)
		return
	var pixels := PackedByteArray()
	for i in 16:
		pixels.append_array(PackedByteArray([240, 40, 30, 255]))
	var payload := Marshalls.raw_to_base64(pixels)
	terminal.send_text(
		"printf '\\033[2J\\033[HOVERLAPPED TEXT AND IMAGES\\n\\033_Ga=T,f=32,s=4,v=4,c=16,r=7;"
		+ payload + "\\033\\\\'; sleep 30\n"
	)
	var placements: Array = []
	for i in 50:
		await create_timer(.1).timeout
		placements = terminal.image_placements()
		if not placements.is_empty():
			break
	check(not placements.is_empty(), 'Kitty graphics image is present in the live terminal')
	world.fx_cam_tilt = Vector2.ZERO
	world._sync_graphics_planes()
	var material: ShaderMaterial = terminal.get_meta('graphics_plane_material', null)
	check(material != null, 'Normal display keeps an independent image material')
	if material != null and not placements.is_empty():
		var dest: Rect2 = placements[0].dest
		check(
			Graphics.bounds(material.get_shader_parameter('plane_projection'), dest).is_equal_approx(
				dest
			),
			'Live image placement stays unchanged without lean',
		)
		world.fx_cam_tilt = Vector2(.12, .08)
		world.fx_plane_lift = .04
		world._sync_graphics_planes()
		check(
			not Graphics.bounds(material.get_shader_parameter('plane_projection'), dest).is_equal_approx(
				dest
			),
			'Normal display applies image parallax independently of the text',
		)
	world.fx_mat.set_shader_parameter('curvature_rad', deg_to_rad(8.0))
	if DisplayServer.get_name() != 'headless':
		world._update_ink_view()
		for i in 4:
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png('/tmp/graffitty-layers-live.png')
	var layers: Array = world._window_layers(
		host.pane_focus,
		world._effect_surface_frame(Vector2.ZERO).origin,
		world.uv_du,
		world.uv_dv,
	)
	check(not layers.is_empty(), 'Transition creates terminal layers')
	for layer in layers:
		check(
			is_equal_approx(
				float(layer._material().get_shader_parameter('source_curvature')),
				deg_to_rad(8.0),
			),
			'Transition layer shares the live sheet bend',
		)
	if DisplayServer.get_name() != 'headless':
		world.walls[world.surfaces[world.active].id].hide()
		for i in 4:
			await process_frame
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png('/tmp/graffitty-layers-assembled.png')
		world.walls[world.surfaces[world.active].id].show()
	for layer in layers:
		layer.queue_free()
	if DisplayServer.get_name() != 'headless':
		world.set_process(true)
		world.fx_last_key = world.fx_time
		await create_timer(.4).timeout
		RenderingServer.force_draw()
		root.get_texture().get_image().save_png('/tmp/graffitty-image-layer.png')
	print(
		(
			'WORKSPACE_LAYERS_PASS'
			if failures.is_empty()
			else 'WORKSPACE_LAYERS_FAIL: ' + str(failures)
		)
	)
	quit(0 if failures.is_empty() else 1)
