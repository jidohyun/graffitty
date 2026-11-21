extends "../../../../replay/replay.gd"

var chromium: Node

func ready(predicate: Callable, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not predicate.call() and is_instance_valid(chromium):
		print("NATIVE_CHROMIUM_STATE ", await chromium.request("chrome-state"), " status=", chromium.status)
	return check(predicate.call(), label)

func evaluate(expression: String) -> Variant:
	var result: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": expression, "returnByValue": true}})
	return result.get("result", {}).get("result", {}).get("value")

func activate_owner(helper: String) -> int:
	var result := [-1, []]
	var arguments := PackedStringArray([helper, str(OS.get_process_id()), "--activate"])
	var task := WorkerThreadPool.add_task(func(): result[0] = OS.execute("python", arguments, result[1], true))
	while not WorkerThreadPool.is_task_completed(task):
		await process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	print("NATIVE_OWNER_FOCUS ", result[1])
	return result[0]

func measure_motion() -> void:
	await evaluate("window.videoTicks=0;window.videoRunning=true;function videoTick(){if(!videoRunning)return;document.body.style.background='hsl('+((++videoTicks*7)%360)+' 80% 50%)';requestAnimationFrame(videoTick)};videoTick();true")
	await hold(2.0)
	var before: int = chromium.gpu_frames
	var started := Time.get_ticks_msec()
	await hold(10.0)
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	var fps: float = (chromium.gpu_frames - before) / elapsed
	print("WINDOWS_CHROMIUM_MOTION ", JSON.stringify({"fps": fps, "seconds": elapsed,
		"frames": chromium.gpu_frames - before, "shared_gpu": chromium.gpu_active,
		"size": [chromium.texture.get_width(), chromium.texture.get_height()]}))
	check(chromium.gpu_active and fps >= 55.0, "Embedded shared-GPU video sustains display cadence")
	await evaluate("window.videoRunning=false;document.body.style.background='#2040b0';true")

func play() -> void:
	root.always_on_top = false
	await camera_at_rest()
	host.world.fx_enabled = false
	chromium = await host.create_chromium_session("about:blank")
	if not check(chromium != null, "A private Windows CEF chromium is created"): return
	if not await ready(func(): return chromium.chromium_ready and chromium.gpu_active and chromium.gpu_frames > 0, "D3D12 imports verified frames"): return
	var chromium_pid: int = chromium.pid
	var first: int = chromium.selected_page_id
	var page_ids: Array[int] = [first]
	var key := "%%%d" % chromium.session_id
	var pane: Control = host.workspace_view.panes[key]
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	host.workspace_view.set_window_rect(key, Rect2(40, 100, 1000, 700), true)
	host.workspace_view.toggle_fit_pane(key)
	await camera_at_rest()
	check(await evaluate("window.marker='first';document.body.style.background='#d04040';document.title='First';marker") == "first", "First page owns its live marker")
	for count in [2, 3]:
		root.get_texture().get_image().save_png(OS.get_environment("XDG_STATE_HOME").path_join("before-plus-%d.png" % count))
		print("PLUS_POINT ", on(pane.chrome.tabs.plus), " size=", pane.chrome.tabs.plus.size)
		await click(on(pane.chrome.tabs.plus))
		if not await ready(func(): return chromium.page_tabs.size() == count and chromium.selected_page_id not in page_ids, "Plus creates and selects page %d" % count): return
		page_ids.append(chromium.selected_page_id)
		check(await evaluate("window.marker='page%d';document.body.style.background='#2040b0';document.title='Page %d';marker" % [count, count]) == "page%d" % count, "New page has independent JavaScript state")
	await click(on(pane.chrome.tabs.buttons[first]))
	if not await ready(func(): return chromium.selected_page_id == first, "Pointer selects the first page"): return
	check(await evaluate("window.marker") == "first", "Selecting restores the same first page")
	await click(on(pane.chrome.tabs.buttons[first].get_node("Close")))
	if not await ready(func(): return chromium.page_tabs.size() == 2, "Closing the first page retains two live pages"): return
	check(await evaluate("window.marker") in ["page2", "page3"], "The surviving tab remains controllable after the original CDP page closes")
	await click(on(pane.chrome.tabs.buttons[page_ids[2]]))
	if not await ready(func(): return chromium.selected_page_id == page_ids[2], "Surviving page IDs route to the correct tab"): return
	check(await evaluate("window.marker") == "page3", "The third page survives first-page closure")
	await measure_motion()
	var before_zoom: float = float(await evaluate("devicePixelRatio"))
	chromium.change_text_size(1)
	await hold(.5)
	check(float(await evaluate("devicePixelRatio")) > before_zoom, "Chrome page zoom uses its native command")
	chromium.change_text_size(0)
	await hold(.3)
	var external: Button = pane.chrome.native_button
	check(external.visible == chromium.can_open_native(), "Native window button follows the server capability")
	if not chromium.can_open_native():
		check(not chromium.native_window_supported, "Alloy keeps browser pages inside Graffitty")
		chromium.close()
		return
	var helper: String = get_script().resource_path.get_base_dir().path_join("chromium-native.py")
	for attempt in 2:
		if not check(await activate_owner(helper) == 0, "The owning Godot window receives real desktop input"): return
		await hold(.2)
		if not check(root.has_focus(), "The owning Godot window is foreground before opening Chrome"): return
		await click(on(external))
		if not await ready(func(): return chromium.native_visible, "Native Chrome opens on attempt %d" % (attempt + 1)): return
		var state: Dictionary = (await chromium.request("chrome-state")).get("result", {})
		var focus_deadline := Time.get_ticks_msec() + 3000
		while not state.get("nativeFocused", false) and Time.get_ticks_msec() < focus_deadline:
			await process_frame
			state = (await chromium.request("chrome-state")).get("result", {})
		print("NATIVE_PRESENTATION ", state)
		check(state.get("nativeFocused", false) and int(state.get("visibleWindows", 0)) == 1, "Exactly one owned native chromium is foreground")
		check(chromium.pid == chromium_pid and await evaluate("window.marker") == "page3", "Native presentation preserves chromium identity and page state")
		var output := OS.get_environment("XDG_STATE_HOME").path_join("native-chromium-%d.png" % attempt)
		check(OS.execute("python", PackedStringArray([helper, str(chromium_pid), output])) == 0, "Capture and close only the owned native window")
		if not await ready(func(): return not chromium.native_visible, "Native close returns to embedded presentation"): return
		var previous: int = chromium.gpu_frames
		await evaluate("document.body.style.background='%s';true" % ["#206030", "#806020"][attempt])
		if not await ready(func(): return chromium.gpu_frames > previous, "GPU import resumes after native close"): return
		check(chromium.pid == chromium_pid and await evaluate("window.marker") == "page3", "Returning retains the live chromium and page")
	chromium.close()
