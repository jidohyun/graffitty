extends "res://llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
## A product demonstration using the same real input path as the E2E replays.
var output := ""
var demo_directory := "/Users/Shared/demo-workspace/demo"
var capture_active := false
var beats: Array[Dictionary] = []
var peak_typing := 0.0
var typing_events: Array[Dictionary] = []
var settling: Array[Dictionary] = []
var castle_surfaces: Array[String] = []
var human_typing := preload("res://videos/shared/typing/HumanTyping.gd").new()
var voice_durations := {}
var shortcut_events: Array[Dictionary] = []
var visual_explanation := {}
var tabs_summary := {}
var filetree_toggle := {}
var transition_pointer: Array[Dictionary] = []
var demo_sessions: RefCounted
var split_pointer_moves: Array[Dictionary] = []
var pending_split := {}


func point_at(target: Vector2, seconds := 0.7) -> void:
	var split := pending_split
	if not split.is_empty():
		split.start_frame = movie_frame()
		split.from = [overlay.pointer.x, overlay.pointer.y]
	await super.point_at(target, seconds * 0.4)
	if not split.is_empty():
		split.end_frame = movie_frame()
		split.to = [overlay.pointer.x, overlay.pointer.y]
		split_pointer_moves.append(split)
		pending_split = {}


func on_header(key: String, part: String) -> Vector2:
	if part not in ["split_right", "split_down"]:
		return await super.on_header(key, part)
	var view: Control = host.workspace_view
	var header: Control = view.panes[key].header
	# Measure the real button layout without painting a frame or moving the
	# pointer. The subsequent direct approach reveals the controls naturally.
	var hovered: bool = header.hovered
	header.set_hovered(true)
	var rect: Rect2 = header.part_rect(part)
	header.set_hovered(hovered)
	check(rect.has_area(), "The split button has a measured click target")
	pending_split = {"part": part, "points": []}
	return view.window_point(header.get_global_transform() * rect.get_center())


func wait(seconds: float) -> void:
	await super.wait(seconds * 0.45)


func camera_at_rest(seconds := 8.0) -> void:
	var start: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	await super.camera_at_rest(seconds)
	var end: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	if capture_active and end - start > 84:
		settling.append({"start_frame": start, "end_frame": end})


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-output="):
			output = arg.trim_prefix("--demo-output=")
		if arg.begins_with("--demo-directory="):
			demo_directory = arg.trim_prefix("--demo-directory=")
	var audio_path := output.path_join("demo-audio.json")
	if FileAccess.file_exists(audio_path):
		var audio: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(audio_path))
		for voice in audio.get("voices", []): voice_durations[voice.id] = float(voice.duration_s)
	super._initialize()
	# The app's automatic language follows the host's system locale and
	# overrides Godot's --language. Save English in the replay's private config
	# before the Localization autoload reads it, then confirm it took effect.
	root.get_node("Localization").set_language("en-US")
	require_english.call_deferred()
	# The replay base selects its own isolated config directory. Install the
	# Castle preset there before its deferred host startup reads world settings.
	var config := preload("res://config/UserConfig.gd").config_path()
	DirAccess.make_dir_recursive_absolute(config.get_base_dir())
	var settings := ""
	if OS.get_cmdline_user_args().has("--plugin=edinburgh-castle"):
		settings = FileAccess.get_file_as_string("res://videos/main-demo/recording/tiling/castle-client.toml")
	# Footage is silent; narration and music are assembled later. Native agent
	# sounds bypass Godot's Dummy audio driver and need a foreground audio unit.
	settings += "\n[sounds]\nenabled = false\n"
	# Keep the full app viewport in the demo without the bottom status panel.
	settings += "\n[mods.status-line]\nenabled = false\n"
	FileAccess.open(config, FileAccess.WRITE).store_string(settings)
	process_frame.connect(publish_animation_clock)


## Runs before the replay overlay exists, so it cannot use check()'s toast.
func require_english() -> void:
	var english := TranslationServer.get_locale() == "en_US"
	print("[demo] ", "PASS" if english else "FAIL", " The demo records the English interface")
	if not english: failures.append("The demo records the English interface")


func publish_animation_clock() -> void:
	if capture_active and not pending_split.is_empty():
		pending_split.points.append([overlay.pointer.x, overlay.pointer.y])
	if capture_active and "--filetree-transition-only" in OS.get_cmdline_user_args():
		transition_pointer.append({"frame": movie_frame(), "x": overlay.pointer.x, "y": overlay.pointer.y})
	var path := output.path_join("animation-clock")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(str(Engine.get_singleton("GraffittyMovieWriter").frames_written() * 1000 / 60))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)


func say(step: String) -> void:
	print("[demo] ", step)
	var frame: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	beats.append({"frame": frame, "seconds": frame / 60.0, "action": step})


func movie_frame() -> int:
	return Engine.get_singleton("GraffittyMovieWriter").frames_written()


func keys(combo: String) -> void:
	if capture_active and combo in ["cmd+alt+enter", "cmd+enter"]:
		shortcut_events.append({"combo": combo, "frame": movie_frame()})
	await super.keys(combo)


func finish_narration(id: String, start_frame: int) -> void:
	if not capture_active: return
	var end_frame := start_frame + int(ceil((float(voice_durations.get(id, 0)) + 0.8) * 60))
	while movie_frame() < end_frame: await process_frame


func workspace_space_demo(key: String) -> void:
	var view: Control = host.workspace_view
	await say("Workspace: zoom out")
	var start := movie_frame()
	await pinch_overview()
	check(view.overview, "Zooming out reveals space around Main View")
	await finish_narration("workspace-space", start)
	# Resource and agent status belong to every pane, independently of stashing.
	await say("Workspace: pane status")
	start = movie_frame()
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(not Layout.find(tree, key).get("stashed", false), "Pane status is shown before stashing")
	var monitor: Node = host.resource_monitor_for(int(key.substr(1)))
	await until(func(): return monitor != null and monitor.enabled and monitor.cpu_valid and monitor.memory_current > 0,
		"The pane publishes real CPU and RAM samples before stashing", 20.0)
	check(not str(host.agent_api.graph.nodes.get(key, {}).get("status", "")).is_empty(),
		"The pane has agent status before stashing")
	await finish_narration("workspace-status", start)
	await snapshot("03a-pane-status-before-stash")
	await say("Workspace: stash old pane")
	start = movie_frame()
	var area: Rect2 = view.content_rect()
	var handle: Control = view.panes[key].handle
	var offset: Vector2 = handle.get_global_transform() * (handle.size * .5) - view.pane_rects[key].position
	await drag(on(handle), view.window_point(Vector2(area.position.x, area.end.y + 90) + offset), 1.2)
	await hold(.4)
	tree = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(Layout.find(tree, key).get("stashed", false), "The old Claude pane is stashed outside Main View")
	await finish_narration("workspace-stash", start)
	await snapshot("03a-stashed-agent-overview")
	var previous_center: Vector2 = view.navigation_center
	var previous_zoom: float = view.navigation_zoom
	await say("Workspace: fit Main View")
	start = movie_frame()
	await keys("cmd+alt+enter")
	await hold(.5)
	check(not view.overview, "Command-Option-Enter fits Main View")
	await finish_narration("workspace-main", start)
	await snapshot("03b-fit-main-view")
	await say("Workspace: inspect stashed pane")
	start = movie_frame()
	await keys("cmd+alt+enter")
	await hold(.7)
	check(view.overview and view.navigation_center.distance_to(previous_center) < .1
		and absf(view.navigation_zoom - previous_zoom) < .001,
		"The same shortcut restores the previous overview")
	await click(on(view.panes[key].handle))
	await keys("cmd+enter")
	await hold(.6)
	check(host.pane_focus == key and view.navigation_zoom > previous_zoom * 1.5,
		"Fit to Pane brings the stashed Claude pane close")
	await finish_narration("workspace-pane", start)
	await snapshot("03c-inspect-stashed-agent")
	await say("Workspace: return from pane inspection")
	await keys("cmd+enter")
	await hold(1.5)
	check(view.overview and absf(view.navigation_zoom - previous_zoom) < .001,
		"Repeating Command-Enter returns from the pane close-up")
	await snapshot("03d-return-from-pane")


func shell_text(key: String) -> String:
	# Assertions inspect terminal state, including panes outside the camera.
	# Draw glyphs are culled and can be empty while a live pane keeps updating.
	return str(host.sessions[int(key.substr(1))].term.get_text(false).get("text", ""))


func ready_shell(key: String) -> void:
	# Session reattachment and small splits need not retain the startup marker.
	# Wait for the fixture's actual prompt and shell-integration cwd instead.
	var terminal: Node = host.sessions[int(key.substr(1))].term
	var prompt := ">" if OS.get_name() == "Windows" else "$"
	var ready := func():
		var state: Dictionary = terminal.get_ui_state()
		return (not str(state.get("cwd", "")).is_empty() and not state.get("alternate_screen", false)
			and shell_text(key).strip_edges().ends_with(prompt))
	var deadline := Time.get_ticks_msec() + 20000
	while not ready.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(ready.call(), "The isolated demo shell is ready")


func human_text(text: String, max_gap_frames := 0) -> void:
	if text.is_empty(): return
	var frames: Array = human_typing.frames_before(text).duplicate()
	if max_gap_frames > 0:
		for i in frames.size(): frames[i] = mini(int(frames[i]), max_gap_frames)
	var key_frames: Array[int] = []
	for i in text.length():
		for frame in int(frames[i]): await process_frame
		var ch := text[i]
		_send_key(OS.find_keycode_from_string(ch.to_upper()), ch.unicode_at(0), {"shift": ch != ch.to_lower()})
		peak_typing = maxf(peak_typing, host.world.fx_typing)
		key_frames.append(Engine.get_singleton("GraffittyMovieWriter").frames_written())
	if capture_active:
		typing_events.append({"text": text, "frames_before": frames, "key_frames": key_frames})


func type(text: String) -> void:
	# Preserve replay key tokens while pacing all visible text through one model.
	var start := 0
	while start < text.length():
		var token := text.find("{", start)
		if token < 0:
			await human_text(text.substr(start))
			break
		await human_text(text.substr(start, token - start))
		var end := text.find("}", token)
		assert(end > token, "Closed replay key token")
		var key := text.substr(token + 1, end - token - 1)
		assert(NAMED.has(key), "Known replay key token")
		await hold(.10)
		_send_key(NAMED[key][0], 0, {})
		start = end + 1
	await wait(.6)


func command(text: String, max_gap_frames := 0) -> void:
	await human_text(text, max_gap_frames)
	await hold(.12)
	_send_key(KEY_ENTER, 0, {})
	await say("Typing finished")
	await hold(0.3)


func snapshot(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))
	# Retain terminal state beside the actual frame to distinguish PTY content
	# corruption from rendering artifacts during resize/typing effects.
	var terminals := {}
	for id in host.sessions:
		var terminal: Node = host.sessions[id].term
		terminals[str(id)] = {"grid": str(terminal.get_grid_size()),
			"text": terminal.get_text(false)}
	FileAccess.open(output.path_join(name + "-terminals.json"), FileAccess.WRITE).store_string(JSON.stringify(terminals, "\t"))


func demo_time() -> float:
	if capture_active:
		return Engine.get_singleton("GraffittyMovieWriter").frames_written() / 60.0
	return Time.get_ticks_msec() / 1000.0


func until(predicate: Callable, description: String, timeout := 20.0) -> bool:
	var deadline := demo_time() + timeout
	while not predicate.call() and demo_time() < deadline:
		await process_frame
	var passed: bool = predicate.call()
	check(passed, description)
	if not passed:
		await snapshot("failed-" + str(beats.size()))
		for id in host.sessions:
			print("[demo terminal %", id, "] ", shell_text("%%%d" % id))
	return passed


func file_point(key: String, filename: String) -> Vector2:
	var terminal: Node = host.sessions[int(key.substr(1))].term
	var rows := {}
	for glyph in terminal.cell_glyphs():
		var line: String = rows.get(int(glyph.row), "")
		while line.length() <= int(glyph.col): line += " "
		line[int(glyph.col)] = String.chr(int(glyph.cp))
		rows[int(glyph.row)] = line
	for row in rows:
		var col: int = rows[row].find(filename)
		if col >= 0:
			var pane: Control = host.workspace_view.panes[key]
			var local: Vector2 = terminal.position + Vector2(col + 2.5, row + 0.5) * terminal.get_cell_size()
			return host.workspace_view.window_point(pane.body.get_global_transform() * local)
	check(false, "Filename is visible for mouse input: " + filename)
	return Vector2.ZERO


func open_file_with_mouse(key: String, filename: String, wait_for_camera := true) -> void:
	if wait_for_camera: await camera_at_rest()
	await say("Point to " + filename)
	await point_at(file_point(key, filename))
	# Re-measure after the approach. The camera can still be easing after a
	# divider drag and Neovim needs both presses in the same cell.
	var point := file_point(key, filename)
	_motion(point, point - overlay.pointer)
	overlay.pointer = point
	tap()
	await process_frame
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	event.double_click = true
	event.position = point
	event.global_position = point
	root.push_input(event, true)
	await release(MOUSE_BUTTON_LEFT, 0.0)
	await hold(0.3)


func chromium_ready(chromium: Node, expression: String, label: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var reply: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
			"expression": expression, "returnByValue": true}})
		if reply.get("result", {}).get("result", {}).get("value", false) == true:
			check(true, label)
			return true
		await process_frame
	var diagnostic: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "JSON.stringify({url:location.href, video: (() => { const v=document.querySelector('video'); return v ? {ready:v.readyState, paused:v.paused, time:v.currentTime, error:v.error?.message, h264:v.canPlayType('video/mp4; codecs=\"avc1.42E01E\"')} : null; })()})",
		"returnByValue": true}})
	print("[demo chromium] ", diagnostic.get("result", {}).get("result", {}).get("value", ""))
	await snapshot("failed-chromium-preview")
	check(false, label)
	return false


func resize_filetree_width(fraction: float) -> float:
	var view: Control = host.workspace_view
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var area: Rect2 = view.content_rect()
	for divider in Layout.tile_dividers(tree.tiles, area):
		if divider.axis != "h": continue
		var point: Vector2 = divider.rect.get_center()
		var previous := (point.x - area.position.x) / area.size.x
		await point_at(view.window_point(point), 0.2)
		await press()
		await point_at(view.window_point(Vector2(area.position.x + area.size.x * fraction, point.y)), 0.45)
		await release()
		await owner_at_rest()
		return previous
	check(false, "Filetree has a draggable width divider")
	return fraction

func enlarge_image(chromium_key: String) -> void:
	var view: Control = host.workspace_view
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var old_height: float = view.pane_rects[chromium_key].size.y
	for divider in Layout.tile_dividers(tree.tiles, view.content_rect()):
		if divider.axis != "v": continue
		var point: Vector2 = divider.rect.position + divider.rect.size * Vector2(0.65, 0.5)
		var destination := Vector2(point.x, view.content_rect().end.y - 110)
		await say("Enlarge the image pane")
		await point_at(view.window_point(point), 0.2)
		await press()
		await point_at(view.window_point(destination), 0.45)
		await release()
		await hold(0.2)
		check(view.pane_rects[chromium_key].size.y > old_height * 1.4,
			"Dragging the divider makes the PNG viewer substantially larger")
		return
	check(false, "The image viewer has a draggable divider")


func hold_full_view() -> Dictionary:
	var cfg = host.world.fx_cfg
	var active: String = str(cfg.behavior.active_state)
	var frame: Dictionary = cfg.frame(active)
	var saved := {"state": active, "camera.zoom": frame["camera.zoom"],
		"camera.tilt_limit_deg": frame["camera.tilt_limit_deg"], "pane_zoom": cfg.typing_settings().pane_zoom}
	cfg.set_option("state." + active, "camera.zoom", 1.0)
	cfg.set_option("state." + active, "camera.tilt_limit_deg", 0.0)
	cfg.set_option("scene.typing", "pane_zoom", 1.0)
	host.workspace_view._reset_pane_zoom()
	return saved


func restore_full_view(saved: Dictionary) -> void:
	var cfg = host.world.fx_cfg
	for key in ["camera.zoom", "camera.tilt_limit_deg"]:
		cfg.set_option("state." + str(saved.state), key, saved[key])
	cfg.set_option("scene.typing", "pane_zoom", saved.pane_zoom)


func filetree_demo() -> void:
	var view: Control = host.workspace_view
	await say("Select the Filetree session")
	if not await demo_sessions.select("Filetree"): return
	var source: String = host.pane_focus
	var original_count: int = host.sessions.size()
	await ready_shell(source)
	check(host.workspace_layout.tabs.size() == 1, "Filetree has its own prepared session")
	await hold(0.4)
	await say("Chapter: filetree")
	var cwd_narration_start := movie_frame()
	check(not view.panes[source].header.filetree_open, "Filetree toggle starts inactive")
	await point_at(await on_header(source, "filetree"), 1.0)
	await hold(0.25)
	await press()
	await release()
	if not await until(func(): return host.sessions.size() == original_count + 1, "Filetree opens beside its shell"): return
	if not await until(func(): return host.pane_focus != source and view.panes.has(host.pane_focus),
		"Clicking the icon focuses the filetree"): return
	var tree: String = host.pane_focus
	if not await until(func(): return "README.md" in shell_text(tree), "Prepared filetree opens", 30.0): return
	if not await until(func(): return (view.panes[source].header.filetree_open
		and view.panes[tree].header.filetree_open), "Both filetree toggles reflect the server's open state"): return
	for key in [source, tree]:
		await on_header(key, "filetree")
		check(view.panes[key].header.has_part("filetree"), "Open filetree toggle is visible on " + key)
	filetree_toggle = {"source": source, "tree": tree, "active": true, "color": "#4da3ff", "background": "none"}
	check(host.application.notifications.history.is_empty(), "Prepared filetree opens without a setup warning")
	await say("Filetree ready")
	await hold(0.4)
	await snapshot("05-filetree-open")
	await say("Filetree: follow the shell cwd")
	var saved_effects := hold_full_view()
	await say("Cwd effects disabled")
	await click(on(view.panes[source].handle))
	await command("cd docs")
	if not await until(func(): return "notes.txt" in shell_text(tree), "Changing the shell cwd expands docs in the filetree"): return
	var reported_cwd := str(host.sessions[int(source.substr(1))].term.get_ui_state().get("cwd", "")).replace("\\", "/")
	check(reported_cwd.trim_suffix("/").ends_with("/demo/docs"),
		"The shell reports its actual new cwd (%s)" % reported_cwd)
	await hold(0.3)
	await snapshot("06a-filetree-cwd-docs")
	await command("cd ..")
	if not await until(func(): return "notes.txt" not in shell_text(tree), "Returning to the project collapses docs"): return
	await hold(0.3)
	await snapshot("06b-filetree-cwd-collapsed")
	await command("cd ..")
	if not await until(func(): return "demo" in shell_text(tree) and "README.md" not in shell_text(tree), "Moving above the project changes the filetree root to its parent"): return
	await hold(0.3)
	await snapshot("06c-filetree-cwd-parent")
	await command("cd demo")
	if not await until(func(): return "README.md" in shell_text(tree), "Returning to the project expands its folder under the new root"): return
	check(is_equal_approx(host.world.fx_cam_zoom, 1.0) and host.world.fx_cam_tilt.length() < 0.001,
		"Camera zoom and tilt remain off during cwd navigation")
	check(is_equal_approx(host.world.fx_cfg.typing_settings().pane_zoom, 1.0),
		"Pane zoom remains off during cwd navigation")
	await say("Cwd view settled")
	await hold(0.3)
	await snapshot("06-filetree-cwd")
	await finish_narration("filetree-cwd", cwd_narration_start)
	await say("Chapter: filetree: edit filenames like a vim buffer")
	var rename_narration_start := movie_frame()
	# The confirmation lists both relative paths. Widen the actual pane so
	# neither filename is clipped at the platform's native font/DPI settings.
	var previous_filetree_width := await resize_filetree_width(0.45 if OS.get_name() == "Windows" else 0.60)
	await open_file_with_mouse(tree, "docs")
	if not await until(func(): return "notes.txt" in shell_text(tree), "Mouse opens docs for editing"): return
	await click(file_point(tree, "notes.txt"))
	restore_full_view(saved_effects)
	# The click leaves the cursor inside the stem, so ciw replaces just "notes".
	await type("ciw")
	await human_text("plan")
	await keys("escape")
	await hold(0.3)
	await human_text(":w")
	await say("Filetree write typed; hold before Enter")
	await hold(2.0)
	await say("Filetree write submitted")
	await keys("enter")
	await hold(0.4)
	await snapshot("07-filetree-rename-pending")
	if not await until(func(): return "Want to continue?" in shell_text(tree), "Fyler previews the filename change"): return
	check("notes.txt" in shell_text(tree) and "plan.txt" in shell_text(tree), "Rename confirmation shows both complete filenames")
	await keys("enter")
	if not await until(func(): return FileAccess.file_exists(demo_directory.path_join("docs/plan.txt")), "Vim buffer write renames the actual file", 8.0): return
	check(not FileAccess.file_exists(demo_directory.path_join("docs/notes.txt")), "The original filename is gone")
	await hold(0.5)
	await snapshot("08-filetree-renamed")
	await visible_camera_at_rest("Filetree rename")
	await finish_narration("filetree-rename", rename_narration_start)
	if previous_filetree_width > 0: await resize_filetree_width(previous_filetree_width)
	await say("Chapter: filetree: open text files in nvim, and image/video/pdf in chromium")
	await open_file_with_mouse(tree, "plan.txt", false)
	if not await until(func(): return host.sessions.size() == original_count + 2, "Text file opens in connected Neovim"): return
	var editor := ""
	for id in host.sessions:
		var candidate := "%%%d" % id
		if candidate != source and candidate != tree: editor = candidate
	if not await until(func(): return "Keep related work together." in shell_text(editor), "Neovim displays the text file"): return
	host.focus_pane(editor)
	await say("Text viewer ready")
	await hold(2.0)
	await snapshot("09-filetree-text")
	check(host.pane_focus == editor, "Neovim has keyboard focus without moving the pointer")
	await say("Quit Neovim with :q")
	await type(":q")
	await snapshot("09-filetree-quit")
	await keys("enter")
	if not await until(func(): return not view.panes.has(editor), "Neovim exits through :q"): return
	check(not is_instance_valid(host.close_dialog) or not host.close_dialog.visible,
		"Quitting Neovim does not show a close-pane dialog")
	await say("Text viewer closed")
	await camera_at_rest()
	await say("Text viewer transition settled")
	await hold(0.65)
	await point_at(file_point(tree, "layout.png"), 1.75)
	await hold(0.3)
	await open_file_with_mouse(tree, "layout.png")
	if not await until(func(): return host.chromiums.size() == 1, "PNG opens in Chromium", 40.0): return
	var chromium: Node = host.chromiums.values()[0]
	if not await until(func(): return chromium.texture != null, "Chromium renders the image", 30.0): return
	var decoded := false
	var deadline := Time.get_ticks_msec() + 10000
	while not decoded and Time.get_ticks_msec() < deadline:
		var loaded: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
			"expression": "location.href.endsWith('/docs/layout.png') && document.images[0]?.complete && document.images[0]?.naturalWidth === 640",
			"returnByValue": true}})
		decoded = loaded.get("result", {}).get("result", {}).get("value", false) == true
		if not decoded: await process_frame
	check(decoded, "Chromium decodes the actual demo PNG")
	await say("Image viewer ready")
	await snapshot("10-filetree-image")
	await hold(0.7)
	var chromium_key: String = "%%%d" % host.chromiums.keys()[0]
	await enlarge_image(chromium_key)
	await hold(0.4)
	check(host.world.fx_typing < 0.01, "Mouse-driven file opening and resizing leave typing effects idle")
	await snapshot("11-filetree-image-large")
	await say("Open video from filetree")
	await open_file_with_mouse(tree, "video.webm")
	if not await chromium_ready(chromium,
		"location.pathname.endsWith('/docs/video.webm') && document.querySelector('video')?.readyState >= 2",
		"Chromium decodes the demo video"): return
	var playback: Dictionary = await chromium.request("cdp", {"method": "Runtime.evaluate", "params": {
		"expression": "document.querySelector('video').paused", "returnByValue": true}})
	if playback.get("result", {}).get("result", {}).get("value", true) == true:
		await click(on(view.panes[chromium_key].body))
	if not await chromium_ready(chromium, "document.querySelector('video')?.currentTime > 0.25 && !document.querySelector('video').paused",
		"The video is visibly playing"): return
	await say("Video viewer ready")
	if not await chromium_ready(chromium, "document.querySelector('video')?.ended === true",
		"The demo video finishes before opening the PDF"): return
	await say("Video playback ended")
	await snapshot("11a-filetree-video")
	await say("Open PDF from filetree")
	await open_file_with_mouse(tree, "layout.pdf")
	if not await chromium_ready(chromium,
		"location.pathname.endsWith('/docs/layout.pdf') && document.readyState === 'complete'",
		"Chromium opens the demo PDF"): return
	await camera_at_rest()
	await hold(2.0)
	await snapshot("11b-filetree-pdf")
	check(host.chromiums.size() == 1, "Image, video, and PDF reuse one Chromium pane")
	await say("Close the file viewer")
	while chromium.page_tabs.size() > 1:
		var page_count: int = chromium.page_tabs.size()
		await click(on(view.panes[chromium_key].chrome.tabs.buttons[chromium.selected_page_id].get_node("Close")))
		if not await until(func(): return chromium.page_tabs.size() < page_count, "Close a file preview tab"): return
	await click(on(view.panes[chromium_key].chrome.tabs.buttons[chromium.selected_page_id].get_node("Close")))
	await hold(.3)
	await keys("enter")
	if not await until(func(): return not view.panes.has(chromium_key), "Close Chromium after the file previews"): return
	await camera_at_rest()
	await say("Chapter: filetree: send paths to the terminal")
	var path_effects := hold_full_view()
	var paths_start := movie_frame()
	await click(on(view.panes[source].handle))
	await human_text("cd")
	await click(file_point(tree, "docs"))
	await type("2")
	await hold(0.18)
	await type("-")
	if not await until(func(): return str(host.sessions[int(source.substr(1))].term.get_ui_state().get("cwd", "")).replace("\\", "/").trim_suffix("/").ends_with("/demo/docs"),
		"Sending the selected directory path changes the connected shell directory"): return
	await finish_narration("filetree-send-path", paths_start)
	if "--filetree-transition-only" in OS.get_cmdline_user_args():
		# Off-camera setup skips narration holds. Preserve the final hold so
		# restoring the normal effects cannot revive the just-typed 2- sparks.
		await hold(float(voice_durations.get("filetree-send-path", 4.96)) + 0.8)
		check(host.world.fx_typing < 0.01, "Typing effects settle before the direct session transition")
		beats.clear()
		typing_events.clear()
		shortcut_events.clear()
		settling.clear()
		capture_active = true
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
		await say("Filetree: paths ready for next session")
	await snapshot("11c-filetree-send-path")
	restore_full_view(path_effects)
	check(demo_sessions.retained("Workspace"), "The opening workspace remains alive in its session")
	check(host.workspace_layout.tabs.size() == 1, "Filetree stays within its prepared session")


func visible_camera_at_rest(context: String) -> void:
	# Move on once the camera looks settled; the typing effect's invisible
	# decay tail is not a useful pause between the opening narration lines.
	await owner_at_rest()
	var view: Control = host.workspace_view
	var deadline: float = overlay.clock + 8.0
	var last := PackedVector2Array()
	var last_at := 0.0
	var still := 0
	while overlay.clock < deadline and still < 3:
		await process_frame
		var corners := PackedVector2Array([view.window_point(Vector2.ZERO), view.window_point(view.canvas_size())])
		var speed := INF
		if not last.is_empty() and overlay.clock > last_at:
			speed = maxf(corners[0].distance_to(last[0]), corners[1].distance_to(last[1])) / (overlay.clock - last_at)
		still = still + 1 if landed() and host.world.tab_fx_t < 0.0 and speed < 2.0 else 0
		last = corners
		last_at = overlay.clock
	check(still >= 3, context + " camera visibly settles before continuing")
	await say(context + " camera settled")


func rearrange(source: String, target: String, edge: String, opening := false) -> void:
	var view: Control = host.workspace_view
	await say("Rearrange " + source + " to the " + edge + " of " + target)
	var rect: Rect2 = view.pane_rects[target]
	var point := rect.position + rect.size * Vector2(0.5, 0.5)
	if edge == "bottom": point.y = rect.end.y - 40
	if edge == "right": point.x = rect.end.x - 40
	await point_at(on(view.panes[source].handle), 0.7)
	await press()
	await point_at(view.window_point(point), 1.25)
	await hold(0.25)
	check(view.layout_preview.visible, "Dragging previews the resulting tiles")
	check(view.preview_plan.get("edge", "") == edge, "The intended split edge is selected")
	var preview: Dictionary = view.preview_plan.get("rectangles", {}).duplicate(true)
	await release()
	if opening: await visible_camera_at_rest("Opening")
	else: await camera_at_rest()
	check_tiles()
	for key in preview:
		check(view.pane_rects.has(key) and view.pane_rects[key].is_equal_approx(preview[key]),
			"Committed drop matches the visible preview: " + str(key))
	print("DEMO_DROP ", {"preview":preview, "actual":view.pane_rects})
	check(not view.overview, "Rearranging stays in Main View")
	if not opening: await hold(0.35)


func play() -> void:
	# Use the desktop DPI policy so the recorded chrome has native proportions.
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = maxf(1.0, DisplayServer.screen_get_scale(root.current_screen))
	root.size = Vector2i(2400, 1500)
	await hold(0.3)
	var previous := overlay
	overlay = load("res://videos/shared/TilingPointer.gd").new()
	previous.get_parent().add_child(overlay)
	previous.queue_free()
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	await ready_shell(first)
	var castle := OS.get_cmdline_user_args().has("--plugin=edinburgh-castle")
	if not castle:
		check(host.world.default_config == "res://presets/flat.conf",
			"The demo uses the bundled Flat effects preset")
	check(host.world.fx_enabled and host.world.fx_cfg.frame("typing")["typing.particles"] == "sparks",
		"Default typing sparks are enabled")
	var defaults := preload("res://graffitty/terminal_config.gd").new()
	var actual = host.world.terminal_config
	check(actual.background.color == defaults.background.color
		and is_equal_approx(actual.background.alpha, 0.5 if castle else defaults.background.alpha)
		and actual.font_family == defaults.font_family and actual.font_size == defaults.font_size,
		"Terminal appearance uses the approved world settings")
	demo_sessions = preload("res://videos/shared/DemoSessions.gd").new(self)
	if not await demo_sessions.name_current("Workspace"): return
	FileAccess.open(output.path_join("host-mode"), FileAccess.WRITE).close()
	for name in ["Filetree", "Markdown", "Diagram", "Automation"]:
		if not await demo_sessions.create(name): return
		await ready_shell(host.pane_focus)
		if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
			await view_menu("Tiling")
		view.show_main()
	# The tab-summary and numeric-command features still demonstrate real tabs
	# inside Automation. Prepare their second tab before showing any footage.
	var automation_pane: String = host.pane_focus
	host.create_session()
	if not await until(func(): return host.workspace_layout.tabs.size() == 2, "Prepare Automation's search tab"): return
	var notes_tab: int = host.get_tabs()[1].id
	if not await until(func(): return (host.workspace_layout.active == notes_tab
		and host.pane_focus != automation_pane
		and host.pane_focus == host.workspace_layout.tab(notes_tab).focused),
		"The prepared notes tab owns focus before naming its pane"): return
	await ready_shell(host.pane_focus)
	await host.set_pane_title(host.pane_focus, "HTP notes")
	host.workspace_layout.set_title(host.workspace_layout.active, "HTTP notes")
	await host.session_backend.connection.remote_call(host.active_session_id, "tab.set_title", {"id": host.workspace_layout.active, "title": "HTTP notes"})
	check(host.get_tab_menu_items()[1].panes.any(func(pane): return pane.key == host.pane_focus and pane.title == "HTP notes"),
		"The notes pane has its searchable title before capture")
	await select_tab(0)
	if not await demo_sessions.show_compact(): return
	if not await demo_sessions.select("Workspace"): return
	DirAccess.remove_absolute(output.path_join("host-mode"))
	if not failures.is_empty(): return
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		await view_menu("Tiling")
	view.show_main()
	await type("git log --oneline -3{enter}")
	await super.camera_at_rest()
	await hold(0.5)
	overlay.pointer = root.get_visible_rect().size * Vector2(0.72, 0.83)
	await RenderingServer.frame_post_draw
	var canvas := root.get_texture().get_image().get_size()
	check(canvas == Vector2i(2400, 1500), "Movie canvas fits the native UI: %s" % canvas)
	var capture_from_filetree := "--capture-from-filetree" in OS.get_cmdline_user_args()
	capture_active = not capture_from_filetree and "--filetree-transition-only" not in OS.get_cmdline_user_args()
	Engine.get_singleton("GraffittyMovieWriter").set_recording(capture_active)
	if "--chromium-only" in OS.get_cmdline_user_args():
		await load("res://videos/main-demo/recording/tiling/ChromiumChapters.gd").new(self).play()
		return
	if "--filetree-only" in OS.get_cmdline_user_args():
		await filetree_demo()
		if not failures.is_empty(): return
		if "--through-filetree" in OS.get_cmdline_user_args():
			await load("res://videos/main-demo/recording/tiling/ChromiumChapters.gd").new(self).play()
		else:
			await say("Finished")
		return
	await say("One terminal in Main View")
	var intro_start := movie_frame()
	await hold(0.4)
	await snapshot("01-one-pane")
	await say("Create a pane to the right")
	var second := await add_window(first, "h")
	if second.is_empty(): return
	await ready_shell(second)
	await say("Create a pane below")
	# The native agent mock needs the host CLI and its inherited workspace
	# capability. The two existing Podman shells remain alive beside it.
	FileAccess.open(output.path_join("host-mode"), FileAccess.WRITE).close()
	var third := await add_window(second, "v")
	if third.is_empty(): return
	await ready_shell(third)
	await say("Type in the last pane")
	await command("claude")
	if not await until(func(): return "? for shortcuts" in shell_text(third), "The opening Claude mock is ready"): return
	# Demonstrate dragging immediately, while the typing effect settles.
	await owner_at_rest()
	await snapshot("02-three-panes")
	var pids := {}
	for key in [first, second, third]:
		pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
	await rearrange(third, first, "bottom", true)
	await snapshot("03-first-shuffle")
	for key in pids:
		check(host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key],
			"The same shell survives the layout change")
		if key == third:
			check("claude" in view.panes[key].handle.text.to_lower(), "The agent supplies the Claude pane title")
		else:
			check(view.panes[key].handle.text.replace("\\", "/").trim_suffix("/").ends_with("/demo"),
				"The default pane title uses the demo working directory")
	check(host.workspace_layout.tabs.size() == 1 and view.panes.size() == 3,
		"Three distinct terminals remain in one tab")
	check(peak_typing > 0.5, "Simulated typing activates the default effects")
	await finish_narration("intro", intro_start)
	await workspace_space_demo(third)
	if not failures.is_empty(): return
	if "--opening-only" in OS.get_cmdline_user_args():
		await say("Finished")
		return
	if capture_from_filetree:
		# Recreate the Workspace session for a continuous splice without recording it again.
		beats.clear()
		typing_events.clear()
		shortcut_events.clear()
		settling.clear()
		capture_active = true
		Engine.get_singleton("GraffittyMovieWriter").set_recording(true)
	await filetree_demo()
	if not failures.is_empty(): return
	await load("res://videos/main-demo/recording/tiling/ChromiumChapters.gd").new(self).play()


func finish() -> void:
	if OS.get_cmdline_user_args().has("--plugin=edinburgh-castle"):
		for name in ["Workspace", "Filetree", "Markdown", "Diagram", "Automation"]:
			if demo_sessions != null and demo_sessions.prepared.has(name):
				castle_surfaces.append(demo_sessions.prepared[name].place)
		var expected := ["LiveTerminalWall1", "Royal Palace", "National War Museum", "LiveTerminalWall3", "LiveTerminalWall5"]
		check(castle_surfaces == expected,
			"Every prepared session has its own Castle area: %s" % [castle_surfaces])
	Engine.get_singleton("GraffittyMovieWriter").set_recording(false)
	capture_active = false
	var captured_frames: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	var file := FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"fps": 60, "frames": captured_frames,
		"beats": beats, "settling": settling, "shortcut_events": shortcut_events,
		"failures": failures, "size": [2400, 1500],
		"ui_scale": root.content_scale_factor, "typing_schedule_sha256": human_typing.source_hash,
		"typing_events": typing_events, "visual_explanation": visual_explanation, "tabs_summary": tabs_summary,
		"filetree_toggle": filetree_toggle, "transition_pointer": transition_pointer,
		"split_pointer_moves": split_pointer_moves,
		"session_navigation": demo_sessions.evidence() if demo_sessions != null else {},
		"terminal_config": "app defaults", "effects_preset": host.world.default_config,
		"peak_typing": peak_typing, "castle_surfaces": castle_surfaces}, "\t"))
	file.close()
	super.finish()
