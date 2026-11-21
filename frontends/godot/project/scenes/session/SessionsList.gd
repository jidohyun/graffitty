extends RefCounted
## Presentation model only; server-provided named sessions remain authoritative.
const Names := preload("res://scenes/remote/ConnectionName.gd")

static func icon_path(group: Dictionary) -> String:
	var platform := str(group.get("platform", ""))
	return "res://scenes/icons/%s.svg" % ("os-" + platform if platform in ["macos", "windows", "linux"] else "monitor")

## `hidden` hosts hold a session without any window showing it.
static func collect(hosts: Array, saved: Array, include_local := false, hidden: Array = []) -> Array:
	var groups := {}
	var candidates := hosts.duplicate()
	for host in hosts:
		if not is_instance_valid(host): continue
		var client: Node = host.get_parent()
		if client != null and "local_return" in client and client.local_return != null and is_instance_valid(client.local_return.client):
			var parked: Node = client.local_return.client.host
			if parked not in candidates: candidates.append(parked)
	for host in candidates:
		if not is_instance_valid(host) or host.is_queued_for_deletion() or not "session_backend" in host: continue
		var backend: RefCounted = host.session_backend
		if not backend.is_remote or not "connection" in backend: continue
		var connection: Node = backend.connection
		if not is_instance_valid(connection): continue
		var peers: Array = connection.connections if "connections" in connection else [connection]
		# A window showing several servers views one of them: its active tab's.
		var viewed: Node = connection
		if "owners" in connection:
			viewed = connection.owners.get(host.workspace_layout.active if host.get("workspace_layout") != null else -1, connection.selected)
		for peer in peers:
			if not is_instance_valid(peer): continue
			var key: String = peer.url
			if key.is_empty(): continue
			var local := key == "shared://local"
			if not groups.has(key):
				groups[key] = {"id": key, "local": local, "name": "This computer" if local else Names.display({"name": peer.display_name if "display_name" in peer else "", "hostname": peer.server_hostname if "server_hostname" in peer else "", "url": key}), "connected": false, "sessions": [], "peer": peer, "host": host}
			var group: Dictionary = groups[key]
			group.connected = group.connected or peer.connected
			if peer.connected or not group.has("platform"):
				group.platform = peer.server_platform if "server_platform" in peer else ""
			if not peer.connected: continue
			group.peer = peer
			group.host = host
			for value in peer.available_sessions:
				var session := str(value.id)
				var existing := -1
				for i in group.sessions.size():
					if group.sessions[i].id == session: existing = i
				var attached: bool = session == peer.workspace
				var label := preload("res://scenes/session/SessionLabel.gd").name_of(value)
				# Attached: a connection holds this session. Viewing: a window shows it
				# now; `viewers` are those windows, so each highlights only its own.
				var shown: bool = attached and peer == viewed and host not in hidden
				var row := {"id": session, "name": label, "peer": peer, "host": host, "attached": attached, "viewing": shown, "viewers": [host] if shown else []}
				if existing < 0: group.sessions.append(row)
				else:
					var viewers: Array = group.sessions[existing].viewers + row.viewers
					if row.viewing or (attached and not group.sessions[existing].viewing): group.sessions[existing] = row
					group.sessions[existing].viewers = viewers
					group.sessions[existing].viewing = not viewers.is_empty()
	for settings in saved:
		var key := str(settings.get("url", ""))
		if key.is_empty(): continue
		if groups.has(key):
			if str(groups[key].get("platform", "")).is_empty(): groups[key].platform = settings.get("platform", "")
			continue
		groups[key] = {"id": key, "local": false, "name": Names.display(settings), "platform": settings.get("platform", ""), "connected": false, "sessions": [], "peer": null, "host": null}
	if include_local and not groups.has("shared://local"):
		# A computer with no open local presentation can still create a session.
		# Do not invent a connected transport or a list of sessions.
		groups["shared://local"] = {"id": "shared://local", "local": true, "name": "This computer", "platform": OS.get_name().to_lower(), "connected": false, "sessions": [], "peer": null, "host": null}
	var order := []
	for settings in saved:
		var url := str(settings.get("url", ""))
		if not order.has(url): order.append(url)
	var result: Array = groups.values()
	result.sort_custom(func(a, b):
		if a.local != b.local: return a.local
		var ai := order.find(a.id)
		var bi := order.find(b.id)
		if ai != bi: return ai >= 0 and (bi < 0 or ai < bi)
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return result


## The public sessions list as `window` sees it: `viewing` is the session that
## window shows. With no window, every session some window shows.
static func rows(groups: Array, saved_urls: Array, window: Node) -> Array:
	var result := []
	for group in groups:
		var sessions := []
		for row in group.sessions:
			sessions.append({"id": row.id, "name": row.name, "viewing": row.viewing if window == null else window in row.viewers})
		result.append({"id": group.id, "name": group.name, "local": group.local, "connected": group.connected,
			"platform": str(group.get("platform", "")), "saved": saved_urls.has(group.id), "sessions": sessions})
	return result
