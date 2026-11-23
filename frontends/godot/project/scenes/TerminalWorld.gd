extends Node3D
signal workspace_projection_changed
signal workspace_typed

var _workspace_projection: Array = []
var _workspace_clip_top := 0.0
const ViewportUpdates := preload("res://scenes/TerminalViewportUpdates.gd")
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
## Optional all-in-one workspace presenter. Basic worlds own their own UI.
@export var terminal_space_scene: PackedScene
const WorkspaceLayoutScript := preload("res://scenes/WorkspaceLayout.gd")
const CameraMotionScript := preload("res://scenes/CameraMotion.gd")
var camera_motion := CameraMotionScript.new()
var _camera_observed := false
var fly_glide := true
const UserConfig := preload("res://config/UserConfig.gd")
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
var terminal_config: TerminalConfig
var terminal_window := preload("res://scenes/WorldAppearance.gd").new()
var window_config: RefCounted
# World-owned geometry, deliberately not in TerminalConfig.
var backdrop_fill_viewport := true
var terminal_padding := 8.0
## Shared terminal world kit: live nodes, input/IME, framing and effects.
var effect_control := preload("res://scenes/EffectControl.gd").new()
var host: Node
# In-world presenters reserve part of the existing sheet, not a screen viewport.
var workspace_terminal_rect := Rect2(0, 0, 1, 1)
var default_config := "res://presets/flat.conf"
var fixed_tab_camera := true
var background_opacity := 1.0
var flat_tab_count := 1
## The flat world's paper is ours to shape; authored walls keep their aspect.
var flat_sheets := false
var dt_last := 0.0

const FLY_TIME := 1.6
## Switching tabs in a 3D world: the screen comes apart on the wall it leaves,
## drifts while the camera crosses the room, and is put back together on the
## wall it arrives at.
##
## Camera and incoming groups ease to rest together, using the final
## half-second for a shared landing instead of a stationary tail.
const TAB_FX_LEAVE := 1.5 ## the old screen is past the viewer by here
const TAB_FX_ARRIVE := preload("res://scenes/ScatterMotion.gd").ARRIVAL
const TAB_FX_SETTLE := 0.5 ## camera and scatter share this gentle landing interval
const FLY_AWAY_ARRIVAL_DELAY := 0.08 ## Seconds before the incoming screen follows the departing pieces.
## How far past the eye a piece carries before it is gone, in world units.
const TAB_FX_PAST := 1.2
## How thick a flying glyph looks, in fractions of a cell.
const TAB_FX_THICKNESS := 0.16
## How hard a piece accelerates along its path. 1 is a constant speed.
const TAB_FX_EASE := 2.4
## Render priority of the lowest window's frame in a switch. Each window takes
## three above the one below it: frame, background, text.
const TAB_FX_WINDOW_PRIORITY := CoreTerminalEffects.SHEET_RENDER_PRIORITY

# Exposure values used by the world camera: the authored-world lighting calibration.
# They do not set depth of field; update_lens() sets the blur directly.
const F_APERTURE := 16.0
const F_SHUTTER := 125.0
const F_ISO := 100.0
# Full-frame horizontal sensor width.
#
# The active wall supplies its horizontal field of view as `pose_half_x =
# tan(hfov / 2)`, so this converts that field of view to the focal length used
# solely by the physical DoF calculation.
const PHYSICAL_SENSOR_WIDTH_MM := 36.0
# The terminal grid occupies this centered portion of the WINDOW, at the
# window's own aspect.
#
# The wall is framed to COVER the window (_apply_camera_fx), so the grid is
# whatever rectangle of the wall texture lands on that fraction of the frame —
# see _terminal_content_rect().
const TERMINAL_FRAME_FRACTION := 0.90
# 1.0 covers the window exactly. Larger pulls the camera back and lets the world
# show around the canvas, which is a letterbox by another name.
const CANVAS_COVER_MARGIN := 1.0
# The terminal surface is a decal over the corresponding world wall. Keep it
# a few centimetres toward the viewer to avoid coplanar depth fighting.
const TERMINAL_SURFACE_LIFT := 0.06

## Every destination in this world, in tab order. Elements are
## [TerminalSurface3D] nodes living in the scene tree — an authored world
## puts them there in the editor, the flat world builds them below.
var surfaces: Array = []
var accents: Array = []
var walls: Dictionary = { }
var focus_points: Dictionary = { } # id -> Vector3, Filament focusPoint()
## The world's own places that no tab stands at, in the world's order. A new
## tab takes the first of them before it doubles up on a place in use.
var spare_places: Array = []
var cam: Camera3D
var backdrop_color := Color.TRANSPARENT
var backdrop_texture: Texture2D
var scenery_material: ShaderMaterial
var term_vp: SubViewport
var term: Node
var tabs: Control
var active := -1
var wall_shade := 0.3

# flight state, mirroring background.inc
var fly_t := 0.0
var fly_dur := 0.0
## Carry speed from an interrupted camera flight into the next leg.
##
## This coefficient scales the cubic Hermite tangent basis `t(1-t)^2`.
## It sets the new leg's starting speed to the interrupted leg's speed.
## Uninterrupted flights use zero and keep their exact quintic path.
var fly_carry := 0.0
## Use a cubic base when carrying speed from an interrupted leg.
##
## `f(t) = t^2(3-2t) + c*t(1-t)^2` has slope `(1-t)[6t + c(1-3t)]`.
## Keeping `c` in [0, 3] makes the slope nonnegative over [0, 1].
## The flight therefore never reverses or overshoots.
##
## The quintic starts too flat for that carry and can reverse near the
## end. A leg that starts in motion also has no need for zero initial
## acceleration.
##
## `--film=30` advances the flight by 1/30 s per frame. Encoding PNGs
## can take much longer than drawing. The fixed step saves the same
## samples as a 30 fps flight, regardless of write time.
var film_fps := 0
var film_dt := 0.0
## Tab captures belong to their world surfaces while the camera moves between them.
var camera_relative_tab_fx := false
var tab_fx_disabled := false
var tab_fx := true ## --no-tabfx turns the transition off
var tab_fx_t := -1.0 ## < 0 when no transition is running
var _tab_fx_generation := 0
var tab_fx_preparing := false
var _tab_fx_capture_pending := false
var _tab_fx_just_prepared := false
var _tab_fx_prepared_viewports: Array[SubViewport] = []
var _tab_fx_layout_started := false
var _tab_fx_layout_frame: Array = []
var tab_fx_dur := 1.0 ## the flight this transition has to cover
var lens_transition_t := -1.0
var lens_transition_from := 1.0
var lens_transition_zoom_from := 1.0
var lens_transition_optics_from := Vector3(0.0, 0.0263, 0.0)
var terminal_lens_zoom := 1.0
var lens_transition_duration := FLY_TIME
# Fade only terminal defocus while glyphs travel; retain the authored resting DOF.
var terminal_dof_weight := 1.0
var terminal_dof_from := 1.0
var terminal_dof_target := 1.0
var terminal_dof_elapsed := 0.0
var tab_fx_out: Array = [] ## layers leaving the wall behind us
var tab_fx_in: Array = [] ## layers landing on the wall ahead
var tab_fx_wall: MeshInstance3D = null
var probe_freeze := false ## --rt=noprocess: is the frame CPU or GPU?
## Put the terminal wall on a separate visual layer so a second camera
## can draw it alone. Layer 1 contains everything else.
const INK_LAYER := 2
const INK_MASK := 1 << (INK_LAYER - 1)
## At rest the terminal is drawn through a viewport of its own: native
## resolution, no post-processing, no antialiasing.
##
## During a flight it goes back into the 3D view, because that is where it is
## occluded correctly by the scenery it is passing.
var ink_vp: SubViewport = null
var ink_cam: Camera3D = null
var ink_overlay: TextureRect = null
var ink_active := false
## Both passes share geometry, but only scenery sees lights and shadows.
var ink_enabled := true
var scenery_vp: SubViewport
var _scenery_live := true
var _scenery_dirty := true
var _scenery_camera_snapshot: Array = []
var _scenery_animation_nodes: Array[Node] = []
var _scenery_animation_scan := true
var _scenery_particles_until := 0
## The motion scale starts after this many consecutive moving frames, so the
## isolated sub-pixel nudges of a settling camera stay at full resolution.
const SCENERY_MOTION_FRAMES := 3
## Brief pauses between pointer events or keystrokes keep the motion scale,
## so they do not reallocate the render buffers twice.
const SCENERY_MOTION_HOLD_MSEC := 200
## Scenery 3D scale at rest (x) and while the camera moves (y).
var _scenery_scales := Vector2.ONE
var _scenery_moved_msec := -SCENERY_MOTION_HOLD_MSEC
var _scenery_motion_frames := 0
## Plugins with procedural/TIME-based scenery can opt into continuous rendering.
var scenery_continuous := false
var _compositor_had_3d_disabled := false
var ink_part := "all" ## vp | overlay | all, for narrowing a fault
## A terminal spends most of its life behind something else.
##
## Stopping the renderer outright when the window loses focus is the usual
## answer, and this does the same to the world — but never to the terminal.
##
## The pty, the viewport and the process are untouched: output still arrives,
## the cursor still blinks, and clicking back is instant. Only the scenery and
## the camera's animation stop.
var background_skip := true ## --no-focus-skip turns it off
var world_awake := true
var pointer_active_until := 0
## Scale the 3D render after capping it to the display's pixel count.
##
## In one fullscreen measurement, a scale of 0.8 after the cap halved
## the frame time and lost 2% of the gradient.
var render_scale := 0.8
## Scenery scale while the camera moves: typing, gestures and flights. The
## frame left on screen returns to render_scale; at or above it, this is off.
var motion_render_scale := 1.0
var key_light: DirectionalLight3D = null
var terminals: Dictionary = { } ## surface id -> {"vp": SubViewport, "term": Node}
var tab_fx_out_target := Vector3.ZERO
var tab_fx_in_target := Vector3.ZERO
## Keep pieces in motion when another switch interrupts their flight.
## They follow their current paths and fade at the end to avoid a visible cut.
##
## Each entry holds `{layer, target, fly, speed}`.
var tab_fx_stale: Array = []
var tab_fx_direction := 1.0
const DepthMotion := preload("res://scenes/TabDepthMotion.gd")
const SwitchTimeline := preload("res://scenes/SwitchTimeline.gd")
var fly_from: Dictionary = { }
# Navigation graph lifted out of Filament's KWALL002 sidecar. The first
# walls.size() nodes are the wall eyes, which is why route() can take wall
# indices directly.
#
# Without this the camera flies straight and cuts through the masonry;
# Filament routes around it.
var fx_tilt_light_strength := 0.5
var fx_tilt_light_min := 0.45
var fx_tilt_light_max := 1.15
var fx_tilt_light_color := Color("#fff0dc")
var fx_tilt_shadow_color := Color("#9db2d6")
var fx_shadow_tint_strength := 1.0
var fx_plane_lean_scale := 1.0
var fx_plane_lift := 0.0
var fx_prev_frame: Dictionary = { }
var fx_cam_zoom := 1.0
var fx_cam_tilt := Vector2.ZERO # radians: yaw, pitch
var fx_cam_pan := Vector2.ZERO
# Current stable framing in page-normalised units. Decorations are added only
# after this has eased toward its cursor-follow target.
var fx_follow_pan := Vector2.ZERO
var fly_from_distance := 1.0
var pose_eye := Vector3.ZERO
var pose_forward := Vector3.FORWARD
var pose_up := Vector3.UP
var pose_half_x := 0.5
# The camera as _apply_camera_fx() last left it, kept because projecting a world
# point has to use the frustum that was actually drawn (see _project_to_window).
var proj_eye := Vector3.ZERO
var proj_forward := Vector3.FORWARD
var proj_right := Vector3.RIGHT
var proj_up := Vector3.UP
var proj_rect := Vector4(-0.5, -0.5, 1.0, 1.0) # left, bottom, width, height
# uv -> world for the active surface: world = uv_origin + u*uv_du + v*uv_dv.
#
# A wall is planar and its UVs are linear, so this is exact and costs nothing
# per frame; it is refitted whenever the destination changes.
var uv_origin := Vector3.ZERO
var uv_du := Vector3.ZERO
var uv_dv := Vector3.ZERO
var ime_anchor_last := Vector2i(-1, -1)

# --- effects: terminal behaviour state machine ------------------------------
# Names and defaults follow kitty/options/definition.py and the capture scenes
# in the reference capture scenes, so a preset reads across unchanged.
const Effects := preload("res://scenes/Effects.gd")
const TerminalCameraControllerScript := preload("res://scenes/TerminalCameraController.gd")
const CellShatterScript := preload("res://scenes/CellShatter.gd")
var fx_camera: TerminalCameraController = TerminalCameraControllerScript.new()
var navigation_camera: TerminalCameraController
var navigation_camera_active := false
var _adaptive_content_rect := Rect2()
## Rust FramingSettle state for the tracked terminal; see typing_camera.rs.
var _adaptive_settle := {}
var _adaptive_settle_owner := []
var fx_cfg = null # the loaded config; see scenes/Effects.gd
var fx_mat: ShaderMaterial = null
## Pages the sheet shader can composite beneath the canvas.
const VIDEO_LAYERS := 4
## The sheet material whose page slots set_video_layers() last filled.
var _video_layer_material: ShaderMaterial
var fx_time := 0.0
var fx_typing := 0.0 # eased 0 = idle, 1 = typing
var fx_last_key := -1e9
var fx_cursor := Vector2(0.06, 0.10)
var fx_col := 0
var fx_cursor_live := false
var fx_cell_px := Vector2(22.0, 44.0)
var fx_row := 0
var fx_splash_age := -1.0
var fx_splash_at := Vector2(0.5, 0.5)
var fx_attr: CameraAttributesPhysical = null
var fx_env: Environment = null

# behaviour (capture/scenes/camera_zoom.py)
var fx_zoom_typing := 2.0
var fx_enter_duration := 0.5
var fx_idle_after := 1.2
var fx_leave_duration := 1.5
# sheet
var fx_ripple_idle := 0.0
var fx_ripple_typing := 9.0
var fx_ripple_wavelength := 0.35
var fx_ripple_speed := 2.5
var fx_ripple_falloff := 0.3
var fx_tilt_limit_deg := 12.0
var fx_splash_scale := 14.0
var fx_splash_speed := 600.0
var fx_splash_life := 0.7
var fx_curvature_deg := 0.0
var fx_edge_margin := 0.0
var fx_corner_radius := 0.0
var fx_edge_shadow := 0.0
var fx_edge_shadow_width := 48.0
var fx_content_gloss := 0.0
# camera_drift / camera_shake (capture/scenes/camera_drift.py, camera_shake.py)
var fx_drift_px := 0.0
var fx_drift_speed := 2.5
var fx_shake_px := 0.0
var fx_shake_seconds := 0.18
# typing particles
var fx_particles := "none"
var fx_particles_amount := 6
var fx_particles_scale := 1.0
const SheetParticles := preload("res://scenes/Particles.gd")
var fx_parts: Node3D = null
const CoreTerminalEffects := preload("res://scenes/TerminalEffects.gd")
var terminal_effects: Node3D
const CursorTrail := preload("res://scenes/CursorTrail.gd")
var fx_trail: Node3D = null

var shot_dir := ""
var autoplay := false
var demo_shell := ""
var ink_gain := 1.0
var shade_override := -1.0
var self_mod := true
var pose_override: Array = []
# At the 1600×1000 reference layout this produces an approximately 80-column
# terminal. The actual raster size follows the viewport in
# _apply_terminal_font_scale().
var term_font_size := 16
var term_font_size_default := 16
var gesture_zoom := 1.0
# A pinch may take a camera state from a quarter to six times its size.
const PINCH_MIN_ZOOM := 0.25
const PINCH_MAX_ZOOM := 6.0
const TERMINAL_LAYOUT_REFERENCE_HEIGHT := 1000.0
# `--grid=` sets the requested grid fraction. An angled wall projects
# slightly smaller than the frustum, so the visible grid is smaller too.
# Raise the fraction to give the terminal more of the wall's margin.
var grid_fraction := TERMINAL_FRAME_FRACTION
var flight_pair: Array = []
var fx_enabled := true
var debug_render := false
var fx_overrides: Array = []
# Choose what appears behind the terminal sheet.
#
# - `3d` loads an authored 3D environment.
# - `wallpaper` shows a still image.
# - `color` uses a flat color.
# - `transparent` shows the desktop through the window.
#
# Camera zoom, tilt, drift, and shake work with any backdrop.
# Ripple, splash, and particle effects do too.
var world_mode := "color"
var wallpaper_path := ""
var bg_color := Color(0.05, 0.055, 0.07)
var bench_frames := 0
var tonemap_exposure := 1.0
var start_at := 0


## Override this method to use, modify, or completely replace user preferences.
func configure_terminal(user: TerminalConfig) -> TerminalConfig:
	return user.copy()


## Worlds may apply their own typed settings after the terminal overlays.
func configure_effects(_effects: RefCounted) -> void:
	pass


func _ready() -> void:
	var preferences: TerminalConfig = host.terminal_config.copy() if host != null else TerminalConfig.new()
	terminal_config = configure_terminal(preferences)
	var config_errors := terminal_config.validate()
	if not config_errors.is_empty():
		push_warning("Invalid world terminal config: " + "; ".join(config_errors))
		terminal_config = TerminalConfig.new()
	term_font_size = terminal_config.font_size
	fx_camera.name = "TerminalCameraController"
	add_child(fx_camera)
	for a in OS.get_cmdline_user_args():
		if _parse_world_arg(a):
			continue
		if a.begins_with("--shots="):
			shot_dir = a.substr(8)
		elif a == "--autoplay":
			autoplay = true
		elif a.begins_with("--shell="):
			demo_shell = a.substr(8)

		elif a.begins_with("--ink="):
			ink_gain = float(a.substr(6))
		elif a.begins_with("--shade="):
			shade_override = float(a.substr(8))
		elif a == "--no-selfmod":
			self_mod = false

		elif a.begins_with("--world="):
			world_mode = a.substr(8)
		elif a.begins_with("--wallpaper="):
			wallpaper_path = a.substr(12)
			world_mode = "wallpaper"
		elif a.begins_with("--opacity="):
			background_opacity = clampf(float(a.substr(10)), 0.0, 1.0)
		elif a.begins_with("--tabs="):
			flat_tab_count = clampi(int(a.substr(7)), 1, 32)
		elif a.begins_with("--bg="):
			bg_color = Color(a.substr(5))
		elif a.begins_with("--set="):
			# --set=state.typing:camera.zoom=2.0
			var body := a.substr(6)
			var at := body.find("=")
			var lhs := body.substr(0, at) if at > 0 else body
			var rhs := body.substr(at + 1) if at > 0 else ""
			var parts := lhs.split(":")
			if parts.size() == 2:
				fx_overrides.append([parts[0], parts[1], rhs])
		elif a.begins_with("--fx="):
			# --fx=zoom_typing:2,ripple_typing:9,...
			for kv in a.substr(5).split(","):
				var bits := kv.split(":")
				if bits.size() == 2:
					var key := "fx_" + bits[0]
					if key in self:
						var cur = get(key)
						if cur is String:
							set(key, bits[1])
						elif cur is bool:
							set(key, bits[1] == "1" or bits[1] == "true")
						elif cur is int:
							set(key, int(bits[1]))
						else:
							set(key, float(bits[1]))
		elif a == "--debug-render":
			debug_render = true
		elif a == "--no-fx":
			fx_enabled = false

		elif a == "--no-focus-skip":
			background_skip = false
		elif a == "--inkview":
			ink_enabled = true
		elif a.begins_with("--ink-part="):
			ink_part = a.substr(11)
		elif a.begins_with("--render-scale="):
			render_scale = clampf(float(a.substr(15)), 0.25, 1.0)
		elif a.begins_with("--motion-render-scale="):
			motion_render_scale = clampf(float(a.substr(22)), 0.25, 1.0)

		elif a == "--no-tabfx":
			tab_fx_disabled = true
			tab_fx = false

		elif a.begins_with("--film="):
			film_fps = maxi(int(a.substr(7)), 1)
			film_dt = 1.0 / float(film_fps)
		elif a.begins_with("--grid="):
			grid_fraction = clampf(float(a.substr(7)), 0.2, 1.0)
		elif a.begins_with("--font="):
			term_font_size = int(a.substr(7))

		elif a.begins_with("--bench="):
			bench_frames = int(a.substr(8))

		elif a.begins_with("--goto="):
			start_at = int(a.substr(7))

	term_font_size_default = term_font_size
	var light := _load_world()

	fx_cfg = Effects.new()
	# Camera and sheet are world-owned. Only terminal overlays come
	# from the effective TerminalConfig this world selected.
	fx_cfg.load_config(default_config)
	terminal_config.apply_effects(fx_cfg)
	configure_effects(fx_cfg)
	UserConfig.apply_effect_settings(fx_cfg, OS.get_cmdline_user_args())
	if backdrop_fill_viewport:
		fx_cfg.set_option("scene.sheet", "corner_radius", 0.0)
		fx_cfg.set_option("scene.sheet", "edge_blur", 0.0)
	for ov in fx_overrides:
		fx_cfg.set_option(ov[0], ov[1], str_to_var(ov[2]) if str_to_var(ov[2]) != null else ov[2])
	_fx_apply_scene()
	print("[effects] ", fx_cfg.describe())

	_load_background_config()
	_build_environment(light)
	_build_world()
	# The world's own places, in its order: a place a tab leaves is kept for
	# the next tab, while a copy made for a tab too many goes with it.
	for i in surfaces.size():
		surfaces[i].set_meta("place", i)
	if host != null and (host.restoring_window or host.session_count() > 0):
		# A detached window receives exactly its transferred workspaces, not a
		# second set of the plugin's default tabs or a throwaway shell.
		#
		# A world changed under open tabs gives those tabs places and adds none: its
		# places past the last tab stay empty.
		if (
			host.restoring_window
			and (host.initial_surface != null or not host.initial_surfaces.is_empty())
		):
			for surface in surfaces:
				surface.free()
			surfaces.clear()
			walls.clear()
			focus_points.clear()
			var transferred: Array = host.initial_surfaces.duplicate()
			if host.initial_surface != null:
				transferred.append(host.initial_surface)
			host.initial_surface = null
			host.initial_surfaces.clear()
			for restored: TerminalSurface3D in transferred:
				# A place of the world it came from, not of this one.
				restored.remove_meta("place")
				add_child(restored)
				surfaces.append(restored)
			_build_walls()
		else:
			while surfaces.size() > host.session_count():
				spare_places.push_front(surfaces.pop_back())
	if host != null:
		while surfaces.size() < host.session_count():
			_append_terminal_surface(_new_terminal_surface_source())
	if host != null:
		var definitions: Array[Dictionary] = []
		var existing: Array = host.get_terminal_tabs()
		for i in surfaces.size():
			surfaces[i].session_id = existing[i].id if i < existing.size() else host.allocate_session_id()
			definitions.append(
				{
					"id": surfaces[i].session_id,
					"label": _surface_label(str(surfaces[i].id)),
				}
			)
		host.set_tabs(definitions)
		# Tabs stand at the places in tab order, whatever order they came in,
		# and a tab's other windows give theirs back.
		var ordered := _tab_order_ids()
		for i in surfaces.size():
			surfaces[i].session_id = ordered[i]
		_seat_tabs()
		host.session_requested.connect(_on_session_requested)
		# A detached browser-only presentation still needs a canvas surface,
		# but must not create a terminal mirror or a replacement shell.
		if surfaces.is_empty() and not host.chromiums.is_empty() and _floating():
			var carrier := _append_terminal_surface(0)
			surfaces[carrier].session_id = int(host.chromiums.keys()[0])
	_build_terminal()
	_apply_terminal_config()
	_build_ui()
	terminal_effects = CoreTerminalEffects.new()
	terminal_effects.effect_control = effect_control
	terminal_effects.automatic = false
	terminal_effects.enabled = fx_enabled
	terminal_effects.camera_zoom = fx_cam_zoom
	add_child(terminal_effects)
	terminal_effects.configure(fx_cfg)
	terminal_effects.typed.connect(_on_effect_typed)
	terminal_effects.input_activity.connect(func(): workspace_typed.emit())
	fx_parts = terminal_effects.particles
	fx_trail = terminal_effects.trail

	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.far = 4000.0
	cam.near = 0.05
	# Give the render camera the physical attributes directly. A world attribute
	# is only a default; attaching it here makes the exposure unambiguous for
	# this camera. It does not alter our explicit frustum matrix.
	cam.attributes = fx_attr
	if fixed_tab_camera and background_opacity < 1.0:
		# Godot does not support physical DoF in transparent viewports.
		cam.attributes = CameraAttributesPractical.new()
	add_child(cam)
	# Explicit, not incidental. Every surface carries a ViewPose Camera3D and
	# they enter the tree first, so relying on "the first camera wins" would
	# render the whole world from LiveTerminalWall0's pose and never move.
	cam.current = true

	_build_scenery_view()
	_goto(clampi(start_at, 0, surfaces.size() - 1), true)
	_build_ink_view()
	_update_ink_view()
	if host != null: host._sync_world_chrome_clip.call_deferred()
	if background_skip:
		_set_world_awake(get_window().has_focus())
	_apply_render_scale()
	get_viewport().size_changed.connect(_apply_render_scale)
	get_viewport().size_changed.connect(_sync_ink_viewport_size)
	get_viewport().size_changed.connect(_sync_terminal_viewport_size)
	get_window().size_changed.connect(_on_window_size_changed)
	if flight_pair.size() == 2:
		_flight_shots.call_deferred()
		return
	if pose_override.size() == 4:
		_apply_pose(
			pose_override[0],
			pose_override[1],
			pose_override[2],
			pose_override[3] if pose_override[3] > 0.0 else tan(deg_to_rad(cam.fov) * 0.5),
		)
	if bench_frames > 0:
		_bench.call_deferred()
		return
	if shot_dir != "":
		_tour.call_deferred()


func _read_json(path: String) -> Dictionary:
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		push_error("cannot read %s" % path)
		return { }
	return JSON.parse_string(txt)

# --- lighting, matched to background.inc ------------------------------------


func _relax_renderer_for_flat_world() -> void:
	# A flat sheet has no surrounding scenery to contribute ambient occlusion.
	if fx_env != null:
		fx_env.ssao_enabled = false


func _build_flat_world() -> void:
	## Build a single sheet facing the camera. It supports zoom, tilt,
	## curvature, ripple, splash, and particles without a 3D backdrop.
	##
	## The viewport controls MSAA. This world disables SSAO for the flat sheet.
	##
	## Use the same TerminalSurface3D that authored worlds place. This
	## exercises the public authoring interface. See `design-plugins.md`.
	if host != null:
		flat_tab_count = maxi(flat_tab_count, host.session_count())
	_relax_renderer_for_flat_world()
	var canvas := Vector2(16.0, 10.0)
	# The eye sits two larger sides from the paper: a narrow lens, in which a
	# lean is a gentle change of perspective rather than a wide-angle swing.
	var distance := 2.0 * maxf(canvas.x, canvas.y)
	surfaces = []
	for i in flat_tab_count:
		surfaces.append(
			_make_surface(
				"Terminal %d" % (i + 1),
				i,
				canvas,
				Transform3D.IDENTITY,
				Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, distance)),
				rad_to_deg(2.0 * atan(0.5 * canvas.x / distance)),
			)
		)
	accents = []
	flat_sheets = true
	_fit_flat_sheets()

	if background_opacity > 0.0 and (world_mode == "wallpaper" or backdrop_fill_viewport):
		_build_backdrop()


## Floating windows fill the frame, so the flat world's paper takes the
## frame's shape: the workspace canvas then covers exactly the window, with
## nothing rendered off-screen at rest.
##
## The eye stays two larger sides away.
func _fit_flat_sheets() -> void:
	if not flat_sheets or not _floating():
		return
	var canvas := Vector2(10.0 * _frame_aspect(), 10.0)
	var distance := 2.0 * maxf(canvas.x, canvas.y)
	var changed := false
	for s in surfaces:
		if s.canvas.is_equal_approx(canvas):
			continue
		changed = true
		s.canvas = canvas
		var view: Camera3D = s.view_pose
		if view != null:
			view.position = Vector3(0.0, 0.0, distance)
			# Resizing containers can briefly produce a one-pixel-wide viewport.
			# Keep the authored lens inside Camera3D's legal range even then.
			view.fov = clampf(rad_to_deg(2.0 * atan(0.5 * canvas.x / distance)), 1.0, 179.0)
		if walls.has(s.id):
			focus_points[s.id] = s.focus_point()
	if not changed or active < 0 or active >= surfaces.size():
		return
	_fit_uv_basis()
	if not camera_motion.moving:
		var s: TerminalSurface3D = surfaces[active]
		_apply_pose(s.eye, s.forward, s.up, s.half_x)


func _build_backdrop() -> void:
	## Screen-space fill is composed below scenery and ink, outside exposure.
	## It covers the frame independently of camera tilt, pan, zoom and resizing.
	var tex: Texture2D = null
	if world_mode == "wallpaper" and wallpaper_path != "":
		tex = load(wallpaper_path) if ResourceLoader.exists(wallpaper_path) else null
		if tex == null:
			var img := Image.new()
			if img.load(wallpaper_path) == OK:
				tex = ImageTexture.create_from_image(img)
		if tex == null:
			push_warning("wallpaper not loadable: %s" % wallpaper_path)

	backdrop_texture = tex
	backdrop_color = Color.WHITE if tex != null else bg_color
	backdrop_color.a = background_opacity


func _configure_backdrop(material: ShaderMaterial) -> void:
	material.set_shader_parameter("world_background", backdrop_color)
	material.set_shader_parameter("wallpaper_enabled", backdrop_texture != null)
	if backdrop_texture != null:
		material.set_shader_parameter("wallpaper_texture", backdrop_texture)


## Fallback tab label until the shell reports a title; authored names stay literal.
func _surface_label(id: String) -> String:
	return tr("Wall %s") % id.trim_prefix("LiveTerminalWall") if id.begins_with("LiveTerminalWall") else id


func _make_surface(
	id: String,
	order: int,
	canvas: Vector2,
	placement: Transform3D,
	pose: Transform3D,
	fov_degrees: float,
) -> TerminalSurface3D:
	## Build the node an authored world would have placed in the editor.
	##
	## A world that ships a .tscn never calls this; it exists so the flat world
	## and `create_terminal_tab()` produce the same thing the editor does.
	var surface := TerminalSurface3D.new()
	surface.name = id
	surface.surface_id = id
	surface.visit_order = order
	surface.canvas = canvas
	surface.transform = placement
	add_child(surface)
	var view := Camera3D.new()
	view.name = "ViewPose"
	view.keep_aspect = Camera3D.KEEP_WIDTH
	view.fov = fov_degrees
	view.near = 0.05
	view.far = 4000.0
	view.transform = pose
	view.current = false
	surface.add_child(view)
	return surface


func _adopt_surfaces(container: Node) -> void:
	## Read the screens already placed in an authored scene.
	## `container` is the node that groups them and may be the world itself.
	surfaces = []
	for child in container.get_children():
		if child is TerminalSurface3D:
			surfaces.append(child)
	surfaces.sort_custom(
		func(a, b):
			if a.visit_order != b.visit_order:
				return a.visit_order < b.visit_order
			return a.get_index() < b.get_index(),
	)


func _build_walls() -> void:
	## Whatever put the surfaces there — the editor or `_make_surface()` — this
	## is where the kit starts keying off them. They stay hidden until visited.
	for s in surfaces:
		s.visible = false
		walls[s.id] = s
		focus_points[s.id] = s.focus_point()

# --- terminal ---------------------------------------------------------------


func _build_terminal() -> void:
	if surfaces.is_empty():
		return
	## The first tab's terminal. The rest are made when their wall is first
	## visited, by _terminal_for().
	if host != null and host.selected_session >= 0:
		# A changed world opens at the tab that was showing.
		var tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
		var place := _surface_for_session(_first_terminal(tab))
		start_at = place if place >= 0 else host.selected_session
	var first_index := clampi(start_at, 0, surfaces.size() - 1)
	if host != null and host.is_chromium_pane("%%%d" % surfaces[first_index].session_id):return
	var pair: Dictionary = host.session_for(surfaces[first_index].session_id, self) if host != null else _make_terminal()
	term_vp = pair["vp"]
	term = pair["term"]
	# CJK composition is not an input event and never reaches the terminal, so it
	# is drawn here, over the grid, from what DisplayServer reports.
	fx_cell_px = _terminal_cell_px()
	term.call_deferred("grab_focus")


func _terminal_for(id: String) -> Dictionary:
	## Create a terminal on its tab's first visit. Each tab gets its own shell,
	## scrollback, and screen.
	##
	## Lazy creation avoids starting a shell for every wall in an authored world.
	if terminals.has(id):
		return terminals[id]
	var index := 0
	for i in surfaces.size():
		if str(surfaces[i].id) == id:
			index = i
			break
	if host != null and host.is_chromium_pane("%%%d" % surfaces[index].session_id):return {}
	var pair: Dictionary = host.session_for(surfaces[index].session_id, self) if host != null else _make_terminal()
	terminals[id] = pair
	return pair


func _make_terminal() -> Dictionary:
	var vp := SubViewport.new()
	# This is replaced by _sync_terminal_viewport_size() once the active wall is
	# known.  A fixed 1280x800 source was being enlarged over a 1600x1000 wall,
	# so linear sampling softened every terminal glyph.
	vp.size = Vector2i(2, 2) if host != null else Vector2i(1600, 1000)
	if host != null: vp.set_meta("terminal_saved_size", Vector2i(1600, 1000))
	# The ink must composite over the masonry, so the viewport clears to
	# transparent. graffitty already leaves default-background cells unpainted
	# (bg_color() is None), so only explicitly coloured cells stay opaque.
	vp.transparent_bg = true
	# Premultiply glyph coverage in linear light before the 3D/DoF passes.
	# LDR sRGB premultiplication produces dark fringes after texture decoding.
	vp.use_hdr_2d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.handle_input_locally = true
	vp.gui_embed_subwindows = false
	if host != null:
		host.terminal_viewport_parent().add_child(vp)
	else:
		add_child(vp)

	if not ClassDB.class_exists("Terminal"):
		push_error("graffitty Terminal class not registered")
		return { }
	var t: Node = ClassDB.instantiate("Terminal")
	terminal_config.apply_spawn(t)
	if host != null:
		host.session_backend.configure_terminal(t)
	if host != null and host.has_method("terminal_environment"):
		var environment := { }
		environment.merge(host.terminal_environment(), true)
		t.set("environment", environment)
	if host != null:
		t.set("working_directory", host.terminal_start_directory(""))
	var initial_font: int = host.application.new_pane_font_size(term_font_size) if host != null else term_font_size
	t.set("font_size", initial_font)
	t.set_meta("pane_font_size", initial_font)
	t.set("color_scheme", 1)
	if demo_shell != "":
		t.set("shell", demo_shell)
		t.set("login_shell", false)
	# Make the default background transparent so the world shows through.
	# A preset can raise `[terminal] background_opacity`.
	#
	# Cells with an explicit background color stay opaque.
	t.set("background_opacity", 0.0)
	# --apc=MB, for probing where the kitty graphics payload limit really is.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--storage="):
			t.set("kitty_image_storage_mb", int(arg.substr(10)))
			print("[apc] kitty_image_storage_mb = %s" % arg.substr(10))
		if arg.begins_with("--apc="):
			t.set("kitty_apc_max_mb", int(arg.substr(6)))
			print("[apc] kitty_apc_max_mb = %s" % arg.substr(6))
	# SubViewport is not a Control parent, so anchors alone do not give this root
	# Control a rectangle.
	#
	# Place it in the texture's content rect; otherwise the shell begins
	# above/outside the page when the viewport changes size.
	var initial_rect := _terminal_content_rect(Vector2i(1600, 1000))
	t.position = initial_rect.position
	t.size = initial_rect.size
	ViewportUpdates.configure(vp, t)
	if host != null:
		# Topology can create mirrors for tabs that have never been selected.
		ViewportUpdates.set_visible(vp, false)
	vp.add_child(t)
	var integration := preload("res://scenes/TerminalIntegrationUI.gd").new()
	integration.application = host.application if host != null else null
	integration.host = host
	t.add_child(integration)
	return { "vp": vp, "term": t }


func _apply_terminal_config() -> void:
	## Apply only the effective settings chosen by this world.
	if term == null:
		return
	terminal_config.apply_live(term)
	if not term.shortcut_action.is_connected(_on_terminal_shortcut):
		term.shortcut_action.connect(_on_terminal_shortcut)
	var cfg := _merged_terminal_config()
	term.set("clipboard_write", bool(cfg.get_value("terminal", "clipboard_write", true)))
	var read_policy := str(cfg.get_value("terminal", "clipboard_read", "ask")).to_lower()
	term.set("clipboard_read", { "deny": 0, "ask": 1, "allow": 2 }.get(read_policy, 1))
	var found := cfg.has_section("terminal")
	preload("res://scenes/TerminalSelection.gd").apply(term, cfg)
	if term.has_method("set_live_background_opacity"):
		term.call("set_live_background_opacity", 0.0)
	if not found or not cfg.has_section("terminal"):
		return

	var paths := PackedStringArray(cfg.get_value("terminal", "font_paths", []))
	var family := str(cfg.get_value("terminal", "font_family", ""))
	var fallbacks := PackedStringArray(cfg.get_value("terminal", "font_fallbacks", []))
	if (
		term.get("font_paths") != paths or str(term.get("font_family")) != family
		or term.get("font_fallbacks") != fallbacks
	):
		term.call("set_live_font_config", paths, family, fallbacks)

	var size := int(cfg.get_value("terminal", "font_size", term_font_size))
	if size != term_font_size:
		term_font_size = clampi(size, 1, 72)
		term_font_size_default = term_font_size
		_apply_terminal_font_scale(_terminal_font_scale())

	if term.has_method("set_live_cell_metrics"):
		var pad := float(
			cfg.get_value("terminal", "padding", cfg.get_value("terminal", "cell_padding", -1.0))
		)
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--padding="):
				pad = maxf(float(arg.substr(10)), 0.0)
		var line := float(cfg.get_value("terminal", "line_height", -1.0))
		var column := float(cfg.get_value("terminal", "column_width", -1.0))
		if pad >= 0.0 or line > 0.0 or column > 0.0:
			var metrics := Vector3(
				(
					minf(pad, minf(term.size.x, term.size.y) * 0.2)
					if pad >= 0.0
					else float(term.get("cell_padding"))
				),
				line if line > 0.0 else float(term.get("line_height")),
				column if column > 0.0 else float(term.get("column_width")),
			)
			var current := Vector3(
				float(term.get("cell_padding")),
				float(term.get("line_height")),
				float(term.get("column_width")),
			)
			if not metrics.is_equal_approx(current):
				term.call("set_live_cell_metrics", metrics.x, metrics.y, metrics.z)

	var shape := String(cfg.get_value("terminal", "cursor_shape", ""))
	if shape != "" and term.has_method("set_live_cursor_shape"):
		# 'beam' is ghostty's name for what libghostty calls a bar.
		var shapes := { "auto": 0, "block": 1, "bar": 2, "beam": 2, "underline": 3, "hollow": 4 }
		term.call("set_live_cursor_shape", int(shapes.get(shape.to_lower(), 0)))

	if (
		term.has_method("set_live_background_opacity") \
				and cfg.has_section_key("terminal", "background_opacity")
		and not fixed_tab_camera
	):
		background_opacity = clampf(
			float(cfg.get_value("terminal", "background_opacity", 0.0)),
			0.0,
			1.0,
		)

	var bg_value := String(cfg.get_value("terminal", "bg", ""))
	if bg_value != "" and term.has_method("set_colors"):
		var fg_value := String(cfg.get_value("terminal", "fg", "#d8dade"))
		var cursor_value := String(cfg.get_value("terminal", "cursor", fg_value))
		var ansi := PackedColorArray()
		for c in cfg.get_value("terminal", "ansi", []):
			ansi.append(Color(String(c)))
		term.call("set_colors", Color(bg_value), Color(fg_value), Color(cursor_value), ansi)

	# color0..color255, kitty's spelling, applied over whatever the bulk set.
	if term.has_method("set_palette_color"):
		for key in cfg.get_section_keys("terminal"):
			if not key.begins_with("color"):
				continue
			var index := key.substr(5)
			if not index.is_valid_int():
				continue
			term.call(
				"set_palette_color",
				int(index),
				Color(String(cfg.get_value("terminal", key, "#000000"))),
			)


func _terminal_material() -> ShaderMaterial:
	var mat := CoreTerminalEffects.create_sheet_material(_sheet_viewport())
	# Crop, camera and lens uniforms are otherwise written only when they next
	# change. Continue from the previous sheet when switching materials. Its
	# texture, size and video pages belong to the departing session.
	if fx_mat != null and fx_mat.shader == mat.shader:
		for uniform in mat.shader.get_shader_uniform_list():
			var key: String = uniform.name
			if key in ["terminal_tex", "tex_size"] or key.begins_with("page_"): continue
			mat.set_shader_parameter(key, fx_mat.get_shader_parameter(key))
	RenderUpdates.uniform(mat, "ink_gain", ink_gain)
	RenderUpdates.uniform(mat, "wall_shade", wall_shade)
	RenderUpdates.uniform(mat, "exposure_compensation", tonemap_exposure)
	var cfg := _merged_terminal_config()
	RenderUpdates.uniform(mat, "panel_color", Color(str(cfg.get_value("terminal", "bg", "#1c2530"))))
	RenderUpdates.uniform(mat,
		"panel_opacity",
		0.0 if backdrop_fill_viewport or _floating() else background_opacity,
	)
	var window := _sheet_window()
	RenderUpdates.uniform(mat,
		"sheet_window",
		Vector4(window.position.x, window.position.y, window.size.x, window.size.y),
	)
	if terminal_effects != null:
		terminal_effects.particles.text_color = Color(
			str(cfg.get_value("terminal", "fg", "#d8dade"))
		)
	# Alpha-blended scenery must draw before the depth-writing terminal too.
	mat.render_priority = CoreTerminalEffects.SHEET_RENDER_PRIORITY
	fx_mat = mat
	return mat


func _canvas_aspect() -> float:
	## The active wall's authored canvas. The texture and the camera frame the
	## same rectangle, so both read it from here.
	if active >= 0 and active < surfaces.size():
		var canvas: Vector2 = surfaces[active].canvas
		if canvas.y > 0.0:
			return canvas.x / canvas.y
	return 1.6


func _frame_aspect() -> float:
	var vp := _window_render_size()
	return maxf(vp.x, 1.0) / maxf(vp.y, 1.0)


func _canvas_span_in_frame() -> Vector2:
	## Return the canvas span under the cover framing in `_apply_camera_fx()`.
	## One axis spans exactly 1 frame. The other spans at least 1 and can overflow.
	##
	## This is the same fit as `background-size: cover`.
	var ratio := _frame_aspect() / _canvas_aspect()
	return Vector2(maxf(1.0 / ratio, 1.0), maxf(ratio, 1.0)) / CANVAS_COVER_MARGIN


func _configure_scenery_antialiasing(viewport: SubViewport, compositor: Viewport) -> void:
	viewport.msaa_3d = compositor.msaa_3d
	viewport.screen_space_aa = compositor.screen_space_aa


func _configure_ink_antialiasing(viewport: SubViewport) -> void:
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED


func _build_scenery_view() -> void:
	# Keep the containing viewport as the compositor/input surface. Its 2D
	# chrome and ink overlay keep drawing even when this 3D target is asleep.
	var compositor := get_viewport()
	_compositor_had_3d_disabled = compositor.disable_3d
	compositor.disable_3d = true
	scenery_vp = SubViewport.new()
	scenery_vp.name = "SceneryView"
	# Flat background is added after rendering, even for an opaque window.
	scenery_vp.transparent_bg = compositor.transparent_bg or backdrop_color.a > 0.0
	scenery_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_configure_scenery_antialiasing(scenery_vp, compositor)
	add_child(scenery_vp)
	cam.reparent(scenery_vp)
	cam.current = true
	var layer := CanvasLayer.new()
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.BACKGROUND
	add_child(layer)
	var background := TextureRect.new()
	background.texture = scenery_vp.get_texture()
	scenery_material = ShaderMaterial.new()
	scenery_material.shader = preload("res://scenes/scenery_composite.gdshader")
	_configure_backdrop(scenery_material)
	background.material = scenery_material
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(background)
	_sync_scenery_size()
	compositor.size_changed.connect(_sync_scenery_size)
	get_tree().node_added.connect(_scenery_node_added)
	# Lights have their own visual layers, separate from light_cull_mask.
	# Excluding the lights themselves prevents the ink camera from scheduling
	# scenery shadow cascades, even though the cameras share a World3D.
	for light in find_children("*", "Light3D", true, false):
		light.layers &= ~(INK_MASK | preload("res://scenes/TransitionInk.gd").MASK)


func _exit_tree() -> void:
	_cancel_transition_preparation()
	if scenery_vp != null:
		get_viewport().disable_3d = _compositor_had_3d_disabled


func _sync_scenery_size() -> void:
	if scenery_vp == null:
		return
	scenery_vp.size = Vector2i(get_viewport().get_texture().get_size())
	_scenery_dirty = true
	# The frame can change without the OS window doing so (a menu bar appearing).
	if _floating() and active >= 0:
		_fit_flat_sheets()
		_sync_terminal_viewport_size()
	_refresh_navigation_destination()
	_apply_camera_fx()


func _scenery_node_added(node: Node) -> void:
	if node is AnimationMixer or node is GPUParticles3D or node is CPUParticles3D:
		_scenery_animation_scan = true
	if is_ancestor_of(node): _scenery_dirty = true


func _scenery_has_animation() -> bool:
	if scenery_continuous: return true
	if _scenery_animation_scan:
		_scenery_animation_nodes.clear()
		for type in ["AnimationMixer", "GPUParticles3D", "CPUParticles3D"]:
			_scenery_animation_nodes.append_array(find_children("*", type, true, false))
		_scenery_animation_scan = false
	for node in _scenery_animation_nodes:
		if not is_instance_valid(node): continue
		if node is AnimationPlayer and node.active and node.is_playing(): return true
		if node is AnimationTree and node.active: return true
		# Ink-layer particles render independently and need not wake scenery.
		if (node is GPUParticles3D or node is CPUParticles3D) and node.visible and node.layers & cam.cull_mask:
			if node.emitting:
				_scenery_particles_until = Time.get_ticks_msec() + int(node.lifetime / maxf(node.speed_scale, 0.001) * 1000.0)
				return true
	return Time.get_ticks_msec() < _scenery_particles_until


func _update_scenery_view() -> void:
	if scenery_vp == null:
		return
	# Finish an in-progress flight with real depth testing before sleeping.
	# The final background-only frame removes any baked-in terminal glyphs.
	var camera_snapshot: Array = [cam.global_transform, cam.projection, cam.fov, cam.size, cam.frustum_offset, cam.near, cam.far, cam.cull_mask]
	var camera_changed := camera_snapshot != _scenery_camera_snapshot
	# A pass change alone (cull_mask) is not motion.
	var camera_moved := fly_dur > 0.0 or camera_snapshot.slice(0, 7) != _scenery_camera_snapshot.slice(0, 7)
	_scenery_camera_snapshot = camera_snapshot
	if _update_scenery_scale(camera_moved):
		_scenery_dirty = true
	var interactive := world_awake or Time.get_ticks_msec() < pointer_active_until
	var live := camera_changed or fly_dur > 0.0 or not ink_active or (interactive and _scenery_has_animation())
	if live:
		scenery_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif _scenery_live or _scenery_dirty:
		scenery_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif scenery_vp.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		# UPDATE_ONCE resets the RenderingServer, but not SubViewport's cached
		# property. Keep the node's visible state in sync on the following frame.
		scenery_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_scenery_live = live
	_scenery_dirty = false


func _update_scenery_scale(camera_moved: bool) -> bool:
	## Dynamic resolution: fewer scenery pixels during sustained camera motion,
	## full resolution for the frame left on screen. Returns whether the scale changed.
	var now := Time.get_ticks_msec()
	_scenery_motion_frames = _scenery_motion_frames + 1 if camera_moved else 0
	var moving := now - _scenery_moved_msec < SCENERY_MOTION_HOLD_MSEC
	if camera_moved and (moving or _scenery_motion_frames >= SCENERY_MOTION_FRAMES):
		_scenery_moved_msec = now
		moving = true
	var scale := _scenery_scales.y if moving else _scenery_scales.x
	if is_equal_approx(scenery_vp.scaling_3d_scale, scale):
		return false
	scenery_vp.scaling_3d_scale = scale
	return true


var ink_dof: CompositorEffect
var transition_ink: Node


func _build_ink_view() -> void:
	if not ink_enabled:
		return
	## A second look at the same world that draws only the terminal's wall, at
	## the window's own resolution, through nothing.
	##
	## The 3D pass can then be rendered at whatever scale the frame budget wants
	## without the glyphs paying for it.
	ink_vp = SubViewport.new()
	ink_vp.transparent_bg = true
	ink_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.frame_pre_draw.connect(_prepare_ink_frame)
	_configure_ink_antialiasing(ink_vp)
	ink_vp.use_debanding = false
	# Shared geometry, selected by camera layers; scenery lights are excluded.
	add_child(ink_vp)
	if ink_part == "vponly":
		return

	ink_cam = Camera3D.new()
	ink_cam.name = "InkCamera"
	# Mobile color attachments are not storage images. Its terminal fragment
	# blur path remains active; the compute compositor needs Forward+ buffers.
	if RenderingServer.get_current_rendering_method() == "forward_plus":
		ink_dof = preload("res://scenes/InkDepthOfField.gd").new()
		ink_cam.compositor = Compositor.new()
		ink_cam.compositor.compositor_effects = [ink_dof]
	ink_cam.attributes = cam.attributes.duplicate()
	ink_cam.attributes.set_meta("presentation_dof", [false, 1.0, 1.0, false, 1.0, 1.0, 0.0])
	RenderingServer.camera_attributes_set_dof_blur(
		ink_cam.attributes.get_rid(),
		false,
		1.0,
		1.0,
		false,
		1.0,
		1.0,
		0.0,
	)
	# No environment: no sky, no tone mapping, no ambient occlusion. The ink
	# shader already outputs the colour the terminal asked for.
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = tonemap_exposure
	if ink_part != "noenv":
		ink_cam.environment = env
	# Only the terminal's wall. Everything else in the world is invisible here,
	# which is what makes this pass cheap as well as clean.
	ink_cam.cull_mask = INK_MASK
	ink_vp.add_child(ink_cam)
	if ink_part != "nocurrent":
		ink_cam.current = true
	if ink_part == "nocurrent" or ink_part == "noenv" or ink_part == "cam":
		return

	if ink_part == "vp":
		return
	# Composited over the 3D, which is why it is a CanvasLayer above everything.
	var layer := CanvasLayer.new()
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.BROWSER
	add_child(layer)
	ink_overlay = TextureRect.new()
	ink_overlay.texture = ink_vp.get_texture()
	var composite := ShaderMaterial.new()
	composite.shader = preload("res://scenes/terminal_ink_composite.gdshader")
	_configure_backdrop(composite)
	RenderUpdates.uniform(composite, "scenery_texture", scenery_vp.get_texture())
	RenderUpdates.uniform(composite, "backdrop_blur_radius", terminal_window.blur_radius)
	ink_overlay.material = composite
	ink_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	ink_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	ink_overlay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ink_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ink_overlay.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	ink_overlay.visible = false
	layer.add_child(ink_overlay)
	if ink_dof != null:
		transition_ink = preload("res://scenes/TransitionInk.gd").new()
		add_child(transition_ink)
	_sync_ink_viewport_size()


func _ink_should_be_active() -> bool:
	# A tab's captured pieces and live terminal must use the same composition.
	#
	# Moving them into the scenery depth buffer hides parts of the fade behind
	# buildings, then reveals those parts in one frame at the live handoff.
	#
	# Keep the native ink pass throughout tab effects, including interruptions.
	return (
		ink_vp != null and (fly_dur <= 0.0 or flat_sheets or tab_fx_t >= 0.0 or not tab_fx_stale.is_empty())
		and active >= 0 and walls.has(surfaces[active].id)
	)


func _update_ink_view() -> void:
	if ink_vp == null:
		return
	if debug_render and Engine.get_process_frames() % 120 == 30:
		var sheet := get_node_or_null("Sheet")
		print(
			"[ink] active=%s want=%s cull=%d ink_vp=%s overlay=%s sheet_layers=%s term_vp=%s"
			% [
				str(ink_active),
				str(_ink_should_be_active()),
				cam.cull_mask,
				str(ink_vp.size),
				str(ink_overlay.visible) if ink_overlay != null else "nil",
				str((sheet as VisualInstance3D).layers) if sheet != null else "nil",
				str(term_vp.size) if term_vp != null else "nil",
			]
		)
	var want := _ink_should_be_active()
	_set_ink_active(want)
	if not ink_active:
		return
	_sync_ink_viewport_size()
	# The same eye, the same frustum. Anything less and the terminal would sit a
	# pixel off the wall it is supposed to be painted on.
	if ink_cam.near != cam.near: ink_cam.near = cam.near
	if ink_cam.far != cam.far: ink_cam.far = cam.far
	CameraMotionScript.apply(ink_cam, { "transform": cam.global_transform, "rect": proj_rect })
	if debug_render and Engine.get_process_frames() % 120 == 30:
		# Where the wall's own corners land in each view. Matrices printed the
		# same and the renders did not, so ask the cameras about a point instead.
		var corners := [uv_origin, uv_origin + uv_du, uv_origin + uv_dv, uv_origin + uv_du + uv_dv]
		for c in corners:
			print(
				"[ink] corner main %s   ink %s"
				% [
					str(cam.unproject_position(c).round()),
					str(ink_cam.unproject_position(c).round()),
				]
			)
		print(
			"[ink] overlay rect %s  texture %s  vp %s  main target %s"
			% [
				str(ink_overlay.size) if ink_overlay != null else "nil",
				(
					str(ink_overlay.texture.get_size())
					if ink_overlay != null \
							and ink_overlay.texture != null
					else "nil"
				),
				str(ink_vp.size),
				str(get_viewport().get_texture().get_size()),
			]
		)
		if shot_dir != "":
			ink_vp.get_texture().get_image().save_png("%s/ink_raw.png" % shot_dir)


func _prepare_ink_frame() -> void:
	if ink_active and not session_transition_capture.is_empty():
		# Binding can repaint the live canvas at the destination's density.
		# Keep the last rendered ink (including any interrupted passes) until
		# the retained departure takes its place. No GPU readback is needed.
		ink_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	# SceneTree tweens (pane reveals, fit and Main View) run after _process. Copy
	# their final camera before rendering, not one frame earlier: the canvas crop
	# and scenery already use that new pose.
	#
	# Mixing poses makes moving ink lag/blur against the rest of the composition.
	_update_ink_view()
	_update_scenery_view()
	if ink_active and ink_vp != null:
		# This hook runs after the scene's usual transform-notification flush.
		ink_cam.force_update_transform()
		ink_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if transition_ink != null: transition_ink.synchronize(self)


## Keep scenery/alpha behind the tabs while excluding projected workspace ink.
## Spatial clipping also covers flights rendered in the scenery depth buffer.
func set_workspace_clip_top(top: float) -> void:
	_workspace_clip_top = top
	if ink_overlay != null:
		RenderUpdates.uniform(ink_overlay.material, "workspace_clip_top", top)
	for wall: GeometryInstance3D in walls.values():
		wall.set_instance_shader_parameter("workspace_clip_top", top)
	for layer: GeometryInstance3D in tab_fx_out + tab_fx_in:
		layer.set_instance_shader_parameter("workspace_clip_top", top)
	for entry in tab_fx_stale:
		entry.layer.set_instance_shader_parameter("workspace_clip_top", top)
	if fx_parts != null:
		fx_parts.emitter.set_instance_shader_parameter("workspace_clip_top", top)
		fx_parts.mesh.set_instance_shader_parameter("workspace_clip_top", top)
	if fx_trail != null:
		fx_trail._node.set_instance_shader_parameter("workspace_clip_top", top)
	_scenery_dirty = true


func _set_ink_active(on: bool) -> void:
	if active < 0 or not walls.has(surfaces[active].id):
		on = false
	var mask := INK_MASK if on else 1
	for wall in walls.values():
		if wall.layers != mask: wall.layers = mask
	for layer in tab_fx_out + tab_fx_in:
		if layer.layers != mask: layer.layers = mask
	for entry in tab_fx_stale:
		if entry.layer.layers != mask: entry.layer.layers = mask
	if fx_parts != null:
		if fx_parts.emitter.layers != mask: fx_parts.emitter.layers = mask
		if fx_parts.mesh.layers != mask: fx_parts.mesh.layers = mask
	if fx_trail != null:
		if fx_trail._node.layers != mask: fx_trail._node.layers = mask
	var camera_mask := (0xFFFFF & ~(INK_MASK | preload("res://scenes/TransitionInk.gd").MASK)) if on else 0xFFFFF
	if cam.cull_mask != camera_mask: cam.cull_mask = camera_mask
	if ink_overlay != null:
		ink_overlay.visible = on
	if ink_vp != null and ink_active != on:
		ink_vp.render_target_update_mode = SubViewport.UPDATE_ONCE if on else SubViewport.UPDATE_DISABLED
	if ink_active != on:
		_scenery_dirty = true
	ink_active = on


func _sync_ink_viewport_size() -> void:
	if ink_vp == null:
		return
	# Native: the whole point is that this one is not scaled.
	var size := Vector2i(get_viewport().get_texture().get_size())
	if size.x > 0 and size.y > 0 and ink_vp.size != size:
		ink_vp.size = size


func pointer_activity() -> void:
	# Hover/scroll can interact with a background window without focusing it.
	pointer_active_until = Time.get_ticks_msec() + 750
	if host != null and host.application != null: host.application.wake_pointer_frames()


func _set_world_awake(awake: bool) -> void:
	# Rendering is controlled after navigation and pass selection in _process.
	# Never pause the tree: PTYs, terminal textures and chrome remain live.
	if world_awake == awake:
		return
	world_awake = awake
	# 30 is not a pause: output still appears within a frame of arriving, which
	# is what the constraint on this was.
	if host != null and host.application != null:
		host.application.update_frame_limit.call_deferred()
	else:
		Engine.max_fps = 120 if awake else 30
	if debug_render:
		print("[focus] world %s" % ("awake" if awake else "asleep"))


func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("TerminalWorld._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if not background_skip:
		return
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			_set_world_awake(false)
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_set_world_awake(true)


func _apply_render_scale() -> void:
	## Cap the 3D pass to the display's pixel count before applying `render_scale`.
	##
	## Godot's macOS backing store can exceed the physical panel resolution.
	## One measurement was 8100×5088 backing pixels on a 7200×4676 panel.
	## The cap avoids rendering those extra pixels.
	var vp: Viewport = scenery_vp if scenery_vp != null else get_viewport()
	var target := vp.get_texture().get_size()
	if target.x < 1.0 or target.y < 1.0:
		return
	var screen := Vector2(DisplayServer.screen_get_size()) \
			* DisplayServer.screen_get_scale()
	var cap := 1.0
	if screen.x > 1.0 and screen.y > 1.0:
		cap = minf(1.0, sqrt((screen.x * screen.y) / (target.x * target.y)))
	var scale := clampf(cap * render_scale, 0.25, 1.0)
	_scenery_scales = Vector2(scale, clampf(cap * motion_render_scale, 0.25, scale))
	# Bilinear, not FSR2: at 0.8 the upscaler cost as much as the resolution
	# saved (1.4 ms against 18 for the same scale).
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	# Each assignment reallocates the render buffers, so set the scale once.
	if scenery_vp != null:
		_update_scenery_scale(false)
	else:
		vp.scaling_3d_scale = scale
	if debug_render:
		print(
			"[render] target %s, screen %s, cap %.3f, scale %.3f, moving %.3f"
			% [str(target), str(screen), cap, scale, _scenery_scales.y]
		)


func _sync_terminal_viewport_size() -> void:
	if _floating():
		# Windows size their own terminals; the canvas is the frame, and its
		# place on the wall follows the frame's shape.
		_fit_uv_basis()
		host.workspace_view.sync_canvas()
		host._refresh_workspace_layout()
		if fx_mat != null:
			RenderUpdates.uniform(fx_mat, "tex_size", _sheet_size())
		return
	# The authored sheet covers the window at its own aspect. The window size
	# is already in backing pixels. Keep the layout used for PTY and font
	# metrics even when the area budget requires a smaller texture.
	if term_vp == null:
		return
	var aspect := _canvas_aspect()
	var win := _window_render_size()
	var height := minf(maxf(win.y, win.x / aspect), ViewportUpdates.MAX_SIDE / maxf(aspect, 1.0))
	var desired := Vector2i(ceili(height * aspect), ceili(height)).max(Vector2i.ONE)
	var raster_scale := ViewportUpdates.bounded_scale(Vector2(desired), 1.0, ViewportUpdates.target_pixel_limit())
	var raster_size := Vector2i((Vector2(desired) * raster_scale).floor()).max(Vector2i.ONE)
	term_vp.size_2d_override = desired
	term_vp.size_2d_override_stretch = true
	term_vp.oversampling = true
	if term_vp.size != raster_size:
		term_vp.size = raster_size
	if term != null:
		if term.has_method("set_raster_scale"):
			term.set_raster_scale(raster_scale)
		var content_rect := _terminal_content_rect(desired)
		term.position = content_rect.position
		term.size = content_rect.size
	if fx_mat != null:
		RenderUpdates.uniform(fx_mat, "tex_size", Vector2(desired))
	_apply_terminal_font_scale(_terminal_font_scale())


func _terminal_content_rect(texture_size: Vector2i) -> Rect2:
	## Center the grid in the texture using `TERMINAL_FRAME_FRACTION`
	## of the visible window and the window's aspect ratio.
	##
	## At the authored aspect ratio, the texture span is (1, 1), so the
## grid occupies the centered 80%.
##
## If the canvas extends beyond the window, divide the overflowing
## axis by its overflow ratio. This keeps the grid at 80% of the
## visible window.
	var span := _canvas_span_in_frame()
	var size := (Vector2(texture_size) * grid_fraction / span).round()
	var origin := ((Vector2(texture_size) - size) * 0.5).round()
	var rect := Rect2(
		(origin + size * workspace_terminal_rect.position).round(),
		(size * workspace_terminal_rect.size).round(),
	)
	return rect


func _terminal_font_scale() -> float:
	## term_font_size is authored for the reference layout, whose grid is
	## TERMINAL_FRAME_FRACTION of 1000 px.
	##
	## The grid is 1:1 with window pixels, so the font follows the grid's own
	## height and a glyph keeps its on-screen size whatever the window's shape.
	##
	## Dividing by the live fraction, not the constant, keeps --grid= a change of
	## how many cells fit rather than of how big a cell is.
	var reference := TERMINAL_LAYOUT_REFERENCE_HEIGHT * grid_fraction
	if term_vp != null:
		return _terminal_content_rect(CoreTerminalEffects.layout_size(term_vp)).size.y / reference
	return _window_render_size().y * grid_fraction / reference


func _project_to_window(point: Vector3) -> Vector2:
	## Project using the frustum the renderer drew.
	##
	## `Camera3D.unproject_position()` uses a height-based projection here.
	## The renderer uses width, so its result differs by the aspect ratio.
	## See `_apply_camera_fx()`.
	var delta := point - proj_eye
	var depth := delta.dot(proj_forward)
	if depth <= 1e-4:
		return Vector2(-1.0, -1.0)
	var x := delta.dot(proj_right) / depth
	var y := delta.dot(proj_up) / depth
	var win := _window_render_size()
	return Vector2(
		(x - proj_rect.x) / maxf(proj_rect.z, 1e-6) * win.x,
		(1.0 - (y - proj_rect.y) / maxf(proj_rect.w, 1e-6)) * win.y,
	)


func _fit_uv_basis() -> void:
	## Where the active screen's uv (0,0) corner is in the world, and the two
	## edge vectors from it.
	##
	## This used to be a least-squares fit over 2400 authored vertices; a quad
	## with a transform simply knows, so the surface answers it directly.
	uv_origin = Vector3.ZERO
	uv_du = Vector3.ZERO
	uv_dv = Vector3.ZERO
	if active < 0 or active >= surfaces.size():
		return
	# Flat2D shares viewport/session synchronization but has no world-space
	# sheet basis. Android's TerminalSurface2D must not enter the 3D projection.
	var surface := surfaces[active] as TerminalSurface3D
	if surface == null:
		return
	var frame := surface.uv_basis()
	var window := _sheet_window()
	uv_origin = frame.origin + frame.du * window.position.x + frame.dv * window.position.y
	uv_du = frame.du * window.size.x
	uv_dv = frame.dv * window.size.y
	if fx_mat != null:
		RenderUpdates.uniform(fx_mat,
			"sheet_window",
			Vector4(window.position.x, window.position.y, window.size.x, window.size.y),
		)
		if _floating() and host.workspace_view.raster_region.has_area():
			var region: Rect2 = host.workspace_view.raster_region
			var sheet := _sheet_size()
			set_workspace_render_region(Rect2(region.position / sheet, region.size / sheet))


## The part of the active surface the sheet occupies, in its UV.
##
## Floating windows are laid out in the frame, so their page is what the
## camera shows at rest: the whole wall where it fits the frame, else the
## covered middle of it.
func _sheet_window() -> Rect2:
	if not _floating():
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var view: Control = host.workspace_view
	var visible: Rect2 = view.viewport_content_rect()
	var retained: Rect2 = view.content_rect()
	# Owner coordinates must keep the same physical attachment when a smaller
	# client reconnects. The client canvas is a render window onto that page,
	# not the page's world-space size. Include the chrome excluded by area.
	var page_origin := retained.position - visible.position
	var page_size := (retained.size + view.size - visible.size).max(Vector2.ONE)
	var ratio := (page_size.x / page_size.y) / _canvas_aspect()
	var shown := Vector2(minf(ratio, 1.0), minf(1.0 / ratio, 1.0)) * CANVAS_COVER_MARGIN
	return Rect2(
		(Vector2.ONE - shown) * 0.5 - page_origin / page_size * shown,
		view.canvas_size() / page_size * shown,
	)


func _texture_uv_to_window(uv: Vector2) -> Vector2:
	uv = _saddle_uv(uv)
	return _project_to_window(uv_origin + uv_du * uv.x + uv_dv * uv.y)


func _cursor_window_point() -> Vector2:
	## Where the cell under the cursor ends up on screen.
	##
	## The terminal knows the point in its own coordinates; only the host knows
	## the surface it is painted on and the camera looking at it.
	if term == null or term_vp == null or not term.has_method("get_cursor_anchor_local"):
		return Vector2(-1.0, -1.0)
	var local: Vector2 = term.call("get_cursor_anchor_local")
	var texel := _terminal_sheet_origin() + (Vector2(term.position) + local) * _terminal_sheet_scale()
	return _project_to_window(_effect_surface_frame(texel / _sheet_size()).origin)


func _update_ime_anchor() -> void:
	## Project the IME candidate window anchor onto the rendered wall.
	## By default Godot uses the terminal control's position inside its
	## SubViewport, which does not locate the wall on screen.
	##
	## See `docs/developers/internals/korean-input.md`.
	if term == null or not term.has_method("set_ime_anchor"):
		return
	var point := _cursor_window_point()
	if point.x < 0.0:
		return
	if _floating():
		# The host window owns the candidate window, not this world's viewport.
		var container: Control = host.world_container
		point = container.get_global_transform_with_canvas() * (
			point / _window_render_size().max(Vector2.ONE) * container.size
		)
	var anchor := Vector2i(point.round())
	if anchor == ime_anchor_last:
		return
	ime_anchor_last = anchor
	term.call("set_ime_anchor", anchor)


func _terminal_cell_px() -> Vector2:
	## Read the measured cell box from the terminal extension.
	## An estimate such as 0.6 × 1.3 em shifts splash and ripple origins
	## away from the rendered glyph.
	if term != null and term.has_method("get_cell_size"):
		var cell: Vector2 = term.call("get_cell_size")
		if cell.x > 0.0 and cell.y > 0.0:
			return cell
	var fs := float(term.get("font_size")) if term != null else 16.0
	return Vector2(maxf(fs * 0.6, 4.0), maxf(fs * 1.3, 8.0))


func _window_render_size() -> Vector2:
	if get_viewport() is SubViewport:
		return Vector2((get_viewport() as SubViewport).size)
	## On macOS, get_visible_rect() can remain at the launch resolution after a
	## native resize. The camera and terminal must follow the actual window.
	var native_size := DisplayServer.window_get_size()
	if native_size.x > 0 and native_size.y > 0:
		return Vector2(native_size)
	return get_viewport().get_visible_rect().size


func _on_window_size_changed() -> void:
	# Native windows may emit a final resize while their world is leaving the tree.
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if active >= 0 and active < surfaces.size() and not surfaces[active].is_inside_tree():
		return
	_fit_flat_sheets()
	_sync_terminal_viewport_size()
	_apply_camera_fx()


func _apply_terminal_font_scale(viewport_scale: float) -> void:
	## Scale the font with the SubViewport. The extension rasterizes
	## glyphs in SubViewport pixels.
	##
	## `term_font_size` is the user's size at the 1600×1000 reference layout.
	var scale := maxf(viewport_scale, 0.001)
	# Resizing a pane must not overwrite the requested font size. Transient
	# tiny viewports can clamp the raster size without making that permanent.
	var requested := term_font_size
	if host != null and host.workspace_view != null and term != null:
		requested = int(term.get_meta("pane_font_size", term_font_size))
	var effective := (
		requested
		if host != null and host.workspace_view != null
		else clampi(roundi(float(term_font_size) * scale), 1, 72)
	)
	if term != null:
		var current := (
			int(term.call("get_live_font_size"))
			if term.has_method("get_live_font_size")
			else int(term.get("font_size"))
		)
		if current != effective:
			if term.has_method("set_live_font_size"):
				term.call("set_live_font_size", effective)
			else:
				term.set("font_size", effective)
	fx_cell_px = _terminal_cell_px()

# --- ui ---------------------------------------------------------------------


func _append_terminal_surface(source_index: int, spare := true) -> int:
	## A new tab reserves the first empty surface; session activation assigns its
	## actual world location in _seat_session.
	##
	## Past the authored places it reuses an existing destination: same
	## placement, same framing, a second screen.
	##
	## Duplicating the node carries its ViewPose child with it, so the copy needs
	## no pose maths of its own.
	var index := surfaces.size()
	if spare and not spare_places.is_empty():
		surfaces.append(spare_places.pop_front())
		return index
	if surfaces.is_empty():
		var initial := TerminalSurface3D.new()
		initial.surface_id = "terminal_1"
		var view := Camera3D.new()
		view.name = "ViewPose"
		view.position.z = 12.0
		initial.add_child(view)
		add_child(initial)
		surfaces.append(initial)
		walls[initial.id] = initial
		focus_points[initial.id] = initial.focus_point()
		return 0
	var source: TerminalSurface3D = surfaces[source_index]
	var surface: TerminalSurface3D = source.duplicate()
	# A copy shares its source's place; it is not a place of the world's own.
	surface.remove_meta("place")
	var id := "terminal_%d" % (index + 1)
	while walls.has(id):
		id += "_new"
	surface.name = id
	surface.surface_id = id
	surface.visit_order = index
	surface.visible = false
	add_child(surface)
	surface.global_transform = source.global_transform
	surfaces.append(surface)
	walls[id] = surface
	focus_points[id] = focus_points.get(source.id, surface.focus_point())
	return index


func _new_terminal_surface_source(_tab_ordinal := -1) -> int:
	return maxi(active, 0)


func create_terminal_tab() -> void:
	host.session_backend.create_tab(host)


## A terminal that opens as another window of a tab. It is drawn on its tab's
## sheet, so it takes none of the world's empty places.
##
## A newly received tab instead allocates a world destination, cycling
## authored places by tab order.
func add_terminal_window(session_id: int, tab_ordinal := -1) -> void:
	var new_tab := tab_ordinal >= 0
	var source := _new_terminal_surface_source(tab_ordinal) if new_tab else maxi(active, 0)
	var index := _append_terminal_surface(source, new_tab)
	surfaces[index].session_id = session_id
	var definitions: Array[Dictionary] = []
	for i in surfaces.size():
		definitions.append({ "id": surfaces[i].session_id, "label": tr("Terminal %d") % (i + 1) })
	host.set_tabs(definitions)


func import_terminal_tab(session_id: int, template: Node = null) -> void:
	# A tab arriving with its own place keeps it, and leaves the empty ones.
	var index := _append_terminal_surface(_new_terminal_surface_source(), template == null)
	if template != null:
		var placeholder: TerminalSurface3D = surfaces[index]
		var id: String = placeholder.id
		var restored: TerminalSurface3D = template.duplicate()
		restored.remove_meta("place")
		restored.surface_id = id
		restored.name = id
		restored.visit_order = index
		restored.visible = false
		placeholder.free()
		add_child(restored)
		surfaces[index] = restored
		walls[id] = restored
		focus_points[id] = restored.focus_point()
	surfaces[index].session_id = session_id
	# receive_workspace already installed the persistent session and definition.
	_goto(index, true)
	host.ui_changed.emit()


func remove_terminal_tab(index: int) -> void:
	var next_active := active - (1 if active > index else 0)
	if active == index:
		next_active = mini(index, surfaces.size() - 2)
	var removing_active := active == index
	if removing_active:
		_end_tab_transition()
	var removed: TerminalSurface3D = surfaces[index]
	var removed_id: String = removed.id
	terminals.erase(removed_id)
	surfaces.remove_at(index)
	if removed.has_meta("place"):
		# The world's own place stays, empty, for the next new tab.
		removed.session_id = -1
		spare_places.append(removed)
		spare_places.sort_custom(
			func(a, b):
				return int(a.get_meta("place")) < int(b.get_meta("place")),
		)
	else:
		# walls[id] IS the surface node, so this frees the destination itself.
		walls[removed_id].queue_free()
		walls.erase(removed_id)
		focus_points.erase(removed_id)
	removed.visible = false
	var definitions: Array[Dictionary] = []
	for i in surfaces.size():
		surfaces[i].visit_order = i
		if not host.is_chromium_pane("%%%d" % surfaces[i].session_id):
			definitions.append({ "id": surfaces[i].session_id, "label": tr("Terminal %d") % (i + 1) })
	host.set_tabs(definitions)
	if removing_active:
		active = -1
		term = null
		term_vp = null
		# The destination session selects its own surface after its tabs exist.
		if not host.session_switch_in_progress: _goto(next_active, true)
	else:
		active = next_active


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.WORLD_CHROME
	add_child(layer)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.add_theme_constant_override("separation", 0)
	layer.add_child(root)

	var external: bool = host != null and host.workspace_view != null
	var tab_strip: Control = host.ui.create_tab_strip() if host != null and not external else null
	tabs = (
		host.workspace_view.tab_bar.tabs
		if external
		else (tab_strip.tabs if tab_strip != null else TabBar.new())
	)
	# Keep keyboard focus in the terminal when the user changes tabs.
	# The tab bar works through clicks and Ctrl+Tab without taking focus.
	#
	# Godot clears focus across all viewports in the window when a control
	# grabs focus. See Viewport::_gui_control_grab_focus and
	# _gui_remove_focus_for_window. If a tab grabs focus, the terminal stops
	# receiving keys until the user clicks it again.
	tabs.focus_mode = Control.FOCUS_NONE
	if host == null:
		tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
		tabs.clip_tabs = true
		tabs.scrolling_enabled = true
		tabs.select_with_rmb = false
		for s in surfaces:
			tabs.add_tab(_surface_label(str(s.id)))
		tabs.tab_changed.connect(_on_session_requested)
	if not external:
		root.add_child(tab_strip if tab_strip != null else tabs)
	if host != null:
		# Workspace tabs already show progress. A second bar at y=0 would paint
		# over their background instead of belonging to a terminal pane.
		if not external:
			var progress: ProgressBar = host.ui.create_progress_bar()
			progress.custom_minimum_size.y = 5
			root.add_child(progress)
		if external:
			host.ui.mount_scroll_bar(self)
			return
		var scrollbar: VScrollBar = host.ui.create_scroll_bar()
		layer.add_child(scrollbar)
		scrollbar.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
		scrollbar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		var strip: Control = host.workspace_view.tab_bar if external else tab_strip
		var layout_scrollbar := _layout_scrollbar.bind(scrollbar, strip)
		strip.item_rect_changed.connect(layout_scrollbar)
		strip.visibility_changed.connect(layout_scrollbar)
		scrollbar.minimum_size_changed.connect(layout_scrollbar)
		host.world_container.resized.connect(layout_scrollbar)
		layout_scrollbar.call_deferred()




func _layout_scrollbar(scrollbar: VScrollBar, strip: Control) -> void:
	# Follow the actual tab strip, including custom heights and hidden tabs.
	scrollbar.offset_left = -scrollbar.get_combined_minimum_size().x
	scrollbar.offset_right = 0
	var bottom := strip.get_global_rect().end.y
	if strip.get_viewport() != scrollbar.get_viewport():
		# Workspace chrome lives outside the world viewport, below window chrome.
		var container: SubViewportContainer = host.world_container
		bottom = (bottom - container.get_global_rect().position.y) / container.stretch_shrink
	scrollbar.offset_top = maxf(0.0, bottom) if strip.is_visible_in_tree() else 0.0
	scrollbar.offset_bottom = 0

# --- flight, matched to background.inc --------------------------------------


func _on_session_requested(index: int) -> void:
	if host != null:
		_seat_tabs()
		# Every window of a tab is on one sheet: focusing another window only
		# moves the camera to its cursor. Changing tabs changes surfaces.
		var surface := _surface_for_session(_sheet_session(index) if _floating() else index)
		if surface >= 0 and surface != active:
			_goto(surface, false)
		if _floating():
			_focus_session(index)
		return
	_goto(index, false)


## The world's own places are for tabs.
##
## A window that joins another tab gives its place back, and a window made a
## tab takes the first free one: new tabs then go to places in order, with no
## gaps.
##
## The place on screen is never swapped from under the camera.
func _seat_tabs() -> void:
	var firsts: Array[int] = []
	for group in host.workspace_layout.tabs:
		firsts.append(_first_terminal(group))
	for i in surfaces.size():
		if (
			i != active and surfaces[i].has_meta("place")
			and not firsts.has(int(surfaces[i].session_id))
		):
			_trade_place(i, null)
	for first in firsts:
		var index := _surface_for_session(first)
		if spare_places.is_empty():
			return
		if index >= 0 and index != active and not surfaces[index].has_meta("place"):
			_trade_place(index, spare_places.pop_front())


## Surface `index` changes its node for another, keeping its terminal: for a
## free place of the world's own, or for a copy of itself when `place` is
## null.
##
## A place it gives back waits for the next tab; a copy it gives up goes.
func _trade_place(index: int, place: TerminalSurface3D) -> void:
	var old: TerminalSurface3D = surfaces[index]
	if place == null:
		place = old.duplicate()
		place.remove_meta("place")
		var id := "terminal_%d" % (surfaces.size() + spare_places.size() + 1)
		while walls.has(id):
			id += "_new"
		place.name = id
		place.surface_id = id
		place.visible = false
		add_child(place)
		place.global_transform = old.global_transform
		walls[id] = place
		focus_points[id] = place.focus_point()
	place.session_id = old.session_id
	surfaces[index] = place
	terminals.erase(old.id)
	if old.has_meta("place"):
		old.session_id = -1
		old.visible = false
		spare_places.append(old)
		spare_places.sort_custom(
			func(a, b):
				return int(a.get_meta("place")) < int(b.get_meta("place")),
		)
	else:
		walls.erase(old.id)
		focus_points.erase(old.id)
		old.queue_free()


func _surface_for_session(index: int) -> int:
	for i in surfaces.size():
		if int(surfaces[i].session_id) == index:
			return i
	return -1


## The terminal whose surface carries a tab's sheet: the tab's first one.
func _sheet_session(index: int) -> int:
	var first := _first_terminal(
		host.workspace_layout.tab(host.workspace_layout.containing("%%%d" % index))
	)
	return first if first >= 0 else index


func _first_terminal(group: Dictionary) -> int:
	for key in WorkspaceLayoutScript.keys(group.get("tree", { })):
		if host.is_terminal_pane(key):
			return int(key.substr(1))
	return -1


## Another window on the same sheet takes the keyboard and the camera's cursor.
func cancel_typing_effects() -> void:
	# Cancel the trigger, not the current pose or interpolation state.
	fx_last_key = -1e9
	if is_instance_valid(terminal_effects): terminal_effects.cancel_typing()


func _focus_session(index: int) -> void:
	var pair: Dictionary = host.session_for(index, self)
	if pair.is_empty():
		return
	if pair.term != term:
		term_vp = pair.vp
		term = pair.term
		fx_cell_px = _terminal_cell_px()
		_apply_terminal_config()
		if terminal_effects != null:
			terminal_effects.bind_terminal(term, fx_mat, _effect_surface_frame, _terminal_presentation_frame)
	host.activate_session(pair)
	term.call_deferred("grab_focus")


## Tabs stand at the world's places in tab order, so moving a tab moves it to
## the place of its new position, and the camera goes along with the tab shown.
func follow_tab_order() -> void:
	if host == null or surfaces.is_empty():
		return
	_seat_tabs()
	# The world's places in its own order, then copies: the n-th tab takes the
	# n-th place, whatever order the places were taken in.
	var shown_surface: Node = surfaces[active] if active >= 0 else null
	var taken := { }
	for i in surfaces.size():
		taken[surfaces[i]] = i
	surfaces.sort_custom(
		func(a, b):
			var pa := int(a.get_meta("place", 1 << 20))
			var pb := int(b.get_meta("place", 1 << 20))
			return pa < pb if pa != pb else taken[a] < taken[b],
	)
	if shown_surface != null:
		active = surfaces.find(shown_surface)
	var ids := _tab_order_ids()
	var shown := _first_terminal(host.workspace_layout.tab(host.workspace_layout.active))
	var target := ids.find(shown)
	if (
		active >= 0 and target >= 0 and target != active
		and int(surfaces[active].session_id) == shown
	) \
			and surfaces[target].global_transform.is_equal_approx(surfaces[active].global_transform):
		# Its new place is where it already stands, as every flat sheet shares
		# one: the tab shown keeps its surface, and nothing moves.
		ids[target] = ids[active]
		ids[active] = shown
	var changed := false
	for i in surfaces.size():
		changed = changed or int(surfaces[i].session_id) != ids[i]
	if changed:
		for i in surfaces.size():
			surfaces[i].session_id = ids[i]
		# The terminal a place shows is looked up again on the next visit.
		terminals.clear()
	# The tab shown may stand somewhere new even with no place changing hands:
	# a window just made a tab has been given a place of its own.
	target = _surface_for_session(shown)
	if target < 0 or target == active:
		return
	var focused: int = host.active_session_id
	_goto(target, false)
	if _floating() and focused >= 0:
		_focus_session(focused)


## The terminal each place shows, in place order: every tab's own, in tab
## order, then the tabs' other terminals.
func _tab_order_ids() -> Array[int]:
	var ids: Array[int] = []
	for group in host.workspace_layout.tabs:
		var first := _first_terminal(group)
		if first >= 0 and _surface_for_session(first) >= 0:
			ids.append(first)
	for s in surfaces:
		if not ids.has(int(s.session_id)):
			ids.append(int(s.session_id))
	return ids


var session_transition_active := false
var _building_switch_arrival := false
var session_transition_capture: Dictionary = {}
var _session_places: Dictionary = {}

## Session identity survives replacing its terminal mirrors. Reserve authored
## destinations for server sessions, so revisiting one returns to its location.
## Tabs still exchange content on the current surface without travelling.
func _seat_session(index: int) -> void:
	if not host.session_backend.is_remote: return
	var connection: Node = host.session_backend.connection
	var peer: Node = connection.owners.get(int(surfaces[index].session_id), connection.selected) if "owners" in connection else connection
	if peer == null: return
	var places: Array = (surfaces + spare_places).filter(func(surface): return surface.has_meta("place"))
	if places.size() < 2: return
	places.sort_custom(func(a, b): return int(a.get_meta("place")) < int(b.get_meta("place")))
	for session in peer.available_sessions:
		var key := JSON.stringify([peer.url, session.id])
		if not _session_places.has(key): _session_places[key] = _session_places.size() % places.size()
	var key := JSON.stringify([peer.url, peer.workspace])
	if not _session_places.has(key): return
	var place: TerminalSurface3D = places[_session_places[key]]
	if surfaces[index] == place: return
	var shown: Node = surfaces[active] if active >= 0 else null
	var occupied := surfaces.find(place)
	if occupied >= 0:
		_swap_tab_places(index, occupied)
	else:
		spare_places.erase(place)
		_trade_place(index, place)
	active = surfaces.find(shown)

func _set_session_transition_active(value: bool) -> void:
	if session_transition_active == value: return
	# Retiring pieces may continue only within the same effect. Handing dust
	# to a tab's zoom leaves both animations visible and mixes their clocks.
	_clear_switch_visuals()
	session_transition_active = value

func _clear_switch_visuals() -> void:
	for layer in tab_fx_out + tab_fx_in: layer.hide()
	_end_tab_transition()
	for entry in tab_fx_stale:
		entry.layer.hide()
		entry.layer.queue_free()
	tab_fx_stale.clear()

func begin_session_transition(animate := true) -> void:
	var interrupted := animate and session_transition_active and tab_fx_wall != null
	var retiring: Array = []
	var previous_wall := tab_fx_wall
	if interrupted:
		# Preserve the pieces actually on screen, including their current alpha
		# and flight phase. Recapturing the live pane would make it fully opaque.
		_hand_over_flying_pieces()
		retiring = tab_fx_stale
		tab_fx_stale = []
	if animate: _end_tab_transition()
	else: _clear_switch_visuals()
	if interrupted and is_instance_valid(previous_wall): previous_wall.hide()
	# Keep the departing adaptive pose until the incoming topology is bound.
	# A frame can render between these callbacks; resetting here flashes the
	# neutral tilt before finish_session_transition restores the capture.
	for layer in session_transition_capture.get("layers", []): layer.queue_free()
	for entry in session_transition_capture.get("retiring", []): entry.layer.queue_free()
	session_transition_capture.clear()
	_set_session_transition_active(animate and fx_cfg.scene.session_switch.effect != "none" and fx_enabled and effect_control.allows("session_switch"))
	if not session_transition_active or not _floating() or active < 0:
		for entry in retiring: entry.layer.queue_free()
		return
	var origin := _effect_surface_frame(Vector2.ZERO).origin
	var shape := _piece_sheet_shape()
	# The live sheet can still draw while the server binds the destination.
	# Freeze its complete lens with its displayed pose through that interval.
	# The short Fly Away handoff lands while its scatter is still departing.
	# Reach its idle look by mid-flight even when the backings outlast it.
	var fade_end := minf(CellShatterScript.BACKING_FLIGHT_FRACTION, 0.5 * _transition_duration() / _tab_departure_duration())
	var departing_lens := Vector3(terminal_effects.focus_depth, terminal_effects.blur_radius, terminal_effects.depth_range)
	session_transition_capture = {"origin": origin, "du": uv_du, "dv": uv_dv, "layers": [], "retiring": retiring,
		"camera": {"transform": cam.global_transform, "rect": proj_rect},
		"focus_depth": departing_lens.x, "lens_zoom": terminal_lens_zoom,
		# Only the departing pieces carry the aperture after binding.
		"optics": Vector3(0.0, departing_lens.z, terminal_effects.defocus_weight)}
	cancel_typing_effects()
	if not interrupted:
		var layers := _workspace_transition_layers(origin, uv_du, uv_dv, shape)
		var windows := _shown_panes()
		for i in windows.size():
			layers.append_array(_window_layers(windows[i], origin, uv_du, uv_dv, shape, i))
		for layer in layers:
			layer.departing_lens = departing_lens
			layer.aperture_end_phase = fade_end / CellShatterScript.BACKING_FLIGHT_FRACTION if layer.has_meta("panel") else fade_end
			layer.hide()
		session_transition_capture.layers = layers

func finish_session_transition() -> void:
	if session_transition_capture.is_empty(): return
	var captured := session_transition_capture
	session_transition_capture = {}
	if active < 0 or active >= surfaces.size():
		for layer in captured.layers: layer.queue_free()
		for entry in captured.retiring: entry.layer.queue_free()
		return
	session_transition_active = true
	tab_fx_stale.append_array(captured.retiring)
	for layer in captured.layers: layer.show()
	var surface: TerminalSurface3D = surfaces[active]
	# Replacing every pane can bind the new surface instantly. Restore the
	# departing view before starting the session's actual world-space flight.
	camera_motion.reset(captured.camera)
	_display_camera_frame(captured.camera)
	# Restore the captured focus and tint before any retained pass draws.
	lens_transition_from = captured.focus_depth
	lens_transition_zoom_from = captured.lens_zoom
	lens_transition_optics_from = captured.optics
	lens_transition_t = 0.0
	# The departure already includes the typing transform. Aim directly at
	# the arriving session's resting view, as for a tab navigation.
	fx_typing = 0.0
	_settle_camera_at_rest()
	_begin_navigation(-1, active, 0.0)
	_update_terminal_lens()
	_start_tab_transition(captured.origin, captured.du, captured.dv,
		walls[surface.id], surface.eye, term, term_vp, [], {}, [], captured.layers)
	_sync_tab_transition_deadline()


func _swap_tab_places(previous: int, destination: int) -> void:
	var leaving: TerminalSurface3D = surfaces[previous]
	var arriving: TerminalSurface3D = surfaces[destination]
	var leaving_pair: Dictionary = terminals.get(leaving.id, {})
	var arriving_pair: Dictionary = terminals.get(arriving.id, {})
	var leaving_session := leaving.session_id
	leaving.session_id = arriving.session_id
	arriving.session_id = leaving_session
	surfaces[previous] = arriving
	surfaces[destination] = leaving
	terminals.erase(leaving.id)
	terminals.erase(arriving.id)
	if not arriving_pair.is_empty(): terminals[leaving.id] = arriving_pair
	if not leaving_pair.is_empty(): terminals[arriving.id] = leaving_pair


func _goto(idx: int, instant: bool) -> void:
	instant = instant or (host != null and host.instant_workspace_switch)
	if idx < 0 or idx >= surfaces.size():
		return
	if host != null and (active < 0 or host.session_switch_in_progress):
		_seat_session(idx)
	if idx == active: return
	if instant:
		_end_tab_transition()
		for entry in tab_fx_stale:
			entry.layer.queue_free()
		tab_fx_stale.clear()
	var prev := active
	# Instant switches keep the typing camera, but never the previous wall's
	# adaptive correction (non-instant switches reset the whole camera below).
	if fx_camera != null: fx_camera.reset_projection()
	if host == null or not host.session_switch_in_progress:
		_set_session_transition_active(false)
	tab_fx_direction = _tab_direction(prev, idx)
	if cam != null:
		var displayed := { "transform": cam.global_transform, "rect": proj_rect }
		if not _camera_observed:
			camera_motion.reset(displayed)
			_camera_observed = true
		else:
			camera_motion.frame = displayed
	# The map of the wall we are leaving, before _fit_uv_basis() replaces it with
	# the one we are going to. The departing pieces live on the old plane.
	#
	# Pieces must start on the rendered mesh, including its decal lift.
	var from_origin := _effect_surface_frame(Vector2.ZERO).origin
	var from_du := uv_du
	var from_dv := uv_dv
	# The terminal we are leaving: the departing pieces are cut from its screen,
	# not from the one we are going to. They are different terminals.
	var out_term := term
	var out_vp := term_vp
	# With floating windows, the ones on screen now, before focus refreshes them.
	var out_windows: Array = _shown_panes() if _floating() else []
	var out_shape := _piece_sheet_shape()
	var out_graph: Array = []
	var out_layers: Array = []
	if _floating() and tab_fx and effect_control.allows("tab_switch") and not host.session_switch_in_progress and not instant and prev >= 0 and walls.has(surfaces[idx].id) and tab_fx_wall == null:
		# During a transition the live sheet is hidden. Its retained pieces are
		# the displayed content; capturing that sheet again creates a second copy.
		out_graph = _workspace_transition_layers(from_origin, from_du, from_dv, out_shape)
		# Capture the displayed chrome before activating the destination changes
		# navigation compensation and the outgoing pane's title geometry.
		for i in out_windows.size():
			out_layers.append_array(_window_layers(out_windows[i], from_origin, from_du, from_dv, out_shape, i))
	if _floating():
		host.workspace_view.restore_navigation(
			host.workspace_layout.containing("%%%d" % surfaces[idx].session_id)
		)
	if not instant and prev >= 0:
		# The full displayed frame is already captured. Settle the new terminal
		# at its authored view; never add the departing typing transform twice.
		fx_last_key = -1e8
		fx_cam_zoom = 1.0
		gesture_zoom = 1.0
		fx_cam_pan = Vector2.ZERO
		fx_cam_tilt = Vector2.ZERO
		fx_camera.reset(_sheet_size())
	# Hold optical depth, not a world-space point: the focus plane travels with
	# the camera. Interruptions start from the lens actually displayed now.
	lens_transition_t = 0.0 if prev >= 0 and not instant else -1.0
	if terminal_effects != null:
		lens_transition_from = terminal_effects.focus_depth
		lens_transition_zoom_from = terminal_lens_zoom
		lens_transition_optics_from = Vector3(terminal_effects.blur_radius, terminal_effects.depth_range, terminal_effects.defocus_weight)
	lens_transition_duration = maxf(FLY_TIME, maxf(TAB_FX_LEAVE, TAB_FX_ARRIVE))
	# How fast the camera is already travelling, read before `active` moves on
	# and before the path is rebuilt under it. Zero unless this cuts a flight
	# short.
	var out_speed := _fly_speed()
	# Capture the outgoing geometry first, then exchange content in place.
	if prev >= 0 and host != null and not host.session_switch_in_progress:
		_swap_tab_places(prev, idx)
	active = idx
	if fx_trail != null:
		fx_trail.clear()
	var s: TerminalSurface3D = surfaces[idx]

	if prev >= 0 and walls.has(surfaces[prev].id):
		walls[surfaces[prev].id].visible = false
	_fit_uv_basis()
	# The first terminal exists before any wall is active, so the first visit
	# adopts it instead of making a second one.
	if prev < 0 and term != null and not terminals.has(s.id):
		terminals[s.id] = { "vp": term_vp, "term": term }
	var pair := _terminal_for(s.id)
	if not pair.is_empty():
		term_vp = pair["vp"]
		term = pair["term"]
		if host != null:
			host.activate_session(pair)
		_apply_terminal_config()
		term.call_deferred("grab_focus")
	if (term != null or _floating()) and walls.has(s.id):
		_sync_terminal_viewport_size()
		var wall: MeshInstance3D = walls[s.id]
		wall.material_override = _terminal_material()
		wall.set_instance_shader_parameter("workspace_clip_top", _workspace_clip_top)
		# Use `TerminalSurface3D.surface_lift` to offset the mesh.
		# Keep the node position at its authored placement.
		wall.visible = true

	if terminal_effects != null:
		terminal_effects.bind_terminal(term, fx_mat, _effect_surface_frame, _terminal_presentation_frame)
	if host == null and tabs != null and tabs.current_tab != idx:
		tabs.current_tab = idx

	if tab_fx and effect_control.allows("tab_switch") and (host == null or not host.session_switch_in_progress) and not instant and prev >= 0 and walls.has(s.id):
		_start_tab_transition(
			from_origin,
			from_du,
			from_dv,
			walls[s.id],
			s.eye,
			out_term,
			out_vp,
			out_windows,
			out_shape,
			out_graph,
			out_layers,
		)

	if instant or prev < 0:
		camera_motion.stop()
		_camera_observed = false
		fly_dur = 0.0
		fly_carry = 0.0
		_apply_pose(s.eye, s.forward, s.up, s.half_x)
		return

	_settle_camera_at_rest()
	_begin_navigation(prev, idx, out_speed)
	_sync_tab_transition_deadline()


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("TerminalWorld", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	if term == null or term_vp == null:
		return
	if probe_freeze:
		return
	if fly_dur > 0.0 or tab_fx_t >= 0.0 or lens_transition_t >= 0.0 or scenery_continuous:
		RenderUpdates.activity()
	if film_dt > 0.0:
		dt = film_dt
	# Navigation and scatter are analytic animations: retain elapsed wall time
	# through slow frames while bounding the physics/typing simulation step.
	var elapsed := _transition_elapsed(dt)
	dt = minf(dt, 0.05)
	dt_last = dt
	_update_ime_anchor()
	if debug_render and Engine.get_process_frames() % 45 == 30:
		print(
			"[focus] term=%s vp_focus_owner=%s main_focus_owner=%s vp_size=%s"
			% [
				str(term.has_focus()) if term else "nil",
				str(term_vp.gui_get_focus_owner()) if term_vp else "nil",
				str(get_viewport().gui_get_focus_owner()),
				str(term_vp.size) if term_vp else "nil",
			]
		)
	if debug_render and Engine.get_process_frames() % 120 == 30:
		print(
			"[dbg] f=%d cam=%s fov=%.1f current=%s vp=%s walls=%d"
			% [
				Engine.get_process_frames(),
				str(cam.global_position) if cam else "nil",
				cam.fov if cam else -1.0,
				str(cam.current) if cam else "nil",
				str(get_viewport().size),
				walls.size(),
			]
		)
	# The cursor comes straight from the terminal now (_read_cursor reads the
	# cell repaint() already computed), so this is a field read per frame.
	#
	# It used to be an 18 ms get_image() readback, which is why it was once gated
	# on being idle.
	fx_cursor_live = _read_cursor()
	# Anything that releases GUI focus — a click on the bare 3D view, a future
	# control — can leave the terminal unfocused.
	#
	# Restore it only when the window has no focused control, so messages and
	# other UI keep keyboard input.
	var chromium_text_focus := false
	if host != null and is_instance_valid(host.chromium_panel) and host.chromium_panel.has_method(
			"has_text_focus"
		):
		chromium_text_focus = host.chromium_panel.has_text_focus()
	if (
		not chromium_text_focus and term != null and term_vp != null
		and term_vp.gui_get_focus_owner() == null
		and get_window().gui_get_focus_owner() == null
	):
		term.grab_focus()
	_step_navigation(elapsed)
	# Focus and tint land with the camera even when a slow frame exceeds
	# the typing simulation's 50 ms step.
	if lens_transition_t >= 0.0:
		lens_transition_t += elapsed
	_step_terminal_dof(minf(dt, elapsed))
	if world_awake or Time.get_ticks_msec() < pointer_active_until or fly_dur > 0.0:
		_fx_step(minf(dt, elapsed))
	_update_tab_transition(elapsed)
	terminal_effects.advance_cursor(dt)
	_update_stale_pieces(elapsed)
	if cam != null and not camera_motion.moving:
		var displayed := { "transform": cam.global_transform, "rect": proj_rect }
		if _camera_observed:
			camera_motion.observe(displayed, elapsed)
		else:
			camera_motion.reset(displayed)
			_camera_observed = true
	# Ink-enabled worlds synchronize both passes at frame_pre_draw, after
	# workspace tweens have finished changing the camera for this frame.
	if ink_vp == null:
		_update_scenery_view()
	_notify_workspace_projection_changed()


func _fx_apply_scene() -> void:
	tab_fx = fx_cfg.scene.tab_switch.effect != "none" and not tab_fx_disabled
	## Scene-wide settings do not vary with state, so they are pushed once.
	var sh: Dictionary = fx_cfg.scene["sheet"]
	fx_ripple_wavelength = float(sh["ripple_wavelength"])
	fx_ripple_speed = float(sh["ripple_speed"])
	fx_ripple_falloff = float(sh["ripple_falloff"])
	fx_edge_margin = float(sh["edge_margin"])
	fx_corner_radius = float(sh["corner_radius"])
	fx_edge_shadow = float(sh["edge_shadow"])
	fx_edge_shadow_width = float(sh["edge_shadow_width"])
	fx_content_gloss = float(sh["content_gloss"])

	var ty: Effects.TypingSettings = fx_cfg.typing_settings()
	fx_particles_amount = ty.particles_amount
	fx_particles_scale = ty.particles_scale
	fx_splash_scale = ty.splash_scale
	fx_splash_speed = ty.splash_speed
	fx_splash_life = ty.splash_life

	# [scene.camera] was declared in Effects.gd and never read, so every one of
	# these was silently inert and the shader's own defaults applied instead.
	var cm: Dictionary = fx_cfg.scene["camera"]
	fx_camera.configure(cm)
	fx_tilt_light_strength = float(fx_cfg.scene.lighting["strength"])
	fx_tilt_light_min = float(fx_cfg.scene.lighting["minimum"])
	fx_tilt_light_max = float(fx_cfg.scene.lighting["maximum"])
	fx_tilt_light_color = Color(String(fx_cfg.scene.lighting["color"]))
	fx_tilt_shadow_color = Color(String(fx_cfg.scene.camera["dof_blur_tint"]))
	fx_shadow_tint_strength = clampf(float(fx_cfg.scene.camera["dof_blur_tint_strength"]), 0.0, 1.0)
	fx_plane_lean_scale = maxf(float(cm["graphics_plane_tilt_scale"]), 0.0)
	fx_plane_lift = float(cm["graphics_plane_lift"])

	var wo: Dictionary = fx_cfg.scene["world"]
	if (
		String(wo["mode"]) != "3d"
		and not Array(OS.get_cmdline_user_args()).any(
			func(a):
				return a.begins_with("--world=") or a.begins_with("--wallpaper="),
		)
	):
		world_mode = String(wo["mode"])
		wallpaper_path = String(wo["wallpaper"])
		if String(wo["color"]) != "":
			bg_color = Color(String(wo["color"]))

	fx_enter_duration = float(fx_cfg.behavior["enter_duration"])
	fx_idle_after = float(fx_cfg.behavior["idle_after"])
	fx_leave_duration = float(fx_cfg.behavior["leave_duration"])


func _fx_frame(e: float) -> Dictionary:
	## The two states the behaviour machine moves between, blended by the eased
	## typing factor. Named, so a preset is not limited to idle/typing.
	var rest: Dictionary = fx_cfg.frame(String(fx_cfg.behavior["rest_state"]))
	var active: Dictionary = fx_cfg.frame(String(fx_cfg.behavior["active_state"]))
	return _controlled_frame(fx_cfg.blend(rest, active, e))


func _controlled_frame(source: Dictionary, destination := false) -> Dictionary:
	var rest: Dictionary = fx_cfg.frame(str(fx_cfg.behavior.rest_state))
	rest["sheet.curvature_deg"] = fx_cfg.curvature_deg(rest)
	source["sheet.curvature_deg"] = fx_cfg.curvature_deg(source)
	return effect_control.frame(source, destination, rest)


func _fx_step(dt: float) -> void:
	## idle <-> typing with separate enter and leave ramps, as
	## effects.Behavior(enter_duration=, idle_after=, leave_duration=) describes.
	if fx_mat == null:
		return
	fx_time += dt
	effect_control.advance(dt, fx_enter_duration, fx_leave_duration)
	var target := 1.0 if (fx_time - fx_last_key) < fx_idle_after else 0.0
	var ramp: float = fx_enter_duration if target > fx_typing else fx_leave_duration
	# Move toward the target by `1 - 2^(-10*dt/td)` each step, where `td`
	# is the transition duration. This moves quickly at first and slows
	# as it settles. A smoothstep ramp delayed the first response to typing.
	#
	# Each target is a fixed frame value. Decaying the blend factor
	# is therefore equivalent to decaying every quantity.
	fx_typing += (target - fx_typing) * (1.0 - pow(2.0, -10.0 * dt / maxf(ramp, 1e-3)))
	# Finish the ease exactly. Subpixel residual curvature otherwise changes
	# sheet geometry forever and prevents the rendering server from sleeping.
	if absf(target - fx_typing) < 0.000001: fx_typing = target
	var e: float = fx_typing # the decay IS the easing; a smoothstep on top double-eases

	# Resolved before the pan and tilt below read tilt_limit_deg and zoom out of it.
	var fr := _fx_frame(e)
	fx_prev_frame = fr
	fx_drift_px = float(fr["camera.drift_px"])
	fx_drift_speed = float(fr["camera.drift_speed"])
	fx_shake_px = float(fr["camera.shake_px"])
	fx_shake_seconds = float(fr["camera.shake_seconds"])
	fx_tilt_limit_deg = float(fr["camera.tilt_limit_deg"])
	fx_curvature_deg = (
		0.0
		if _floating() and host.workspace_view.is_overview()
		else fx_cfg.curvature_deg(fr)
	)
	fx_particles = String(fr["typing.particles"])

	# The terminal-camera controller owns pixel-space zoom,
	# follow pan, cursor anchoring, drift, shake and tilt. Godot receives only
	# its resolved pose and applies it to Camera3D in _apply_camera_fx().
	var pane_px := _sheet_size()
	_update_camera_follow_bounds()
	# Follow the same rendered, bent-sheet anchor used by final containment.
	#
	# Following the flat grid can otherwise leave the real cursor pinned to a
	# frustum edge, especially in a narrow window with saddle and zoom enabled.
	var cursor_px := _camera_cursor_center()
	var camera_typing := target > 0.5 and not camera_motion.moving and effect_control.camera_active()
	var destination: Dictionary = fx_cfg.frame(
		String(fx_cfg.behavior["active_state"] if camera_typing else fx_cfg.behavior["rest_state"])
	)
	destination = _controlled_frame(destination, true)
	_prepare_adaptive_camera(fx_camera)
	fx_camera.advance(
		dt,
		cursor_px,
		pane_px,
		fx_cell_px,
		float(destination["camera.zoom"]) if fx_enabled else 1.0,
		deg_to_rad(float(destination["camera.tilt_limit_deg"])) if fx_enabled else 0.0,
		float(destination["camera.drift_px"]) if fx_enabled else 0.0,
		float(destination["camera.drift_speed"]),
		fx_enabled and camera_typing,
		maxf(ramp, 1e-3),
		tab_fx_t < 0.0,
	)
	_advance_navigation_camera(dt, destination, camera_typing, ramp)
	fx_cam_zoom = fx_camera.zoom
	fx_cam_tilt = fx_camera.tilt
	fx_follow_pan = (fx_camera.pan / pane_px - Vector2(0.5, 0.5)) * 2.0


	fx_cam_pan = ((fx_camera.render_pan / pane_px) - Vector2(0.5, 0.5)) * 2.0 if fx_enabled else Vector2.ZERO
	# Neutral: pan is a camera translation now, so panning the ink too would
	# move the page twice.
	RenderUpdates.uniform(fx_mat, "pan", Vector2.ZERO)

	_apply_camera_fx(_saddle_uv(fx_camera.animated_cursor / pane_px, true))

	# Neutral: the zoom is carried by the camera now, so scaling here too would
	# apply it twice.
	RenderUpdates.uniform(fx_mat, "zoom", 1.0)
	# The lean angle still reaches the shader because the reference bridge keeps
	# the tilt LIGHTING (live_producer.inc calls sheet_frame_light with
	# camera_tilt_light_*).
	#
	# Only the geometric warp is off: the viewpoint swings instead, so the paper
	# stays flat.
	RenderUpdates.uniform(fx_mat, "tilt_rad", fx_cam_tilt)
	# The reference path publishes pane.w_row as the denominator row of the page
	# homography.
	#
	# For a flat Godot wall the equivalent row is the projective denominator
	# induced by the camera lean; keeping it as a row makes the shader path
	# explicit and gives future image planes the same mapping.
	RenderUpdates.uniform(fx_mat, "homography_row", Vector3(0.0, 0.0, 1.0))
	RenderUpdates.uniform(fx_mat, "plane_lift_factor", 1.0)
	RenderUpdates.uniform(fx_mat, "tilt_warp", 0.0)
	# Defocus tint is driven by the lens, continuously, without animation gates.
	RenderUpdates.uniform(fx_mat, "tilt_light_strength", fx_tilt_light_strength * effect_control.weight("lighting"))
	RenderUpdates.uniform(fx_mat, "tilt_light_min", fx_tilt_light_min)
	RenderUpdates.uniform(fx_mat, "tilt_light_max", fx_tilt_light_max)
	RenderUpdates.uniform(fx_mat, "tilt_light_color", fx_tilt_light_color)
	RenderUpdates.uniform(fx_mat, "tilt_shadow_color", fx_tilt_shadow_color)
	RenderUpdates.uniform(fx_mat, "shadow_tint_strength", fx_shadow_tint_strength)
	terminal_effects.enabled = fx_enabled
	# Windows move on the canvas; effects follow the focused one's place on it.
	terminal_effects.sheet_viewport = _sheet_viewport()
	terminal_effects.sheet_origin = _terminal_sheet_origin()
	terminal_effects.sheet_scale = _terminal_sheet_scale()
	terminal_effects.sheet_panel = Rect2(0, 0, 1, 1) if _floating() else Rect2()
	terminal_effects.cursor = terminal_effects.to_sheet_uv(fx_cursor)
	terminal_effects.camera_zoom = fx_cam_zoom
	terminal_effects.advance(dt, fr)
	fx_splash_at = terminal_effects.splash_at
	fx_splash_age = terminal_effects.splash_age
	RenderUpdates.uniform(fx_mat, "curvature_rad", deg_to_rad(fx_curvature_deg))
	RenderUpdates.uniform(fx_mat, "edge_margin", fx_edge_margin)
	RenderUpdates.uniform(fx_mat, "corner_radius", fx_corner_radius)
	RenderUpdates.uniform(fx_mat, "edge_shadow", fx_edge_shadow * effect_control.weight("sheet.shadow"))
	RenderUpdates.uniform(fx_mat, "edge_shadow_width", fx_edge_shadow_width)
	RenderUpdates.uniform(fx_mat, "content_gloss", fx_content_gloss * effect_control.weight("sheet.gloss"))
	_sync_graphics_planes()
	_update_terminal_lens()


func _update_terminal_lens() -> void:
	if not session_transition_capture.is_empty(): return
	# Focus on the cursor. update_lens() hands Godot's bokeh pass the focus and
	# dof_blur_amount directly; the physical attributes only carry exposure.
	if fx_attr != null and active >= 0:
		# Grid coordinates are not sheet UVs: padding and the inset terminal
		# rectangle matter, particularly on tall world surfaces.
		var focus_world: Vector3 = _effect_surface_frame(terminal_effects.to_sheet_uv(fx_cursor)).origin
		# The normalized lens is set directly below. Updating physical focal
		# length here also changes Camera3D's projection, undoing the off-axis
		# framing just applied above and desynchronizing the ink camera.
		var target_depth := maxf(
			(focus_world - cam.global_position).dot(-cam.global_basis.z),
			0.051,
		)
		var lens_depth := target_depth
		var lens_progress := 1.0
		terminal_lens_zoom = fx_cam_zoom * gesture_zoom
		if lens_transition_t >= 0.0:
			lens_progress = smoothstep(0.0, 1.0, lens_transition_t / lens_transition_duration)
			lens_depth = transition_focus_depth(
				lens_transition_from,
				target_depth,
				lens_transition_t / lens_transition_duration,
			)
			# The destination camera controller resets at a switch. The displayed
			# lens must retain the outgoing zoom and follow the same smooth flight.
			terminal_lens_zoom = lerpf(lens_transition_zoom_from, terminal_lens_zoom, lens_progress)
			if lens_transition_t >= lens_transition_duration:
				lens_transition_t = -1.0
		terminal_effects.blur_limit = 24.0
		terminal_effects.blur_weight = terminal_dof_weight
		# Input may already reach the new terminal while frozen pieces are
		# still on screen, including dust that outlives the live handoff.
		if session_transition_active and (tab_fx_wall != null or not tab_fx_stale.is_empty()):
			terminal_effects.blur_weight = 0.0
		terminal_effects.screen_dof = ink_active and ink_dof != null
		terminal_effects.update_lens(
			cam,
			focus_world,
			terminal_lens_zoom,
			lens_depth,
			fx_typing if fx_typing > 0.001 else 0.0,
			lens_transition_optics_from,
			lens_progress,
		)
		_sync_terminal_defocus_tint()
		if ink_dof != null:
			ink_dof.set_lens(
				terminal_effects.focus_depth,
				terminal_effects.blur_radius if terminal_effects.screen_dof else 0.0,
				terminal_effects.depth_range,
				terminal_effects.blur_limit,
			)


func _sync_graphics_planes() -> void:
	if not _floating() or cam == null:
		return
	var sheet := _sheet_size()
	for key in _shown_windows():
		var pair: Dictionary = host.sessions.get(int(key.substr(1)), { })
		if pair.is_empty() or not pair.term.has_method("set_image_plane_material"):
			continue
		var material: ShaderMaterial = (
			pair.term.get_meta("graphics_plane_material")
			if pair \
					.term \
					.has_meta("graphics_plane_material")
			else null
		)
		if material == null:
			material = ShaderMaterial.new()
			material.shader = preload("res://scenes/graphics_plane.gdshader")
			pair.term.set_meta("graphics_plane_material", material)
		# Respawning a shell replaces its retained canvas items, not the node.
		var binding := [material.get_instance_id(), pair.term.get_shell_pid()]
		if pair.term.get_meta("graphics_plane_binding", []) != binding:
			pair.term.set_image_plane_material(material)
			pair.term.set_meta("graphics_plane_binding", binding)
			ViewportUpdates.request(pair.vp)
		var pane_scale: float = host.workspace_view.terminal_scale(key)
		var at: Vector2 = host.workspace_view.terminal_origin(key) + Vector2(pair.term.position) * pane_scale
		var projection := preload("res://scenes/GraphicsPlane.gd").projection(
			_effect_surface_frame(at / sheet).origin,
			uv_du * pane_scale / sheet.x,
			uv_dv * pane_scale / sheet.y,
			pair.term.size,
			cam.global_position,
			fx_cam_tilt,
			fx_plane_lift if fx_enabled else 0.0,
			fx_plane_lean_scale if fx_enabled else 1.0,
			fx_cam_zoom * gesture_zoom if fx_enabled else 1.0,
		)
		if RenderUpdates.uniform(material, "plane_projection", projection):
			# This material transforms cached images inside the terminal viewport.
			# Camera motion must redraw it even when no terminal frame has changed.
			ViewportUpdates.request(pair.vp)


func _step_terminal_dof(dt: float) -> void:
	var moving := fly_dur > 0.0 or tab_fx_t >= 0.0 or not tab_fx_stale.is_empty()
	var target := 0.0 if moving else 1.0
	if target != terminal_dof_target:
		terminal_dof_from = terminal_dof_weight
		terminal_dof_target = target
		terminal_dof_elapsed = 0.0
	terminal_dof_elapsed += dt
	var duration := 0.35 if moving else 0.25
	var t := clampf(terminal_dof_elapsed / duration, 0.0, 1.0)
	var weight := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
	terminal_dof_weight = lerpf(terminal_dof_from, target, weight)


static func transition_focus_depth(
	from_depth: float,
	target_depth: float,
	progress: float,
) -> float:
	# Quintic smoothstep has zero first/second derivatives at both endpoints.
	var t := clampf((progress - 0.5) * 2.0, 0.0, 1.0)
	var weight := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
	return lerpf(from_depth, target_depth, weight)


func _terminal_presentation_frame(point: Vector2) -> Variant:
	if tab_fx_wall != null or tab_fx_preparing:
		for layer in tab_fx_in + tab_fx_out:
			if layer.live_source != null and layer.live_source.get_ref() == term_vp and float(layer._material().get_shader_parameter("fly")) < 1.0:
				return layer.presentation_frame(point)
		return null
	var uv := (_terminal_sheet_origin() + point * _terminal_sheet_scale()) / _sheet_size()
	return _effect_surface_frame(uv)


func _effect_surface_frame(uv: Vector2) -> Transform3D:
	uv = _saddle_uv(uv)
	var right := uv_du.normalized()
	var up := -uv_dv.normalized()
	var normal := right.cross(up).normalized()
	# uv_origin describes the authored wall; the rendered terminal mesh is
	# lifted off it. Effects must start on that mesh, not behind its depth.
	var lift := Vector3.ZERO
	if active >= 0 and active < surfaces.size():
		lift = surfaces[active].global_basis.z * surfaces[active].surface_lift
	return Transform3D(Basis(right, up, normal), uv_origin + uv_du * uv.x + uv_dv * uv.y + lift)


func _saddle_uv(uv: Vector2, inverse := false) -> Vector2:
	if is_zero_approx(fx_curvature_deg) or fx_mat == null or _sheet_viewport() == null:
		return uv
	var size := _sheet_size()
	# A new tab's material has not received advance() yet. Read the same live
	# layout that the shader will receive later this frame, not a stale uniform.
	#
	# With floating windows the whole canvas is the page.
	var pane := Rect2(Vector2.ZERO, Vector2.ONE)
	if not _floating() and is_instance_valid(term):
		pane = Rect2(Vector2(term.position) / size, Vector2(term.size) / size)
	elif not _floating():
		var rect = fx_mat.get_shader_parameter("panel_rect")
		if rect is Vector4:
			pane = Rect2(rect.x, rect.y, rect.z, rect.w)
	if inverse:
		return preload("res://scenes/SheetMath.gd").saddle_unproject(
			uv,
			pane,
			size,
			fx_curvature_deg,
		)
	return preload("res://scenes/SheetMath.gd").saddle_project(uv, pane, size, fx_curvature_deg)


func _on_effect_typed(uv: Vector2) -> void:
	fx_camera.resume_projection()
	effect_control.pulse()
	fx_last_key = fx_time
	fx_cursor = uv
	if effect_control.allows("camera.shake"):
		fx_camera.typed(fx_shake_px, fx_shake_seconds)


func _fx_key(ev: InputEventKey) -> void:
	RenderUpdates.activity()
	## Follow the real cursor from Graffitty via `_read_cursor()` when tilting
	## the camera. Count keys only if the library cannot report the cursor.
	##
	## Counting can lose track of the cursor in two ways:
	##
	## - Enter reset the count to column 0. The real cursor lands after the
	##   shell prompt, measured here at 27% of the screen width.
	## - `fx_row` only grew. After one screenful, the vertical tilt stayed
	##   pinned at its limit.
	workspace_typed.emit()
	if not fx_enabled:
		return
	fx_camera.resume_projection()
	effect_control.pulse()
	fx_last_key = fx_time
	# Eligible input starts a non-repeating shake. The controller captures the
	# cursor anchor itself, once, as typing begins.
	if effect_control.allows("camera.shake"):
		fx_camera.typed(fx_shake_px, fx_shake_seconds)
	if ev.keycode == KEY_ENTER:
		fx_col = 0
		fx_row += 1
	elif ev.keycode == KEY_BACKSPACE:
		fx_col = maxi(fx_col - 1, 0)
	elif ev.unicode > 0:
		fx_col += 1
	if fx_cursor_live:
		terminal_effects.pulse(fx_cursor)
		return
	# Fallback only, for a stock godotty that exposes no cursor.
	var cols := maxf(float(CoreTerminalEffects.layout_size(term_vp).x) / fx_cell_px.x, 1.0)
	var rows := maxf(float(CoreTerminalEffects.layout_size(term_vp).y) / fx_cell_px.y, 1.0)
	if fx_col >= int(cols):
		fx_col = 0
		fx_row += 1
	fx_row = mini(fx_row, maxi(int(rows) - 1, 0))
	fx_cursor = Vector2(clampf(fx_col / cols, 0.0, 1.0), clampf(fx_row / rows, 0.0, 1.0))
	terminal_effects.pulse(fx_cursor)


func _sheet_basis() -> Array:
	var s: TerminalSurface3D = surfaces[active]
	var fwd := s.forward
	var up := s.up
	return [fwd.cross(up).normalized(), up, -fwd]


func _sheet_up() -> Vector3:
	return _sheet_basis()[1]


func _sheet_normal() -> Vector3:
	return _sheet_basis()[2]


func _sheet_point(uv: Vector2) -> Vector3:
	## UV on the terminal sheet -> a world point on the wall, so particles and
	## splashes originate where the cursor actually is.
	var s: TerminalSurface3D = surfaces[active]
	var b := _sheet_basis()
	var canvas: Vector2 = s.canvas
	return focus_points[s.id] \
			+ b[0] * (uv.x - 0.5) * canvas.x \
			+ b[1] * (0.5 - uv.y) * canvas.y


func _turn(a: Vector3, b: Vector3, t: float) -> Vector3:
	var cosine := clampf(a.dot(b), -1.0, 1.0)
	if cosine > 0.999:
		return a.lerp(b, t).normalized()
	var angle := acos(cosine)
	var tangent := b - a * cosine
	if tangent.length() < 1e-5:
		tangent = a.cross(Vector3.UP)
	if tangent.length() < 1e-5:
		tangent = a.cross(Vector3.RIGHT)
	return (a * cos(angle * t) + tangent.normalized() * sin(angle * t)).normalized()


func _apply_pose(eye: Vector3, forward: Vector3, up: Vector3, half_x: float) -> void:
	## The flight's pose is the BASE. Effects are an offset from it, recomputed
	## every frame, so they can never accumulate.
	pose_eye = eye
	pose_forward = forward
	pose_up = up
	pose_half_x = half_x
	_apply_camera_fx()


func _wall_distance() -> float:
	## The mean depth of the wall's own geometry, which
	## is what the focus point is built from. Mixed across a flight, as
	## background.inc mixes flightFromDistance into it on the same quintic.
	if active < 0 or surfaces.is_empty():
		return 1.0
	var s: TerminalSurface3D = surfaces[active]
	var d: float = maxf(s.eye.distance_to(focus_points[s.id]), 0.1)
	if fly_dur > 0.0:
		var t := fly_t
		var e := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
		d = lerpf(fly_from_distance, d, e)
	return d


func _floating() -> bool:
	return host != null and host.workspace_view != null


## The viewport painted on the sheet: the terminal itself, or with floating
## windows the workspace canvas holding every window of the active tab.
func _sheet_viewport() -> SubViewport:
	return host.workspace_view.canvas if _floating() else term_vp


func _sheet_size() -> Vector2:
	var viewport := _sheet_viewport()
	return Vector2(CoreTerminalEffects.layout_size(viewport)).max(Vector2.ONE) if viewport != null else Vector2.ONE


## The focused terminal viewport's origin on the sheet, in sheet pixels.
func _terminal_sheet_origin() -> Vector2:
	if not _floating() or host.active_session_id < 0:
		return Vector2.ZERO
	return host.workspace_view.terminal_origin("%%%d" % host.active_session_id)


func _terminal_sheet_scale() -> float:
	return host.workspace_view.terminal_scale("%%%d" % host.active_session_id) if _floating() else 1.0


## Follow the pane frame, not just the terminal texture below its title.
func _update_camera_follow_bounds() -> void:
	fx_camera.follow_rect = Rect2()
	fx_camera.follow_top_inset = 0.0
	fx_camera.visible_rect = Rect2()
	if _floating(): fx_camera.visible_rect = host.workspace_view.workspace_region().in_projection(_sheet_size())
	if not _floating() or host.active_session_id < 0: return
	var view: Control = host.workspace_view
	var key := "%%%d" % host.active_session_id
	if not view.panes.has(key): return
	fx_camera.follow_pane(key)
	var pane: Control = view.panes[key]
	fx_camera.follow_rect = pane.get_transform() * Rect2(Vector2.ZERO, pane.size)
	# Small breathing room also covers the Flat surface's projection lift.
	fx_camera.follow_top_inset = 4.0


## Compose typing effects in pixels of the user's current view. This keeps the
## zoom multiplier and follow thresholds independent of manual zoom/pan.
func _advance_navigation_camera(dt: float, destination: Dictionary, typing: bool, ramp: float) -> void:
	var enabled: bool = _floating() and host.workspace_view.uses_navigation_camera() and fx_enabled
	if not enabled:
		navigation_camera_active = false
		return
	if navigation_camera == null:
		navigation_camera = TerminalCameraControllerScript.new()
		add_child(navigation_camera)
	var sheet := _sheet_size()
	if not navigation_camera_active: navigation_camera.reset(sheet)
	navigation_camera_active = true
	navigation_camera.unbounded_pan = true
	navigation_camera.configure(fx_cfg.scene.camera)
	var view: Control = host.workspace_view
	var scale: float = maxf(view.navigation_zoom, 0.01)
	var origin: Vector2 = view.navigation_center
	var bounds := fx_camera.follow_rect
	navigation_camera.follow_rect = Rect2((bounds.position - origin) * scale + sheet * .5, bounds.size * scale)
	navigation_camera.follow_top_inset = fx_camera.follow_top_inset
	navigation_camera.visible_rect = view.workspace_region().in_projection(sheet)
	var cursor := (_camera_cursor_center() - origin) * scale + sheet * .5
	var rest_zoom := maxf(float(fx_cfg.frame(str(fx_cfg.behavior.rest_state))["camera.zoom"]), .01)
	_prepare_adaptive_camera(navigation_camera, scale, origin)
	navigation_camera.advance(dt, cursor, sheet, fx_cell_px * scale,
		float(destination["camera.zoom"]) / rest_zoom, deg_to_rad(float(destination["camera.tilt_limit_deg"])),
		float(destination["camera.drift_px"]), float(destination["camera.drift_speed"]),
		typing, maxf(ramp, .001), typing or (OS.has_feature("mobile") and DisplayServer.virtual_keyboard_get_height() > 0))


## Presentation adapter only: Rust owns fitting; the tracker owns content bounds.
func _prepare_adaptive_camera(controller: Node, navigation_scale := 1.0, navigation_origin := Vector2.ZERO) -> void:
	controller.configure(fx_cfg.scene.camera)
	controller.adaptive_enabled = fx_enabled and fx_cfg.scene.camera.zoom_mode == "adaptive" and effect_control.allows("camera.zoom")
	controller.adaptive_target = Vector3.ZERO
	_adaptive_content_rect = Rect2()
	if not controller.adaptive_enabled: return
	var content := _adaptive_main_rect() if fx_cfg.scene.camera.adaptive_group.main_view else Rect2()
	var cell := Vector2.ZERO
	var pane_scale := 1.0
	if not content.has_area():
		if term == null: return
		var observed: Dictionary = term.get_visible_area()
		if not observed.has("framing"): return
		var owner := [term.get_instance_id(), observed.get("grid", Vector2i.ZERO)]
		if owner != _adaptive_settle_owner:
			_adaptive_settle_owner = owner
			_adaptive_settle = {}
		_adaptive_settle = CameraMotionScript._core().settle_framing(_adaptive_settle, Rect2i(observed.framing), Time.get_ticks_msec())
		var cells := Rect2(_adaptive_settle.get("accepted", Rect2i(observed.framing)))
		cell = observed.cell_size
		pane_scale = _terminal_sheet_scale()
		content = Rect2(_terminal_sheet_origin() + (Vector2(term.position) + Vector2(observed.grid_origin) + cells.position * cell) * pane_scale, cells.size * cell * pane_scale)
	# Main is a base frame, not an exclusive mode: selected relations can
	# enlarge it (e.g. an attached filetree stashed outside the tiled area).
	content = _group_adaptive_content(content, cell * pane_scale)
	_adaptive_content_rect = content
	if controller == navigation_camera:
		content = Rect2((content.position - navigation_origin) * navigation_scale + _sheet_size() * .5, content.size * navigation_scale)
	var fit: Vector3 = CameraMotionScript._core().adaptive_fit(_sheet_size(), controller.visible_rect, content, cell * pane_scale * navigation_scale, 3.0 / maxf(pane_scale * navigation_scale, .001))
	controller.adaptive_target = fit


## Only tiled Main panes use the whole Main area. Stashed/free/graph panes
## continue to frame their own content and selected relations.
##
## Typing pane zoom draws a full-width or full-height tile past Main's edges;
## the frame includes that drawn footprint, not just the layout area.
func _adaptive_main_rect() -> Rect2:
	if not _floating() or host.active_session_id < 0: return Rect2()
	var key := "%%%d" % host.active_session_id
	var layout = host.workspace_layout
	var tree: Dictionary = layout.tab(layout.containing(key)).get("tree", {})
	var main_keys := WorkspaceLayoutScript.main_keys(tree)
	if not tree.get("tiling", false) or key not in main_keys: return Rect2()
	var view: Control = host.workspace_view
	var main: Rect2 = view.content_rect()
	for main_key in main_keys:
		var drawn: Rect2 = view.typing_zoom_rect(main_key)
		if drawn.has_area(): main = main.merge(drawn)
	return main


## Include nearby related panes when framing the focused terminal.
##
## `content` contains the terminal's occupied cells. The fit adds two
## columns and four rows of padding. Use that padding for the gap test.
##
## Consider the nearest companions first. A companion joins if the gap
## to the current frame uses at most the share allowed for its relation.
func _group_adaptive_content(content: Rect2, cell: Vector2) -> Rect2:
	var companions := _adaptive_companions()
	if companions.is_empty(): return content
	var core := CameraMotionScript._core()
	var padded := content.grow_individual(cell.x * 2.0, cell.y * 4.0, cell.x * 2.0, cell.y * 4.0)
	companions.sort_custom(func(a, b): return core.gap_fraction(padded, a.rect) < core.gap_fraction(padded, b.rect))
	var frame := padded
	for companion in companions:
		var grouped: Rect2 = core.group_fit(frame, companion.rect, float(companion.max_gap))
		if grouped.has_area(): frame = grouped
	if frame == padded: return content
	return frame.grow_individual(-cell.x * 2.0, -cell.y * 4.0, -cell.x * 2.0, -cell.y * 4.0)


## Shown panes related to the selected base group, as {rect (sheet pixels),
## max_gap}.
##
## Main grouping uses all its tiled panes as relation seeds, so switching
## focus within Main does not drop another tiled pane's external filetree.
##
## Per `camera.adaptive_group`: a pane's filetree or the pane a focused
## filetree belongs to, chromium viewers it opened, panes it started with `gft
## run` (or its parent), and live agent-graph neighbours.
func _adaptive_companions() -> Array:
	if not _floating() or host.active_session_id < 0: return []
	var limits: Dictionary = fx_cfg.scene.camera.adaptive_group
	var view: Control = host.workspace_view
	var key := "%%%d" % host.active_session_id
	var seeds: Array[String] = [key]
	if limits.main_view and _adaptive_main_rect().has_area():
		var layout = host.workspace_layout
		seeds = WorkspaceLayoutScript.main_keys(layout.tab(layout.containing(key)).get("tree", {}))
	var related: Dictionary = {}
	var relate := func(other: String, relation: String) -> void:
		var limit = limits.get(relation, false)
		if other in seeds or limit is bool and not limit: return
		var max_gap := 1.0 if limit is bool else float(limit)
		related[other] = maxf(float(related.get(other, 0.0)), max_gap)
	for id in host.sessions:
		var other := "%%%d" % id
		var term_node: Node = host.sessions[id].term
		var filetree_owner: int = term_node.get_meta("filetree_owner", -1)
		if "%%%d" % filetree_owner in seeds: relate.call(other, "filetree")
		if other in seeds and filetree_owner >= 0: relate.call("%%%d" % filetree_owner, "filetree")
		var parent: int = term_node.get_meta("spawned_by", -1)
		if "%%%d" % parent in seeds: relate.call(other, "spawned")
		if other in seeds and parent >= 0: relate.call("%%%d" % parent, "spawned")
	for id in host.chromiums:
		if "%%%d" % host.chromiums[id].owner_id in seeds: relate.call("%%%d" % id, "chromium")
	if host.agent_api != null and not (limits.get("graph", false) is bool and not limits.get("graph", false)):
		var graph = host.agent_api.graph
		for edge in graph.edges.values():
			if edge.get("muted", false) or graph.connection_expired(edge): continue
			var from := str(edge.get("from", ""))
			var to := str(edge.get("to", ""))
			if from in seeds: relate.call(to, "graph")
			if to in seeds: relate.call(from, "graph")
	var result := []
	for other in related:
		if not view.pane_rects.has(other): continue
		var rect: Rect2 = view.pane_rects[other]
		if rect.has_area(): result.append({"rect": rect, "max_gap": related[other]})
	return result


func _navigation_camera_zoom() -> float:
	var view: Control = host.workspace_view
	if not navigation_camera_active or not fx_enabled: return view.navigation_zoom
	var zoom := navigation_camera.target_zoom if _adaptive_framing_enabled() else navigation_camera.zoom
	return view.navigation_zoom * zoom


func _navigation_camera_center() -> Vector2:
	var view: Control = host.workspace_view
	var offset := Vector2.ZERO
	if navigation_camera_active and fx_enabled:
		var pan := navigation_camera.framing_pan if _adaptive_framing_enabled() else navigation_camera.render_pan
		offset = (pan - _sheet_size() * .5) / maxf(view.navigation_zoom, .01)
	return view.navigation_center + offset


func _camera_cursor_center() -> Vector2:
	# Terminal/IME anchors are bottom-left, whereas camera cell bounds are
	# symmetric around a center. Convert once before any camera follows it.
	var sheet := _sheet_size()
	var center := _camera_cursor_uv() * sheet + Vector2(fx_cell_px.x, -fx_cell_px.y) * .5
	return _saddle_uv(center / sheet) * sheet

func _camera_cursor_uv() -> Vector2:
	if term != null and term_vp != null and term.has_method("get_cursor_anchor_local"):
		return (
			_terminal_sheet_origin() + (Vector2(term.position)
			+ Vector2(term.call("get_cursor_anchor_local"))) * _terminal_sheet_scale()
		) / _sheet_size()
	return (
		terminal_effects.to_sheet_uv(fx_cursor)
		if terminal_effects != null
		else Vector2(0.5, 0.5)
	)


func _camera_base_frame(eye: Vector3, forward: Vector3, up: Vector3, half_x: float) -> Dictionary:
	if _floating() and uv_du != Vector3.ZERO and uv_dv != Vector3.ZERO:
		# At rest, the frame acts as the page that holds the windows. The authored
		# camera sees an image plane parallel to the wall. Shifting the lens onto
		# that page draws the frame as the rectangle used for layout.
		var face := uv_du.cross(uv_dv).normalized()
		if face.dot(forward) < 0.0:
			face = -face
		var wall_up := -uv_dv.normalized()
		var right := face.cross(wall_up).normalized()
		var depth := (uv_origin - eye).dot(face)
		if depth > 0.0001:
			var width := uv_du.length() / depth
			var sheet_height := uv_dv.length() / depth
			# Camera3D derives vertical extent from its viewport aspect. The sheet
			# may exclude chrome, so retain its center but use the rendered extent
			# for input projection and screen-space sockets as well.
			var height := width / _frame_aspect()
			var top := (uv_origin - eye).dot(wall_up) / depth
			return CameraMotionScript.pose(
				eye,
				face,
				wall_up,
				Vector4((uv_origin - eye).dot(right) / depth, top - sheet_height * .5 - height * .5, width, height),
			)
	var aspect := _frame_aspect()
	var width := 2.0 * half_x * minf(1.0, aspect / _canvas_aspect()) * CANVAS_COVER_MARGIN
	var height := width / maxf(aspect, 0.05)
	return CameraMotionScript.pose(
		eye,
		forward,
		up,
		Vector4(-width * .5, -height * .5, width, height),
	)


func _display_camera_frame(value: Dictionary) -> void:
	if not cam.global_transform.is_equal_approx(value.transform) or not proj_rect.is_equal_approx(value.rect):
		_scenery_dirty = true
	CameraMotionScript.apply(cam, value)
	proj_eye = value.transform.origin
	proj_forward = -value.transform.basis.z
	proj_right = value.transform.basis.x
	proj_up = value.transform.basis.y
	proj_rect = value.rect
	_notify_workspace_projection_changed()


func _workspace_projection_frame() -> Array:
	return [proj_eye, proj_forward, proj_right, proj_up, proj_rect]


## Compare only the projection inputs already owned by the animation loop.
## Stationary worlds must not reproject every pane or rebuild graph sockets.
func _notify_workspace_projection_changed() -> void:
	if not _floating():
		return
	var view: Control = host.workspace_view
	var next := _workspace_projection_frame() + [
		uv_origin, uv_du, uv_dv, fx_curvature_deg, _sheet_size(),
		fx_cam_zoom * gesture_zoom, fly_dur > 0.0, tab_fx_t >= 0.0,
		pose_eye, pose_forward, pose_up, pose_half_x,
		view.overview, view.navigation_center, view.navigation_zoom,
	]
	if next.size() == _workspace_projection.size():
		var same := true
		for i in next.size():
			var value: Variant = next[i]
			var previous: Variant = _workspace_projection[i]
			if value is float:
				same = is_equal_approx(value, previous)
			elif value is Vector2 or value is Vector3 or value is Vector4 or value is Transform2D:
				same = value.is_equal_approx(previous)
			else:
				same = value == previous
			if not same: break
		if same: return
	_workspace_projection = next
	workspace_projection_changed.emit()


func _apply_camera_fx(cursor_uv := Vector2.INF) -> void:
	if cam == null:
		return
	# Binding the next session may reset its camera before the flight is ready.
	# Keep displaying the departure through every intervening rendered frame.
	if not session_transition_capture.is_empty():
		_display_camera_frame(session_transition_capture.camera)
		return
	if camera_motion.moving:
		_display_camera_frame(_flight_frame())
		return
	_display_camera_frame(
		_camera_fx_frame(
			_camera_base_frame(pose_eye, pose_forward, pose_up, pose_half_x),
			cursor_uv,
		)
	)


## The flight already targets the complete destination framing. Applying zoom
## again here would cause a second landing and corrupt interrupted flights.
func _flight_frame() -> Dictionary:
	return camera_motion.frame


## Fit the retained Main area without moving the authored camera eye.
func _navigation_frame(value: Dictionary, zoom: float, center: Vector2, tilt := Vector2.ZERO) -> Dictionary:
	# Adjust the lens to fit the owner's page in this client window.
	# Keep the camera at the authored eye until inspection or typing moves it.
	# Moving it just to fit the page can shift nearby landmarks to the other side.
	var main: Dictionary = host.workspace_view.main_frame()
	var sheet := _sheet_size()
	var main_zoom: float = maxf(main.zoom, .01)
	var main_uv: Vector2 = main.center / sheet
	var rect: Vector4 = value.rect
	var fitted := CameraMotionScript.pose(
		value.transform.origin, -value.transform.basis.z, value.transform.basis.y,
		Vector4(rect.x + rect.z * (main_uv.x - .5 / main_zoom),
			rect.y + rect.w * (1.0 - main_uv.y - .5 / main_zoom),
			rect.z / main_zoom, rect.w / main_zoom),
	)
	return CameraMotionScript.frame_sheet(fitted, zoom / main_zoom,
		(center - Vector2(main.center)) / sheet * 2.0, tilt,
		uv_origin + uv_du * main_uv.x + uv_dv * main_uv.y, uv_du, uv_dv)


## A resting frame with the typing camera's zoom, pan and lean applied.
func _camera_fx_frame(value: Dictionary, cursor_uv := Vector2.INF) -> Dictionary:
	var candidate := _unfitted_camera_fx_frame(value, cursor_uv)
	var fitted := _contain_adaptive_camera_frame(value, cursor_uv, candidate) if _adaptive_containment_active() else candidate
	if not _adaptive_framing_enabled(): return candidate
	# Interpolate the complete destination relative to manual navigation, never
	# relative to an independently easing typing camera. Moving that baseline
	# made the two filters chase each other and reverse after typing stopped.
	var reference := value
	if _floating() and host.workspace_view.uses_navigation_camera():
		var view: Control = host.workspace_view
		reference = _navigation_frame(value, view.navigation_zoom, view.navigation_center)
	return fx_camera.project(reference, fitted, uv_origin + (uv_du + uv_dv) * .5)


func _contain_adaptive_camera_frame(value: Dictionary, cursor_uv: Vector2, candidate: Dictionary) -> Dictionary:
	var points := PackedVector3Array()
	# Sample the surface, not just corners: saddle extrema can lie on edges.
	for y in 9:
		for x in 9:
			var point := _adaptive_content_rect.position + _adaptive_content_rect.size * Vector2(x / 8.0, y / 8.0)
			points.append(_effect_surface_frame(point / _sheet_size()).origin)
	var visible := _adaptive_visible_fraction()
	var core := CameraMotionScript._core()
	var fitted: Dictionary = core.contain_projected(candidate, points, visible, cam.near)
	if fitted.rect.z <= candidate.rect.z * 1.00001: return fitted
	# Preserve magnification by reducing automatic tilt first. Search for the
	# largest combined tilt that fits; all other geometry remains live.
	var flat := _unfitted_camera_fx_frame(value, cursor_uv, 0.0)
	var safe: Dictionary = core.contain_projected(flat, points, visible, cam.near)
	if safe.rect.z > flat.rect.z * 1.00001: return safe
	var low := 0.0
	var high := 1.0
	for iteration in 8:
		var weight := (low + high) * .5
		var trial := _unfitted_camera_fx_frame(value, cursor_uv, weight)
		var adjusted: Dictionary = core.contain_projected(trial, points, visible, cam.near)
		if adjusted.rect.z <= trial.rect.z * 1.00001:
			low = weight
			safe = adjusted
		else:
			high = weight
	return safe

func _adaptive_framing_enabled() -> bool:
	# Gates stop new fitting destinations, not the displayed projection filter.
	# Settling/holding zoom must ease its existing correction back to rest.
	return fx_enabled and fx_cfg.scene.camera.zoom_mode == "adaptive"

## Preserve the current fitted correction while the user moves its reference.
## Fresh typing resumes fitting; output and idle transitions do not.
func interrupt_adaptive_camera() -> bool:
	if fx_cfg == null or not _adaptive_framing_enabled(): return false
	fx_camera.interrupt_projection()
	return true

func _adaptive_containment_active() -> bool:
	var controller := navigation_camera if navigation_camera_active else fx_camera
	return _adaptive_framing_enabled() and controller.was_typing and _adaptive_content_rect.has_area()

func _adaptive_visible_fraction() -> Rect2:
	var sheet := _sheet_size()
	var visible := fx_camera.visible_rect
	if not visible.has_area(): return Rect2(0, 0, 1, 1)
	return Rect2(visible.position / sheet, visible.size / sheet)

func _unfitted_camera_fx_frame(value: Dictionary, cursor_uv := Vector2.INF, tilt_weight := 1.0) -> Dictionary:
	var center := uv_origin + (uv_du + uv_dv) * .5
	if cursor_uv == Vector2.INF:
		cursor_uv = _camera_cursor_uv()
	if _floating() and host.workspace_view.uses_navigation_camera():
		return _navigation_frame(
			value,
			_navigation_camera_zoom(),
			_navigation_camera_center(),
			(navigation_camera.framing_tilt if _adaptive_framing_enabled() else navigation_camera.tilt) * tilt_weight if navigation_camera_active and fx_enabled else Vector2.ZERO,
		)
	if not fx_enabled:
		return value
	var zoom := fx_camera.target_zoom if _adaptive_framing_enabled() else fx_cam_zoom
	var pan := (fx_camera.framing_pan / _sheet_size() - Vector2.ONE * .5) * 2.0 if _adaptive_framing_enabled() else fx_cam_pan
	var tilt := fx_camera.framing_tilt if _adaptive_framing_enabled() else fx_cam_tilt
	if _floating():
		return CameraMotionScript.frame_sheet(
			value,
			zoom * gesture_zoom,
			pan,
			tilt * tilt_weight,
			center,
			uv_du,
			uv_dv,
		)
	return CameraMotionScript.compose(
		value,
		zoom * gesture_zoom,
		pan,
		tilt * tilt_weight,
		center,
		uv_du,
		uv_dv,
		_effect_surface_frame(cursor_uv).origin,
		cam.near,
		fly_dur <= 0 and tab_fx_t < 0 and terminal_effects != null
		and not fx_camera.adaptive_enabled
		and (fx_cam_zoom * gesture_zoom > 1.001 or fx_typing > .01),
	)


## The typing camera at rest on the terminal just arrived at, as it stands
## once a flight lands: the resting state's zoom, which a pinch edits, framed
## on the cursor.
##
## A flight aimed at an unzoomed wall would end in a cut to this.
func _settle_camera_at_rest() -> void:
	navigation_camera_active = false
	var sheet := _sheet_size()
	fx_camera.reset(sheet)
	_update_camera_follow_bounds()
	if fx_enabled:
		fx_camera.zoom = maxf(
			float(fx_cfg.frame(String(fx_cfg.behavior["rest_state"]))["camera.zoom"]),
			0.25,
		)
		fx_camera.target_zoom = fx_camera.zoom
		var cursor := _camera_cursor_center()
		fx_camera.pan = fx_camera._follow_target(cursor, sheet, fx_camera.zoom, false, fx_cell_px)
		fx_camera.render_pan = fx_camera.pan
		fx_camera.framing_pan = fx_camera.pan
		fx_camera.animated_cursor = cursor
		fx_camera.cursor_initialized = true
	fx_cam_zoom = fx_camera.zoom
	fx_cam_pan = (fx_camera.render_pan / sheet - Vector2(0.5, 0.5)) * 2.0 if fx_enabled else Vector2.ZERO
	fx_cam_tilt = Vector2.ZERO


## The fingers edit the current state's zoom one to one, with no easing, and
## without firing typing or its quiet timer.
## factor is InputEventMagnifyGesture.factor, 1 + the macOS magnification.
func pinch_zoom(factor: float) -> void:
	if not fx_enabled or fx_cfg == null or factor <= 0.1 or factor > 10.0:
		return
	var typing := (fx_time - fx_last_key) < fx_idle_after and not camera_motion.moving and effect_control.camera_active()
	var state := String(fx_cfg.behavior["active_state" if typing else "rest_state"])
	var zoom := clampf(
		float(fx_cfg.frame(state)["camera.zoom"]) * factor,
		PINCH_MIN_ZOOM,
		PINCH_MAX_ZOOM,
	)
	fx_cfg.set_option("state." + state, "camera.zoom", zoom)
	fx_camera.target_zoom = zoom
	fx_camera.zoom = zoom
	fx_cam_zoom = zoom
	_apply_camera_fx()


var dbg_keys_seen := 0


func _input(ev: InputEvent) -> void:
	if host != null and not host.is_terminal_pane(host.pane_focus):
		if ev is InputEventKey and ev.pressed:
			_terminal_tab_shortcut(ev)
		return
	if ev is InputEventMagnifyGesture:
		if _floating() and not host.workspace_view.workspace_region().in_projection(_window_render_size()).has_point(ev.position):
			return
		pinch_zoom(ev.factor)
		get_viewport().set_input_as_handled()
		return
	# Window shortcuts run before the focused terminal can consume them.
	if ev is InputEventKey and ev.pressed and _terminal_tab_shortcut(ev):
		get_viewport().set_input_as_handled()


func _unhandled_input(ev: InputEvent) -> void:
	if host != null and host.workspace_view != null:
		return
	if host != null and not host.is_terminal_pane(host.pane_focus):
		return # Chromium input must never reach a hidden PTY.
	if ev is InputEventKey and ev.pressed:
		dbg_keys_seen += 1
	if ev is InputEventKey and ev.pressed and _terminal_tab_shortcut(ev):
		get_viewport().set_input_as_handled()
		return
	if ev is InputEventKey and ev.pressed and ev.ctrl_pressed and ev.keycode == KEY_TAB:
		var step := -1 if ev.shift_pressed else 1
		if host != null:
			host.select_next_workspace(step)
		else:
			_goto(wrapi(active + step, 0, surfaces.size()), false)
		get_viewport().set_input_as_handled()
		return
	if (
		ev is InputEventKey and ev.pressed
		and term != null and not term.has_signal("keystroke")
	):
		_fx_key(ev)
	if (
		term_vp != null
		and (
			ev is InputEventKey or ev is InputEventMouseButton
			or ev is InputEventPanGesture or ev is InputEventMouseMotion
		)
	):
		var forwarded := ev.duplicate() as InputEvent
		if ev is InputEventMouse or ev is InputEventGesture:
			forwarded.position = _window_to_terminal(ev.position)
		term_vp.push_input(forwarded, true)
		get_viewport().set_input_as_handled()


func _window_to_terminal(point: Vector2) -> Vector2:
	var hit := sheet_point_at(point / get_viewport().get_visible_rect().size)
	return hit if hit.is_finite() else term.position + term.size * 0.5


## Sheet pixels under a fraction of the frame. This inverts the off-axis
## camera actually drawn, not Camera3D's aspect getter.
##
## Points off the sheet extend its plane; a ray parallel to it has no answer
## (INF).
func sheet_point_at(fraction: Vector2) -> Vector2:
	var ray := proj_forward + proj_right * (proj_rect.x + fraction.x * proj_rect.z) \
			+ proj_up * (proj_rect.y + (1.0 - fraction.y) * proj_rect.w)
	var normal := uv_du.cross(uv_dv).normalized()
	var denom := ray.dot(normal)
	if normal == Vector3.ZERO or absf(denom) < 0.00001:
		return Vector2.INF
	var hit := proj_eye + ray * ((uv_origin - proj_eye).dot(normal) / denom) - uv_origin
	var uv := Basis(uv_du, uv_dv, normal).inverse() * hit
	return _saddle_uv(Vector2(uv.x, uv.y), true) * _sheet_size()


## Title compensation follows deliberate navigation, never the typing camera.
func title_navigation_scale(point: Vector2) -> float:
	# pose_* remains the departure pose until the flight finishes. The pane
	# already belongs to the destination, including its captured arrival title.
	var value := _camera_base_frame(pose_eye, pose_forward, pose_up, pose_half_x)
	if active >= 0 and active < surfaces.size():
		var surface: TerminalSurface3D = surfaces[active]
		value = _camera_base_frame(surface.eye, surface.forward, surface.up, surface.half_x)
	var view: Control = host.workspace_view
	if view.uses_navigation_camera():
		value = _navigation_frame(value, view.navigation_zoom, view.navigation_center)
	var projected: Array[Vector2] = []
	for offset in [Vector2.ZERO, Vector2(0, 20)]:
		var uv := _saddle_uv((point + offset) / _sheet_size())
		var delta: Vector3 = uv_origin + uv_du * uv.x + uv_dv * uv.y - value.transform.origin
		var depth: float = delta.dot(-value.transform.basis.z)
		if depth <= .0001: return 1.0
		projected.append(Vector2(delta.dot(value.transform.basis.x) / depth / value.rect.z,
			-delta.dot(value.transform.basis.y) / depth / value.rect.w) * view.size)
	return 20.0 / maxf(projected[0].distance_to(projected[1]), .01)


## Where a sheet point is drawn, as a fraction of the frame; INF behind the eye.
func sheet_window_fraction(point: Vector2) -> Vector2:
	var uv := _saddle_uv(point / _sheet_size())
	var delta := uv_origin + uv_du * uv.x + uv_dv * uv.y - proj_eye
	var depth := delta.dot(proj_forward)
	if depth <= 1e-4:
		return Vector2.INF
	return Vector2(
		(delta.dot(proj_right) / depth - proj_rect.x) / maxf(proj_rect.z, 1e-6),
		1.0 - (delta.dot(proj_up) / depth - proj_rect.y) / maxf(proj_rect.w, 1e-6),
	)


func _terminal_tab_shortcut(ev: InputEventKey) -> bool:
	if not ev.meta_pressed or ev.ctrl_pressed or ev.alt_pressed or ev.shift_pressed:
		return false
	var key := ev.keycode if ev.keycode != KEY_NONE else ev.physical_keycode
	if key < KEY_1 or key > KEY_9:
		return false
	# Reserve missing tabs too, so the shortcut never types into the shell.
	if not ev.echo:
		# Cmd+9 always selects the last tab, as in chromiums.
		if host != null:
			var definitions: Array = host.get_tabs(true)
			var index := definitions.size() - 1 if key == KEY_9 else int(key - KEY_1)
			if index >= 0 and index < definitions.size():
				host.select_workspace(int(definitions[index].id))
		else:
			var index := surfaces.size() - 1 if key == KEY_9 else int(key - KEY_1)
			if index >= 0 and index < surfaces.size():
				_goto(index, false)
	return true


func _on_terminal_shortcut(action: String) -> void:
	if term == null or not term.has_focus():
		return
	var current := int(term.get_meta("pane_font_size", term_font_size)) if host != null and host.workspace_view != null else term_font_size
	match action:
		"increase_font_size":
			_set_terminal_font_size(preload("res://scenes/TerminalFontSizing.gd").step(current, true))
		"decrease_font_size":
			_set_terminal_font_size(preload("res://scenes/TerminalFontSizing.gd").step(current, false))
		"reset_font_size":
			var default_size: int = host.session_backend.connection.font_default(host.active_session_id) if host != null and host.session_backend.is_remote else term_font_size_default
			_set_terminal_font_size(default_size)


func _set_terminal_font_size(size: int) -> void:
	if host != null and host.workspace_view != null:
		if term == null: return
		var requested := clampi(size, 1, 72)
		term.set_meta("pane_font_size", requested)
		if not host.session_backend.is_remote:
			term.set_live_font_size(requested)
		if host.session_backend.is_remote:
			host.session_backend.connection.send_action("font_size", host.active_session_id, {"size": requested})
		host.application.remember_font_size(requested)
		host.workspace_view.refresh()
		return
	# Store the requested size in reference-layout pixels. The live terminal gets
	# the viewport-scaled value, so Cmd +/- behaves consistently after a resize.
	var scale := maxf(_terminal_font_scale(), 0.001)
	# Clamp stored intent to the *renderable* range, so reverse immediately works.
	term_font_size = preload("res://scenes/TerminalFontSizing.gd").clamp_requested(size, scale, host != null and host.workspace_view != null)
	_apply_terminal_font_scale(_terminal_font_scale())

# --- capture ----------------------------------------------------------------


func _flight_shots() -> void:
	## Start at flight_pair[0], fly to flight_pair[1], capture mid-flight frames.
	DirAccess.make_dir_recursive_absolute(shot_dir)
	_goto(flight_pair[0], true)
	await get_tree().create_timer(2.5).timeout
	_goto(flight_pair[1], false)
	var shot_at := [0.2, 0.4, 0.6, 0.8]
	var last := 0.0
	for frac in shot_at:
		await get_tree().create_timer(FLY_TIME * (frac - last)).timeout
		last = frac
		await _shot("t%02d" % int(frac * 100))
	print("FLIGHT_DONE")
	get_tree().quit()


func _bench() -> void:
	# A benchmark that stops at the display's refresh rate measures the display.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for i in 30:
		await RenderingServer.frame_post_draw # warm up
	var t0 := Time.get_ticks_usec()
	for i in bench_frames:
		await RenderingServer.frame_post_draw
	var dt := (Time.get_ticks_usec() - t0) / 1000000.0
	print(
		"BENCH %d frames in %.3fs = %.2f fps (%.2f ms/frame) sky=%s"
		% [bench_frames, dt, bench_frames / dt, dt / bench_frames * 1000.0, world_mode]
	)
	get_tree().quit()


func _tour() -> void:
	DirAccess.make_dir_recursive_absolute(shot_dir)
	# --settle=SEC: how long to let the shell finish before measuring. A big
	# kitty graphics payload takes real time to cross the pty.
	var settle := 3.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--settle="):
			settle = float(arg.substr(9))
	await get_tree().create_timer(settle).timeout
	if OS.get_cmdline_user_args().has("--apitest"):
		print("=== Terminal properties ===")
		for pr in term.get_property_list():
			if pr["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE or pr["usage"] & PROPERTY_USAGE_DEFAULT:
				var nm := String(pr["name"])
				if (
					nm.to_lower().contains("curs") or nm.to_lower().contains("row")
					or nm.to_lower().contains("col")
					or nm.to_lower().contains("grid")
					or nm \
							.to_lower() \
							.contains("cell") or nm.to_lower().contains("size") or nm
					.to_lower()
					.contains("font")
				):
					print("  %s : %s" % [nm, type_string(pr["type"])])
		print("=== Terminal methods ===")
		for mt in term.get_method_list():
			var nm2 := String(mt["name"])
			if not nm2.begins_with("_"):
				print("  %s()" % nm2)
		print("TOUR_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--lagtest"):
		await _lag_test()
		return
	if OS.get_cmdline_user_args().has("--projtest"):
		## Use this projection comparison for diagnostics. Confirm actual framing
		## with `--layouttest` and rendered pixels.
		##
		## `Camera3D.get_camera_projection()` omits the renderer's `vaspect` flag.
		## It uses the height convention while `KEEP_WIDTH` uses width. Matching
		## its result made the camera a factor of `aspect` too tight.
		var half_x := pose_half_x
		var vp2 := get_viewport().get_visible_rect().size
		var aspect2: float = maxf(vp2.x, 1.0) / maxf(vp2.y, 1.0)
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = rad_to_deg(2.0 * atan(half_x))
		var a := cam.get_camera_projection()
		# hypothesis: size is the HEIGHT at the near plane, offsets likewise
		var w2 := 2.0 * half_x
		var h2 := w2 / aspect2
		var cx := 0.13 * half_x
		var cy := -0.07 * half_x
		cam.projection = Camera3D.PROJECTION_FRUSTUM
		cam.size = h2 * cam.near
		cam.frustum_offset = Vector2(cx * cam.near, cy * cam.near)
		var b := cam.get_camera_projection()
		print("[projtest] aspect=%.4f half_x=%.5f" % [aspect2, half_x])
		print(
			"  perspective m00=%.6f m11=%.6f  (want 1/half_x=%.6f, 1/(half_x/aspect)=%.6f)"
			% [a[0][0], a[1][1], 1.0 / half_x, aspect2 / half_x]
		)
		print(
			"  frustum     m00=%.6f m11=%.6f m02=%.6f m12=%.6f"
			% [b[0][0], b[1][1], b[2][0], b[2][1]]
		)
		print("  want        m02=%.6f m12=%.6f" % [cx / half_x, cy / (half_x / aspect2)])
		# does frustum_focal_length bleed into the field of view under
		# PROJECTION_FRUSTUM? If it does, calibrating DoF by focal length is
		# unusable, because changing blur would rescale the image.
		if fx_attr != null:
			for fl in [20.0, 120.0, 458.0]:
				fx_attr.frustum_focal_length = fl
				_apply_camera_fx()
				var m := cam.get_camera_projection()
				print(
					"  focal %5.0f mm -> m00=%.6f m11=%.6f fov=%.3f"
					% [fl, m[0][0], m[1][1], cam.fov]
				)
		print("TOUR_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--inputtest"):
		await _input_test()
		return
	if OS.get_cmdline_user_args().has("--fxdemo"):
		await _fx_demo()
		return
	if OS.get_cmdline_user_args().has("--alphatest"):
		await RenderingServer.frame_post_draw
		var ti := term_vp.get_texture().get_image()
		ti.save_png("%s/term_raw.png" % shot_dir)
		var hist := { }
		var n := 0
		for yy in range(0, ti.get_height(), 7):
			for xx in range(0, ti.get_width(), 7):
				var a := int(round(ti.get_pixel(xx, yy).a * 10.0))
				hist[a] = hist.get(a, 0) + 1
				n += 1
		print("ALPHA_HIST total=", n, " ", hist)
		print(
			"corner px: ",
			ti.get_pixel(5, 5),
			" mid: ",
			ti.get_pixel(ti.get_width() / 2, ti.get_height() - 30),
		)
		print("TOUR_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--imgtest"):
		## The shell's own clock says how fast the bytes crossed the pty; this says
		## when the picture is actually on the wall, which is the number a person
		## notices.
		##
		## Sampled repeatedly, because "it arrives eventually" and "it arrives at
		## once" look identical in a single screenshot.
		var t0 := Time.get_ticks_msec()
		for mark in [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]:
			while (Time.get_ticks_msec() - t0) / 1000.0 < mark:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var ti2 := term_vp.get_texture().get_image()
			var painted := 0
			var sampled := 0
			for yy in range(0, ti2.get_height(), 8):
				for xx in range(0, ti2.get_width(), 8):
					sampled += 1
					if ti2.get_pixel(xx, yy).a > 0.05:
						painted += 1
			var places: Array = []
			if term.has_method("image_placements"):
				places = term.call("image_placements")
			var first := ""
			if places.size() > 0:
				var pl: Dictionary = places[0]
				first = " first=%dx%d px at cell (%d,%d) over %dx%d cells" % [
					int(pl["pixel_width"]),
					int(pl["pixel_height"]),
					int(pl["col"]),
					int(pl["row"]),
					int(pl["cols"]),
					int(pl["rows"]),
				]
			print(
				"[imgtest] t=%.2fs placements=%d painted=%.1f%%%s"
				% [mark, places.size(), 100.0 * painted / maxf(sampled, 1), first]
			)
			ti2.save_png("%s/img_%0.2f.png" % [shot_dir, mark])
		print("TOUR_DONE")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--rendertest"):
		await _render_test()
		return
	if OS.get_cmdline_user_args().has("--tabfxtest"):
		await _tab_fx_test()
		return
	if OS.get_cmdline_user_args().has("--layertest"):
		await _layer_test()
		return
	if OS.get_cmdline_user_args().has("--shattertest"):
		await _shatter_test()
		return
	if OS.get_cmdline_user_args().has("--seltest"):
		await _selection_test()
		return
	if OS.get_cmdline_user_args().has("--signaltest"):
		await _signal_test()
		return
	if OS.get_cmdline_user_args().has("--layouttest"):
		await _layout_test()
		print("TOUR_DONE")
		get_tree().quit()
		return
	await _shot("00_arrive")
	for step in [3, 6, 9, 12]:
		_goto(step, false)
		await get_tree().create_timer(FLY_TIME * 0.45).timeout
		await _shot("%02d_midflight" % step)
		await get_tree().create_timer(FLY_TIME * 0.75).timeout
		await _shot("%02d_arrived" % step)
	print("TOUR_DONE")
	if not autoplay:
		get_tree().quit()


func _shatter_test() -> void:
	## The terminal's own texture, cut into one quad per inked cell, flown in and
	## assembled.
	##
	## Nothing here is new API: the grid size, the cell box, the texture and the
	## wall's uv->world map all already existed — which is the claim this test is
	## here to prove.
	await get_tree().create_timer(2.5).timeout
	var rect := _terminal_content_rect(CoreTerminalEffects.layout_size(term_vp))
	var cell: Vector2 = term.call("get_cell_size")
	var padding := float(term.get("cell_padding")) if term.get("cell_padding") != null else 4.0
	var grid_origin := rect.position + Vector2(padding, padding)

	# Images are their own layer: the terminal knows which cells they occupy, so
	# the text layer can skip them and the image can arrive on its own terms.
	var claimed: Array = []
	var regions: Array = []
	if term.has_method("image_placements"):
		for entry in term.call("image_placements"):
			var placement: Dictionary = entry
			claimed.append(
				Rect2i(
					int(placement["col"]),
					int(placement["row"]),
					int(placement["cols"]),
					int(placement["rows"]),
				)
			)
			regions.append(
				Rect2(
					grid_origin
					+ Vector2(float(placement["col"]) * cell.x, float(placement["row"]) * cell.y),
					Vector2(float(placement["pixel_width"]), float(placement["pixel_height"])),
				)
			)

	var pieces := CellShatterScript.new()
	add_child(pieces)
	# Text: many small pieces, scattered wide, gently turning.
	var cells: Array = []
	for cut in preload("res://scenes/RetainedViewport.gd").terminal_state(term).flight_cells():
		var at := Vector2i(cut.x, cut.y)
		if not claimed.any(func(region): return region.has_point(at)):
			cells.append(cut)
	var count: int = pieces.build_cells(
		term,
		term_vp,
		rect,
		uv_origin,
		uv_du,
		uv_dv,
		cells,
		Vector2(7.0, 5.0),
	)
	var images := CellShatterScript.new()
	add_child(images)
	# The image: one piece, from close in, tumbling, arriving last.
	var image_count: int = images.build_regions(
		term_vp,
		regions,
		rect,
		uv_origin,
		uv_du,
		uv_dv,
		Vector2(3.0, 12.0),
	)
	var grid: Vector2i = term.call("get_grid_size")
	print(
		"[shatter] %d text cells of %d x %d (%.1f%%), %d image placements"
		% [
			count,
			grid.x,
			grid.y,
			100.0 * float(count) / maxf(float(grid.x * grid.y), 1.0),
			image_count,
		]
	)
	if count == 0 and image_count == 0:
		print("SHATTER_DONE")
		get_tree().quit()
		return
	# Hide the source while its pieces fly. This demo hides the whole wall.
	#
	# For the full effect, mask only the flying cells in the sheet shader
	# so the rest of the terminal remains visible and usable.
	var wall: MeshInstance3D = walls[surfaces[active].id]
	wall.visible = false
	var marks := [0.0, 0.25, 0.5, 0.75, 1.0]
	var next := 0
	var t := 0.0
	var frames := 0
	var worst := 0.0
	var started := Time.get_ticks_usec()
	while t <= 1.0001:
		pieces.set_progress(t)
		if image_count > 0:
			images.set_progress(t)
		var frame_started := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		var ms := float(Time.get_ticks_usec() - frame_started) / 1000.0
		# The first frames pay for shader compilation and the one-off readback;
		# what matters is what a frame costs once it is flying.
		if frames > 2:
			worst = maxf(worst, ms)
		frames += 1
		if next < marks.size() and t >= marks[next]:
			await _shot("shatter_%03d" % int(marks[next] * 100.0))
			next += 1
		t += 0.02
	wall.visible = true
	await _shot("shatter_source")
	print(
		"[shatter] %d frames in %.0f ms, worst frame %.2f ms"
		% [frames, float(Time.get_ticks_usec() - started) / 1000.0, worst]
	)
	print("SHATTER_DONE")
	get_tree().quit()


## What a cell *is*, in the order the layers arrive. The terminal answers the
## first three from the vt and the font stack; nothing here re-reads a glyph.
const LAYERS := [
	{ "name": "text", "motion": Vector2(6.0, 4.0), "when": Vector2(0.00, 0.34) },
	{ "name": "styled", "motion": Vector2(9.0, 7.0), "when": Vector2(0.14, 0.46) },
	{ "name": "cjk", "motion": Vector2(4.0, 2.5), "when": Vector2(0.28, 0.58) },
	{ "name": "icons", "motion": Vector2(7.0, 9.0), "when": Vector2(0.44, 0.72) },
	{ "name": "emoji", "motion": Vector2(12.0, 14.0), "when": Vector2(0.58, 0.90) },
]


## Nerd Font's own glyph ranges, lifted from the terminal config's symbol_map
## — the table that tells the terminal which font to draw them from, so both
## agree on what an icon is.
##
## A blanket "private use area" test does not agree with anything: the PUA is
## far larger than the icons in it, and the Nerd set is scattered through it
## in islands.
const NERD_RANGES := [
	[0xE000, 0xE00A],
	[0xE0A0, 0xE0A3],
	[0xE0B0, 0xE0C8],
	[0xE0CA, 0xE0CA],
	[0xE0CC, 0xE0D7],
	[0xE200, 0xE2A9],
	[0xE300, 0xE3E3],
	[0xE5FA, 0xE6B7],
	[0xE700, 0xE8EF],
	[0xEA60, 0xEC1E],
	[0xED00, 0xEFCE],
	[0xF000, 0xF2FF],
	[0xF300, 0xF381],
	[0xF400, 0xF533],
	[0xF0001, 0xF1AF0],
	# Symbols that same config routes to the Nerd Font one at a time. They sit
	# inside the emoji blocks below, so they are tested first on purpose.
	[0x2022, 0x2022],
	[0x2191, 0x2191],
	[0x2193, 0x2193],
	[0x2197, 0x2198],
	[0x23FB, 0x23FE],
	[0x25AA, 0x25AB],
	[0x2665, 0x2665],
	[0x26A0, 0x26A0],
	[0x2713, 0x2713],
	[0x2B58, 0x2B58],
]
## Frames, blocks and braille: structure rather than language or decoration.
const BOX_RANGES := [[0x2500, 0x257F], [0x2580, 0x259F], [0x25A0, 0x25A9], [0x2800, 0x28FF]]
## The two ranges that config sends to Noto Color Emoji, plus the dingbats and
## miscellaneous symbols it leaves to the text font (✨ ☀ ☂) and the variation
## selector that asks for emoji presentation.
const EMOJI_RANGES := [[0x1F000, 0x1FAFF], [0x2600, 0x27BF], [0xFE0F, 0xFE0F]]
## Hangul, kana, the CJK blocks and the fullwidth forms that follow them.
const CJK_RANGES := [
	[0x1100, 0x11FF],
	[0x2E80, 0x2EFF],
	[0x3000, 0x303F],
	[0x3040, 0x30FF],
	[0x3130, 0x318F],
	[0x31F0, 0x31FF],
	[0x3400, 0x4DBF],
	[0x4E00, 0x9FFF],
	[0xA960, 0xA97F],
	[0xAC00, 0xD7A3],
	[0xD7B0, 0xD7FF],
	[0xF900, 0xFAFF],
	[0xFF00, 0xFF60],
	[0xFFE0, 0xFFE6],
	[0x20000, 0x2FA1F],
]


func _in_ranges(cp: int, table: Array) -> bool:
	for r in table:
		if cp >= r[0] and cp <= r[1]:
			return true
	return false


func _glyph_layer(cp: int, style: int, font: int) -> int:
	## Use Unicode ranges first so known characters land in the same layer
	## regardless of installed fonts.
	##
	## For scripts outside the tables, use the resolved font slot. Slots
	## 0–3 are style faces. Slots 4 and above are fallbacks for glyphs the
	## body face could not draw.
	if _in_ranges(cp, NERD_RANGES) or _in_ranges(cp, BOX_RANGES):
		return 3
	if _in_ranges(cp, EMOJI_RANGES):
		return 4
	if _in_ranges(cp, CJK_RANGES):
		return 2
	if font >= 4:
		return 3
	if style != 0:
		return 1
	return 0


func _render_sample(label: String) -> void:
	## 20 frames to settle whatever just changed, then 90 to take the median of.
	for i in 20:
		await RenderingServer.frame_post_draw
	var times: Array[float] = []
	for i in 90:
		var t0 := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	var median: float = times[times.size() / 2]
	print("[render] %-26s %6.2f ms  %6.1f fps" % [label, median, 1000.0 / median])


func _render_median() -> float:
	for i in 30:
		await RenderingServer.frame_post_draw
	var times: Array[float] = []
	for i in 120:
		var t0 := Time.get_ticks_usec()
		await RenderingServer.frame_post_draw
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	return times[times.size() / 2]


func _tab_fx_test() -> void:
	## The tab transition, sampled: the screen coming apart on the wall we leave,
	## crossing the world, and being put back together on the wall ahead.
	##
	## Screenshots stall a frame each, so the printed time is the one the shot
	## was actually taken at, not the mark asked for.
	await get_tree().create_timer(2.5).timeout
	if surfaces.size() < 2:
		print("[tabfx] %d surface(s): nothing to switch to" % surfaces.size())
		print("TABFX_DONE")
		get_tree().quit()
		return
	var split := _layer_split()
	var sizes: Array = []
	for b in split["cells"]:
		sizes.append(b.size())
	var from_id: String = surfaces[active].id
	print("[tabfx] %d glyph cells, per layer %s" % [int(split["total"]), str(sizes)])
	_goto(wrapi(active + 1, 0, surfaces.size()), false)
	print(
		"[tabfx] %s -> %s: %d leaving, %d arriving, camera %.1fs, effect %.1fs"
		% [from_id, surfaces[active].id, tab_fx_out.size(), tab_fx_in.size(), fly_dur, tab_fx_dur]
	)
	print("[tabfx] terminals alive: %d %s" % [terminals.size(), str(terminals.keys())])
	var marks := [0.0, 0.15, 0.3, 0.7, 1.1, 1.3, 1.45, 1.55]
	var next := 0
	while next < marks.size():
		await RenderingServer.frame_post_draw
		if tab_fx_t < 0.0:
			print("[tabfx] transition ended before mark %.2f" % float(marks[next]))
			break
		if tab_fx_t >= float(marks[next]):
			var at := tab_fx_t
			await _shot("tabfx_%03d" % int(float(marks[next]) * 100.0))
			print("[tabfx] mark %.2f shot at t=%.3f" % [float(marks[next]), at])
			next += 1
	await get_tree().create_timer(0.6).timeout
	await _shot("tabfx_landed")
	var wall_id: String = surfaces[active].id
	print(
		"[tabfx] after: wall %s visible=%s, pieces left %d"
		% [
			wall_id,
			str(walls[wall_id].visible) if walls.has(wall_id) else "no wall",
			tab_fx_out.size() + tab_fx_in.size(),
		]
	)
	print("TABFX_DONE")
	get_tree().quit()


func _build_image_pieces(
	source: Node,
	vp: SubViewport,
	rect: Rect2,
	origin: Vector3,
	du: Vector3,
	dv: Vector3,
) -> Array:
	## Keep images on the pane while text scatters. A frozen graphics-only
	## capture preserves them while the live surface is hidden during a switch.
	var layers: Array = []
	if source == null or vp == null or not source.has_method("image_placements"):
		return layers
	var placements: Array = source.call("image_placements")
	if placements.is_empty():
		return layers
	var cell: Vector2 = source.call("get_cell_size")
	var padding := 4.0
	if source.get("cell_padding") != null:
		padding = float(source.get("cell_padding"))
	# build_regions() takes one size for the whole batch, so images of different
	# sizes go in batches of their own rather than being stretched to match.
	var by_size := { }
	for entry in placements:
		var p: Dictionary = entry
		var local_rect: Rect2 = p.get(
			"dest",
			Rect2(
				Vector2(padding, padding)
				+ Vector2(float(p["col"]) * cell.x, float(p["row"]) * cell.y),
				Vector2(float(p["pixel_width"]), float(p["pixel_height"])),
			),
		)
		var material: ShaderMaterial = (
			source.get_meta("graphics_plane_material")
			if source.has_meta("graphics_plane_material")
			else null
		)
		if material != null:
			local_rect = preload("res://scenes/GraphicsPlane.gd").bounds(
				material.get_shader_parameter("plane_projection"),
				local_rect,
			)
		var capture_rect := Rect2(rect.position + local_rect.position, local_rect.size).intersection(
			rect
		)
		if not capture_rect.has_area():
			continue
		var size := capture_rect.size
		var key := "%s" % size
		if not by_size.has(key):
			by_size[key] = []
		by_size[key].append(capture_rect)
	if debug_render:
		print("[tabfx] images: %d placements, sizes %s" % [placements.size(), str(by_size.keys())])
	for key in by_size:
		var layer := CellShatterScript.new()
		add_child(layer)
		# Images use the same intact fade/approach as their pane backing.
		if layer.build_regions(vp, by_size[key], rect, origin, du, dv, Vector2.ZERO) > 0:
			layer.set_progress(1.0)
			layer.set_meta("panel", true)
			layer.set_meta("image_layer", true)
			layer.set_fly_character(0.0, 0.0, 0.0, 0.0, 1.0)
			var material: ShaderMaterial = layer._material()
			material.set_shader_parameter("background_layer", true)
			var layout := Vector2(CoreTerminalEffects.layout_size(vp))
			material.set_shader_parameter("panel_rect", Vector4(
				rect.position.x / layout.x, rect.position.y / layout.y,
				rect.size.x / layout.x, rect.size.y / layout.y))
			layer.set_appearance(ink_gain, tonemap_exposure)
			_prepare_transition_layer(layer)
			layers.append(layer)
		else:
			layer.queue_free()
	return layers


func _start_tab_transition(
	from_origin: Vector3,
	from_du: Vector3,
	from_dv: Vector3,
	wall: MeshInstance3D,
	to_eye: Vector3,
	out_term: Node,
	out_vp: SubViewport,
	out_windows: Array = [],
	out_shape: Dictionary = { },
	out_graph: Array = [],
	out_layers: Array = [],
) -> void:
	## Build two sets of flight pieces.
	##
	## - The outgoing tab leaves its wall and flies past the viewer.
	## - The incoming tab starts behind the viewer and lands on its own wall.
	##
	## Both use the same flight logic. The incoming path plays in reverse.
	var interrupted := tab_fx_wall != null
	_hand_over_flying_pieces()
	_end_tab_transition()
	if out_term == null or out_vp == null:
		for layer in out_graph + out_layers: layer.queue_free()
		return
	# A point a little past the eye: the pieces have to go by the camera, not
	# stop at it, or they pile up in front of the lens and pop.
	var from_centre := from_origin + from_du * 0.5 + from_dv * 0.5
	var eye := cam.global_transform.origin
	tab_fx_out_target = eye + (eye - from_centre).normalized() * TAB_FX_PAST
	var to_centre := uv_origin + uv_du * 0.5 + uv_dv * 0.5
	tab_fx_in_target = to_eye + (to_eye - to_centre).normalized() * TAB_FX_PAST
	if interrupted:
		# Reuse the visible pieces handed to the stale list. This also covers
		# switches before the previous destination had begun arriving.
		_await_arrival(wall)
		return
	if _floating():
		# The canvas already holds the next tab's windows. Each leaving window
		# flies from independent terminal drawing state and copied frame state.
		for layer in out_layers:
			layer.set_fly(tab_fx_out_target, 0.0)
			tab_fx_out.append(layer)
		for layer in out_graph:
			layer.set_fly(tab_fx_out_target, 0.0)
			tab_fx_out.append(layer)
		_await_arrival(wall)
		return
	var out_ratio := dust_flying_ratio(out_term) if dust_effect() else -1.0
	var out_cells: Array = _transition_cells(out_term, out_ratio)
	out_cells = CellShatterScript.limit_layers(out_cells, scatter_block_budget())
	var out_rect := _terminal_content_rect(CoreTerminalEffects.layout_size(out_vp))
	var panel := _build_panel_pieces(out_vp, out_rect, from_origin, from_du, from_dv)
	var fills := _build_background_pieces(out_vp, out_rect, from_origin, from_du, from_dv)
	fills.set_fly(tab_fx_out_target, 0.0)
	tab_fx_out.append(fills)
	if panel != null:
		panel.set_fly(tab_fx_out_target, 0.0)
		tab_fx_out.append(panel)
	for i in LAYERS.size():
		var spec: Dictionary = LAYERS[i]
		var motion: Vector2 = spec["motion"]
		# Each kind keeps its original spacing and shares one eased flight.
		var out_layer := CellShatterScript.new()
		add_child(out_layer)
		if out_layer.build_cells(
			out_term,
			out_vp,
			out_rect,
			from_origin,
			from_du,
			from_dv,
			out_cells[i],
			motion,
			Vector2(0.0, 0.0),
			3,
			dust_effect() and i == 0,
			dust_particle_budget(),
			out_ratio,
		) > 0:
			# Whole, not scattered: what leaves the wall is the screen itself.
			out_layer.set_progress(1.0)
			_group_transition_layer(out_layer, i, true)
			out_layer.set_thickness(TAB_FX_THICKNESS)
			out_layer.set_appearance(ink_gain, tonemap_exposure)
			_prepare_transition_layer(out_layer)
			out_layer.set_fly(tab_fx_out_target, 0.0)
			tab_fx_out.append(out_layer)
		else:
			out_layer.queue_free()
	for layer in _build_image_pieces(out_term, out_vp, out_rect, from_origin, from_du, from_dv):
		layer.set_fly(tab_fx_out_target, 0.0)
		tab_fx_out.append(layer)
	_await_arrival(wall)


func _await_arrival(wall: MeshInstance3D) -> void:
	CellShatterScript.assign_release_ranks(tab_fx_out.filter(func(layer): return layer.get_meta("glyph_layer", false)))
	if camera_relative_tab_fx or depth_effect():
		for layer in tab_fx_out: _bind_transition_camera(layer, cam.global_transform)
	# Build the destination pieces after repainting its owner snapshot.
	# Restored render resources or a new shell can take longer than a fixed delay.
	#
	# Keep the destination wall dark until the pieces land.
	tab_fx_wall = wall
	if wall != null:
		wall.visible = false
	tab_fx_dur = _transition_duration()
	tab_fx_t = 0.0
	_begin_transition_preparation()
	host.workspace_view.set_connection_transition(true)
	_prepare_ink_frame()


func _begin_transition_preparation() -> void:
	_cancel_transition_preparation()
	tab_fx_preparing = true


func _release_prepared_viewports() -> void:
	for viewport in _tab_fx_prepared_viewports:
		if is_instance_valid(viewport):
			viewport.remove_meta("terminal_transition_live")
			ViewportUpdates.set_capture_active(viewport, false)
			# Restore the camera crop once preparation and live-layer holds end.
			viewport.emit_signal("render_budget_changed")
	_tab_fx_prepared_viewports.clear()


func _cancel_transition_preparation() -> void:
	_tab_fx_generation += 1
	tab_fx_preparing = false
	_tab_fx_capture_pending = false
	_tab_fx_just_prepared = false
	_tab_fx_layout_started = false
	_tab_fx_layout_frame.clear()
	_release_prepared_viewports()


func _transition_sources_ready(check_painted := true) -> bool:
	if not _tab_fx_layout_started and is_instance_valid(host):
		_tab_fx_layout_started = true
		# _goto can start preparation before activating the destination (2D).
		# Claim on its first preparation frame, after the new tab is installed.
		host.session_backend.sync_window_area(host)
		host.session_backend.note_activity(host)
		host._refresh_workspace_layout()
	var pairs: Array = []
	var ready := true
	var layout_frame: Array = [_sheet_size(), camera_motion._target.duplicate(true)]
	if _floating():
		for key in _shown_panes():
			var pane: Control = host.workspace_view.panes[key]
			layout_frame.append([key, pane.position, pane.size, pane.scale])
			if host.is_terminal_pane(key):
				pairs.append(host.sessions[int(key.substr(1))])
			elif host.is_chromium_pane(key):
				var browser: Node = host.chromiums[int(key.substr(1))]
				ready = ready and (browser.texture != null or browser.native_visible or not browser.failure_reason.is_empty())
	else:
		pairs.append({"term": term, "vp": term_vp})
	for pair in pairs:
		if pair.vp not in _tab_fx_prepared_viewports:
			_tab_fx_prepared_viewports.append(pair.vp)
			pair.vp.set_meta("terminal_transition_live", live_arrival())
			ViewportUpdates.set_capture_active(pair.vp, true)
			pair.vp.emit_signal("render_budget_changed")
		ready = ready and (not check_painted or pair.term.is_render_snapshot_ready())
		layout_frame.append([pair.term.get_instance_id(), pair.term.position, pair.term.size, pair.term.get_grid_size()])
	var layout_ready: bool = host.session_backend.transition_layout_ready(host)
	# Require the same acknowledged geometry across preparation frames. The
	# post-draw check below catches deferred sizing without a fixed idle delay.
	if not layout_ready or layout_frame != _tab_fx_layout_frame:
		_tab_fx_layout_frame = layout_frame
		return false
	return ready and not pairs.is_empty()


## Preparation time never consumes the camera/arrival interval. Keep the last
## displayed workspace intact while subscriptions, fonts and native pixels warm.
func _transition_elapsed(dt: float) -> float:
	if _tab_fx_just_prepared:
		_tab_fx_just_prepared = false
		return 0.0
	if not tab_fx_preparing: return dt
	if not _tab_fx_capture_pending and _transition_sources_ready():
		_build_transition_arrival()
		_tab_fx_capture_pending = true
		_wait_for_transition_capture(_tab_fx_generation)
	return 0.0


func _transition_frame_drawn() -> void:
	if DisplayServer.get_name() == "headless":
		await get_tree().process_frame
		await get_tree().process_frame
	else:
		await RenderingServer.frame_post_draw


func _wait_for_transition_capture(generation: int) -> void:
	# Captures are UPDATE_ONCE: construction is not proof of rendered pixels.
	await _transition_frame_drawn()
	if not is_inside_tree() or generation != _tab_fx_generation: return
	if not _transition_sources_ready(false):
		_discard_transition_arrival()
		_tab_fx_capture_pending = false
		return
	# Keep the destination painted while its immutable pieces fly. Releasing it
	# here can suspend an off-canvas pane and discard the pixels needed at landing.
	tab_fx_preparing = false
	_tab_fx_just_prepared = true


func _discard_transition_arrival() -> void:
	for layer in tab_fx_in: layer.queue_free()
	tab_fx_in.clear()


func _build_transition_arrival() -> void:
	_building_switch_arrival = true
	_build_arriving_layers()
	if camera_relative_tab_fx or depth_effect():
		var reference: Transform3D = camera_motion._target.get("transform", cam.global_transform)
		for layer in tab_fx_in: _bind_transition_camera(layer, reference, true, camera_motion._target.get("rect", proj_rect))
	_building_switch_arrival = false


## Terminal windows the canvas currently shows.
func _shown_windows() -> Array:
	var keys: Array = []
	for key in host.workspace_view.panes:
		if host.is_terminal_pane(key) and host.workspace_view.panes[key].visible:
			keys.append(key)
	return keys


## The windows the canvas shows, lowest first.
func _shown_panes() -> Array:
	var keys: Array = []
	for child in host.workspace_view.canvas_root.get_children():
		var key = child.get("key")
		if key is String and host.workspace_view.panes.get(key) == child and child.visible:
			keys.append(key)
	return keys


## Build the pieces for one window's flight in its place on the sheet.
## The caller supplies the sheet's UV origin and edges.
##
## Use a still of the window frame and, for terminals, the background,
## text, and images from its own texture. `order` follows canvas stacking
## from lowest to highest.
func _window_layers(
	key: String,
	origin: Vector3,
	du: Vector3,
	dv: Vector3,
	shape: Dictionary = { },
	order := 0,
) -> Array:
	var layers: Array = []
	var frame := _build_frame_pieces(key, origin, du, dv)
	if frame != null:
		layers.append(frame)
	var pair: Dictionary = (
		host.sessions.get(int(key.substr(1)), { })
		if host.is_terminal_pane(key)
		else { }
	)
	if not pair.is_empty():
		var sheet := _sheet_size()
		var at: Vector2 = host.workspace_view.terminal_origin(key) / sheet
		var extent: Vector2 = Vector2(CoreTerminalEffects.layout_size(pair.vp)) * host.workspace_view.terminal_scale(key) / sheet
		var window_origin: Vector3 = origin + du * at.x + dv * at.y
		var window_du := du * extent.x
		var window_dv := dv * extent.y
		var rect := Rect2(pair.term.position, pair.term.size)
		var terminal: Array = []
		if depth_effect():
			var layer := CellShatterScript.new()
			add_child(layer)
			var full := Rect2(Vector2.ZERO, Vector2(CoreTerminalEffects.layout_size(pair.vp)))
			layer.bind_live_source(pair.vp)
			host.workspace_view.panes[key]._resize_terminal_preview()
			layer.build_regions(pair.vp, [full], full, window_origin, window_du, window_dv, Vector2.ZERO, 0)
			layer.set_progress(1.0)
			layer.set_appearance(ink_gain, tonemap_exposure)
			_prepare_transition_layer(layer)
			terminal.append(layer)
		else:
			terminal = [
				_build_background_pieces(pair.vp, rect, window_origin, window_du, window_dv)
			]
			var fly_ratio := dust_flying_ratio(pair.term) if dust_effect() else -1.0
			var cells: Array = _transition_cells(pair.term, fly_ratio)
			cells = CellShatterScript.limit_layers(cells, scatter_block_budget())
			for i in LAYERS.size():
				if cells[i].is_empty():
					continue
				var layer := CellShatterScript.new()
				add_child(layer)
				if layer.build_cells(
					pair.term,
					pair.vp,
					rect,
					window_origin,
					window_du,
					window_dv,
					cells[i],
					LAYERS[i]["motion"],
					Vector2(0.0, 0.0),
					3,
					dust_effect() and i == 0,
					dust_particle_budget(),
					fly_ratio,
				) > 0:
					layer.set_progress(1.0)
					_group_transition_layer(layer, i, true)
					layer.set_thickness(TAB_FX_THICKNESS)
					layer.set_appearance(ink_gain, tonemap_exposure)
					_prepare_transition_layer(layer)
					terminal.append(layer)
				else:
					layer.queue_free()
			terminal.append_array(
				_build_image_pieces(pair.term, pair.vp, rect, window_origin, window_du, window_dv)
			)
		for layer in terminal:
			layer.set_meta("terminal_ink", true)
			terminal_effects.configure_defocus_tint(layer._material())
			layer._material().set_shader_parameter("source_depth_plane", host.workspace_view.panes[key].texture.material.get_shader_parameter("ink_depth_plane"))
			layer._material().set_shader_parameter(
				"source_sheet_rect",
				Vector4(at.x, at.y, extent.x, extent.y),
			)
		layers.append_array(terminal)
	for layer in layers:
		# Overlapping windows stack as on the canvas: a lower window's text never
		# shows through a higher one's frame.
		var rank := 0 if layer == frame else (1 if layer.has_meta("panel") and not layer.has_meta("image_layer") else 2)
		_set_transition_priority(layer, mini(TAB_FX_WINDOW_PRIORITY + order * 3 + rank, 120))
		_apply_piece_sheet_shape(layer, _piece_sheet_shape() if shape.is_empty() else shape)
	return layers


## A still of a window's frame: border, title bar, and a chromium's page.
##
## It is taken as the switch begins, while the window is still on the canvas,
## and flies as one piece with the window's background: they stay while the
## text leaves and go last, and arriving, they come first.
func _build_frame_pieces(key: String, origin: Vector3, du: Vector3, dv: Vector3) -> Node:
	var view: Control = host.workspace_view
	var pane: Control = view.panes.get(key)
	if pane == null or not pane.is_inside_tree():
		return null
	var layout := Vector2i(pane.size.ceil()).max(Vector2i.ONE)
	# The canvas's texel density, so the still is as sharp as the window was.
	var scale := minf(maxf(view.canvas_scale() * pane.scale.x, 1.0), 8192.0 / maxf(layout.x, layout.y))
	var still := preload("res://scenes/RetainedViewport.gd").new()
	# Linear premultiplied, like the canvas it stands in for.
	still.transparent_bg = true
	still.use_hdr_2d = true
	still.disable_3d = true
	still.size_2d_override = layout
	still.size_2d_override_stretch = true
	still.oversampling = true
	still.size = Vector2i((Vector2(layout) * scale).round()).max(Vector2i.ONE)
	still.render_target_update_mode = SubViewport.UPDATE_ONCE
	still.add_child(pane.still_copy())
	# Beside the terminals' viewports, which Godot draws before the views that
	# show them: the still is there on the switch's first frame.
	view.canvas.add_child(still)
	var layer := CellShatterScript.new()
	add_child(layer)
	layer.tree_exiting.connect(still.queue_free)
	var sheet := _sheet_size()
	var at := (pane.get_transform() * Vector2.ZERO) / sheet
	var extent := Vector2(layout) * pane.scale / sheet
	var whole := Rect2(Vector2.ZERO, Vector2(layout))
	layer.build_regions(
		still,
		[whole],
		whole,
		origin + du * at.x + dv * at.y,
		du * extent.x,
		dv * extent.y,
		Vector2.ZERO,
		0,
	)
	layer.set_meta("panel", true)
	layer.set_progress(1.0)
	layer.set_appearance(ink_gain, tonemap_exposure)
	_prepare_transition_layer(layer)
	var mat: ShaderMaterial = layer._material()
	RenderUpdates.uniform(mat, "background_layer", true)
	RenderUpdates.uniform(mat, "panel_rect", Vector4(0.0, 0.0, 1.0, 1.0))
	RenderUpdates.uniform(mat, "source_sheet_rect", Vector4(at.x, at.y, extent.x, extent.y))
	return layer


func _piece_sheet_shape() -> Dictionary:
	var result := { "source_sheet_size": _sheet_size() }
	if not _floating() or fx_mat == null:
		return { }
	var names := {
		"source_curvature": "curvature_rad",
		"source_ripple": "ripple",
		"source_wavelength": "ripple_wavelength",
		"source_falloff": "ripple_falloff",
		"source_phase": "ripple_phase",
		"source_zoom": "wave_zoom",
		"source_cursor": "cursor",
		"source_splashes": "splash_rings",
		"source_splash_count": "splash_count",
		"source_splash_life": "splash_life",
		"source_splash_speed": "splash_speed",
	}
	for key in names:
		var value = fx_mat.get_shader_parameter(names[key])
		if value != null:
			result[key] = value
	return result


func _apply_piece_sheet_shape(layer: Node, shape: Dictionary) -> void:
	for key in shape:
		layer._material().set_shader_parameter(key, shape[key])


func _update_tab_transition(dt: float) -> void:
	if tab_fx_t < 0.0:
		return
	# Draw the fully assembled pieces once before replacing them with the live
	# surface. Otherwise a slow final frame can jump several pixels at handoff.
	if tab_fx_t >= tab_fx_dur:
		_finish_tab_transition()
		return
	tab_fx_t = minf(tab_fx_t + dt, tab_fx_dur)
	var t := tab_fx_t
	# Arrival shares the camera's deceleration interval and landing deadline.
	var out_fly: float = clampf(t / _tab_departure_duration(), 0.0, 1.0)
	for layer in tab_fx_out:
		layer.set_fly(tab_fx_out_target, _layer_fly(layer, out_fly))
		_update_transition_camera(layer)
	var arrival_duration := _tab_arrival_duration()
	var arrive_at := _tab_arrival_start()
	var in_fly: float = 1.0 - clampf((t - arrive_at) / maxf(arrival_duration, 0.001), 0.0, 1.0)
	var arriving_shape := _piece_sheet_shape() if _floating() else { }
	for layer in tab_fx_in:
		_apply_piece_sheet_shape(layer, arriving_shape)
		layer.set_fly(tab_fx_in_target, _layer_fly(layer, in_fly, true))
		_update_transition_camera(layer)


static func tab_transition_duration() -> float:
	# The departure (TAB_FX_LEAVE) retires over the live surface; only the
	# camera flight and the arrival hold the handoff.
	return maxf(FLY_TIME + TAB_FX_SETTLE, TAB_FX_ARRIVE)


func fly_away_effect() -> bool:
	return session_transition_active and fx_cfg.scene.session_switch.effect == "fly_away"

func depth_effect() -> bool:
	if session_transition_active: return fly_away_effect() and _building_switch_arrival
	return fx_cfg != null and fx_cfg.scene.tab_switch.effect == "push_pull"


func live_arrival() -> bool:
	return fly_away_effect() or (not session_transition_active and depth_effect())


## The current effect's two clocks. Every world and effect hands over to the
## live surface when this timeline's arrival (and the camera) has landed.
func _switch_timeline() -> RefCounted:
	if fly_away_effect():
		# The destination zooms in right behind the departing dust, so the old
		# screen reads as being replaced; the dust finishes over the live view.
		return SwitchTimeline.make(SwitchTimeline.Anchor.START, TAB_FX_LEAVE, DepthMotion.DURATION, FLY_AWAY_ARRIVAL_DELAY)
	if depth_effect(): return SwitchTimeline.make(SwitchTimeline.Anchor.STRETCH, DepthMotion.DURATION, DepthMotion.DURATION)
	return SwitchTimeline.make(SwitchTimeline.Anchor.DEADLINE, TAB_FX_LEAVE, TAB_FX_ARRIVE, 0.0, tab_transition_duration())


## Live handoff deadline; also the camera's flight unless a world travels.
func _transition_duration() -> float:
	return _switch_timeline().landing()


## Camera flight for a switch. Worlds that travel between walls override this;
## a longer flight moves the live handoff with it, never the effect's clocks.
func _navigation_duration() -> float:
	return _transition_duration()


func _tab_departure_duration() -> float:
	return _switch_timeline().departure_duration(tab_fx_dur)


func _tab_direction(previous: int, destination: int) -> float:
	if previous < 0: return 1.0
	var order: Array = host.workspace_layout.tabs.map(func(tab): return int(tab.id))
	var source := order.find(host.workspace_layout.containing("%%%d" % surfaces[previous].session_id))
	var target := order.find(host.workspace_layout.containing("%%%d" % surfaces[destination].session_id))
	return 1.0 if target >= source else -1.0


func _tab_arrival_duration() -> float:
	return _switch_timeline().arrival_duration(tab_fx_dur)


func _tab_arrival_start() -> float:
	return _switch_timeline().arrival_start(tab_fx_dur)


func _sync_tab_transition_deadline() -> void:
	if tab_fx_t < 0.0 or not camera_motion.moving:
		return
	# Read the actual flight, including a world's custom duration and any
	# retarget after layout/zoom changes. Retargeting resets the camera's elapsed
	# time. Camera, scatter and optical focus share the same landing deadline.
	var camera_deadline := tab_fx_t + maxf(camera_motion.duration - camera_motion.elapsed, 0.001)
	tab_fx_dur = camera_deadline
	lens_transition_duration = camera_deadline


func _build_arriving_layers() -> void:
	# Native-size overlays must be unprojected from their final camera, not
	# from a camera that is still hundreds of world units away.
	var displayed := {"transform": cam.global_transform, "rect": proj_rect}
	if camera_motion._target.has("transform"):
		_display_camera_frame(camera_motion._target)
	_build_arriving_layers_at_destination()
	CellShatterScript.assign_release_ranks(tab_fx_in.filter(func(layer): return layer.get_meta("glyph_layer", false)))
	_display_camera_frame(displayed)


func _build_arriving_layers_at_destination() -> void:
	## The destination has received and painted its snapshot before capture.
	if _floating():
		var sheet_origin := _effect_surface_frame(Vector2.ZERO).origin
		host.workspace_view._update_compact_headers(true)
		host.workspace_view._sync_chromium_links()
		for layer in _workspace_transition_layers(sheet_origin, uv_du, uv_dv, {}, true):
			layer.set_fly(tab_fx_in_target, 1.0)
			tab_fx_in.append(layer)
		var shown := _shown_panes()
		for i in shown.size():
			for layer in _window_layers(shown[i], sheet_origin, uv_du, uv_dv, { }, i):
				layer.set_fly(tab_fx_in_target, 1.0)
				tab_fx_in.append(layer)
		return
	if term == null or term_vp == null:
		return
	var fly_ratio := dust_flying_ratio(term) if dust_effect() else -1.0
	var cells: Array = _transition_cells(term, fly_ratio)
	cells = CellShatterScript.limit_layers(cells, scatter_block_budget())
	var rect := _terminal_content_rect(CoreTerminalEffects.layout_size(term_vp))
	var origin := _effect_surface_frame(Vector2.ZERO).origin
	var panel := _build_panel_pieces(term_vp, rect, origin, uv_du, uv_dv)
	var fills := _build_background_pieces(term_vp, rect, origin, uv_du, uv_dv)
	fills.set_fly(tab_fx_in_target, 1.0)
	tab_fx_in.append(fills)
	if panel != null:
		panel.set_fly(tab_fx_in_target, 1.0)
		tab_fx_in.append(panel)
	for i in LAYERS.size():
		if cells[i].is_empty():
			continue
		var spec: Dictionary = LAYERS[i]
		var layer := CellShatterScript.new()
		add_child(layer)
		if layer.build_cells(
			term,
			term_vp,
			rect,
			origin,
			uv_du,
			uv_dv,
			cells[i],
			spec["motion"],
			Vector2(0.0, 0.0),
			3,
			dust_effect() and i == 0,
			dust_particle_budget(),
			fly_ratio,
		) > 0:
			layer.set_progress(1.0)
			_group_transition_layer(layer, i, true)
			layer.set_thickness(TAB_FX_THICKNESS)
			layer.set_appearance(ink_gain, tonemap_exposure)
			_prepare_transition_layer(layer)
			layer.set_fly(tab_fx_in_target, 1.0)
			tab_fx_in.append(layer)
		else:
			layer.queue_free()
	for image_layer in _build_image_pieces(term, term_vp, rect, origin, uv_du, uv_dv):
		image_layer.set_fly(tab_fx_in_target, 1.0)
		tab_fx_in.append(image_layer)


## Departing pieces keep flying on their own clock after the transition ends
## or is interrupted; the live surface no longer waits for them.
func _retire_departing_pieces(leaving: float) -> void:
	var group: int = tab_fx_out[0].get_instance_id() if not tab_fx_out.is_empty() else 0
	for layer in tab_fx_out:
		var fly: float = _layer_fly(layer, leaving)
		if fly >= 1.0:
			layer.queue_free()
			continue
		if not layer.get_meta("depth_mode", false): layer.freeze_live_source()
		tab_fx_stale.append(
			{
				"layer": layer,
				"capture_group": group,
				"target": tab_fx_out_target,
				"fly": fly,
				"speed": 1.0 / maxf(TAB_FX_LEAVE, 0.001),
			}
		)
	tab_fx_out.clear()


func _hand_over_flying_pieces() -> void:
	## A second switch while the first is still in the air. The pieces already
	## travelling keep their position and direction; the ones that were landing
	## carry their velocity into a gentle turn.
	##
	## Retain the two latest snapshots so repeated interruptions leave room for
	## the next capture.
	if tab_fx_wall == null:
		return
	# A completed flight still owns its assembled pieces while the live-sheet
	# handoff waits for frame_post_draw. Retarget those pieces too.
	var transition_time := tab_fx_dur if tab_fx_t < 0.0 else tab_fx_t
	_retire_departing_pieces(clampf(transition_time / maxf(_tab_departure_duration(), 0.001), 0.0, 1.0))
	# Snapshot each arriving phase. The shader preserves each chunk's actual
	# velocity and joins the departure speed without replaying a spring backwards.
	var arrival_duration := _tab_arrival_duration()
	var arrive_at := _tab_arrival_start()
	var landing: float = 1.0 - clampf((transition_time - arrive_at) / maxf(arrival_duration, 0.001), 0.0, 1.0)
	for layer in tab_fx_in:
		if not layer.get_meta("depth_mode", false): layer.freeze_live_source()
		layer._material().set_shader_parameter("retirement_phase", landing)
		layer._material().set_shader_parameter("retirement_time", 0.0)
		tab_fx_stale.append(
			{
				"layer": layer,
				"capture_group": tab_fx_in[0].get_instance_id(),
				"target": tab_fx_in_target,
				"fly": _layer_fly(layer, landing, true),
				"retirement_time": 0.0,
			}
		)
	# Preserve the most visible depth captures. During repeated reversals the
	# newest arrival can still be fully transparent.
	var group_opacity := {}
	for entry in tab_fx_stale:
		var opacity := 1.0
		if entry.layer.get_meta("depth_mode", false):
			var mat: ShaderMaterial = entry.layer._material()
			entry.depth_opacity = float(mat.get_shader_parameter("depth_opacity"))
			opacity = entry.depth_opacity * (1.0 - entry.fly)
		group_opacity[entry.capture_group] = maxf(group_opacity.get(entry.capture_group, 0.0), opacity)
	tab_fx_out.clear()
	tab_fx_in.clear()
	var groups := group_opacity.keys()
	while groups.size() > 2:
		var discard_group = groups[0]
		for group in groups:
			if group_opacity[group] < group_opacity[discard_group]: discard_group = group
		groups.erase(discard_group)
		for entry in tab_fx_stale:
			if entry.capture_group == discard_group: entry.layer.queue_free()
		tab_fx_stale = tab_fx_stale.filter(func(entry): return entry.capture_group != discard_group)


# Connections sit below panes; sockets sit above them. Freeze their geometry
# independently so a tab switch cannot redraw the old snapshot with new edges.
func _workspace_border_captures(displayed := true) -> Array:
	var view: Control = host.workspace_view
	var result: Array = []
	if view.boundary.visible:
		var copy: Control = view.boundary.duplicate(0)
		copy.position = Vector2.ZERO
		result.append({"drawing": copy, "rect": Rect2(view.boundary.position, view.boundary.size), "kind": "main"})
	# Tab focus can change before _goto captures the outgoing view. Preserve
	# the last painted outline rather than asking the new focus what to draw.
	var selection: Array = view.agent_links.wire_layer.selection_commands
	if not displayed:
		var painter: Node2D = view.agent_links.wire_layer.get_script().new()
		painter.frozen = true
		painter.unproject = view.agent_links.wire_layer.unproject
		view.agent_links.tools.draw_selection(painter)
		selection = painter.commands
		painter.free()
	for command in selection:
		var style: StyleBoxFlat = command[1][0]
		var rect: Rect2 = command[1][1]
		rect = rect.grow(style.shadow_size + 2)
		var drawing: Node2D = view.agent_links.wire_layer.get_script().new()
		drawing.frozen = true
		drawing.commands = [command]
		drawing.position = -rect.position
		result.append({"drawing": drawing, "rect": rect, "kind": "selection"})
	return result


func _workspace_transition_layers(origin: Vector3, du: Vector3, dv: Vector3, shape: Dictionary = {}, arriving := false) -> Array:
	var view: Control = host.workspace_view
	var result: Array = []
	# Outlines are intact pane decorations. Give each its own backing capture,
	# so the selected pane and Main View keep their own zoom/fade pivot.
	for border in _workspace_border_captures(not arriving):
		var rect: Rect2 = border.rect
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.disable_3d = true
		still.size = Vector2i(rect.size.ceil()).max(Vector2i.ONE)
		still.size_2d_override = still.size
		still.size_2d_override_stretch = true
		preload("res://scenes/EffectCaptureBudget.gd").fit(still)
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(border.drawing)
		view.canvas.add_child(still)
		var layer := CellShatterScript.new()
		add_child(layer)
		layer.tree_exiting.connect(still.queue_free)
		var at := rect.position / _sheet_size()
		var extent := rect.size / _sheet_size()
		var whole := Rect2(Vector2.ZERO, Vector2(still.size))
		layer.build_regions(still, [whole], whole, origin + du * at.x + dv * at.y, du * extent.x, dv * extent.y, Vector2.ZERO, 0)
		layer.set_progress(1.0)
		layer.set_meta("panel", true)
		layer.set_meta("border_layer", border.kind)
		layer.set_appearance(ink_gain, tonemap_exposure)
		_prepare_transition_layer(layer)
		var material: ShaderMaterial = layer._material()
		_set_transition_priority(layer, TAB_FX_WINDOW_PRIORITY - 1)
		material.set_shader_parameter("background_layer", true)
		material.set_shader_parameter("panel_rect", Vector4(0, 0, 1, 1))
		material.set_shader_parameter("source_sheet_rect", Vector4(at.x, at.y, extent.x, extent.y))
		_apply_piece_sheet_shape(layer, _piece_sheet_shape() if shape.is_empty() else shape)
		result.append(layer)
	var wires := view.agent_links.wire_layer.still_copy(false, true) as Node2D
	var owners := view.chromium_links.wire_layer.still_copy() as Node2D
	wires.commands.append_array(owners.commands)
	owners.free()
	var sockets := view.agent_links.wire_layer.get_script().new() as Node2D
	sockets.frozen = true
	sockets.unproject = view.agent_links.wire_layer.unproject
	for output in [false, true]:
		for button in view.agent_links.sockets(output).values():
			if button.visible:
				sockets.circle(button.position + button.size * 0.5, 4.0, button.get_meta("port_color"))
	for drawing in [wires, sockets]:
		if drawing.commands.is_empty():
			drawing.free()
			continue
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.disable_3d = true
		# Graphs may be anywhere on the workspace, including wholly outside
		# Main View. Capture the visible canvas, not a sheet at the origin.
		# Include the socket margin in both the raster and its world basis.
		var sheet := _sheet_size()
		var padding := Vector2.ONE * maxf(32.0, drawing.local_width(view.size * 0.5, 32.0))
		var rect: Rect2 = view.visible_canvas_rect().grow(padding.x)
		rect = Rect2(rect.position.floor(), rect.end.ceil() - rect.position.floor())
		still.size = Vector2i(rect.size).max(Vector2i.ONE)
		still.size_2d_override = still.size
		still.size_2d_override_stretch = true
		preload("res://scenes/EffectCaptureBudget.gd").fit(still)
		drawing.position = -rect.position
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(drawing)
		view.canvas.add_child(still)
		var layer := CellShatterScript.new()
		add_child(layer)
		layer.tree_exiting.connect(still.queue_free)
		var whole := Rect2(Vector2.ZERO, Vector2(CoreTerminalEffects.layout_size(still)))
		var at := rect.position / sheet
		var extent := rect.size / sheet
		layer.build_regions(still, [whole], whole, origin + du * at.x + dv * at.y, du * extent.x, dv * extent.y, Vector2.ZERO, 0)
		layer._material().set_shader_parameter("source_sheet_rect", Vector4(at.x, at.y, extent.x, extent.y))
		layer.set_progress(1.0)
		layer.set_appearance(ink_gain, tonemap_exposure)
		_prepare_transition_layer(layer)
		layer.set_meta("graph_layer", "wires" if drawing == wires else "sockets")
		# Connections belong to the pane backing, not independently flying ink.
		layer.set_meta("panel", true)
		layer._material().set_shader_parameter("background_layer", true)
		layer._material().set_shader_parameter("panel_rect", Vector4(0, 0, 1, 1))
		_set_transition_priority(layer, TAB_FX_WINDOW_PRIORITY - 1 if drawing == wires else 121)
		_apply_piece_sheet_shape(layer, _piece_sheet_shape() if shape.is_empty() else shape)
		result.append(layer)
	# Sheet-anchored overview captions transition with the workspace.
	# Dockable tool windows remain independent, like Agents and Sessions.
	var controls: Array = view.status_strips.values()
	for control in controls:
		if not control.visible or control.size.x <= 0 or control.size.y <= 0: continue
		var still := CellShatterScript.capture_control(control)
		view.canvas.add_child(still)
		var sheet := _sheet_size()
		var rect: Rect2 = view.control_canvas_rect(control)
		var at := rect.position / sheet
		var extent := rect.size / sheet
		var layer := CellShatterScript.new()
		add_child(layer)
		layer.tree_exiting.connect(still.queue_free)
		var whole := Rect2(Vector2.ZERO, Vector2(CoreTerminalEffects.layout_size(still)))
		layer.build_regions(still, [whole], whole, origin + du * at.x + dv * at.y, du * extent.x, dv * extent.y, Vector2.ZERO, 0)
		layer.set_progress(1.0)
		layer.set_meta("workspace_chrome", true)
		layer.set_appearance(ink_gain, tonemap_exposure)
		_prepare_transition_layer(layer)
		_group_transition_layer(layer, 1)
		_set_transition_priority(layer, 122)
		layer._material().set_shader_parameter("source_sheet_rect", Vector4(at.x, at.y, extent.x, extent.y))
		_apply_piece_sheet_shape(layer, _piece_sheet_shape() if shape.is_empty() else shape)
		result.append(layer)
	return result


func _bind_transition_camera(layer: Node3D, reference: Transform3D, arriving := false, reference_rect := Vector4.ZERO) -> void:
	layer.set_meta("transition_arriving", arriving)
	layer.set_meta("transition_camera", reference)
	layer.set_meta("transition_frustum", proj_rect if reference_rect == Vector4.ZERO else reference_rect)
	layer._material().set_shader_parameter("camera_relative_flight", true)
	_update_transition_camera(layer)


func _update_transition_camera(layer: Node3D) -> void:
	if not layer.has_meta("transition_camera"):
		layer.update_raster(cam)
		return
	var reference: Transform3D = layer.get_meta("transition_camera")
	var transform := cam.global_transform * reference.affine_inverse()
	if layer.get_meta("depth_mode", false):
		# Keep the capture's screen framing while the live camera moves between
		# saved views. Only the shared dolly clock may magnify these panes.
		var captured: Vector4 = layer.get_meta("transition_frustum")
		var material: ShaderMaterial = layer._material()
		var direction: float = material.get_shader_parameter("depth_direction")
		var arriving: bool = material.get_shader_parameter("arrival_flight") == true
		var phase: float = material.get_shader_parameter("fly")
		var magnification := pow(DepthMotion.ZOOM_RATIO, direction * (-1.0 if arriving else 1.0) * phase)
		transform = DepthMotion.presentation_transform(reference, cam.global_transform, captured, proj_rect, magnification)
		material.set_shader_parameter("depth_transform", transform)
	elif layer.get_meta("transition_arriving", false):
		# Follow the camera early, then settle onto the actual destination plane.
		# Resting camera effects may differ from the flight's original target.
		var flight: float = layer._material().get_shader_parameter("fly")
		transform = Transform3D.IDENTITY.interpolate_with(transform, smoothstep(0.0, 1.0, flight))
	# The shader positions vertices explicitly; update both it and the node so
	# the renderer's culling bounds follow the same camera-relative geometry.
	layer.global_transform = transform
	layer._material().set_shader_parameter("flight_camera_transform", transform)
	layer._material().set_shader_parameter("flight_camera_eye", transform.affine_inverse() * cam.global_position)
	layer.update_raster(cam)


func _group_transition_layer(layer: Node, index: int, glyphs := false) -> void:
	if dust_effect() and not glyphs:
		layer._material().set_shader_parameter("background_layer", true)
		layer._material().set_shader_parameter("panel_rect", Vector4(0, 0, 1, 1))
		return
	layer.set_meta("glyph_layer", glyphs)
	if glyphs and not layer.has_meta("dust"): layer.enable_flight_volume()
	layer.set_meta("semantic_layer", index)
	layer._material().set_shader_parameter("grouped_flight", true)
	layer._material().set_shader_parameter("chunked_flight", glyphs)
	layer._material().set_shader_parameter("chunk_seed", randf())
	layer._material().set_shader_parameter("group_index", float(index))
	# A small lateral drift varies the path; most travel is toward the camera.
	var angle := randf_range(-PI, PI)
	var direction := Vector2(cos(angle), sin(angle))
	direction /= maxf(absf(direction.x), absf(direction.y))
	var reach := randf_range(0.035, 0.085)
	layer._material().set_shader_parameter("group_motion", Vector4(direction.x * reach, direction.y * reach, randf_range(0.96, 1.06), randf()))
	layer._material().set_shader_parameter("group_rotation", Vector2(randf_range(-0.22, 0.22), randf_range(-0.3, 0.3)))
	layer._material().set_shader_parameter("group_float", Vector2(randf_range(-0.16, 0.16), randf_range(-0.16, 0.16)))
	var mat: ShaderMaterial = layer._material()
	var travel_du: Vector3 = mat.get_shader_parameter("plane_a_du")
	var travel_dv: Vector3 = mat.get_shader_parameter("plane_a_dv")
	# All UI captures share the workspace scale, including fixed-pixel chrome
	# whose own unprojected dimensions grow as the camera moves away.
	if uv_du.length_squared() > 0.000001 and uv_dv.length_squared() > 0.000001:
		travel_du = uv_du
		travel_dv = uv_dv
	RenderUpdates.uniform(mat, "group_travel_du", travel_du)
	RenderUpdates.uniform(mat, "group_travel_dv", travel_dv)


func _set_transition_priority(layer: Node, priority: int) -> void:
	var material: ShaderMaterial = layer._material()
	material.render_priority = priority
	# Reverse-Z: bring later canvas layers slightly forward. This preserves
	# pane/chrome stacking without disabling the depth writes needed by DOF.
	material.set_shader_parameter("stack_depth_bias", float(priority - TAB_FX_WINDOW_PRIORITY + 1) * 0.0000001)


func _prepare_transition_layer(layer: Node) -> void:
	if depth_effect():
		layer._material().shader = preload("res://scenes/tab_depth_3d.gdshader")
		# A whole pane must follow the same curved sheet as the live texture.
		# Four corners approximate it with two triangles and shift rows at capture.
		var mesh := layer.multimesh.mesh as QuadMesh
		if mesh != null:
			mesh.subdivide_width = 32
			mesh.subdivide_depth = 32
		layer.set_meta("depth_mode", true)
		layer._material().set_shader_parameter("depth_opacity", 1.0)
		layer._material().set_shader_parameter("depth_direction", tab_fx_direction)
		layer._material().set_shader_parameter("depth_zoom_ratio", DepthMotion.ZOOM_RATIO)
	# A switch can happen after this frame's _update_ink_view. Never expose a
	# newly created glyph layer to scenery glow/DoF for even that first frame.
	layer.layers = INK_MASK if ink_active else 1
	layer.set_instance_shader_parameter("workspace_clip_top", _workspace_clip_top)
	_set_transition_priority(layer, TAB_FX_WINDOW_PRIORITY + 2)
	_update_transition_lens(layer)


func _update_transition_lens(layer: Node) -> void:
	if layer.departing_lens.y > 0.0: return # set_fly owns this capture's lens
	layer._material().set_shader_parameter("focus_depth", terminal_effects.focus_depth)
	layer._material().set_shader_parameter(
		"blur_radius",
		(
			0.0
			if terminal_effects.screen_dof
			else terminal_effects.blur_radius / maxf(terminal_effects.depth_range, 0.0263)
		),
	)
	layer._material().set_shader_parameter("blur_limit", terminal_effects.blur_limit)


func _layer_fly(layer: Node, value: float, arriving := false) -> float:
	if arriving and layer.get_meta("terminal_ink", false):
		terminal_effects.configure_defocus_tint(layer._material())
		layer._material().set_shader_parameter("source_depth_plane", _terminal_depth_plane())
	layer._material().set_shader_parameter("arrival_flight", arriving)
	layer._material().set_shader_parameter("retire_flight_pieces", true)
	_update_transition_lens(layer)
	if layer.get_meta("depth_mode", false):
		var mat: ShaderMaterial = layer._material()
		if not layer.has_meta("depth_priority"): layer.set_meta("depth_priority", mat.render_priority)
		var front: bool = arriving == (float(mat.get_shader_parameter("depth_direction")) < 0.0)
		mat.render_priority = int(layer.get_meta("depth_priority")) - (0 if front else 128)
		return DepthMotion.phase(value)
	# Backings leave first and return last; arrival runs value from one to zero.
	return clampf(value / CellShatterScript.BACKING_FLIGHT_FRACTION, 0.0, 1.0) if layer.has_meta("panel") else value


func _build_background_pieces(
	viewport: SubViewport,
	rect: Rect2,
	origin: Vector3,
	du: Vector3,
	dv: Vector3,
) -> Node:
	var layer := CellShatterScript.new()
	add_child(layer)
	layer.build_regions(viewport, [rect], rect, origin, du, dv, Vector2.ZERO, 1 << 17)
	layer.set_meta("panel", true)
	layer.set_progress(1.0)
	layer.set_appearance(1.0, tonemap_exposure)
	_prepare_transition_layer(layer)
	var mat: ShaderMaterial = layer._material()
	RenderUpdates.uniform(mat, "background_layer", true)
	_set_transition_priority(layer, TAB_FX_WINDOW_PRIORITY + 1)
	var layout := Vector2(CoreTerminalEffects.layout_size(viewport))
	RenderUpdates.uniform(mat,
		"panel_rect",
		Vector4(
			rect.position.x / layout.x,
			rect.position.y / layout.y,
			rect.size.x / layout.x,
			rect.size.y / layout.y,
		),
	)
	return layer


func _build_panel_pieces(
	viewport: SubViewport,
	rect: Rect2,
	origin: Vector3,
	du: Vector3,
	dv: Vector3,
) -> Node:
	if background_opacity <= 0.0:
		return null
	var layer := CellShatterScript.new()
	add_child(layer)
	# One unbroken sheet. Only glyphs scatter; the backing floats as a whole.
	layer.build_regions(viewport, [rect], rect, origin, du, dv, Vector2.ZERO, 0)
	layer.set_meta("panel", true)
	layer.set_progress(1.0)
	layer.set_fly_character(0.0, 0.0, 0.0, 0.0, 1.0)
	layer.set_appearance(1.0, tonemap_exposure)
	_prepare_transition_layer(layer)
	var mat: ShaderMaterial = layer._material()
	_set_transition_priority(layer, TAB_FX_WINDOW_PRIORITY)
	RenderUpdates.uniform(mat, "panel_layer", true)
	var layout := CoreTerminalEffects.layout_size(viewport)
	RenderUpdates.uniform(mat, "panel_tex_size", Vector2(layout))
	RenderUpdates.uniform(mat,
		"panel_rect",
		Vector4(
			rect.position.x / layout.x,
			rect.position.y / layout.y,
			rect.size.x / layout.x,
			rect.size.y / layout.y,
		),
	)
	for key in ["panel_color", "panel_opacity"]:
		RenderUpdates.uniform(mat, key, fx_mat.get_shader_parameter(key))
	RenderUpdates.uniform(mat, "panel_radius", fx_cfg.scene.sheet.corner_radius)
	RenderUpdates.uniform(mat, "panel_feather", fx_cfg.scene.sheet.edge_blur)
	return layer


func _update_stale_pieces(dt: float) -> void:
	if tab_fx_stale.is_empty(): return
	var arrival := 1.0 if tab_fx_t < 0.0 else clampf((tab_fx_t - _tab_arrival_start()) / _tab_arrival_duration(), 0.0, 1.0)
	var depth_fade := 1.0 - DepthMotion.phase(arrival)
	var still: Array = []
	for entry in tab_fx_stale:
		var e: Dictionary = entry
		var layer = e["layer"]
		if e.has("depth_opacity"):
			# Fade in step with the replacement, including its preparation wait.
			if arrival >= 1.0:
				layer.queue_free()
				continue
			layer._material().set_shader_parameter("depth_opacity", e.depth_opacity * depth_fade)
			_update_transition_lens(layer)
			_update_transition_camera(layer)
			still.append(e)
			continue
		var retiring_arrival := e.has("retirement_time")
		var fly: float
		var finished := false
		if retiring_arrival:
			e.retirement_time += dt
			fly = preload("res://scenes/ScatterMotion.gd").retire_pose(e.fly, -1.0 / TAB_FX_ARRIVE, e.retirement_time)
			finished = e.retirement_time >= TAB_FX_LEAVE
		else:
			fly = float(e["fly"]) + dt * float(e["speed"])
			finished = fly >= 1.0
		if finished or layer == null or not is_instance_valid(layer):
			if layer != null and is_instance_valid(layer):
				layer.queue_free()
			continue
		if retiring_arrival:
			layer._material().set_shader_parameter("retirement_time", e.retirement_time)
		else:
			e["fly"] = fly
		_update_transition_lens(layer)
		layer.set_fly(e["target"], fly)
		_update_transition_camera(layer)
		still.append(e)
	tab_fx_stale = still


func _finish_tab_transition() -> void:
	# Apply the settled crop while the assembled pieces still cover the surface.
	# Projection notifications normally flush next frame. Waiting would
	# show the old crop for one frame during handoff.
	var generation := _tab_fx_generation
	# The arrival has landed; a slower departure (fly away) continues over the
	# live surface instead of delaying it.
	_retire_departing_pieces(clampf(tab_fx_t / maxf(_tab_departure_duration(), 0.001), 0.0, 1.0))
	tab_fx_t = -1.0
	if _floating():
		_release_prepared_viewports()
		_notify_workspace_projection_changed()
		host.workspace_view.update_raster_region()
		host.workspace_view._update_compact_headers()
		host.workspace_view._sync_chromium_links()
		_wait_for_live_transition_frame(generation)
		return
	_end_tab_transition()


## Bound one-shot callbacks disappear when this world is freed. Awaiting here
## would resume a destroyed world when an Android view changes worlds mid-flight.
func _wait_for_live_transition_frame(generation: int) -> void:
	if not is_inside_tree() or generation != _tab_fx_generation: return
	get_tree().process_frame.connect(_transition_live_process.bind(generation), CONNECT_ONE_SHOT)


func _transition_live_process(generation: int) -> void:
	if not is_inside_tree() or generation != _tab_fx_generation: return
	if DisplayServer.get_name() == "headless":
		get_tree().process_frame.connect(_transition_live_drawn.bind(generation), CONNECT_ONE_SHOT)
	else:
		RenderingServer.frame_post_draw.connect(_transition_live_drawn.bind(generation), CONNECT_ONE_SHOT)
		# Low-processor mode draws only after a change, and the landed pieces
		# are still. Without this frame the wall would stay hidden until
		# something else redraws.
		RenderUpdates.before_draw(_draw_transition_frame)


func _draw_transition_frame() -> void:
	pass


func _transition_live_drawn(generation: int) -> void:
	if not is_inside_tree() or generation != _tab_fx_generation: return
	for key in _shown_windows():
		var pair: Dictionary = host.sessions[int(key.substr(1))]
		if pair.term.is_render_active() and not pair.term.is_render_snapshot_ready():
			_wait_for_live_transition_frame(generation)
			return
	_complete_live_transition()


func _complete_live_transition() -> void:
	_end_tab_transition()


func _end_tab_transition() -> void:
	## Whatever happens — finished, interrupted by another switch, or refused
	## before it started — the wall must come back. A transition that can leave
	## the terminal invisible is worse than no transition.
	_cancel_transition_preparation()
	for layer in tab_fx_out:
		layer.queue_free()
	for layer in tab_fx_in:
		layer.queue_free()
	tab_fx_out.clear()
	tab_fx_in.clear()
	if tab_fx_wall != null:
		tab_fx_wall.visible = active >= 0 and walls.get(surfaces[active].id) == tab_fx_wall
		tab_fx_wall = null
	tab_fx_t = -1.0
	if is_instance_valid(host) and is_instance_valid(host.workspace_view):
		host.workspace_view.set_connection_transition(false)


func dust_effect() -> bool:
	return session_transition_active and (fx_cfg.scene.session_switch.effect == "fly_away_and_in" or (fly_away_effect() and not _building_switch_arrival))


func dust_particle_budget() -> int:
	# Outgoing and incoming captures overlap. Split the configured total.
	return maxi(1, int(fx_cfg.scene.session_switch.dust_particles) / (2 * maxi(_shown_windows().size() if _floating() else 1, 1)))


func dust_flying_ratio(source: Node = null) -> float:
	var builder := preload("res://scenes/DustPieces.gd")
	var count := 0
	if _floating():
		# Density belongs to the whole tab, not the individual pane. Captures
		# choose this before switching focus, separately for departure/arrival.
		for key in _shown_windows():
			var pair: Dictionary = host.sessions.get(int(key.substr(1)), {})
			if not pair.is_empty():
				var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(pair.term)
				if snapshot != null: count += snapshot.occupied_cell_count()
	elif source != null:
		var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(source)
		if snapshot != null: count = snapshot.occupied_cell_count()
	var settings: Dictionary = fx_cfg.scene.session_switch
	return builder.flying_ratio(count, float(settings.fly_ratio_sparse), float(settings.fly_ratio_dense), int(settings.fly_dense_count))


func _transition_cells(source: Node, fly_ratio := -1.0) -> Array:
	if dust_effect():
		var builder := preload("res://scenes/DustPieces.gd")
		var cells := builder.cells(source, dust_particle_budget())
		return [cells, builder.letters(cells, dust_flying_ratio(source) if fly_ratio < 0.0 else fly_ratio), [], [], []]
	return _layer_split(source)["cells"]


func scatter_block_budget() -> int:
	if dust_effect(): return 0
	var maximum := int(fx_cfg.scene.session_switch.max_blocks)
	if maximum == 0: return 0
	# Share one tab's text budget across visible terminals, with at least one
	# block per pane. Incoming and outgoing tabs each get their own budget.
	var panes := _shown_windows().size() if _floating() else 1
	return maxi(1, maximum / maxi(panes, 1))


func _layer_split(from: Node = null) -> Dictionary:
	## One screen grouped by what each cell is — `from` is which terminal's,
	## since every tab has its own.
	##
	## Images are their own layer already and hold no glyph, so they are absent
	## here and need no excluding.
	var source: Node = from if from != null else term
	var cells: Array = [[], [], [], [], []]
	var samples: Array = ["", "", "", "", ""]
	var total := 0
	if source == null or not source.has_method("capture_render_state"):
		return { "cells": cells, "samples": samples, "total": total }
	var snapshot := preload("res://scenes/RetainedViewport.gd").terminal_state(source)
	if snapshot == null: return { "cells": cells, "samples": samples, "total": total }
	for entry in snapshot.flight_glyphs():
		var g: Dictionary = entry
		var layer := _glyph_layer(int(g["cp"]), int(g["style"]), int(g["font"]))
		cells[layer].append(g.rect)
		if samples[layer].length() < 12:
			samples[layer] += char(int(g["cp"]))
		total += 1
	return { "cells": cells, "samples": samples, "total": total }


func _layer_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").layer_test(self)


func _selection_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").selection_test(self)


func _signal_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").signal_test(self)


func _layout_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").layout_test(self)


func _fx_demo() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").fx_demo(self)


func _shot(tag: String) -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").shot(self, tag)


func _input_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").input_test(self)


func _fx_target_zoom(target: float) -> float:
	## The target zoom is the state being moved TO, not the
	## value part-way through the transition.
	var state: String = String(
		(fx_cfg.behavior["active_state"]
			if target > 0.5
			else fx_cfg.behavior["rest_state"])
	)
	return maxf(float(_controlled_frame(fx_cfg.frame(state), true)["camera.zoom"]), 0.25)


func _lag_test() -> void:
	await preload("res://scenes/diagnostics/TerminalWorldProbes.gd").lag_test(self)


func _read_cursor() -> bool:
	## Read the cursor cell and grid size directly from the terminal.
	##
	## `get_cursor_cell()` and `get_grid_size()` reuse data cached during repaint.
	## Reading them every frame avoids guessing from shell input. The upstream
	## Control exposed only `font_size` and `color_scheme`.
	if term == null or not term.has_method("get_cursor_cell"):
		return false
	var cell: Vector2i = term.get_cursor_cell()
	if cell.x < 0:
		return false # hidden, or the shell has not started
	var grid: Vector2i = term.get_grid_size()
	if grid.x <= 0 or grid.y <= 0:
		return false
	# Centre of the cell, so the lean is measured from the glyph, not its edge.
	fx_cursor = Vector2(
		clampf((float(cell.x) + 0.5) / float(grid.x), 0.0, 1.0),
		clampf((float(cell.y) + 0.5) / float(grid.y), 0.0, 1.0),
	)
	return true


func _merged_terminal_config() -> ConfigFile:
	var config := (
		terminal_config.to_config()
		if terminal_config != null
		else TerminalConfig \
				.new() \
				.to_config()
	)
	# WorkspacePane already positions/sizes the terminal using per-edge padding.
	# The legacy sheet inset must not be applied again inside that terminal.
	var pane_managed := host != null and host.workspace_view != null
	config.set_value("terminal", "padding", 0.0 if pane_managed else terminal_padding)
	return config


func _load_background_config() -> void:
	if not fixed_tab_camera:
		return
	var cfg := _merged_terminal_config()
	var args := Array(OS.get_cmdline_user_args())
	if not args.any(
		func(a):
			return a.begins_with("--bg="),
	):
		bg_color = Color(str(cfg.get_value("terminal", "bg", bg_color.to_html())))
	if not args.any(
		func(a):
			return a.begins_with("--opacity="),
	):
		background_opacity = clampf(
			float(cfg.get_value("terminal", "background_opacity", background_opacity)),
			0.0,
			1.0,
		)
	if (world_mode == "transparent"
		and not args.any(
			func(a):
				return a.begins_with("--opacity="),
		)):
		background_opacity = 0.0


func _load_world() -> Dictionary:
	return { }


func _build_world() -> void:
	## The same two steps an authored world takes: put the surfaces in the scene,
	## then hand them to the kit.
	##
	## An authored world overriding _build_world() does nothing different in
	## shape — its surfaces just come from a .tscn.
	_build_flat_world()
	_build_walls()


func _build_environment(_light: Dictionary) -> void:
	var transparent := background_opacity < 1.0
	get_viewport().transparent_bg = transparent
	preload("res://scenes/DesktopBlur.gd").set_window_transparent(get_window(), transparent)
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0) if transparent else bg_color)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	var attr := CameraAttributesPractical.new()
	we.camera_attributes = attr
	fx_env = env
	fx_attr = CameraAttributesPhysical.new()
	add_child(we)


func _fly_speed() -> float:
	return camera_motion.velocity.length()


func _navigation_route(_prev: int, _idx: int) -> PackedVector3Array:
	return PackedVector3Array()


func _resume_navigation_route(_idx: int, _destination: Dictionary, _seconds: float) -> bool:
	return false


func _begin_navigation(prev: int, idx: int, _speed: float) -> void:
	var surface: TerminalSurface3D = surfaces[idx]
	var destination := _camera_base_frame(surface.eye, surface.forward, surface.up, surface.half_x)
	if _floating():
		destination = _camera_fx_frame(destination)
	var seconds := _navigation_duration()
	var session_navigation: bool = host == null or host.session_switch_in_progress
	var resumed: bool = session_navigation and fly_glide and _resume_navigation_route(idx, destination, seconds)
	var route := _navigation_route(prev, idx) if session_navigation and not resumed else PackedVector3Array()
	# A navigation graph may include the wall's authored eye as its last node.
	#
	# The saved view replaces that endpoint; visiting both would land at Main
	# first and then take a second leg to the remembered zoom and pan.
	while not route.is_empty() and route[-1].distance_to(surface.eye) < 0.001:
		route.remove_at(route.size() - 1)
	if not fly_glide or not session_navigation:
		camera_motion.reset(camera_motion.frame)
	var distance: float = camera_motion.frame.transform.origin.distance_to(surface.eye)
	fly_from_distance = _wall_distance()
	fly_carry = camera_motion.velocity.length() * seconds / maxf(distance, .001)
	fly_t = 0.0
	if not resumed: camera_motion.retarget(destination, seconds, route)
	fly_dur = camera_motion.duration
	_display_camera_frame(_flight_frame())


func _refresh_navigation_destination() -> void:
	if not camera_motion.moving or active < 0 or active >= surfaces.size():
		return
	var surface: TerminalSurface3D = surfaces[active]
	var destination := _camera_base_frame(surface.eye, surface.forward, surface.up, surface.half_x)
	if _floating():
		destination = _camera_fx_frame(destination)
	var previous: Dictionary = camera_motion._target
	if destination.transform.is_equal_approx(previous.transform) and destination.rect.is_equal_approx(previous.rect):
		return
	fly_from_distance = _wall_distance()
	camera_motion.retarget_remaining(destination)
	fly_t = 0.0
	fly_dur = camera_motion.duration


func _step_navigation(dt: float) -> void:
	if not camera_motion.moving:
		return
	# Retarget the flight when the container has laid out and canonical
	# Main View framing has settled, even after the resize signal.
	#
	# Preserve the incoming derivatives and arrival time to avoid a cut at landing.
	_refresh_navigation_destination()
	_sync_tab_transition_deadline()
	camera_motion.advance(dt)
	fly_t = camera_motion.elapsed / camera_motion.duration
	if not camera_motion.moving:
		fly_t = 0.0
		fly_dur = 0.0
		fly_carry = 0.0
		var surface: TerminalSurface3D = surfaces[active]
		pose_eye = surface.eye
		pose_forward = surface.forward
		pose_up = surface.up
		pose_half_x = surface.half_x
	if camera_motion.moving:
		_display_camera_frame(_flight_frame())
	else:
		_apply_camera_fx()


func _render_test() -> void:
	push_error("Renderer comparison cases belong to the optional world plugin")
	get_tree().quit(1)


func _parse_world_arg(_arg: String) -> bool:
	return false


## Chromium pages the sheet composites beneath the canvas, topmost first, as
## WorkspacePane.video_layer_geometry() describes them. Returns how many fit.
func set_video_layers(layers: Array) -> int:
	if fx_mat != _video_layer_material:
		# A replaced wall material must not keep showing pages.
		if is_instance_valid(_video_layer_material):
			RenderUpdates.uniform(_video_layer_material, "page_count", 0)
			# A hidden wall must also release its viewport texture references.
			for slot in VIDEO_LAYERS:
				RenderUpdates.uniform(_video_layer_material, "page_%d" % slot, null)
		_video_layer_material = fx_mat
	if fx_mat == null: return 0
	# Depth of field blurs the canvas in the sheet itself, holes included; a
	# sharp page beneath would show through them. Typing effects only.
	var blurred: bool = fx_mat.get_shader_parameter("blur_pyramid_ready") == true \
		and float(fx_mat.get_shader_parameter("blur_radius")) > 0.0
	var count := 0 if blurred or not _floating() else mini(layers.size(), VIDEO_LAYERS)
	for slot in VIDEO_LAYERS:
		var layer: Dictionary = layers[slot] if slot < count else {}
		RenderUpdates.uniform(fx_mat, "page_%d" % slot, layer.get("texture"))
		if layer.is_empty(): continue
		var rect: Rect2 = layer.rect
		var clip: Rect2 = layer.clip
		RenderUpdates.uniform(fx_mat, "page_rect_%d" % slot, Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
		RenderUpdates.uniform(fx_mat, "page_clip_%d" % slot, Vector4(clip.position.x, clip.position.y, clip.size.x, clip.size.y))
		RenderUpdates.uniform(fx_mat, "page_radius_%d" % slot, float(layer.radius))
	RenderUpdates.uniform(fx_mat, "page_count", count)
	return count


func set_workspace_render_region(region: Rect2) -> void:
	if active < 0 or active >= surfaces.size():
		return
	var window := _sheet_window()
	surfaces[active].set_render_region(
		Rect2(window.position + region.position * window.size, region.size * window.size)
	)
	RenderUpdates.uniform(fx_mat, "workspace_canvas", true)
	RenderUpdates.uniform(fx_mat,
		"texture_region",
		Vector4(region.position.x, region.position.y, region.size.x, region.size.y),
	)


func _terminal_depth_plane() -> Vector3:
	var lift := Vector3.ZERO
	if active >= 0 and active < surfaces.size():
		lift = surfaces[active].global_basis.z * surfaces[active].surface_lift
	var axis := -cam.global_basis.z
	return Vector3((uv_origin + lift - cam.global_position).dot(axis), uv_du.dot(axis), uv_dv.dot(axis))


func _sync_terminal_defocus_tint() -> void:
	if not _floating() or not is_instance_valid(host.workspace_view): return
	const WARP_PARAMETERS := ["tex_size", "panel_rect", "curvature_rad", "ripple", "ripple_wavelength", "ripple_falloff", "ripple_phase", "wave_zoom", "cursor", "splash_rings", "splash_count", "splash_life", "splash_speed"]
	var active_tint: bool = terminal_effects.defocus_weight > 0.0
	var sheet := Vector2.ONE
	var depth_plane := Vector3.ZERO
	var canvas_inverse := Transform2D.IDENTITY
	var warp := {}
	if active_tint:
		sheet = _sheet_size()
		depth_plane = _terminal_depth_plane()
		canvas_inverse = host.workspace_view.canvas_root.get_global_transform().affine_inverse()
		for key in WARP_PARAMETERS:
			var value = fx_mat.get_shader_parameter(key)
			if value != null: warp[key] = value
	for pane in host.workspace_view.panes.values():
		if not pane.visible or not host.is_terminal_pane(pane.key): continue
		var mat: ShaderMaterial = pane.texture.material
		if mat == null: continue
		if not active_tint:
			RenderUpdates.uniform(mat, "defocus_weight", 0.0)
			continue
		terminal_effects.configure_defocus_tint(mat)
		var transform: Transform2D = canvas_inverse * pane.texture.get_global_transform()
		var start: Vector2 = transform * Vector2.ZERO / sheet
		var end: Vector2 = (transform * pane.texture.size) / sheet
		RenderUpdates.uniform(mat, "ink_sheet_rect", Vector4(start.x, start.y, end.x - start.x, end.y - start.y))
		RenderUpdates.uniform(mat, "ink_depth_plane", depth_plane)
		# Share all forward surface-warp parameters with the final sheet shader.
		for key in warp:
			RenderUpdates.uniform(mat, key, warp[key])
