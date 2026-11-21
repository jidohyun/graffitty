extends Node3D
## World-space presentation only. TerminalHost retains all session ownership.
var host: Node
var world: Node3D
var active: Node
var surface := MeshInstance3D.new()
var heading := Label3D.new()
var material := ShaderMaterial.new()
var chromium_rect := Rect2()
var _layout_key := ""
var _opacity := 0.0
var menu: PopupMenu
var close_dialog: ConfirmationDialog
var chrome_view := SubViewport.new()
var chrome: Control
var chrome_fraction := 0.12
var _toolbar_pointer := false
var _toolbar_hover := false
var CHROME_SIZE := Vector2i(640, 90) # Logical input/layout units, not raster pixels.
var _chromium_focus := false
var _chrome_revision := -1
var _mesh_size := Vector2.ZERO
var _mesh_fraction := -1.0
var _outgoing: Array[Dictionary] = []
var _arrival := -1.0
var _arrival_duration := 1.6


func _ready() -> void:
	name = "ChromiumSurface3D"
	process_priority = 100 # Follow the world's navigation/camera update.
	material.shader = preload("res://scenes/chromium_surface.gdshader")
	material.render_priority = 125
	chrome_view.size = CHROME_SIZE * 2
	chrome_view.size_2d_override = CHROME_SIZE
	chrome_view.size_2d_override_stretch = true
	chrome_view.transparent_bg = false
	chrome_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(chrome_view)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("20242c")
	style.set_content_margin_all(4)
	panel.add_theme_stylebox_override("panel", style)
	chrome_view.add_child(panel)
	chrome = preload("res://scenes/ChromiumChrome.gd").new()
	panel.add_child(chrome)
	chrome.close_session_requested.connect(
		func():
			_menu_action(3),
	)
	material.set_shader_parameter("chrome_tex", chrome_view.get_texture())
	surface.mesh = QuadMesh.new()
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	surface.layers = world.INK_MASK
	add_child(surface)
	heading.text = "Chromium · click to open Chrome · right-click for options\nExperimental · sandbox off · no sensitive sites"
	heading.font_size = 28
	heading.outline_size = 4
	heading.no_depth_test = false
	heading.render_priority = 126
	heading.layers = world.INK_MASK
	add_child(heading)
	menu = PopupMenu.new()
	menu.add_item("Open full Chrome UI", 0)
	menu.add_item("Previous chromium", 1)
	menu.add_item("Next chromium", 2)
	menu.add_separator()
	menu.add_item("Close chromium window…", 3)
	menu.id_pressed.connect(_menu_action)
	add_child(menu)


func refresh() -> void:
	if not is_instance_valid(host) or not is_instance_valid(world):
		return
	var next: Node = host.visible_chromium()
	if next != active:
		_retire_surface()
		_opacity = 0.0
		_chromium_focus = false
		_arrival = 0.0
		_arrival_duration = maxf(world.FLY_TIME, world.TAB_FX_LEAVE + world.TAB_FX_ARRIVE)
	active = next
	var viewport_size: Vector2 = world.get_viewport().get_visible_rect().size
	var split := float(host.workspaces.get(host.active_session_id, { }).get("split", 0.55))
	var key := "%s:%s:%s:%s" % [active != null, viewport_size, split, world.active]
	if key != _layout_key:
		_layout_key = key
		if active == null:
			world.workspace_terminal_rect = Rect2(0, 0, 1, 1)
		elif viewport_size.x >= viewport_size.y:
			world.workspace_terminal_rect = Rect2(0, 0.08, split - 0.04, 0.84)
			chromium_rect = Rect2(split + 0.02, 0.08, 0.98 - split, 0.84)
		else:
			world.workspace_terminal_rect = Rect2(0, 0, 1, 0.46)
			chromium_rect = Rect2(0, 0.54, 1, 0.46)
		world._sync_terminal_viewport_size()
	visible = active != null
	if active != null:
		# Quantize width to avoid texture reallocations for small camera/layout
		# movements. Render at screen density, with 2x minimum for tilted text.
		var logical_width := clampi(int(viewport_size.x * chromium_rect.size.x / 32) * 32, 384, 1536)
		# Include the panel's padding; tab shape and toolbar spacing determine
		# their height, including any wrapped session information.
		var logical_height := maxi(90, ceili(chrome.get_combined_minimum_size().y) + 8)
		var logical := Vector2i(logical_width, logical_height)
		var density := clampf(DisplayServer.screen_get_scale(), 2.0, 3.0)
		var raster := Vector2i(Vector2(logical) * density)
		if chrome_view.size != raster:
			CHROME_SIZE = logical
			chrome_view.size = raster
			chrome_view.size_2d_override = logical
			chrome_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		material.set_shader_parameter("chromium_tex", active.texture)
		material.set_shader_parameter(
			"page_ready",
			active.captured_page_id == active.selected_page_id,
		)
		chrome.refresh(active)
		if _chrome_revision != chrome.visual_revision:
			_chrome_revision = chrome.visual_revision
			chrome_view.render_target_update_mode = SubViewport.UPDATE_ONCE
		if chrome.address.has_focus() or chrome.tabs.is_processing():
			chrome_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif chrome_view.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			chrome_view.render_target_update_mode = SubViewport.UPDATE_ONCE


func _process(dt: float) -> void:
	_update_outgoing(dt)
	refresh()
	if active == null or world.active < 0:
		return
	# Match the terminal's arrival window, including fixed-camera tab changes.
	if _arrival >= 0.0:
		_arrival += dt
		var duration: float = _arrival_duration if world.tab_fx_t >= 0.0 or world.fly_dur > 0.0 else world.TAB_FX_ARRIVE
		var p := clampf((_arrival - duration + world.TAB_FX_ARRIVE) / world.TAB_FX_ARRIVE, 0.0, 1.0)
		_opacity = smoothstep(0.0, 1.0, p)
		material.set_shader_parameter("scatter", 1.0 - _opacity)
		if p >= 1.0:
			_arrival = -1.0
	material.set_shader_parameter("opacity", _opacity)
	var gain := 1.0 / maxf(world.tonemap_exposure, 0.0001)
	heading.modulate = Color(gain, gain, gain, _opacity)
	material.set_shader_parameter("exposure_compensation", world.tonemap_exposure)
	var span: Vector2 = world._canvas_span_in_frame()
	var full_size: Vector2 = Vector2.ONE * world.grid_fraction / span
	var uv_size := full_size * chromium_rect.size
	var uv_center := (Vector2.ONE - full_size) * 0.5 + full_size * chromium_rect.get_center()
	var right: Vector3 = world.uv_du.normalized()
	var up: Vector3 = -world.uv_dv.normalized()
	var normal := right.cross(up).normalized()
	var available := Vector2(world.uv_du.length() * uv_size.x, world.uv_dv.length() * uv_size.y)
	var aspect := 1.6
	if active.texture != null and active.texture.get_height() > 0:
		aspect = float(active.texture.get_width()) / active.texture.get_height()
	var chrome_aspect := float(CHROME_SIZE.y) / CHROME_SIZE.x
	chrome_fraction = chrome_aspect / (1.0 / aspect + chrome_aspect)
	aspect = 1.0 / (1.0 / aspect + chrome_aspect)
	material.set_shader_parameter("chrome_fraction", chrome_fraction)
	var width := minf(available.x, available.y * aspect)
	var size := Vector2(width, width / aspect)
	if not size.is_equal_approx(_mesh_size) or not is_equal_approx(chrome_fraction, _mesh_fraction):
		_mesh_size = size
		_mesh_fraction = chrome_fraction
		surface.mesh = preload("res://scenes/ChromiumTransition.gd").mesh(size, chrome_fraction)
		surface.extra_cull_margin = size.length() * 0.5
	material.set_shader_parameter("surface_size", size)
	# Same authored plane and camera as the terminal, slightly lifted off masonry.
	global_transform = Transform3D(
		Basis(right, up, normal),
		world.uv_origin + world.uv_du * uv_center.x + world.uv_dv * uv_center.y + normal * 0.09,
	)
	heading.pixel_size = width / 900.0
	heading.position = Vector3(0, size.y * 0.5 + width * 0.035, 0.01)


func _retire_surface() -> void:
	if active == null or _opacity <= 0.001 or _mesh_size == Vector2.ZERO:
		return
	var ghost := MeshInstance3D.new()
	ghost.mesh = surface.mesh
	ghost.layers = surface.layers
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.extra_cull_margin = _mesh_size.length() * 0.5
	var mat := material.duplicate() as ShaderMaterial
	var toolbar := preload("res://scenes/CellShatter.gd").capture_control(chrome_view.get_child(0))
	ghost.add_child(toolbar)
	mat.set_shader_parameter("chrome_tex", toolbar.get_texture())
	ghost.material_override = mat
	world.add_child(ghost)
	ghost.global_transform = surface.global_transform
	_outgoing.append(
		{
			"node": ghost,
			"toolbar": toolbar,
			"age": 0.0,
			"opacity": _opacity,
			"scatter": float(material.get_shader_parameter("scatter")),
		}
	)


func _update_outgoing(dt: float) -> void:
	for i in range(_outgoing.size() - 1, -1, -1):
		var entry: Dictionary = _outgoing[i]
		entry.age += dt
		var p := clampf(float(entry.age) / world.TAB_FX_LEAVE, 0.0, 1.0)
		var mat: ShaderMaterial = entry.node.material_override
		mat.set_shader_parameter("opacity", float(entry.opacity) * (1.0 - smoothstep(0.0, 1.0, p)))
		mat.set_shader_parameter("scatter", lerpf(float(entry.scatter), 1.0, p))
		var camera: Camera3D = world.cam
		var extent: Vector2 = mat.get_shader_parameter("surface_size")
		var top: Vector3 = entry.node.global_transform * Vector3(-extent.x * 0.5, extent.y * 0.5, 0)
		var right: Vector3 = entry.node.global_transform * Vector3(extent.x * 0.5, extent.y * 0.5, 0)
		if not camera.is_position_behind(top) and not camera.is_position_behind(right):
			var width := camera.unproject_position(top).distance_to(camera.unproject_position(right))
			entry.toolbar.request_extent(Vector2(width, width * float(entry.toolbar.size_2d_override.y) / entry.toolbar.size_2d_override.x))
		if p >= 1.0:
			entry.node.queue_free()
			_outgoing.remove_at(i)


func _exit_tree() -> void:
	for entry in _outgoing:
		if is_instance_valid(entry.node):
			entry.node.queue_free()


func hit_test(point: Vector2) -> bool:
	var uv := surface_uv(point)
	return uv.x >= 0 and uv.y >= 0 and uv.x <= 1 and uv.y <= 1


func surface_uv(point: Vector2) -> Vector2:
	if not visible or _opacity < 0.5:
		return Vector2(-1, -1)
	# Invert the actual world frustum (Camera3D's getter uses a different aspect
	# convention here), then intersect this surface's own plane.
	var fraction := point / world.get_viewport().get_visible_rect().size
	var ray: Vector3 = world.proj_forward + world.proj_right * (
		world.proj_rect.x + fraction.x * world.proj_rect.z
	) + world.proj_up * (world.proj_rect.y + (1.0 - fraction.y) * world.proj_rect.w)
	var normal := global_basis.z
	var denom := ray.dot(normal)
	if absf(denom) < 0.00001:
		return Vector2(-1, -1)
	var distance: float = (global_position - world.proj_eye).dot(normal) / denom
	if distance <= 0:
		return Vector2(-1, -1)
	var local := to_local(world.proj_eye + ray * distance)
	var size: Vector2 = _mesh_size
	return Vector2(local.x / size.x + 0.5, 0.5 - local.y / size.y)


func has_text_focus() -> bool:
	return visible and chrome != null and (_chromium_focus or chrome.address.has_focus())


func handle_workspace_key(event: InputEvent) -> bool:
	if (close_dialog != null and close_dialog.visible) or (menu != null and menu.visible):
		return false
	if visible and event is InputEventKey and has_text_focus():
		if chrome.handle_shortcut(event):
			return true
		if chrome.address.has_focus():
			chrome_view.push_input(event.duplicate(), true)
		# Focus belongs to chromium chrome, never leak typing to the terminal.
		return true
	return false


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		if event is InputEventMouseButton and event.pressed:
			_chromium_focus = hit_test(event.position)
		var uv := surface_uv(event.position)
		var toolbar := uv.x >= 0 and uv.x <= 1 and uv.y >= 0 and uv.y < chrome_fraction
		if toolbar or _toolbar_pointer or (_toolbar_hover and event is InputEventMouseMotion):
			var forwarded := event.duplicate() as InputEventMouse
			forwarded.position = Vector2(
				uv.x * CHROME_SIZE.x,
				uv.y / chrome_fraction * CHROME_SIZE.y,
			)
			forwarded.global_position = forwarded.position
			chrome_view.push_input(forwarded, true)
			chrome_view.render_target_update_mode = SubViewport.UPDATE_ONCE
			_toolbar_hover = toolbar
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
				_toolbar_pointer = event.pressed
			if toolbar or _toolbar_pointer or event is InputEventMouseButton:
				get_viewport().set_input_as_handled()
				return
		if event is InputEventMouseButton and event.pressed:
			chrome.address.release_focus()
	if event is InputEventMouseButton and event.pressed and hit_test(event.position):
		if event.button_index == MOUSE_BUTTON_LEFT:
			active.open_native()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			preload("res://scenes/input/PointerPopup.gd").open(menu)
		else:
			return
		get_viewport().set_input_as_handled()


func _menu_action(id: int) -> void:
	if not is_instance_valid(active):
		return
	if id == 0:
		active.open_native()
	elif id == 1 or id == 2:
		var ids: Array = host.workspaces[active.tab_id].chromiums
		host.select_chromium_surface(
			ids[posmod(ids.find(active.session_id) + (-1 if id == 1 else 1), ids.size())]
		)
	elif id == 3 and close_dialog == null:
		var target: int = active.session_id
		close_dialog = ConfirmationDialog.new()
		close_dialog.title = "Close chromium window?"
		close_dialog.dialog_text = tr("This closes this chromium window and its tabs. Unsaved page state in this window will be lost.") + host.session_end_warning([target])
		add_child(close_dialog)
		close_dialog.confirmed.connect(
			func():
				host.close_chromium_session(target),
		)
		close_dialog.visibility_changed.connect(
			func():
				if not close_dialog.visible:
					close_dialog.queue_free()
					close_dialog = null,
		)
		close_dialog.popup_centered(Vector2i(460, 150))
