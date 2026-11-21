extends "../../../../tests/llm-e2e/replay/replay.gd"
## Exercise real chromium panes and camera projection without launching Chromium.
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var terminal: String = host.pane_focus
	var owner := int(terminal.substr(1))
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["physics"] = false
	group.tree["tiling"] = false
	var center: Vector2 = view.content_rect().get_center()
	Layout.find(group.tree, terminal)["rect"] = Rect2(center + Vector2(-310, -110), Vector2(250, 220))
	for i in 2:
		var chromium: Node = load("res://scenes/ChromiumSession.gd").new()
		var id: int = host.allocate_session_id()
		chromium.tab_id = owner
		chromium.owner_id = owner
		chromium.session_id = id
		chromium.title = "Connection %d" % (i + 1)
		app.add_child(chromium)
		host.chromiums[id] = chromium
		host.workspaces[owner].chromiums.append(id)
		var item := Layout.leaf("%%%d" % id)
		item["rect"] = Rect2(center + Vector2(100, -270 + i * 300), Vector2(280, 220))
		host.workspace_layout.merge(group.id, item, terminal)
	view.refresh()
	check(view.chromium_links.wire_layer.get_parent() == view.canvas_root, "Chromium wires share the pane canvas")
	for pane in view.panes.values():
		check(view.chromium_links.wire_layer.get_index() < pane.get_index(), "Chromium wires draw below pane contents")
	view.overview = true
	view.navigation_center = center
	for zoom in [0.6, 1.0, 2.0, 3.0]:
		view.navigation_zoom = zoom
		view._apply_navigation()
		await hold(0.25)
		check(view.chromium_links.edges.size() == 2, "Both chromium connections exist at %.1fx zoom" % zoom)
		await check_pixels(view, "zoom-%.1f" % zoom)
	# Overlap at the top of the viewport: the route above would be hidden.
	view.navigation_zoom = 1.0
	var rect := Rect2(Vector2(view.content_rect().get_center().x - 180, view.content_rect().position.y + 2), Vector2(360, 260))
	Layout.find(group.tree, terminal)["rect"] = rect
	var chromium_key := "%%%d" % host.workspaces[owner].chromiums[0]
	Layout.find(group.tree, chromium_key)["rect"] = Rect2(rect.position + Vector2(80, 20), rect.size)
	view.navigation_center = view.size * 0.5
	view.refresh()
	view._apply_navigation()
	await hold(0.25)
	check(view.chromium_links.edges.size() == 2, "Overlap keeps both connections")
	await check_pixels(view, "overlap")
	check(view.chromium_links.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Connection overlay never intercepts pane input")


func check_pixels(view: Control, label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	var pixel_scale := Vector2(picture.get_size()) / root.get_visible_rect().size
	var found := 0
	for edge in view.chromium_links.edges:
		for point in edge:
			var screen: Vector2 = (view.get_global_transform_with_canvas() * point) * pixel_scale
			if not view.content_rect().grow(-8).has_point(point):
				continue
			var bright := false
			for dx in range(-3, 4):
				for dy in range(-3, 4):
					var pixel := Vector2i(screen) + Vector2i(dx, dy)
					if not Rect2i(Vector2i.ZERO, picture.get_size()).has_point(pixel):
						continue
					var color := picture.get_pixelv(pixel)
					bright = bright or (color.b > 0.8 and color.g > 0.55 and color.r > 0.35 and color.b > color.r + 0.1)
			if bright:
				found += 1
	check(found >= 2, "Connections are actually drawn in %s (%d visible samples)" % [label, found])
	picture.save_png("/tmp/chromium-links-%s.png" % label)
