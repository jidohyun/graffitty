extends "res://tests/unit/test_case.gd"

class Connection extends Node:
	var url := "test://server"
	var epoch := "test-epoch"
	var server_hostname := "fixture-server"
	var display_name := "Office fixture"
	var workspace := "$2"
	var available_sessions := [{"id": "$1", "name": "other"}, {"id": "$2", "automatic_name": "graffitty"}]
	func wire_id(_id: int) -> int: return 7

class Host extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var presentation_active := true
	var pane_focus := "%1"
	var sessions: Dictionary = {}
	var chromiums: Dictionary = {}
	func is_terminal_pane(key: String) -> bool: return key.begins_with("%")
	func is_chromium_pane(_key: String) -> bool: return false
	func pane_title(_key: String) -> String: return "Agent task"

class Graph extends RefCounted:
	var nodes := {}
	var remote_owners := {}
	var edges := {}

class API extends RefCounted:
	var graph := Graph.new()

class Application extends Node:
	var hosts: Array = []
	var agent_api := API.new()
	var agent_attention := preload("res://scenes/AgentAttention.gd").new()
	func _init() -> void:
		agent_attention.application = self
		add_child(agent_attention)

func test_recorded_view_clears_tab_and_agent_completion_together() -> void:
	var app := Application.new()
	var host := Host.new()
	var connection := Connection.new()
	app.hosts = [host]
	host.workspace_layout.tabs = [
		{"id":1, "focused":"%1", "tree":{"type":"windows", "windows":[{"pane":"%1", "shown":true}]}},
		{"id":2, "focused":"%2", "tree":{"type":"windows", "windows":[{"pane":"%2", "shown":true}]}},
	]
	host.workspace_layout.active = 1
	app.agent_api.graph.nodes = {"%1": {"provider":"pi", "status":"busy"}}
	app.agent_api.graph.remote_owners = {"%1": connection}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	var refresh := func():
		app.agent_attention.refresh()
		controller.refresh()
	refresh.call()
	app.agent_api.graph.nodes["%1"].status = "idle"
	refresh.call()
	expect(app.agent_attention.marker(["%1"]).state == "completed" and controller.rows[0].status == "done",
		"Without native focus, both surfaces mark the completion unseen")
	app.agent_attention.in_view = func(view): return view == host and view.presentation_active
	refresh.call()
	expect(app.agent_attention.marker(["%1"]).state == "" and controller.rows[0].status == "idle",
		"The recorded view clears both markers without native window focus")
	app.agent_api.graph.nodes["%1"].status = "busy"
	refresh.call()
	app.agent_api.graph.nodes["%1"].status = "idle"
	refresh.call()
	expect(app.agent_attention.marker(["%1"]).state == "" and controller.rows[0].status == "idle",
		"A completion displayed in the recording never becomes unread")
	host.workspace_layout.active = 2
	app.agent_api.graph.nodes["%1"].status = "busy"
	refresh.call()
	app.agent_api.graph.nodes["%1"].status = "idle"
	refresh.call()
	expect(app.agent_attention.marker(["%1"]).state == "completed" and controller.rows[0].status == "done",
		"A background tab still marks an unseen completion")
	host.workspace_layout.active = 1
	refresh.call()
	expect(app.agent_attention.marker(["%1"]).state == "" and controller.rows[0].status == "idle",
		"Returning to the recorded tab clears both surfaces")
	controller.free()
	connection.free()
	host.free()
	app.free()

func test_controller_keeps_pins_across_local_id_remapping() -> void:
	var app := Application.new()
	var host := Host.new()
	var connection := Connection.new()
	app.hosts = [host]
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	for key in ["%1", "%999"]:
		host.pane_focus = key
		host.workspace_layout.tabs = [{"id":1, "focused":key, "tree":{"type":"windows", "windows":[{"pane":key, "shown":true}]}}]
		app.agent_api.graph.nodes = {key: {"provider":"pi", "status":"busy"}}
		app.agent_api.graph.remote_owners = {key: connection}
		controller.refresh()
		expect(controller.rows.size() == 1 and controller.rows[0].key == key, "Current local pane is listed")
		expect(controller.rows[0].remote == "Office fixture", "Agent row carries its configured remote display name")
		expect(controller.rows[0].session == "graffitty", "Agent row carries its server-owned automatic session name")
		if key == "%1": controller.pin(controller.rows[0].id, true)
		else: expect(controller.rows[0].pinned, "Wire identity preserves pin after reconnect remapping")
	connection.url = "shared://local"
	controller.refresh()
	expect(controller.rows.size() == 1 and controller.rows[0].remote.is_empty(), "Local agents remain listed without a connection label")
	expect(controller.rows[0].session == "graffitty", "Local agents still show their session")
	connection.available_sessions[1].name = "manual"
	controller.refresh()
	expect(controller.rows[0].session == "manual", "A user-set session name wins over the automatic name")
	connection.available_sessions = []
	controller.refresh()
	expect(controller.rows[0].session == "2", "Unknown session metadata falls back to its ID")
	connection.url = "test://server"
	controller.refresh()
	expect(controller.rows[0].remote == "Office fixture", "Remote agents keep their connection label")
	connection.epoch = "new-epoch"
	controller.refresh()
	expect(not controller.rows[0].pinned, "A new server epoch cannot inherit another terminal's pin")
	controller.free()
	connection.free()
	host.free()
	app.free()

class Peer extends Node:
	var url := "test://server"
	var epoch := "test-epoch"
	var display_name := "Office fixture"
	var server_hostname := "fixture-server"
	var connected := true
	var workspace := "$2"
	var available_sessions := [
		{"id": "$1", "name": "other", "agents": [
			{"pane": 3, "provider": "claude", "status": "waiting", "title": "", "program": null},
			{"pane": 4, "provider": "shell", "status": "unintegrated", "title": "", "program": {"state": "working", "app": "codex", "title": "", "msg": "Refactor"}}]},
		{"id": "$2", "automatic_name": "graffitty", "agents": [
			{"pane": 7, "provider": "pi", "status": "busy", "title": "", "program": null}]}]
	func wire_id(id: int) -> int: return 7 if id == 1 else id

class Backend extends RefCounted:
	var is_remote := true
	var connection: Node

class SessionHost extends Host:
	var session_backend := Backend.new()

func test_agents_in_other_sessions_and_servers_are_listed() -> void:
	var app := Application.new()
	var host := SessionHost.new()
	var peer := Peer.new()
	host.session_backend.connection = peer
	app.hosts = [host]
	host.workspace_layout.tabs = [{"id":1, "focused":"%1", "tree":{"type":"windows", "windows":[{"pane":"%1", "shown":true}]}}]
	app.agent_api.graph.nodes = {"%1": {"provider":"pi", "status":"busy"}}
	app.agent_api.graph.remote_owners = {"%1": peer}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	controller.refresh()
	expect(controller.rows.size() == 3, "Shown agent plus both agents of the unshown session are listed")
	var by_key := {}
	for row in controller.rows: by_key[row.key] = row
	expect(by_key.has("%1") and not by_key.has("%7"), "The shown view of an agent wins over its session summary")
	expect(by_key.has("%3") and by_key["%3"].session == "other" and by_key["%3"].remote == "Office fixture", "Unshown agents carry server and session captions")
	expect(by_key["%3"].status == "blocked", "Summary status maps like a shown agent's")
	expect(by_key.has("%4") and by_key["%4"].provider == "codex" and by_key["%4"].title == "Refactor", "OSC-reported agents use their program app and message")
	peer.url = "shared://local"
	controller.refresh()
	var local_row: Dictionary = controller.rows.filter(func(row): return row.key == "%3")[0]
	expect(local_row.remote.is_empty() and local_row.session == "other", "Local unshown agents show only their session")
	peer.connected = false
	app.agent_api.graph.remote_owners = {}
	controller.refresh()
	expect(controller.rows.is_empty(), "A disconnected server lists no stale agents")
	controller.free()
	host.free()
	peer.free()
	app.free()

func test_agents_command_and_bridge_states() -> void:
	expect("Agents" in preload("res://scenes/HostActions.gd").names(), "Agents is a registered command")
	var core: RefCounted = ClassDB.instantiate("AgentsCore")
	var input := [{"id":"test/epoch/1", "key":"%1", "title":"Test agent", "provider":"pi", "status":"busy", "looking":false, "focused":false}]
	var first: Dictionary = core.observe(input, 100)
	expect(first.rows[0].section == "Working" and first.sounds.is_empty(), "Working begins silently")
	input[0].status = "waiting"
	var wait: Dictionary = core.observe(input, 110)
	expect(wait.rows[0].section == "Needs you" and wait.sounds == ["blocked"], "Awaiting input raises attention")
	expect(core.observe(input, 111).sounds.is_empty(), "Repeated snapshots do not play a sound")
	input[0].status = "idle"
	var done: Dictionary = core.observe(input, 120)
	expect(done.rows[0].section == "Done" and done.sounds == ["done"], "An unseen completion is Done")
	input[0].looking = true
	input[0].focused = true
	var seen: Dictionary = core.observe(input, 130)
	expect(seen.rows[0].section == "Done" and seen.rows[0].status == "idle" and seen.rows[0].at == 120, "Focused completed row holds its group and duration")
	core.pin("test/epoch/1", true)
	expect(core.observe(input, 140).rows[0].section == "Pinned", "Pinning takes precedence")
	var restored: RefCounted = ClassDB.instantiate("AgentsCore")
	expect(restored.restore(core.save()).is_empty(), "Current schema restores")
	expect(restored.observe(input, 150).rows[0].pinned, "Pins survive restart")

func test_native_attention_output_rejects_invalid_input_without_opening_device() -> void:
	var audio: RefCounted = ClassDB.instantiate("AttentionAudio")
	expect(not audio.play(PackedVector2Array(), 44100).is_empty(), "Empty audio is rejected")
	expect(not audio.play(PackedVector2Array([Vector2.ONE]), 0).is_empty(), "Invalid sample rate is rejected")
	expect(not audio.play(PackedVector2Array([Vector2(NAN, 0)]), 44100).is_empty(), "Non-finite audio is rejected")
	var state: Dictionary = audio.poll()
	expect(state.active == 0 and state.completed == 0, "Invalid input never opens a native output")

func test_session_sound_toggle() -> void:
	var client := preload("res://scenes/Agents.gd").new()
	client._sounds = {"enabled": true, "blocked": "custom.ogg"}
	expect(client.sounds_enabled(), "Sound starts enabled from client configuration")
	client.toggle_sounds()
	expect(not client.sounds_enabled(), "Unchecking disables client sounds")
	client._play("blocked")
	expect(client._audio == null and client._streams.is_empty(), "Disabled toggle prevents playback")
	client.toggle_sounds()
	expect(client.sounds_enabled() and client._sounds.blocked == "custom.ogg", "Checking enables sounds without changing custom clips")
	client._sounds = {"enabled": false}
	client.toggle_sounds()
	expect(client.sounds_enabled(), "Session toggle can override a disabled saved setting")
	client.free()

func test_compressed_sound_and_client_settings() -> void:
	var sound: AudioStream = load("res://scenes/sounds/agent-attention.ogg")
	expect(sound is AudioStreamOggVorbis and sound.get_length() > 1.0 and sound.get_length() < 2.0, "Only the compressed notification is needed at runtime")
	var client := preload("res://scenes/Agents.gd").new()
	client._sounds = {"enabled":false}
	client._play("blocked")
	expect(client._streams.is_empty() and client._audio == null, "Disabled client audio does not load or play sounds")
	client.free()


class TreeTerm extends Node:
	pass

class TreeSession extends RefCounted:
	var foreground_app: Dictionary = {}

class TreeHost extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var pane_focus := "%1"
	var sessions: Dictionary = {}
	var chromiums: Dictionary = {}
	var titles: Dictionary = {}
	var focused := ""
	func is_terminal_pane(key: String) -> bool: return key.begins_with("%") and not chromiums.has(int(key.substr(1)))
	func is_chromium_pane(key: String) -> bool: return chromiums.has(int(key.substr(1)))
	func pane_title(key: String) -> String: return titles.get(key, key)
	var revealed := ""
	func focus_pane(key: String) -> void: focused = key
	# Hidden `gft pane run` children must be shown, as every other go-to-pane path does.
	func reveal_pane(key: String) -> void:
		revealed = key
		focus_pane(key)
	func terminal(id: int, spawned_by := -1, app := "") -> void:
		var term := TreeTerm.new()
		add_child(term)
		term.set_meta("spawned_by", spawned_by)
		var model := TreeSession.new()
		if not app.is_empty(): model.foreground_app = {"id": app}
		sessions[id] = {"term": term, "model": model}

class TreeChromium extends RefCounted:
	var owner_id := -1

class TreeConnection extends Connection:
	func wire_id(id: int) -> int: return id

func test_connected_panes_form_a_tree_under_the_first_agent() -> void:
	var app := Application.new()
	var host := TreeHost.new()
	var connection := TreeConnection.new()
	app.hosts = [host]
	host.terminal(1)
	host.terminal(2, 1, "python3")
	host.terminal(3, 2)
	host.terminal(4)
	host.terminal(6, 1)
	host.sessions[6].term.set_meta("filetree_owner", 1)
	var chromium := TreeChromium.new()
	chromium.owner_id = 1
	host.chromiums[5] = chromium
	host.titles = {"%1": "lead", "%2": "server", "%3": "logs", "%4": "helper", "%5": "docs"}
	var windows := []
	for item in [["%1", 0], ["%2", 300], ["%3", 300], ["%4", 900], ["%5", 600], ["%6", 1200]]:
		windows.append({"pane": item[0], "shown": true, "rect": Rect2(item[1], 0, 200, 100)})
	host.workspace_layout.tabs = [{"id": 1, "focused": "%1", "tree": {"type": "windows", "windows": windows}}]
	app.agent_api.graph.nodes = {"%1": {"provider": "pi", "status": "busy"}, "%4": {"provider": "claude", "status": "idle"}}
	app.agent_api.graph.remote_owners = {"%1": connection, "%4": connection}
	app.agent_api.graph.edges = {"%1/send>%4/in": {"from": "%1", "to": "%4", "send": true}}
	var controller := preload("res://scenes/Agents.gd").new()
	controller.application = app
	controller._sounds = {"enabled": false}
	controller.refresh()
	expect(controller.rows.size() == 1 and controller.rows[0].key == "%1", "The agent another agent points at leaves the top level")
	var subs: Array = controller.trees.get(controller.rows[0].id, [])
	expect(subs.map(func(s): return s.key) == ["%2", "%3", "%5", "%4"], "Children follow spawn, chromium and graph wires in reading order: %s" % [subs.map(func(s): return s.key)])
	expect(subs.map(func(s): return s.icon) == ["python", "terminal", "chromium", "claude"], "Programs, chromiums and agents get their own glyphs: %s" % [subs.map(func(s): return s.icon)])
	expect(subs[1].lines == ["│", "└"] and subs[3].lines == ["└"], "Tree lines nest grandchildren")
	expect(subs[3].status == "idle" and subs[3].has("row_id"), "A sub-agent carries its list status and identity")
	app.agent_api.graph.nodes["%4"].status = "offline"
	controller.refresh()
	var offline_subs: Array = controller.trees.get(controller.rows[0].id, [])
	var offline: Dictionary = offline_subs.filter(func(s): return s.key == "%4")[0]
	expect(offline.status == "offline" and offline.icon == "claude", "A closed connected agent keeps its identity and offline status for grayscale artwork")
	expect(not subs.any(func(s): return s.key == "%6"), "Filetree connections are hidden even when spawned by an agent")
	controller.focus_key(subs[0].host_id, subs[0].key)
	expect(host.focused == "%2" and host.revealed == "%2", "Clicking a connected pane reveals and focuses it")
	controller.free()
	connection.free()
	host.free()
	app.free()
