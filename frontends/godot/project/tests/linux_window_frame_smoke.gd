extends "res://tests/tab_overflow_smoke.gd"
var close_requests := 0


# Exercise the same draw/resize controls on CI hosts without a Linux desktop.
class SimulatedFrame extends "res://scenes/WindowFrameLinux.gd":
	func _refresh_frame() -> void:
		_apply_shape(Mode.ROUNDED if get_window().mode == Window.MODE_WINDOWED else Mode.SQUARE)


class ScrollWorkspace extends Control:
	var tab_bar: Control

	func _foreground_rect() -> Rect2:
		return Rect2(0, tab_bar.size.y, size.x, size.y - tab_bar.size.y)


func run() -> void:
	auto_accept_quit = false
	root.title = "Graffitty Window Frame Test"
	root.gui_embed_subwindows = false
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(900, 500)
	root.close_requested.connect(
		func():
			close_requests += 1,
	)
	var backdrop := ColorRect.new()
	backdrop.color = Color("35485d")
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var host := FakeHost.new()
	root.add_child(host)
	for i in 6:
		host.items.append(
			{
				"id": i + 1,
				"title": "Terminal %d" % (i + 1),
				"progress_state": 0,
				"progress_value": -1,
			}
		)
	var linux := DisplayServer.get_name() in ["X11", "Wayland"]
	var frame: Node
	if linux:
		frame = preload("res://scenes/NativeWindowFrame.gd").acquire(root)
	else:
		frame = SimulatedFrame.new()
		root.set_meta(&"graffitty_window_frame", frame)
		root.add_child(frame)
	var strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	strip.bind_host(host)
	root.add_child(strip)
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	var scroll_view := ScrollWorkspace.new()
	scroll_view.tab_bar = strip
	scroll_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(scroll_view)
	scroll_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrollbar := preload("res://scenes/TerminalScrollBar.gd").new()
	scrollbar.mount_workspace(scroll_view, host)
	var alpha_available := not linux or preload("res://graffitty/window_transparency.gd").available()
	if "--expect-rounded" in OS.get_cmdline_user_args():
		check(linux and alpha_available, "The composited test display supports rounded windows")
	if linux:
		await _check_workspace_windows(host)
	if linux and root.get_node("TerminalApplication").window_decorations == "system":
		await process_frame
		strip._sync_window_frame()
		check(not root.borderless and strip._title_margins == Vector3.ZERO, "System decorations own the frame")
		check(frame == null or (not frame.buttons.visible and frame.resize_border() == 0), "System frame leaves all edges and caption controls to the WM")
		quit(1 if failures else 0)
		return
	if DisplayServer.get_name() != "headless":
		preload("res://scenes/DesktopBlur.gd").set_window_transparent(root, false)
		check(root.transparent == alpha_available and root.transparent_bg == alpha_available, "Floating frame requests native alpha only when supported")
	# Paint into the final canvas above normal chrome. Only the corner quads
	# may change these samples, independent of the world or a popup below.
	var probe_layer := CanvasLayer.new()
	probe_layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.POINTER_CAPTURE
	root.add_child(probe_layer)
	var probe := ColorRect.new()
	var paint := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; render_mode unshaded, blend_disabled; uniform float alpha; void fragment() { COLOR = vec4(vec3(0.5)*alpha, alpha); }"
	paint.shader = shader
	probe.material = paint
	probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	probe_layer.add_child(probe)
	probe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for scale in [1.0, 1.25, 1.5, 1.75, 2.0]:
		root.content_scale_factor = scale
		root.size = Vector2i((Vector2(901, 503) * scale).round())
		for i in 30:
			await process_frame
		strip._sync_window_frame()
		if DisplayServer.get_name() != "headless":
			check(root.borderless, "Linux frame replaces the separate system title bar")
		check(
			strip._title_margins.x + strip._title_margins.y == 132,
			"Window controls reserve the same logical width at each scale",
		)
		check(
			strip.tabs.plus.get_global_rect().end.x < strip.get_global_rect().end.x - strip._title_margins.y,
			"Tabs and new-tab button leave room for window controls",
		)
		check(
			frame.close.get_global_rect().end.x <= root.get_visible_rect().size.x + 1,
			"Close button fits the window",
		)
		check(frame.edges.size() == 8, "All resize edges are installed")
		if DisplayServer.get_name() != "headless":
			check(
				scrollbar.get_global_rect().end.x <= frame.edges[4].get_global_rect().position.x + 0.5 / scale
				and scrollbar.get_global_rect().end.y <= frame.edges[6].get_global_rect().position.y + 0.5 / scale,
				"Scrollbar input stays inside the window resize edges at each scale",
			)
			check(
				frame.edges.all(
					func(edge):
						return edge.visible,
				),
				"Resizable windows expose all resize edges",
			)
			var transform := root.get_final_transform()
			var border_px := roundi(5 * transform.get_scale().x)
			var right_edge: Rect2 = transform * frame.edges[DisplayServer.WINDOW_EDGE_RIGHT].get_global_rect()
			var bottom_edge: Rect2 = transform * frame.edges[DisplayServer.WINDOW_EDGE_BOTTOM].get_global_rect()
			check(roundi(right_edge.position.x) == root.size.x - border_px and roundi(right_edge.end.x) == root.size.x,
				"Right resize target covers exactly %d physical pixels at %sx" % [border_px, scale])
			check(roundi(bottom_edge.position.y) == root.size.y - border_px and roundi(bottom_edge.end.y) == root.size.y,
				"Bottom resize target meets the last physical row at %sx" % scale)
			var physical = preload("res://scenes/NativeWindowFrame.gd")
			if frame.buttons.get_child_count() > 0:
				check(physical._physical_rect(frame.buttons.get_child(-1)).end.x == root.size.x,
					"Rightmost caption target meets the physical window edge at %sx" % scale)
			if frame.left_buttons.get_child_count() > 0:
				check(physical._physical_rect(frame.left_buttons.get_child(0)).position.x == 0,
					"Leftmost caption target meets the physical window edge at %sx" % scale)
			for group in [frame.left_buttons, frame.buttons]:
				for i in range(1, group.get_child_count()):
					var left: Rect2i = physical._physical_rect(group.get_child(i - 1))
					var right: Rect2i = physical._physical_rect(group.get_child(i))
					check(left.end.x == right.position.x and right.size.x == roundi(44 * transform.get_scale().x),
						"Adjacent caption hit targets share one physical boundary at %sx" % scale)
			for alpha: float in [1.0, 0.55]:
				paint.set_shader_parameter("alpha", alpha)
				await RenderingServer.frame_post_draw
				var raster := root.get_texture().get_image()
				var end := raster.get_size() - Vector2i.ONE
				for x in [0, end.x]:
					for y in [0, end.y]:
						if alpha_available:
							check(raster.get_pixel(x, y).a < 0.01, "Every outer corner is transparent at %sx" % scale)
						else:
							check(raster.get_pixel(x, y).is_equal_approx(raster.get_pixel(end.x / 2, 0)),
								"Square frame border meets the corner at %sx" % scale)
				if not alpha_available:
					var border := raster.get_pixel(end.x / 2, 0)
					# The window ignores the framebuffer's alpha channel without a compositor.
					check(not root.transparent and border.to_html(false) == "515662" and raster.get_pixel(end.x / 2, 1).to_html(false) != "515662",
						"Opaque frame has a one-physical-pixel border")
					continue
				var radius := roundi(12 * root.get_final_transform().get_scale().x)
				check(absf(raster.get_pixel(radius, 0).a - alpha) < 0.01, "World opacity survives beside the corner")
				check(raster.get_pixel(maxi(1, roundi(radius * 0.2)), 1).a < 0.01, "Corner radius follows UI scale")
	probe_layer.visible = false
	root.remove_meta(&"graffitty_window_frame")
	scrollbar._layout_workspace(scroll_view)
	check(
		is_equal_approx(scrollbar.get_global_rect().end.x, scroll_view.get_global_rect().end.x),
		"Windows without a custom frame do not reserve a resize strip",
	)
	root.set_meta(&"graffitty_window_frame", frame)
	scrollbar._layout_workspace(scroll_view)
	frame.close.pressed.emit()
	check(close_requests == 1, "Close uses the window's existing close_requested handler")
	if DisplayServer.get_name() in ["X11", "Wayland"]:
		if DisplayServer.window_is_maximize_allowed(root.get_window_id()):
			await _check_maximize(frame, strip, scrollbar, scroll_view)
		root.mode = Window.MODE_FULLSCREEN
		await create_timer(0.5).timeout
		strip._sync_window_frame()
		check(not frame._mask.visible and frame.resize_border() == 0 and not frame.buttons.visible and strip._title_margins == Vector3.ZERO,
			"Fullscreen is square and reclaims the caption and resize space")
		root.mode = Window.MODE_WINDOWED
		await create_timer(0.5).timeout
		strip._sync_window_frame()
		var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
		if not evidence.is_empty():
			root.content_scale_factor = 1.25
			root.size = Vector2i(1000, 680)
			await create_timer(0.5).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(evidence.path_join("linux-window-frame.png"))
			print("LINUX_WINDOW_FRAME_CAPTURE")
			if "--inspect-frame" in OS.get_cmdline_user_args():
				await create_timer(15.0).timeout
	strip.queue_free()
	host.queue_free()
	scroll_view.queue_free()
	frame.queue_free()
	await process_frame
	print("LINUX_WINDOW_FRAME failures=", failures)
	quit(1 if failures else 0)


# The app also uses _session_window to detach tabs and to open another session.
# Hiding and showing the same Window gives it a fresh native surface.
func _check_workspace_windows(source: Node) -> void:
	var app := root.get_node("TerminalApplication")
	var custom: bool = app.window_decorations == "client"
	var child: Window = app._session_window(source, Vector2i(60, 40), null)
	for mapping in ["new", "remapped"]:
		child.show()
		await process_frame
		var controller = preload("res://scenes/NativeWindowFrame.gd").acquire(child)
		check(child.borderless == custom and (controller != null) == custom, "%s workspace honors decoration preference" % mapping)
		if controller:
			var frame = root.get_meta(&"graffitty_window_frame")
			check(controller.mode == frame.mode, "%s workspace uses the same frame as the main window" % mapping)
		child.hide()
	child.queue_free()
	await process_frame


func _check_maximize(frame: Node, strip: Control, scrollbar: Control, scroll_view: Control) -> void:
	var double_click := InputEventMouseButton.new()
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	strip._gui_input(double_click)
	await create_timer(0.6).timeout
	strip._sync_window_frame()
	check(not frame._mask.visible, "Maximized window has square corners")
	check(root.mode == Window.MODE_MAXIMIZED, "Compositor maximizes the native window")
	check(
		is_equal_approx(scrollbar.get_global_rect().end.x, scroll_view.get_global_rect().end.x),
		"Maximized scrollbar reclaims the hidden resize border",
	)
	check(
		frame.edges.all(
			func(edge):
				return not edge.visible,
		),
		"Maximized frame hides resize edges",
	)
	frame.maximize.pressed.emit()
	await create_timer(0.5).timeout
	check(root.mode == Window.MODE_WINDOWED, "Compositor restores the native window")
