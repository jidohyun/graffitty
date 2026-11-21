extends "../../../../tests/llm-e2e/replay/replay.gd"
## Background resize must reflow the workspace without advancing animations.


func play() -> void:
	await camera_at_rest()
	var world: Node = host.world
	var view: Control = host.workspace_view
	world.background_skip = true
	world._set_world_awake(false)
	var frozen_time: float = world.fx_time
	for zoom in [1.0, 2.0]:
		world.fx_cam_zoom = zoom
		world._apply_camera_fx()
		view.update_raster_region()
		for extent in [Vector2i(1600, 900), Vector2i(533, 900), Vector2i(1200, 500)]:
			root.size = Vector2i(Vector2(extent) * root.content_scale_factor)
			await hold(0.3)
			var full: Vector2 = view.canvas_size()
			var region: Rect2 = view.raster_region
			var expected_scale := full / region.size
			check(view.canvas.canvas_transform.get_scale().is_equal_approx(expected_scale),
				"Inactive resize %s at zoom %.1f updates both rendering axes" % [extent, zoom])
			check(view.canvas.canvas_transform.origin.is_equal_approx(-region.position * expected_scale),
				"Canvas crop offset follows the resized workspace")
			var expected_region := Vector4(region.position.x / full.x, region.position.y / full.y, region.size.x / full.x, region.size.y / full.y)
			var shader_region: Vector4 = world.fx_mat.get_shader_parameter("texture_region")
			check(shader_region.is_equal_approx(expected_region), "Sheet texture mapping agrees with canvas layout")
			check(not world.world_awake and is_equal_approx(world.fx_time, frozen_time),
				"Resizing keeps background animations asleep")
