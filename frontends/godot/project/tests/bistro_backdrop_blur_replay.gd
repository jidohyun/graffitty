extends "../../../../tests/llm-e2e/replay/replay.gd"

func play() -> void:
	var path := preload("res://config/UserConfig.gd").config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string("[worlds.bistro.terminal_window]\nblur_radius = 8\n")
	if not check(host.switch_world("bistro"), "Bistro loads"): return
	_stay_awake()
	await camera_at_rest()
	await hold(1.0)
	var world: Node = host.world
	check(world.ink_active, "Bistro uses the scenery/ink compositor")
	var material: ShaderMaterial = world.ink_overlay.material
	check(material.get_shader_parameter("backdrop_blur_radius") == 8.0, "Bistro config reaches the blur shader")
	# Freeze the camera and scenery so the comparison measures only the blur.
	world.set_process(false)
	RenderingServer.force_draw(false)
	world.scenery_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	material.set_shader_parameter("backdrop_blur_radius", 0.0)
	await hold(.2)
	var before := await screen_image()
	material.set_shader_parameter("backdrop_blur_radius", 8.0)
	await hold(.2)
	var after := await screen_image()
	if not check(before.get_size() == after.get_size(), "Comparison frames have matching dimensions"): return
	DirAccess.make_dir_recursive_absolute("res://artifacts")
	before.save_png("res://artifacts/bistro-blur-off.png")
	after.save_png("res://artifacts/bistro-blur-on.png")
	var changed := 0
	for y in range(100, before.get_height() - 100, 3):
		for x in range(100, before.get_width() - 100, 3):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > .01:
				changed += 1
	check(changed > 100, "Blur changes the rendered bistro backdrop (%d samples)" % changed)
