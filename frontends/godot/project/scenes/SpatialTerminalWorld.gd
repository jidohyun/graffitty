extends "res://scenes/TerminalWorld.gd"
## Shared authored destinations and graph-routed camera flights for 3D worlds.
const F_IRRADIANCE := Color(0.62, 0.66, 0.74)
const F_FILL_COLOR := Color(0.55, 0.62, 0.78)
const F_FILL_DIR := Vector3(0.5, 0.35, 0.6)
var nav_nodes: PackedVector3Array = PackedVector3Array()
var _navigation_graph: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
var fly_path: PackedVector3Array = PackedVector3Array()
var use_navgraph := true
var world_dir := ""

var authored_surface_count := 0
var nav_node_for_surface: Dictionary = { }
var authored_routes: Dictionary = {}
var _normal_routes: Dictionary = {}
var _flight_endpoints := Vector2i(-1, -1)
## The place node the last flight was sent to; -1 before the first flight.
var _resting_place := -1
var navigation_route_kind := "graph"
var navigation_allows_wall_crossing := false


func create_chromium_presenter() -> Node:
	var presenter := preload("res://scenes/ChromiumSurface3D.gd").new()
	presenter.world = self
	add_child(presenter)
	return presenter


func _new_terminal_surface_source(tab_ordinal := -1) -> int:
	var ordinal := surfaces.size() if tab_ordinal < 0 else tab_ordinal
	var place := ordinal % maxi(authored_surface_count, 1)
	# Pane surfaces and tab reorders need not match authored destination indices.
	for i in surfaces.size():
		if int(surfaces[i].get_meta("place", -1)) == place:
			return i
	return ordinal % maxi(mini(authored_surface_count, surfaces.size()), 1)


func _load_navgraph() -> void:
	## Graph nodes and edges are generated visibility data. Authored scene
	## surfaces match destination nodes by their stable source names.
	nav_nodes.clear()
	_navigation_graph.clear()
	nav_node_for_surface.clear()
	authored_routes.clear()
	_normal_routes.clear()
	_resting_place = -1
	_flight_endpoints = Vector2i(-1, -1)
	var txt := FileAccess.get_file_as_string(world_dir + "/navgraph.json")
	if txt.is_empty():
		push_warning("no navigation graph; flights will be straight lines and clip geometry")
		return
	var g = JSON.parse_string(txt)
	if not g is Dictionary:
		push_warning("navigation graph is not an object; flights will be straight lines")
		return
	var names: Array = g.get("walls", [])
	for i in names.size():
		nav_node_for_surface[str(names[i])] = i
	for n in g.get("nodes", []):
		nav_nodes.append(Vector3(n[0], n[1], n[2]))
	var adjacency: Array = []
	adjacency.resize(nav_nodes.size())
	for i in adjacency.size():
		adjacency[i] = []
	for e in g.get("edges", []):
		var i: int = e[0]
		var j: int = e[1]
		var d: float = e[2]
		adjacency[i].append([j, d])
		adjacency[j].append([i, d])
	_navigation_graph.replace(adjacency)
	var routes_file := world_dir.path_join("camera_routes.json")
	if FileAccess.file_exists(routes_file):
		_load_authored_routes(JSON.parse_string(FileAccess.get_file_as_string(routes_file)))


func _load_authored_routes(data: Variant) -> void:
	if not data is Dictionary: return
	for entry in data.get("routes", []):
		if not entry is Dictionary: continue
		var from: int = nav_node_for_surface.get(entry.get("from", ""), -1)
		var to: int = nav_node_for_surface.get(entry.get("to", ""), -1)
		if from < 0 or to < 0 or from == to: continue
		var points := PackedVector3Array()
		var valid := true
		for point in entry.get("points", []):
			if not point is Array or point.size() != 3:
				valid = false
				break
			for value in point:
				if not (value is float or value is int) or not is_finite(float(value)): valid = false
			if not valid: break
			points.append(Vector3(point[0], point[1], point[2]))
		if not valid: continue
		var route := {"points": points, "allow_wall_crossing": entry.get("allow_wall_crossing", false) == true}
		authored_routes[Vector2i(from, to)] = route
		if entry.get("bidirectional", true):
			# Packed arrays are shared: reversing in place would reverse the forward route too.
			var returning := points.duplicate()
			returning.reverse()
			authored_routes[Vector2i(to, from)] = {"points": returning, "allow_wall_crossing": route.allow_wall_crossing}


func _route(from: int, to: int) -> PackedInt32Array:
	if from < 0 or to < 0 or from >= nav_nodes.size() or to >= nav_nodes.size(): return PackedInt32Array()
	return _navigation_graph.route(from, to)


func _path_length(p: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, p.size()):
		total += p[i].distance_to(p[i - 1])
	return total


func _nearest_nav(point: Vector3) -> int:
	## The node the camera is closest to right now.
	##
	## An interrupted flight has left the node it set off from behind, so routing
	## from that node again would send the camera back the way it came before it
	## turned around.
	var best := -1
	var best_d := INF
	for i in nav_nodes.size():
		var d := nav_nodes[i].distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = i
	return best


func _nearest_place(point: Vector3) -> int:
	var best := -1
	var best_d := INF
	for place in nav_node_for_surface.values():
		var d := nav_nodes[place].distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = place
	return best


func _nav_node_for(s: TerminalSurface3D) -> int:
	## Authored screens are named in the graph.
	##
	## A screen that is not — a tab duplicated at runtime — routes from whichever
	## node is nearest its eye, which for a duplicate is its source's own node.
	if nav_node_for_surface.has(s.id):
		return int(nav_node_for_surface[s.id])
	return _nearest_nav(s.eye)


func _navigation_route(prev: int, idx: int) -> PackedVector3Array:
	var points := PackedVector3Array()
	navigation_route_kind = "graph"
	navigation_allows_wall_crossing = false
	_flight_endpoints = Vector2i(-1, -1)
	if not use_navgraph or nav_nodes.is_empty():
		return points
	var destination := _nav_node_for(surfaces[idx])
	var departure := _nav_node_for(surfaces[prev]) if prev >= 0 and prev < surfaces.size() else -1
	var origin: Vector3 = camera_motion.frame.transform.origin
	# Scene-authored views can move independently of generated graph anchors.
	var departure_eye := nav_nodes[departure] if departure >= 0 else Vector3.ZERO
	if departure >= 0 and surfaces[prev].view_pose != null: departure_eye = surfaces[prev].eye
	if departure < 0 and not camera_motion.moving and _resting_place != destination and _nearest_place(origin) == _resting_place:
		# A session switch replaces the surface being left before routing, so no
		# previous surface exists: the camera still rests where its last flight
		# landed.
		#
		# A saved view or a graph overview may sit metres from that place's eye and
		# still belongs to it while no other place is nearer.
		departure = _resting_place
		departure_eye = origin
	_resting_place = destination
	if not camera_motion.moving and departure >= 0 and origin.distance_to(departure_eye) < 0.5:
		var pair := Vector2i(departure, destination)
		_flight_endpoints = pair
		var authored := _authored_navigation_route(pair.x, pair.y)
		if not authored.is_empty():
			navigation_route_kind = "authored"
			navigation_allows_wall_crossing = authored.get("allow_wall_crossing", false)
			points = authored.points.duplicate()
		else:
			# Stable endpoints use the same route on every visit. Only unusual
			# mid-flight destinations route again from the current camera.
			if not _normal_routes.has(pair):
				var normal := PackedVector3Array()
				for node in _route(pair.x, pair.y): normal.append(nav_nodes[node])
				_normal_routes[pair] = normal
				var reverse := Vector2i(pair.y, pair.x)
				if not _normal_routes.has(reverse):
					var returning := normal.duplicate()
					returning.reverse()
					_normal_routes[reverse] = returning
			navigation_route_kind = "normal"
			points = _normal_routes[pair].duplicate()
		fly_path = points
		return points
	var from_node := _nearest_nav(origin)
	var route := _route(from_node, destination)
	for node in route:
		points.append(nav_nodes[node])
	# The shared motion component supplies the exact displayed departure.
	while points.size() >= 2 and (origin - points[0]).dot(points[1] - points[0]) > 0:
		points.remove_at(0)
	fly_path = points
	return points


func _authored_navigation_route(from: int, to: int) -> Dictionary:
	return authored_routes.get(Vector2i(from, to), {})


func _resume_navigation_route(idx: int, destination: Dictionary, seconds: float) -> bool:
	if not use_navgraph or not camera_motion.moving or _flight_endpoints.x < 0: return false
	var target := _nav_node_for(surfaces[idx])
	if target != _flight_endpoints.x and target != _flight_endpoints.y: return false
	# Keep the route's scoped collision policy while braking/reversing on it.
	return camera_motion.retarget_on_path(destination, seconds)


func _wall_distance() -> float:
	## The mean depth of the wall's own geometry, which
	## is what the focus point is built from. Mixed across a flight, as
	## background.inc mixes flightFromDistance into it on the same quintic.
	if active < 0 or surfaces.is_empty():
		return 1.0
	var s: TerminalSurface3D = surfaces[active]
	var d: float = maxf(s.eye.distance_to(focus_points[s.id]), 0.1)
	if fly_dur > 0.0:
		d = lerpf(fly_from_distance, d, fly_t * fly_t * (3.0 - 2.0 * fly_t))
	return d


func _navigation_duration() -> float:
	# Walls are apart here: a session flight never outruns its departure. The
	# live wall then waits for the camera (see _sync_tab_transition_deadline).
	var seconds := super._navigation_duration()
	if host == null or host.session_switch_in_progress:
		seconds = maxf(seconds, _switch_timeline().departure_duration(seconds))
	return seconds
