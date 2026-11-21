extends "res://tests/shared_chromium_gpu.gd"
## Native frontend with negotiated video, not a claim of native GPU sharing.

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_GPU_EVIDENCE")
	await camera_at_rest()
	var owner: int = host.active_session_id
	var owner_pid: int = host.sessions[owner].term.get_shell_pid()
	var chromium: Node = await host.create_chromium_session(OS.get_environment("GRAFFITTY_GPU_URL"))
	if chromium == null:
		check(false, "Owner creates chromium")
		return
	var id: int = chromium.session_id
	if not await until(func(): return chromium.frames > 0 and not chromium.video_codec.is_empty() and chromium.texture != null, "Native frontend presents negotiated Chromium video"):
		printerr("Video diagnostic: ", chromium.video_error, " status: ", chromium.status)
		return
	check(not chromium.gpu_active, "Video acceptance does not claim shared GPU transport")
	host.focus_pane("%%%d" % id)
	host.workspace_view.toggle_fit_pane("%%%d" % id)
	await camera_at_rest()
	await colors("initial", Color("f020c0"), Color("20e0e0"))
	var before: int = chromium.frames
	await paint(chromium, "#f0d020", "#2050e0")
	await until(func(): return chromium.frames > before, "Changed page produces fresh decoded video")
	await colors("changed", Color("f0d020"), Color("2050e0"))
	var pane: Control = host.workspace_view.panes["%%%d" % id]
	var old_size: Vector2 = chromium.texture.get_size()
	var chrome: Vector2 = pane.size - pane.texture.size
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	host.workspace_view.set_window_rect("%%%d" % id, Rect2(pane.position, Vector2(802, 602) + chrome), true)
	await camera_at_rest()
	var page_metrics: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "({width:innerWidth,height:innerHeight})", "returnByValue": true,
	}})
	var metrics: Dictionary = page_metrics.get("result", {}).get("result", {}).get("value", {})
	var viewport := Vector2(chromium.viewport_for(Vector2(802, 602)))
	check(metrics.get("width") == viewport.x and metrics.get("height") == viewport.y, "Pane resize changes Chromium's actual CSS viewport")
	await until(func(): return chromium.texture.get_size() != old_size, "Resized video presents new dimensions")
	await colors("resized", Color("f0d020"), Color("2050e0"))
	var peer: RefCounted = chromium.connection.socket
	var settings: Dictionary = chromium.connection.shared_options.duplicate(true)
	var previous_generation: int = chromium.gpu_generation
	chromium.connection.connect_shared(settings)
	if not await until(func(): return chromium.gpu_generation > previous_generation and chromium.gpu_peer == chromium.connection.socket and chromium.connection.socket != peer and chromium.connection.connected, "Reconnect replaces the actual frontend transport"):
		return
	before = chromium.frames
	await paint(chromium, "#9030e0", "#20d0b0")
	await until(func(): return chromium.frames > before and not chromium.video_codec.is_empty(), "Reconnect resumes freshly decoded video")
	await colors("reconnected", Color("9030e0"), Color("20d0b0"))
	var chromium_tab: int = host.workspace_layout.containing("%%%d" % id)
	host.world.create_terminal_tab()
	await owner_at_rest()
	check(id not in chromium.connection.subscriptions, "Hidden Chromium is unsubscribed")
	await paint(chromium, "#20d040", "#d04020")
	before = chromium.frames
	host.select_workspace(chromium_tab)
	await owner_at_rest()
	await until(func(): return chromium.frames > before, "Showing Chromium resumes fresh video")
	await colors("shown-again", Color("20d040"), Color("d04020"))
	check(chromium.video_error.is_empty(), "Negotiated video has no decoder error")
	check(host.chromiums.has(id) and host.sessions[owner].term.get_shell_pid() == owner_pid, "Resize, reconnect and hide/show preserve Chromium and its owner PTY")
	FileAccess.open(evidence.path_join("samples.json"), FileAccess.WRITE).store_string(JSON.stringify({"samples": samples, "transport": "video", "codec": chromium.video_codec, "frames": chromium.frames, "chromium": id, "owner_pid": owner_pid}, "\t"))
