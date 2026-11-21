extends RefCounted
## Public addresses use the application's shared, monotonic session allocator.
const Layout := preload("res://scenes/WorkspaceLayout.gd")


static func number(value: String) -> bool:
	return not value.is_empty() and value.is_valid_int() and value == str(int(value)) and int(value) >= 0


static func valid(key: String) -> bool:
	return key.begins_with("%") and number(key.substr(1))


static func label(key: String) -> String:
	return "pane " + key if valid(key) else key


static func tab_id(id: int) -> String:
	return "@%d" % id


static func resolve_tab(host: Node, target: String) -> int:
	if target.begins_with("@") and number(target.substr(1)):
		var id := int(target.substr(1))
		return id if not host.workspace_layout.tab(id).is_empty() else -1
	if target.begins_with(":") and number(target.substr(1)):
		var index := int(target.substr(1)) - 1
		var tabs: Array = host.get_tabs()
		return int(tabs[index].id) if index >= 0 and index < tabs.size() else -1
	return -1


static func resolve(application: Node, host: Node, target: String) -> String:
	if target.begins_with("%") and number(target.substr(1)):
		var id := int(target.substr(1))
		var terminal_host: Node = application.host_for_workspace(id)
		if terminal_host != null and terminal_host.sessions.has(id):
			return target
		if application.chromium_host(id) != null:
			return target
		return ""
	if target.begins_with(":") or target.begins_with("@"):
		if target.count(".") != 1:
			return ""
		var id := resolve_tab(host, target.get_slice(".", 0))
		var position := target.get_slice(".", 1)
		if id < 0 or not number(position):
			return ""
		# Pane numbers start at 1, like tmux with pane-base-index 1.
		var group: Dictionary = host.workspace_layout.tab(id)
		var keys := Layout.numbered_keys(group.tree, group.get("focused", ""))
		var index := int(position) - 1
		return keys[index] if index >= 0 and index < keys.size() else ""
	return ""


static func list_panes(host: Node) -> Array:
	var panes: Array = []
	var position := 0
	for tab in host.get_tabs():
		position += 1
		var group: Dictionary = host.workspace_layout.tab(int(tab.id))
		var keys := Layout.numbered_keys(group.tree, group.get("focused", ""))
		for index in keys.size():
			var key: String = keys[index]
			panes.append({"pane": key, "id": key, "type": "chromium" if host.is_chromium_pane(key) else "terminal",
				"tab": tab_id(int(tab.id)), "target": ":%d.%d" % [position, index + 1]})
	return panes


## Explains why a positional target can never match, for error messages.
static func hint(target: String) -> String:
	if (target.begins_with(":") or target.begins_with("@")) and target.ends_with(".0"):
		return " (pane numbers start at 1)"
	return ""
