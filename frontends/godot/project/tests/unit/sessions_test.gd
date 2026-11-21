extends "res://tests/unit/test_case.gd"
const Model := preload("res://scenes/session/SessionsList.gd")

class Peer extends Node:
	var url := "test://remote"
	var display_name := "Remote fixture"
	var server_hostname := "fixture"
	var server_platform := "linux"
	var connected := true
	var workspace := "$1"
	var available_sessions := [{"id":"$1", "name":null, "automatic_name":"~"}, {"id":"$2", "name":"work", "automatic_name":"project"}]

class Backend extends RefCounted:
	var is_remote := true
	var connection: Node

class Host extends Node:
	var session_backend := Backend.new()

func test_desktop_always_offers_local_even_without_an_open_local_view() -> void:
	var groups := Model.collect([], [{"url": "test://remote", "name": "Remote fixture"}], true)
	expect(groups.size() == 2 and groups[0].local, "Desktop keeps This Computer above remote servers")
	expect(not groups[0].connected and groups[0].sessions.is_empty() and groups[0].peer == null, "Empty local entry does not invent sessions or a transport")
	expect(Model.collect([], [], false).is_empty(), "Mobile does not offer an unsupported local session server")

func test_groups_include_local_and_every_remote_without_duplicate_sessions() -> void:
	var parent := Node.new()
	var peers: Array[Node] = []
	var hosts: Array = []
	for url in ["test://remote", "shared://local", "test://remote"]:
		var host := Host.new()
		var peer := Peer.new()
		peer.url = url
		if hosts.size() == 2: peer.workspace = "$2"
		host.session_backend.connection = peer
		peers.append(peer)
		hosts.append(host)
		parent.add_child(host)
	var groups := Model.collect(hosts, [{"url": "test://offline", "name": "Offline fixture"}])
	expect(groups.size() == 3, "Local, connected remote and saved offline remote are represented")
	expect(groups[0].local and groups[0].name == "This computer", "Local computer is first")
	var remote: Dictionary = groups.filter(func(group): return group.id == "test://remote")[0]
	expect(remote.sessions.size() == 2, "Multiple views do not duplicate named sessions")
	expect(remote.sessions.all(func(row): return row.attached), "Each attached session retains its owning view")
	var offline: Dictionary = groups.filter(func(group): return group.id == "test://offline")[0]
	expect(not offline.connected and offline.sessions.is_empty(), "Offline status does not pretend sessions are known")
	parent.free()
	for peer in peers: peer.free()

func test_each_window_highlights_only_the_session_it_shows() -> void:
	var parent := Node.new()
	var windows: Array = []
	var peers: Array[Node] = []
	for session in ["$1", "$2"]:
		var window := Host.new()
		var peer := Peer.new()
		peer.url = "shared://local"
		peer.workspace = session
		window.session_backend.connection = peer
		parent.add_child(window)
		windows.append(window)
		peers.append(peer)
	var groups := Model.collect(windows, [])
	var shown := func(window) -> Array:
		var result := []
		for group in Model.rows(groups, [], window):
			for row in group.sessions:
				if row.viewing: result.append(row.id)
		return result
	expect(shown.call(windows[0]) == ["$1"], "The first window highlights only its own session")
	expect(shown.call(windows[1]) == ["$2"], "The second window highlights only its own session")
	expect(shown.call(null) == ["$1", "$2"], "Without a window, every shown session is marked")
	parent.free()
	for peer in peers: peer.free()

func test_disconnected_transport_does_not_publish_stale_sessions() -> void:
	var parent := Node.new()
	var host := Host.new()
	parent.add_child(host)
	var peer := Peer.new()
	peer.connected = false
	host.session_backend.connection = peer
	var groups := Model.collect([host], [])
	expect(groups.size() == 1 and not groups[0].connected, "Disconnected transport remains in list")
	expect(groups[0].sessions.is_empty(), "Stale topology is not offered for switching")
	parent.free()
	peer.free()

func test_saved_server_order_is_shared_and_local_stays_first() -> void:
	var parent := Node.new()
	var host := Host.new()
	parent.add_child(host)
	var peer := Peer.new()
	peer.url = "shared://local"
	host.session_backend.connection = peer
	var saved := [{"url":"test://z", "name":"Z"}, {"url":"test://a", "name":"A"}, {"url":"test://z", "name":"Z second session"}]
	var groups := Model.collect([host], saved)
	expect(groups.map(func(group): return group.id) == ["shared://local", "test://z", "test://a"], "Saved order wins over alphabetic order and duplicate sessions stay grouped")
	saved = [saved[1], saved[0], saved[2]]
	groups = Model.collect([host], saved)
	expect(groups.map(func(group): return group.id) == ["shared://local", "test://a", "test://z"], "Reordering is reflected on the next refresh")
	parent.free()
	peer.free()

func test_server_platform_icons() -> void:
	for platform in ["macos", "windows", "linux"]:
		var groups := Model.collect([], [{"url": "test://offline", "platform": platform}])
		expect(Model.icon_path(groups[0]) == "res://scenes/icons/os-%s.svg" % platform, "Saved servers retain OS icons while offline")
	expect(Model.icon_path({}) == "res://scenes/icons/monitor.svg", "Unknown OS uses a neutral computer, never an invented platform")
	var parent := Node.new()
	var host := Host.new()
	parent.add_child(host)
	var peer := Peer.new()
	host.session_backend.connection = peer
	var groups := Model.collect([host], [{"url": peer.url, "platform": "windows"}])
	expect(groups[0].platform == "linux", "Live platform takes precedence over saved metadata")
	parent.free()
	peer.free()

func test_sessions_action_and_shared_window_chrome() -> void:
	expect("AllSessions" in preload("res://scenes/HostActions.gd").names(), "AllSessions is registered for the command line")
	var window := preload("res://scenes/mods/PanelWindow.gd").new()
	window.mod_name = "sessions"
	expect(not window.exclusive and not window.unresizable, "Sessions is non-modal and resizable")
	expect(FileAccess.file_exists("res://mods/sessions/main.js") and FileAccess.file_exists("res://mods/agents/main.js"), "Sessions and Agents ship as panels in the shared panel window")
	for manifest in [preload("res://scenes/mods/ModService.gd").manifest("sessions"), preload("res://scenes/mods/ModService.gd").manifest("agents")]:
		expect(manifest.get("sides", []) == ["left", "right"], "Lists dock left or right only")
	window.free()


class Federation extends Node:
	var connections: Array = []
	var owners := {}
	var selected: Node

class Layout extends RefCounted:
	var active := 0

class FederatedHost extends Node:
	var session_backend := Backend.new()
	var workspace_layout := Layout.new()


func test_one_window_with_several_servers_views_only_its_active_tabs_session() -> void:
	var host := FederatedHost.new()
	var federation := Federation.new()
	var mac := Peer.new()
	var windows := Peer.new()
	mac.url = "test://mac"
	windows.url = "test://windows"
	windows.workspace = "$2"
	federation.connections = [mac, windows]
	federation.owners = {1: mac, 2: windows}
	federation.selected = mac
	host.session_backend.connection = federation
	var viewing := func() -> Array:
		var rows := []
		for group in Model.collect([host], []):
			for row in group.sessions:
				if row.viewing: rows.append(group.id + row.id)
		return rows
	host.workspace_layout.active = 2
	expect(viewing.call() == ["test://windows$2"], "Only the active tab's session is being viewed")
	host.workspace_layout.active = 1
	expect(viewing.call() == ["test://mac$1"], "Switching tab to another server moves the highlight")
	var attached := 0
	for group in Model.collect([host], []):
		attached += group.sessions.filter(func(row): return row.attached).size()
	expect(attached == 2, "Both servers still hold an attached session")
	host.free(); federation.free(); mac.free(); windows.free()
