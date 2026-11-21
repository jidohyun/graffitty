extends SceneTree
## Driven by tests/chromium/chromium_video_datagram_e2e.py against a real owner and an
## animating page. The client logs in with the owner's password over loopback,
## so its session is encrypted and the owner offers video datagrams.
var connection: Node
var chromium: Node
var failures: Array[String] = []
## Every chromium video frame the connection delivered, in arrival order.
var frames: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func expect(value: bool, message: String) -> void:
	print("%s %s" % ["PASS" if value else "FAIL", message])
	if not value: failures.append(message)

func until(check: Callable, timeout_msec := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not check.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return check.call()

func wait(msec: int) -> void:
	await until(func(): return false, msec)

func datagram_frames() -> int:
	return int(connection.video_datagrams.stats().frames) if connection.video_datagrams != null else 0

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	connection = preload("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(connection)
	connection.connect_remote(descriptor.url, descriptor.token)
	expect(await until(func(): return connection.connected), "Godot logs in with the password")
	# A remote login selects its session afterwards, as the session chooser does.
	if connection.workspace.is_empty():
		var switched: Dictionary = await connection.request_action("session_switch", {"name": "main"})
		expect(switched.get("type") != "error", "The client attaches to the owner's session: %s" % switched)
	expect(await until(func(): return connection.topology.get("chromiums", []).any(func(c): return int(c.id) == int(args[2]))), "The client sees the owner's browsers")
	expect(connection.video_datagrams != null, "The owner offers video datagrams to an encrypted login")
	if connection.video_datagrams == null:
		finish()
		return
	chromium = preload("res://scenes/remote/RemoteChromiumSession.gd").new()
	chromium.connection = connection
	chromium.tab_id = connection.local_id(int(args[1]))
	chromium.session_id = connection.local_id(int(args[2]))
	chromium.chromium_ready = true
	chromium.set_preview_size(Vector2(1000, 700))
	root.add_child(chromium)
	connection.chromium_video_received.connect(func(id, header, data):
		if id != chromium.session_id: return
		frames.append({"at": Time.get_ticks_msec(), "key": bool(header.get("key", false)), "format": str(header.get("format", ""))})
		chromium.apply_video_frame(header, data))
	connection.subscribe([chromium.session_id])
	connection.set_chromium_viewports({chromium.session_id: 720})
	expect(await until(func(): return connection.video_datagrams.confirmed()), "The owner answers the client's hello")
	expect(await until(func(): return datagram_frames() >= 30), "Video frames arrive as datagrams")
	var via_datagrams := datagram_frames()
	var total := frames.size()
	await wait(1000)
	var datagram_share := float(datagram_frames() - via_datagrams) / maxf(1.0, float(frames.size() - total))
	expect(frames.size() - total >= 20 and datagram_share > 0.95,
		"Once confirmed, video uses only the datagram link (%d frames, %.0f%%)" % [frames.size() - total, datagram_share * 100.0])
	expect(await until(func(): return chromium.texture != null), "Datagram video decodes")
	expect(connection.video_transport().get("transport") == "datagram", "The status line sees datagram video, so it shows no warning")
	if args.size() > 3 and args[3] == "lossy":
		await lossy()
		finish()
		return
	if args.size() > 3 and args[3] in ["multi", "paced"]:
		# A phone renders about 25 frames a second and acknowledges video once
		# per frame; that scheduling delay is not link congestion.
		if args[3] == "paced": Engine.max_fps = 25
		await multi(Array(args.slice(4)).map(func(id): return int(id)), 15.0)
		finish()
		return

	connection.set_chromium_viewports({chromium.session_id: 0})
	await wait(500)
	var paused := frames.size()
	await wait(1500)
	expect(frames.size() - paused <= 1, "A paused pane receives no frames (%d)" % [frames.size() - paused])

	var resumed_at := Time.get_ticks_msec()
	var before := frames.size()
	connection.set_chromium_viewports({chromium.session_id: 720})
	expect(await until(func(): return frames.size() >= before + 10), "A resumed pane streams again")
	var first: Dictionary = {}
	for frame in frames.slice(before):
		if int(frame.at) >= resumed_at:
			first = frame
			break
	expect(first.get("key", false), "Resuming starts at a keyframe")

	# Stopping the link silences the client's hellos. The owner must return
	# video to the WebSocket instead of streaming into a dead path.
	connection._stop_video_datagrams()
	var stopped := frames.size()
	expect(await until(func(): return frames.size() >= stopped + 20, 15000), "Video returns to the WebSocket when datagrams stop")
	finish()

## The driver sets GRAFFITTY_TEST_DATAGRAM_LOSS: the client discards that share
## of received datagrams. Parity, then retransmission, must keep frames decoding.
func lossy() -> void:
	var start: Dictionary = connection.video_datagrams.stats()
	var count := frames.size()
	await wait(4000)
	var stats: Dictionary = connection.video_datagrams.stats()
	var delivered := int(stats.frames) - int(start.frames)
	var abandoned := int(stats.abandoned) - int(start.abandoned)
	var keys := 0
	for frame in frames.slice(count):
		if frame.key: keys += 1
	var recovered := int(stats.recovered) - int(start.recovered)
	expect(recovered > 0, "Parity rebuilds frames without a round trip (%d frames, %d NACKs)" % [recovered, int(stats.nacked) - int(start.nacked)])
	expect(delivered >= 60, "Video keeps flowing over a lossy link (%d frames in 4 s)" % delivered)
	expect(abandoned * 10 <= delivered, "Retransmission recovers most frames (%d abandoned of %d)" % [abandoned, delivered])
	expect(keys * 5 <= delivered, "Losses rarely force keyframes (%d keyframes)" % keys)


## The driver opens three noisy browsers and sets GRAFFITTY_TEST_DATAGRAM_RATE:
## a tunnel narrower than their combined bitrate. The owner must adapt rate and
## bitrate so every stream keeps moving, instead of overflowing the tunnel.
func multi(ids: Array, floor_fps: float) -> void:
	connection.set_chromium_viewports({})
	var sessions := {}
	for id in ids:
		var session := preload("res://scenes/remote/RemoteChromiumSession.gd").new()
		session.connection = connection
		session.tab_id = chromium.tab_id
		session.session_id = connection.local_id(int(id))
		session.chromium_ready = true
		session.set_preview_size(Vector2(1000, 700))
		root.add_child(session)
		sessions[session.session_id] = {"node": session, "frames": [], "bytes": 0}
	connection.chromium_video_received.connect(func(id, header, data):
		if not sessions.has(id): return
		sessions[id].frames.append({"at": Time.get_ticks_msec(), "key": bool(header.get("key", false))})
		sessions[id].bytes += data.size()
		sessions[id].node.apply_video_frame(header, data))
	connection.subscribe(sessions.keys())
	var viewports := {}
	for id in sessions: viewports[id] = 720
	connection.set_chromium_viewports(viewports)
	# Let the link find its rate before measuring the steady state.
	await wait(6000)
	var start := Time.get_ticks_msec()
	var marks := {}
	for id in sessions: marks[id] = [sessions[id].frames.size(), sessions[id].bytes]
	var link_start: Dictionary = connection.video_datagrams.stats()
	await wait(10000)
	var elapsed := (Time.get_ticks_msec() - start) / 1000.0
	var link: Dictionary = connection.video_datagrams.stats()
	for id in sessions:
		var measured: Array = sessions[id].frames.slice(marks[id][0])
		var gap := 0
		var keys := 0
		var previous := start
		for frame in measured:
			gap = maxi(gap, int(frame.at) - previous)
			previous = int(frame.at)
			if frame.key: keys += 1
		gap = maxi(gap, Time.get_ticks_msec() - previous)
		var fps := measured.size() / elapsed
		var kbps: float = (sessions[id].bytes - marks[id][1]) * 8.0 / elapsed / 1000.0
		print("STREAM %d fps=%.1f kbps=%.0f keys=%d max_gap_ms=%d" % [id, fps, kbps, keys, gap])
		expect(fps >= floor_fps, "Stream %d keeps moving through the narrow tunnel (%.1f fps)" % [id, fps])
		expect(gap < 1000, "Stream %d never freezes (longest gap %d ms)" % [id, gap])
		expect(keys * 5 <= measured.size(), "Stream %d adapts without keyframe storms (%d keyframes)" % [id, keys])
	var abandoned := int(link.abandoned) - int(link_start.abandoned)
	var delivered := int(link.frames) - int(link_start.frames)
	print("LINK delivered=%d abandoned=%d nacked=%d" % [delivered, abandoned, int(link.nacked) - int(link_start.nacked)])
	expect(abandoned * 20 <= delivered, "The owner's rate fits the tunnel: few frames are lost beyond repair (%d of %d)" % [abandoned, delivered])
	expect(connection.video_transport().get("transport") == "datagram", "Video stays on the datagram link")


func finish() -> void:
	if connection.video_datagrams != null:
		print("datagram stats: ", connection.video_datagrams.stats())
	print("frames received: ", frames.size())
	if failures.is_empty():
		print("CHROMIUM_VIDEO_DATAGRAM_PASS")
	quit(0 if failures.is_empty() else 1)
