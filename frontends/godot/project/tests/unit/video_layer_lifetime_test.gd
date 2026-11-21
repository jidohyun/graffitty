extends "res://tests/unit/test_case.gd"

func test_replaced_wall_releases_page_textures() -> void:
	var world := preload("res://scenes/TerminalWorld.gd").new()
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; uniform float page_count; uniform sampler2D page_0; uniform sampler2D page_1; uniform sampler2D page_2; uniform sampler2D page_3;"
	var old := ShaderMaterial.new()
	old.shader = shader
	var page := ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	old.set_shader_parameter("page_0", page)
	old.set_shader_parameter("page_count", 1.0)
	world._video_layer_material = old
	world.fx_mat = ShaderMaterial.new()
	world.fx_mat.shader = shader
	world.set_video_layers([])
	expect(old.get_shader_parameter("page_0") == null, "A previous wall cannot retain a decoder viewport texture")
	expect(float(old.get_shader_parameter("page_count")) == 0.0, "The previous wall stops compositing pages")
	world.free()

func test_retained_pane_keeps_its_own_page_view() -> void:
	# Android decodes Chromium pages into a SubViewport owned by the session,
	# outside the pane. A transition copy must survive that view being freed.
	var tree := Engine.get_main_loop() as SceneTree
	var session := Node.new()
	var page := SubViewport.new()
	page.size = Vector2i(8, 4)
	session.add_child(page)
	tree.root.add_child(session)
	var pane := Control.new()
	pane.name = "Pane"
	var content := TextureRect.new()
	content.name = "Content"
	content.texture = page.get_texture()
	pane.add_child(content)
	var copy: Control = preload("res://scenes/RetainedPresentation.gd").control(pane, [session])
	expect(copy.get_child_count() == 2 and copy.get_child(1) is SubViewport, "The copy owns a snapshot of the page view")
	session.free()
	var retained: Texture2D = (copy.get_child(0) as TextureRect).texture
	expect(retained != null and retained.get_size() == Vector2(8, 4), "A freed page view leaves the retained copy drawable")
	copy.free()
	pane.free()
