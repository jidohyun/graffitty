extends "res://tests/client_scenarios/workspace.gd"
## Feature checks through a real owner; shared by desktop simulation and APK.

func scene_retention() -> void:
	var original: String = host.pane_focus
	var writer := "import sys,time; print('REMOTE_BEFORE',flush=True); time.sleep(3); print('REMOTE_DURING',flush=True); time.sleep(1); print('REMOTE_AFTER',flush=True)"
	await run_python(writer)
	if not await until(func(): return "REMOTE_BEFORE" in text_in(), "Remote writer reaches the scene replica"): return
	expect(terminal().perform_action("copy_mode"), "Copy mode opens on remote terminal")
	await until(func(): return terminal().get_ui_state().held_output, "Owner output is held during copy mode")
	expect(not "REMOTE_DURING" in text_in(), "Frozen text excludes incoming output")
	await key(KEY_ESCAPE)
	await until(func(): return "REMOTE_AFTER" in text_in(), "Leaving copy mode applies latest owner state")
	var peer := await new_tab()
	terminal().send_text("printf 'REMOTE_PEER\\n'\r")
	await until(func(): return "REMOTE_PEER" in text_in(), "Second tab remains interactive")
	await select_tab(initial_id)
	await until(func(): return "REMOTE_AFTER" in text_in(original), "Inactive tab retains its completed output")
	view.show_overview()
	await wait(.3)
	expect(not text_in(original).is_empty(), "Overview restores retained terminal text without new output")
	expect(peer != initial_id, "Tabs have independent identities")

func remote_notifications() -> void:
	# Native desktop notifications are unavailable on Android. Both OSC forms
	# must be consumed without spawning a desktop helper or opening diagnostics.
	await run_python("import sys; sys.stdout.write('\\x1b]9;Android remote notification\\x07\\x1b]99;i=android-e2e;Remote Unicode 한글\\x1b\\\\\\nNOTIFICATION_DONE\\n'); sys.stdout.flush()")
	await until(func(): return "NOTIFICATION_DONE" in text_in(), "OSC 9 and OSC 99 traverse the remote PTY")
	await wait(1.0)
	expect(diagnostic_guard.failures.is_empty(), "Remote notifications produce no diagnostic dialog")
	terminal().send_text("printf 'NOTIFICATION_RECOVERED\\n'\r")
	await until(func(): return "NOTIFICATION_RECOVERED" in text_in(), "Terminal accepts input after notifications")

func typing_effects() -> void:
	var first: String = host.pane_focus
	var second := await split(first)
	if second.is_empty(): return
	var world: Node = host.world
	world.fx_enabled = true
	world.fx_cfg.set_option("state.typing", "camera.zoom", 1.15)
	world.fx_cfg.set_option("scene.typing", "pane_zoom", 1.1)
	world.fx_cfg.set_option("behavior", "enter_duration", .2)
	world.fx_cfg.set_option("behavior", "idle_after", 10.0)
	world.fx_cfg.set_option("behavior", "leave_duration", .3)
	world._fx_apply_scene()
	host.focus_pane(second)
	terminal().grab_focus()
	await key(KEY_A, false, false, 97)
	await until(func(): return world.fx_typing > .8, "Remote key input activates typing effects")
	# Effects react locally; the echo needs a round trip through the owner.
	await until(func(): return "a" in text_in(), "Typing also reaches the owner PTY")
	host.focus_pane(first)
	await until(func(): return world.fx_typing < .01, "Changing focus cancels and settles typing effects")
	host.focus_pane(second)
	await wait(.4)
	expect(world.fx_typing < .01, "Returning to a pane does not revive cancelled effects")
	await key(KEY_U, true, false, 117)
	world.fx_enabled = false

func terminal_throughput() -> void:
	var source := "import time; time.sleep(2)\nfor frame in range(200):\n print('\\x1b[36m'+('render %04d 한글 abcdefghijklmnopqrstuvwxyz\\n'%frame)*10+'\\x1b[0m',end='',flush=True); time.sleep(.05)\nprint('THROUGHPUT_DONE',flush=True)"
	await _terminal_stream(source, false)

func agent_title_stream() -> void:
	# Match the aggregate title-update rate observed with Claude/Codex/Pi,
	# without spending provider tokens or depending on account credentials.
	var source := "import time; time.sleep(2)\nfor frame in range(40):\n print('\\x1b]2;Agent spinner %04d\\x07'%frame+'\\x1b[36m'+('render %04d 한글 abcdefghijklmnopqrstuvwxyz\\n'%frame)*10+'\\x1b[0m',end='',flush=True); time.sleep(.25)\nprint('THROUGHPUT_DONE',flush=True)"
	await _terminal_stream(source, true)

func _terminal_stream(source: String, observe_titles: bool) -> void:
	var panes: Array[String] = [host.pane_focus]
	for index in 5:
		var created := await split(panes[0])
		if created.is_empty(): return
		panes.append(created)
	view.show_overview()
	await wait(.5)
	# Deterministic colored scrolling and cursor rewrites, without provider cost.
	# A start delay lets all six PTYs enter the workload before measuring.
	var titles: Dictionary = {}
	for pane in panes:
		titles[pane] = 0
		if observe_titles:
			host.session_model(int(pane.substr(1))).title_changed.connect(func(value):
				if str(value).begins_with("Agent spinner "): titles[pane] += 1)
		terminal(pane).send_text("python3 -c 'import base64;exec(base64.b64decode(\"%s\"))'\r" % Marshalls.utf8_to_base64(source))
	await wait(2.0)
	var paints: Dictionary = {}
	var focus: Dictionary = {}
	for pane in panes:
		paints[pane] = 0
		terminal(pane).frame_changed.connect(func(): paints[pane] += 1)
		focus[pane] = {"focused": terminal(pane).has_focus(), "input_disabled": terminal(pane).get_viewport().gui_disable_input}
	var fonts_before := {"complete": transport.server_fonts.complete, "fetch_percent": transport.server_fonts.fetch_percent}
	var intervals: Array[float] = []
	var profile := preload("res://graffitty/frame_profile.gd")
	var render_stats := preload("res://graffitty/render_stats.gd")
	print(render_stats.report(get_tree()))
	profile.take()
	var previous := Time.get_ticks_usec()
	var end := previous + 12000000
	while Time.get_ticks_usec() < end:
		await get_tree().process_frame
		if not render_stats.enabled(): profile.frame()
		var now := Time.get_ticks_usec()
		intervals.append(float(now - previous) / 1000.0)
		previous = now
	intervals.sort()
	var report := {"frames": intervals.size(), "p95_ms": intervals[int(intervals.size() * .95)], "p99_ms": intervals[int(intervals.size() * .99)], "max_ms": intervals.back(), "panes": panes.size(), "repaints": paints, "focus": focus, "title_updates": titles}
	report["profile"] = profile.take()
	report["render"] = render_stats.report(get_tree())
	report["fonts_before"] = fonts_before
	report["fonts_after"] = {"complete": transport.server_fonts.complete, "fetch_percent": transport.server_fonts.fetch_percent}
	var report_file := FileAccess.open("user://throughput-result.json", FileAccess.WRITE)
	report_file.store_string(JSON.stringify(report))
	report_file.close()
	print("[android throughput] ", JSON.stringify(report))
	for pane in panes:
		# Six panes side by side are a few columns wide on a portrait device,
		# so the marker wraps across rows.
		await until(func(): return "THROUGHPUT_DONE" in text_in(pane).replace("\n", ""), "Output completes in " + pane)
	if observe_titles:
		for pane in panes: expect(titles[pane] > 1, "Animated owner titles reach " + pane)
	# A responsive event loop is insufficient if backpressure leaves panes
	# showing stale output. Allow coalescing while requiring visible progress.
	var minimum_paints := 20 if observe_titles else 40
	for pane in panes:
		expect(paints[pane] >= minimum_paints, "Streaming pane repaints at least %d times: %s" % [minimum_paints, pane])
	expect(report.p95_ms < 50.0, "Six streaming panes keep P95 main-loop interval below 50 ms")
	expect(report.max_ms < 500.0, "No half-second stall during terminal output")
