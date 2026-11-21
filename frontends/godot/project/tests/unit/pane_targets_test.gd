extends "res://tests/unit/test_case.gd"
const Targets := preload("res://scenes/PaneTargets.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const API := preload("res://scenes/AgentAPI.gd")

class Shell extends Node:
	func get_shell_pid() -> int:
		return 4321

class Monitor extends Node:
	func snapshot() -> Dictionary:
		return {"status": "paused", "sample_age_seconds": 9.0, "coverage_gap": true,
			"processes": [{"pid": 4322, "parent_pid": 4321, "start_identity": "start-1",
				"name": "worker", "memory_current": 42, "argv": "secret", "env": "secret"}]}

class Host extends Node:
	var workspace_layout = Layout.new()
	var sessions := {}
	var workspaces := {}
	var chromiums := {8: null}
	var monitor: Node
	func is_chromium_pane(key: String) -> bool:
		return Targets.valid(key) and chromiums.has(int(key.substr(1)))
	func get_tabs() -> Array:
		return workspace_layout.tabs
	func resource_monitor_for(_id: int) -> Node:
		return monitor

class App extends Node:
	var host: Node
	func host_for_workspace(id: int) -> Node:
		return host if host.sessions.has(id) else null
	func chromium_host(id: int) -> Node:
		return host if id == 8 else null

func setup() -> Array:
	var host := Host.new()
	var app := App.new()
	app.host = host
	host.sessions = {3: {"term": Shell.new()}, 9: {"term": Shell.new()}}
	host.workspaces = {3: {}, 9: {}}
	host.workspace_layout.add(3, {"windows": [{"pane": "%3"}, {"pane": "%8"}]})
	host.workspace_layout.add(9, {"pane": "%9"})
	host.monitor = Monitor.new()
	return [app, host]

func cleanup(app: Node, host: Node) -> void:
	for session in host.sessions.values():
		session.term.free()
	host.monitor.free()
	host.free()
	app.free()

func test_targets_stable_across_reorder_and_move() -> void:
	var fixture := setup()
	var app: Node = fixture[0]
	var host: Node = fixture[1]
	expect(Targets.resolve(app, host, "%3") == "%3", "Terminal stable ID resolves")
	expect(Targets.resolve(app, host, "%8") == "%8", "Chromium shares the ID namespace")
	expect(Targets.resolve(app, host, ":1.2") == "%8", "Position includes chromium panes")
	host.workspace_layout.reorder(9, 0)
	expect(Targets.resolve(app, host, ":1.1") == "%9", "Positions follow tab order")
	expect(Targets.resolve(app, host, "@3.1") == "%3", "Tab ID survives reorder")
	var pane: Dictionary = host.workspace_layout.take_pane("%8")
	host.workspace_layout.tab(9).tree = {"windows": [{"pane": "%9"}, pane]}
	expect(Targets.resolve(app, host, "%8") == "%8", "Pane ID survives move")
	expect(Targets.resolve(app, host, ":1.2") == "%8", "Position follows move")
	expect(Targets.list_panes(host).map(func(row): return row.target) == [":1.1", ":1.2", ":2.1"], "Listed pane numbers start at 1")
	for invalid in ["%999", "%+3", "%03", ":0.1", ":1.0", "@3.0", ":1.-1", ":99.1", "@999.1", ":1.1.1"]:
		expect(Targets.resolve(app, host, invalid).is_empty(), "Reject invalid/stale target " + invalid)
	expect(not Targets.hint(":1.0").is_empty() and not Targets.hint("@3.0").is_empty(), "Pane zero explains the numbering")
	expect(Targets.hint(":1.1").is_empty() and Targets.hint(":10").is_empty(), "Valid targets need no hint")
	cleanup(app, host)

func test_main_numbers_follow_rows_before_stored_outside_order() -> void:
	var fixture := setup()
	var app: Node = fixture[0]
	var host: Node = fixture[1]
	var tree := {"tiling": true, "windows": [
		{"pane": "%20", "stashed": true}, {"pane": "%9"},
		{"pane": "%21", "shown": false}, {"pane": "%3"}, {"pane": "%8"},
		{"pane": "%22"}, {"pane": "%23", "graph_floating": true}],
		"tiles": {"axis": "h", "children": [
			{"axis": "v", "children": [{"pane": "%3"}, {"pane": "%9"}]},
			{"axis": "v", "children": [{"pane": "%8"}, {"pane": "%22"}]}]}}
	host.workspace_layout.tab(3).tree = tree
	var before := tree.duplicate(true)
	var expected := ["%3", "%8", "%9", "%22", "%20", "%21", "%23"]
	expect(Layout.numbered_keys(tree) == expected, "Read across rows, not down the left column first")
	for index in expected.size():
		expect(Targets.resolve(app, host, ":1.%d" % [index + 1]) == expected[index], "CLI target matches reading order")
		expect(Targets.resolve(app, host, "@3.%d" % [index + 1]) == expected[index], "Stable tab target uses the same numbering")
	expect(Targets.list_panes(host).slice(0, 7).map(func(row): return row.pane) == expected, "Listed targets match resolution")
	expect(tree == before, "Numbering queries never mutate the stored layout")
	tree.tiles.children.reverse()
	expect(Layout.numbered_keys(tree) == ["%8", "%3", "%22", "%9", "%20", "%21", "%23"], "Changing columns renumbers Main without reordering outside panes")
	tree.tiling = false
	expect(Layout.numbered_keys(tree) == ["%9", "%3", "%8", "%22", "%20", "%21", "%23"], "Free layout keeps stored order within Main and outside")
	Layout.find(tree, "%9")["rect"] = Rect2(800, 600, 100, 100)
	Layout.find(tree, "%20")["rect"] = Rect2(-5000, -5000, 100, 100)
	expect(Layout.numbered_keys(tree) == ["%9", "%3", "%8", "%22", "%20", "%21", "%23"], "Free movement cannot spatially reorder pane numbers")
	expect(Targets.resolve(app, host, "%3") == "%3", "Stable pane ID survives all renumbering")
	cleanup(app, host)


func test_numbering_tracks_stash_restore_close_and_pending_tiles() -> void:
	var tree := {"tiling": true, "windows": [
		{"pane": "%1", "stashed": true}, {"pane": "%2"}, {"pane": "%3"}],
		"tiles": {"axis": "h", "children": [{"pane": "%3"}, {"pane": "%2"}]}}
	var area := Rect2(0, 0, 1000, 600)
	expect(Layout.numbered_keys(tree) == ["%3", "%2", "%1"], "Older stash follows newer Main panes")
	Layout.place(tree, "%2", Rect2(1500, 0, 300, 200), area)
	expect(Layout.numbered_keys(tree) == ["%3", "%1", "%2"], "Stashing keeps the outside panes' stored order")
	Layout.place(tree, "%1", Rect2(0, 0, 300, 200), area, "%3", "left")
	expect(Layout.numbered_keys(tree) == ["%1", "%3", "%2"], "Restoring to the left takes the first number")
	tree = Layout.remove(tree, "%1")
	expect(Layout.numbered_keys(tree) == ["%3", "%2"], "Closing Main shifts the outside numbers down")
	tree.windows.append({"pane": "%4"})
	var before := tree.duplicate(true)
	expect(Layout.numbered_keys(tree, "%3") == ["%3", "%4", "%2"], "New panes are numbered before arrange materializes their tiles")
	expect(tree == before, "Resolving pending tiles is read-only")
	Layout.arrange(tree, area, {}, "%3")
	expect(Layout.numbered_keys(tree, "%3") == ["%3", "%4", "%2"], "Arrangement and numbering agree")


func test_pid_scope_freshness_and_secret_filtering() -> void:
	var fixture := setup()
	var app: Node = fixture[0]
	var host: Node = fixture[1]
	var api := API.new()
	api.application = app
	var result: Dictionary = api.terminal_pids(host, {})
	expect(result.result.terminals.size() == 2, "Default lists this window's terminals")
	expect(not result.result.terminals[0].has("processes"), "Inventory is opt-in")
	result = api.terminal_pids(host, {"target": "%3", "details": true})
	var row: Dictionary = result.result.terminals[0]
	expect(row.pane == "%3" and row.root_pid == 4321, "PID is the live root shell")
	expect(row.status == "paused" and row.sample_age_seconds == 9.0, "Stale data stays labeled")
	expect(row.processes[0].start_identity == "start-1", "PID reuse identity retained")
	expect(not row.processes[0].has("argv") and not row.processes[0].has("env"), "Only allowed fields exposed")
	expect(api.terminal_pids(host, {"target": "@9"}).result.terminals.size() == 1, "Tab filtering")
	expect(api.terminal_pids(host, {"target": "%8"}).has("error"), "Chromium cannot masquerade as a shell")
	expect(api.terminal_pids(host, {"target": "%999"}).has("error"), "No access outside this window")
	expect(api.terminal_pids(host, {"details": "yes"}).has("error"), "Details must be boolean")
	api.graph.free()
	api.free()
	cleanup(app, host)
