extends "../../../../tests/llm-e2e/replay/replay.gd"
## Real GUI + CEF + authorized socket fixture for the published JS entry points.

func play() -> void:
	await camera_at_rest()
	var directory := OS.get_environment("GRAFFITTY_PLAYWRIGHT_TEST_DIR")
	var chromium: Node = await host.create_chromium_session(OS.get_environment("GRAFFITTY_PLAYWRIGHT_TEST_URL"))
	var until := Time.get_ticks_msec() + 30000
	while not chromium.chromium_ready and Time.get_ticks_msec() < until:
		await process_frame
	check(chromium.chromium_ready, "Embedded Chromium is ready")
	if not chromium.chromium_ready:
		return
	var loaded := false
	until = Time.get_ticks_msec() + 20000
	while not loaded and Time.get_ticks_msec() < until:
		var state: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
			"expression": "document.readyState === 'complete' && location.href === " + JSON.stringify(OS.get_environment("GRAFFITTY_PLAYWRIGHT_TEST_URL")), "returnByValue": true}})
		loaded = state.get("result", {}).get("result", {}).get("value", false) == true
		await process_frame
	check(loaded, "Test HTTP page finished navigating before owner setup")
	var proof: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "window.ownerProof='graffitty-owned'; window.retainedCount=0", "returnByValue": true}})
	check(not proof.has("error"), "Owner marks the existing primary page")
	var initial_pid: int = chromium.pid
	var initial_page: int = chromium.primary_page_id
	var initial_frames: int = chromium.frames
	var original_workspace: int = host.workspace_layout.active
	var created: Dictionary = await host.session_backend.connection.request_action("create", {"kind": "tab"})
	if not check(created.get("type") == "ack", "Owner creates foreign capability fixture"): return
	var foreign_id := int(created.created)
	until = Time.get_ticks_msec() + 10000
	while not host.sessions.has(foreign_id) and Time.get_ticks_msec() < until:
		await process_frame
	var foreign: Dictionary = host.agent_api.environment_for(foreign_id)
	# Creating an owner-backed tab selects it. Return to the chromium workspace
	# before measuring pushed presentation frames during the attachment.
	for index in host.get_tabs().size():
		if int(host.get_tabs()[index].id) == original_workspace:
			await select_tab(index)
			break
	await camera_at_rest()
	initial_frames = chromium.frames
	var env: Dictionary = host.agent_api.environment_for(chromium.tab_id)
	var ready := FileAccess.open(directory.path_join("ready.json"), FileAccess.WRITE)
	ready.store_string(JSON.stringify({"env": env, "chromium": "%%%d" % chromium.session_id,
		"pid": initial_pid, "profile": chromium.profile_directory, "foreign_token": foreign.GRAFFITTY_TOKEN}))
	ready.close()
	until = Time.get_ticks_msec() + 180000
	while not FileAccess.file_exists(directory.path_join("done")) and Time.get_ticks_msec() < until:
		for request in ["hide-chromium", "restore-chromium"]:
			if not FileAccess.file_exists(directory.path_join(request)): continue
			DirAccess.remove_absolute(directory.path_join(request))
			var destination: int = foreign_id if request == "hide-chromium" else original_workspace
			for index in host.get_tabs().size():
				if int(host.get_tabs()[index].id) == destination:
					await select_tab(index)
					break
			await camera_at_rest()
			check(host.workspace_layout.active == destination, "Attachment fixture selects the requested workspace")
			var name := "chromium-hidden.json" if request == "hide-chromium" else "chromium-restored.json"
			var acknowledgement := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
			acknowledgement.store_string(JSON.stringify({"active": host.workspace_layout.active, "chromium_workspace": original_workspace}))
			acknowledgement.close()
		if FileAccess.file_exists(directory.path_join("revoke")):
			host.agent_api.revoke(chromium.tab_id)
			DirAccess.remove_absolute(directory.path_join("revoke"))
		await process_frame
	check(FileAccess.file_exists(directory.path_join("done")), "Package clients completed before timeout")
	check(chromium.pid == initial_pid and OS.is_process_running(initial_pid), "Attachment never replaces or closes the owner's chromium")
	check(chromium.primary_page_id == initial_page, "The same primary page survives every attachment")
	print("[attachment frames] ", JSON.stringify({"before": initial_frames, "after": chromium.frames,
		"gpu_active": chromium.gpu_active, "gpu_frames": chromium.gpu_frames, "gpu_error": chromium.gpu_error,
		"video_codec": chromium.video_codec, "subscriptions": chromium.connection.subscriptions,
		"workspace": host.workspace_layout.active, "chromium_workspace": original_workspace}))
	check(chromium.frames > initial_frames, "GPU frames keep arriving during Playwright automation")
	var value: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "({owner:window.ownerProof,count:window.retainedCount,fixture:window.fixturePassed})", "returnByValue": true}})
	var state: Dictionary = value.get("result", {}).get("result", {}).get("value", {})
	check(state.get("owner") == "graffitty-owned" and int(state.get("count", 0)) == 2, "Node and Bun operated on the original page and preserved state")
	check(state.get("fixture", false), "Playwright Test fixture used that same page")
	check(not FileAccess.file_exists(chromium.profile_directory.path_join("DevToolsActivePort")), "No public Chromium CDP listener was opened")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(directory.path_join("workspace.png"))
	chromium.close()
