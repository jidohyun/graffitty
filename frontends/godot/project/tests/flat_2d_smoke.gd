extends SceneTree
var failures: Array[String] = []
var folder := OS.get_environment("GRAFFITTY_2D_ARTIFACTS")
class ErrorWatch extends Logger:
	var errors: Array[String] = []
	func _log_error(_function: String,_file: String,_line: int,code: String,rationale: String,_editor_notify: bool,_error_type: int,_backtraces: Array[ScriptBacktrace]) -> void:
		errors.append(rationale if not rationale.is_empty() else code)
	func _log_message(_message: String,_error: bool) -> void: pass
var watch := ErrorWatch.new()
func _initialize() -> void:
	OS.add_logger(watch)
	OS.set_environment("XDG_CONFIG_HOME",OS.get_cache_dir().path_join("flat-2d-test-%d" % OS.get_process_id()))
	OS.set_environment("XDG_STATE_HOME",OS.get_cache_dir().path_join("flat-2d-state-%d" % OS.get_process_id()))
	root.size = Vector2i(1280,800)
	if folder.is_empty(): folder = OS.get_cache_dir().path_join("graffitty-flat-2d")
	DirAccess.make_dir_recursive_absolute(folder)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ")+message)
	if not ok: failures.append(message)
func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join(name+".png"))
func run() -> void:
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	if wrapper.host == null: await wrapper.host_ready
	var host = wrapper.host
	await create_timer(2).timeout
	var session: int = host.active_session_id
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	terminal.send_text("Write-Output 'Flat world / Flat 2D parity'; Clear-Host; Write-Output 'Graffitty rendering parity'; Write-Output 'Colors, text, pane chrome, graph wires'\r")
	await create_timer(2).timeout
	terminal.set_process(false)
	await capture("flat")
	check(host.switch_world("flat-2d"),"Switch to built-in Flat 2D")
	await create_timer(1).timeout
	check(host.world.camera_2d is Camera2D,"Real Camera2D")
	check(host.world.cam == null,"No 3D render camera")
	check(host.world_viewport.disable_3d,"3D rendering disabled")
	check(host.active_terminal() == terminal and terminal.get_shell_pid() == pid,"PTY and terminal survive switching")
	await capture("flat-2d")
	compare_images()
	var world: Node = host.world
	world.fx_enabled = true
	world.effects_2d.enabled = true
	terminal.set_process(true)
	var before_key: float = world.fx_last_key
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_3
	key.shift_pressed = true
	key.unicode = 35
	world.term_vp.push_input(key,true)
	await create_timer(.1).timeout
	check(world.fx_last_key > before_key,"Native terminal typing drives the 2D effects")
	for point in [Vector2(0,0),Vector2(300,200),Vector2(1100,600)]:
		check(world.sheet_point_at(world.sheet_window_fraction(point)).distance_to(point)<.01,"2D input projection round trip")
	world.pinch_zoom(1.5)
	await process_frame
	check(world.camera_2d.zoom.x>1.4,"Pinch zoom uses Camera2D")
	host.workspace_view.pan_workspace(Vector2(100,50),Vector2(500,300))
	await process_frame
	check(host.workspace_view.overview,"Pan enters navigation")
	await capture("flat-2d-pan")
	host.workspace_view.show_main()
	host.create_session()
	await create_timer(1.8).timeout
	check(host.get_tabs().size()==2,"Create and animate a second tab")
	host.create_terminal_window(host.pane_focus)
	await create_timer(.2).timeout
	check(host.workspace_view.pane_rects.size()==2,"Multiple panes share the 2D canvas")
	world.tab_fx = true
	host.select_workspace(host.workspace_layout.containing("%%%d" % session))
	var handoff_seen := false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if world.tab_fx_t >= 0.0: continue
		if is_instance_valid(world._transition_in) and not world.sheet_2d.visible:
			handoff_seen = true
		elif handoff_seen: break
	check(handoff_seen and world.sheet_2d.visible, "Arrival stays visible until the live sheet has drawn")
	await create_timer(0.2).timeout
	check(host.active_session_id==session,"Switch back to original tab")
	host.world.effects_2d.pulse(Vector2(.5,.5))
	await create_timer(.1).timeout
	check(host.world.effects_2d.particles.sparks.size()>0,"Typing particles run in 2D")
	await capture("flat-2d-effects")
	check(host.switch_world(""),"Switch back to Flat")
	await create_timer(.5).timeout
	check(host.world.cam != null and not host.world.cam.get_viewport().disable_3d,"Restores 3D viewport")
	check(host.active_terminal()==terminal,"Original terminal retained after round trip")
	check(watch.errors.is_empty(),"No engine/script/shader errors: "+str(watch.errors))
	print("FLAT_2D_SMOKE "+JSON.stringify({"failures":failures}))
	quit(0 if failures.is_empty() else 1)

func compare_images() -> void:
	var a := Image.load_from_file(folder.path_join("flat.png"))
	var b := Image.load_from_file(folder.path_join("flat-2d.png"))
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	var x := a.get_data()
	var y := b.get_data()
	var total := 0.0
	var changed := 0
	var max_error := 0
	for i in range(0,mini(x.size(),y.size()),4):
		var error := maxi(absi(x[i]-y[i]),maxi(absi(x[i+1]-y[i+1]),absi(x[i+2]-y[i+2])))
		total += absi(x[i]-y[i])+absi(x[i+1]-y[i+1])+absi(x[i+2]-y[i+2])
		if error>2: changed += 1
		max_error = maxi(max_error,error)
	var pixels := a.get_width()*a.get_height()
	var result := {"width":a.get_width(),"height":a.get_height(),"mean_absolute_error_255":total/(pixels*3.0),"pixels_over_2_fraction":float(changed)/pixels,"maximum_channel_error":max_error}
	print("VISUAL_PARITY "+JSON.stringify(result))
	var file := FileAccess.open(folder.path_join("parity.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"  "))
	check(result.mean_absolute_error_255<.5 and result.pixels_over_2_fraction<.001,"Resting view matches within rasterization tolerance")
