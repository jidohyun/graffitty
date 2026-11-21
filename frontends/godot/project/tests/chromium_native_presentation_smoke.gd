extends SceneTree
## Native presentation belongs to the local Mac, never a remote server.
class Connection extends Node:
	var url := ""
	var connected := false

class Workspace extends Control:
	var fitted := ""
	func toggle_fit_pane(key: String) -> void: fitted = key

class Host extends Node:
	var workspace_view := Workspace.new()
	var chromiums := {}


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var app := root.get_node("TerminalApplication")
	var host := Host.new()
	root.add_child(host)
	host.add_child(host.workspace_view)
	var chromium := preload("res://scenes/remote/RemoteChromiumSession.gd").new()
	var connection := Connection.new()
	host.add_child(connection)
	chromium.connection = connection
	chromium.session_id = 42
	host.add_child(chromium)
	host.chromiums[42] = chromium
	app.hosts.append(host)
	if OS.get_name() == "macOS":
		for endpoint in ["shared://local", "ipc:///private/demo.sock"]:
			connection.url = endpoint
			chromium.open_native()
			assert(chromium._queue.pop_front().action == "chrome-native", endpoint)
			assert(host.workspace_view.fitted.is_empty())
	connection.url = "wss://example.invalid/session"
	chromium.open_native()
	assert(chromium._queue.is_empty(), "Remote presentation must not open a server window")
	assert(host.workspace_view.fitted == "%42")
	app.hosts.erase(host)
	host.free()
	print("CHROMIUM_NATIVE_PRESENTATION_PASS")
	call_deferred("quit")
