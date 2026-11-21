extends SceneTree
class Host extends Node:
	var world: Node
	var workspace_view: Node
	var moving_window := false
	var presentation_active := true
	func create_chromium_session(_a, _b, _c): pass
	func is_terminal_pane(_key): return false
	func is_chromium_pane(_key): return false
class View extends Node:
	func split_window(_a, _b): pass
	func split_direction_icon(_direction): return preload("res://scenes/PaneIcons.gd").monitor()
class Pane extends "res://scenes/WorkspacePane.gd":
	func refresh(): pass
	func _refresh_title(): pass
	func _resize_terminal_preview(): pass
func _initialize():
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	call_deferred("run")
func run():
	if DisplayServer.get_name() == "headless":
		print("SKIP: pane alpha pixel check requires a GPU display")
		quit()
		return
	var host := Host.new()
	host.workspace_view = View.new()
	root.add_child(host)
	host.add_child(host.workspace_view)
	var pane := Pane.new()
	pane.host = host
	pane.key = "%0"
	pane.size = Vector2(800,600)
	var vp := SubViewport.new()
	vp.size = Vector2i(800,600)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	vp.add_child(pane)
	var panel: StyleBoxFlat = pane.get_theme_stylebox("panel")
	panel.bg_color = Color(0.1,0.2,0.3,0.35)
	panel.set_corner_radius_all(12)
	var mark := ColorRect.new()
	mark.color = Color.WHITE
	mark.position = Vector2(90,90)
	mark.size = Vector2(20,20)
	pane.body.add_child(mark)
	await process_frame
	await process_frame
	print("HEADER ",pane.header.position," ",pane.header.size," BODY ",pane.body.position)
	print("PADDING ", pane.terminal_content_padding(Vector4(8,8,8,8)), " FONT DESCENT ",pane.handle.get_theme_font("font").get_descent(pane.handle.get_theme_font_size("font_size")))
	var margin = pane.header.get_parent()
	for side in ["top","bottom","left","right"]: print(side,": ", margin.get_theme_constant("margin_"+side))
	for child in pane.header.get_children(): print(child.get_class()," ",child.size," minimum ",child.get_combined_minimum_size())
	await RenderingServer.frame_post_draw
	var pixels := vp.get_texture().get_image()
	print("ALPHA blank=",pixels.get_pixel(400,300).a," opaque=",pixels.get_pixel(100,130).a," corner=",pixels.get_pixel(0,0).a)
	var valid := absf(pixels.get_pixel(400,300).a - 0.35) < 0.02 and pixels.get_pixel(100,130).a > 0.99 and pixels.get_pixel(0,0).a < 0.01
	# A page filling the body is cut to the pane's rounded corners by its own
	# shader, without an offscreen pass, and keeps its exact color inside.
	var page := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	page.fill(Color8(40, 150, 220))
	pane.texture.texture = ImageTexture.create_from_image(page)
	pane.texture.material = ShaderMaterial.new()
	pane.texture.material.shader = preload("res://scenes/pane_content.gdshader")
	pane._sync_corner_clip()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	pixels = vp.get_texture().get_image()
	var inside: Color = pixels.get_pixel(14, 585)
	print("CORNERS outside=",pixels.get_pixel(0,599).a," ",pixels.get_pixel(799,599).a," inside=",inside," centre=",pixels.get_pixel(400,500))
	valid = valid and pixels.get_pixel(0,599).a < 0.01 and pixels.get_pixel(799,599).a < 0.01
	valid = valid and inside.a > 0.99 and absf(inside.r8 - 40) <= 2 and absf(inside.g8 - 150) <= 2 and absf(inside.b8 - 220) <= 2
	print("PANE_ALPHA_PASS" if valid else "PANE_ALPHA_FAIL")
	await create_timer(0.7).timeout # Allow the native visibility guard to sample.
	quit(0 if valid else 1)
