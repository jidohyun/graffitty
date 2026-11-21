extends "res://tests/unit/test_case.gd"
## `[world] path`, power worlds and SwitchWorld menu items accept a world id.
const Host := preload("res://scenes/TerminalHost.gd")


func test_values_without_a_separator_or_pck_suffix_are_world_ids() -> void:
	for value in ["bistro", "flat-3d", "my_world"]:
		expect(Host.is_world_id(value), value + " is a world id")
	for value in ["", "/w/bistro.pck", "bistro.pck", "worlds/bistro", "C:\\w\\bistro"]:
		expect(not Host.is_world_id(value), "'%s' is not a world id" % value)


func test_discovered_world_ids_resolve_to_their_path() -> void:
	var previous := OS.get_environment("XDG_DATA_HOME")
	var data := cache_directory().path_join("graffitty-world-id-%d" % OS.get_process_id())
	var folder := data.path_join("graffitty/worlds/test-id-world")
	DirAccess.make_dir_recursive_absolute(folder)
	var pack := folder.path_join("test-id-world.pck")
	FileAccess.open(pack, FileAccess.WRITE).store_string("")
	FileAccess.open(folder.path_join("test-id-world.json"), FileAccess.WRITE).store_string(
		JSON.stringify({ "api": Host.API_VERSION, "id": "test-id-world", "name": "Test" }))
	OS.set_environment("XDG_DATA_HOME", data)
	var host = Host.new()
	expect(host.resolve_world("test-id-world") == pack, "An id resolves to the discovered pack")
	expect(host.resolve_world("flat-2d") == "flat-2d", "Built-in ids stay as they are")
	expect(host.resolve_world(pack) == pack, "Paths stay as they are")
	expect(host.resolve_world("no-such-world").is_empty(), "An unknown id resolves to nothing")
	host.current_plugin = pack
	expect(host.current_world_id() == "test-id-world", "The loaded pack reports its manifest id")
	host.current_plugin = "flat-3d"
	expect(host.current_world_id() == "flat-3d", "A built-in world is its own id")
	host.free()
	OS.set_environment("XDG_DATA_HOME", previous)
	for file in ["test-id-world.pck", "test-id-world.json"]:
		DirAccess.remove_absolute(folder.path_join(file))
	for directory in [folder, folder.get_base_dir(), data.path_join("graffitty"), data]:
		DirAccess.remove_absolute(directory)
