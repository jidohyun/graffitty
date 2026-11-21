extends "res://scenes/FlatTerminalSpaceWorld.gd"
## Shares session/config/input helpers with Flat. The inherited Node3D is only
## a host API container: this world creates no 3D camera, mesh, light or
## viewport.
##
## All drawing uses CanvasItems and a Camera2D; the viewport disables 3D
## entirely.
const Place2D = preload("res://scenes/TerminalSurface2D.gd")
const Effects2D = preload("res://scenes/TerminalEffects2D.gd")
var camera_2d := Camera2D.new()
var sheet_2d := Sprite2D.new()
var effects_2d: Node2D
var background_2d := TextureRect.new()
var background_layer := CanvasLayer.new()
var _foreground_layer_2d := CanvasLayer.new()
var _foreground_clip_2d := Control.new()
var _foreground_canvas_2d := Node2D.new()
var _workspace_clip_top_2d := 0.0
var _previous_disable_3d := false
var _previous_hdr_2d := false
var _camera_workspace := -1
var _previous_composite: Material
const Transition2D := preload("res://scenes/TabTransition2D.gd")
var _transition_out: Node2D
var _transition_in: Node2D
var _transition_stale: Array[Node2D] = []
var scrollbar: VScrollBar

func _init() -> void:
	super()
	config_id = "flat-2d"


func _ready() -> void:
	terminal_config = configure_terminal(host.terminal_config.copy())
	term_font_size = terminal_config.font_size
	term_font_size_default = term_font_size
	add_child(fx_camera)
	fx_cfg = Effects.new()
	fx_cfg.load_config(default_config)
	terminal_config.apply_effects(fx_cfg)
	configure_effects(fx_cfg)
	UserConfig.apply_effect_settings(fx_cfg, OS.get_cmdline_user_args())
	for arg in OS.get_cmdline_user_args():
		if arg == "--no-fx": fx_enabled = false
		elif arg == "--no-tabfx": tab_fx_disabled = true
		elif arg == "--no-focus-skip": background_skip = false
		elif arg.begins_with("--shell="): demo_shell = arg.substr(8)
		elif arg.begins_with("--tabs="): flat_tab_count = clampi(int(arg.substr(7)),1,32)
		elif arg.begins_with("--bg="): bg_color = Color(arg.substr(5))
		elif arg.begins_with("--opacity="): background_opacity = clampf(float(arg.substr(10)),0,1)
		elif arg.begins_with("--world="): world_mode = arg.substr(8)
		elif arg.begins_with("--wallpaper="):
			world_mode = "wallpaper"
			wallpaper_path = arg.substr(12)
		elif arg.begins_with("--set="):
			var body := arg.substr(6)
			var at := body.find("=")
			var parts := body.substr(0,at).split(":")
			if at > 0 and parts.size() == 2:
				var raw := body.substr(at+1)
				fx_cfg.set_option(parts[0],parts[1],str_to_var(raw) if str_to_var(raw) != null else raw)
	fx_cfg.set_option("scene.sheet","corner_radius",0.0)
	fx_cfg.set_option("scene.sheet","edge_blur",0.0)
	_fx_apply_scene()
	_load_background_config()
	_previous_disable_3d = get_viewport().disable_3d
	_previous_hdr_2d = get_viewport().use_hdr_2d
	get_viewport().disable_3d = true
	get_viewport().use_hdr_2d = true
	_previous_composite = host.world_container.material
	var composite := ShaderMaterial.new()
	composite.shader = preload("res://scenes/linear_canvas_composite.gdshader")
	host.world_container.material = composite
	get_viewport().transparent_bg = background_opacity < 1.0
	preload("res://scenes/DesktopBlur.gd").set_window_transparent(get_window(), background_opacity < 1.0)
	RenderingServer.set_default_clear_color(Color.TRANSPARENT)
	background_layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.BACKGROUND
	add_child(background_layer)
	background_2d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background_2d.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background_2d.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	var image := Image.create(1,1,false,Image.FORMAT_RGBA8)
	image.fill(bg_color)
	background_2d.texture = ImageTexture.create_from_image(image)
	if world_mode == "wallpaper" and not wallpaper_path.is_empty():
		var wallpaper := Image.load_from_file(ProjectSettings.globalize_path(UserConfig.expand_home(wallpaper_path)))
		if wallpaper != null: background_2d.texture = ImageTexture.create_from_image(wallpaper)
	background_2d.modulate.a = background_opacity
	background_layer.add_child(background_2d)
	# Keep the background full-window while clipping workspace content below
	# the tab bar. The fixed canvas layer makes this a screen-space scissor;
	# its child carries the unchanged Camera2D projection.
	_foreground_layer_2d.layer = preload("res://scenes/WorkspaceLayers.gd").Order.CONTENT
	add_child(_foreground_layer_2d)
	_foreground_clip_2d.name = "WorkspaceForegroundClip"
	_foreground_clip_2d.clip_contents = true
	_foreground_clip_2d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_foreground_layer_2d.add_child(_foreground_clip_2d)
	_foreground_clip_2d.add_child(_foreground_canvas_2d)
	camera_2d.name = "Camera2D"
	add_child(camera_2d)
	camera_2d.make_current()
	# Camera2D's internal tick writes the canvas transform even at rest. This
	# world already drives every camera pose explicitly, including navigation.
	camera_2d.process_mode = Node.PROCESS_MODE_DISABLED
	camera_2d.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	fx_mat = ShaderMaterial.new()
	fx_mat.shader = preload("res://scenes/terminal_sheet_2d.gdshader")
	fx_mat.set_shader_parameter("workspace_canvas",true)
	fx_mat.set_shader_parameter("wall_shade",0.0)
	fx_mat.set_shader_parameter("terminal_tex",host.workspace_view.canvas.get_texture())
	sheet_2d.name = "WorkspaceCanvas2D"
	sheet_2d.centered = false
	sheet_2d.texture = host.workspace_view.canvas.get_texture()
	sheet_2d.material = fx_mat
	_foreground_canvas_2d.add_child(sheet_2d)
	effects_2d = Effects2D.new()
	effects_2d.effect_control = effect_control
	effects_2d.automatic = false
	_foreground_canvas_2d.add_child(effects_2d)
	effects_2d.configure(fx_cfg)
	effects_2d.typed.connect(_typed_2d)
	# Places only identify persistent sessions. No per-tab renderer allocation.
	var existing: Array = host.get_terminal_tabs()
	var count := existing.size() if not existing.is_empty() or host.restoring_window else flat_tab_count
	for i in count:
		var index := _append_terminal_surface(0)
		surfaces[index].session_id = existing[i].id if i < existing.size() else host.allocate_session_id()
	for transferred in host.initial_surfaces: transferred.free()
	host.initial_surfaces.clear()
	if host.initial_surface != null:
		host.initial_surface.free()
		host.initial_surface = null
	_publish_tabs()
	host.session_requested.connect(_on_session_requested)
	var focused: int = _initial_terminal()
	var index := _surface_for_session(focused)
	_goto(index if index >= 0 else 0,true)
	_build_scrollbar()
	get_window().size_changed.connect(_on_window_size_changed)
	get_viewport().size_changed.connect(_on_window_size_changed)
	_on_window_size_changed()
	host._sync_world_chrome_clip()
	_set_world_awake(get_window().has_focus() or not background_skip)

func _exit_tree() -> void:
	_cancel_transition_preparation()
	if is_instance_valid(get_viewport()):
		get_viewport().disable_3d = _previous_disable_3d
		get_viewport().use_hdr_2d = _previous_hdr_2d
	if is_instance_valid(host.world_container): host.world_container.material = _previous_composite

func _build_scrollbar() -> void:
	scrollbar = host.ui.mount_scroll_bar(self)

func _publish_tabs() -> void:
	var definitions: Array[Dictionary] = []
	for i in surfaces.size():
		definitions.append({"id":surfaces[i].session_id,"label":tr("Terminal %d") % (i+1)})
	host.set_tabs(definitions)

func _append_terminal_surface(_source_index: int, _spare := true) -> int:
	var place := Place2D.new()
	place.surface_id = "terminal_%d" % surfaces.size()
	add_child(place)
	surfaces.append(place)
	return surfaces.size()-1

func _seat_tabs() -> void:
	pass

func create_terminal_tab() -> void:
	host.session_backend.create_tab(host)


func add_terminal_window(session_id: int, _tab_ordinal := -1) -> void:
	var index := _append_terminal_surface(0)
	surfaces[index].session_id = session_id
	_publish_tabs()

func import_terminal_tab(session_id: int, _template: Node = null) -> void:
	var index := _append_terminal_surface(0)
	surfaces[index].session_id = session_id
	_goto(index,true)
	host.ui_changed.emit()

func remove_terminal_tab(index: int) -> void:
	var selected: int = host.active_session_id
	var removing_active := active == index
	surfaces[index].queue_free()
	surfaces.remove_at(index)
	_publish_tabs()
	if not removing_active:
		active -= 1 if index < active else 0
		return
	active = -1
	var next := _surface_for_session(selected)
	_goto(next if next >= 0 else mini(index,surfaces.size()-1),true)

func follow_tab_order() -> void:
	var first := _first_terminal(host.workspace_layout.tab(host.workspace_layout.active))
	var next := _surface_for_session(first)
	if next >= 0 and next != active: _goto(next,false)

func cancel_typing_effects() -> void:
	super.cancel_typing_effects()
	if is_instance_valid(effects_2d): effects_2d.cancel_typing()

func _initial_terminal() -> int:
	if host.active_session_id >= 0: return host.active_session_id
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var focused := str(group.get("focused", ""))
	if host.is_terminal_pane(focused) and focused in WorkspaceLayoutScript.keys(group.get("tree", {})):
		return int(focused.substr(1))
	return _first_terminal(group)

func _focus_session(index: int) -> void:
	var pair: Dictionary = host.session_for(index,self)
	if pair.is_empty(): return
	if pair.term != term:
		term = pair.term
		term_vp = pair.vp
		_apply_terminal_config()
		fx_cell_px = _terminal_cell_px()
		effects_2d.bind_terminal(term,fx_mat,func(uv): return uv * _sheet_size(),_terminal_presentation_frame)
	host.activate_session(pair)
	term.call_deferred("grab_focus")

func _clear_switch_visuals() -> void:
	for layer in [_transition_out, _transition_in] + _transition_stale:
		if is_instance_valid(layer): layer.hide()
	_end_transition_2d(true)

func begin_session_transition() -> void:
	_end_transition_2d(true)
	if session_transition_capture.has("layer"):
		session_transition_capture.layer.queue_free()
	session_transition_capture.clear()
	_set_session_transition_active(fx_cfg.scene.session_switch.effect != "none" and fx_enabled and effect_control.allows("session_switch"))
	if not session_transition_active or active < 0: return
	var snapshot := Transition2D.new()
	_foreground_canvas_2d.add_child(snapshot)
	snapshot.build(self)
	snapshot.hide()
	session_transition_capture = {"layer": snapshot,
		"camera": _canvas_camera_frame(camera_2d.position, camera_2d.zoom)}

func finish_session_transition() -> void:
	if session_transition_capture.is_empty(): return
	_end_transition_2d(true)
	session_transition_active = true
	_transition_out = session_transition_capture.layer
	camera_motion.reset(session_transition_capture.camera)
	camera_motion.retarget(_canvas_camera_target(), _navigation_duration())
	fly_dur = camera_motion.duration
	fly_t = 0.0
	_display_canvas_camera_frame(camera_motion.frame)
	session_transition_capture.clear()
	_transition_out.show()
	sheet_2d.hide()
	tab_fx_dur = _transition_duration()
	tab_fx_t = 0.0
	_begin_transition_preparation()
	host.workspace_view.set_connection_transition(true)

func _goto(index: int, instant: bool) -> void:
	if index < 0 or index >= surfaces.size() or index == active: return
	instant = instant or host.instant_workspace_switch
	var workspace: int = host.workspace_layout.containing("%%%d" % surfaces[index].session_id)
	# Removing a pane rebinds the sheet instantly. While staying in the same
	# workspace, let its current typing animation finish instead of snapping idle.
	var retain_typing := instant and workspace >= 0 and workspace == _camera_workspace
	_camera_workspace = workspace
	var previous := active
	if not host.session_switch_in_progress: _set_session_transition_active(false)
	tab_fx_direction = _tab_direction(previous, index)
	var animate: bool = previous >= 0 and not instant and not host.session_switch_in_progress and tab_fx and effect_control.allows("tab_switch") and fx_enabled
	if not animate: _end_transition_2d(true)
	# Retarget from the displayed pose and velocity, including an interrupted
	# flight or typing zoom. Depth, rather than magnification, matches Flat 3D.
	camera_motion.frame = _canvas_camera_frame(camera_2d.position, camera_2d.zoom)
	if previous < 0 or instant or not fly_glide:
		camera_motion.reset(camera_motion.frame)
	if animate:
		_start_transition_2d()
	active = index
	host.workspace_view.restore_navigation(workspace)
	_focus_session(surfaces[index].session_id)
	if not retain_typing:
		fx_last_key = -1e8
		gesture_zoom = 1.0
		_settle_camera_at_rest()
	if previous >= 0 and not instant and fx_enabled:
		camera_motion.retarget(_canvas_camera_target(), _navigation_duration())
		fly_dur = camera_motion.duration
	else:
		camera_motion.reset(_canvas_camera_target())
		fly_dur = 0.0
	fly_t = 0.0

	_apply_camera_fx()

func _terminal_content_rect(texture_size: Vector2i) -> Rect2:
	return Rect2(Vector2.ZERO,Vector2(texture_size))

func _terminal_font_scale() -> float:
	return 1.0

func _on_window_size_changed() -> void:
	if not is_inside_tree(): return
	background_2d.size = get_viewport().get_visible_rect().size
	host.workspace_view.sync_canvas()
	_apply_camera_fx()
	host.workspace_view.update_raster_region()

func set_workspace_render_region(region: Rect2) -> void:
	fx_mat.set_shader_parameter("texture_region",Vector4(region.position.x,region.position.y,region.size.x,region.size.y))
	fx_mat.set_shader_parameter("tex_size",_sheet_size())
	sheet_2d.position = region.position * _sheet_size()
	sheet_2d.scale = region.size * _sheet_size() / Vector2(sheet_2d.texture.get_size()).max(Vector2.ONE)

func set_workspace_clip_top(top: float) -> void:
	_workspace_clip_top_2d = clampf(top, 0.0, 1.0)
	_sync_foreground_clip_2d()

func _sync_foreground_clip_2d() -> void:
	if not _foreground_clip_2d.is_inside_tree(): return
	var viewport_size := get_viewport().get_visible_rect().size
	var origin := Vector2(0.0, viewport_size.y * _workspace_clip_top_2d)
	var extent := Vector2(viewport_size.x, maxf(viewport_size.y - origin.y, 0.0))
	if _foreground_clip_2d.position != origin:
		_foreground_clip_2d.position = origin
	if _foreground_clip_2d.size != extent:
		_foreground_clip_2d.size = extent
	var projection := get_viewport().canvas_transform
	projection.origin -= origin
	if _foreground_canvas_2d.transform != projection:
		_foreground_canvas_2d.transform = projection

static func _canvas_camera_frame(center: Vector2, zoom: Vector2) -> Dictionary:
	# A virtual perspective camera over the canvas: one unit of lens width,
	# reciprocal zoom as depth, and the pixel aspect in the lens height.
	var aspect := zoom.x / zoom.y
	return CameraMotionScript.pose(Vector3(center.x, center.y, 1.0 / zoom.x),
		Vector3.FORWARD, Vector3.UP, Vector4(-0.5, -0.5 * aspect, 1.0, aspect))

func _canvas_camera_target() -> Dictionary:
	var view: Control = host.workspace_view
	var logical := _sheet_size()
	var physical := get_viewport().get_visible_rect().size / logical
	var adaptive := _adaptive_framing_enabled()
	var zoom := (fx_camera.target_zoom if adaptive else fx_cam_zoom) * gesture_zoom if fx_enabled else 1.0
	var center := (fx_camera.framing_pan if adaptive else fx_camera.render_pan) if fx_enabled and fx_camera.initialized else logical * 0.5
	var reference_zoom := gesture_zoom if fx_enabled else 1.0
	var reference_center := logical * .5
	if view.uses_navigation_camera():
		zoom = _navigation_camera_zoom()
		center = _navigation_camera_center()
		reference_zoom = view.navigation_zoom
		reference_center = view.navigation_center
	# Flat's decal sits 0.06 units ahead of its reference plane. Preserve that
	# small apparent magnification so the same pane edges land on the same pixels.
	var flat_distance := 20.0 * maxf(logical.x / logical.y,1.0)
	var apparent_zoom := maxf(zoom,0.01) / maxf(1.0 - TERMINAL_SURFACE_LIFT * zoom / flat_distance,0.01)
	var candidate := _canvas_camera_frame(center, physical * apparent_zoom)
	if not adaptive: return candidate
	var reference_apparent := maxf(reference_zoom, .01) / maxf(1.0 - TERMINAL_SURFACE_LIFT * reference_zoom / flat_distance, .01)
	var reference := _canvas_camera_frame(reference_center, physical * reference_apparent)
	# Keep a stable depth and express the entire zoom in the lens. Only the
	# final fitted destination is eased, not a correction to an easing camera.
	var target := _canvas_camera_frame(center, physical * reference_apparent)
	target.rect *= reference_apparent / apparent_zoom
	if _adaptive_containment_active():
		var fitted: Vector3 = CameraMotionScript._core().contain_canvas(logical, _adaptive_visible_fraction(), _adaptive_content_rect, center, apparent_zoom)
		target.rect = reference.rect * (reference_apparent / fitted.z)
		var pose: Transform3D = target.transform
		pose.origin.x = fitted.x
		pose.origin.y = fitted.y
		target.transform = pose
	return fx_camera.project(reference, target)

func _display_canvas_camera_frame(frame: Dictionary) -> void:
	var eye: Vector3 = frame.transform.origin
	var center := Vector2(eye.x, eye.y)
	var zoom := Vector2.ONE / (Vector2(frame.rect.z, frame.rect.w) * maxf(eye.z, 0.0001))
	if not camera_2d.position.is_equal_approx(center) or not camera_2d.zoom.is_equal_approx(zoom):
		camera_2d.position = center
		camera_2d.zoom = zoom
		camera_2d.force_update_scroll()
	_sync_foreground_clip_2d()
	_notify_workspace_projection_changed()

func _apply_camera_fx(_cursor_uv := Vector2.INF) -> void:
	if not camera_2d.is_inside_tree(): return
	_display_canvas_camera_frame(camera_motion.frame if camera_motion.moving else _canvas_camera_target())

func _step_canvas_navigation(dt: float) -> void:
	if not camera_motion.moving: return
	var destination := _canvas_camera_target()
	if not destination.transform.is_equal_approx(camera_motion._target.transform) or not destination.rect.is_equal_approx(camera_motion._target.rect):
		# Layout or a viewport resize may finish after the tab changed. Keep the
		# incoming velocity and original deadline when its final framing changes.
		camera_motion.retarget_remaining(destination)
	camera_motion.advance(dt)
	fly_t = camera_motion.elapsed / camera_motion.duration
	if not camera_motion.moving:
		fly_t = 0.0
		fly_dur = 0.0

func _workspace_projection_frame() -> Array:
	return [get_viewport().canvas_transform]

func title_navigation_scale(_point: Vector2) -> float:
	var view: Control = host.workspace_view
	var zoom: float = view.navigation_zoom if view.uses_navigation_camera() else 1.0
	var logical := _sheet_size()
	var distance := 20.0 * maxf(logical.x / logical.y, 1.0)
	return maxf(1.0 - TERMINAL_SURFACE_LIFT * zoom / distance, .01) / maxf(zoom, .01)


func sheet_point_at(fraction: Vector2) -> Vector2:
	var point := get_viewport().canvas_transform.affine_inverse() * (fraction * get_viewport().get_visible_rect().size)
	return _saddle_uv(point / _sheet_size(),true) * _sheet_size()

func sheet_window_fraction(point: Vector2) -> Vector2:
	return (get_viewport().canvas_transform * (_saddle_uv(point / _sheet_size()) * _sheet_size())) / get_viewport().get_visible_rect().size

func _cursor_window_point() -> Vector2:
	return sheet_window_fraction(_camera_cursor_uv() * _sheet_size()) * get_viewport().get_visible_rect().size

func _typed_2d(_uv: Vector2) -> void:
	fx_camera.resume_projection()
	effect_control.pulse()
	fx_last_key = fx_time
	workspace_typed.emit()
	var frame: Dictionary = fx_cfg.frame(str(fx_cfg.behavior.active_state))
	if effect_control.allows("camera.shake"):
		fx_camera.typed(float(frame["camera.shake_px"]),float(frame["camera.shake_seconds"]))

func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("Flat2DWorld", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	if term == null: return
	var elapsed := _transition_elapsed(dt)
	dt = minf(dt,0.05)
	fx_time += dt
	effect_control.advance(dt, fx_enter_duration, fx_leave_duration)
	_step_canvas_navigation(elapsed)
	_update_ime_anchor()
	var target := 1.0 if fx_time-fx_last_key < fx_idle_after and fx_enabled else 0.0
	var ramp := fx_enter_duration if target > fx_typing else fx_leave_duration
	fx_typing = lerpf(fx_typing,target,1.0-pow(2.0,-10.0*dt/maxf(ramp,0.001)))
	var frame := _fx_frame(fx_typing)
	var camera_typing := target > 0 and not camera_motion.moving and effect_control.camera_active()
	var destination: Dictionary = fx_cfg.frame(str(fx_cfg.behavior.active_state if camera_typing else fx_cfg.behavior.rest_state))
	destination = _controlled_frame(destination, true)
	fx_cell_px = _terminal_cell_px()
	_update_camera_follow_bounds()
	_prepare_adaptive_camera(fx_camera)
	fx_camera.advance(dt,_camera_cursor_center(),_sheet_size(),fx_cell_px,
		float(destination["camera.zoom"]) if fx_enabled else 1.0,0.0,
		float(destination["camera.drift_px"]) if fx_enabled else 0.0,float(destination["camera.drift_speed"]),
		camera_typing,maxf(ramp,0.001),tab_fx_t < 0.0)
	_advance_navigation_camera(dt, destination, camera_typing, ramp)
	fx_cam_zoom = fx_camera.zoom
	fx_cam_tilt = Vector2.ZERO
	fx_curvature_deg = 0.0 # A depth-dependent sheet bend has no 2D analogue.
	_apply_camera_fx()
	_update_transition_2d(elapsed)
	if not camera_motion.moving:
		camera_motion.observe(_canvas_camera_frame(camera_2d.position, camera_2d.zoom), elapsed)
	effects_2d.enabled = fx_enabled
	effects_2d.sheet_viewport = host.workspace_view.canvas
	effects_2d.sheet_origin = _terminal_sheet_origin()
	effects_2d.sheet_scale = _terminal_sheet_scale()
	effects_2d.sheet_panel = Rect2(0,0,1,1)
	effects_2d.cursor = _camera_cursor_uv()
	effects_2d.camera_zoom = fx_cam_zoom
	effects_2d.advance(dt,frame)
	effects_2d.advance_cursor(dt)
	_notify_workspace_projection_changed()

func _terminal_presentation_frame(point: Vector2) -> Variant:
	if is_instance_valid(_transition_in) or is_instance_valid(_transition_out) or tab_fx_preparing:
		for layer in [_transition_in, _transition_out]:
			if not is_instance_valid(layer): continue
			var displayed = layer.presentation_point(term_vp, point, effects_2d)
			if displayed != null: return displayed
		return null
	return _terminal_sheet_origin() + point * _terminal_sheet_scale()

func _start_transition_2d() -> void:
	var capture_live_sheet := sheet_2d.visible
	# An interrupted flight keeps its visible layers and retires them smoothly.
	for layer in [_transition_out, _transition_in]:
		if is_instance_valid(layer):
			layer.retire()
			_transition_stale.append(layer)
	# Repeated interruptions retain at most two outgoing snapshots.
	while _transition_stale.size() > 2:
		_transition_stale.pop_front().queue_free()
	_transition_out = null
	_transition_in = null
	if capture_live_sheet:
		_transition_out = Transition2D.new()
		_foreground_canvas_2d.add_child(_transition_out)
		_transition_out.build(self)
	sheet_2d.hide()
	tab_fx_dur = _transition_duration()
	tab_fx_t = 0.0
	_begin_transition_preparation()
	host.workspace_view.set_connection_transition(true)

func _discard_transition_arrival() -> void:
	if is_instance_valid(_transition_in): _transition_in.queue_free()
	_transition_in = null

func _build_transition_arrival() -> void:
	_building_switch_arrival = true
	_transition_in = Transition2D.new()
	_transition_in.arriving = true
	_foreground_canvas_2d.add_child(_transition_in)
	# Capture screen-space chrome at its final camera, like Flat 3D.
	var displayed := _canvas_camera_frame(camera_2d.position, camera_2d.zoom)
	_display_canvas_camera_frame(_canvas_camera_target())
	host.workspace_view._update_compact_headers(true)
	host.workspace_view._sync_chromium_links()
	_transition_in.build(self)
	_building_switch_arrival = false
	_display_canvas_camera_frame(displayed)

func _update_transition_2d(dt: float) -> void:
	for layer in _transition_stale.duplicate():
		if not layer.advance_retirement(dt):
			_transition_stale.erase(layer)
			layer.queue_free()
	if tab_fx_t < 0.0: return
	if tab_fx_t >= tab_fx_dur:
		_finish_transition_2d()
		return
	tab_fx_t = minf(tab_fx_t + dt, tab_fx_dur)
	if is_instance_valid(_transition_out):
		_transition_out.set_progress(tab_fx_t / _tab_departure_duration())
	var arrival_duration := _tab_arrival_duration()
	var arrive_at := _tab_arrival_start()
	if is_instance_valid(_transition_in):
		_transition_in.set_progress(1.0 - (tab_fx_t - arrive_at) / arrival_duration)

func _finish_transition_2d() -> void:
	# Like 3D, draw the assembled capture and settled live crop before swapping.
	var generation := _tab_fx_generation
	# The arrival has landed; a slower departure (fly away) keeps flying over
	# the live sheet instead of delaying it.
	if is_instance_valid(_transition_out) and _transition_out.progress < 1.0:
		_transition_out.retire()
		_transition_stale.append(_transition_out)
		_transition_out = null
	tab_fx_t = -1.0
	_release_prepared_viewports()
	_notify_workspace_projection_changed()
	host.workspace_view.update_raster_region()
	host.workspace_view._update_compact_headers()
	host.workspace_view._sync_chromium_links()
	_wait_for_live_transition_frame(generation)

func _complete_live_transition() -> void:
	_end_transition_2d()

func _end_transition_2d(clear_stale := false) -> void:
	_cancel_transition_preparation()
	for layer in [_transition_out, _transition_in]:
		if is_instance_valid(layer): layer.queue_free()
	_transition_out = null
	_transition_in = null
	if clear_stale:
		for layer in _transition_stale: layer.queue_free()
		_transition_stale.clear()
	tab_fx_t = -1.0
	host.workspace_view.set_connection_transition(false)
	sheet_2d.show()
	if is_instance_valid(effects_2d): effects_2d.show()
