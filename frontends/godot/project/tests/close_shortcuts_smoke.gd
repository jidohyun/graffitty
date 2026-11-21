extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"


func play() -> void:
	await camera_at_rest()
	var first: String = host.pane_focus
	var first_id := int(first.substr(1))
	var pid: int = host.sessions[first_id].term.get_shell_pid()
	var tab: int = host.workspace_layout.active
	var second := await add_window(first)
	await camera_at_rest()
	await keys("cmd+w")
	await hold(0.3)
	check(not host.sessions.has(int(second.substr(1))), "Cmd+W closes the focused terminal pane")
	check(host.sessions.has(first_id) and host.sessions[first_id].term.get_shell_pid() == pid, "Sibling terminal keeps its PTY")
	check(host.workspace_layout.active == tab, "Pane close preserves the workspace tab")
	host.create_session()
	await camera_at_rest()
	var other_tab: int = host.workspace_layout.active
	var other_id: int = host.active_session_id
	host.select_workspace(tab)
	await camera_at_rest()
	await add_window(first)
	await camera_at_rest()
	await keys("cmd+alt+w")
	await hold(0.3)
	check(host.workspace_layout.tab(tab).is_empty(), "Cmd+Option+W closes the whole workspace tab")
	check(host.workspace_layout.active == other_tab and host.sessions.has(other_id), "Other workspace survives tab close")
	# A busy shell exercises window-close routing without ending the replay host.
	await type("sleep 30{enter}")
	await hold(0.5)
	await keys("cmd+shift+w")
	check(host.close_dialog != null and host.close_dialog.title == "Close window?", "Cmd+Shift+W requests window close")
	if host.close_dialog != null:
		host.close_dialog.hide()
	await hold(0.1)
	check(host.sessions.has(other_id), "Cancel window close preserves the terminal")
