extends Node
## Native windows stay hidden; Metal still renders their viewport textures.
## The launcher installs the native guard before Godot creates its first window.

const INSTANCE_META := "graffitty_e2e_background_renderer"


static func requested() -> bool:
	return OS.get_name() == "macOS" and OS.get_environment("GRAFFITTY_E2E_BACKGROUND") == "1"


static func enabled() -> bool:
	return requested() and DisplayServer.get_name() != "headless"


## A nested client still needs a real renderer as well as the native guard.
static func rendering_arguments() -> PackedStringArray:
	if not requested():
		return []
	return [
		"--disable-render-loop",
		"--rendering-driver",
		"metal",
		"--rendering-method",
		"forward_plus",
		"--max-fps",
		"60",
		"--audio-driver",
		"Dummy",
	]


## The loaded guard removes its own DYLD entry before Godot launches helpers.
## Re-arm only Godot children. Passing the environment through env's arguments
## avoids changing this process's environment while native worker threads run.
static func create_godot_process(arguments: PackedStringArray) -> int:
	var executable := OS.get_executable_path()
	if not requested():
		return OS.create_process(executable, arguments)
	var library := OS.get_environment("GRAFFITTY_E2E_NATIVE_LIBRARY")
	if library.is_empty() or not FileAccess.file_exists(library):
		push_error("Background Godot child requires the native guard library")
		return -1
	var libraries := PackedStringArray([library])
	for other in OS.get_environment("DYLD_INSERT_LIBRARIES").split(":", false):
		if other != library:
			libraries.append(other)
	var command := PackedStringArray(["DYLD_INSERT_LIBRARIES=" + ":".join(libraries), executable])
	command.append_array(arguments)
	return OS.create_process("/usr/bin/env", command)


static func install(tree: SceneTree) -> void:
	if not enabled() or tree.has_meta(INSTANCE_META):
		return
	# An inherited marker is insufficient: the constructor must have run in
	# this process too, otherwise a nested client could open a visible window.
	if OS.get_environment("GRAFFITTY_E2E_GUARD_ACTIVE") != str(OS.get_process_id()):
		push_error("Background E2E rendering requires the native window guard in this process")
		tree.quit(1)
		return
	if RenderingServer.is_render_loop_enabled():
		push_error("Background E2E rendering requires --disable-render-loop")
		tree.quit(1)
		return
	tree.set_meta(INSTANCE_META, true)
	var renderer: Node = new()
	tree.root.add_child.call_deferred(renderer)


func _ready() -> void:
	get_tree().node_added.connect(_prepare_node, CONNECT_DEFERRED)
	_prepare_tree(get_tree().root)
	# Queue our draw after every other node processes. Deferring directly from
	# process_frame queues it before CanvasItem redraws, exposing stale pixels.
	process_priority = 2147483647


func _prepare_tree(node: Node) -> void:
	_prepare_node(node)
	for child in node.get_children():
		_prepare_tree(child)


## Deferred additions can be freed before dispatch; a typed Node argument
## rejects the freed reference before is_instance_valid gets to examine it.
func _prepare_node(node) -> void:
	if not is_instance_valid(node):
		return
	if node is Window:
		node.always_on_top = false
		RenderingServer.viewport_set_update_mode(
			node.get_viewport_rid(),
			RenderingServer.VIEWPORT_UPDATE_ALWAYS,
		)
	if node.has_method("_set_world_awake"):
		node.set("background_skip", false)
		node.call("_set_world_awake", true)


func _process(delta: float) -> void:
	_draw.call_deferred(delta)


func _draw(delta: float) -> void:
	# Registering a host enables rendering on demand. Hidden E2E runs own
	# their frame clock instead, including waits for frame_post_draw and movies.
	OS.low_processor_usage_mode = false
	RenderingServer.force_draw(false, delta)
