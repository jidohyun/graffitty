extends SceneTree
const World := preload("res://scenes/TerminalWorld.gd")
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")

class ImageTerminal extends Control:
	func set_image_plane_material(_material: ShaderMaterial) -> void: pass
	func get_shell_pid() -> int: return 1

class View extends Control:
	func terminal_origin(_key: String) -> Vector2: return Vector2.ZERO
	func terminal_scale(_key: String) -> float: return 1.0

class Host extends Node:
	var workspace_view: Control
	var sessions: Dictionary

class ImageWorld extends World:
	func _shown_windows() -> Array: return ["%1"]
	func _sheet_size() -> Vector2: return Vector2(800, 600)
	func _effect_surface_frame(_uv: Vector2) -> Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3(-4, 3, -10))


var failures := 0

func expect(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		print("FAIL ", message)

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-image-redraw-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func run() -> void:
	var original_orphans := Node.get_orphan_node_ids()
	var terminal := ImageTerminal.new()
	terminal.size = Vector2(800, 600)
	var viewport := SubViewport.new()
	viewport.set_meta("terminal_frame_events", true)
	var view := View.new()
	var host := Host.new()
	host.workspace_view = view
	host.sessions = {1: {"term": terminal, "vp": viewport}}
	var world := ImageWorld.new()
	world.host = host
	world.cam = Camera3D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(world.cam)
	world.uv_du = Vector3(8, 0, 0)
	world.uv_dv = Vector3(0, -6, 0)
	world.fx_enabled = true
	world.fx_plane_lift = 0.1
	# No terminal events are emitted. Simulate each UPDATE_ONCE being consumed
	# while the client zooms in and eases back to its resting projection.
	for frame in 121:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var t := float(frame) / 120.0
		world.fx_cam_zoom = 1.0 + sin(t * PI) * 0.8
		world._sync_graphics_planes()
		expect(viewport.render_target_update_mode == SubViewport.UPDATE_ONCE,
			"Image projection redraws on camera frame %d without PTY traffic" % frame)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	world._sync_graphics_planes()
	expect(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Settled image projection leaves the terminal viewport asleep")
	Updates.set_visible(viewport, false)
	world.fx_cam_zoom = 1.5
	world._sync_graphics_planes()
	expect(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"Camera updates preserve hidden viewport suspension")
	world.cam.free()
	world.fx_camera.free()
	world.free()
	host.free()
	view.free()
	viewport.free()
	terminal.free()
	# TerminalWorld pre-creates controls that _ready() normally parents.
	for id in Node.get_orphan_node_ids():
		if id in original_orphans or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	print("IMAGE_PLANE_REDRAW_PASS" if failures == 0 else "IMAGE_PLANE_REDRAW_FAIL")
	quit(0 if failures == 0 else 1)
