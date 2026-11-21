extends RefCounted
## Candidates, ranking and actions for the prefix command line; CommandLine.gd
## draws them.
##
## Input starting with a digit, `%` or `@` lists tabs and panes the tmux way
## (`2`, `2.1`, `%ID`, `@ID`, `@ID.1`; numbers start at 1).
##
## Anything starting with `$` lists live sessions by name; anything else lists
## menu commands.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Prefix := preload("res://scenes/WorkspacePrefix.gd")
const Targets := preload("res://scenes/PaneTargets.gd")

## Matches the tiers of the native FuzzyRanker (crates/fuzzy-rank).
enum Tier { EXACT, PREFIX, SUBSTRING, FUZZY, UNFILTERED }

var host: Node
## What the line shows; while Tab cycles it previews the selected row.
var text := ""
## What the rows were ranked by. Typing replaces it; cycling does not.
var query := ""
## {candidate, tier, indices} in rank order. `indices` are character
## positions in the candidate's `label`.
var rows: Array[Dictionary] = []
## Row chosen with Tab or the arrows; -1 while the user has only typed.
var selected := -1
## The chosen row's identity (see identity()), which survives re-ranking and
## renumbering; `selected` is only where that row sits right now.
var _chosen := ""
var _chosen_tier := Tier.FUZZY
## The chosen target closed: Enter must not fall back to another row.
var _chosen_lost := false
## Tab previews the chosen row's label in the line.
var _cycling := false
var _ranker: RefCounted = ClassDB.instantiate("FuzzyRanker")
var _rank_labels := PackedStringArray()


## What a row is, independent of rank and numbering: tab IDs and pane keys
## never change, unlike positions such as 2.1. Commands are their menu label.
static func identity(candidate: Dictionary) -> String:
	match str(candidate.kind):
		"tab":
			return "tab:%d" % int(candidate.id)
		"pane":
			return "pane:" + str(candidate.key)
		"session":
			return "session:%d:%s" % [candidate.peer.get_instance_id(), candidate.name]
		"checkpoint":
			return "checkpoint:%s:%s" % [candidate.tag, candidate.path]
	return "command:" + str(candidate.label)


static func number_mode(value: String) -> bool:
	return not value.is_empty() and (value[0] in ["%", "@"] or value[0] in "0123456789")


static func checkpoint_arg_query(value: String) -> bool:
	var space := value.find(" ")
	if space <= 0:
		return false
	return command_needle(value.substr(0, space)).to_lower() == "restorecheckpoint"


func placeholder_text() -> String:
	# Words are translated; the %id, @id and $session syntax stays literal.
	var parts := PackedStringArray([tr("command")])
	var tabs: Array = host.get_tabs()
	if not tabs.is_empty():
		var last: Dictionary = host.workspace_layout.tab(int(tabs.back().id))
		var panes := Layout.keys(last.get("tree", {})).size()
		parts.append(tr("%d tab") % tabs.size())
		if panes > 0:
			parts.append(tr("%d.%d pane") % [tabs.size(), panes])
	parts.append_array(["%id", "@id", "$session"])
	return "   ·   ".join(parts)


## PascalCase name of a menu label without a registry action, such as
## "Edit::Input Settings…" (InputSettings), matching action names such as
## NewPaneRight. The top-level menu is left out unless `qualified`.
static func command_name(parts: PackedStringArray, qualified := false) -> String:
	var words := parts if qualified or parts.size() < 2 else parts.slice(1)
	var name := ""
	for word in " ".join(words).split(" ", false):
		var clean := ""
		for character in word:
			var code := character.unicode_at(0)
			if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or (code > 127 and character != "…"):
				clean += character
		if not clean.is_empty():
			name += clean[0].to_upper() + clean.substr(1)
	return name


## Command queries ignore word separators: "new pane right" finds NewPaneRight.
static func command_needle(value: String) -> String:
	return value.replace(" ", "").replace("_", "").replace("-", "")


## Candidate strings cross into Rust only when the candidate set changes.
func rank(needle: String, items: PackedStringArray, typos: bool) -> Array:
	if items != _rank_labels:
		_rank_labels = items
		_ranker.set_items(items)
	return _ranker.rank(needle, typos)


## The user typed or edited the line.
func set_text(value: String) -> void:
	text = value
	query = value
	selected = -1
	_chosen = ""
	_chosen_lost = false
	_cycling = false
	refresh()


## Re-rank the current query when tabs or panes change.
##
## Keep the selected row by ID. A renumbered row stays selected under its
## new label even if the label no longer matches the query.
##
## If the selected row closes, require a new choice before Enter acts.
func refresh() -> void:
	var previous := selected
	var targets := number_mode(query)
	var sessions := query.begins_with("$")
	var checkpoint_args := not sessions and not targets and checkpoint_arg_query(query)
	var candidates: Array
	if sessions:
		candidates = _sessions()
	elif targets:
		candidates = _targets(query[0] if query[0] in ["%", "@"] else "")
	elif checkpoint_args:
		candidates = _checkpoints()
	else:
		candidates = _commands()
	if query.is_empty():
		candidates = candidates.filter(func(candidate): return not candidate.get("alias", false))
	rows.clear()
	if sessions and "/" in query.trim_prefix("$"):
		rows = _rank_qualified_sessions(query.trim_prefix("$"), candidates)
	elif checkpoint_args:
		rows = _rank_checkpoints(query.substr(query.find(" ") + 1).strip_edges(), candidates)
	else:
		var labels := PackedStringArray(candidates.map(func(candidate): return str(candidate.label)))
		var needle := query.trim_prefix("$") if sessions else (query if targets else command_needle(query))
		for found in rank(needle, labels, not targets and not sessions):
			rows.append({"candidate": candidates[int(found.index)], "tier": int(found.tier), "indices": found.indices})
	selected = -1
	if _chosen.is_empty():
		return
	for index in rows.size():
		if identity(rows[index].candidate) == _chosen:
			selected = index
			break
	if selected < 0:
		for candidate in candidates:
			if identity(candidate) == _chosen:
				selected = clampi(previous, 0, rows.size())
				rows.insert(selected, {"candidate": candidate, "tier": _chosen_tier, "indices": PackedInt32Array()})
				break
	if selected < 0:
		_chosen = ""
		_chosen_lost = true
	elif _cycling:
		text = str(rows[selected].candidate.label)


## Chooses a row explicitly (arrows, Tab or a click).
func select(index: int) -> void:
	if index < 0 or index >= rows.size():
		return
	selected = index
	_chosen = identity(rows[index].candidate)
	_chosen_tier = int(rows[index].tier)
	_chosen_lost = false


## Arrow keys: move the selection without changing the line.
func move(step: int) -> void:
	if rows.is_empty():
		return
	select((0 if step > 0 else rows.size() - 1) if selected < 0 else wrapi(selected + step, 0, rows.size()))


## Tab: move the selection and preview it in the line, like wilder.nvim. The
## rows stay ranked by what was typed until the user types again.
func cycle(step: int) -> void:
	move(step)
	if selected >= 0:
		_cycling = true
		text = str(rows[selected].candidate.label)


## The row Enter runs: the explicit selection, else the top row when it
## matched at least as a substring.
##
## A fuzzy-only top row needs Tab or the arrows first, so Enter never runs a
## command the user did not spell out.
func accepted() -> Dictionary:
	if _chosen_lost:
		return {}
	if selected >= 0 and selected < rows.size():
		return rows[selected]
	if not query.is_empty() and not rows.is_empty() and int(rows[0].tier) <= Tier.SUBSTRING:
		return rows[0]
	return {}


func status() -> String:
	if _chosen_lost:
		return "The chosen row closed: choose again"
	if query.is_empty():
		return ""
	if rows.is_empty():
		return "No matches"
	if accepted().is_empty():
		return "Only fuzzy matches: Tab to choose"
	return ""


## Runs a row. The caller closes the line first so focus returns before the
## action moves it again.
func execute(row: Dictionary) -> void:
	var candidate: Dictionary = row.candidate
	match str(candidate.kind):
		"command":
			host._on_menu_action(candidate.entry)
		"tab":
			_raise(candidate.host)
			candidate.host.select_workspace(int(candidate.id))
		"pane":
			_raise(candidate.host)
			candidate.host.reveal_pane(str(candidate.key))
		"session":
			_switch_session(candidate)
		"checkpoint":
			host.restore_checkpoint(str(candidate.tag), str(candidate.path))


func _switch_session(candidate: Dictionary) -> void:
	var target_host: Node = candidate.get("host", host)
	if not is_instance_valid(target_host):
		target_host = host
	var peer: Node = candidate.peer
	preload("res://scenes/session/LiveSessionMenu.gd").switch_to(target_host, peer, str(candidate.name))
	var client: Node = target_host.get_parent()
	if client != null and "application" in host and host.application != null:
		var federated: bool = "federated" in client and bool(client.federated)
		if host.application.has_method("opens_windows") and host.application.opens_windows() and not federated:
			if host.application.has_method("present_desktop_client"):
				host.application.present_desktop_client(client)
		elif federated:
			var manager: Node = client.get_parent()
			if manager != null and "transports" in manager:
				for key in manager.transports:
					if manager.transports[key] == peer:
						manager._open_workspace(key)
						break
	_raise(target_host)


static func _server_name(peer: Node) -> String:
	for field in ["display_name", "server_hostname", "server_alias"]:
		if field in peer and not str(peer.get(field)).is_empty():
			return str(peer.get(field))
	if "url" in peer and not str(peer.url).is_empty():
		var url := str(peer.url)
		if url == "shared://local":
			return "This computer"
		return preload("res://scenes/remote/ConnectionName.gd").display({"url": url})
	return ""


func _connected_peers() -> Array[Dictionary]:
	var active: Node = preload("res://scenes/session/LiveSessionMenu.gd").transport(host)
	var hosts: Array = [host]
	if "application" in host and host.application != null:
		if host.application.has_method("session_hosts"):
			for candidate in host.application.session_hosts():
				if candidate not in hosts: hosts.append(candidate)
		elif "hosts" in host.application:
			for candidate in host.application.hosts:
				if candidate not in hosts: hosts.append(candidate)
	for index in hosts.size():
		var candidate: Node = hosts[index]
		if not is_instance_valid(candidate): continue
		var client: Node = candidate.get_parent()
		if client != null and "local_return" in client and client.local_return != null and is_instance_valid(client.local_return.client):
			var parked: Node = client.local_return.client.host
			if is_instance_valid(parked) and parked not in hosts:
				hosts.append(parked)
	var peers: Array[Dictionary] = []
	var seen := {}
	if active != null and is_instance_valid(active) and active.connected:
		seen[active] = true
		peers.append({"peer": active, "host": host, "server": _server_name(active)})
	for owner in hosts:
		if not is_instance_valid(owner) or not "session_backend" in owner: continue
		var backend: RefCounted = owner.session_backend
		if backend == null or not backend.is_remote or not "connection" in backend or not is_instance_valid(backend.connection): continue
		var connection: Node = backend.connection
		var list: Array = connection.connections if "connections" in connection else [connection]
		for peer in list:
			if is_instance_valid(peer) and peer.connected and not seen.has(peer):
				seen[peer] = true
				peers.append({"peer": peer, "host": owner, "server": _server_name(peer)})
	return peers


func _sessions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var active: Node = preload("res://scenes/session/LiveSessionMenu.gd").transport(host)
	var peers := _connected_peers()
	var has_slash := "/" in query.trim_prefix("$")
	var multi := peers.size() > 1
	var Labels := preload("res://scenes/session/SessionLabel.gd")
	for item in peers:
		var peer: Node = item.peer
		var server := str(item.server)
		for value in peer.available_sessions:
			var session := str(value.id)
			var display := Labels.display(value)
			var session_name := Labels.name_of(value)
			var qualified := (has_slash or (multi and peer != active)) and not server.is_empty()
			var label := "%s/%s" % [server, display] if qualified else display
			var detail := server if (multi and not server.is_empty()) else "Session"
			result.append({
				"kind": "session", "peer": peer, "host": item.host, "name": session,
				"session_name": session_name, "display": display, "server": server,
				"label": label, "title": display, "detail": detail,
				"checked": peer == active and session == peer.workspace, "hidden": false,
			})
	return result


func _rank_qualified_sessions(raw: String, candidates: Array) -> Array[Dictionary]:
	var slash := raw.find("/")
	var server_query := raw.substr(0, slash)
	var session_query := raw.substr(slash + 1)
	var matched: Array[Dictionary] = []
	for index in candidates.size():
		var candidate: Dictionary = candidates[index]
		var server := str(candidate.get("server", ""))
		if server.is_empty(): continue
		var server_tier := Tier.PREFIX
		var server_indices := PackedInt32Array()
		if not server_query.is_empty():
			var found_server := rank(server_query, PackedStringArray([server]), false)
			if found_server.is_empty(): continue
			server_tier = int(found_server[0].tier)
			server_indices = found_server[0].indices
		var session_tier := Tier.PREFIX
		var session_indices := PackedInt32Array()
		if not session_query.is_empty():
			var display := str(candidate.get("display", candidate.label))
			var found_session := rank(session_query, PackedStringArray([display]), false)
			if found_session.is_empty(): continue
			session_tier = int(found_session[0].tier)
			session_indices = found_session[0].indices
			var id_target := "$" + session_query.trim_prefix("$")
			var session_name := str(candidate.get("session_name", ""))
			if str(candidate.name).to_lower() == id_target.to_lower() or (not session_name.is_empty() and session_name.to_lower() == session_query.to_lower()):
				session_tier = Tier.EXACT
		var combined := PackedInt32Array(server_indices)
		var offset := server.length() + 1
		for pos in session_indices:
			combined.append(int(pos) + offset)
		matched.append({
			"candidate": candidate, "tier": maxi(server_tier, session_tier),
			"indices": combined, "order": index,
		})
	matched.sort_custom(func(a, b):
		if a.tier != b.tier: return int(a.tier) < int(b.tier)
		return int(a.order) < int(b.order))
	var ordered: Array[Dictionary] = []
	for item in matched:
		ordered.append({"candidate": item.candidate, "tier": item.tier, "indices": item.indices})
	return ordered


func _checkpoints_node() -> Node:
	if "application" in host and host.application != null and "checkpoints" in host.application:
		return host.application.checkpoints
	return null


static func _parse_checkpoint_args(arg_text: String) -> Dictionary:
	var tokens := arg_text.split(" ", false)
	var used_flag := false
	var expect_tag := false
	var tag_filter := ""
	var num_filter := ""
	var valid := true
	for raw_token in tokens:
		var token := str(raw_token)
		var lower := token.to_lower()
		if lower in ["--tag", "-t"]:
			used_flag = true
			expect_tag = true
		elif lower.begins_with("--tag="):
			used_flag = true
			tag_filter = lower.trim_prefix("--tag=")
			expect_tag = false
			if tag_filter.is_empty() or (not "manual".begins_with(tag_filter) and not "auto".begins_with(tag_filter)):
				valid = false
		elif expect_tag:
			tag_filter = lower
			expect_tag = false
			if not "manual".begins_with(tag_filter) and not "auto".begins_with(tag_filter):
				valid = false
		elif token.is_valid_int() and int(token) > 0 and num_filter.is_empty():
			num_filter = token
		elif tag_filter.is_empty() and ("manual".begins_with(lower) or "auto".begins_with(lower)):
			tag_filter = lower
		else:
			valid = false
	return {"used_flag": used_flag, "tag_filter": tag_filter, "num_filter": num_filter, "valid": valid}


func _checkpoints() -> Array[Dictionary]:
	var checkpoints := _checkpoints_node()
	if checkpoints == null or OS.has_feature("mobile"):
		return []
	var arg_text := query.substr(query.find(" ") + 1).strip_edges() if " " in query else ""
	var parsed := _parse_checkpoint_args(arg_text)
	var used_flag: bool = parsed.used_flag
	var tag_filter: String = parsed.tag_filter
	var now := Time.get_unix_time_from_system()
	var result: Array[Dictionary] = []
	if not used_flag and tag_filter.is_empty():
		var all_items: Array = checkpoints.ordered_history("")
		for index in all_items.size():
			var item: Dictionary = all_items[index]
			var number := index + 1
			var tag := str(item.get("tag", "manual"))
			var item_label := "RestoreCheckpoint %d" % number
			result.append({
				"kind": "checkpoint", "tag": tag, "path": str(item.path), "number": number,
				"label": item_label,
				"title": checkpoints.describe_checkpoint(item, now),
				"detail": tag, "checked": false, "hidden": false,
			})
	else:
		for tag in ["manual", "auto"]:
			if not tag_filter.is_empty() and not tag.begins_with(tag_filter):
				continue
			var saved: Array = checkpoints.ordered_history(tag)
			for index in saved.size():
				var item: Dictionary = saved[index]
				var number := index + 1
				var prefix := "RestoreCheckpoint --tag %s " % tag if used_flag else "RestoreCheckpoint %s " % tag
				result.append({
					"kind": "checkpoint", "tag": tag, "path": str(item.path), "number": number,
					"label": prefix + str(number),
					"title": checkpoints.describe_checkpoint(item, now),
					"detail": tag, "checked": false, "hidden": false,
				})
	return result


func _rank_checkpoints(arg_text: String, candidates: Array) -> Array[Dictionary]:
	var parsed := _parse_checkpoint_args(arg_text)
	if not parsed.valid:
		return []
	var tag_filter: String = parsed.tag_filter
	var num_filter: String = parsed.num_filter
	var exact_tag := tag_filter in ["", "manual", "auto"]
	var matched: Array[Dictionary] = []
	for candidate in candidates:
		var num_str := str(candidate.number)
		var label := str(candidate.label)
		var indices := PackedInt32Array()
		if not tag_filter.is_empty():
			var tag_pos := label.find(str(candidate.tag), 18)
			if tag_pos >= 0:
				for i in mini(tag_filter.length(), str(candidate.tag).length()):
					indices.append(tag_pos + i)
		if num_filter.is_empty():
			var tier := (Tier.EXACT if exact_tag else Tier.PREFIX) if int(candidate.number) == 1 else Tier.PREFIX
			matched.append({"candidate": candidate, "tier": tier, "indices": indices})
		elif num_str == num_filter or num_str.begins_with(num_filter):
			var num_pos := label.rfind(num_str)
			for i in num_filter.length():
				indices.append(num_pos + i)
			var tier := Tier.EXACT if (num_str == num_filter and exact_tag) else Tier.PREFIX
			matched.append({"candidate": candidate, "tier": tier, "indices": indices})
	return matched


func _raise(owner: Node) -> void:
	if owner == host:
		return
	var window := owner.get_window()
	if window.mode == Window.MODE_MINIMIZED: window.mode = Window.MODE_WINDOWED
	window.show()
	window.grab_focus()


## Tabs and panes. Plain numbers address this window by position; `%` and `@`
## address stable IDs in every window, the way PaneTargets resolves them.
func _targets(sigil: String) -> Array[Dictionary]:
	var hosts: Array = [host]
	if not sigil.is_empty() and "application" in host and host.application != null:
		hosts = host.application.hosts
	var result: Array[Dictionary] = []
	for owner in hosts:
		var position := 0
		for tab in owner.get_tabs():
			position += 1
			var id := int(tab.id)
			var where := str(position) if owner == host else "other window"
			if sigil != "%":
				result.append({
					"kind": "tab", "host": owner, "id": id, "title": str(tab.title), "hidden": false,
					"label": Targets.tab_id(id) if sigil == "@" else str(position),
					"detail": where if sigil == "@" else Targets.tab_id(id),
				})
			var group: Dictionary = owner.workspace_layout.tab(id)
			var tree: Dictionary = group.get("tree", {})
			var shown := Layout.keys(tree, true)
			var keys := Layout.numbered_keys(tree, group.get("focused", ""))
			for index in keys.size():
				var key: String = keys[index]
				var number := "%d.%d" % [position, index + 1]
				var label := number
				var detail := key
				if sigil == "@":
					label = "%s.%d" % [Targets.tab_id(id), index + 1]
				elif sigil == "%":
					label = key
					detail = number if owner == host else "other window"
				result.append({
					"kind": "pane", "host": owner, "key": key, "title": str(owner.pane_title(key)),
					"hidden": not key in shown, "label": label, "detail": detail,
				})
	return result


## Enabled menu commands in menu order, then registry actions that no menu
## entry runs (FocusLeft), listed only once something is typed. Every name is
## the PascalCase action or command name.
func _commands() -> Array[Dictionary]:
	var entries: Array = host.menu_entries if not host.menu_entries.is_empty() else host.menu_entry_specs()
	var result: Array[Dictionary] = []
	var names := {}
	for entry in entries:
		if not entry.get("command_line", true):
			continue
		if entry.action is String and entry.action == "Separator":
			continue
		var state: Dictionary = host.menu_entry_state(entry)
		if not state.enabled:
			# A disabled menu entry also hides its action.
			if entry.action is String:
				names[entry.action] = true
			continue
		var parts: PackedStringArray = str(entry.label).split("::")
		var named: bool = entry.action is String and entry.action not in ["SwitchWorld", "SetWorldSetting", "SendText"]
		var name := str(entry.get("command", entry.action if named else command_name(parts)))
		if names.has(name):
			name = command_name(parts, true)
		if names.has(name):
			continue
		names[name] = true
		result.append({
			"kind": "command", "entry": entry, "label": name, "title": parts[-1] if entry.get("literal_label", false) else tr(parts[-1]),
			"detail": _shortcut_text(entry), "checked": state.checked, "hidden": false,
		})
	var checkpoints := _checkpoints_node()
	if checkpoints != null and not OS.has_feature("mobile") and not names.has("RestoreCheckpoint"):
		var saved: Array = checkpoints.ordered_history("")
		if not saved.is_empty():
			var latest: Dictionary = saved[0]
			var command := "RestoreCheckpoint"
			names[command] = true
			var restore_entry := {
				"label": "Sessions::Restore checkpoint",
				"command": command,
				"action": func(h): h.restore_checkpoint(str(latest.tag), str(latest.path)),
			}
			result.append({
				"kind": "command", "entry": restore_entry, "label": command,
				"title": tr("Restore checkpoint"), "detail": _shortcut_text(restore_entry),
				"checked": false, "hidden": false,
			})
	var Actions := preload("res://scenes/HostActions.gd")
	for action in Actions.names():
		if names.has(action) or action in Actions.PARAMETERIZED:
			continue
		names[action] = true
		var entry := {"label": action, "action": action}
		# Listed once typed, like the empty line's menu commands would crowd out.
		result.append({
			"kind": "command", "entry": entry, "label": action, "title": Actions.title(action),
			"detail": _shortcut_text(entry), "checked": false, "hidden": false, "alias": true,
		})
	return result


## The action's direct shortcut, else its prefix sequence.
func _shortcut_text(entry: Dictionary) -> String:
	if entry.action is String and host.has_method("shortcut_text"):
		return host.shortcut_text(entry.action)
	return ""
