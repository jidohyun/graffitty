extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
	print("PASS " if ok else "FAIL ", message)

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var settings = preload("res://scenes/FlatWorldSettings.gd").new()
	check(settings.terminal_window.blur_radius == 0.0, "Blur defaults off")
	settings.terminal_window.blur_radius = -1
	check(not settings.validate().is_empty(), "Negative blur is rejected")
	settings.terminal_window.blur_radius = 33
	check(not settings.validate().is_empty(), "Excessive blur is rejected")
	var old_config := OS.get_environment("XDG_CONFIG_HOME")
	var config_root := OS.get_cache_dir().path_join("graffitty-blur-test-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", config_root)
	var paths := preload("res://config/UserConfig.gd")
	DirAccess.make_dir_recursive_absolute(paths.config_path().get_base_dir())
	var source := ""
	for world in ["flat-3d", "bistro"]:
		var radius := 4 if world == "flat-3d" else 8
		source += "[worlds.%s.terminal_window]\nblur_radius = %d\n" % [world, radius]
	FileAccess.open(paths.config_path(), FileAccess.WRITE).store_string(source)
	var flat = load("res://scenes/FlatTerminalSpaceWorld.gd").new()
	flat.configure_terminal(preload("res://graffitty/terminal_config.gd").new())
	check(flat.terminal_window.blur_radius == 4.0, "Flat loads its world-specific blur")
	flat.fx_camera.free() # Normally adopted by _ready; this fixture never enters the tree.
	flat.free()
	# Downloaded worlds read [worlds.<id>] through the same loader.
	var user = preload("res://graffitty/terminal_config.gd").new()
	user.background.alpha = .85
	var downloaded = preload("res://graffitty/world_config.gd").load_settings(preload("res://scenes/WorldSettings.gd"), user, PackedStringArray(["bistro"]))
	check(downloaded.terminal_window.blur_radius == 8.0, "A downloaded world loads its world-specific blur")
	check(is_equal_approx(downloaded.terminal.background.alpha, .85), "World overrides preserve 85 percent opacity")
	OS.set_environment("XDG_CONFIG_HOME", old_config)
	if DisplayServer.get_name() == "headless":
		quit(failures)
		return
	var bg := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var ink := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	ink.fill(Color.TRANSPARENT)
	for y in 128:
		for x in 128:
			bg.set_pixel(x, y, Color.WHITE if x % 8 < 4 else Color.BLACK)
			if x > 24 and x < 104 and y > 24 and y < 104:
				ink.set_pixel(x, y, Color(.15, .15, .15, .85))
			if x > 56 and x < 64 and y > 40 and y < 90:
				ink.set_pixel(x, y, Color.WHITE)
	var vp := SubViewport.new()
	vp.size = Vector2i(128, 128)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(ink)
	var material := ShaderMaterial.new()
	material.shader = preload("res://scenes/terminal_ink_composite.gdshader")
	material.set_shader_parameter("scenery_texture", ImageTexture.create_from_image(bg))
	rect.material = material
	vp.add_child(rect)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var before := vp.get_texture().get_image()
	material.set_shader_parameter("backdrop_blur_radius", 8.0)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var after := vp.get_texture().get_image()
	check(before.get_pixel(60, 60).is_equal_approx(after.get_pixel(60, 60)), "Opaque text stays sharp")
	check(before.get_pixel(12, 12).is_equal_approx(after.get_pixel(12, 12)), "Scenery outside pane stays unchanged")
	check(absf(before.get_pixel(44, 60).r - after.get_pixel(44, 60).r) > .02, "Scenery behind translucent pane is blurred")
	after.save_png("res://.cache/terminal-blur-proof.png")
	print("TERMINAL_BACKDROP_BLUR ", "PASS" if failures == 0 else "FAIL")
	quit(failures)
