extends RefCounted
## Prepare real server sessions off camera; reveal them through sidebar input.
const LiveSessions := preload("res://scenes/session/LiveSessionMenu.gd")
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")
var replay: SceneTree
var prepared: Dictionary = {}
var transitions: Array[Dictionary] = []
var panel: Window

func _init(owner: SceneTree) -> void:
	replay = owner

func peer() -> Node:
	return LiveSessions.transport(replay.host)

func remember(name: String) -> void:
	prepared[name] = {"id": peer().workspace, "pane": replay.host.pane_focus, "place": place_name()}

func place_name() -> String:
	var world: Node = replay.host.world
	return str(world.surfaces[world.active].id)

func name_current(name: String) -> bool:
	var result: Dictionary = await peer().request_action("session_rename", {"name": peer().workspace, "new_name": name})
	if not replay.check(result.get("type") != "error", "Name the initial demo session " + name): return false
	remember(name)
	return true

func create(name: String) -> bool:
	if not replay.check(not replay.capture_active, "Sessions are created before capture"): return false
	var previous: String = peer().workspace
	var result: Dictionary = await peer().request_action("session_new", {"name": name})
	if not replay.check(result.get("type") != "error", "Prepare session " + name): return false
	if not await replay.until(func(): return peer().workspace != previous and ready(), "Prepared session is ready: " + name): return false
	remember(name)
	await replay.camera_at_rest()
	return true

func ready() -> bool:
	var host: Node = replay.host
	return (not host.session_switch_in_progress and host.world.tab_fx_t < 0.0 and not host.world.tab_fx_preparing
		and host.world.tab_fx_stale.is_empty()
		and (host.world._transition_stale.is_empty() if "_transition_stale" in host.world else true)
		and host.active_terminal() != null and host.pane_focus != "")

func show_compact() -> bool:
	panel = PanelWindow.open(replay.host, "sessions")
	if not await replay.until(func(): return is_instance_valid(panel) and is_instance_valid(panel._desktop), "Sessions panel docks on the left"): return false
	var space: Control = panel._desktop.space
	if space.widths.left >= space.COMPACT_WIDTH: space.toggle_fold("left")
	return await replay.until(func(): return (panel.compact and panel._desktop.side == "left"
		and not panel.view.hit_keys().has("new-" + peer().url)
		and prepared.values().all(func(session): return panel.view.hit_rect(row_key(session.id)).has_area())),
		"All prepared sessions appear in the compact sidebar without a create button")

func row_key(id: String) -> String:
	return "session-%s-%s" % [peer().url, id]

func select(name: String) -> bool:
	var target: String = prepared[name].id
	var from: String = peer().workspace
	if from == target: return true
	if not await replay.until(func(): return panel.view.hit_rect(row_key(target)).has_area(), "Sidebar contains prepared session " + name): return false
	var count: int = peer().available_sessions.size()
	var from_place := place_name()
	var camera: Camera3D = replay.host.world.cam
	var eye := camera.global_position if is_instance_valid(camera) else Vector3.ZERO
	var seen := {"departure": false, "arrival": false, "camera_distance": 0.0, "camera_travel_frames": 0, "isolated_departure_frames": 0}
	var camera_frames: Array = []
	var start: int = replay.movie_frame()
	var observe := func():
		var world: Node = replay.host.world
		if is_instance_valid(camera): seen.camera_distance = maxf(seen.camera_distance, eye.distance_to(camera.global_position))
		if replay.capture_active and is_instance_valid(camera) and camera_frames.size() < 60:
			var rotation := camera.global_basis.get_euler()
			camera_frames.append({"frame": replay.movie_frame(), "rotation": [rotation.x, rotation.y, rotation.z],
				"pending_capture": not world.session_transition_capture.is_empty(), "flight": world.camera_motion.moving,
				"focus_depth": world.terminal_effects.focus_depth, "blur_radius": world.terminal_effects.blur_radius,
				"depth_range": world.terminal_effects.depth_range, "defocus_weight": world.terminal_effects.defocus_weight})
		if not world.session_transition_active or world.tab_fx_t < 0.0: return
		if "transition_ink" in world and world.transition_ink != null and not world.tab_fx_out.is_empty():
			var isolated: bool = world.tab_fx_out.all(func(layer): return (layer.layers & world.transition_ink.MASK) != 0 and layer._material().get_shader_parameter("screen_dof") == true)
			if isolated: seen.isolated_departure_frames += 1
		if world.camera_motion.moving: seen.camera_travel_frames += 1
		seen.departure = seen.departure or (is_instance_valid(world._transition_out) if "_transition_out" in world else not world.tab_fx_out.is_empty())
		seen.arrival = seen.arrival or (not world.tab_fx_preparing and (is_instance_valid(world._transition_in) if "_transition_in" in world else not world.tab_fx_in.is_empty()))
	replay.process_frame.connect(observe)
	var rect: Rect2 = panel.view.hit_rect(row_key(target))
	await replay.click(panel.view.get_global_transform_with_canvas() * rect.get_center())
	var clicked: int = replay.movie_frame()
	if replay.capture_active: await replay.say(name + " session clicked")
	var switched: bool = await replay.until(func(): return peer().workspace == target and ready(), "Click selects prepared session " + name)
	if switched: await replay.camera_at_rest()
	replay.process_frame.disconnect(observe)
	if not switched: return false
	replay.check(peer().available_sessions.size() == count, "Session click preserves every prepared session")
	replay.check(place_name() == prepared[name].place, "Session returns to its prepared world location: " + name)
	if replay.host.current_world_id() == "edinburgh-castle":
		replay.check(from_place != place_name() and seen.camera_distance > 1.0 and seen.camera_travel_frames > 10,
			"Castle camera travels to another area: " + name)
	if replay.capture_active:
		replay.check(seen.departure and seen.arrival, "Session departure and arrival animate: " + name)
		if "transition_ink" in replay.host.world and replay.host.world.transition_ink != null:
			replay.check(seen.isolated_departure_frames > 0, "Outgoing glyphs use an isolated screen-space blur pass: " + name)
		transitions.append({"name": name, "from": from, "to": target, "start_frame": start,
			"click_frame": clicked, "end_frame": replay.movie_frame(), "departure": seen.departure,
			"arrival": seen.arrival, "prepared_count": count, "compact": panel.compact,
			"from_place": from_place, "to_place": place_name(), "camera_distance": seen.camera_distance,
			"camera_travel_frames": seen.camera_travel_frames, "camera_frames": camera_frames,
			"isolated_departure_frames": seen.isolated_departure_frames})
	return true

func retained(name: String) -> bool:
	return peer().available_sessions.any(func(session): return session.id == prepared[name].id and session.panes > 0)

func evidence() -> Dictionary:
	return {"prepared": prepared, "transitions": transitions}
