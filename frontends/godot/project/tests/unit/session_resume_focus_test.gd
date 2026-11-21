extends "res://tests/unit/test_case.gd"
const Client := preload("res://scenes/remote/RemoteClient.gd")

func _topology(active: Variant, focused: String) -> Dictionary:
	return {
		"tabs": [{"id": 1}, {"id": 5}],
		"panes": [{"id": 1, "tab": 1}, {"id": 5, "tab": 5}, {"id": 7, "tab": 5}, {"id": 9, "tab": 1}],
		"workspace_state": {"active": active, "order": [1, 5],
			"layout": {"tabs": {"1": {"focused": "%9"}, "5": {"focused": focused}}}},
	}

func test_switching_back_resumes_the_active_tab_and_its_focused_pane() -> void:
	expect(Client.resume_focus(_topology(5, "%7")) == 7, "the session's active tab and its focused pane")
	expect(Client.resume_focus(_topology(1, "%7")) == 9, "another tab keeps its own focus")

func test_missing_or_stale_state_falls_back() -> void:
	expect(Client.resume_focus(_topology(5, "")) == 5, "no focused pane: the active tab")
	expect(Client.resume_focus(_topology(5, "%9")) == 5, "a focused pane from another tab is ignored")
	expect(Client.resume_focus(_topology(42, "%7")) == 1, "a closed active tab: the first tab")
	expect(Client.resume_focus(_topology(null, "%7")) == 1, "no active tab: the first tab")
	expect(Client.resume_focus({"tabs": []}) == -1, "an empty session")

class StartupHost extends Node:
	var active_session_id := -1
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	func is_terminal_pane(key: String) -> bool: return key in ["%1", "%2"]

func test_flat_world_startup_keeps_the_restored_secondary_pane() -> void:
	var host := StartupHost.new()
	host.workspace_layout.tabs.assign([{"id": 1, "focused": "%1", "tree": {"windows": [{"pane": "%2"}, {"pane": "%1"}]}}])
	host.workspace_layout.active = 1
	var world := preload("res://scenes/Flat2DWorld.gd").new()
	world.host = host
	expect(world._initial_terminal() == 1, "Restored focus on %1 wins over tree order")
	host.workspace_layout.tabs[0].focused = "%9"
	expect(world._initial_terminal() == 2, "A missing remembered pane falls back to the first terminal")
	world.host = null
	world.free()
	host.free()
