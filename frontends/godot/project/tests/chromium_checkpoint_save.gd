extends SceneTree

func _initialize() -> void:
	print("CHECKPOINT_USER_DIRECTORY ", JSON.stringify(OS.get_user_data_dir()))
	run.call_deferred()

func page_url(page: String, index: int, count: int) -> String:
	return OS.get_environment("CHECKPOINT_SITE") + "/" + page + ".html" + ("?window=" + str(index) if count > 1 else "")

func capture_matches(captured: Dictionary, count: int) -> bool:
	if not captured.has("result") or captured.result.windows.size() != count: return false
	for index in count:
		var window: Dictionary = captured.result.windows[index]
		if window.chromiums.size() != 1 or window.chromiums[0].urls != [page_url("second", index, count), page_url("first", index, count)]: return false
	return true

func run() -> void:
	var app: Node = root.get_node("TerminalApplication")
	var count := maxi(1, OS.get_environment("CHECKPOINT_WINDOWS").to_int())
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 30000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	assert(wrapper.host != null, "Frontend did not attach to owned server")
	for index in count:
		if index > 0:
			app.open_local_session(PackedStringArray(), OS.get_environment("XDG_STATE_HOME"))
			deadline = Time.get_ticks_msec() + 30000
			while app.hosts.size() < index + 1 and Time.get_ticks_msec() < deadline: await process_frame
		assert(app.hosts.size() == index + 1, "Native frontend window was not created")
		var host: Node = app.hosts[index]
		deadline = Time.get_ticks_msec() + 30000
		while host.active_session_id <= 0 and Time.get_ticks_msec() < deadline: await process_frame
		assert(host.active_session_id > 0, "Window did not attach to its workspace")
		if host.workspace_view.physics_enabled(): host.workspace_view.toggle_physics()
		var profiles := OS.get_environment("CHECKPOINT_PROFILES")
		var profile := profiles.path_join(str(index)) if not profiles.is_empty() else ""
		var browser: Node = await host.create_chromium_session(page_url("first", index, count), -1, true, profile)
		assert(browser != null, "Owned browser was not created")
		await browser.request("tab-new", {"url": page_url("second", index, count)})
		deadline = Time.get_ticks_msec() + 30000
		var title := ""
		while title != "second" and Time.get_ticks_msec() < deadline:
			var reply: Dictionary = await browser.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "document.title", "returnByValue": true}})
			title = str(reply.get("result", {}).get("result", {}).get("value", ""))
			await create_timer(.1).timeout
		assert(title == "second", "Original selected page did not load")
		if not profiles.is_empty():
			var stored: Dictionary = await browser.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "localStorage.getItem('checkpoint-window')", "returnByValue": true}})
			assert(stored.get("result", {}).get("result", {}).get("value") == str(index), "Seeded profile storage missing")
		await browser.request("cdp", {"method": "Runtime.evaluate", "params": {"expression": "window.unsavedCheckpointMarker=42;true", "returnByValue": true}})
	var captured: Dictionary
	deadline = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		captured = await app.checkpoints.capture()
		if capture_matches(captured, count): break
		await create_timer(.2).timeout
	assert(capture_matches(captured, count), "Saved windows/pages/selection differ")
	FileAccess.open(OS.get_environment("CHECKPOINT_DOCUMENT"), FileAccess.WRITE).store_string(JSON.stringify(captured.result))
	print("CHROMIUM_CHECKPOINT_SAVE_PASS")
	if OS.get_environment("CHECKPOINT_WAIT_FOR_CRASH") == "1":
		deadline = Time.get_ticks_msec() + 90000
		while app.hosts[0].session_backend.connection.connected and Time.get_ticks_msec() < deadline:
			await process_frame
		assert(not app.hosts[0].session_backend.connection.connected, "Owned server was not terminated while frontend was alive")
	quit()
