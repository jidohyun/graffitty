extends "res://tests/unit/test_case.gd"
const Badge := preload("res://scenes/AgentStatusBadge.gd")
const Mods := preload("res://scenes/mods/ModService.gd")

func test_offline_icons_keep_their_identity_and_elapsed_time() -> void:
	var at := Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system()) - 24 * 60 - 5) + "Z"
	for provider in ["codex", "pi"]:
		var badge := Badge.new()
		badge.set_agent(provider, "busy")
		var artwork := badge.logo.texture
		badge.set_agent(provider, "offline")
		badge.status_history = [{"at": at, "status": "offline"}]
		expect(badge.visible and badge.logo.visible and badge.logo.texture == artwork, "Offline retains the provider's artwork")
		expect(badge.logo.material != null, "Offline artwork is desaturated")
		expect(badge.duration_label.visible and badge.duration_label.text == "24m", "Offline duration remains readable")
		badge.set_agent(provider, "idle")
		expect(badge.logo.material == null and badge.logo.texture == artwork, "Returning online restores the original artwork")
		badge.free()

func test_providerless_nodes_keep_their_name_and_status() -> void:
	var badge := Badge.new()
	badge.set_agent("", "idle", {"name":"Manual Prompt", "inputs":[], "outputs":[]})
	expect(badge.visible and badge.provider_label.text == "Manual Prompt", "A custom node does not need a fake provider to show its badge")
	badge.status_history = [{"at":"2030-01-01T00:31:15+00:00", "status":"idle"}]
	expect(not badge._get_tooltip(Vector2.ZERO).contains("()"), "Optional providers leave no empty tooltip suffix")
	badge.free()
	var groups: Array = preload("res://scenes/TabListSummary.gd").agents([
		{"kind":"custom", "status":"idle", "manifest":{"name":"Manual Prompt"}},
		{"kind":"custom", "status":"idle", "manifest":{"name":"Payload Inspector"}},
	])
	expect(groups.size() == 2, "Tab summaries retain distinct providerless nodes")

class API extends Node:
	var graph := preload("res://scenes/AgentGraph.gd").new()

class Host extends Node:
	func is_terminal_pane(key: String) -> bool: return key == "%1"
	var agent_api: Node
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	func resource_monitor_for(_id: int) -> Node: return null


func test_server_offsets_convert_to_client_local_time() -> void:
	for timestamp in ["2030-01-01T00:30:15.123+00:00", "2030-01-01T09:30:15+09:00", "2029-12-31T19:00:15-05:30", "2030-01-01T00:30:15Z"]:
		expect(Badge.local_timestamp(timestamp, 540) == "2030-01-01 09:30:15", "Server offsets normalize to the same client instant")
		expect(Badge.local_timestamp(timestamp, -480) == "2029-12-31 16:30:15", "Local conversion handles the previous date")
		expect(Badge.local_timestamp(timestamp, 345) == "2030-01-01 06:15:15", "Quarter-hour client offsets are preserved")
	expect(Badge.local_timestamp("", 540).is_empty(), "Missing timestamps do not become an invented time")


func test_strip_history_is_server_owned_and_newest_first() -> void:
	var history := [
		{"at": "2030-01-01T00:30:15+00:00", "provider": "codex", "status": "busy"},
		{"at": "2030-01-01T00:31:15+00:00", "provider": "codex", "status": "idle"},
	]
	var badge: Dictionary = Mods.agent_badge("codex", "idle", {}, history)
	var tooltip: String = badge.tooltip
	expect(tooltip.contains("Local time (UTC"), "Hover makes the displayed timezone explicit")
	expect(tooltip.find("Done (Codex)") < tooltip.find("Running (Codex)"), "Newest transition appears first with a readable status")
	expect(badge.since == Badge.unix_time("2030-01-01T00:31:15+00:00"), "The current status began at the last matching transition")
	expect(Mods.agent_badge("codex", "idle", {}, history).tooltip == tooltip, "Resource refreshes do not add or replace status history")
	expect(Mods.agent_badge("codex", "idle", {}, []).tooltip == "Codex · " + TranslationServer.translate("Done"), "Without history the hover is identity and status only")


func test_workspace_restores_history_from_server_snapshot() -> void:
	var host := Host.new()
	var api := API.new()
	host.agent_api = api
	var view := preload("res://scenes/WorkspaceView.gd").new()
	view.host = host
	var strip := Control.new()
	view.status_strips["%1"] = strip
	api.graph.changed.connect(view._refresh_status.bind("%1"))
	var connection := Node.new()
	var history := [{"at": "2030-01-01T00:31:15+00:00", "provider": "claude", "status": "waiting"}]
	var snapshot := {"nodes": [{"node": "%1", "provider": "claude", "status": "waiting", "status_history": history}]}
	api.graph.import_remote(connection, snapshot)
	var shown: Dictionary = view.pane_status["%1"].agent
	expect(shown.since == Badge.unix_time(history[0].at), "The owning server's snapshot reaches the actual status strip")
	expect(shown.tooltip.contains("Waiting (Claude)"), "Imported history appears in the badge tooltip")
	api.graph.import_remote(connection, {})
	expect(view.pane_status["%1"].agent == null, "Disconnect clears the presentation history")
	api.graph.import_remote(connection, snapshot)
	expect(view.pane_status["%1"].agent.tooltip == shown.tooltip, "Reconnecting restores the server's original times without inventing transitions")
	strip.free()
	view.free()
	host.free()
	api.graph.free()
	api.free()
	connection.free()


func test_duration_matches_herdr_agents_panel() -> void:
	for case in [[0.0, "<1m"], [59.9, "<1m"], [60.0, "1m"], [24 * 60 + 30, "24m"], [3599.0, "59m"], [3600.0, "1h"],
			[23 * 3600 + 3599, "23h"], [24 * 3600, "1d"], [9 * 86400, "9d"], [-300.0, "<1m"],
			[13 * 86400, "13d"], [14 * 86400, "2w"], [52 * 86400, "7w"], [61 * 86400, "2mo"], [364 * 86400, "12mo"], [800 * 86400, "2y"]]:
		expect(Badge.elapsed(case[0]) == case[1], "%s seconds shows %s, got %s" % [case[0], case[1], Badge.elapsed(case[0])])


func test_status_duration_starts_at_the_last_server_change() -> void:
	var history := [{"at": "2030-01-01T00:00:00+00:00", "status": "busy"}, {"at": "2030-01-01T09:30:15.500+09:00", "status": "idle"}]
	var start := Badge.unix_time("2030-01-01T00:30:15Z") + 0.5
	expect(is_equal_approx(Badge.status_since(history, "idle"), start), "The current status began at its own entry, across offsets and fractions")
	expect(Badge.status_since(history, "busy") < 0, "History that ended in another status is not evidence for this one")
	expect(Badge.status_since([], "idle") < 0 and Badge.status_since([{"at": "soon", "status": "idle"}], "idle") < 0, "Missing or malformed history shows no duration")
	var badge := Badge.new()
	badge.set_agent("claude", "idle")
	expect(not badge.duration_label.visible, "No history, no duration")
	var now := Time.get_unix_time_from_system()
	var at := Time.get_datetime_string_from_unix_time(int(now) - 24 * 60 - 5) + "Z"
	badge.status_history = [{"at": at, "status": "idle"}]
	expect(badge.duration_label.visible and badge.duration_label.text == "24m", "The strip shows how long the agent has been idle: " + badge.duration_label.text)
	badge.set_agent("claude", "busy")
	expect(not badge.duration_label.visible, "A new status hides the old duration until the server records it")
	badge.status_history = [{"at": at, "status": "idle"}, {"at": Time.get_datetime_string_from_unix_time(int(now)) + "Z", "status": "busy"}]
	expect(badge.duration_label.text == "<1m", "A fresh status starts under a minute")
	badge.free()
