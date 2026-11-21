extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/new-terminal-window.md


## A window's title bar button, by its label.
func header_button(window_key: String, label: String) -> Button:
	for child in host.workspace_view.panes[window_key].header.get_children():
		if child is Button and child.text == label:
			return child
	return null


## The terminal windows of the tab `key` is in, oldest first.
func terminal_windows(key: String) -> Array:
	var tab: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(key))
	return host.workspace_layout.keys(tab.tree).filter(
		func(k):
			return host.is_terminal_pane(k),
	)


func opens_beside(from: String, label: String) -> String:
	var before := terminal_windows(from)
	await click(await on_header(from, "split_right"))
	await owner_at_rest()
	var after := terminal_windows(from)
	check(
		after.size() == before.size() + 1,
		"%s: a terminal window opens in the same tab (%d windows)" % [label, after.size()],
	)
	var opened: String = (
		after.filter(
			func(k):
				return not before.has(k),
		).front()
		if after.size() > before.size()
		else ""
	)
	if opened.is_empty():
		return ""
	var rects: Dictionary = host.workspace_view.pane_rects
	check(
		rects[opened].position.x > rects[from].end.x
		and is_equal_approx(rects[opened].position.y, rects[from].position.y),
		"%s: it splits to the right of the selected pane, both title bars showing" % label,
	)
	check(host.pane_focus == opened, "%s: it has the keyboard" % label)
	return opened


func play() -> void:
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		host.workspace_view.toggle_tiling()
		await hold(0.3)
	var alpha: String = window("ALPHA").key

	await say("In ALPHA's title bar, click Split right")
	var second := await opens_beside(alpha, "From ALPHA")
	if second.is_empty():
		return
	check(host.chromiums.is_empty(), "No chromium opens")
	var second_id := int(second.substr(1))
	await say("Type in the new window")
	await type("echo NEWWINDOW $$ {enter}")
	var output_deadline := Time.get_ticks_msec() + 15000
	while not terminal_text(second_id).contains("NEWWINDOW") and Time.get_ticks_msec() < output_deadline:
		await process_frame
	check(
		terminal_text(second_id).contains("NEWWINDOW")
		and not screen_text("ALPHA").contains("NEWWINDOW"),
		"What is typed goes to the new window, not ALPHA",
	)
	var second_pid: int = host.sessions[second_id].term.get_shell_pid()
	check(
		second_pid > 0 and second_pid != shells["ALPHA"],
		"It has a shell of its own (%d, ALPHA %d)" % [second_pid, shells["ALPHA"]],
	)
	check(titles() == [host.session_model(second_id).title], "The automatic tab follows the focused new pane (%s)" % [titles()])

	await say("In ALPHA's title bar, split again while the second pane is focused")
	await camera_at_rest()
	var third := await opens_beside(alpha, "From the unfocused ALPHA pane")
	if third.is_empty():
		return
	await say("Close the third window")
	host.request_close_terminal(int(third.substr(1)))
	# Restricted process inspection conservatively prompts even for an idle shell.
	if is_instance_valid(host.close_dialog):
		host.close_dialog.confirmed.emit()
		host.close_dialog.hide()
	await owner_at_rest()
	check(
		terminal_windows(alpha) == [alpha, second],
		"ALPHA and the second window remain (%s)" % [terminal_windows(alpha)],
	)
	check(
		shell_pid("ALPHA") == shells["ALPHA"]
		and host.sessions[second_id].term.get_shell_pid() == second_pid,
		"Both keep their shells",
	)
	check(
		(await hover_header(second)).has_part("chromium"),
		"Chromium icon stays in the title bar, for its terminal's chromium",
	)
