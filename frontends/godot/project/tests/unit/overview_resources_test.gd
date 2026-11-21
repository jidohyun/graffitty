extends "res://tests/unit/test_case.gd"
const View := preload("res://scenes/WorkspaceView.gd")
const Mods := preload("res://scenes/mods/ModService.gd")

class Monitor extends Node:
	signal snapshot_changed(data: Dictionary)
	func snapshot() -> Dictionary: return {}

class Host extends Node:
	func is_terminal_pane(key: String) -> bool: return key in ["%4", "%9"]
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var agent_api: Node
	var monitor := Monitor.new()
	func resource_monitor_for(_id: int) -> Node: return monitor
	func pane_title(_key: String) -> String: return "A custom terminal title"

func test_status_strip_identifies_pane_without_title() -> void:
	var host := Host.new()
	var view := View.new()
	view.host = host
	expect(view._compact_resources("%0", 1).label == ".1 (%0)", "Status strip uses only ordinal and stable ID, never the pane title")
	view.free()
	host.monitor.free()
	host.free()

func test_status_position_updates_without_waiting_for_resource_sample() -> void:
	var host := Host.new()
	host.workspace_layout.add(4, {"windows": [{"pane": "%4", "shown": false}, {"pane": "%9"}]})
	var view := View.new()
	view.host = host
	view.panes["%9"] = Control.new()
	var strip := Control.new()
	view.status_strips["%9"] = strip
	view._sync_status_sources()
	expect(view.pane_status["%9"].label == ".1 (%9)", "Main panes precede hidden panes in the status strip too")
	var tree: Dictionary = host.workspace_layout.tab(4).tree
	tree.tiling = true
	tree.windows[0].shown = true
	tree.tiles = {"axis": "h", "children": [{"pane": "%4"}, {"pane": "%9"}]}
	view._sync_status_sources()
	expect(view.pane_status["%9"].label == ".2 (%9)", "Changing Main updates numbers without waiting for resource samples")
	host.workspace_layout.take_pane("%4")
	view._sync_status_sources()
	expect(view.pane_status["%9"].label == ".1 (%9)", "Closing the preceding pane updates the ordinal while preserving the stable ID")
	view.panes["%9"].free()
	strip.free()
	view.free()
	host.monitor.free()
	host.free()

func test_optional_agent_status_never_repeats_metrics() -> void:
	var host := Host.new()
	var view := View.new()
	view.host = host
	expect(view._compact_resources("%4", 1).agent == null, "A shell has no duplicate status row")
	var badge: Dictionary = Mods.agent_badge("claude", "idle", {}, [])
	expect(badge.tooltip == "Claude · " + TranslationServer.translate("Done") and badge.logo == "claude-code.svg" and not badge.spinning, "An agent badge identifies provider and status")
	expect(Mods.agent_badge("codex", "busy", {}, []).spinning, "A running agent's glyph spins")
	expect(Mods.agent_badge("", "idle", {"name": "Manual Prompt"}, []).name == "Manual Prompt", "A providerless node shows its name")
	view.free()
	host.monitor.free()
	host.free()

func test_resource_summary_distinguishes_live_zero_from_unknown() -> void:
	var live := {"status": "running", "root_pid": 1234, "cpu_valid": true, "cpu_percent": 0.0, "memory_current": 10485760}
	expect(View.overview_resource_text(live, "%3") == "%3 · CPU 0% · RAM 10M", "Live zero CPU and MiB are displayed")
	expect(View.overview_resource_text(live, "%3", 1) == ".1 (%3) · CPU 0% · RAM 10M", "The pane's ordered position appears alongside its stable ID")
	live.status = "paused"
	expect(View.overview_resource_text(live, "%3") == "%3 · CPU — · RAM —", "Paused samples never masquerade as current measurements")
	expect(View.overview_resource_text({}, "%8") == "%8 · CPU — · RAM —", "Unavailable sampler values are explicit")

func test_status_strips_stay_outside_all_terminal_content() -> void:
	var owners: Array[Rect2] = [Rect2(130, 120, 240, 180), Rect2(380, 40, 180, 160)]
	var desired: Array[Rect2] = [Rect2(130, 53, 108, 64), Rect2(380, -27, 108, 64)]
	var bounds := Rect2(0, 36, 700, 400)
	var placed := View.place_status_strips(desired, bounds, owners)
	expect(placed[0] == desired[0], "Top-left above the pane is preferred")
	expect(placed[1].has_area(), "A pane near the top uses another edge")
	for i in placed.size():
		expect(bounds.encloses(placed[i]), "Stats stay on screen")
		for pane in owners: expect(not placed[i].intersects(pane), "No terminal content is obscured")
		for j in i: expect(not placed[i].intersects(placed[j]), "Stats do not overlap")

func test_status_strips_avoid_larger_background_panes() -> void:
	var owners: Array[Rect2] = [Rect2(150, 150, 200, 150)]
	var obstacles: Array[Rect2] = [owners[0], Rect2(100, 36, 400, 110)]
	var desired: Array[Rect2] = [Rect2(150, 83, 108, 64)]
	var placed := View.place_status_strips(desired, Rect2(0, 36, 700, 400), owners, obstacles)
	expect(placed[0].has_area(), "Stats find free space along another edge")
	for pane in obstacles: expect(not placed[0].intersects(pane), "Background terminal remains unobscured too")

func test_status_strips_hide_when_no_edge_has_room() -> void:
	var owners: Array[Rect2] = [Rect2(0, 36, 400, 300)]
	var desired: Array[Rect2] = [Rect2(0, -31, 108, 64)]
	var placed := View.place_status_strips(desired, owners[0], owners)
	expect(not placed[0].has_area(), "Never fall back over stdout when every edge is offscreen")

func test_status_strips_prefer_clear_ports_but_allow_last_resort() -> void:
	var owners: Array[Rect2] = [Rect2(130, 120, 240, 180)]
	var desired: Array[Rect2] = [Rect2(130, 53, 108, 64)]
	var ports: Array[Rect2] = [desired[0]]
	var placed := View.place_status_strips(desired, Rect2(0, 36, 700, 400), owners, [], ports)
	expect(placed[0].has_area() and not placed[0].intersects(ports[0]), "Another edge beats covering a port")
	var tight := Rect2(130, 53, 108, 67)
	placed = View.place_status_strips(desired, tight, owners, [], ports)
	expect(placed[0].has_area(), "Port overlap is allowed when no clear placement fits")

func test_status_strip_prefers_bottom_over_neighbor_corner_and_side_port() -> void:
	# A short pane below another pane, with a socket halfway down its left edge.
	var owner := Rect2(190, 220, 190, 110)
	var owners: Array[Rect2] = [owner]
	var obstacles: Array[Rect2] = [owner, Rect2(190, 107, 190, 110), Rect2(383, 107, 190, 223)]
	var ports: Array[Rect2] = [Rect2(179, 268, 12, 14)]
	var desired: Array[Rect2] = [Rect2(190, 133, 108, 84)]
	var placed := View.place_status_strips(desired, Rect2(0, 0, 700, 450), owners, obstacles, ports)
	expect(placed[0] == Rect2(190, 333, 108, 84), "Bottom edge clearly associates stats with their owner without covering its socket")

func test_status_strip_corner_remains_available_when_edges_are_blocked() -> void:
	var owners: Array[Rect2] = [Rect2(190, 220, 190, 110)]
	var desired: Array[Rect2] = [Rect2(190, 133, 108, 84)]
	var obstacles: Array[Rect2] = [owners[0], Rect2(190, 107, 190, 110)]
	var placed := View.place_status_strips(desired, Rect2(0, 0, 380, 330), owners, obstacles, [Rect2(179, 268, 12, 14)])
	expect(placed[0].has_area(), "A corner remains a fallback when full edges are obstructed")
	expect(placed[0].position.x < owners[0].position.x and placed[0].position.y < owners[0].position.y, "Fallback can extend above the owner's left edge")
