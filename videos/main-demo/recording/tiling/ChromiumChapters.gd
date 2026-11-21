extends RefCounted
## Real editor/plugin, real chromium surfaces, and scripted agents executing gft.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var r: SceneTree
var host: Node
var output: String
var voice_durations := {}

func _init(replay: SceneTree) -> void:
	r = replay
	host = r.host
	output = r.output
	var audio_path := output.path_join("demo-audio.json")
	if FileAccess.file_exists(audio_path):
		var audio: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(audio_path))
		for voice in audio.get("voices", []):
			voice_durations[voice.id] = float(voice.duration_s)

func movie_frame() -> int:
	return Engine.get_singleton("GraffittyMovieWriter").frames_written()


func finish_narration(id: String, start_frame: int) -> void:
	var end_frame := start_frame + int(ceil((float(voice_durations.get(id, 0)) + 0.8) * 60))
	while movie_frame() < end_frame: await r.process_frame

func evaluate(chromium: Node, expression: String) -> Variant:
	var reply: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": expression, "returnByValue": true}})
	return reply.get("result", {}).get("result", {}).get("value")

func wait_chromium(chromium: Node, expression: String, label: String, seconds := 25.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if await evaluate(chromium, expression) == true:
			r.check(true, label)
			return true
		await r.process_frame
	r.check(false, label)
	await r.snapshot("failed-chromium")
	return false

func active_agent(key: String) -> bool:
	return str(host.agent_api.graph.nodes.get(key, {}).get("status", "")) == "busy"

func drag_out(key: String, position: Vector2) -> void:
	var view: Control = host.workspace_view
	var handle: Control = view.panes[key].handle
	var offset: Vector2 = handle.get_global_transform() * (handle.size * 0.5) - view.pane_rects[key].position
	await r.drag(r.on(handle), view.window_point(position + offset), 0.7)
	await r.hold(0.25)

func resize_stashed(key: String, size: Vector2) -> void:
	var view: Control = host.workspace_view
	var rect: Rect2 = view.pane_rects[key]
	await r.drag(view.window_point(rect.end - Vector2(2, 2)),
		view.window_point(rect.position + size - Vector2(2, 2)), 0.4)
	await r.hold(0.2)


func native_window_demo(chromium: Node, key: String, editor: String, codex: String) -> void:
	var reused_path: String = output.path_join("reused-native-window.json")
	if FileAccess.file_exists(reused_path):
		var reused: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(reused_path))
		if reused.has("composited_scene"):
			# This interval is replaced by the already captured complete scene.
			# Do not open, activate or capture a native Chromium window again.
			await r.say("Native chromium control clicked")
			reused.start_frame = movie_frame()
			while movie_frame() < int(reused.start_frame) + 384: await r.process_frame
			reused.end_frame = movie_frame()
			var source_scale: float = float(r.root.get_texture().get_width()) / r.root.get_visible_rect().size.x
			var source_pointer: Vector2 = r.overlay.pointer * source_scale
			var output_pointer := Vector2(288, 112) + source_pointer * (1344.0 / r.root.get_texture().get_width())
			reused.cursor_return_source = [source_pointer.x, source_pointer.y]
			reused.cursor_return_hotspot = [output_pointer.x, output_pointer.y]
			FileAccess.open(output.path_join("native-window/capture.json"), FileAccess.WRITE).store_string(JSON.stringify(reused))
			r.check(not chromium.native_visible, "Native window scene reused without reopening a window")
			await r.say("Native chromium returned to four-pane layout")
			await r.hold(5.0)
			return
	var view: Control = host.workspace_view
	var chrome: Control = view.panes[key].chrome
	var external: Button
	for button in chrome.find_children("*", "Button", true, false):
		if button.tooltip_text == "Open all tabs in Chrome": external = button
	if not r.check(external != null and external.is_visible_in_tree(), "The chromium has its real Open all tabs in Chrome control"): return
	var saved_effects: Dictionary = r.hold_full_view()
	await r.say("Open the E2E chromium in a native window")
	await r.point_at(r.on(external))
	await r.press()
	await r.say("Native chromium control clicked")
	await r.release(MOUSE_BUTTON_LEFT, 0.0)
	var pointer: Vector2 = r.overlay.pointer
	var writer := Engine.get_singleton("GraffittyMovieWriter")
	# Native window startup/readback is wall-clock work. Exclude it from the
	# movie so it cannot insert an encoder-dependent delay after the click.
	writer.set_recording(false)
	if not await r.until(func(): return chromium.native_visible, "Toolbar click opens the same native Chromium session", 10.0):
		writer.set_recording(true)
		r.restore_full_view(saved_effects)
		return
	# Desktop tiling matters only when sampling fresh external-window pixels.
	# A reused capture already has verified bounds and does not need another
	# window-manager registration; the app surroundings are still recorded.
	if not FileAccess.file_exists(reused_path):
		r.check(preload("res://videos/main-demo/recording/tiling/NativeWindowLayout.gd").float_owned_window(chromium.pid),
			"The private native chromium floats independently of desktop tiling")
	var resize: Dictionary = await chromium.request("cdp", {"method": "Browser.getWindowForTarget", "params": {}})
	var window_id: int = int(resize.get("result", {}).get("windowId", -1))
	if not r.check(window_id >= 0, "Native chromium exposes its real window bounds"):
		chromium.return_to_preview()
		writer.set_recording(true)
		r.restore_full_view(saved_effects)
		return
	var positioned: Dictionary = await chromium.request("cdp", {"method": "Browser.setWindowBounds", "params": {
		"windowId": window_id, "bounds": {"left": 120, "top": 100, "width": 900, "height": 560}}})
	# CEF's Browser.setWindowBounds can acknowledge without resizing the
	# AppKit host. Use the host's actual content-size command as well.
	var sized: Dictionary = await chromium.request("resize", {"width": 900, "height": 500})
	r.check(not positioned.has("error") and not sized.has("error"), "Native window uses a readable fixed Retina capture size")
	await r.hold(0.3)
	var before: String = str(await evaluate(chromium, "document.querySelector('li span')?.textContent"))
	var capture := preload("res://videos/main-demo/recording/tiling/NativeWindowCapture.gd").new(r, chromium)
	# The composited pointer starts exactly at the recorded toolbar click, then
	# stays attached to the native title bar during the two concise window drags.
	r.overlay.pointer = Vector2(-100, -100)
	if capture.begin():
		await r.say("Native chromium visible; E2E continues")
		var frames := 384  # Close at 6.4s, on “brings ... back”, at native playback speed.
		writer.set_recording(true)
		while writer.frames_written() < capture.start_frame + frames: await r.process_frame
		writer.set_recording(false)
		capture.finish(pointer, frames)
		r.check(active_agent(editor) and active_agent(codex), "Both agents remain busy during the native window reveal")
		var after: String = str(await evaluate(chromium, "document.querySelector('li span')?.textContent"))
		r.check(before != after, "The E2E test changes real page state while Chromium is native")
	# Close only the presentation; the same live page returns to its tiled pane.
	chromium._preview_size = Vector2i.ZERO
	chromium.return_to_preview()
	await r.until(func(): return not chromium.native_visible, "Native window returns to the same chromium pane")
	await r.hold(0.3)
	r.restore_full_view(saved_effects)
	await r.say("Native chromium returned to four-pane layout")
	# Leave the replay arrow out of these frames so the composited native
	# pointer can travel back continuously without a second pointer underneath.
	var metadata_path := output.path_join("native-window/capture.json")
	var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
	# Movie Maker encodes 2400px even when the Retina backing texture is larger.
	var source_scale: float = 2400.0 / r.root.get_visible_rect().size.x
	var source_pointer: Vector2 = pointer * source_scale
	var output_pointer := Vector2(288, 112) + source_pointer * 0.56
	metadata.cursor_return_frames = 45
	metadata.cursor_return_source = [source_pointer.x, source_pointer.y]
	metadata.cursor_return_hotspot = [output_pointer.x, output_pointer.y]
	metadata.cursor_scale = 1.344
	metadata.click_intro = {"frames": 22, "playback_rate": 1.0,
		"source_frames": [metadata.start_frame - 22, metadata.start_frame]}
	FileAccess.open(metadata_path, FileAccess.WRITE).store_string(JSON.stringify(metadata))
	writer.set_recording(true)
	var return_start := movie_frame()
	while movie_frame() < return_start + 45: await r.process_frame
	r.overlay.pointer = pointer
	await r.hold(4.25)  # Five seconds total before the ownership narration.
	await r.snapshot("14a-native-chromium-returned")


func play() -> void:
	var view: Control = host.workspace_view
	FileAccess.open(output.path_join("host-mode"), FileAccess.WRITE).close()
	DirAccess.copy_absolute(output.path_join("guide.md"), r.demo_directory.path_join("guide.md"))
	await r.say("Chapter: Chromium: markdown preview")
	var markdown_start := movie_frame()
	await r.say("Select the Markdown session")
	if not await r.demo_sessions.select("Markdown"): return
	var old_chromiums: Array = host.chromiums.keys()
	var editor: String = host.pane_focus
	await r.ready_shell(editor)
	await r.say("Markdown session ready for typing")
	if "--through-filetree" in OS.get_cmdline_user_args():
		r.check(r.demo_sessions.prepared.size() == 5, "All five feature sessions existed before recording")
		await r.snapshot("11c-markdown-session-ready")
		await r.say("Finished")
		return
	await r.command("nvim guide.md")
	if not await r.until(func(): return "A connected workspace" in r.shell_text(editor), "Neovim opens the Markdown document"): return
	await r.hold(0.2)
	# Keep the camera through the brief command confirmation and submit promptly.
	var saved_idle_after: float = host.world.fx_idle_after
	host.world.fx_idle_after = maxf(saved_idle_after, 3.0)
	await r.say("Open the preview with :MarkdownPreview")
	await r.human_text(":MarkdownPreview")
	await r.say("MarkdownPreview typed; hold before Enter")
	await r.hold(0.2)
	r.check(host.world.fx_time - host.world.fx_last_key < host.world.fx_idle_after,
		"MarkdownPreview stays in the typing camera hold until Enter")
	r._send_key(KEY_ENTER, 0, {})
	await r.say("MarkdownPreview submitted")
	if not await r.until(func(): return host.chromiums.size() == old_chromiums.size() + 1, "The configured Neovim plugin opens Graffitty Chromium", 30.0):
		host.world.fx_idle_after = saved_idle_after
		return
	var preview_id := 0
	for id in host.chromiums:
		if id not in old_chromiums: preview_id = id
	var preview: Node = host.chromiums[preview_id]
	var preview_key := "%%%d" % preview_id
	if not await wait_chromium(preview, "document.querySelector('#content h1')?.textContent === 'A connected workspace'", "The real Markdown plugin renders the document"):
		host.world.fx_idle_after = saved_idle_after
		return
	host.world.fx_idle_after = saved_idle_after
	# Start demonstrating the live document as soon as the preview is ready;
	# waiting for the typing camera's idle tail adds several empty seconds.
	var saved_effects: Dictionary = r.hold_full_view()
	await r.owner_at_rest()
	await r.say("Markdown preview ready")
	await r.snapshot("12-markdown-preview")
	await r.click(r.on(view.panes[editor].handle))
	await r.say("Type the Markdown heading")
	await r.type("ggcc")
	await r.human_text("# Markdown Demo")
	await r.type("{escape}:w{enter}")
	if not await wait_chromium(preview, "document.querySelector('#content h1')?.textContent === 'Markdown Demo'", "Typed heading updates the live Markdown preview"): return
	await r.snapshot("12a-markdown-heading")
	await r.hold(0.4)
	var initial: float = float(await evaluate(preview, "window.scrollY"))
	await r.say("Move down through Markdown line by line")
	var positions: Array[float] = []
	for i in 44:
		r._send_key(KEY_J, "j".unicode_at(0), {})
		await r.hold(0.045)
		if i % 8 == 7:
			positions.append(float(await evaluate(preview, "window.scrollY")))
	await r.hold(0.3)
	var scrolled: float = float(await evaluate(preview, "window.scrollY"))
	r.check(scrolled > initial + 200, "Line-by-line cursor movement advances the chromium preview")
	var advances := 0
	for i in range(1, positions.size()):
		if positions[i] > positions[i - 1] + 10: advances += 1
	r.check(advances >= 2, "Preview scroll follows multiple intermediate cursor positions")
	await r.snapshot("13-markdown-scrolled")
	await r.say("Move back up through Markdown line by line")
	for i in 28:
		r._send_key(KEY_K, "k".unicode_at(0), {})
		await r.hold(0.04)
	await r.hold(0.3)
	var returned: float = float(await evaluate(preview, "window.scrollY"))
	r.check(returned < scrolled - 100, "Moving the cursor back up moves the preview back")
	await finish_narration("chromium-markdown", markdown_start)
	r.restore_full_view(saved_effects)

	await r.say("Chapter: Chromium: visual explanations")
	var markdown_session: String = r.demo_sessions.prepared.Markdown.id
	await r.say("Diagram: select the prepared session")
	if not await r.demo_sessions.select("Diagram"): return
	editor = host.pane_focus
	await r.ready_shell(editor)
	r.check(r.demo_sessions.retained("Markdown"), "The Markdown session stays alive")
	await r.say("Diagram: launch Claude in its session")
	if "--markdown-transition-only" in OS.get_cmdline_user_args():
		await r.snapshot("13b-markdown-departure-landed")
		await r.say("Finished")
		return
	await r.command("claude")
	if not await r.until(func(): return "? for shortcuts" in r.shell_text(editor), "Claude starts in the new terminal"): return
	await r.say("Diagram: ask Claude for an explanation")
	var diagram_start := movie_frame()
	var before_diagram: Array = host.chromiums.keys()
	await r.command("Explain an HTTP request with a diagram in graffitty chromium.", 1)
	if not await r.until(func(): return host.chromiums.size() == before_diagram.size() + 1,
		"Claude opens its HTML diagram through the real Chromium CLI", 30.0): return
	for id in host.chromiums:
		if id not in before_diagram:
			preview_id = id
			preview = host.chromiums[id]
			preview_key = "%%%d" % id
	var temporary_directory := "(location.pathname.startsWith('/tmp/') || location.pathname.startsWith('/private/tmp/'))"
	if OS.get_name() == "Windows":
		temporary_directory = "decodeURIComponent(location.pathname).toLowerCase() === %s" % JSON.stringify(("/" + output.path_join("diagram/http-request.html").replace("\\", "/")).to_lower())
	if not await wait_chromium(preview,
		"location.protocol === 'file:' && " + temporary_directory + " && location.pathname.endsWith('/http-request.html') && document.querySelectorAll('#request-flow [data-stage]').length === 3",
		"Chromium renders all three diagram stages from the temporary HTML file"): return
	r.check(preview.tab_id == int(editor.substr(1)), "The diagram chromium belongs to the Claude conversation")
	if not await r.until(func(): return "ThediagramisopeninChromium." in r.shell_text(editor).replace(" ", "").replace("\n", ""), "Claude finishes its visual explanation"): return
	await r.camera_at_rest()
	r.check_tiles()
	var claude_rect: Rect2 = view.pane_rects[editor]
	var diagram_rect: Rect2 = view.pane_rects[preview_key]
	r.check(diagram_rect.position.x >= claude_rect.end.x and is_equal_approx(diagram_rect.position.y, claude_rect.position.y),
		"Chromium opens directly to the right of Claude")
	if not await wait_chromium(preview, "Array.from(document.querySelectorAll('[data-stage]')).every(el => el.getBoundingClientRect().bottom <= innerHeight)",
		"All three diagram cards fit inside the visible chromium viewport"): return
	var diagram_url: String = str(await evaluate(preview, "location.href"))
	r.check(view.panes[preview_key].chrome.address.text == diagram_url,
		"The Chromium address bar shows the same file URL as the diagram")
	r.check(FileAccess.file_exists(output.path_join("http-request.html")), "Claude wrote the diagram HTML on disk")
	r.visual_explanation = {"url": diagram_url, "address_bar": view.panes[preview_key].chrome.address.text,
		"terminal": editor, "chromium": preview_key, "chromium_owner": preview.tab_id,
		"markdown_preserved": true, "markdown_session": markdown_session, "diagram_session": r.demo_sessions.prepared.Diagram.id,
		"stages": await evaluate(preview, "Array.from(document.querySelectorAll('[data-stage]'), el => el.dataset.stage)"),
		"html_sha256": FileAccess.get_sha256(output.path_join("http-request.html"))}
	await r.say("Diagram: local HTML ready")
	await r.snapshot("13a-claude-local-diagram")
	await r.hold(0.5)
	await finish_narration("chromium-diagram", diagram_start)
	await r.say("Diagram: explanation complete")

	await r.say("Chapter: Chromium: automation")
	await r.say("Automation: select the prepared session")
	if not await r.demo_sessions.select("Automation"): return
	editor = host.pane_focus
	var previous_chromiums: Array = host.chromiums.keys()
	var search_tab: int = host.get_tabs()[1].id
	var search_pane: String = host.workspace_layout.tab(search_tab).focused
	r.check(host.workspace_layout.tabs.size() == 2, "Automation retains its two prepared tabs")
	await r.ready_shell(editor)
	var codex: String = await r.add_window(editor, "h")
	if codex.is_empty(): return
	await r.ready_shell(codex)
	var launch_effects: Dictionary = r.hold_full_view()
	await r.click(r.on(view.panes[editor].handle))
	await r.say("Automation: launch Claude")
	await r.command("claude", 1)
	# Launch both agents consecutively, as in the Android demo. Camera decay
	# and the first agent's startup do not need to block input to its neighbor.
	await r.click(r.on(view.panes[codex].handle))
	if not await r.until(func(): return host.pane_focus == codex, "Codex pane has focus before typing"): return
	await r.say("Automation: launch Codex")
	await r.command("codex", 1)
	if not await r.until(func(): return "? for shortcuts" in r.shell_text(editor), "Claude mock is ready"): return
	if not await r.until(func(): return "? for shortcuts" in r.shell_text(codex), "Codex mock is ready"): return
	await r.click(r.on(view.panes[editor].handle))
	await r.say("Automation: type test prompts")
	await r.command("Use graffitty chromium to run the button test", 1)
	# The first chromium inserts another tile and moves Codex's handle. Wait
	# for that layout change before aiming, then recheck after pointer travel.
	if not await r.until(func(): return host.chromiums.size() == previous_chromiums.size() + 1,
		"Claude opens its chromium before the next pane is targeted", 30.0): return
	await r.owner_at_rest()
	await r.point_at(r.on(view.panes[codex].handle))
	await r.point_at(r.on(view.panes[codex].handle), 0.2)
	await r.press()
	await r.release()
	if not await r.until(func(): return host.pane_focus == codex, "Codex pane has focus before its prompt"): return
	await r.command("Use graffitty chromium to run the E2E test", 1)
	if not await r.until(func(): return host.chromiums.size() == previous_chromiums.size() + 2,
		"Both agents create their own new test chromiums", 30.0): return
	var task_id := 0
	for id in host.chromiums:
		if id in previous_chromiums: continue
		if host.chromiums[id].tab_id == int(editor.substr(1)):
			preview_id = id
			preview = host.chromiums[id]
			preview_key = "%%%d" % id
		elif host.chromiums[id].tab_id == int(codex.substr(1)):
			task_id = id
	if not r.check(task_id != 0 and task_id != preview_id, "Each new chromium belongs to its own agent"): return
	var task_chromium: Node = host.chromiums[task_id]
	var task_key := "%%%d" % task_id
	r.check(preview.tab_id == int(editor.substr(1)) and task_chromium.tab_id == int(codex.substr(1)),
		"Each chromium belongs to the agent that controls it")
	if not await r.until(func(): return preview.texture != null and task_chromium.texture != null,
		"Both test pages are visible at original playback speed"): return
	if not await wait_chromium(preview, "!!document.querySelector('#increment')", "The button test is loaded"): return
	if not await wait_chromium(task_chromium, "!!document.querySelector('form')", "The E2E test is loaded"): return
	await r.say("Both chromium tests visible")
	await r.camera_at_rest()
	# Arrange only the newly created chromiums; the diagram workspace stays intact.
	await r.rearrange(preview_key, editor, "bottom")
	await r.rearrange(task_key, codex, "bottom")
	r.check(r.demo_sessions.retained("Diagram"), "The diagram session remains open during automation")
	r.check_tiles()
	r.check(view.pane_rects[editor].position.y < view.pane_rects[preview_key].position.y
		and view.pane_rects[codex].position.y < view.pane_rects[task_key].position.y,
		"Two agent terminals sit above their two chromiums")
	if not r.failures.is_empty(): return
	if not await wait_chromium(preview, "Number(document.querySelector('#count')?.textContent) >= 2", "Claude's real CLI clicks update the counter", 60.0): return
	if not await wait_chromium(task_chromium, "!!document.querySelector('li.done')", "Codex's real CLI completes the task workflow", 60.0): return
	for chromium in [preview, task_chromium]:
		var monitor: Node = chromium.resource_monitor
		if not await r.until(func(): return monitor != null and monitor.enabled and monitor.cpu_valid and monitor.memory_current > 0,
			"Chromium resource monitor publishes real CPU and memory samples", 20.0): return
	r.restore_full_view(launch_effects)
	await r.say("Both chromium tests running")
	await r.hold(1.0)
	await r.snapshot("14-agents-and-chromiums")
	if not "--skip-native-window" in OS.get_cmdline_user_args():
		await native_window_demo(task_chromium, task_key, editor, codex)
		if not r.failures.is_empty(): return

	var chromium_size: Vector2 = view.pane_rects[preview_key].size
	await r.say("Zoom out with both agents working")
	var ownership_start := movie_frame()
	await r.pinch_overview()
	await r.hold(0.4)
	var area: Rect2 = view.content_rect()
	await drag_out(preview_key, Vector2(area.position.x, area.end.y + 90))
	await drag_out(task_key, Vector2(area.get_center().x + 120, area.end.y + 300))
	# Include the entire loop and both owners before the narration reaches it.
	var sweep: Rect2 = view.pane_rects[task_key]
	sweep = sweep.merge(Rect2(sweep.position + Vector2(320, 110), sweep.size)).grow(120)
	var bounds: Rect2 = area.merge(view.pane_rects[preview_key]).merge(sweep)
	var goal: Dictionary = view.fit_frame(bounds, view.viewport_content_rect(), view.size, .9)
	var center: Vector2 = view.navigation_center
	var zoom: float = view.navigation_zoom
	for i in 49:
		var t := smoothstep(0.0, 1.0, float(i) / 48.0)
		view.navigation_center = center.lerp(goal.center, t)
		view.navigation_zoom = lerpf(zoom, goal.zoom, t)
		view._apply_navigation()
		await r.process_frame
	await r.camera_at_rest()
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	for key in [preview_key, task_key]:
		r.check(Layout.find(tree, key).get("stashed", false), "Chromium remains connected outside Main View: " + key)
	r.check(active_agent(editor) and active_agent(codex), "Both agents keep executing tools while their chromiums are outside Main View")
	r.check(view.chromium_links.edges.size() == 2, "Both chromium ownership connections remain drawn")
	var counter_before: float = float(await evaluate(preview, "Number(document.querySelector('#count').textContent)"))
	# Narration starts 0.25s after the overview beat; “connecting line” is
	# spoken at 14.36s. Move the right browser while its live edge follows.
	while movie_frame() < ownership_start + int(14.61 * 60): await r.process_frame
	await r.say("Ownership: move right chromium with connecting line")
	var right_position: Vector2 = view.pane_rects[task_key].position
	var handle: Control = view.panes[task_key].handle
	var grip: Vector2 = handle.get_global_transform() * (handle.size * .5) - right_position
	await r.point_at(r.on(handle), .15)
	await r.press()
	var circle_start := movie_frame()
	var previous: Vector2 = r.overlay.pointer
	var loop_visible := true
	while movie_frame() - circle_start <= 156:
		var t := minf(float(movie_frame() - circle_start) / 156.0, 1.0)
		var angle := PI - TAU * t
		var position := right_position + Vector2(160 + 160 * cos(angle), 110 * sin(angle))
		var point: Vector2 = view.window_point(position + grip)
		r.overlay.pointer = point
		r._motion(point, point - previous)
		previous = point
		await r.process_frame
		for edge in view.chromium_links.edges:
			for vertex in edge:
				loop_visible = loop_visible and view.viewport_content_rect().has_point(vertex)
	await r.release()
	r.check(loop_visible, "Both ownership lines stay visible throughout the circular drag")
	r.check(Layout.find(host.workspace_layout.tab(host.workspace_layout.active).tree, task_key).get("stashed", false),
		"Right chromium stays detached after its circular drag")
	r.check(not view.pane_rects[task_key].intersects(view.content_rect()), "Circular drag stays outside Main View")
	r.check(view.chromium_links.edges.size() == 2, "Both ownership lines follow the moved right chromium")
	await r.say("Ownership: right chromium movement complete")
	await finish_narration("chromium-ownership", ownership_start)
	await r.snapshot("15-chromium-connections")
	await r.say("Fit to Main View while the agents continue")
	await r.view_menu("Fit to Main Area")
	await r.camera_at_rest()
	await r.hold(1.5)
	r.check(not view.overview, "Final framing fits Main View")
	r.check(active_agent(editor) and active_agent(codex), "Agents are still working in the final frame")
	r.check(float(await evaluate(preview, "Number(document.querySelector('#count').textContent)")) > counter_before,
		"Chromium automation continues while its pane is stashed")
	await r.snapshot("16-agents-main-view")
	r.check(host.workspace_layout.tabs.size() == 2,
		"Automation finishes in its original separate tab without creating extra tabs")
	await r.say("Chapter: tabs: status at a glance")
	var summary_start := movie_frame()
	var tab_bar: Control = view.tab_bar
	var tab_menu: Control = tab_bar.navigation.menu
	await r.click(r.on(tab_bar.navigation.all_tabs))
	if not await r.until(func(): return tab_menu.visible, "The down arrow opens the all-tabs status summary"): return
	# Compare labels with the snapshot actually rendered by the popup. Polling
	# the host again can observe a newer CPU/RAM sample between refreshes.
	var items: Array = tab_menu._items
	r.check(tab_menu.list.item_count == 2,
		"The summary lists every workspace tab")
	for i in items.size():
		var row: Button = tab_menu.list.rows[i]
		var props: Dictionary = row.get_meta("mod_props")
		var rendered: Control = row.get_meta("mod_view")
		r.check(rendered.render_now().is_empty(), "The tab summary mod renders without errors")
		var texts: PackedStringArray = rendered.texts()
		r.check(row.get_meta("id") == items[i].id and str(items[i].pane_count) in texts,
			"The summary preserves each tab's identity and pane count")
		r.check(str(items[i].resources.cpu) in texts and str(items[i].resources.ram) in texts,
			"The summary displays each tab's CPU and RAM totals")
		r.check(props.badges.size() == items[i].agents.size(),
			"The summary includes each tab's aggregated agent statuses")
	r.check(active_agent(editor) and active_agent(codex), "Both automation agents keep running under the tab summary")
	r.tabs_summary = {"tab_count": items.size(), "items": items,
		"active_tab": host.workspace_layout.active, "visible": tab_menu.visible}
	await r.say("Tabs: all statuses visible")
	await r.point_at(r.root.get_visible_rect().size * Vector2(.85, .9), .5)
	await r.hold(.5)
	await r.snapshot("17-all-tabs-status-summary")
	await r.hold(5.5)
	await r.keys("escape")
	await r.say("Tabs: prefix V opens search")
	await r.keys("ctrl+a")
	await r.keys("v")
	if not await r.until(func(): return tab_menu.visible and tab_menu.search.has_focus(), "Prefix V opens the focused tab search"): return
	await r.type("HTTP")
	if not await r.until(func(): return tab_menu.list.rows.any(func(row): return row.get_meta("pane_key", "") == search_pane), "Searching a pane title shows its match under the owning tab"): return
	await r.keys("down")
	r.check(tab_menu.search.text == "HTTP", "Arrow selection preserves the search text")
	r.tabs_summary.search = {"query": "HTTP", "pane": search_pane,
		"rows": tab_menu.model.filter(host.get_tab_menu_items(), "HTTP"),
		"match_color": "#ffd078"}
	var typo_matches := 0
	for row in r.tabs_summary.search.rows:
		if row.kind != "pane": continue
		r.check(not row.match_indices.is_empty(), "Pane search highlights the characters actually matched, including typo matches")
		var matched := ""
		for index in row.match_indices:
			r.check(index >= 0 and index < str(row.title).length(), "Match highlights stay within the pane title")
			matched += str(row.title)[index].to_upper()
		if matched != "HTTP": typo_matches += 1
	r.check(typo_matches > 0, "The recorded search includes typo matches, not only exact HTTP titles")
	await r.say("Tabs: matching panes visible")
	await r.snapshot("17a-tab-pane-search")
	await r.hold(2.0)
	await finish_narration("tabs-summary", summary_start)
	await r.say("Tabs: status summary complete")
	await r.keys("escape")
	if not await r.until(func(): return not tab_menu.visible, "Escape closes the summary without switching tabs"): return
	await r.hold(.5)
	await r.say("Chapter: command line: fuzzy finder built in")
	var command_start := movie_frame()
	var overview_before_command: bool = view.overview
	# The composition shows this sequence as Ctrl A, then : at the real keydowns.
	var prefix_frame := movie_frame()
	await r.keys("ctrl+a")
	await r.type(":")
	if r.capture_active:
		r.shortcut_events.append({"combo": "ctrl+a,colon", "label": "Open command line",
			"prefix_frame": prefix_frame, "frame": r.typing_events[-1].key_frames[-1]})
	if not await r.until(func(): return host.command_line_open(), "Prefix colon opens the command line"): return
	# "fitmain" also ranks ResizeToFitMain; this query names only the toggle.
	await r.type("fittomain")
	await r.keys("tab")
	r.check(host.command_line.model.accepted().get("candidate", {}).get("label", "") == "FitToMainArea",
		"Fuzzy command search selects Fit to Main Area")
	await r.say("Command line: fuzzy command selected")
	await r.snapshot("18-command-search")
	await r.hold(2.0)
	await r.keys("enter")
	await r.camera_at_rest()
	r.check(not host.command_line_open() and view.overview != overview_before_command,
		"Enter runs the selected Fit to Main Area toggle")
	await r.keys("ctrl+a")
	await r.type("2")
	if not await r.until(func(): return host.command_line_open(), "A tab number opens command mode"): return
	await r.say("Command line: tab selected")
	await r.snapshot("18a-command-tab-search")
	await r.hold(2.0)
	await r.keys("enter")
	await r.camera_at_rest()
	r.check(host.workspace_layout.active == search_tab, "Command mode switches to the prepared notes tab")
	await r.hold(1.0)
	await r.keys("ctrl+a")
	await r.type("1.2")
	if not await r.until(func(): return host.command_line_open(), "A pane number opens command mode"): return
	var chosen_pane: Dictionary = host.command_line.model.accepted().get("candidate", {})
	r.check(chosen_pane.get("kind", "") == "pane", "The tab and pane query resolves to a pane")
	await r.say("Command line: pane selected")
	await r.snapshot("18b-command-pane-search")
	await r.hold(2.0)
	await r.keys("enter")
	await r.camera_at_rest()
	r.check(host.pane_focus == chosen_pane.get("key", ""), "Enter switches tabs and focuses the selected pane")
	await finish_narration("command-line", command_start)
	await r.say("Command line: demonstration complete")
	# End the footage before interrupting our long-running scripted turns.
	await r.say("Finished")
	Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	for key in [editor, codex]:
		await r.click(r.on(view.panes[key].handle))
		await r.keys("ctrl+c")
