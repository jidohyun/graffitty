extends "replay.gd"
var mouse := Vector2.ZERO
var imaginary := Vector2.ZERO
var anchored_content := Vector2.ZERO
var anchor_error := 0.0
var anchor_marker: Node2D
var content_marker: Node2D
class Marker extends Node2D:
	var ring := false
	func _draw() -> void:
		if ring: draw_arc(Vector2.ZERO,14,0,TAU,48,Color("ffcf66"),2,true)
		else:
			draw_line(Vector2(-10,0),Vector2(10,0),Color("55ddff"),2,true)
			draw_line(Vector2(0,-10),Vector2(0,10),Color("55ddff"),2,true)

## `center` is in view units; the default starts on the Main View.
func prepare(path: String, center := Vector2.INF) -> void:
	host.switch_world(path)
	await hold(.3)
	host.world.fx_enabled = false
	var view: Control = host.workspace_view
	view.overview = true
	view.navigation_zoom = .8
	view.navigation_center = view.size * .5 if not center.is_finite() else center
	view._apply_navigation()
	var term: Node = host.sessions[host.active_session_id].term
	term.send_text("printf '\\033[2J\\033[H'; i=0; while [ $i -lt 36 ]; do printf '%02d  ABCDEFGHIJ  0123456789  ABCDEFGHIJ  0123456789  ABCDEFGHIJ\\n' $i; i=$((i+1)); done\r")
	await hold(.3)
	if is_instance_valid(content_marker): content_marker.free()
	content_marker = Marker.new()
	view.canvas_root.add_child(content_marker)
	content_marker.z_index = 100
	if anchor_marker == null:
		anchor_marker = Marker.new()
		anchor_marker.ring = true
		overlay.add_child(anchor_marker)
	mouse = view.size * Vector2(.37,.43)
	imaginary = mouse
	anchored_content = view.canvas_point_at(mouse)
	content_marker.position = anchored_content
	anchor_marker.position = view.get_global_transform_with_canvas() * imaginary
	await point_at(view.get_global_transform_with_canvas() * mouse)

func gesture(factor: float, translation := Vector2.ZERO, native_dispatch := false) -> void:
	var view: Control = host.workspace_view
	var previous := imaginary
	imaginary += translation
	anchor_marker.position = view.get_global_transform_with_canvas() * imaginary
	var event := InputEventMagnifyGesture.new()
	event.position = view.get_global_transform_with_canvas() * mouse
	event.factor = factor
	# Same payload as AppKit -> Rust, including physical-pixel metadata on Retina.
	var physical := root.get_final_transform() * view.get_global_transform_with_canvas()
	event.set_meta("pinch_previous",physical * previous)
	event.set_meta("pinch_center",physical * imaginary)
	event.set_meta("pinch_pan",root.get_final_transform().basis_xform(translation))
	if native_dispatch:
		# Follow the Rust bridge through DisplayServer's window routing. Direct
		# Viewport.push_input skips this boundary and cannot verify it unfocused.
		event.window_id = root.get_window_id()
		event.position = physical * mouse
		Input.parse_input_event(event)
	else:
		root.push_input(event,true)
	await hold(.045)
	var error: float = view.view_point(anchored_content).distance_to(imaginary)
	anchor_error = maxf(anchor_error,error)
	if error >= 2.0: check(false,"Content drifted from the remembered zoom point by %.2f pixels" % error)
