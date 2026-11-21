extends SceneTree
## Render regression: a translucent terminal must not erase sprite scenery.
## godot --path . --script tests/transition_alpha.gd
const Effects := preload("res://scenes/TerminalEffects.gd")


class RenderWorld extends "res://scenes/TerminalWorld.gd":
	func _ready() -> void:
		pass


	func _process(_dt: float) -> void:
		pass


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test requires a rendering window")
		quit(1)
		return
	var view := SubViewport.new()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var world := RenderWorld.new()
	world.terminal_effects = Effects.new()
	view.add_child(world)
	var camera := Camera3D.new()
	camera.position.z = 5.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	world.add_child(camera)
	var sprite := MeshInstance3D.new()
	sprite.mesh = QuadMesh.new()
	sprite.mesh.size = Vector2(4, 4)
	sprite.position.z = -1.0
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0, 1, 0, 1)
	sprite.material_override = material
	world.add_child(sprite)
	var source := SubViewport.new()
	source.size = Vector2i(64, 64)
	source.transparent_bg = true
	source.disable_3d = true
	source.world_2d = World2D.new()
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var fill := ColorRect.new()
	fill.size = Vector2(64, 64)
	fill.color = Color(0, 0, 0, 0.28)
	source.add_child(fill)
	var origin := Vector3(-1, 1, 0)
	var du := Vector3(2, 0, 0)
	var dv := Vector3(0, -2, 0)
	var layer: Node = world._build_background_pieces(source, Rect2(0, 0, 64, 64), origin, du, dv)
	# Floating windows override the background's priority with their stack rank.
	layer._material().render_priority = world.TAB_FX_WINDOW_PRIORITY + 1
	for i in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	var pixel := view.get_texture().get_image().get_pixel(32, 32)
	var passed := pixel.g > 0.65 and pixel.r < 0.05 and pixel.b < 0.05
	print("TRANSITION_ALPHA_", "PASS" if passed else "FAIL", " scenery through sheet: ", pixel)
	world.terminal_effects.free()
	world.fx_camera.free()
	quit(0 if passed else 1)
