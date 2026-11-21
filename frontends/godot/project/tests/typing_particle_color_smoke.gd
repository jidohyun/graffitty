extends SceneTree
## Compare a frozen opaque particle with the same sRGB tint drawn by Godot.
const TINT := Color(0.50, 0.68, 0.84)
const EXTENT := 120

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Particle color checks need a renderer that draws pixels")
		quit(1)
		return
	var matched := true
	for spatial in [false, true]:
		var view := SubViewport.new()
		view.size = Vector2i(EXTENT, EXTENT)
		view.transparent_bg = true
		view.use_hdr_2d = true
		root.add_child(view)
		var instances: MultiMesh
		if spatial:
			view.world_3d = World3D.new()
			var camera := Camera3D.new()
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = EXTENT
			camera.position.z = 100
			view.add_child(camera)
			var particles := preload("res://scenes/TerminalParticles.gd").new()
			view.add_child(particles)
			var shader_material := ShaderMaterial.new()
			shader_material.shader = preload("res://scenes/terminal_particles.gdshader")
			particles.mesh.material_override = shader_material
			instances = particles.mesh.multimesh
			instances.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(-28, 0, 0)))
			var swatch := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.size = Vector2(32, 32)
			swatch.mesh = quad
			var material := StandardMaterial3D.new()
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.albedo_color = TINT
			swatch.material_override = material
			swatch.position.x = 28
			view.add_child(swatch)
		else:
			view.disable_3d = true
			var particles := preload("res://scenes/TerminalParticles2D.gd").new()
			view.add_child(particles)
			instances = particles.mesh.multimesh
			instances.set_instance_transform_2d(0, Transform2D(0.0, Vector2(32, 60)))
			var swatch := ColorRect.new()
			swatch.color = TINT
			swatch.position = Vector2(72, 44)
			swatch.size = Vector2(32, 32)
			view.add_child(swatch)
		instances.set_instance_color(0, TINT)
		instances.set_instance_custom_data(0, Color(32, 1, 0, -1))
		instances.visible_instance_count = 1
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		for draw in 3: await RenderingServer.frame_post_draw
		var pixels := view.get_texture().get_image()
		var dot := pixels.get_pixel(32, 60)
		var reference := pixels.get_pixel(88, 60)
		var delta := (Vector3(dot.r, dot.g, dot.b) - Vector3(reference.r, reference.g, reference.b)).abs()
		var ok := dot.a > 0.99 and reference.a > 0.99 and delta[delta.max_axis_index()] < 0.015
		print("%s %s typing particle %s, reference %s" % ["PASS" if ok else "FAIL", "3D" if spatial else "2D", dot, reference])
		matched = matched and ok
		view.free()
	quit(0 if matched else 1)
