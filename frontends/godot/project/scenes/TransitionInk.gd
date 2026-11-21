extends Node
## Each retained workspace uses the live screen-space lens before composition.
## Separate depth attachments prevent a fading arrival from defocusing departure.
const MASK := (1 << 12) | (1 << 13) | (1 << 14) | (1 << 15)
var passes := {}


func synchronize(world: Node) -> void:
	var groups := {}
	if world.ink_active:
		for layers in [world.tab_fx_out, world.tab_fx_in]:
			if not layers.is_empty():
				groups[layers[0].get_instance_id()] = layers.duplicate()
		for entry in world.tab_fx_stale:
			groups.get_or_add(entry.capture_group, []).append(entry.layer)
	for id in passes.keys():
		if not groups.has(id):
			passes[id].view.queue_free()
			passes.erase(id)
	var ordered: Array = groups.keys()
	ordered.sort_custom(func(a, b): return groups[a][0]._material().render_priority < groups[b][0]._material().render_priority)
	for id in ordered:
		if not passes.has(id):
			var slot := 0
			var used: Array = passes.values().map(func(render_pass): return render_pass.slot)
			while slot in used: slot += 1
			assert(slot < 4, "At most two retiring workspaces plus the current pair")
			var view := SubViewport.new()
			view.transparent_bg = true
			view.use_debanding = false
			world._configure_ink_antialiasing(view)
			add_child(view)
			var camera := Camera3D.new()
			camera.environment = world.ink_cam.environment
			camera.attributes = world.ink_cam.attributes
			camera.cull_mask = 1 << (12 + slot)
			var lens := preload("res://scenes/InkDepthOfField.gd").new()
			camera.compositor = Compositor.new()
			camera.compositor.compositor_effects = [lens]
			view.add_child(camera)
			camera.current = true
			passes[id] = {"slot": slot, "view": view, "camera": camera, "lens": lens}
		var render_pass: Dictionary = passes[id]
		render_pass.view.size = world.ink_vp.size
		render_pass.view.render_target_update_mode = SubViewport.UPDATE_ONCE
		render_pass.camera.near = world.cam.near
		render_pass.camera.far = world.cam.far
		preload("res://scenes/CameraMotion.gd").apply(render_pass.camera, {"transform": world.cam.global_transform, "rect": world.proj_rect})
		render_pass.camera.force_update_transform()
		var phase := 0.0
		for layer in groups[id]:
			layer.layers = render_pass.camera.cull_mask
			var material: ShaderMaterial = layer._material()
			material.set_shader_parameter("screen_dof", true)
			phase = maxf(phase, float(material.get_shader_parameter("fly")))
		var effects: Node = world.terminal_effects
		var optics := Vector2(effects.depth_range, phase * 6.0)
		if not groups[id][0].get_meta("depth_mode", false):
			optics = departure_lens(effects.depth_range, effects.blur_radius, phase)
		render_pass.lens.set_lens(effects.focus_depth, effects.blur_radius, optics.x, effects.blur_limit, optics.y)
	var composite: ShaderMaterial = world.ink_overlay.material
	composite.set_shader_parameter("transition_count", ordered.size())
	var foreground_mask := 0
	for index in ordered.size():
		# Flying fragments approach the camera, ahead of the arriving/live pane.
		# Their isolated depth attachment must not put them behind that pane.
		if not groups[ordered[index]][0].get_meta("depth_mode", false): foreground_mask |= 1 << index
	composite.set_shader_parameter("transition_foreground_mask", foreground_mask)
	for index in 4:
		composite.set_shader_parameter("transition_%d" % index, passes[ordered[index]].view.get_texture() if index < ordered.size() else null)


static func departure_lens(depth_range: float, radius: float, phase: float) -> Vector2:
	# The typing lens resolves tiny differences across a nearly flat sheet. It is
	# far too shallow for staggered glyph flight: one cohort becomes a blurred
	# block while its unreleased neighbours remain sharp.
	#
	# Open the depth range before they separate and give the departing sheet a
	# shared, smooth defocus envelope. At phase zero keep the captured lens
	# unchanged.
	var flight_range := lerpf(depth_range, maxf(depth_range, 0.4), smoothstep(0.0, 0.04, phase))
	var shared_blur := radius * smoothstep(0.0, 0.18, phase)
	return Vector2(flight_range, shared_blur)
