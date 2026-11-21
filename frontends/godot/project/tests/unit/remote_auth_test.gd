extends "res://tests/unit/test_case.gd"

func test_server_address_normalization_is_shared_with_connection_persistence() -> void:
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var result: Dictionary = JSON.parse_string(auth.normalize_server_url("desktop.local"))
	expect(result.get("url") == "ws://desktop.local:7183", "Bare host uses the shared server port")
	var settings := {"url": "desktop.local:9000"}
	var helper := preload("res://scenes/remote/ClientAuthentication.gd")
	expect(helper.normalize_address(settings).is_empty() and settings.url == "ws://desktop.local:9000", "Forms normalize before looking up or remembering credentials")
	expect(not helper.normalize_address({"url": "https://desktop.local"}).is_empty(), "Unsupported schemes remain errors")


func test_heartbeat_survives_paused_polling_but_closes_a_silent_peer() -> void:
	var listener := TCPServer.new()
	expect(listener.listen(0, "127.0.0.1") == OK, "Loopback listener starts")
	var client := preload("res://scenes/remote/SecureWebSocketPeer.gd").new()
	expect(client.peer.heartbeat_interval > 0.0, "Production sockets detect silently lost connections")
	client.peer.heartbeat_interval = 0.05
	client.connect_to_url("ws://127.0.0.1:%d" % listener.get_local_port())
	var server := WebSocketPeer.new()
	var deadline := Time.get_ticks_msec() + 2000
	while client.get_ready_state() != WebSocketPeer.STATE_OPEN and Time.get_ticks_msec() < deadline:
		client.poll()
		if listener.is_connection_available(): server.accept_stream(listener.take_connection())
		server.poll()
		OS.delay_msec(1)
	expect(client.get_ready_state() == WebSocketPeer.STATE_OPEN, "Native WebSocket handshake succeeds")
	# First drain any initial heartbeat, then send a fresh ping and leave its
	# pong queued while the app's event loop is suspended past the timeout.
	deadline = Time.get_ticks_msec() + 100
	while Time.get_ticks_msec() < deadline:
		client.poll()
		server.poll()
		OS.delay_msec(1)
	OS.delay_msec(60)
	client.poll()
	client.poll()
	deadline = Time.get_ticks_msec() + 20
	while Time.get_ticks_msec() < deadline:
		server.poll()
		OS.delay_msec(1)
	OS.delay_msec(100)
	client.poll()
	client.poll()
	expect(client.get_ready_state() == WebSocketPeer.STATE_OPEN, "Resume reads a queued pong before checking its expired deadline")
	# Stop polling the server without closing TCP. Writes can still succeed,
	# but no pong arrives, just like a silently dropped mobile connection.
	deadline = Time.get_ticks_msec() + 500
	while client.get_ready_state() == WebSocketPeer.STATE_OPEN and Time.get_ticks_msec() < deadline:
		client.poll()
		OS.delay_msec(1)
	expect(client.get_ready_state() == WebSocketPeer.STATE_CLOSED, "An apparently open socket with no pong is closed within a bounded time")
	client.close(-1)
	server.close(-1)
	listener.stop()


class ChannelProbe extends RefCounted:
	var sealed := 0
	func seal(data: PackedByteArray, _text: bool) -> PackedByteArray:
		sealed += 1
		return data


func test_disconnected_sends_do_not_consume_encrypted_record_sequence() -> void:
	var socket := preload("res://scenes/remote/SecureWebSocketPeer.gd").new()
	expect(socket.send_text("late update") == ERR_CONNECTION_ERROR, "Closed plaintext transport rejects late text")
	expect(socket.send(PackedByteArray([1])) == ERR_CONNECTION_ERROR, "Closed plaintext transport rejects late bytes")
	var probe := ChannelProbe.new()
	socket.secure(probe)
	expect(socket.send_text("late update") == ERR_CONNECTION_ERROR, "Closed encrypted transport rejects late text")
	expect(socket.send(PackedByteArray([1])) == ERR_CONNECTION_ERROR, "Closed encrypted transport rejects late bytes")
	expect(probe.sealed == 0, "A detached transport cannot consume an encrypted record sequence")


func test_persistent_password_wire_login_and_legacy_rejection() -> void:
	var path := cache_directory().path_join("graffitty-auth-test-%d.json" % Time.get_ticks_usec())
	var server: RefCounted = ClassDB.instantiate("RemoteAuth")
	expect(server != null, "Native password authentication is available")
	if server == null:
		return
	var password := "test-only persistent password 한글"
	var saved: Dictionary = JSON.parse_string(server.save_settings(path, password, false, "", "", 6))
	expect(saved.get("ok", false), "Password registration succeeds")
	expect(not FileAccess.get_file_as_string(path).contains(password), "Config does not contain the password")
	for restart in range(2):
		var settings: Dictionary = JSON.parse_string(server.configure(path, "temporary fallback"))
		expect(settings.get("permanent", false), "Verifier survives server restart")
		var version: int = preload("res://scenes/remote/RemoteProtocol.gd").VERSION
		var legacy: Dictionary = JSON.parse_string(server.server_step(100 + restart, JSON.stringify({"type": "auth", "version": version, "token": "temporary fallback"})))
		expect(legacy.has("error"), "Plaintext tokens are never accepted")
		var client: RefCounted = ClassDB.instantiate("RemoteAuth")
		var context := {"type": "auth_start", "version": version, "features": ["bell"]}
		var start: Dictionary = JSON.parse_string(client.client_start(password, JSON.stringify(context)))
		context.message = start.message
		var challenge: Dictionary = JSON.parse_string(server.server_step(restart, JSON.stringify(context)))
		expect(client.client_channel() == null, "No channel before the password is verified")
		var finish: Dictionary = JSON.parse_string(client.client_finish(challenge.message))
		var result: Dictionary = JSON.parse_string(server.server_step(restart, JSON.stringify({"type": "auth_finish", "message": finish.message})))
		expect(result.get("type") == "authenticated", "OPAQUE login succeeds with persisted verifier")
		var channel: RefCounted = client.client_channel()
		var marker := "graffitty-plaintext-marker".to_utf8_buffer()
		var record: PackedByteArray = channel.seal(marker, true)
		expect(record.size() == 272, "Small messages share one padded record size")
		expect(not record.hex_encode().contains(marker.hex_encode()), "Records do not carry plaintext")
		expect(channel.open(record).has("error"), "A client cannot open its own records")
		server.server_forget(restart)
	DirAccess.remove_absolute(path)


func test_command_telegram_credentials_save_references_and_destination() -> void:
	var path := cache_directory().path_join("graffitty-command-auth-%d.json" % Time.get_ticks_usec())
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var saved: Dictionary = JSON.parse_string(auth.save_settings(path, "", false, "telegram-work", "123", 6))
	expect(saved.get("ok", false), "Command-backed Telegram setup saves without accessing a token")
	var settings: Dictionary = JSON.parse_string(auth.settings(path))
	expect(settings.get("telegram_credential") == "telegram-work", "The selected credential name persists")
	expect(settings.get("chat_id") == "123", "The non-secret destination persists separately")
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	expect(not document.has("telegram_profile"), "Obsolete fnox-specific schema is absent")
	expect(not document.has("token"), "Command-backed configuration contains no token")
	var invalid: Dictionary = JSON.parse_string(auth.save_settings(path, "", false, "telegram-work", "not-a-chat", 6))
	expect(invalid.has("error"), "Invalid destinations are rejected before saving")
	DirAccess.remove_absolute(path)


func test_remote_authentication_ui_compiles() -> void:
	for path in ["RemoteAccessSettings", "CredentialStore", "ClientAuthentication", "RemoteManager", "RemoteClient", "RemoteAccessControl"]:
		var script: GDScript = load("res://scenes/remote/%s.gd" % path)
		expect(script != null and script.can_instantiate(), path + " compiles")


func test_generated_temporary_password_length_survives_settings_reload() -> void:
	var path := cache_directory().path_join("graffitty-temporary-auth-%d.json" % Time.get_ticks_usec())
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var initial: Dictionary = JSON.parse_string(auth.configure(path, ""))
	expect(str(initial.get("temporary_password", "")).length() == 6, "New hosts default to a six-character temporary password")
	for length in [6, 8, 10]:
		var saved: Dictionary = JSON.parse_string(auth.save_settings(path, "", false, "", "", length))
		expect(saved.get("ok", false), "Temporary password length saves")
		var settings: Dictionary = JSON.parse_string(auth.settings(path))
		expect(settings.get("temporary_password_length") == length, "Length is available to the settings dialog")
		var configured: Dictionary = JSON.parse_string(auth.configure(path, ""))
		expect(str(configured.get("temporary_password", "")).length() == length, "Host uses selected temporary password length")
	DirAccess.remove_absolute(path)


func test_saved_ssh_password_identity_survives_tunnel_port_changes() -> void:
	var authentication := preload("res://scenes/remote/ClientAuthentication.gd")
	expect(authentication.account("ws://127.0.0.1:10001", "ssh:work") == authentication.account("ws://127.0.0.1:29999", "ssh:work"), "SSH host credentials do not depend on tunnel port")
	expect(authentication.account("ws://127.0.0.1:10001", "ssh:work") != authentication.account("ws://127.0.0.1:10001", "ssh:home"), "Different SSH hosts never share saved credentials")
