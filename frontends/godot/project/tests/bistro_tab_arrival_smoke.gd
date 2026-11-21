extends "res://tests/terminal_space_smoke.gd"
## Run through tests/godot/bistro_tab_arrival_e2e.py, which starts a private
## session server and provides the installed Bistro pack.

func _initialize() -> void:
	# Keep the runner's isolated XDG folders: the app finds the private
	# session server through them.
	OS.add_logger(error_watch)
	_start_test.call_deferred()


func run() -> void:
	root.unfocusable = true
	root.always_on_top = true
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	check(wrapper.host != null, "Client attaches to the session server")
	if wrapper.host == null:
		quit(1)
		return
	var host: Node = wrapper.host
	await create_timer(.5).timeout
	check(host.switch_world("bistro"), "Bistro loads")
	host.instant_workspace_switch = true
	deadline = Time.get_ticks_msec() + 30000
	while host.get_tabs().size() < 14 and Time.get_ticks_msec() < deadline:
		await wrapper.connection.request_action("create", {"kind": "tab"})
		for frame in range(4): await process_frame
	check(host.get_tabs().size() == 14, "Fourteen Bistro tabs open")
	if host.get_tabs().size() != 14:
		quit(1)
		return
	host.instant_workspace_switch = false
	root.size = Vector2i(1280, 800)
	await create_timer(2.0).timeout
	var world = host.world
	world.fx_cfg.set_option("scene.tab_switch", "effect", "push_pull")
	world.tab_fx = true
	check(world.active == 13, "Departure is Bistro tab 14")
	world.film_dt = 1.0 / 60.0
	var viewed_surface: Node = world.surfaces[world.active]
	world._goto(12, false)
	check(world.surfaces[world.active] == viewed_surface, "Bistro tabs keep the same authored surface")
	check(world.depth_effect() and not world.dust_effect(), "Bistro tabs use only zoom, not session dust")
	var folder := OS.get_environment("GRAFFITTY_TAB_ARRIVAL_ARTIFACTS")
	if not folder.is_empty(): DirAccess.make_dir_recursive_absolute(folder)
	var sample := 0
	var checked_arrival := false
	var arrival_title_scale := Vector2.ZERO
	var stable_composite := true
	while world.tab_fx_t >= 0:
		await process_frame
		if world.tab_fx_t >= 0:
			stable_composite = stable_composite and world.ink_active
		var arrival_duration: float = world._tab_arrival_duration()
		var arrival_phase: float = (world.tab_fx_t - (world.tab_fx_dur - arrival_duration)) / arrival_duration
		if not checked_arrival and arrival_phase > 0.4 and arrival_phase < 0.7:
			var panels := 0
			for layer in world.tab_fx_in:
				if not layer.has_meta("panel"): continue
				panels += 1
				var flight: float = layer._material().get_shader_parameter("fly")
				check(flight > 0.1 and flight < 0.9, "Incoming background is still fading halfway through arrival")
			check(panels > 0, "Arrival includes captured pane backgrounds")
			arrival_title_scale = host.workspace_view.pane_titles[host.pane_focus].scale
			checked_arrival = true
		if not folder.is_empty() and DisplayServer.get_name() != "headless" and sample % 3 == 0:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(folder.path_join("%02d.png" % sample))
		sample += 1
	world.film_dt = 0.0
	check(checked_arrival, "Sampled the actual 14 to 13 arrival")
	check(stable_composite, "Terminal composition stays consistent throughout flight")
	await create_timer(.3).timeout
	check(world.ink_active and world.tab_fx_t < 0, "Destination returns to its live terminal")
	# Sheet curvature can change the projection by a fraction of a pixel.
	var settled_scale: Vector2 = host.workspace_view.pane_titles[host.pane_focus].scale
	check(absf(arrival_title_scale.x - settled_scale.x) * 20.0 < 0.25, "Arrival title matches the settled size within a quarter pixel")
	world._goto(13, false)
	await create_timer(0.18).timeout
	var departing: Array = world.tab_fx_out.duplicate()
	var arriving: Array = world.tab_fx_in.duplicate()
	var previous := {}
	for layer in departing + arriving:
		if layer.has_meta("panel"): previous[layer] = layer._material().get_shader_parameter("fly")
	check(not previous.is_empty(), "Interrupted arrival includes pane backgrounds")
	world._goto(12, false)
	for entry in world.tab_fx_stale:
		if previous.has(entry.layer):
			check(is_equal_approx(entry.fly, previous[entry.layer]), "Interrupted background keeps its displayed fade")
	await create_timer(2.0).timeout
	check(world.ink_active and world.tab_fx_t < 0 and world.walls[world.surfaces[12].id].visible, "Interrupted switch restores the destination")
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	for unused in range(5): await process_frame
	check(error_watch.errors.is_empty(), "No runtime errors: %s" % [error_watch.errors])
	quit(0 if failures.is_empty() else 1)
