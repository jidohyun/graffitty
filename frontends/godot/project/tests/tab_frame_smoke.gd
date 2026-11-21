extends "res://tests/tab_overflow_smoke.gd"
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")

func _initialize():
	Background.install(self)
	super._initialize()

func frame() -> Image:
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func pixel(image: Image, point: Vector2) -> Color:
	var p := Vector2i(root.get_final_transform() * point)
	return image.get_pixel(p.x, p.y)

func same(a: Color, b: Color) -> bool:
	return Vector4(a.r, a.g, a.b, a.a).distance_to(Vector4(b.r, b.g, b.b, b.a)) < 0.015

func run():
	root.size = Vector2i(960, 540)
	# This pixel fixture owns its logical viewport. The application's startup
	# scale can otherwise shrink the requested 960-point strip into ~560 pixels,
	# turning an interior curved-foot sample into an antialiased edge pixel.
	root.content_scale_size = Vector2i(960, 540)
	root.content_scale_factor = 1.0
	var texture := GradientTexture2D.new()
	texture.gradient = Gradient.new()
	texture.gradient.colors = PackedColorArray([Color("bbdfe5"), Color("60508f"), Color("192d42")])
	texture.gradient.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	texture.fill_to = Vector2(1, 0.7)
	var backdrop := TextureRect.new()
	backdrop.texture = texture
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var host := FakeHost.new()
	root.add_child(host)
	host.items = [{'id':1,'title':'ALPHA','progress_state':0,'progress_value':-1}, {'id':2,'title':'BRAVO','progress_state':0,'progress_value':-1}]
	var strip = load('res://scenes/TerminalTabBar.tscn').instantiate()
	strip.bind_host(host)
	root.add_child(strip)
	strip.size.x = 960
	for selected in [1, 2]:
		host.select_workspace(selected)
		for i in 120:
			await process_frame
			if not strip.tabs._settling: break
		strip.hide()
		var world := await frame()
		strip.show()
		var rendered := await frame()
		var button: Button = strip.tabs.buttons[selected]
		var rect := button.get_global_rect()
		var top_inset := 6 if OS.get_name() == "Windows" else 8
		check(rect.position.y >= top_inset, 'Tabs preserve the platform titlebar inset')
		check(is_equal_approx(rect.end.y, strip.size.y), 'Active tab meets the world without a bottom gap: tab=%s strip=%s' % [rect, strip.size])
		for point in [rect.position + Vector2(20, 5), Vector2(rect.get_center().x, rect.end.y - 1), Vector2(rect.position.x - 3, rect.end.y - 1)]:
			check(same(pixel(rendered, point), pixel(world, point)), 'Active tab and its curved foot reveal the underlying world at ' + str(point))
		for point in [Vector2(rect.get_center().x, 3), rect.position + Vector2(1, 1)]:
			check(not same(pixel(rendered, point), pixel(world, point)), 'Frame fills top inset and rounded-corner cutout at ' + str(point))
		var output := OS.get_environment('GRAFFITTY_TEST_EVIDENCE')
		if not output.is_empty(): rendered.save_png(output.path_join('tab-frame-%d.png' % selected))
	texture.gradient.colors = PackedColorArray([Color("ad4532"), Color("739444"), Color("27243d")])
	strip.hide()
	var changed_world := await frame()
	strip.show()
	var changed := await frame()
	var active: Rect2 = strip.tabs.buttons[2].get_global_rect()
	var sample := Vector2(active.get_center().x, active.end.y - 1)
	check(same(pixel(changed, sample), pixel(changed_world, sample)), 'Background changes remain live through the selected tab')
	# Exercise the actual drag over a translucent world. A slot fill or hover
	# underline changes both the selected opening's colour and its alpha.
	root.transparent_bg = true
	texture.gradient.colors = PackedColorArray([Color(0.7, 0.2, 0.1, 0.55), Color(0.2, 0.6, 0.3, 0.7), Color(0.1, 0.2, 0.4, 0.4)])
	strip.hide()
	changed_world = await frame()
	strip.show()
	var dragged: Button = strip.tabs.buttons[2]
	var grip := dragged.global_position + Vector2(40, 18)
	var press := InputEventMouseButton.new()
	press.position = grip
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	root.push_input(press, true)
	for x in [120.0, 30.0]:
		var motion := InputEventMouseMotion.new()
		motion.position = Vector2(strip.tabs.global_position.x + x, grip.y)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		root.push_input(motion, true)
		strip.tabs.set_hover_hint(1, 0.65)
		var moving := await frame()
		check(strip.tabs._dragging, 'Pointer motion starts a real tab reorder')
		var rect := dragged.get_global_rect()
		var clean := true
		for dx in range(20, int(rect.size.x) - 20, 10):
			for dy in [31.0, 32.0]:
				var point := rect.position + Vector2(dx, dy)
				if strip.tabs.get_global_rect().has_point(point):
					clean = clean and same(pixel(moving, point), pixel(changed_world, point))
		check(clean, 'Dragged tab preserves the world colour and alpha without a slot fill or underline at x=%s' % x)
		var output := OS.get_environment('GRAFFITTY_TEST_EVIDENCE')
		if not output.is_empty(): moving.save_png(output.path_join('tab-reorder-%d.png' % int(x)))
	var release := InputEventMouseButton.new()
	release.position = Vector2(strip.tabs.global_position.x + 30, grip.y)
	release.button_index = MOUSE_BUTTON_LEFT
	root.push_input(release, true)
	strip.tabs.set_hover_hint(-1)
	check(not strip.tabs._dragging, 'Release finishes the tab reorder')
	for i in range(3, 41):
		host.items.append({'id':i, 'title':'Workspace %d' % i, 'progress_state':0, 'progress_value':-1})
	host.select_workspace(40)
	for i in 120:
		await process_frame
		if not strip.tabs._settling: break
	var scrolled := await frame()
	var visible: Rect2 = strip.tabs.buttons[40].get_global_rect().intersection(strip.tabs.get_global_rect())
	sample = Vector2(visible.get_center().x, visible.end.y - 2)
	check(visible.size.x > 10 and same(pixel(scrolled, sample), pixel(changed_world, sample)), 'Scrolling the selected tab into view moves its world opening with it')
	strip.tabs.scroll_horizontal = 0
	var offscreen := await frame()
	sample = Vector2(strip.tabs.global_position.x + 16, strip.size.y - 2)
	check(not same(pixel(offscreen, sample), pixel(changed_world, sample)), 'An offscreen selected tab leaves no stale opening in the visible strip')
	strip.queue_free()
	host.queue_free()
	backdrop.queue_free()
	await process_frame
	print('TAB_FRAME failures=', failures)
	quit(1 if failures else 0)
