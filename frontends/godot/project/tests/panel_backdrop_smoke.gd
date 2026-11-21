extends SceneTree
const SHADER := preload("res://scenes/mods/panel_backdrop.gdshader")
var failed := false
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	failed = failed or not ok
func frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw
func run() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(128, 128)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	for x in 64:
		var stripe := ColorRect.new()
		stripe.position = Vector2(x * 2, 0)
		stripe.size = Vector2(2, 128)
		stripe.color = Color.WHITE if x % 2 == 0 else Color.BLACK
		vp.add_child(stripe)
	var panel := Panel.new()
	panel.position = Vector2(16, 16)
	panel.size = Vector2(96, 96)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.1, 0.2)
	panel.add_theme_stylebox_override("panel", style)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("surface_opacity", 0.2)
	mat.set_shader_parameter("radius", 1.0)
	panel.material = mat
	vp.add_child(panel)
	var content := ColorRect.new()
	content.position = Vector2(30, 30)
	content.size = Vector2(12, 12)
	content.color = Color.RED
	panel.add_child(content)
	await frame()
	await frame()
	var sharp := vp.get_texture().get_image()
	mat.set_shader_parameter("radius", 16.0)
	await frame()
	await frame()
	var blurred := vp.get_texture().get_image()
	var before := absf(sharp.get_pixel(64, 70).r - sharp.get_pixel(66, 70).r)
	var after := absf(blurred.get_pixel(64, 70).r - blurred.get_pixel(66, 70).r)
	check(before > 0.4 and after < 0.1, "Increasing the radius blurs backdrop stripes")
	check(blurred.get_pixel(48, 48).r > 0.95 and blurred.get_pixel(48, 48).g < 0.05, "Panel children stay sharp and untinted")
	check(absf(blurred.get_pixel(2, 8).r - blurred.get_pixel(4, 8).r) > 0.9, "Pixels outside the panel remain sharp")
	check(blurred.get_pixel(64, 70).a > 0.99, "Opaque background is not spuriously made transparent")
	mat.set_shader_parameter("tint_surface", false)
	await frame()
	await frame()
	var untinted := vp.get_texture().get_image()
	check(absf(untinted.get_pixel(64, 70).r - untinted.get_pixel(66, 70).r) < 0.1, "Embedded-parent mode blurs without adding a second tint")
	# Remove stripes to check that blur retains the transparent window backdrop.
	for child in vp.get_children():
		if child != panel: child.queue_free()
	await frame()
	await frame()
	var transparent := vp.get_texture().get_image()
	check(transparent.get_pixel(64, 70).a < 0.03, "Untinted embedded backdrop preserves transparency")
	mat.set_shader_parameter("tint_surface", true)
	await frame()
	await frame()
	transparent = vp.get_texture().get_image()
	check(absf(transparent.get_pixel(64, 70).a - 0.2) < 0.03, "Transparent backdrop retains the surface opacity")
	vp.queue_free()
	await process_frame
	quit(1 if failed else 0)
