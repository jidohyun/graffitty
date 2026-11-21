extends "res://tests/chromium_tab_overflow_smoke.gd"
## Retained toolbar state, production 2D/3D exits and interrupted cleanup.

class World extends Node3D:
	const INK_MASK := 1
	const FLY_TIME := 1.0
	const TAB_FX_LEAVE := .42
	const TAB_FX_ARRIVE := .42
	var tab_fx_t := -1.0
	var cam := Camera3D.new()
	func _ready() -> void:
		add_child(cam)
		cam.position.z = 5

class Host extends Node:
	signal ui_changed
	var world := World.new()
	var layout_root := Control.new()
	func visible_chromium() -> Node: return null
	func _ready() -> void:
		add_child(world)
		add_child(layout_root)

func frame(view: SubViewport) -> Image:
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	return view.get_texture().get_image()

func difference(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size(): return 1.0
	var sum := 0.0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			sum += absf(p.r-q.r) + absf(p.g-q.g) + absf(p.b-q.b) + absf(p.a-q.a)
	return sum / maxf(a.get_width() * a.get_height(), 1)

func has_title(node: Node, title: String) -> bool:
	if node is Button and node.text == title: return true
	for child in node.get_children():
		if has_title(child, title): return true
	return false

func run() -> void:
	root.size = Vector2i(900, 500)
	var session := Session.new()
	root.add_child(session)
	session.page_tabs = [{"id": 1, "title": "ORIGINAL CHROME STATE", "url": "https://example.test/original"}]
	var source := SubViewport.new()
	source.size = Vector2i(1800, 300)
	source.size_2d_override = Vector2i(600, 100)
	source.size_2d_override_stretch = true
	source.use_hdr_2d = true
	source.transparent_bg = true
	source.oversampling = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var chrome := preload("res://scenes/ChromiumChrome.gd").new()
	chrome.size = Vector2(600, 100)
	source.add_child(chrome)
	root.add_child(source)
	chrome.refresh(session)
	await settle()
	var original := await frame(source)
	var retained := preload("res://scenes/CellShatter.gd").capture_control(chrome)
	root.add_child(retained)
	retained.size = source.size
	check(difference(original, await frame(retained)) < .003, "Toolbar state preserves text, background, controls and colors")
	source.free()
	retained.size = Vector2i(2400, 400)
	var redrawn := await frame(retained)
	check(has_title(retained, "ORIGINAL CHROME STATE") and redrawn.get_pixel(20, 20).a > .9, "Toolbar rerasterizes at higher density after source destruction")
	retained.free()
	var host := Host.new()
	root.add_child(host)
	var panel := preload("res://scenes/ChromiumPanel.gd").new()
	panel.host = host
	root.add_child(panel)
	panel.set_process(false)
	panel.root.show()
	panel.root.modulate.a = 1
	panel.active = session
	panel.chrome.refresh(session)
	await settle()
	await RenderingServer.frame_post_draw
	var chrome_rect := Rect2i(root.get_final_transform() * panel.chrome.get_global_rect())
	var panel_pixels := root.get_texture().get_image().get_region(chrome_rect)
	panel._retire_panel()
	panel.root.hide()
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	var tile_pixels := root.get_texture().get_image().get_region(chrome_rect)
	print("CHROME_TILE_PIXEL_ERROR ", difference(panel_pixels, tile_pixels))
	var evidence := OS.get_cache_dir().path_join("retained-toolbar")
	DirAccess.make_dir_recursive_absolute(evidence)
	panel_pixels.save_png(evidence.path_join("live.png"))
	tile_pixels.save_png(evidence.path_join("tiles.png"))
	check(difference(panel_pixels, tile_pixels) < .012, "2D retained slices preserve toolbar colors and text at the assembled pose")
	var outgoing: Dictionary = panel._outgoing.back()
	var mod_view: SubViewport = outgoing.toolbar
	check(outgoing.tiles.size() == 12 and outgoing.tiles.all(func(tile): return tile.node.texture == mod_view.get_texture()), "All 2D toolbar tiles share one retained UI view")
	panel.chrome.free()
	panel.chrome = Control.new()
	panel.root.add_child(panel.chrome)
	mod_view.size = Vector2i(1200, 200)
	await frame(mod_view)
	check(has_title(mod_view, "ORIGINAL CHROME STATE"), "2D departure outlives the live toolbar")
	panel._process(1.0)
	await process_frame
	check(not is_instance_valid(mod_view), "2D departure frees its retained toolbar")
	panel.free()
	var surface := preload("res://scenes/ChromiumSurface3D.gd").new()
	surface.host = host
	surface.world = host.world
	host.world.add_child(surface)
	surface.set_process(false)
	surface.active = session
	surface._opacity = 1.0
	surface._mesh_size = Vector2(4, 3)
	surface.chrome.refresh(session)
	surface.material.set_shader_parameter("surface_size", surface._mesh_size)
	await settle()
	surface._retire_surface()
	surface._retire_surface()
	var views: Array = surface._outgoing.map(func(entry): return entry.toolbar)
	check(views.size() == 2 and views[0] != views[1], "Interrupted 3D departures own independent toolbar views")
	surface.chrome_view.free()
	for view in views:
		view.size = Vector2i(1280, 180)
		await frame(view)
		check(has_title(view, "ORIGINAL CHROME STATE"), "3D toolbar redraws after its source viewport is destroyed")
	surface._update_outgoing(1.0)
	await process_frame
	check(views.all(func(view): return not is_instance_valid(view)), "3D departures release every retained toolbar")
	surface.free()
	host.free()
	session.free()
	print("CHROMIUM_RETAINED_TOOLBAR_PASS" if failures == 0 else "CHROMIUM_RETAINED_TOOLBAR_FAIL")
	quit(failures)
