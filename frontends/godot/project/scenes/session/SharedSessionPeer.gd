extends RefCounted
## The common client owns attachment, request correlation and bounded polling.
## This adapter preserves RemoteConnection's packet interface for Godot rendering.
var native: RefCounted
var packets: Array = []
var last_text := false
var reason := ""
var options: Dictionary = {}

func connect_to_url(_endpoint: String) -> Error:
	if not ClassDB.class_exists("SessionClient"):
		reason = "Rebuild the Godot extension: shared session client is unavailable"
		return ERR_UNAVAILABLE
	native = ClassDB.instantiate("SessionClient")
	var launch_options := options.duplicate()
	var capabilities: Dictionary = launch_options.get("capabilities", {}).duplicate(true)
	var features: Array = capabilities.get("features", ["stream", "bell"])
	if "session-switch-v1" not in features: features.append("session-switch-v1")
	capabilities.features = features
	launch_options.capabilities = capabilities
	if str(launch_options.get("server", "")).is_empty() and OS.get_environment("GRAFFITTY_SERVER").is_empty():
		# Packaged apps and development checkouts use the same CLI locator.
		launch_options.server = preload("res://graffitty/executables.gd").cli()
	if native.connect_shared(JSON.stringify(launch_options)):
		return OK
	reason = native.last_error()
	return ERR_CANT_CONNECT

func poll() -> void:
	if native != null:
		packets.append_array(native.poll_packets())
		reason = native.last_error()

func get_ready_state() -> int:
	return WebSocketPeer.STATE_OPEN if native != null and native.is_open() else WebSocketPeer.STATE_CLOSED

func send_text(text: String) -> Error:
	return OK if native != null and native.send_packet(text.to_utf8_buffer(), true) else ERR_CONNECTION_ERROR

func send(bytes: PackedByteArray) -> Error:
	return OK if native != null and native.send_packet(bytes, false) else ERR_CONNECTION_ERROR

func get_available_packet_count() -> int:
	return packets.size()

func get_packet() -> PackedByteArray:
	var item: Dictionary = packets.pop_front()
	last_text = item.text
	return item.data

func was_string_packet() -> bool:
	return last_text

func close(_code := 1000, _reason := "") -> void:
	if native != null: native.disconnect_private()
	packets.clear()

func get_close_reason() -> String:
	return reason

func get_close_code() -> int:
	return 1000


func local_peer_pid() -> int:
	return native.local_peer_pid() if native != null and native.has_method("local_peer_pid") else -1

func take_native_packet() -> Dictionary:
	if not packets.is_empty() and (packets[0].has("native") or packets[0].has("chromium_header")):
		return packets.pop_front()
	return {}
