# SPDX-License-Identifier: GPL-2.0-or-later
# Adapted from Blender node_add.cc and node_relationships.cc (see docs/developers/automation-and-extensions/blender-node-links.md).
extends RefCounted
const Ports := preload("res://scenes/GraphPorts.gd")
## Visual reroutes are separate from AgentGraph's authoritative terminal edges.

static func normalize(data: Dictionary) -> void:
	if not data.has("reroutes"): data.reroutes = {}
	# Retire frame metadata; pane and reroute positions are already absolute.
	data.erase("groups")
	data.erase("parents")
	if not data.has("serial"): data.serial = 0
	for key in data.routes:
		var route: Array = data.routes[key]
		for i in route.size():
			if route[i] is Vector2:
				var id := allocate(data, "reroute")
				data.reroutes[id] = {"position": route[i]}
				route[i] = id

static func allocate(data: Dictionary, prefix: String) -> String:
	data.serial = int(data.get("serial", 0)) + 1
	return prefix + ":" + Crypto.new().generate_random_bytes(16).hex_encode()

static func remove_reroute(data: Dictionary, id: String) -> void:
	for route in data.routes.values(): route.erase(id)
	data.reroutes.erase(id)

static func prune(data: Dictionary, edges: Dictionary) -> void:
	normalize(data)
	var used := {}
	for key in data.routes.keys():
		if not edges.has(key):
			data.routes.erase(key)
			continue
		for id in data.routes[key]: used[id] = true
	for id in data.reroutes.keys():
		if not used.has(id): data.reroutes.erase(id)

static func segments(data: Dictionary, edges: Dictionary) -> Array:
	# Shared reroute outputs correspond to one visual socket. Fan-out stems are
	# represented once, with all authoritative terminal edges passing through it.
	var unique := {}
	for key in edges:
		var edge: Dictionary = edges[key]
		var chain: Array = [Ports.endpoint(edge, true)]
		chain.append_array(data.routes.get(key, []))
		chain.append(Ports.endpoint(edge, false))
		for i in range(1, chain.size()):
			var id: String = str(chain[i - 1]) + ">" + str(chain[i])
			if not unique.has(id): unique[id] = {"from": chain[i - 1], "to": chain[i], "edges": [], "muted": true}
			unique[id].edges.append(key)
			unique[id].muted = unique[id].muted and edge.get("muted", false)
	return unique.values()

static func insert_cuts(data: Dictionary, cuts: Array) -> Array:
	# Blender groups intersections by the originating output socket, creates one
	# reroute for each group, and places it at the average intersection location.
	var sockets := {}
	for cut in cuts:
		if not sockets.has(cut.segment.from): sockets[cut.segment.from] = []
		sockets[cut.segment.from].append(cut)
	var inserted: Array = []
	for source in sockets:
		var position := Vector2.ZERO
		var keys := {}
		for cut in sockets[source]:
			position += Vector2(cut.position)
			for key in cut.segment.edges: keys[key] = true
		position /= sockets[source].size()
		var id := allocate(data, "reroute")
		data.reroutes[id] = {"position": position}
		for key in keys:
			var route: Array = data.routes.get(key, []).duplicate()
			var index := route.find(source) + 1 if data.reroutes.has(source) else 0
			route.insert(index, id)
			data.routes[key] = route
		inserted.append(id)
	return inserted
