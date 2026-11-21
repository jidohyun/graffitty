extends RefCounted
## Godot's WebSocketPeer carrying the login's encrypted channel. Messages pass
## unchanged until `secure()` installs the channel right after auth_finish.
##
## From then on every message in both directions is a channel record, and a
## plaintext, forged, replayed or reordered record closes the connection.

var peer := WebSocketPeer.new()
var channel: RefCounted
## Why the channel closed the connection; empty while it is healthy.
var failure := ""
var _text := false
var _last_poll_msec := 0
var _no_delay_set := false


func _init() -> void:
	# One 8 MiB session message plus its record overhead.
	peer.inbound_buffer_size = 8388608 + 65536
	peer.outbound_buffer_size = 262144
	peer.max_queued_packets = 128
	# A mobile network/VPN can silently discard an idle TCP connection. Native
	# WebSocket ping/pong times it out so RemoteConnection can reconnect.
	peer.heartbeat_interval = 5.0


func secure(value: RefCounted) -> void:
	channel = value


func connect_to_url(url: String) -> int:
	_no_delay_set = false
	return peer.connect_to_url(url)


func poll() -> void:
	var now := Time.get_ticks_msec()
	var interval := peer.heartbeat_interval
	if interval > 0.0 and now - _last_poll_msec >= int(interval * 1000):
		# Godot checks heartbeat expiry before reading the socket. After Android
		# suspends polling, consume a queued pong before allowing that check.
		peer.heartbeat_interval = 0.0
		peer.poll()
		peer.heartbeat_interval = interval
	else:
		peer.poll()
	_last_poll_msec = now
	if not _no_delay_set and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		# Input and video credits are small latency-sensitive packets. Enable
		# TCP_NODELAY once the peer has established its underlying TCP stream.
		peer.set_no_delay(true)
		_no_delay_set = true


func get_ready_state() -> int:
	return peer.get_ready_state()


func get_available_packet_count() -> int:
	return 0 if not failure.is_empty() else peer.get_available_packet_count()


func get_close_code() -> int:
	return peer.get_close_code()


func get_close_reason() -> String:
	return failure if not failure.is_empty() else peer.get_close_reason()


func close(code := 1000, reason := "") -> void:
	peer.close(code, reason)


func send_text(text: String) -> int:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN: return ERR_CONNECTION_ERROR
	return peer.send_text(text) if channel == null else _send(text.to_utf8_buffer(), true)


func send(data: PackedByteArray, _write_mode := WebSocketPeer.WRITE_MODE_BINARY) -> int:
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN: return ERR_CONNECTION_ERROR
	return peer.send(data) if channel == null else _send(data, false)


func get_packet() -> PackedByteArray:
	var packet := peer.get_packet()
	_text = peer.was_string_packet()
	if channel == null:
		return packet
	if _text:
		return _fail("Unencrypted message on an encrypted connection")
	var opened: Dictionary = channel.open(packet)
	if opened.has("error"):
		return _fail(str(opened.error))
	_text = opened.text
	return opened.data


func was_string_packet() -> bool:
	return _text


func _send(data: PackedByteArray, text: bool) -> int:
	if not failure.is_empty() or peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_CONNECTION_ERROR
	var record: PackedByteArray = channel.seal(data, text)
	if record.is_empty():
		_fail("Encrypted session failed")
		return ERR_CONNECTION_ERROR
	return peer.send(record)


func _fail(reason: String) -> PackedByteArray:
	failure = reason
	peer.close(1002, reason)
	return PackedByteArray()
