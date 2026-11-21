extends SceneTree
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")
var failures := 0
class FakeTerminal extends Control:
	signal frame_changed
class QuietWorld extends "res://scenes/TerminalWorld.gd":
	func _ready(): pass
	func _process(_dt): pass
	func _exit_tree(): pass
func check(ok: bool, message: String):
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize():
	var scratch := OS.get_cache_dir().path_join("idle-rendering-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, scratch.path_join(kind))
	call_deferred("run")
func run():
	var existing := Node.get_orphan_node_ids()
	var vp := SubViewport.new()
	root.add_child(vp)
	var terminal := FakeTerminal.new()
	vp.add_child(terminal)
	Updates.configure(vp, terminal)
	check(vp.render_target_update_mode == SubViewport.UPDATE_ONCE, "Initial terminal frame is requested once")
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	Updates.set_visible(vp, true)
	check(vp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Repeated visible layout refresh does not redraw idle terminal")
	terminal.frame_changed.emit()
	check(vp.render_target_update_mode == SubViewport.UPDATE_ONCE, "Changed terminal pixels wake its viewport")
	Updates.set_visible(vp, false)
	terminal.frame_changed.emit()
	check(vp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Hidden terminal output does not wake its viewport")
	Updates.set_visible(vp, true)
	check(vp.render_target_update_mode == SubViewport.UPDATE_ONCE, "Showing terminal requests its latest pixels")
	var world := QuietWorld.new()
	root.add_child(world)
	world.cam = Camera3D.new()
	world.add_child(world.cam)
	world.scenery_vp = SubViewport.new()
	world.add_child(world.scenery_vp)
	world.ink_active = true
	world.world_awake = true
	for i in 3: world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Focused static scenery sleeps")
	world.cam.position.x += 1
	world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Camera movement wakes scenery immediately")
	for i in 3: world._update_scenery_view()
	world._scenery_dirty = true
	world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ONCE, "Dirty scenery redraws once")
	world.scenery_continuous = true
	world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Procedural scenery can request continuous animation")
	world.scenery_continuous = false
	var player := AnimationPlayer.new()
	var library := AnimationLibrary.new()
	var animation := Animation.new()
	animation.length = 2.0
	library.add_animation("motion", animation)
	player.add_animation_library("", library)
	world.add_child(player)
	world._scenery_node_added(player)
	player.play("motion")
	world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Playing scenery animation remains live")
	player.stop()
	for i in 3: world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Stopped scenery animation returns to sleep")
	world._scenery_scales = Vector2(0.8, 0.5)
	world.scenery_vp.scaling_3d_scale = 0.8
	world.cam.position.x += 1
	world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.8), "An isolated camera nudge keeps full resolution")
	for i in 2:
		world.cam.position.x += 1
		world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.5), "Sustained camera motion renders scenery at the motion scale")
	world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.5), "A brief pause keeps the motion scale")
	world.cam.position.x += 1
	world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.5), "Motion resumed within the hold keeps the motion scale")
	world._scenery_moved_msec -= 10000
	world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.8) and world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ONCE, "Resting frame redraws once at full resolution")
	for i in 2: world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_DISABLED, "Full-resolution scenery sleeps")
	world.cam.cull_mask = 1
	world._update_scenery_view()
	check(is_equal_approx(world.scenery_vp.scaling_3d_scale, 0.8), "A pass change alone keeps full resolution")
	world.fly_dur = 1.0
	world._update_scenery_view()
	check(world.scenery_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Camera flight remains live")
	world.fx_camera.free()
	world.free()
	vp.free()
	await process_frame
	await process_frame
	for id in Node.get_orphan_node_ids():
		if id in existing or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	quit.call_deferred(failures)
