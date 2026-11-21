class_name TerminalCameraController
extends Node
## Pixel-space terminal-camera state for Godot's Camera3D backend.
## It resolves a camera pose; Godot still owns nodes, rendering and compositing.

var zoom := 1.0
var target_zoom := 1.0
var pan := Vector2.ZERO
var render_pan := Vector2.ZERO
var animated_cursor := Vector2.ZERO
var cursor_initialized := false
var follow_owner := ""
var _focus_containment := false

func follow_pane(key: String) -> void:
	if key != follow_owner:
		_focus_containment = not follow_owner.is_empty()
		follow_owner = key
var tilt := Vector2.ZERO
var drift_radius := 0.0
var drift_phase := 0.0
var drift := Vector2.ZERO
var shake := Vector2.ZERO
var shake_left := 0.0
var shake_amplitude := 0.0
var rng := 0x9e3779b9
var cursor_anchor_pending := false
var cursor_anchor_set := false
var cursor_anchor_y := 0.0
var cursor_anchor_grid_y := 0.0
var framing_returning := false
var was_typing := false
var initialized := false
var _viewport_size := Vector2.ZERO
var follow_threshold := Vector2(0.5, 0.5)
var overscroll := 0.5
## Focused pane bounds, including its title, in sheet pixels. Empty keeps single-sheet framing.
var follow_rect := Rect2()
## Navigation can place panes beyond the original sheet bounds.
var unbounded_pan := false
## Extra breathing room below the unobstructed viewport's top edge.
var follow_top_inset := 0.0
## Usable screen area, in the same full-viewport coordinate system as the camera.
var visible_rect := Rect2()
## Absolute framing destination resolved by the Rust content-fit solver.
var adaptive_enabled := false
var adaptive_target := Vector3.ZERO
# Unsmoothed framing goal. Adaptive presentation interpolates the final
# projected frame once, rather than correcting this controller's moving frame.
var framing_pan := Vector2.ZERO
var framing_tilt := Vector2.ZERO
var _projection_dt := 0.0
var adaptive_zoom_in_seconds := 10.0
var adaptive_zoom_out_seconds := 1.5
# Rust eases the complete projection correction (pan, zoom and tilt), not just
# its release scale. Render queries publish targets; advance() owns the clock.
var _projection: RefCounted = ClassDB.instantiate("SceneAdaptiveProjection")


func configure(settings: Dictionary) -> void:
	follow_threshold = Vector2(
		float(settings.get("left_preserving_cursor_follow_threshold", 0.5)),
		float(settings.get("top_preserving_cursor_follow_threshold", 0.5)),
	).clampf(0.0, 1.0)
	overscroll = maxf(float(settings.get("overscroll", 0.5)), 0.0)
	adaptive_zoom_in_seconds = float(settings.get("adaptive_zoom_in_seconds", 10.0))
	adaptive_zoom_out_seconds = float(settings.get("adaptive_zoom_out_seconds", 1.5))


func project(reference: Dictionary, fitted: Dictionary, focus := Vector3.ZERO) -> Dictionary:
	var result: Dictionary = _projection.project(reference, fitted, focus, _projection_dt, adaptive_zoom_in_seconds, adaptive_zoom_out_seconds)
	_projection_dt = 0.0
	return result


func _follow_target(
	cursor: Vector2,
	viewport: Vector2,
	camera_zoom: float,
	anchored: bool,
	cell := Vector2.ZERO,
) -> Vector2:
	return preload("res://scenes/CameraMotion.gd")._core().follow_target(
		cursor, viewport, camera_zoom, cell, follow_rect, visible_rect,
		follow_threshold, cursor_anchor_y, anchored, follow_top_inset,
		unbounded_pan and was_typing)


## The pans that keep a cursor cell wholly in view, with room that grows with
## the zoom; unbounded without a cell.
static func cell_bounds(
	cursor: Vector2,
	viewport: Vector2,
	cell: Vector2,
	camera_zoom: float,
	visible := Rect2(),
) -> PackedVector2Array:
	return preload("res://scenes/CameraMotion.gd")._core().cursor_pan_bounds(cursor, viewport, cell, camera_zoom, visible)


static func decay_step(current: float, target: float, dt: float, decay: float) -> float:
	if dt <= 0.0 or decay <= 0.0:
		return current
	return current + (target - current) * (1.0 - pow(2.0, -10.0 * dt / decay))


static func clamp_pan(value: float, extent: float, camera_zoom: float, overscroll := 0.0) -> float:
	if extent <= 0.0:
		return 0.0
	var half_window := extent / (2.0 * maxf(camera_zoom, 1e-4))
	var slack := overscroll * minf(half_window, extent * 0.5) if overscroll > 0.0 else 0.0
	var lo := extent - half_window if camera_zoom < 1.0 else half_window
	var hi := half_window if camera_zoom < 1.0 else extent - half_window
	lo -= slack
	hi += slack
	return extent * 0.5 if lo >= hi else clampf(value, lo, hi)


## An offset on top of the eased pan, damped back to keep [lo, hi] in view but
## never inverted into a pan of its own.
static func decorated_pan(value: float, offset: float, lo: float, hi: float) -> float:
	var decorated := value + offset
	var bounded := clampf(decorated, lo, hi)
	return clampf(bounded, minf(value, decorated), maxf(value, decorated))


## Drop the eased adaptive correction. It is relative to the reference frame
## and content it was fitted to; carried onto another tab or session it aims
## at the old content from the new view.
func reset_projection() -> void:
	_projection.reset()
	_projection_dt = 0.0


func interrupt_projection() -> void:
	_projection.interrupt()
	_projection_dt = 0.0


func resume_projection() -> void:
	_projection.resume()
	_projection_dt = 0.0


func reset(viewport: Vector2) -> void:
	_viewport_size = viewport
	zoom = 1.0
	target_zoom = 1.0
	_projection.reset()
	_projection_dt = 0.0
	pan = viewport * 0.5
	render_pan = pan
	framing_pan = pan
	framing_tilt = Vector2.ZERO
	animated_cursor = pan
	cursor_initialized = false
	_focus_containment = false
	tilt = Vector2.ZERO
	drift_radius = 0.0
	drift_phase = 0.0
	drift = Vector2.ZERO
	shake = Vector2.ZERO
	shake_left = 0.0
	shake_amplitude = 0.0
	cursor_anchor_pending = false
	cursor_anchor_set = false
	framing_returning = false
	was_typing = false
	initialized = true


## One eligible key. It may start a jolt, never restarting a running one. The
## framing is advance()'s: it takes the anchor once, as typing begins.
func typed(amplitude: float, seconds: float) -> void:
	if shake_left <= 0.0 and amplitude > 0.0 and seconds > 0.0:
		shake_left = seconds
		shake_amplitude = amplitude


func _frand() -> float:
	# xorshift32.
	rng = int((rng ^ (rng << 13)) & 0xffffffff)
	rng = int((rng ^ (rng >> 17)) & 0xffffffff)
	rng = int((rng ^ (rng << 5)) & 0xffffffff)
	return float(rng & 0xffffffff) / 4294967295.0 * 2.0 - 1.0


func advance(
	dt: float,
	cursor: Vector2,
	viewport: Vector2,
	cell: Vector2,
	new_target_zoom: float,
	tilt_limit: float,
	drift_target: float,
	drift_speed: float,
	typing: bool,
	transition_decay: float,
	constrain_cursor := true,
) -> void:
	dt = minf(maxf(dt, 0.0), 0.25)
	if not initialized:
		reset(viewport)
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return
	if _viewport_size != viewport:
		# The workspace canvas can resize while a new tab is being attached.
		#
		# Preserve normalized framing; easing from the old pixel centre creates a
		# hidden pan during the flight and a sideways jump at the handoff.
		if _viewport_size.x > 0.0 and _viewport_size.y > 0.0:
			var scale := viewport / _viewport_size
			pan *= scale
			render_pan *= scale
			animated_cursor *= scale
			cursor_anchor_grid_y *= scale.y
		_viewport_size = viewport
	if typing and not was_typing:
		# Entering the typing state holds the framing the eye already has. Later
		# keys leave it alone, or each would re-aim the camera mid-zoom.
		cursor_anchor_pending = true
		framing_returning = false
	elif not typing and was_typing:
		framing_returning = cursor_anchor_set
	was_typing = typing
	if cursor_anchor_pending:
		cursor_anchor_y = (cursor.y - pan.y) * zoom / viewport.y
		cursor_anchor_grid_y = cursor.y
		cursor_anchor_pending = false
		cursor_anchor_set = true
	if not unbounded_pan and not adaptive_enabled:
		pan.x = clamp_pan(pan.x, viewport.x, zoom, overscroll)
		pan.y = clamp_pan(pan.y, viewport.y, zoom, overscroll)
	# A state, including one a pinch edited, may zoom out to a quarter.
	var fitting := adaptive_enabled and typing and adaptive_target.z > 0.0
	target_zoom = adaptive_target.z if fitting else maxf(new_target_zoom, 0.25)
	var old_zoom := zoom
	var framing_decay := transition_decay
	if adaptive_enabled:
		framing_decay = adaptive_zoom_in_seconds if target_zoom > zoom else adaptive_zoom_out_seconds
	_projection_dt += dt
	zoom = decay_step(zoom, target_zoom, dt, framing_decay)
	# The anchor holds the cursor's screen height only while it stays on the line
	# it was taken on.
	#
	# Past that line the threshold owns the framing, which keeps what a command
	# printed above the cursor in view.
	if cursor_anchor_set and cell.y > 0.0 and absf(cursor.y - cursor_anchor_grid_y) > cell.y * 1.5:
		cursor_anchor_set = false
		framing_returning = false
	var visible_cell := cell if constrain_cursor else Vector2.ZERO
	# Resolve the destination once at TARGET zoom, keeping the cursor cell in
	# view there, then ease screen translation and zoom with the same decay:
	# every point of the page travels one curve.
	#
	# Correcting the pan afterwards, or following the current zoom's moving
	# target, adds a second motion.
	var destination := _follow_target(
		cursor,
		viewport,
		target_zoom,
		cursor_anchor_set and not framing_returning,
		visible_cell,
	)
	if fitting:
		destination = Vector2(adaptive_target.x, adaptive_target.y)
		cursor_anchor_set = false
		framing_returning = false
	var old_shift := (viewport * 0.5 - pan) * old_zoom
	var target_shift := (viewport * 0.5 - destination) * target_zoom
	var shift := Vector2(
		decay_step(old_shift.x, target_shift.x, dt, framing_decay),
		decay_step(old_shift.y, target_shift.y, dt, framing_decay),
	)
	pan = viewport * 0.5 - shift / zoom
	if not unbounded_pan and not adaptive_enabled:
		pan.x = clamp_pan(pan.x, viewport.x, zoom, overscroll)
		pan.y = clamp_pan(pan.y, viewport.y, zoom, overscroll)
	# Where effects that trail the camera aim: the cursor, eased like the pan.
	if not cursor_initialized:
		animated_cursor = cursor
		cursor_initialized = true
	else:
		animated_cursor = Vector2(
			decay_step(animated_cursor.x, cursor.x, dt, transition_decay),
			decay_step(animated_cursor.y, cursor.y, dt, transition_decay),
		)
	if framing_returning and absf(zoom - target_zoom) < 1e-5 and pan.distance_to(destination) < 1e-4:
		cursor_anchor_set = false
		framing_returning = false
	if shake_left > 0.0:
		shake_left -= dt
		shake = (
			Vector2.ZERO
			if shake_left <= 0.0
			else Vector2(_frand(), _frand()) * (shake_amplitude / zoom)
		)
	else:
		shake = Vector2.ZERO
	drift_radius = decay_step(drift_radius, drift_target if typing else 0.0, dt, transition_decay)
	if drift_radius > 0.01:
		drift_phase += dt * drift_speed
		drift = Vector2(sin(drift_phase), cos(drift_phase)) * (drift_radius / zoom)
	else:
		drift = Vector2.ZERO
	# Shake and drift decorate the eased pan. They may be damped to keep the
	# cursor cell in view; zoomed, the sum never passes the edge of the sheet.
	#
	# Focus can move the cursor across the whole sheet.
	#
	# Constrain the same eased cursor used by the camera effects, so the dock
	# boundary cannot turn that focus change into an immediate camera cut.
	if animated_cursor.distance_to(cursor) < 0.5: _focus_containment = false
	var box := cell_bounds(animated_cursor if _focus_containment else cursor, viewport, visible_cell, zoom, visible_rect)
	var decorated := Vector2(
		decorated_pan(pan.x, shake.x + drift.x, box[0].x, box[1].x),
		decorated_pan(pan.y, shake.y + drift.y, box[0].y, box[1].y),
	)
	render_pan = decorated
	if not unbounded_pan and not adaptive_enabled and absf(zoom - 1.0) > 1e-6:
		render_pan = Vector2(
			clamp_pan(decorated.x, viewport.x, zoom, overscroll),
			clamp_pan(decorated.y, viewport.y, zoom, overscroll),
		)
	# At fixed zoom, keep the cursor inside the space left by docks and chrome.
	# Adaptive mode eases its framing targets. An immediate clamp there
	# would make cursor or dock changes jump.
	if visible_rect.has_area() and not adaptive_enabled:
		render_pan = render_pan.clamp(box[0], box[1])
	# Aim the lean from the destination framing at target zoom, not the shrinking
	# offset of an intermediate zoom.
	#
	# The side of the view that holds the cursor comes closer; the destination
	# state's limit is 0 unless it leans.
	var framed := _follow_target(cursor, viewport, target_zoom, cursor_anchor_set)
	var lean := ((cursor - framed) * 2.0 * target_zoom / viewport).clampf(-1.0, 1.0)
	framing_pan = destination
	framing_tilt = Vector2(-lean.x * tilt_limit, -lean.y * tilt_limit)
	var tilt_target := framing_tilt
	tilt.x = decay_step(tilt.x, tilt_target.x, dt, transition_decay)
	tilt.y = decay_step(tilt.y, tilt_target.y, dt, transition_decay)
