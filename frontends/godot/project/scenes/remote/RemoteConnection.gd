extends Node
signal chromium_received(session: int, data: PackedByteArray)
signal chromium_video_received(session: int, header: Dictionary, data: PackedByteArray)
signal chromium_gpu_state_received(session: int, active: bool)
signal resources_received(session: int, data: Dictionary, interval: float)
signal notification_received(session: int, event: Dictionary)
signal clipboard_received(session: int, event: Dictionary)
signal code_required
signal authentication_failed(message: String)
signal connection_failed(message: String)
signal authenticated
signal session_closed
signal sessions_changed
signal session_switching
signal session_switched
signal changed
## Volatile pane fields (titles, foreground app, holds, filetree) arrived as a
## `pane_update` delta and were merged into `topology`. Cheaper than `changed`:
## the structure is unchanged, so listeners only refresh those panes.
signal panes_updated(ids: Array)
const Protocol := preload("res://scenes/remote/RemoteProtocol.gd")
const SecurePeer := preload("res://scenes/remote/SecureWebSocketPeer.gd")
signal terminal_received(session: int, frame: Dictionary, data: PackedByteArray)
signal terminal_input_received(session: int, keys: Array)
var scene_flow := 0
## Highest chromium frame handled per wire session this poll, acknowledged once.
var _chromium_acks: Dictionary[int, int] = {}
var scene_decoder: RefCounted
var terminal_gpu: RefCounted
## Chromium video beside the WebSocket once the owner offered its UDP port.
## Its messages are the same GRT2 chromium packets; everything else, including
## acknowledgements and keyframe requests, stays on the WebSocket.
var video_datagrams: RefCounted
## The owner's `video_datagram` offer from `ready`; empty when none was made.
var _video_offer: Dictionary = {}
var _video_confirmed_once := false
var _video_signature := ""
var _video_checked_at := 0
var terminal_gpu_negotiating := false
var terminal_asset_requests: Array[Dictionary] = []

var stats := { "packets": 0, "bytes": 0 }
signal state_changed(message: String)
## Chromium video moved between datagrams and the WebSocket, or the reason it
## uses the WebSocket changed. Details come from `video_transport()`.
signal video_transport_changed
signal history_received(session: int, text: String)
signal acknowledged(message: Dictionary)
var server_fonts := preload("res://scenes/remote/ServerFonts.gd").new()
var shared_options: Dictionary = {}
var authentication: RefCounted
var password_verified := false
var socket: RefCounted
var workspace := ""
## Device-local view preference, never part of server authentication.
var preferred_session := ""
## Whether the last reported session switch only returned this connection to
## the session it was already showing, after its socket was replaced (the app
## came back from the background, or the network dropped). The view is
## rebuilt, but nothing was switched.
var session_reattached := false
## The session this connection last presented; it survives a reconnect.
var _shown_session := ""
## The session viewed before the current one, for LastSession.
var last_session := ""
var available_sessions: Array = []
var sessions_known := false
var stops_when_empty := false
var _selecting_session := -1
var namespace_ids := false
var _mapped_topology_parts := {}
var _core: RefCounted = ClassDB.instantiate("RemoteClientCore")
var local_ids: Dictionary[int, int]:
	get: return _core.local_ids()
	set(value):
		_core.seed_ids(value)
		_mapped_topology_parts.clear()
var url := ""
var server_hostname := ""
# Local presentation name; never sent to the server.
var display_name := ""
var server_alias := ""
var controller_identity := ""
var server_platform := ""
var server_username := ""
var token := ""
var connected := false
var epoch := ""
var topology: Dictionary = { "tabs": [], "panes": [], "edges": [] }
## Counts topology messages; acknowledgements only patch workspace_state.
var topology_generation := 0
## Acknowledgements patch workspace state too, but cannot confirm that the
## matching pane geometry and size owner have arrived in a full topology.
var topology_received_revision := -1
var frames: Dictionary = { }
var subscriptions: Array = []
## Desired panes can outlive a socket; these panes were subscribed on this one.
var _subscribed: Array = []
var terminal_themes: Dictionary = {}
var stream_quality: Dictionary = {}
var chromium_viewports: Dictionary = {}
## The demand the owner holds: wire IDs last sent, limited to subscribed panes.
var sent_chromium_viewports: Dictionary = {}
const CONNECT_TIMEOUT_MSEC := 10000
const RETRY_DELAY_MSEC := 3000
var connect_deadline := 0
var status_message := "Disconnected"
var status_source := "Disconnected"
var status_args: Array = []
var retry_at := 0
## Returning to the app: the first reconnect is immediate, not RETRY_DELAY_MSEC
## later. A link that fails again backs off as usual.
const RESUME_GRACE_MSEC := 5000
var _resumed_at := -RESUME_GRACE_MSEC
var _resume_retry := false
var enabled := false
var auth_sent := false
var sequence := 0
var last_error := ""
var frontend_generation := 0
var frontend_inflight := 0


func connect_remote(endpoint: String, secret: String) -> void:
	disconnect_remote()
	shared_options.clear()
	url = endpoint
	token = secret
	enabled = true
	last_error = ""
	retry_at = 0
	_open()


func connect_shared(options: Dictionary) -> void:
	disconnect_remote()
	shared_options = options.duplicate(true)
	workspace = str(options.get("workspace", ""))
	url = "shared://local"
	enabled = true
	last_error = ""
	retry_at = 0
	_open()


func _open() -> void:
	_subscribed.clear()
	_core.controller_stop()
	_stop_video_datagrams()
	terminal_themes.clear()
	_mapped_topology_parts.clear()
	sent_chromium_viewports = {}
	server_fonts.cancel_download()
	if terminal_gpu != null:
		terminal_gpu.close()
	terminal_gpu = null
	terminal_gpu_negotiating = false
	terminal_asset_requests.clear()
	scene_decoder = null
	scene_flow = 0
	if url == "shared://local":
		socket = preload("res://scenes/session/SharedSessionPeer.gd").new()
		socket.options = shared_options.duplicate(true)
		var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
		if not codecs.is_empty():
			var capabilities: Dictionary = socket.options.get("capabilities", {}).duplicate(true)
			capabilities.chromium_video = Array(codecs)
			socket.options.capabilities = capabilities
	elif url.begins_with("ipc://"):
		socket = preload("res://scenes/session/PrivateSessionPeer.gd").new()
	else:
		socket = SecurePeer.new()
	auth_sent = url == "shared://local"
	password_verified = auth_sent
	authentication = ClassDB.instantiate("RemoteAuth")
	connected = false
	connect_deadline = Time.get_ticks_msec() + CONNECT_TIMEOUT_MSEC
	if last_error.is_empty():
		_set_state("Connecting…")
	var err: int = socket.connect_to_url(url)
	if err != OK:
		var detail: String = socket.get_close_reason()
		_network_failed(detail if not detail.is_empty() else error_string(err))


func disconnect_remote() -> void:
	_subscribed.clear()
	_core.controller_stop()
	server_fonts.cancel_download()
	if is_inside_tree(): get_node("/root/Localization").remove_server(self)
	if connected and url == "shared://local" and frontend_generation > 0 and socket != null:
		socket.send_text(JSON.stringify({"type": "frontend_unregister"}))
	if terminal_gpu != null:
		terminal_gpu.close()
	terminal_gpu = null
	terminal_gpu_negotiating = false
	terminal_asset_requests.clear()
	scene_decoder = null
	scene_flow = 0
	enabled = false
	connected = false
	_stop_video_datagrams()
	_clear_resources()
	if socket != null:
		socket.close(1000, "Client detached")
	socket = null
	_set_state("Disconnected")


func _set_state(message: String, args: Array = []) -> void:
	status_source = message
	status_args = args.duplicate()
	# State observers keep canonical text; only presentation translates it.
	status_message = message if args.is_empty() else message % args
	state_changed.emit(status_message)


func _network_failed(reason: String) -> void:
	_core.controller_stop()
	connected = false
	_stop_video_datagrams()
	_clear_resources()
	auth_sent = false
	last_error = reason if not reason.is_empty() else "Server unreachable"
	if socket != null:
		socket.close()
	socket = null
	var now := Time.get_ticks_msec()
	# The system drops a backgrounded app's sockets; that loss is only seen on
	# return, when the server is reachable again straight away.
	var resuming := _resume_retry and now - _resumed_at < RESUME_GRACE_MSEC
	_resume_retry = false
	retry_at = now if resuming else now + RETRY_DELAY_MSEC
	_set_state("Offline — %s. Check the server and network/VPN. Retrying automatically…", [last_error])


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_resumed_at = Time.get_ticks_msec()
		_resume_retry = true
		# Already waiting out a retry delay from before the pause: connect now.
		if enabled and socket == null: retry_at = 0


func _process(_dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_dt)
	preload("res://graffitty/frame_profile.gd").add("RemoteConnection", Time.get_ticks_usec() - profiled_started)


func _process_body(_dt: float) -> void:
	if Time.get_ticks_msec() - _video_checked_at >= 250:
		_video_checked_at = Time.get_ticks_msec()
		var video := video_transport()
		var signature := "%s|%s|%s" % [video.get("transport", ""), video.get("reason", ""), video.get("streaming", false)]
		if signature != _video_signature:
			_video_signature = signature
			video_transport_changed.emit()
	if terminal_gpu != null:
		for prepared in terminal_gpu.poll():
			terminal_received.emit(local_id(int(prepared.session)), prepared, PackedByteArray())
		if not terminal_gpu.last_error().is_empty():
			_reject_terminal_gpu()
	if scene_decoder != null:
		for prepared in scene_decoder.poll():
			var id := local_id(int(prepared.session))
			if id not in subscriptions: continue
			if prepared.has("error"):
				send_action("terminal_resync", id)
			else:
				if prepared.has("columns"):
					frames[id] = prepared
				terminal_received.emit(id, prepared, PackedByteArray())
		# Delivery above consumes the prepared mailbox. Checking before poll()
		# adds a full frame to every credit round trip and starves slow clients.
		# Pending decoder jobs or undelivered results still retain their credit.
		if scene_flow > 0 and scene_decoder.idle():
			if send_action("scene_ack", -1, {"sequence": scene_flow}) >= 0:
				scene_flow = 0
	if scene_decoder == null and scene_flow > 0:
		if send_action("scene_ack", -1, {"sequence": scene_flow}) >= 0: scene_flow = 0
	if not enabled:
		return
	if socket == null:
		if _core.poll_action(enabled, -1, false, Time.get_ticks_msec(), connect_deadline, retry_at) == 1:
			_open()
		return
	socket.poll()
	var state: int = socket.get_ready_state()
	# The owner may close the transport in the same poll as its final replies.
	# Consume buffered acknowledgements/session_closed before treating EOF as a
	# network failure, for both native IPC and WebSocket clients.
	var buffered: bool = socket.get_available_packet_count() > 0
	var action: int = _core.poll_action(enabled, state, buffered, Time.get_ticks_msec(), connect_deadline, retry_at)
	if action == 3:
		var reason: String = socket.get_close_reason()
		var code: int = socket.get_close_code()
		if _core.close_action(code, password_verified) == 1:
			_auth_error(reason if not reason.is_empty() else "Authentication rejected")
		elif _core.close_action(code, password_verified) == 2:
			_connection_error(reason if not reason.is_empty() else tr("Server closed the connection (%d)") % code)
		else:
			_network_failed(reason)
		return
	if action == 4:
		_network_failed("Connection timed out")
		return
	if action != 2:
		return
	if connected:
		for request in _core.controller_poll():
			if socket.send_text(JSON.stringify(request)) != OK:
				_network_failed("Server unreachable")
				return
	if not auth_sent and state == WebSocketPeer.STATE_OPEN:
		var context := { "type": "auth_start", "version": Protocol.VERSION, "features": ["scene-flow-v1", "session-switch-v1", "clipboard"], "chromium_image_format": "png" }
		# Owners offer datagrams only to encrypted logins; local ones ignore it.
		if ClassDB.class_exists("VideoDatagramLink"):
			context.features.append("video-datagram-v1")
		# Saved settings come back from JSON as floats; the limits are integers.
		var stream := {}
		for key in stream_quality: stream[key] = int(stream_quality[key])
		context.chromium_stream = stream
		if ClassDB.class_exists("ChromiumVideoDecoder"):
			var codecs := preload("res://scenes/remote/ChromiumVideoSupport.gd").codecs()
			if not codecs.is_empty():
				context.chromium_video = Array(codecs)
		if url.begins_with("ipc://"):
			context.workspace = workspace
			context.type = "auth_local"
			context.token = token
			password_verified = true
			socket.send_text(JSON.stringify(context))
			auth_sent = true
			return
		if authentication == null:
			_auth_error("Native authentication support is missing")
			return
		var reply: Dictionary = JSON.parse_string(authentication.client_start(token, JSON.stringify(context)))
		if reply.has("error"):
			_auth_error(str(reply.error))
			return
		context.message = reply.message
		socket.send_text(JSON.stringify(context))
		auth_sent = true
	# Network readiness must not monopolize the same thread as touch and
	# animation. Leave excess packets queued; scene credits bound the sender.
	#
	# Chromium frames are bounded by the server's frame window instead: a frame
	# left queued only delays its acknowledgement and therefore the next frame,
	# which held a tablet at one frame per rendered frame.
	var receive_deadline := Time.get_ticks_usec() + 2000
	var received_packets := 0
	while socket != null and socket.get_available_packet_count() > 0:
		if received_packets >= 32 or Time.get_ticks_usec() >= receive_deadline: break
		received_packets += 1
		var packet_started := Time.get_ticks_usec()
		if socket.has_method("take_native_packet"):
			var prepared: Dictionary = socket.take_native_packet()
			if not prepared.is_empty():
				if prepared.has("chromium_header"):
					_receive_chromium(JSON.parse_string(prepared.chromium_header), prepared.data)
					receive_deadline += Time.get_ticks_usec() - packet_started
					received_packets -= 1
					continue
				if local_id(int(prepared.session)) not in subscriptions: continue
				if prepared.has("columns"):
					frames[local_id(int(prepared.session))] = prepared
				terminal_received.emit(local_id(int(prepared.session)), prepared, PackedByteArray())
				continue
		if scene_decoder != null and not scene_decoder.ready_for_packet():
			break
		var packet: PackedByteArray = socket.get_packet()
		if socket is SecurePeer and not socket.failure.is_empty():
			_connection_error(socket.failure)
			return
		if packet.size() > 8388608:
			_connection_error("Server message exceeds the size limit")
			return
		if not socket.was_string_packet():
			if not connected:
				_auth_error("Unexpected data before authentication")
				return
			var decoded := Protocol.unpack(packet)
			if decoded == null or decoded.header.get("type") not in ["terminal", "chromium", "terminal_asset", "terminal_asset_gpu"]:
				_connection_error("Invalid server packet")
				return
			if decoded.header.type == "terminal_asset_gpu":
				if terminal_gpu != null:
					terminal_gpu.describe(decoded.header)
				elif local_id(int(decoded.header.session)) in subscriptions:
					send_action("terminal_asset_request", local_id(int(decoded.header.session)), {"asset": decoded.header.asset})
				continue
			if local_id(int(decoded.header.session)) not in subscriptions:
				# A subscription change can overtake packets already on the wire.
				# Acknowledge flow, but never decode an inactive scene.
				scene_flow = int(decoded.header.get("flow", scene_flow))
				continue
			if decoded.header.type in ["terminal", "terminal_asset"]:
				if scene_decoder == null:
					scene_decoder = ClassDB.instantiate("TerminalSceneDecoder")
				if not scene_decoder.submit(decoded.header_json, decoded.payload):
					_connection_error("Invalid terminal scene packet")
					return
				scene_flow = int(decoded.header.get("flow", scene_flow))
				continue
			var id := local_id(int(decoded.header.session))
			if decoded.header.type == "chromium":
				_receive_chromium(decoded.header, decoded.payload)
				receive_deadline += Time.get_ticks_usec() - packet_started
				received_packets -= 1
				continue
			decoded.header.session = id
			frames[id] = decoded.header
			stats.packets += 1
			stats.bytes += packet.size()
			terminal_received.emit(id, decoded.header, decoded.payload)
			continue
		var decoded: Dictionary = _core.decode_message(packet)
		if decoded.has("message"):
			_receive(decoded.message)
		else:
			_connection_error(str(decoded.error))
			return
	_receive_video_datagrams()
	_acknowledge_chromium()


## The owner's UDP port is reached at the address the WebSocket connected to,
## so DNS and VPN routing match. Without a reply video stays on the WebSocket.
func _start_video_datagrams(offer: Variant) -> void:
	_stop_video_datagrams()
	if not (offer is Dictionary) or not (socket is SecurePeer) or authentication == null:
		return
	var host: String = socket.peer.get_connected_host()
	if host.is_empty(): return
	_video_offer = {"host": host, "port": int(offer.get("port", 0))}
	video_datagrams = authentication.video_datagram_link(host, int(offer.get("port", 0)), int(offer.get("ssrc", 0)))


func _stop_video_datagrams() -> void:
	if video_datagrams != null:
		video_datagrams.stop()
	video_datagrams = null
	_video_offer = {}
	_video_confirmed_once = false


## How this connection's chromium video travels, for the status line.
## `transport` is "datagram" or "websocket"; a WebSocket `reason` says why:
## "unoffered", "unavailable" (no UDP socket here), "no_reply" or "stopped".
##
## Local connections share GPU textures and report nothing.
func video_transport() -> Dictionary:
	if not connected or not url.begins_with("ws"): return {}
	var streaming := false
	for chromium in topology.get("chromiums", []):
		if chromium is Dictionary and int(chromium.get("id", -1)) in subscriptions:
			streaming = true
			break
	var result := {"streaming": streaming, "transport": "websocket"}
	if not _video_offer.is_empty():
		var host := str(_video_offer.host)
		result.address = ("[%s]:%d" if host.contains(":") else "%s:%d") % [host, int(_video_offer.port)]
	if video_datagrams == null:
		result.reason = "unavailable" if not _video_offer.is_empty() else "unoffered"
		return result
	var stats: Dictionary = video_datagrams.stats()
	if bool(stats.confirmed):
		_video_confirmed_once = true
		result.transport = "datagram"
	else:
		result.reason = "stopped" if _video_confirmed_once else "no_reply"
	for key in ["round_trip_ms", "frames", "recovered", "nacked", "abandoned"]:
		result[key] = stats[key]
	return result


func _receive_video_datagrams() -> void:
	if video_datagrams == null or not connected: return
	var packets: Array = video_datagrams.take_messages()
	var ages: PackedInt32Array = video_datagrams.message_ages()
	for index in packets.size():
		var decoded := Protocol.unpack(packets[index])
		# Only chromium video uses this link; anything else is not trusted
		# to bypass the WebSocket's checks.
		if decoded == null or decoded.header.get("type") != "chromium": continue
		if local_id(int(decoded.header.session)) not in subscriptions: continue
		# When the worker thread completed the frame; see acknowledge_chromium.
		decoded.header["arrived_msec"] = Time.get_ticks_msec() - ages[index]
		_receive_chromium(decoded.header, decoded.payload)
	# A frame lost beyond repair is acknowledged like one the decoder skipped:
	# the owner may hold nothing newer, so no later frame would reveal it.
	#
	# The next frame's sequence gap then asks for a keyframe.
	var abandoned: PackedInt64Array = video_datagrams.take_abandoned()
	for index in range(0, abandoned.size(), 2):
		var session := int(abandoned[index])
		_chromium_acks[session] = maxi(_chromium_acks.get(session, 0), int(abandoned[index + 1]))


## One cumulative acknowledgement per session and poll; the server's flow
## credits are cumulative because frames are handled in order.
func _acknowledge_chromium() -> void:
	if socket != null:
		for session in _chromium_acks:
			socket.send_text(JSON.stringify({"type": "chromium_ack", "session": session, "frame": _chromium_acks[session]}))
	_chromium_acks.clear()


func _clear_resources() -> void:
	for pane in topology.panes:
		resources_received.emit(int(pane.id), {"status": "disconnected"}, 1.0)


func _receive(message: Dictionary) -> void:
	if not connected and message.get("type") not in ["auth_challenge", "auth_wait", "auth_code_required", "ready"]:
		_auth_error("Unexpected message before authentication")
		return
	match message.get("type", ""):
		"auth_challenge":
			if not (socket is SecurePeer):
				_auth_error("Unexpected password challenge")
				return
			var reply: Dictionary = JSON.parse_string(authentication.client_finish(str(message.get("message", ""))))
			if reply.has("error"):
				_auth_error(str(reply.error))
				return
			password_verified = true
			socket.send_text(JSON.stringify({"type": "auth_finish", "message": reply.message}))
			# The owner answers auth_finish only on the login's encrypted channel.
			socket.secure(authentication.client_channel())
		"auth_wait":
			_set_state("Sending Telegram code…")
		"auth_code_required":
			_set_state("Enter the Telegram code")
			code_required.emit()
		"ready":
			if not password_verified:
				_auth_error("Server did not verify the password")
				return
			if message.get("version") != Protocol.VERSION:
				_connection_error(tr("Server protocol %s is incompatible with app protocol %s. Update Graffitty on both devices.") % [str(message.get("version", "?")), str(Protocol.VERSION)])
				return
			if epoch != message.epoch:
				frames.clear()
				topology = { "tabs": [], "panes": [], "edges": [] }
			epoch = message.epoch
			server_hostname = str(message.get("hostname", "")).strip_edges()
			server_platform = str(message.get("platform", "")).strip_edges()
			server_username = str(message.get("username", "")).strip_edges()
			# A new network connection authenticates before selecting a session.
			# Retain the destination, not the previous socket's attachment.
			if not workspace.is_empty(): preferred_session = workspace
			workspace = str(message.get("workspace", ""))
			available_sessions.clear()
			sessions_known = false
			_selecting_session = -1
			connected = true
			if is_inside_tree():
				get_node("/root/Localization").set_server_language(self, str(message.get("localization", {}).get("language", "auto")))
			_begin_terminal_gpu()
			if url == "shared://local":
				shared_options.workspace = workspace
				shared_options.get_or_add("capabilities", {}).erase("new_session")
				# Reconnects return to this session or fail; they never resume another.
				shared_options.get_or_add("capabilities", {}).erase("workspace_fallback")
				shared_options.get_or_add("capabilities", {})["require_workspace"] = true
			last_error = ""
			_start_video_datagrams(message.get("video_datagram"))
			_set_state("Connected")
			authenticated.emit()
			# Authentication observers persist the hostname-derived alias first.
			if connected and not OS.has_feature("mobile") and url.begins_with("ws"):
				var control_error: String = _core.controller_start(preload("res://graffitty/paths.gd").stdpath("state"), server_alias, controller_identity if not controller_identity.is_empty() else url)
				if not control_error.is_empty(): push_error(control_error)
			subscribe(subscriptions)
			if url == "shared://local":
				frontend_generation += 1
				socket.send_text(JSON.stringify({"type": "frontend_register", "generation": frontend_generation}))
		"session_list":
			available_sessions = message.sessions
			stops_when_empty = message.stops_when_empty == true
			sessions_known = true
			sessions_changed.emit()
			if not topology.tabs.is_empty(): changed.emit()
			_restore_session()
		"session_switched":
			# Save the outgoing view while its workspace and owner IDs still match.
			session_switching.emit()
			terminal_themes.clear()
			if not workspace.is_empty() and workspace != str(message.workspace): last_session = workspace
			session_reattached = workspace.is_empty() and str(message.workspace) == _shown_session
			workspace = str(message.workspace)
			_shown_session = workspace
			preferred_session = workspace
			_selecting_session = -1
			shared_options.workspace = workspace
			frames.clear()
			subscriptions.clear()
			_subscribed.clear()
			topology_received_revision = -1
			# Keep the authenticated transport and its GPU/flow channels. The next
			# topology replaces the presentation before subscribing to new panes.
			session_switched.emit()
			if url == "shared://local":
				frontend_generation += 1
				socket.send_text(JSON.stringify({"type": "frontend_register", "generation": frontend_generation}))
		"session_closed":
			# The shared client batches correlated replies after topology/events.
			# Drain those acknowledgements before closing the packet queue, so a
			# successful last-tab transfer cannot lose its own success response.
			_complete_session_close.call_deferred(socket)
		"frontend_request":
			_handle_frontend_request(message)
		"update":
			# An upgrade replaced this app's files, or is about to.
			if url == "shared://local":
				get_node("/root/TerminalApplication").leave_for_update(bool(message.get("relaunch", false)))
		"terminal_input":
			terminal_input_received.emit(local_id(int(message.session)), message.get("keys", []))
		"clipboard", "clipboard_reset":
			clipboard_received.emit(local_id(int(message.session)), message)
		"topology":
			message = _map_topology(message)
			var graph_changed: bool = topology.get("graph") != message.get("graph")
			topology = message
			topology_generation += 1
			topology_received_revision = int(message.workspace_revision)
			server_fonts.prepare(message.get("terminal_font", {}), self)
			var ids: Array = message.panes.map(
				func(p):
					return int(p.id),
			)
			for id in frames.keys():
				if id not in ids:
					frames.erase(id)
			changed.emit()
			var api: Node = get_node("/root/TerminalApplication").agent_api
			if api != null and graph_changed and message.get("graph") is Dictionary:
				api.graph.import_remote(self, message.graph)
		"pane_update":
			_apply_pane_update(message)
		"resources":
			for sample in message.samples:
				resources_received.emit(local_id(int(sample.session)), sample.snapshot, float(sample.interval))
		"notification":
			notification_received.emit(local_id(int(message.session)), map_graph(message, true))
		"chromium_gpu_state":
			chromium_gpu_state_received.emit(local_id(int(message.session)), bool(message.get("active", false)))
		"history":
			history_received.emit(local_id(int(message.session)), str(message.text))
		"ack", "error":
			if _core.controller_complete(message): return
			if message.get("request") == null: return
			if int(message.request) == _selecting_session:
				_selecting_session = -1
				# A session may close between discovery and selection. Keep the
				# server authenticated; its next inventory supplies the new choices.
				# Retry only when a new catalog arrives, never spin on a rejected selection.
			# A switch acknowledgment may precede its first topology. Never
			# combine the new layout with the previous session's pane list.
			if message.get("workspace_state") is Dictionary and message.get("workspace", workspace) == workspace and topology.get("workspace") == workspace:
				if namespace_ids:
					message.workspace_state = preload("res://scenes/session/ServerWorkspace.gd").map_snapshot(message.workspace_state, local_id)
				topology.workspace_state = message.workspace_state
				topology.workspace_revision = int(message.workspace_state.get("revision", 0))
				changed.emit()
			if message.type == "error":
				last_error = str(message.get("message", "Remote error"))
			if message.has("created"):
				message.created = local_id(int(message.created))
			if message.get("tab") != null:
				message.tab = local_id(int(message.tab))
			acknowledged.emit(message)


func subscribe(ids: Array) -> void:
	# Every subscription change requests fresh owner snapshots. Release
	# unfinished scene/image assemblies instead of retaining abandoned tabs.
	scene_decoder = null
	subscriptions = ids.duplicate()
	for id in terminal_themes.keys():
		if id not in subscriptions: terminal_themes.erase(id)
	for id in frames.keys():
		if id not in subscriptions: frames.erase(id)
	if connected and not workspace.is_empty():
		_subscribed = subscriptions.duplicate()
		socket.send_text(
			JSON.stringify({ "type": "subscribe", "sessions": subscriptions.map(wire_id) })
		)
		# The owner discards demand for unsubscribed panes. Re-send retained
		# preferences when they return even if their displayed sizes are unchanged.
		var retained := {}
		for id in subscriptions:
			var key := str(wire_id(int(id)))
			if sent_chromium_viewports.has(key): retained[key] = sent_chromium_viewports[key]
		sent_chromium_viewports = retained
		set_chromium_viewports(chromium_viewports)


func set_terminal_theme(id: int, theme: Dictionary) -> void:
	if not connected or id not in _subscribed or terminal_themes.get(id) == theme: return
	if send_action("terminal_theme", id, {"theme": theme}) >= 0:
		terminal_themes[id] = theme.duplicate(true)


func send_action(kind: String, id: int, values: Dictionary = { }) -> int:
	# Worker completions and GPU fallback requests can arrive after a tab switch.
	# The owner only accepts scene requests for currently subscribed terminals.
	if kind in ["terminal_asset_request", "terminal_resync"] and id not in _subscribed:
		return -1
	if kind == "terminal_asset_request" and terminal_gpu_negotiating:
		terminal_asset_requests.append({"id": id, "values": values})
		return -1
	# Never replay input after reconnect: its delivery may already have happened.
	if not connected:
		return -1
	sequence += 1
	var message := values.duplicate()
	message.merge({ "type": kind, "session": wire_id(id), "request": sequence }, true)
	if message.has("tab") and message.tab != null:
		message.tab = wire_id(int(message.tab))
	if message.has("tabs"):
		message.tabs = message.tabs.map(func(tab): return wire_id(int(tab)))
	if message.has("destination_tab"):
		message.destination_tab = wire_id(int(message.destination_tab))
	if message.get("surface") is String and preload("res://scenes/PaneTargets.gd").valid(message.surface):
		message.surface = "%%%d" % wire_id(int(message.surface.substr(1)))
	var error: int = socket.send_text(JSON.stringify(message))
	if error != OK:
		_network_failed(error_string(error))
		return -1
	return sequence


func send_key(id: int, event: InputEventKey) -> int:
	return send_action(
		"key",
		id,
		{
			"keycode": event.keycode,
			"unicode": event.unicode,
			"pressed": event.pressed,
			"echo": event.echo,
			"shift": event.shift_pressed,
			"ctrl": event.ctrl_pressed,
			"alt": event.alt_pressed,
			"meta": event.meta_pressed,
		},
	)


func send_input(id: int, data: PackedByteArray) -> void:
	if not connected:
		return
	# Split large pastes, preserving order, without JSON/base64 expansion.
	for start in range(0, data.size(), 65536):
		var error: int = socket.send(
			Protocol.pack(
				{ "type": "input", "session": wire_id(id) },
				data.slice(start, start + 65536),
			)
		)
		if error != OK:
			_network_failed(error_string(error))
			return


func local_id(id: int) -> int:
	if not namespace_ids or id < 0:
		return id
	var allocated: int = _core.local_id(id)
	if allocated < 0:
		var application: Node = get_node("/root/TerminalApplication")
		var identity := JSON.stringify([url, epoch])
		var mapping: Dictionary = application.remote_identity_maps.get_or_add(identity, {})
		if not mapping.has(id): mapping[id] = _allocate_id()
		allocated = mapping[id]
		_core.bind_id(id, allocated)
	return allocated

func _allocate_id() -> int:
	return get_node("/root/TerminalApplication").allocate_id()

func wire_id(id: int) -> int:
	return _core.wire_id(id) if namespace_ids else id


func _map_topology(message: Dictionary) -> Dictionary:
	if not namespace_ids:
		return message
	# Only these lists are edited in place. Graph and workspace snapshots are
	# detached by their mapping cache, so do not deep-copy them twice.
	message = message.duplicate()
	for part in ["panes", "tabs", "chromiums"]:
		if message.has(part): message[part] = message[part].duplicate(true)
	if message.get("workspace_state") is Dictionary:
		message.workspace_state = _map_topology_part("workspace_state", message.workspace_state)
	for pane in message.panes:
		pane.id = local_id(int(pane.id))
		pane.tab = local_id(int(pane.tab))
		if pane.get("filetree_owner") != null: pane.filetree_owner = local_id(int(pane.filetree_owner))
		if pane.get("spawned_by") != null: pane.spawned_by = local_id(int(pane.spawned_by))
		if pane.get("filetree") is Dictionary: pane.filetree.owner = local_id(int(pane.filetree.owner))
	for chromium in message.get("chromiums", []):
		chromium.id = local_id(int(chromium.id))
		chromium.owner = local_id(int(chromium.owner))
		chromium.tab = local_id(int(chromium.tab))
	for tab in message.tabs:
		tab.id = local_id(int(tab.id))
		tab.sessions = tab.sessions.map(
			func(id):
				return local_id(int(id)),
		)
	if message.get("graph") is Dictionary:
		message.graph = _map_topology_part("graph", message.graph)
	# Remote graph node identities belong to the connection, never the local API.
	return message


## Merge a `pane_update` delta into the retained topology. Only listed fields
## of existing panes, tabs and chromiums change; unknown ids are ignored, since
## a structural change always arrives as a full topology first.
func _apply_pane_update(message: Dictionary) -> void:
	var ids: Array = []
	var panes_by_id := {}
	for pane in topology.get("panes", []): panes_by_id[int(pane.id)] = pane
	for update in message.get("panes", []):
		if not update is Dictionary or not update.has("id"): continue
		var id := local_id(int(update.id))
		if not panes_by_id.has(id): continue
		var pane: Dictionary = panes_by_id[id]
		for key in update:
			if key == "id": continue
			var value: Variant = update[key]
			if key == "filetree" and value is Dictionary and value.has("owner"):
				value = value.duplicate()
				value.owner = local_id(int(value.owner))
			pane[key] = value
		ids.append(id)
	var tabs_by_id := {}
	for tab in topology.get("tabs", []): tabs_by_id[int(tab.id)] = tab
	for update in message.get("tabs", []):
		if not update is Dictionary or not update.has("id"): continue
		var id := local_id(int(update.id))
		if not tabs_by_id.has(id): continue
		for key in update:
			if key != "id": tabs_by_id[id][key] = update[key]
	var chromiums_by_id := {}
	for chromium in topology.get("chromiums", []): chromiums_by_id[int(chromium.id)] = chromium
	for update in message.get("chromiums", []):
		if not update is Dictionary or not update.has("id"): continue
		var id := local_id(int(update.id))
		if not chromiums_by_id.has(id): continue
		for key in update:
			if key != "id": chromiums_by_id[id][key] = update[key]
		ids.append(id)
	if not ids.is_empty() or not message.get("tabs", []).is_empty():
		panes_updated.emit(ids)


func _map_topology_part(part: String, value: Dictionary) -> Dictionary:
	# CLI title animation carries unchanged layout/graph snapshots. Namespace
	# conversion is independent of those titles; retain one current result per
	# part, and return a copy so presentation edits cannot mutate the cache.
	var cached: Dictionary = _mapped_topology_parts.get(part, {})
	if cached.is_empty() or cached.source != value:
		var mapped: Dictionary = map_graph(value, true) if part == "graph" else preload("res://scenes/session/ServerWorkspace.gd").map_snapshot(value, local_id)
		cached = {"source": value.duplicate(true), "mapped": mapped}
		_mapped_topology_parts[part] = cached
	return cached.mapped.duplicate(true)


func _receive_chromium(header: Dictionary, payload: PackedByteArray) -> void:
	var id := local_id(int(header.session))
	chromium_video_received.emit(id, header, payload)
	chromium_received.emit(id, payload)
	# Both local native packets and remote wire packets share acknowledgement
	# flow. A decoding session acknowledges its own frames once consumed.
	if header.has("frame") and not header.get("ack_deferred", false):
		_chromium_acks[int(header.session)] = maxi(_chromium_acks.get(int(header.session), 0), int(header.frame))


## Acknowledge the frame once the codec accepts it.
##
## `held_msec` measures the time since the frame arrived. The owner uses
## it to exclude the render loop's wait from link delay.
func acknowledge_chromium(id: int, frame: int, held_msec := 0) -> void:
	if socket != null:
		socket.send_text(JSON.stringify({"type": "chromium_ack", "session": wire_id(id), "frame": frame, "held_ms": maxi(held_msec, 0)}))


func map_graph(value: Variant, incoming: bool, field := "") -> Variant:
	if not namespace_ids:
		return value.duplicate(true) if value is Dictionary or value is Array else value
	return _core.map_graph(value, incoming, field, _allocate_id)


func _complete_session_close(peer: RefCounted) -> void:
	if socket != peer: return
	if url == "shared://local" and peer.get_ready_state() == WebSocketPeer.STATE_OPEN and not fallback_session([]).is_empty():
		# Another live session remains. Its window decides whether to switch
		# there (session_switch) or retire; the owner keeps this client attached.
		pass
	elif url == "shared://local" or url.begins_with("ipc://"):
		disconnect_remote()
	else:
		session_switching.emit()
		workspace = ""
		_shown_session = ""
		_selecting_session = -1
		frames.clear()
		topology = {"tabs": [], "panes": [], "edges": []}
		subscriptions.clear()
		_subscribed.clear()
		changed.emit()
	session_closed.emit()
	_restore_session()


## The session to show after this connection's session ends, skipping the
## sessions `shown` by other windows, or "".
func fallback_session(shown: PackedStringArray) -> String:
	return _core.fallback_session(available_sessions, workspace, last_session, shown)


## The session "next", "previous" or "last" switches to, or "".
## Null when the connection has no current catalog for this session.
func session_close_stops_server(target: String) -> Variant:
	if not connected or not sessions_known or not available_sessions.any(func(session): return session.id == target):
		return null
	return stops_when_empty and available_sessions.size() == 1


func session_target(which: String) -> String:
	return _core.session_target(available_sessions, workspace, last_session, which)


func _restore_session() -> void:
	if not connected or not url.begins_with("ws") or not workspace.is_empty() or _selecting_session >= 0: return
	var target: String = _core.restore_session(available_sessions, preferred_session)
	if not target.is_empty(): _selecting_session = send_action("session_switch", -1, {"name": target})


func request_action(kind: String, values: Dictionary = {}, timeout_msec: int = 10000) -> Dictionary:
	# Carried controls can be displayed before the destination session attaches.
	# Keep their explicit UI actions pending until discovery/selection completes.
	if url.begins_with("ws") and workspace.is_empty() and kind not in ["session_new", "session_switch", "session_rename", "session_kill", "resource_subscription", "font_asset"]:
		var selection_deadline := Time.get_ticks_msec() + timeout_msec
		while connected and workspace.is_empty() and (not sessions_known or _selecting_session >= 0) and Time.get_ticks_msec() < selection_deadline:
			await get_tree().process_frame
		if connected and workspace.is_empty(): return {"type": "error", "code": "no_session", "message": "No session is selected"}
	var replies := {}
	var receive := func(message):
		replies[int(message.get("request", -1))] = message
	acknowledged.connect(receive)
	var request := send_action(kind, int(values.get("session", -1)), values)
	var deadline := Time.get_ticks_msec() + timeout_msec
	while request >= 0 and connected and not replies.has(request) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	acknowledged.disconnect(receive)
	return replies.get(request, {"type": "error", "code": "owner_unavailable", "message": "Session owner disconnected or timed out"})


func _handle_frontend_request(message: Dictionary) -> void:
	if url != "shared://local" or int(message.get("generation", -1)) != frontend_generation: return
	if int(message.get("expires_unix_ms", 0)) <= int(Time.get_unix_time_from_system() * 1000): return
	var response := {"error": {"code": "frontend_busy", "message": "Too many pending presentation requests"}}
	var generation := frontend_generation
	if frontend_inflight < 32:
		frontend_inflight += 1
		var application: Node = get_node("/root/TerminalApplication")
		var id := local_id(int(message.get("session", -1)))
		if application.agent_api != null:
			response = await application.agent_api.dispatch(id, str(message.get("method", "")), map_graph(message.get("params", {}), true))
			var owner: Node = application.host_for_workspace(id)
			if owner != null:
				owner.session_backend.commit_workspace(owner)
				var deadline := Time.get_ticks_msec() + 10000
				while connected and owner.session_backend.work_pending() and Time.get_ticks_msec() < deadline:
					await get_tree().process_frame
				if owner.session_backend.work_pending(): response = {"error": {"code": "frontend_timeout", "message": "Workspace edit was not acknowledged"}}
		frontend_inflight -= 1
	if connected and generation == frontend_generation:
		socket.send_text(JSON.stringify({"type": "frontend_reply", "ticket": int(message.ticket), "response": map_graph(response, false)}))


func remote_call(id: int, method: String, params: Dictionary, canceled: Callable = Callable()) -> Dictionary:
	var replies := { }
	var receive := func(message):
		replies[int(message.get("request", -1))] = message
	acknowledged.connect(receive)
	var request := send_action("rpc", id, { "method": method, "params": map_graph(params, false) })
	var deadline := Time.get_ticks_msec() + (65000 if method == "dictation.transcribe" else (35000 if method in ["terminal.type", "terminal.press"] else 10000))
	while (
		request >= 0 and connected and not replies.has(request) and Time.get_ticks_msec() < deadline
		and not (canceled.is_valid() and canceled.call())
	):
		await get_tree().process_frame
	acknowledged.disconnect(receive)
	if not replies.has(request):
		return {
			"error": {
				"code": "remote_error",
				"message": "Remote request disconnected or timed out",
			}
		}
	var reply: Dictionary = replies[request]
	if reply.type == "error":
		if reply.get("error") is Dictionary:
			return {"error": map_graph(reply.error, true)}
		return {
			"error": {
				"code": "remote_error",
				"message": reply.get("message", "Remote request failed"),
			}
		}
	return { "result": map_graph(reply.get("result", { }), true) }


func _exit_tree() -> void:
	_core.controller_stop()
	var application := get_node_or_null("/root/TerminalApplication")
	if application != null and application.agent_api != null:
		application.agent_api.graph.import_remote(self, { })


func _auth_error(message: String) -> void:
	disconnect_remote()
	last_error = message
	_set_state(message)
	authentication_failed.emit(message)


func _connection_error(message: String) -> void:
	disconnect_remote()
	last_error = message
	_set_state("Connection error · %s", [message])
	connection_failed.emit(message)


func submit_code(code: String) -> void:
	var reply: Dictionary = JSON.parse_string(authentication.code_proof(code))
	if reply.has("error"):
		_auth_error(str(reply.error))
		return
	socket.send_text(JSON.stringify({"type": "auth_code", "proof": reply.proof}))


func reject_chromium_codec(id: int, codec: String) -> void:
	if connected:
		socket.send_text(JSON.stringify({ "type": "chromium_video_reject", "session": wire_id(id), "codec": codec }))


func reset_chromium_video(id: int) -> void:
	if connected:
		socket.send_text(JSON.stringify({ "type": "chromium_video_reset", "session": wire_id(id) }))

func _begin_terminal_gpu() -> void:
	if socket == null or not socket.has_method("local_peer_pid"):
		return
	var resources := preload("res://scenes/TerminalGpuAssets.gd").new()
	if not resources.start(socket.local_peer_pid()):
		return
	terminal_gpu = resources
	terminal_gpu_negotiating = true
	var peer = socket
	var offer: Dictionary = await request_action("terminal_gpu_offer", {"mechanism": "mach-iosurface-v1", "endpoint": resources.endpoint})
	if socket != peer or terminal_gpu != resources:
		return
	if offer.get("type") == "error":
		_reject_terminal_gpu()
		return
	var deadline := Time.get_ticks_msec() + 4500
	while connected and socket == peer and terminal_gpu == resources and not resources.proof_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if socket != peer or terminal_gpu != resources:
		return
	if not resources.proof_ready():
		_reject_terminal_gpu()
		return
	while connected and Time.get_ticks_msec() < deadline:
		var confirmed: Dictionary = await request_action("terminal_gpu_confirm")
		if socket != peer or terminal_gpu != resources:
			return
		if confirmed.get("result", {}).get("active", false):
			_finish_terminal_gpu()
			return
		if confirmed.get("type") == "error":
			break
		await get_tree().process_frame
	_reject_terminal_gpu()

func _finish_terminal_gpu() -> void:
	terminal_gpu_negotiating = false
	var requests := terminal_asset_requests.duplicate()
	terminal_asset_requests.clear()
	for request in requests:
		send_action("terminal_asset_request", int(request.id), request.values)

func _reject_terminal_gpu() -> void:
	var retry: Array = terminal_gpu.pending_descriptors() if terminal_gpu != null else []
	if terminal_gpu != null:
		terminal_gpu.close()
	terminal_gpu = null
	if connected:
		send_action("terminal_gpu_reject", 0)
	_finish_terminal_gpu()
	for descriptor in retry:
		send_action("terminal_asset_request", local_id(int(descriptor.session)), {"asset": descriptor.asset})

func fonts_ready() -> bool:
	return server_fonts.ready

func fonts_revision() -> String:
	return str(server_fonts.revision)

func fonts_for(_id: int) -> RefCounted:
	return server_fonts

func font_default(_id: int) -> int:
	return int(topology.get("terminal_font", {}).get("default_size", 16))


func dictation_stream(id: int, job: String, offset: int, audio: PackedByteArray) -> int:
	if not connected: return -1
	if socket.has_method("get_current_outbound_buffered_amount") and socket.get_current_outbound_buffered_amount() > 512000: return -1
	sequence += 1
	if socket.send(Protocol.pack({"type":"rpc", "session":wire_id(id), "request":sequence,
		"method":"dictation.live.append", "params":{"job":job,"offset":offset}}, audio)) != OK: return -1
	return sequence

func dictation_upload(id: int, job: String, audio: PackedByteArray, canceled: Callable) -> bool:
	# Each binary packet stays below the protocol limit. One frame between chunks
	# keeps large uploads from starving keyboard and terminal traffic.
	for offset in range(0, audio.size(), 65536):
		if not connected or canceled.call(): return false
		sequence += 1
		if socket.send(Protocol.pack({"type":"rpc", "session":wire_id(id), "request":sequence,
			"method":"dictation.append", "params":{"job":job,"offset":offset}}, audio.slice(offset, offset+65536))) != OK: return false
		await get_tree().process_frame
	return true

func set_chromium_viewports(sizes: Dictionary) -> void:
	chromium_viewports = sizes.duplicate()
	if not connected: return
	var requests := {}
	for id in sizes:
		if int(id) in subscriptions: requests[str(wire_id(int(id)))] = sizes[id]
	if requests == sent_chromium_viewports: return
	socket.send_text(JSON.stringify({"type": "chromium_stream", "viewports": requests}))
	sent_chromium_viewports = requests
