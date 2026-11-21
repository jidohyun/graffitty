extends "res://tests/unit/test_case.gd"
const Motion := preload("res://scenes/CameraMotion.gd")

class World extends "res://scenes/SpatialTerminalWorld.gd":
	var searches := 0
	func _route(from: int, to: int) -> PackedInt32Array:
		searches += 1
		return super._route(from, to)

func frame_at(point: Vector3) -> Dictionary:
	return Motion.pose(point, Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.3, 1, .6))

func fixture() -> World:
	var world := World.new()
	world.nav_nodes = PackedVector3Array([Vector3.ZERO, Vector3(20,0,0), Vector3(20,0,20), Vector3(10,0,10)])
	world._navigation_graph.replace([[[3, 14.0]], [[3, 14.0]], [[3, 14.0]], [[0, 14.0], [1, 14.0], [2, 14.0]]])
	for i in 3:
		var surface := TerminalSurface3D.new()
		surface.surface_id = "view-%d" % i
		world.surfaces.append(surface)
		world.nav_node_for_surface[surface.id] = i
	world.camera_motion.reset(frame_at(Vector3.ZERO))
	world._load_authored_routes({"routes": [{"from": "view-0", "to": "view-1", "points": [[10, 4, 0]], "allow_wall_crossing": true}]})
	return world

func test_authored_route_reverses_but_third_destination_uses_graph() -> void:
	var world := fixture()
	var route := world._navigation_route(0, 1)
	expect(route == PackedVector3Array([Vector3(10,4,0)]) and world.searches == 0, "Normal authored flight bypasses Dijkstra")
	expect(world.navigation_allows_wall_crossing, "Only the authored route grants the collision exception")
	world.camera_motion.retarget(frame_at(world.nav_nodes[1]), 2.1, route)
	world.camera_motion.advance(.8)
	expect(world._resume_navigation_route(0, frame_at(world.nav_nodes[0]), 2.1), "A→B→A keeps the existing curve")
	expect(world.searches == 0 and world.navigation_allows_wall_crossing, "Reversal keeps this route's collision policy")
	expect(not world._resume_navigation_route(2, frame_at(world.nav_nodes[2]), 2.1), "A third destination cannot reuse the old route")
	world._navigation_route(0, 2)
	expect(world.searches == 1 and world.navigation_route_kind == "graph", "Interrupted third-destination flight invokes Dijkstra")
	expect(not world.navigation_allows_wall_crossing, "The authored collision exception never leaks into graph routing")

func test_normal_routes_are_cached_and_authored_paths_are_bidirectional() -> void:
	var world := fixture()
	var route := world._navigation_route(0, 2)
	expect(world._navigation_route(0, 2) == route and world.searches == 1, "Repeated normal flights reuse a stable route")
	world.camera_motion.reset(frame_at(world.nav_nodes[1]))
	expect(world._navigation_route(1, 0) == PackedVector3Array([Vector3(10,4,0)]), "Normal return uses the authored reverse route")
	world.camera_motion.reset(frame_at(Vector3(8,0,8)))
	world._navigation_route(0, 1)
	expect(world.navigation_route_kind == "graph" and not world.navigation_allows_wall_crossing, "Panned departures away from the route use graph routing")

func test_bidirectional_authored_route_keeps_its_forward_order() -> void:
	var world := World.new()
	world.nav_node_for_surface = {"a": 0, "b": 1}
	world._load_authored_routes({"routes": [{"from": "a", "to": "b", "points": [[1, 0, 0], [2, 0, 0], [3, 0, 0]]}]})
	var forward := PackedVector3Array([Vector3(1,0,0), Vector3(2,0,0), Vector3(3,0,0)])
	var backward := forward.duplicate()
	backward.reverse()
	expect(world._authored_navigation_route(0, 1).points == forward, "Building the return route leaves the forward route in order")
	expect(world._authored_navigation_route(1, 0).points == backward, "The return route is the forward route reversed")
