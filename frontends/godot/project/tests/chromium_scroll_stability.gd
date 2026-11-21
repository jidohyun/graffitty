extends "../../../../tests/llm-e2e/replay/replay.gd"
## Sustained real Mac pane gestures through the shared-GPU Chromium transport.
var chromium: Node

func evaluate(expression: String) -> Variant:
	var result: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": true}})
	check(not result.has("error"), "Chromium control remains responsive")
	return result.get("result", {}).get("result", {}).get("value")

func play() -> void:
	await camera_at_rest()
	host.world.fx_enabled = false
	chromium = await host.create_chromium_session("about:blank")
	if not check(chromium != null, "Creates isolated Chromium"): return
	var deadline := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(chromium.chromium_ready, "Chromium becomes ready"): return
	var html := "<!doctype html><style>html,body{margin:0;background:#f08060}body{font:32px sans-serif;color:#222}section{height:160px;padding:8px;box-sizing:border-box;background:linear-gradient(110deg,#20ffff,#ffcc40);will-change:transform;transform:translateZ(0)}section:nth-child(even){background:linear-gradient(20deg,#ff80ff,#80ff40)}.fixed{position:fixed;top:0;width:100%;height:65px;background:#ffffff80;backdrop-filter:blur(12px);z-index:2}</style>"
	for index in 80:
		html += "<section>Scroll stability row %d: 한글 日本語</section>" % index
	html += "<div class=fixed>Composited header</div>"
	check(await evaluate("document.open();document.write(%s);document.close();true" % JSON.stringify(html)) == true, "Fixture installed")
	host.focus_pane("%%%d" % chromium.session_id)
	host.workspace_view.toggle_fit_pane("%%%d" % chromium.session_id)
	await camera_at_rest()
	deadline = Time.get_ticks_msec() + 10000
	while not chromium.gpu_active and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(chromium.gpu_active, "Actual Mac native shared-GPU path is active"): return
	var pane: Control = host.workspace_view.panes["%%%d" % chromium.session_id]
	var trace: Array = []
	for cycle in 8:
		for direction in [1, -1]:
			var before: int = chromium.gpu_frames
			for step in 120:
				var gesture := InputEventPanGesture.new()
				gesture.device = REPLAY_POINTER_DEVICE
				gesture.position = on(pane.texture, Vector2(.5, .5))
				gesture.delta = Vector2(.001 if step % 2 else -.001, direction * 4.0)
				root.push_input(gesture, true)
				await hold(.008333)
			await hold(.7)
			var position: Variant = await evaluate("({y:scrollY,height:innerHeight,total:document.documentElement.scrollHeight})")
			if not check(position is Dictionary, "Page still responds after gesture"): return
			check(absf(position.y - (position.total - position.height if direction > 0 else 0)) <= 1, "Repeated gesture reaches document edge")
			check(chromium.gpu_active and chromium.gpu_frames > before + 10, "GPU frames keep advancing throughout repeated scrolling")
			trace.append({"cycle": cycle, "direction": direction, "frames": chromium.gpu_frames - before, "position": position})
			print("SCROLL_GPU ", trace[-1])
	var evidence := OS.get_environment("GRAFFITTY_SCROLL_EVIDENCE")
	if not evidence.is_empty():
		FileAccess.open(evidence.path_join("gpu-scroll.json"), FileAccess.WRITE).store_string(JSON.stringify(trace, "  "))
		root.get_texture().get_image().save_png(evidence.path_join("gpu-scroll-final.png"))
	var state: Dictionary = (await chromium.request("chrome-state")).get("result", {})
	for counter in ["visibleWindows", "unexpectedWindowOrders", "unexpectedKeyEvents", "unexpectedActivations", "errors"]:
		check(int(state.get(counter, -1)) == 0, "%s remains zero" % counter)
	chromium.close()
