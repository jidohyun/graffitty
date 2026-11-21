extends "../../../../tests/llm-e2e/replay/replay.gd"
## A real private Chromium texture is sampled by Godot's normal viewport.
var decoded := 0
var evidence := ""
var samples: Array = []

func until(predicate: Callable, label: String, seconds := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	var success: bool = predicate.call()
	check(success, label)
	return success

func colors(label: String, left: Color, right: Color) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	var counts := [0, 0]
	var last: Image
	while Time.get_ticks_msec() < deadline:
		# The settled viewport can legitimately stop drawing. Request this
		# instrumentation capture instead of waiting forever for another frame.
		await process_frame
		RenderingServer.force_draw(false)
		var image := root.get_texture().get_image()
		last = image
		counts = [0, 0]
		for y in range(40, image.get_height(), 8):
			for x in range(0, image.get_width(), 8):
				var pixel := image.get_pixel(x, y)
				for i in range(2):
					var color: Color = [left, right][i]
					if maxf(absf(pixel.r-color.r), maxf(absf(pixel.g-color.g), absf(pixel.b-color.b))) < .18:
						counts[i] += 1
		if mini(counts[0], counts[1]) >= 80:
			image.save_png(evidence.path_join(label + ".png"))
			samples.append({"label": label, "matching_samples": counts})
			check(true, "Godot viewport samples both chromium colors: " + label)
			return
	if last != null: last.save_png(evidence.path_join(label + "-failure.png"))
	check(false, "Godot viewport samples both chromium colors: %s (%s)" % [label, counts])

func paint(chromium: Node, first: String, second: String) -> void:
	var result: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "paint('%s','%s')" % [first, second], "returnByValue": true,
	}})
	check(not result.has("error"), "Real Chromium accepts color change")

func prepare_test_display(screen: int, label: String) -> bool:
	var helper := OS.get_environment("GRAFFITTY_TEST_WINDOW_HELPER")
	if helper.is_empty():
		return true
	# Keep the window manager's workspace assignment consistent with the native
	# move. Only this test process's window is moved; global rules are unchanged.
	# Run asynchronously so Godot can answer the manager's AX requests.
	var helper_pid := OS.create_process(OS.get_environment("GRAFFITTY_TEST_WINDOW_PYTHON"), [helper,
		"--move-parent-to-screen", str(screen), "--evidence", evidence.path_join("window-move-%s.json" % label)])
	if helper_pid <= 0:
		check(false, "Launch owned-window display adapter")
		return false
	if not await until(func(): return not OS.is_process_running(helper_pid), "Owned-window display adapter completes: " + label, 20.0):
		OS.kill(helper_pid)
		return false
	var ok := OS.get_process_exit_code(helper_pid) == 0
	check(ok, "Owned-window display adapter succeeds: " + label)
	return ok

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_GPU_EVIDENCE")
	await camera_at_rest()
	# Isolate before synchronous GPU readback probes: the external manager
	# needs this process's main thread to remain available for AX requests.
	if not await prepare_test_display(host.get_window().current_screen, "initial"):
		return
	var owner: int = host.active_session_id
	var owner_pid: int = host.sessions[owner].term.get_shell_pid()
	var chromium: Node = await host.create_chromium_session(OS.get_environment("GRAFFITTY_GPU_URL"))
	if chromium == null:
		check(false, "Owner creates chromium")
		return
	var id: int = chromium.session_id
	chromium.frame_decoded.connect(func(_image): decoded += 1)
	if not await until(func(): return chromium.gpu_active and chromium.gpu_frames > 0, "Actual Godot device proves and imports shared GPU resources"):
		printerr("GPU diagnostic: ", chromium.gpu_error, " status: ", chromium.status)
		return
	check(chromium.texture is Texture2DRD, "Chromium uses native Texture2DRD instead of decoded pixels")
	host.focus_pane("%%%d" % id)
	host.workspace_view.toggle_fit_pane("%%%d" % id)
	await camera_at_rest()
	await colors("initial", Color("f020c0"), Color("20e0e0"))
	var before_decoded := decoded
	var before_frames: int = chromium.gpu_frames
	await paint(chromium, "#f0d020", "#2050e0")
	await colors("changed", Color("f0d020"), Color("2050e0"))
	check(chromium.gpu_frames > before_frames and decoded == before_decoded, "Changing native frames never decode CPU image/video pixels")
	# Resize through the pane, which owns the browser viewport. A direct browser
	# request races the pane's queued preview-size update and is overwritten.
	var pane: Control = host.workspace_view.panes["%%%d" % id]
	var old_size: Vector2 = chromium.texture.get_size()
	# Native backing scale is independent of the page's devicePixelRatio
	# (which also includes Chrome page zoom). Keep the same display and measure
	# its existing backing-pixel ratio before requesting a different extent.
	var backing_scale: float = old_size.x / float(chromium._preview_size.x)
	var chrome: Vector2 = pane.size - pane.texture.size
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	host.workspace_view.set_window_rect("%%%d" % id, Rect2(pane.position, Vector2(802, 602) + chrome), true)
	await camera_at_rest()
	var page_metrics: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "({width:innerWidth,height:innerHeight,scale:devicePixelRatio})", "returnByValue": true,
	}})
	var metrics: Dictionary = page_metrics.get("result", {}).get("result", {}).get("value", {})
	# A narrow pane fits a desktop-width page; the viewport keeps the pane's aspect.
	var viewport := Vector2(chromium.viewport_for(Vector2(802, 602)))
	check(metrics.get("width") == viewport.x and metrics.get("height") == viewport.y, "Pane resize changes Chromium's actual CSS viewport")
	# macOS adapts its raster scale to the visible pane while preserving CSS
	# geometry. Compare against the current scale, not the pre-resize ratio.
	var pixels := (viewport * backing_scale).ceil()
	var resized := false
	var resize_deadline := Time.get_ticks_msec() + 20000
	var diagnostics: Dictionary = {}
	while Time.get_ticks_msec() < resize_deadline:
		if OS.get_name() == "macOS":
			var state: Dictionary = await chromium.request("chrome-state", {})
			diagnostics = state.get("result", {})
			if not diagnostics.has("renderScale"):
				check(false, "Host reports its actual macOS raster scale")
				break
			pixels = (viewport * float(diagnostics.renderScale)).round()
		if chromium.texture.get_size() == pixels and chromium.texture.get_size() != old_size:
			resized = true
			break
		await process_frame
	print("GPU_EXPECTED_PIXELS ", {"metrics": metrics, "backing_scale": backing_scale, "pixels": pixels, "render_scale": diagnostics.get("renderScale")})
	check(resized, "Resized GPU resource imports with actual new dimensions")
	print("GPU_RESIZE_STATE ", {"before": old_size, "pane": pane.size, "preview": chromium._preview_size, "texture": chromium.texture.get_size()})
	await colors("resized", Color("f0d020"), Color("2050e0"))
	var peer: RefCounted = chromium.connection.socket
	var settings: Dictionary = chromium.connection.shared_options.duplicate(true)
	var previous_generation: int = chromium.gpu_generation
	chromium.connection.connect_shared(settings)
	if not await until(func(): return chromium.gpu_generation > previous_generation and chromium.gpu_peer == chromium.connection.socket and chromium.gpu_active and chromium.gpu_frames > 0 and chromium.connection.socket != peer, "Reconnect performs a fresh native proof"):
		return
	check(host.chromiums.has(id) and host.sessions[owner].term.get_shell_pid() == owner_pid, "Reconnect preserves chromium ID and owner shell PID")
	await colors("reconnected", Color("f0d020"), Color("2050e0"))
	var chromium_tab: int = host.workspace_layout.containing("%%%d" % id)
	var previous_imports: int = chromium.gpu_frames
	var previous_decoded := decoded
	host.world.create_terminal_tab()
	await owner_at_rest()
	check(id not in chromium.connection.subscriptions, "Hidden chromium is unsubscribed on the same connection")
	await paint(chromium, "#9030e0", "#20d0b0")
	host.select_workspace(chromium_tab)
	await owner_at_rest()
	if await until(func(): return chromium.gpu_active and chromium.gpu_frames > previous_imports, "Showing hidden chromium resumes the verified GPU channel"):
		await colors("shown-again", Color("9030e0"), Color("20d0b0"))
	print("GPU_HIDE_SHOW_STATE ", {"decoded_before": previous_decoded, "decoded_after": decoded, "gpu_active": chromium.gpu_active, "gpu_error": chromium.gpu_error, "generation": chromium.gpu_generation})
	check(decoded == previous_decoded, "Hide and show keep native transport without CPU decoding")
	if OS.get_environment("GRAFFITTY_TEST_WINDOW_LIFECYCLE") == "1":
		var window: Window = host.get_window()
		var previous_mode := window.mode
		var previous_count: int = chromium.gpu_frames
		window.mode = Window.MODE_MINIMIZED
		await until(func(): return window.mode == Window.MODE_MINIMIZED, "Native window minimizes")
		await until(func(): return not host.presentation_active and id not in chromium.connection.subscriptions, "Minimized native window releases its Chromium subscription")
		# Change the content, not just the paint call: Alloy may correctly avoid
		# producing a frame when the CSS colors are unchanged.
		await paint(chromium, "#f0d020", "#2050e0")
		window.mode = previous_mode
		await until(func(): return window.mode == previous_mode, "Native window restores its previous mode")
		if await until(func(): return chromium.gpu_active and chromium.gpu_frames > previous_count, "Restored native window resumes GPU presentation"):
			await colors("window-restored", Color("f0d020"), Color("2050e0"))
		check(host.sessions[owner].term.get_shell_pid() == owner_pid, "Minimize/restore retains the owner PTY")
	if OS.get_environment("GRAFFITTY_TEST_DISPLAY_MOVEMENT") == "1":
		var window: Window = host.get_window()
		var previous_mode := window.mode
		var previous_screen := window.current_screen
		var previous_position := window.position
		var previous_size := window.size
		var displays: Array = []
		window.mode = Window.MODE_WINDOWED
		for screen in DisplayServer.get_screen_count():
			var bounds := DisplayServer.screen_get_usable_rect(screen)
			var display_record := {"screen": screen, "dpi": DisplayServer.screen_get_dpi(screen), "scale": DisplayServer.screen_get_scale(screen), "bounds": str(bounds)}
			displays.append(display_record)
			if not await prepare_test_display(screen, "display-%d" % screen):
				continue
			display_record["started_at_ms"] = Time.get_ticks_msec()
			window.current_screen = screen
			display_record["after_screen"] = {"screen": window.current_screen, "position": str(window.position)}
			window.position = bounds.position + Vector2i(20, 20)
			display_record["after_position"] = {"screen": window.current_screen, "position": str(window.position)}
			window.size = Vector2i(mini(previous_size.x, bounds.size.x - 40), mini(previous_size.y, bounds.size.y - 40))
			display_record["after_size"] = {"screen": window.current_screen, "position": str(window.position)}
			# AppKit/window-manager placement is asynchronous. Observe a stable
			# destination instead of sampling once at an arbitrary 500 ms; do
			# not reissue the move if a window manager rejects/overrides it.
			var placement_deadline := Time.get_ticks_msec() + 5000
			var on_display_since := Time.get_ticks_msec()
			var placed := false
			while Time.get_ticks_msec() < placement_deadline:
				await process_frame
				if window.current_screen != screen:
					on_display_since = 0
				elif on_display_since == 0:
					on_display_since = Time.get_ticks_msec()
				elif Time.get_ticks_msec() - on_display_since >= 500:
					placed = true
					break
			display_record["placement_settled"] = placed
			display_record["actual_screen"] = window.current_screen
			display_record["window_position"] = str(window.position)
			display_record["window_size"] = str(window.size)
			check(placed, "Native window reaches display %d" % screen)
			if not placed:
				continue # Pixels on another monitor do not establish display coverage.
			var previous_count: int = chromium.gpu_frames
			# Distinct from both hide/show and minimize/restore content, even
			# when display movement is requested without window lifecycle.
			var first := "#e06010" if screen % 2 == 0 else "#6080f0"
			var second := "#30b070" if screen % 2 == 0 else "#d02060"
			await paint(chromium, first, second)
			if await until(func(): return chromium.gpu_active and chromium.gpu_frames > previous_count, "Display %d receives fresh native GPU frames" % screen):
				await colors("display-%d" % screen, Color(first), Color(second))
			display_record["screen_after_pixels"] = window.current_screen
			check(window.current_screen == screen, "Native window stays on display %d through pixel validation" % screen)
		await prepare_test_display(previous_screen, "restore")
		window.current_screen = previous_screen
		window.position = previous_position
		window.size = previous_size
		window.mode = previous_mode
		FileAccess.open(evidence.path_join("displays.json"), FileAccess.WRITE).store_string(JSON.stringify(displays, "\t"))
	# Destroy only this test-owned native endpoint. The owner must detect the
	# closed native receiver and resume hardware video on the same connection.
	chromium.gpu.close()
	chromium.gpu = null
	await paint(chromium, "#20d040", "#d04020")
	if await until(func(): return not chromium.gpu_active and decoded > before_decoded and chromium.texture is ImageTexture, "Closed native endpoint resumes negotiated video"):
		await colors("fallback", Color("20d040"), Color("d04020"))
		FileAccess.open(evidence.path_join("fallback-state.json"), FileAccess.WRITE).store_string(JSON.stringify({"status": chromium.status, "frames": chromium.frames, "codec": chromium.video_codec, "error": chromium.video_error, "gpu_error": chromium.gpu_error, "captured": chromium.captured_page_id, "selected": chromium.selected_page_id, "size": str(chromium.texture.get_size()), "bound_same": host.workspace_view.panes["%%%d" % id].texture.texture == chromium.texture, "bound_class": str(host.workspace_view.panes["%%%d" % id].texture.texture), "chromium_node": chromium.get_instance_id(), "host_node": host.chromiums[id].get_instance_id()}, "\t"))
		chromium.texture.get_image().save_png(evidence.path_join("fallback-texture.png"))
		host.workspace_view.canvas.get_texture().get_image().save_png(evidence.path_join("fallback-canvas.png"))
	check(host.sessions[owner].term.get_shell_pid() == owner_pid, "Fallback keeps the same live PTY")
	FileAccess.open(evidence.path_join("samples.json"), FileAccess.WRITE).store_string(JSON.stringify({"samples": samples, "decoded_frames": decoded, "chromium": id, "owner_pid": owner_pid}, "\t"))
