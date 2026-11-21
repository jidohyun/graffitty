extends "res://tests/unit/test_case.gd"

const Connection := preload("res://scenes/remote/RemoteConnection.gd")

class FailedPeer extends RefCounted:
	var code := 1011
	var reason := "Formatter hyperlink cell mismatch"
	func poll() -> void: pass
	func get_ready_state() -> int: return WebSocketPeer.STATE_CLOSED
	func get_available_packet_count() -> int: return 0
	func get_close_code() -> int: return code
	func get_close_reason() -> String: return reason
	func close(_code := 1000, _reason := "") -> void: pass

func test_protocol_and_server_failures_stop_retrying_and_preserve_reason() -> void:
	for code in [1002, 1011]:
		var connection := Connection.new()
		var peer := FailedPeer.new()
		peer.code = code
		connection.enabled = true
		connection.connected = true
		connection.socket = peer
		var failures := []
		connection.connection_failed.connect(func(message): failures.append(message))
		connection._process(0.0)
		expect(failures == [peer.reason], "The UI receives the actual close reason once")
		expect(connection.last_error == peer.reason, "Failure details survive disconnect cleanup")
		expect(not connection.connected and not connection.enabled and connection.socket == null, "Protocol failures detach instead of entering a retry loop")
		connection._process(0.0)
		expect(connection.socket == null and failures.size() == 1, "Later frames cannot silently reconnect")
		connection.free()

func test_authenticated_session_failure_is_not_a_password_failure() -> void:
	var connection := Connection.new()
	var peer := FailedPeer.new()
	peer.code = 1008
	peer.reason = "Session not found: $4"
	connection.enabled = true
	connection.password_verified = true
	connection.socket = peer
	var errors := []
	var passwords := []
	connection.connection_failed.connect(func(message): errors.append(message))
	connection.authentication_failed.connect(func(message): passwords.append(message))
	connection._process(0.0)
	expect(errors == [peer.reason] and passwords.is_empty(), "Post-authentication failure keeps the actual reason and valid credentials")
	connection.free()

func test_network_session_close_keeps_authenticated_server_and_empty_inventory() -> void:
	var connection := Connection.new()
	connection.url = "ws://example.test:7183"
	connection.connected = true
	connection.enabled = true
	connection.workspace = "$4"
	connection.socket = RecordingPeer.new()
	connection._complete_session_close(connection.socket)
	expect(connection.connected and connection.enabled and connection.socket != null, "Closing the last session keeps the server connection")
	expect(connection.workspace.is_empty() and connection.topology.tabs.is_empty(), "Only the selected view is cleared")
	connection.free()

func test_incompatible_server_version_returns_a_recoverable_connection_error() -> void:
	var connection := Connection.new()
	connection.enabled = true
	connection.password_verified = true
	var failures := []
	connection.connection_failed.connect(func(message): failures.append(message))
	connection._receive({"type": "ready", "version": -1})
	expect(failures.size() == 1 and "incompatible" in failures[0], "Protocol mismatch explains the need to update")
	expect(not connection.enabled, "Incompatible versions do not retry indefinitely")
	connection.free()

class RecordingPeer extends RefCounted:
	var sent: Array = []
	func send_text(text: String) -> int:
		sent.append(JSON.parse_string(text))
		return OK

func test_reauthenticated_socket_restores_the_previous_session() -> void:
	var connection := Connection.new()
	var peer := RecordingPeer.new()
	connection.url = "ws://example.test:7183"
	connection.socket = peer
	connection.password_verified = true
	connection.workspace = "$4"
	connection.epoch = "same-server"
	connection._receive({"type": "ready", "version": Connection.Protocol.VERSION, "epoch": "same-server"})
	expect(connection.workspace.is_empty() and connection.preferred_session == "$4", "Authentication retains the destination without claiming the new socket is attached")
	connection._receive({"type": "session_list", "sessions": [{"id": "$4"}], "stops_when_empty": false})
	expect(peer.sent.any(func(message): return message.get("type") == "session_switch" and message.get("name") == "$4"), "Session discovery explicitly reattaches the previous session")
	connection.free()

func test_returning_to_the_shown_session_after_a_reconnect_is_not_a_switch() -> void:
	var connection := Connection.new()
	connection.url = "ws://example.test:7183"
	connection.socket = RecordingPeer.new()
	connection.password_verified = true
	connection.connected = true
	connection._receive({"type": "session_switched", "workspace": "$0"})
	expect(not connection.session_reattached, "The first attachment is a real arrival")
	# The socket is replaced: the server authenticates before any session is selected.
	connection.epoch = "same-server"
	connection._receive({"type": "ready", "version": Connection.Protocol.VERSION, "epoch": "same-server"})
	expect(connection.workspace.is_empty(), "A new socket starts with no session attached")
	connection._receive({"type": "session_switched", "workspace": "$0"})
	expect(connection.session_reattached, "Coming back to the session on screen is a reattachment")
	connection._receive({"type": "session_switched", "workspace": "$1"})
	expect(not connection.session_reattached, "Choosing another session is a switch")
	connection._receive({"type": "ready", "version": Connection.Protocol.VERSION, "epoch": "same-server"})
	connection._receive({"type": "session_switched", "workspace": "$0"})
	expect(not connection.session_reattached, "Landing on a different session after a reconnect is a switch")
	connection.free()


func test_session_close_prediction_uses_server_policy_and_inventory() -> void:
	var connection := Connection.new()
	connection.connected = true
	expect(connection.session_close_stops_server("$4") == null, "An unpublished catalog gives no shutdown prediction")
	connection._receive({"type": "session_list", "sessions": [{"id": "$4"}], "stops_when_empty": true})
	expect(connection.session_close_stops_server("$4") == true, "The final private session stops the server")
	expect(connection.session_close_stops_server("$5") == null, "An unknown target gives no shutdown prediction")
	connection._receive({"type": "session_list", "sessions": [{"id": "$4"}, {"id": "$5"}], "stops_when_empty": true})
	expect(connection.session_close_stops_server("$4") == false, "A sibling session keeps the private server running")
	connection._receive({"type": "session_list", "sessions": [{"id": "$4"}], "stops_when_empty": false})
	expect(connection.session_close_stops_server("$4") == false, "Remote access keeps the server running without sessions")
	connection.free()

func test_acknowledged_layout_is_not_a_received_topology() -> void:
	var connection := Connection.new()
	connection.connected = true
	connection.workspace = "$1"
	connection.topology = {"workspace": "$1", "workspace_revision": 3, "workspace_state": {"revision": 3}}
	connection.topology_received_revision = 3
	connection._receive({"type": "ack", "request": 1, "workspace_state": {"revision": 4}})
	expect(connection.topology.workspace_revision == 4, "Acknowledged layout advances the edit base")
	expect(connection.topology_received_revision == 3, "An acknowledgement cannot stand in for matching pane geometry")
	connection._receive({"type": "session_switched", "workspace": "$2"})
	expect(connection.topology_received_revision == -1, "The previous session's revision cannot confirm a new session's claim")
	connection.free()

class WriteFailurePeer extends RefCounted:
	var writes := 0
	var closes := 0
	func send_text(_text: String) -> int:
		writes += 1
		return ERR_CONNECTION_ERROR
	func send(_data: PackedByteArray) -> int:
		writes += 1
		return ERR_CONNECTION_ERROR
	func close(_code := 1000, _reason := "") -> void: closes += 1

func test_failed_input_and_actions_retry_without_replaying_or_discarding_workspace() -> void:
	for binary_input in [false, true]:
		var connection := Connection.new()
		var peer := WriteFailurePeer.new()
		connection.socket = peer
		connection.enabled = true
		connection.connected = true
		connection.subscriptions = [7]
		connection.epoch = "same-server"
		connection.topology = {"tabs": [{"id": 7}], "panes": [{"id": 7}], "edges": []}
		if binary_input:
			# Stop at the first failed chunk; do not replay an uncertain paste.
			connection.send_input(7, "x".repeat(70000).to_utf8_buffer())
		else:
			expect(connection.send_action("key", 7, {"unicode": 120}) == -1, "Failed key reports failure")
		expect(connection.enabled and not connection.connected and connection.socket == null, "Write failure releases the socket but keeps automatic reconnection enabled")
		expect(connection.retry_at > Time.get_ticks_msec() and connection.status_message.begins_with("Offline"), "Write failure reports offline and schedules a bounded retry")
		expect(connection.epoch == "same-server" and connection.topology.panes == [{"id": 7}] and connection.subscriptions == [7], "Reconnect retains the terminal identity and desired subscriptions")
		connection.send_input(7, "later".to_utf8_buffer())
		connection.send_action("key", 7, {"unicode": 121})
		expect(peer.writes == 1 and peer.closes == 1, "No further input reaches the failed socket")
		var replacement := RecordingPeer.new()
		connection.socket = replacement
		connection.connected = true
		connection.send_action("key", 7, {"unicode": 122})
		expect(replacement.sent.size() == 1 and replacement.sent[0].unicode == 122, "Only new input is sent after reconnection")
		connection.free()

func test_regroup_maps_pane_destination_and_reply_between_namespaces() -> void:
	var connection := Connection.new()
	var peer := RecordingPeer.new()
	connection.socket = peer
	connection.connected = true
	connection.namespace_ids = true
	connection.local_ids = {0: 70, 8: 80}
	connection.send_action("regroup", -1, {"surface": "%70", "tab": 80})
	expect(peer.sent[0].surface == "%0" and int(peer.sent[0].tab) == 8,
		"Regroup sends the server's pane and tab IDs, including pane zero")
	connection.send_action("regroup", -1, {"surface": "%70", "tab": null})
	expect(peer.sent[1].tab == null, "Creating a tab preserves the null destination")
	var replies := []
	connection.acknowledged.connect(func(reply): replies.append(reply))
	connection._receive({"type": "ack", "request": 1, "tab": 8})
	expect(replies.size() == 1 and replies[0].tab == 80, "Regroup acknowledgement returns the frontend's tab ID")
	connection.free()

func test_tab_switch_discards_late_scene_and_gpu_fallback_requests() -> void:
	var connection := Connection.new()
	var peer := RecordingPeer.new()
	connection.socket = peer
	connection.connected = true
	connection.workspace = "$1"
	connection.subscriptions = [7]
	connection._subscribed = [7]
	connection.terminal_gpu_negotiating = true
	connection.send_action("terminal_asset_request", 7, {"asset": "old-pane"})
	expect(connection.terminal_asset_requests.size() == 1, "Asset waits for GPU negotiation")
	connection.subscribe([8])
	connection._finish_terminal_gpu()
	connection.send_action("terminal_resync", 7)
	connection.send_action("terminal_asset_request", 8, {"asset": "current-pane"})
	expect(peer.sent.size() == 2, "Only subscription and current pane asset reach the owner")
	expect(peer.sent[1].type == "terminal_asset_request" and int(peer.sent[1].session) == 8, "Active pane still fetches its pixels")
	expect(connection.terminal_asset_requests.is_empty(), "Stale deferred requests do not survive negotiation")
	connection.free()

func test_graph_connections_map_canonical_pane_ids_and_keep_port_names() -> void:
	var connection := Connection.new()
	connection.namespace_ids = true
	connection.local_ids = {0: 70, 8: 80}
	var graph := {"nodes": [{"node": "%0", "pane": "%0"}, {"node": "%8"}],
		"edges": [{"from": "%0", "to": "%8", "from_port": "out", "to_port": "in", "edge": "%0/out>%8/in"}],
		"queues": {"%8": [{"source": "%0", "target": "%8", "edge": "%0/out>%8/in"}]},
		"by_edge": {"%0/out>%8/in": {"count": 1}}}
	var mapped: Dictionary = connection.map_graph(graph, true)
	expect(mapped.nodes[0].node == "%70" and mapped.nodes[0].pane == "%70", "Node and pane use one canonical ID, including pane zero")
	expect(mapped.edges[0].from == "%70" and mapped.edges[0].to == "%80", "Connections use canonical pane endpoints")
	expect(mapped.edges[0].edge == "%70/out>%80/in", "Socket IDs preserve their port suffixes")
	expect(mapped.queues["%80"][0].source == "%70" and mapped.by_edge.has("%70/out>%80/in"), "Queue and edge map keys use the same namespace")
	expect(connection.map_graph(mapped, false) == graph, "Returning to the owner preserves the entire graph")
	connection.free()

func test_terminal_targets_and_pid_rows_keep_server_namespaces() -> void:
	var connection := Connection.new()
	connection.namespace_ids = true
	connection.local_ids = {7: 70, 8: 80}
	expect(connection.map_graph({"target":"%70"}, false).target == "%7", "Pane aliases use the owner's IDs")
	expect(connection.map_graph({"target":"@80.1"}, false).target == "@8.1", "Tab aliases preserve pane numbers")
	var row: Dictionary = connection.map_graph({"pane":"%7", "id":"%7", "tab":"@8", "root_pid":123}, true)
	expect(row.pane == "%70" and row.id == "%70" and row.tab == "@80", "PID rows map identifiers back to the view")
	expect(row.root_pid == 123, "Operating system PIDs are never remapped")
	connection.free()

class ClosingPeer extends RefCounted:
	var packets := [{"type": "session_closed", "workspace": "test"}, {"type": "ack", "request": 1}]
	func poll() -> void: pass
	func get_ready_state() -> int: return WebSocketPeer.STATE_CLOSED
	func get_available_packet_count() -> int: return packets.size()
	func get_packet() -> PackedByteArray: return JSON.stringify(packets.pop_front()).to_utf8_buffer()
	func was_string_packet() -> bool: return true
	func close(_code := 1000, _reason := "") -> void: pass


func test_final_packets_before_eof_do_not_trigger_reconnection() -> void:
	var connection := Connection.new()
	var peer := ClosingPeer.new()
	connection.url = "shared://local"
	connection.enabled = true
	connection.connected = true
	connection.auth_sent = true
	connection.socket = peer
	var replies := []
	connection.acknowledged.connect(func(reply): replies.append(reply))
	connection._process(0.0)
	expect(replies.size() == 1 and replies[0].request == 1, "Final close acknowledgement survives EOF")
	expect(connection.retry_at == 0 and connection.last_error.is_empty(), "Orderly close does not schedule reconnection")
	# The regular event loop runs this deferred after draining the batch.
	connection._complete_session_close(peer)
	expect(not connection.enabled and connection.socket == null, "Session closure stops reconnection")
	connection.free()


class OpenPeer extends ClosingPeer:
	func get_ready_state() -> int: return WebSocketPeer.STATE_OPEN


func test_local_session_close_stays_attached_while_another_session_lives() -> void:
	var connection := Connection.new()
	var peer := OpenPeer.new()
	peer.packets.clear()
	connection.url = "shared://local"
	connection.enabled = true
	connection.connected = true
	connection.socket = peer
	connection.workspace = "$1"
	connection.last_session = "$3"
	connection.available_sessions = [{"id": "$2"}, {"id": "$3"}]
	var closed := [0]
	connection.session_closed.connect(func(): closed[0] += 1)
	expect(connection.fallback_session([]) == "$3", "The previously viewed session is shown first")
	expect(connection.fallback_session(["$3"]) == "$2", "A session another window shows is skipped")
	expect(connection.fallback_session(["$2", "$3"]).is_empty(), "No fallback when every session is shown")
	connection._complete_session_close(peer)
	expect(closed[0] == 1 and connection.connected and connection.socket == peer, "The window can switch to a remaining session")
	connection.available_sessions = []
	connection._complete_session_close(peer)
	expect(closed[0] == 2 and not connection.enabled and connection.socket == null, "The last session's close detaches")
	connection.free()


func test_closed_socket_before_authentication_reports_offline() -> void:
	var connection := Connection.new()
	connection.enabled = true
	connection.socket = WebSocketPeer.new()
	connection._process(0.0)
	expect(connection.status_message.begins_with("Offline"), "An unreachable server is reported before authentication starts")
	expect(connection.status_message.contains("network/VPN"), "Status suggests checking connectivity")
	expect(connection.socket == null, "Failed socket is released")
	expect(connection.retry_at > Time.get_ticks_msec(), "Retry is delayed instead of looping immediately")
	connection.free()


func test_first_reconnect_after_resume_is_immediate() -> void:
	var connection := Connection.new()
	connection.enabled = true
	connection.url = "ws://127.0.0.1:1"
	connection.token = "test-only"
	connection._network_failed("Server unreachable")
	expect(connection.retry_at > Time.get_ticks_msec(), "An ordinary loss waits before retrying")
	connection.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	expect(connection.retry_at == 0, "Returning to the app cuts a pending retry delay short")
	connection.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	connection._network_failed("Server unreachable")
	expect(connection.retry_at <= Time.get_ticks_msec(), "A socket found dead on return reconnects at once")
	connection._network_failed("Server unreachable")
	expect(connection.retry_at > Time.get_ticks_msec(), "A link that fails again backs off as usual")
	connection.free()


func test_retry_preserves_offline_status_and_detach_cancels_retry() -> void:
	var connection := Connection.new()
	connection.enabled = true
	connection.url = "ws://127.0.0.1:1"
	connection.token = "test-only"
	connection._network_failed("Connection timed out")
	var offline_message := connection.status_message
	connection.retry_at = 0
	connection._process(0.0)
	expect(connection.socket != null, "Retry starts another connection attempt")
	expect(connection.status_message == offline_message, "Automatic retry does not hide the offline status")
	connection.disconnect_remote()
	connection._process(0.0)
	expect(connection.socket == null and not connection.enabled, "Detach stops automatic retries")
	expect(connection.status_message == "Disconnected", "Explicit detach is distinct from network failure")
	connection.free()

func test_native_chromium_packet_preserves_order_and_acknowledgement() -> void:
	var shared := preload("res://scenes/session/SharedSessionPeer.gd").new()
	var payload := PackedByteArray([1, 2, 3])
	shared.packets = [{"text": true, "data": PackedByteArray()}, {"chromium_header": '{"type":"chromium","session":7,"frame":42}', "data": payload}]
	expect(shared.take_native_packet().is_empty(), "Chromium frame cannot overtake a preceding message")
	shared.get_packet()
	var packet := shared.take_native_packet()
	expect(packet.data == payload and shared.packets.is_empty(), "Prepared chromium packet keeps its payload without reframing")
	var connection := Connection.new()
	var peer := RecordingPeer.new()
	connection.socket = peer
	connection.namespace_ids = true
	connection.local_ids = {7: 70}
	var received := []
	connection.chromium_video_received.connect(func(id, header, data): received.append([id, header, data]))
	connection._receive_chromium(JSON.parse_string(packet.chromium_header), packet.data)
	connection._receive_chromium({"type": "chromium", "session": 7, "frame": 43}, payload)
	expect(received.size() == 2 and received[0][0] == 70 and received[0][2] == payload, "Chromium frame uses the client's local ID")
	expect(peer.sent.is_empty(), "Frames handled in one poll wait for a single acknowledgement")
	connection._acknowledge_chromium()
	expect(peer.sent.size() == 1 and peer.sent[0].type == "chromium_ack" and int(peer.sent[0].session) == 7 and int(peer.sent[0].frame) == 43, "One cumulative acknowledgement uses the owner's wire ID")
	connection._acknowledge_chromium()
	expect(peer.sent.size() == 1, "An acknowledged poll is not acknowledged again")
	connection.free()

func test_discovered_server_does_not_receive_scene_requests_before_attachment() -> void:
	var connection := Connection.new()
	var peer := RecordingPeer.new()
	connection.socket = peer
	connection.connected = true
	connection.subscribe([7])
	connection.send_action("terminal_resync", 7)
	connection.send_action("terminal_asset_request", 7, {"asset": "pixels"})
	connection.set_terminal_theme(7, {"foreground": "#ffffff"})
	expect(peer.sent.is_empty(), "Desired panes are not subscribed until the server session is attached")
	connection.workspace = "$1"
	connection.subscribe([7])
	connection.send_action("terminal_resync", 7)
	expect(peer.sent.size() == 2 and peer.sent[0].type == "subscribe" and peer.sent[1].type == "terminal_resync", "Scene traffic follows the actual subscription on the new socket")
	connection.free()


func test_remote_access_that_could_not_start_names_who_holds_the_address() -> void:
	var control: Node = preload("res://scenes/remote/RemoteAccessControl.gd").new()
	var base := {"auth_path": "/a", "connection_file": "/c", "remote": null}
	control._install_settings(base)
	expect(control.unavailable_text().is_empty(), "A server sharing nothing by choice reports no failure")
	control._install_settings(base.merged({"remote_error": {"address": "127.0.0.1:7183", "holder": "program", "name": "nginx", "pid": 7, "message": "m"}}))
	expect(not control.enabled, "Remote access is off")
	expect(control.unavailable_text() == "127.0.0.1:7183 is in use by nginx (process 7).", "Another program is named: " + control.unavailable_text())
	control._install_settings(base.merged({"remote_error": {"address": "127.0.0.1:7183", "holder": "graffitty", "name": "gft", "pid": 9, "message": "m"}}))
	expect(control.unavailable_text() == "127.0.0.1:7183 is in use by another Graffitty server (process 9).", "Another Graffitty server is told apart: " + control.unavailable_text())
	control._install_settings(base.merged({"remote_error": {"address": "127.0.0.1:7183", "holder": "unknown", "name": "", "pid": 0, "message": "m"}}))
	expect(control.unavailable_text() == "127.0.0.1:7183 is in use by another program.", "A holder that cannot be seen is still reported")
	control._install_settings(base.merged({"remote_error": {"address": "10.0.0.9:7183", "message": "10.0.0.9:7183: cannot assign requested address"}}))
	expect(control.unavailable_text() == "10.0.0.9:7183: cannot assign requested address", "Any other failure is quoted")
	control._install_settings(base)
	expect(control.unavailable_text().is_empty(), "The failure clears once the server reports none")
	control.free()
