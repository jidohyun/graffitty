extends "res://tests/terminal_space_smoke.gd"

class KitHost extends TestHost:
	func resolve_world(value: String) -> String:
		return value if value.begins_with("test-kit-") else super.resolve_world(value)

	func _plugin_entry(path: String) -> String:
		if path == "test-kit-starter": return "res://tests/fixtures/StarterWorld.tscn"
		if path == "test-kit-custom": return "res://tests/fixtures/CustomWorldKit.tscn"
		return super._plugin_entry(path)

func run() -> void:
	var host := KitHost.new()
	root.add_child(host)
	await create_timer(.5).timeout
	var id: int = host.active_session_id
	var pid: int = host.sessions[id].term.get_shell_pid()
	check(host.switch_world("test-kit-starter"), "Scene-only starter world loads")
	await create_timer(.5).timeout
	var world: Node = host.world
	check(world.authored_surface_count == 2, "Nested spaces are discovered without world glue")
	check(world.surfaces.size() == 1 and world.spare_places.size() == 1, "Changing world preserves existing tabs")
	check(host.workspace_view != null and world.tabs != null, "Tabs and full workspace are installed by default")
	check(world.terminal_effects != null and world.cam != null, "Default effects and camera are wired")
	check(world.get_node("Floor") != null, "Authored scenery remains in the world")
	host.create_session()
	await create_timer(2.0).timeout
	check(world.surfaces.size() == 2 and world.spare_places.is_empty(), "New tab uses the next authored space")
	check(world.active == 1, "Selecting a new tab visits the second camera pose")
	check(host.sessions[id].term.get_shell_pid() == pid, "World kit preserves the existing shell")
	var authored_transform: Transform3D = world.surfaces[0].global_transform
	host.create_session()
	await create_timer(2.0).timeout
	check(world.surfaces[2].global_transform.is_equal_approx(authored_transform), "Extra tabs preserve nested destination transforms")
	# Authored curves are transformed from local path coordinates into world space.
	var surface: Node3D = world.surfaces[1]
	var path := Path3D.new()
	path.name = "Approach"
	path.position = Vector3(1, 2, 3)
	path.curve = Curve3D.new()
	path.curve.add_point(Vector3(0, 0, 8))
	path.curve.add_point(Vector3(0, 0, 2))
	surface.add_child(path)
	surface.approach_path = NodePath("Approach")
	var route: PackedVector3Array = surface.camera_route_from(path.to_global(Vector3(0, 0, 8)))
	check(not route.is_empty() and route[-1].is_equal_approx(path.to_global(Vector3(0,0,2))), "Camera paths respect transformed spaces")
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	view._refresh_status(key)
	check(view.pane_status.has(key) and str(view.pane_status[key].label).contains(key), "A custom world's workspace publishes pane status for the pane strip mod")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-starter-world.png")
	if not OS.get_cmdline_user_args().has("--skip-pack"):
		# Load a real pack with an entry that does not exist as a loose source file.
		var pack_path := OS.get_cache_dir().path_join("starter-kit-%d.pck" % OS.get_process_id())
		var entry := "res://worlds/starter-kit-packed/world.tscn"
		var packer := PCKPacker.new()
		check(packer.pck_start(pack_path) == OK, "Create world pack")
		check(packer.add_file(entry, "res://tests/fixtures/StarterWorld.tscn") == OK and packer.flush() == OK, "Pack contains only authored scene")
		var manifest := FileAccess.open(pack_path.get_basename()+".json", FileAccess.WRITE)
		manifest.store_string(JSON.stringify({"api":1,"id":"starter-kit-packed","entry":entry}))
		manifest.close()
		check(host.switch_world(pack_path), "Scene-only PCK resolves default kit from core")
		await create_timer(.4).timeout
		check(host.workspace_view != null and host.sessions[id].term.get_shell_pid() == pid, "Packed world preserves workspace and live PTY")
		DirAccess.remove_absolute(pack_path)
		DirAccess.remove_absolute(pack_path.get_basename()+".json")
	check(host.switch_world("test-kit-custom"), "World kit accepts scene-authored replacements")
	await create_timer(.4).timeout
	check(host.world.fx_env == host.world.get_node("Environment").environment, "Authored environment is adopted")
	check(host.workspace_view.tab_bar == host.workspace_view.get_node("MyTabs"), "Custom UI remains wired to the kit")
	host.queue_free()
	await process_frame
	await process_frame
	check(error_watch.errors.is_empty(), "No Godot lifecycle errors: %s" % [error_watch.errors])
	print("TERMINAL_WORLD_KIT_PASS" if failures.is_empty() else "TERMINAL_WORLD_KIT_FAIL")
	quit(0 if failures.is_empty() else 1)
