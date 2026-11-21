extends "res://tests/tab_window_session_smoke.gd"
## Actual workspace state can redraw after its source changes or goes away.

func image_of(view: Viewport, label: String) -> Image:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	var image := view.get_texture().get_image()
	var folder := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if folder.is_empty(): folder = OS.get_cache_dir().path_join("retained-handoff")
	DirAccess.make_dir_recursive_absolute(folder)
	image.save_png(folder.path_join(label + ".png"))
	print("HANDOFF_IMAGE ", folder.path_join(label + ".png"))
	return image

func difference(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size(): return 1.0
	var total := 0.0
	var count := 0
	for y in range(120, a.get_height() - 20, 3):
		for x in range(20, a.get_width() - 20, 3):
			var p := a.get_pixel(x, y)
			var q := b.get_pixel(x, y)
			total += absf(p.r - q.r) + absf(p.g - q.g) + absf(p.b - q.b) + absf(p.a - q.a)
			count += 4
	return total / maxf(count, 1)

func header_ink(image: Image) -> int:
	var count := 0
	for y in range(16, 80):
		for x in range(50, image.get_width() - 50):
			if image.get_pixel(x, y).r > 0.7: count += 1
	return count

func redraw(node: Node) -> void:
	if node is SubViewport: node.render_target_update_mode = SubViewport.UPDATE_ONCE
	if node is CanvasItem: node.queue_redraw()
	for child in node.get_children(): redraw(child)

func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if not check_host(wrapper): return
	var source: Node = wrapper.host
	await settled(source)
	source.set_tab_transition_effect("none")
	for path in ["flat-2d", "", "bistro"]:
		check(source.switch_world(path), "Load handoff world " + path)
		await settled(source)
		await create_timer(1.0).timeout
		var terminal: Node = source.sessions[source.active_session_id].term
		terminal.send_text("printf '\\033[35mRETAINED HANDOFF TEXT 0123456789\\033[0m\\n'\n")
		await create_timer(2.5).timeout
		source.world.set_process(false)
		var original := await image_of(root, path.get_file() + "-live")
		var preview := preload("res://scenes/TabDragPreview.gd").new()
		preview.configure(source, source.workspace_view.tab_bar.tabs, source.workspace_layout.active)
		root.add_child(preview)
		preview.show()
		var before := await image_of(preview, path.get_file() + "-before-retain")
		preview.retain_presentation()
		var retained := await image_of(preview, path.get_file() + "-retained")
		check(header_ink(retained) >= header_ink(before) * .9, "The preview title strip remains above the retained workspace")
		var error := difference(original, retained)
		print("HANDOFF_PIXEL_ERROR ", path, " ", error)
		check(error < 0.008, "Retained scene preserves workspace pixels in " + path)
		terminal.send_text("clear\n")
		await create_timer(.2).timeout
		check(source.switch_world("" if path == "flat-2d" else "flat-2d"), "Destroy the source world while the handoff owns its presentation")
		await process_frame
		redraw(preview._presentation)
		var after := await image_of(preview, path.get_file() + "-redrawn")
		print("HANDOFF_REDRAW_ERROR ", path, " ", difference(retained, after))
		check(difference(retained, after) < 0.002, "Retained scene redraws after terminal changes and source world destruction")
		var held: SubViewport = preview._presentation
		preview.complete_handoff()
		await process_frame
		check(not is_instance_valid(held), "Handoff releases all retained render targets")
		preview.queue_free()
		source.world.set_process(true)
	print("RETAINED_HANDOFF_PASS" if failures.is_empty() else "RETAINED_HANDOFF_FAIL")
	quit(failures.size())
