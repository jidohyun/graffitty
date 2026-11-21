extends RefCounted
## WebSocketPeer-shaped adapter; both transports feed RemoteConnection unchanged.
var native: RefCounted
var packets: Array = []
var last_text := false
var reason := ""

func connect_to_url(endpoint: String) -> Error:
	if not ClassDB.class_exists("SessionTransport"):
		reason = "Rebuild graffitty: private session transport is unavailable"
		return ERR_UNAVAILABLE
	native = ClassDB.instantiate("SessionTransport")
	return OK if native.connect_private(endpoint) else ERR_CANT_CONNECT

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
