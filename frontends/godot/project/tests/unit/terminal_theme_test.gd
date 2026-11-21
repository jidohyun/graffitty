extends "res://tests/unit/test_case.gd"

const Connection := preload("res://scenes/remote/RemoteConnection.gd")
const Client := preload("res://scenes/remote/RemoteClient.gd")
const Federation := preload("res://scenes/remote/FederatedConnection.gd")

class Peer extends RefCounted:
	var sent: Array = []
	var documents: Array[String] = []
	func send_text(text: String) -> int:
		documents.append(text)
		sent.append(JSON.parse_string(text))
		return OK
	func send(_bytes: PackedByteArray) -> int:
		sent.append({"type": "input"})
		return OK

class TerminalStub extends Node:
	signal input_ready
	signal colors_changed
	var document := {}
	func remote_theme() -> Dictionary: return document
	func remote_take_input() -> PackedByteArray: return "pi\r".to_utf8_buffer()
	func remote_take_attachment() -> Dictionary: return {}

class Host extends Node:
	var sessions := {}

func test_native_theme_exports_resolved_defaults_and_sparse_palette() -> void:
	var terminal := ClassDB.instantiate("Terminal") as Node
	var config := preload("res://graffitty/terminal_config.gd").new()
	var changed := []
	terminal.colors_changed.connect(func(): changed.append(true))
	terminal.set_colors(config.background.color, config.foreground, config.cursor_color, config.palette)
	terminal.set_palette_color(200, Color("#123456"))
	var theme: Dictionary = terminal.remote_theme()
	expect(theme.background == [40, 44, 52], "Terminal queries keep the gray theme independently of the world's backdrop")
	expect(theme.foreground == [255, 255, 255] and theme.cursor == [255, 255, 255], "Foreground and cursor defaults are explicit")
	expect(theme.scheme == "dark", "Publish the displayed light/dark scheme")
	expect(theme.palette.size() == 256 and theme.palette[2] == [181, 189, 104], "Resolve the entire palette including configured ANSI slots")
	expect(theme.palette[200] == [18, 52, 86], "Include sparse extended palette overrides")
	expect(changed.size() == 2, "Both full and sparse changes notify the transport adapter")
	terminal.free()

func test_theme_publication_is_scoped_deduplicated_and_republished_on_attach() -> void:
	var terminal := ClassDB.instantiate("Terminal") as Node
	terminal.set_colors(Color("#282c34"), Color.WHITE, Color.WHITE, PackedColorArray())
	var document: Dictionary = terminal.remote_theme()
	var connection := Connection.new()
	var peer := Peer.new()
	connection.socket = peer
	connection.connected = true
	connection.workspace = "$1"
	connection.subscribe([7])
	peer.sent.clear()
	connection.set_terminal_theme(8, document)
	expect(peer.sent.is_empty(), "Never publish an unsubscribed terminal's theme")
	connection.set_terminal_theme(7, document)
	connection.set_terminal_theme(7, document)
	expect(peer.sent.size() == 1 and peer.sent[0].type == "terminal_theme" and peer.sent[0].session == 7, "Publish one canonical document per change")
	expect(peer.sent[0].theme.background == [40.0, 44.0, 52.0], "The transport keeps RGB values intact")
	expect(not ".0" in peer.documents.back(), "The wire carries integer channels accepted by the shared Rust schema")
	connection.subscribe([])
	connection.subscribe([7])
	peer.sent.clear()
	connection.set_terminal_theme(7, document)
	expect(peer.sent.size() == 1, "Reattaching republishes even when local colours are unchanged")
	connection._receive({"type": "session_switched", "workspace": "other"})
	expect(connection.terminal_themes.is_empty(), "Switching sessions cannot reuse old publication state")
	connection.connected = false
	peer.sent.clear()
	connection.set_terminal_theme(7, document)
	expect(peer.sent.is_empty(), "Offline theme publication waits for a new subscription")
	terminal.free()
	connection.free()

func test_input_publishes_changed_theme_first_and_federation_routes_to_owner() -> void:
	var terminal := TerminalStub.new()
	terminal.document = {"background": [40, 44, 52]}
	var host := Host.new()
	host.sessions[7] = {"term": terminal}
	var connection := Connection.new()
	var peer := Peer.new()
	connection.socket = peer
	connection.connected = true
	connection.workspace = "$1"
	connection.subscribe([7])
	var client := Client.new()
	client.connection.free()
	client.connection = connection
	client.host = host
	client._bind_terminal_input(7)
	peer.sent.clear()
	terminal.document = {"background": [50, 54, 62]}
	client._flush_terminal_input(7)
	expect(peer.sent.size() == 2 and peer.sent[0].type == "terminal_theme" and peer.sent[1].type == "input", "A program cannot query stale colours when launched by this input")
	var federation := Federation.new()
	federation.owners[7] = connection
	peer.sent.clear()
	federation.set_terminal_theme(7, {"background": [60, 64, 72]})
	expect(peer.sent.size() == 1 and peer.sent[0].session == 7, "Federated views publish to the terminal's owning transport")
	federation.free()
	client.free()
	host.free()
	terminal.free()
	connection.free()
