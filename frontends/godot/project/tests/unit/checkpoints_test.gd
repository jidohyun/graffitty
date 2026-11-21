extends "res://tests/unit/test_case.gd"
const Checkpoints := preload("res://scenes/Checkpoints.gd")

class RestoreHost extends RefCounted:
	var restored := []
	func restore_checkpoint(tag: String, checkpoint: String) -> void: restored.append([tag, checkpoint])

func test_saved_pane_and_route_ids_upgrade_without_changing_titles() -> void:
	var saved := {"focused": "terminal:0", "title": "terminal:0",
		"tree": {"windows": [{"pane": "terminal:0"}, {"pane": "chromium:8"}], "physics_anchor": "terminal:0"},
		"graph_visual": {"routes": {"terminal:0/out>terminal:2/in": ["r1"]}}}
	var restored: Dictionary = Checkpoints.decode(saved)
	expect(restored.focused == "%0" and restored.tree.physics_anchor == "%0", "Saved pane zero keeps its identity")
	expect(restored.tree.windows[1].pane == "%8", "Chromium IDs use the same namespace")
	expect(restored.graph_visual.routes == {"%0/out>%2/in": ["r1"]}, "Saved routes use canonical graph endpoints")
	expect(restored.title == "terminal:0", "User titles are preserved verbatim")
	expect(Checkpoints.decode(restored) == restored, "Loading the migrated document again is stable")


func test_layout_json_round_trip_keeps_stashes_and_split_ratios() -> void:
	var tabs := [
		{
			"id": 7,
			"title": "review",
			"focused": "%9",
			"tree": {
				"windows": [
					{ "pane": "%7", "rect": Rect2(-420, 80, 400, 300), "stashed": true },
					{ "pane": "%9", "rect": Rect2(4, 80, 800, 600), "shown": true },
				],
				"tiles": {
					"axis": "h",
					"children": [
						{ "pane": "%9", "weight": 0.37 },
						{ "pane": "%10", "weight": 0.63 },
					],
				},
				"tiling": true,
			},
		}
	]
	var restored: Array = Checkpoints.decode(JSON.parse_string(JSON.stringify(Checkpoints.encode(tabs))))
	expect(
		restored[0].tree.windows[0].rect == Rect2(-420, 80, 400, 300),
		"Off-sheet location and size survive JSON",
	)
	expect(restored[0].tree.windows[0].stashed, "Stash state survives")
	expect(
		is_equal_approx(restored[0].tree.tiles.children[0].weight, 0.37)
		and is_equal_approx(restored[0].tree.tiles.children[1].weight, 0.63),
		"Split ratio survives",
	)
	expect(
		restored[0].focused == "%9" and restored[0].title == "review",
		"Focus and title survive",
	)


func test_save_and_quit_ignores_navigation_but_not_closed_chromiums() -> void:
	var saved := {"windows": [{"tabs": [], "active": 1, "position": [0, 0], "size": [800, 600], "graph": {},
		"panes": [{"id": 1, "pid": 10}], "chromiums": [{"id": 2, "owner": 1, "urls": ["https://a.example/"]}]}]}
	var navigated: Dictionary = saved.duplicate(true)
	navigated.windows[0].chromiums[0].urls = ["https://b.example/", "https://a.example/"]
	expect(Checkpoints.layout_signature(saved) == Checkpoints.layout_signature(navigated), "A page that navigates during the save does not block quitting")
	var closed: Dictionary = saved.duplicate(true)
	closed.windows[0].chromiums.clear()
	expect(Checkpoints.layout_signature(saved) != Checkpoints.layout_signature(closed), "A chromium closed during the save does")


func test_restored_panes_spawn_their_prepared_program_and_arguments() -> void:
	var windows := Checkpoints.spawn_options({"cwd": "C:/work", "restore_shell": "pwsh.exe",
		"restore_args": ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "C:/restore/pane-3.ps1"]})
	expect(windows == {"cwd": "C:/work", "shell": "pwsh.exe", "args": ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "C:/restore/pane-3.ps1"],
		"login": false, "shell_integration": false}, "A Windows pane runs PowerShell on its prepared script")
	var posix := Checkpoints.spawn_options({"cwd": "/work", "restore_shell": "/restore/pane-3.sh"})
	expect(posix == {"cwd": "/work", "shell": "/restore/pane-3.sh", "login": false, "shell_integration": false}, "A POSIX pane runs its script directly")
	expect(Checkpoints.spawn_options({"cwd": "/work"}) == {"cwd": "/work"}, "A plain pane keeps the default shell")

func test_restored_panes_ask_for_their_saved_ids_only_from_local_history() -> void:
	var window := {"panes": [{"id": 3}, {"id": 4}, {"id": 9}], "chromiums": [{"id": 12}],
		"tabs": [{"id": 7, "tree": {"windows": [{"pane": "%3"}, {"pane": "%4"}]}}]}
	var saved := {"keep_ids": true, "windows": [window]}
	expect(Checkpoints.saved_tabs(saved) == {3: 7, 4: 7}, "Each placed pane knows its saved tab")
	expect(Checkpoints.saved_identity(saved, window.panes[0], true) == {"id": 3, "tab": 7, "through": 12},
		"A pane that opens its tab asks for both IDs, and new IDs start after the largest saved one")
	expect(Checkpoints.saved_identity(saved, window.panes[1], false) == {"id": 4, "through": 12}, "A later pane joins its tab")
	expect(Checkpoints.saved_identity(saved, window.panes[2], true) == {"id": 9, "through": 12}, "A pane outside every tab opens a new one")
	saved.keep_ids = false
	expect(Checkpoints.saved_identity(saved, window.panes[0], true) == {}, "An imported checkpoint takes new IDs")


func test_checkpoints_are_a_separated_group_inside_sessions() -> void:
	var checkpoints := Checkpoints.new()
	var commands := checkpoints.menu_entries()
	if OS.has_feature("mobile"):
		expect(commands.is_empty(), "Mobile does not expose local CLI checkpoint commands")
		checkpoints.free()
		return
	expect(not commands.is_empty(), "Desktop exposes checkpoint commands")
	for command in commands:
		expect(command.label.begins_with("Sessions::") and not command.label.begins_with("Sessions::Checkpoints"), "Checkpoint entries sit directly under Sessions: %s" % command.label)
		expect("checkpoint" in command.label and "snapshot" not in command.label, "Entries name the checkpoint explicitly: %s" % command.label)
	var entries: Array[Dictionary] = [{"label": "Sessions::New Session…", "action": "new"}]
	entries.append_array(commands)
	entries.append({"label": "Sessions::Servers…", "action": "servers"})
	var ordered := preload("res://scenes/session/LiveSessionMenu.gd").order(entries)
	var first := ordered.find(commands[0])
	expect(first > 0 and ordered[first - 1].action == "Separator", "A divider separates checkpoints from live sessions and servers")
	expect(ordered.slice(first) == commands, "Checkpoint command order stays intact")
	checkpoints.free()


func test_menu_lists_saved_history_like_tmux_restore_agents() -> void:
	if OS.has_feature("mobile"): return
	var checkpoints := Checkpoints.new()
	var now := Time.get_unix_time_from_system()
	var empty := checkpoints.menu_entries()
	var resume := empty.filter(func(e): return "Resume manual checkpoint" in e.label or "Resume auto checkpoint" in e.label)
	expect(resume.size() == 2 and resume.all(func(e): return e.label.ends_with("::No checkpoints") and not e.enabled.call(null)), "Empty histories show one disabled entry per tag")
	expect(empty.all(func(e): return "History" not in e.label and "Restore Latest" not in e.label), "No history dialog or restore-latest command")
	checkpoints.history = {
		"manual": [{"path": "/tmp/a.json", "saved_at": now - 52 * 86400, "windows": 4, "tabs": 20, "panes": 20},
			{"path": "/tmp/b.json", "saved_at": now - 90, "windows": 1, "tabs": 2, "panes": 3}],
		"auto": [{"path": "/tmp/c.json", "saved_at": now - 400 * 86400, "windows": 2, "tabs": 9, "panes": 9}],
	}
	var entries := checkpoints.menu_entries()
	var manual := entries.filter(func(e): return e.label.begins_with("Sessions::Resume manual checkpoint::"))
	var auto := entries.filter(func(e): return e.label.begins_with("Sessions::Resume auto checkpoint::"))
	expect(manual.size() == 2 and auto.size() == 1, "Every saved checkpoint is one menu entry under its tag")
	expect(manual[0].label.ends_with("::7w ago, 4 sessions, 20 tabs, 20 panes") and manual[0].literal_label, "Entries read age, sessions, tabs, panes: %s" % manual[0].label)
	expect(manual[1].label.ends_with("::1m ago, 1 sessions, 2 tabs, 3 panes"), "Recent entries use minutes")
	expect(auto[0].label.ends_with("::1y ago, 2 sessions, 9 tabs, 9 panes"), "Old entries use years")
	var host := RestoreHost.new()
	manual[0].action.call(host)
	auto[0].action.call(host)
	expect(host.restored == [["manual", "/tmp/a.json"], ["auto", "/tmp/c.json"]], "Choosing an entry restores that file under its tag")
	checkpoints.free()
