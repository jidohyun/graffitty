extends SceneTree
const Effects := preload("res://scenes/TerminalEffects.gd")
const World := preload("res://scenes/TerminalWorld.gd")
const InkShader := preload("res://scenes/terminal_composite.gdshader")
var failures := 0

class Host extends Node:
	func is_terminal_pane(key: String) -> bool: return key in ["%0", "%1"]
	var workspace_view: Control

class View extends Control:
	var canvas := SubViewport.new()
	var canvas_root := Control.new()
	var panes := {}

class Pane extends Control:
	var key := "%0"
	var texture := TextureRect.new()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func _initialize() -> void: run.call_deferred()

func run() -> void:
	check(InkShader.get_shader_uniform_list().any(func(item): return item.name == "defocus_focus_depth"), "Terminal content shader parses with shared defocus parameters")
	check(Effects.SheetShader.get_shader_uniform_list().any(func(item): return item.name == "defocus_focus_depth"), "Sheet shader parses shared wave and defocus includes")
	var effects := Effects.new()
	effects.automatic = false
	root.add_child(effects)
	var camera := Camera3D.new()
	root.add_child(camera)
	var sheet := ShaderMaterial.new()
	sheet.shader = Effects.SheetShader
	effects.material = sheet
	effects.surface_frame = func(uv: Vector2): return Transform3D(Basis.IDENTITY, Vector3(uv.x, uv.y, -2.0 - uv.x))
	# Cursor is at depth 2; the lens is in transition at depth 2.5.
	effects.update_lens(camera, Vector3(0, 0, -2), 1.3, 2.5, 0.6)
	check(is_equal_approx(sheet.get_shader_parameter("defocus_focus_depth"), 2.5), "Tint uses the interpolated DOF focus, not raw cursor depth")
	check(is_equal_approx(sheet.get_shader_parameter("defocus_depth_range"), effects.depth_range), "Tint shares DOF depth normalization")
	check(is_equal_approx(sheet.get_shader_parameter("defocus_weight"), 0.6), "Tint follows the continuous lens weight without waiting for zoom")
	effects.screen_dof = true
	effects.update_lens(camera, Vector3(0, 0, -2), 1.1, 2.3, 0.4)
	check(is_equal_approx(sheet.get_shader_parameter("defocus_weight"), 0.4), "Return transition decreases tint continuously")
	check(is_zero_approx(sheet.get_shader_parameter("blur_radius")) and effects.defocus_weight > 0, "Screen-space DOF keeps source text tint enabled")
	var host := Host.new()
	var view := View.new()
	host.workspace_view = view
	root.add_child(view)
	view.canvas.size = Vector2i(1000, 500)
	view.add_child(view.canvas)
	view.canvas.add_child(view.canvas_root)
	for key in ["%0", "%1", "%2"]:
		var pane := Pane.new()
		pane.key = key
		view.canvas_root.add_child(pane)
		pane.position = Vector2(100 if key == "%0" else 500, 50)
		pane.add_child(pane.texture)
		pane.texture.position = Vector2(8, 40)
		pane.texture.size = Vector2(300, 200)
		pane.texture.material = ShaderMaterial.new()
		pane.texture.material.shader = InkShader
		view.panes[key] = pane
	var world := World.new() # Do not launch a terminal, socket or full world.
	world.host = host
	world.cam = camera
	world.terminal_effects = effects
	world.fx_mat = sheet
	world.uv_origin = Vector3(0, 0, -2)
	world.uv_du = Vector3(1, 0, -1)
	world.uv_dv = Vector3(0, 1, -0.5)
	sheet.set_shader_parameter("tex_size", Vector2(1000, 500))
	sheet.set_shader_parameter("curvature_rad", 0.12)
	world._sync_terminal_defocus_tint()
	var mat: ShaderMaterial = view.panes["%0"].texture.material
	check(mat.get_shader_parameter("ink_sheet_rect").is_equal_approx(Vector4(0.108, 0.18, 0.3, 0.4)), "Tint depth mapping includes terminal position and header/padding inset")
	check(mat.get_shader_parameter("ink_depth_plane").is_equal_approx(Vector3(2, 1, 0.5)), "Tint derives fragment depth from the actual camera and sheet plane")
	check(is_equal_approx(mat.get_shader_parameter("curvature_rad"), 0.12), "Tint shares the sheet's surface warp")
	check(is_equal_approx(view.panes["%1"].texture.material.get_shader_parameter("defocus_weight"), 0.4), "Every visible terminal receives current lens state")
	check(view.panes["%2"].texture.material.get_shader_parameter("defocus_weight") == null or is_zero_approx(view.panes["%2"].texture.material.get_shader_parameter("defocus_weight")), "Chromium content is not assigned terminal tint")
	effects.enabled = false
	effects.update_lens(camera, Vector3(0, 0, -2), 1, -1, 1)
	world._sync_terminal_defocus_tint()
	check(is_zero_approx(mat.get_shader_parameter("defocus_weight")), "Disabling effects clears terminal tint")
	sheet.set_shader_parameter("curvature_rad", 0.25)
	view.panes["%0"].position.x += 50
	effects.enabled = true
	effects.update_lens(camera, Vector3(0, 0, -2), 1.1, 2.3, 0.4)
	world._sync_terminal_defocus_tint()
	check(is_equal_approx(mat.get_shader_parameter("curvature_rad"), 0.25)
		and is_equal_approx(mat.get_shader_parameter("ink_sheet_rect").x, 0.158),
		"Reactivating tint picks up geometry and warp changes made while idle")
	world.fx_camera.free() # Normally adopted by the full world during _ready.
	world.free()
	host.free()
	view.free()
	camera.free()
	effects.free()
	if DisplayServer.get_name() == "headless":
		print("SKIP GPU pixel checks: headless renderer")
	else:
		await pixel_checks()
	quit(1 if failures else 0)

func pixel_checks() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var background := ColorRect.new()
	background.color = Color(0.2, 0.3, 0.4)
	background.size = Vector2(64, 64)
	viewport.add_child(background)
	var pixels := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	pixels.fill(Color.TRANSPARENT)
	pixels.fill_rect(Rect2i(28, 16, 8, 32), Color.WHITE)
	pixels.fill_rect(Rect2i(27, 16, 1, 32), Color(0.5, 0.5, 0.5, 0.5))
	# Match the premultiplied SubViewport texture consumed in production.
	# Color.TRANSPARENT has white RGB; alpha alone does not premultiply it.
	pixels.premultiply_alpha()
	var ink := TextureRect.new()
	ink.texture = ImageTexture.create_from_image(pixels)
	var material := ShaderMaterial.new()
	material.shader = InkShader
	material.set_shader_parameter("ink_depth_plane", Vector3(2, 0, 0))
	ink.material = material
	viewport.add_child(ink)
	await process_frame
	await RenderingServer.frame_post_draw
	var before := viewport.get_texture().get_image()
	material.set_shader_parameter("defocus_weight", 1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var tinted := viewport.get_texture().get_image()
	check(before.get_pixel(8, 8).is_equal_approx(tinted.get_pixel(8, 8)), "Tint leaves empty background pixels unchanged: %s -> %s" % [before.get_pixel(8, 8), tinted.get_pixel(8, 8)])
	check(not before.get_pixel(30, 30).is_equal_approx(tinted.get_pixel(30, 30)), "Out-of-focus glyphs receive tint")
	check(not before.get_pixel(27, 30).is_equal_approx(tinted.get_pixel(27, 30)), "Antialiased glyph coverage receives tint")
	material.set_shader_parameter("defocus_focus_depth", 2.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var focused := viewport.get_texture().get_image()
	check(before.get_pixel(30, 30).is_equal_approx(focused.get_pixel(30, 30)), "In-focus glyph color remains neutral")
	viewport.free()
