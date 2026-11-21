extends "res://tests/unit/test_case.gd"
const World := preload("res://scenes/TerminalWorld.gd")
const Effects := preload("res://scenes/Effects.gd")

func test_session_request_keeps_departing_adaptive_tilt_until_topology_arrives() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	var reference := {"transform": Transform3D(Basis.IDENTITY, Vector3(0, 0, 4)), "rect": Vector4(-.5, -.5, 1, 1)}
	var fitted := {"transform": Transform3D(Basis.from_euler(Vector3(.12, -.18, 0)), Vector3(.4, .2, 3)), "rect": Vector4(-.6, -.4, 1.2, .8)}
	world.fx_camera._projection_dt = .25
	var before: Dictionary = world.fx_camera.project(reference, fitted)
	expect(not before.transform.basis.is_equal_approx(reference.transform.basis), "Fixture begins with visible adaptive tilt")
	world.begin_session_transition()
	# A rendered frame may fall between the switch event and its new topology.
	# A query must still return the departing pose, with no neutral-pose flash.
	var waiting: Dictionary = world.fx_camera.project(reference, fitted)
	expect(waiting.transform.is_equal_approx(before.transform) and waiting.rect.is_equal_approx(before.rect),
		"Waiting for the incoming session preserves the displayed tilt, pan and zoom")
	world.free()

class PendingCameraWorld extends World:
	var displayed := {}
	func _camera_base_frame(_eye: Vector3, _forward: Vector3, _up: Vector3, _half_x: float) -> Dictionary:
		return {"transform": Transform3D.IDENTITY, "rect": Vector4(-.5, -.5, 1, 1)}
	func _camera_fx_frame(value: Dictionary, _cursor_uv := Vector2.INF) -> Dictionary: return value
	func _display_camera_frame(value: Dictionary) -> void: displayed = value

func test_session_binding_keeps_the_captured_camera_on_screen() -> void:
	var world := PendingCameraWorld.new()
	world.cam = Camera3D.new()
	var departure := {"transform": Transform3D(Basis.from_euler(Vector3(.12, -.18, 0)), Vector3(.4, .2, 3)), "rect": Vector4(-.6, -.4, 1.2, .8)}
	world.session_transition_capture = {"camera": departure}
	world.fx_camera.reset(Vector2(1200, 750))
	world._apply_camera_fx()
	expect(world.displayed == departure, "A destination camera reset cannot replace the pending departure on screen")
	world.session_transition_capture.clear()
	world._apply_camera_fx()
	expect(world.displayed.transform == Transform3D.IDENTITY, "Normal camera updates resume after the departure is handed to the flight")
	world.cam.free()
	world.free()

class ReadyBackend extends RefCounted:
	var ready := true
	func sync_window_area(_host: Node) -> void: pass
	func note_activity(_host: Node) -> void: pass
	func transition_layout_ready(_host: Node) -> bool: return ready

class ReadyHost extends Node:
	var workspace_view: Node
	var session_backend := ReadyBackend.new()
	func _refresh_workspace_layout() -> void: pass

class ReadyTerminal extends Control:
	var painted := true
	func is_render_snapshot_ready() -> bool: return painted
	func get_grid_size() -> Vector2i: return Vector2i(80, 24)

func test_ready_transition_has_no_fixed_quiet_time_delay() -> void:
	var world := World.new()
	var host := ReadyHost.new()
	var viewport := SubViewport.new()
	var terminal := ReadyTerminal.new()
	viewport.add_child(terminal)
	preload("res://scenes/TerminalViewportUpdates.gd").configure(viewport, terminal)
	world.host = host
	world.term = terminal
	world.term_vp = viewport
	world.fx_cfg = Effects.new()
	host.session_backend.ready = false
	expect(not world._transition_sources_ready(), "Unacknowledged destination geometry still blocks preparation")
	host.session_backend.ready = true
	terminal.painted = false
	expect(not world._transition_sources_ready(), "Unpainted content still blocks preparation")
	terminal.painted = true
	expect(world._transition_sources_ready(), "Matching geometry and painted pixels proceed without an 80 ms sleep")
	terminal.size += Vector2(1, 0)
	expect(not world._transition_sources_ready(false), "A deferred geometry change invalidates the prepared arrival")
	expect(world._transition_sources_ready(false), "Stable geometry can be retried immediately")
	world._cancel_transition_preparation()
	world.free()
	host.free()
	viewport.free()

class PlacePeer extends Node:
	var url := "fixture-server"
	var workspace := "$1"
	var available_sessions := [{"id": "$1"}, {"id": "$2"}]

class PlaceBackend extends RefCounted:
	var is_remote := true
	var connection: Node

class PlaceHost extends Node:
	var session_backend := PlaceBackend.new()

func test_session_places_survive_terminal_replacement_and_session_rename() -> void:
	var world := World.new()
	var host := PlaceHost.new()
	var peer := PlacePeer.new()
	host.session_backend.connection = peer
	world.host = host
	var first := TerminalSurface3D.new()
	first.surface_id = "courtyard"
	first.set_meta("place", 0)
	first.session_id = 10
	var second := TerminalSurface3D.new()
	second.surface_id = "palace"
	second.set_meta("place", 1)
	world.surfaces = [first]
	world.spare_places = [second]
	world._seat_session(0)
	expect(world.surfaces[0] == first, "First session occupies the courtyard")
	# A switch replaces all terminal mirrors and initially reuses a free wall.
	peer.workspace = "$2"
	first.session_id = 20
	world._seat_session(0)
	expect(world.surfaces[0] == second and second.session_id == 20, "Second session takes the palace despite a reused mirror slot")
	expect(first in world.spare_places and first.session_id == -1, "The courtyard remains available for its session")
	peer.available_sessions = [{"id": "$2", "name": "renamed"}, {"id": "$1"}]
	peer.workspace = "$1"
	second.session_id = 30
	world._seat_session(0)
	expect(world.surfaces[0] == first and first.session_id == 30, "Returning session keeps its place after reordering, renaming and replacing panes")
	first.free()
	second.free()
	peer.free()
	host.free()
	world.free()

func test_session_arrives_at_reserved_place_even_if_another_tab_holds_it() -> void:
	var world := World.new()
	var host := PlaceHost.new()
	var peer := PlacePeer.new()
	host.session_backend.connection = peer
	world.host = host
	var first := TerminalSurface3D.new()
	first.surface_id = "courtyard"
	first.set_meta("place", 0)
	first.session_id = 10
	var second := TerminalSurface3D.new()
	second.surface_id = "palace"
	second.set_meta("place", 1)
	second.session_id = 20
	world.surfaces = [first, second]
	world.active = 0
	world._seat_session(1)
	expect(world.surfaces[1] == first and first.session_id == 20, "The session's resumed tab lands at the session's reserved place")
	expect(world.active == 1, "Reassigning content preserves the displayed physical surface")
	first.free()
	second.free()
	peer.free()
	host.free()
	world.free()

func test_tab_places_exchange_content_without_changing_the_visible_surface() -> void:
	var world := World.new()
	var first := TerminalSurface3D.new()
	first.surface_id = "first"
	first.session_id = 10
	var second := TerminalSurface3D.new()
	second.surface_id = "second"
	second.session_id = 20
	world.surfaces = [first, second]
	world.terminals = {"first": {"id": 10}, "second": {"id": 20}}
	world._swap_tab_places(0, 1)
	expect(world.surfaces[1] == first, "Destination stays on the currently viewed surface")
	expect(first.session_id == 20 and second.session_id == 10, "Content ownership follows the tab")
	expect(world.terminals.first.id == 20 and world.terminals.second.id == 10, "Retained terminals follow content ownership")
	world._swap_tab_places(1, 0)
	expect(world.surfaces[0] == first and first.session_id == 10, "Returning tabs also stay on the same surface")
	first.free()
	second.free()
	world.free()

func test_changing_effect_kind_clears_current_and_retiring_dust() -> void:
	var world := World.new()
	world.session_transition_active = true
	var outgoing := Node3D.new()
	var incoming := Node3D.new()
	var retired := Node3D.new()
	world.tab_fx_out = [outgoing]
	world.tab_fx_in = [incoming]
	world.tab_fx_stale = [{"layer": retired}]
	world.tab_fx_preparing = true
	var generation: int = world._tab_fx_generation
	world._set_session_transition_active(false)
	expect(world.tab_fx_out.is_empty() and world.tab_fx_in.is_empty() and world.tab_fx_stale.is_empty(), "Tabs inherit no session particles, including retiring ones")
	expect(not outgoing.visible and not incoming.visible and not retired.visible, "Particles hide immediately, before deferred deletion")
	expect(not world.tab_fx_preparing and world._tab_fx_generation > generation, "Pending session captures cannot publish into the tab effect")
	outgoing.free()
	incoming.free()
	retired.free()
	world.free()

func test_fly_away_uses_different_capture_modes_on_one_clock() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.session_transition_active = true
	world.fx_cfg.set_option("scene.session_switch", "effect", "fly_away")
	expect(world.dust_effect() and not world.depth_effect(), "Departure uses dust only")
	world._building_switch_arrival = true
	expect(world.depth_effect() and not world.dust_effect() and world.live_arrival(), "Arrival zooms live terminal panes")
	world._building_switch_arrival = false
	world.tab_fx_dur = world._transition_duration()
	expect(is_equal_approx(world.tab_fx_dur, World.FLY_AWAY_ARRIVAL_DELAY + 0.42), "Fly away hands over to the live surface once the zoom-in lands")
	expect(is_equal_approx(world._tab_departure_duration(), World.TAB_FX_LEAVE), "Fly away retains the original departure speed")
	expect(is_equal_approx(world._tab_arrival_duration(), 0.42), "Zoom arrival keeps its short reveal duration")
	expect(is_equal_approx(world._tab_arrival_start(), World.FLY_AWAY_ARRIVAL_DELAY), "Zoom arrival starts almost with the departure, replacing the old screen")
	var departure := world._tab_departure_duration()
	var total := world._transition_duration()
	world.fx_cfg.set_option("scene.session_switch", "effect", "fly_away_and_in")
	expect(not world.live_arrival(), "A flying glyph arrival retains its own drawing state")
	expect(is_equal_approx(world._tab_departure_duration(), departure), "Both flight effects use identical departure duration")
	expect(total < world._transition_duration(), "Removing the flying arrival shortens the overall transition")
	world.free()

func test_live_handoff_waits_for_arrival_not_departure() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	world.session_transition_active = true
	for effect in ["fly_away", "fly_away_and_in"]:
		world.fx_cfg.set_option("scene.session_switch", "effect", effect)
		world.tab_fx_dur = world._transition_duration()
		expect(is_equal_approx(world._tab_arrival_start() + world._tab_arrival_duration(), world.tab_fx_dur), effect + ": the live surface takes over exactly when the arrival lands")
	world.session_transition_active = false
	world.tab_fx_dur = world._transition_duration()
	expect(is_equal_approx(world._tab_arrival_start() + world._tab_arrival_duration(), world.tab_fx_dur), "push_pull: the live surface takes over when the dolly lands")
	world.free()

func test_session_and_tab_effects_are_mutually_exclusive() -> void:
	var world := World.new()
	world.fx_cfg = Effects.new()
	expect(world.depth_effect() and not world.dust_effect(), "Tabs default to zoom, without dust")
	expect(world.live_arrival(), "Push/pull arrives with live terminal output")
	world.session_transition_active = true
	expect(world.dust_effect() and not world.depth_effect(), "Sessions use dust, without tab zoom")
	world.fx_cfg.set_option("scene.session_switch", "effect", "none")
	expect(not world.dust_effect() and not world.depth_effect(), "Disabling session animation does not enable tab animation")
	world.session_transition_active = false
	expect(world.depth_effect(), "The tab choice is independent of the session choice")
	world.free()
