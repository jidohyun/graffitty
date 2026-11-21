extends "res://tests/unit/test_case.gd"
const Backend := preload("res://scenes/session/RemoteSessionBackend.gd")
const Connection := preload("res://scenes/remote/RemoteConnection.gd")


func activated_links(connection: Node, targets: Array[String]) -> Array[String]:
	var backend := Backend.new(connection)
	var terminal: Node = ClassDB.instantiate("Terminal")
	backend.configure_terminal(terminal)
	terminal.open_hyperlinks = false
	var opened: Array[String] = []
	terminal.hyperlink_activated.connect(func(uri: String): opened.append(uri))
	for target in targets:
		terminal.activate_hyperlink(target)
	terminal.free()
	return opened


func test_remote_clients_activate_only_web_urls() -> void:
	for endpoint in ["wss://server.example:7183", "ws://127.0.0.1:7183", "ipc:///tmp/remote-session"]:
		var connection := Connection.new()
		connection.url = endpoint
		var urls: Array[String] = ["http://example.test", "https://example.test/path", "HTTPS://example.test"]
		var targets := urls.duplicate()
		targets.append_array([
			"file:///tmp/server.txt", "FILE:///C:/server.txt", "/tmp/server.txt",
			"mailto:user@example.test", "ftp://example.test/file", "ssh://server.example",
			"javascript:alert(1)", "https://example.test/\nfile:///tmp/server.txt",
		])
		expect(activated_links(connection, targets) == urls, "Remote file links and non-web schemes never reach client handlers: " + endpoint)
		connection.free()


func test_federated_clients_use_the_same_link_policy() -> void:
	var connection := preload("res://scenes/remote/FederatedConnection.gd").new()
	expect(activated_links(connection, ["file:///tmp/server.txt", "https://example.test"]) == ["https://example.test"], "Combining servers retains web-only link activation")
	connection.free()


func test_local_desktop_sessions_keep_file_links() -> void:
	var connection := Connection.new()
	connection.url = "shared://local"
	var targets: Array[String] = ["file:///tmp/local.txt", "https://example.test"]
	var expected: Array[String] = ["https://example.test"] if OS.has_feature("mobile") else targets
	expect(activated_links(connection, targets) == expected, "Local desktop file links remain available while mobile always restricts schemes")
	connection.free()
